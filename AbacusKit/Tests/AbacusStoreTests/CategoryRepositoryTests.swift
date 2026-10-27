import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Categories")
struct CategoryRepositoryTests {
  typealias F = StoreFixture

  @Test("R-CAT-2: lists by kind; one level of subcategories of the same kind")
  func treeRules() async throws {
    let f = try F()
    try f.seedBasics()
    #expect(try await f.categories.categories(kind: .income, includeArchived: false).map(\.id) == [F.salary.id, F.cashback.id])
    #expect(try await f.categories.categories(kind: nil, includeArchived: false).count == 7)

    // A grandchild is not allowed.
    let snacks = AbacusDomain.Category(name: "Snacks", kind: .expense, parentID: F.groceries.id)
    await #expect(throws: StoreError.invalidParent) { try await f.categories.save(snacks) }
    // A parent with children cannot become a child.
    var food = F.food
    food.parentID = F.transport.id
    await #expect(throws: StoreError.invalidParent) { try await f.categories.save(food) }
    // Child and parent share the kind.
    let bonus = AbacusDomain.Category(name: "Bonus", kind: .income, parentID: F.food.id)
    await #expect(throws: RepositoryError.kindMismatch) { try await f.categories.save(bonus) }
    // A valid child.
    let coffee = AbacusDomain.Category(name: "Coffee", kind: .expense, parentID: F.food.id)
    try await f.categories.save(coffee)
    #expect(try await f.categories.categories(kind: .expense, includeArchived: false).contains(coffee))
  }

  @Test("Archiving a parent archives its children; unarchiving a child restores the parent")
  func archive() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.categories.setArchived(F.food.id, true)
    let visible = try await f.categories.categories(kind: .expense, includeArchived: false).map(\.id)
    #expect(visible == [F.fees.id, F.transport.id])
    try await f.categories.setArchived(F.groceries.id, false)
    let after = try await f.categories.categories(kind: .expense, includeArchived: false).map(\.id)
    #expect(after.contains(F.food.id) && after.contains(F.groceries.id) && !after.contains(F.eatingOut.id))
  }

  @Test("R-CAT-3: deleting a category in use needs a same-kind reassignment target")
  func deleteInUse() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.transport))
    await #expect(throws: RepositoryError.categoryInUse) { try await f.categories.delete(F.transport.id, reassignTo: nil) }
    await #expect(throws: RepositoryError.kindMismatch) { try await f.categories.delete(F.transport.id, reassignTo: F.salary.id) }
    // Nothing changed after the failures.
    #expect(try await f.categories.categories(kind: .expense, includeArchived: true).contains(F.transport))
    // An unused category is deleted outright.
    try await f.categories.delete(F.fees.id, reassignTo: nil)
    #expect(try await !f.categories.categories(kind: nil, includeArchived: true).map(\.id).contains(F.fees.id))
  }

  @Test("R-CAT-3: reassignment moves transactions, attached records, budget, rules and mappings")
  func deleteWithReassign() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(
      F.expense(100, "2026-03-02", 10_00, F.transport),
      lines: [AttachedRecord(txnID: F.id(100), categoryID: F.transport.id, amountMinor: 1_00)])
    let plan = BudgetPlan(id: F.id(200), effectiveMonth: "2026-01")
    try await f.budgets.save(plan, allocations: [
      BudgetAllocation(planID: plan.id, categoryID: F.transport.id, limitMinor: 100_00, currency: .PLN),
      BudgetAllocation(planID: plan.id, categoryID: F.fees.id, limitMinor: 50_00, currency: .PLN),
    ])
    // Another plan whose limits are in different currencies: the target keeps its own (D43).
    let later = BudgetPlan(id: F.id(201), effectiveMonth: "2026-06")
    try await f.budgets.save(later, allocations: [
      BudgetAllocation(planID: later.id, categoryID: F.transport.id, limitMinor: 100_00, currency: .EUR),
      BudgetAllocation(planID: later.id, categoryID: F.fees.id, limitMinor: 50_00, currency: .PLN),
    ])
    let rule = CategoryRule(pattern: "uber", categoryID: F.transport.id)
    try await f.rules.save(rule)
    try await f.database.write { db in
      try db.seed {
        ImportMapping(source: .saldo, kind: .category, externalKey: "Taxi", targetID: F.transport.id)
      }
    }

    try await f.categories.delete(F.transport.id, reassignTo: F.fees.id)

    let row = try #require(try await f.txns.transaction(F.id(100)))
    #expect(row.txn.categoryID == F.fees.id)
    #expect(row.lines.map(\.categoryID) == [F.fees.id])
    let allocations = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 3))).allocations
    #expect(allocations.count == 1)
    #expect(allocations.first?.categoryID == F.fees.id)
    #expect(allocations.first?.limit == Money(minorUnits: 150_00, currency: .PLN))
    let laterAllocations = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 6))).allocations
    #expect(laterAllocations.map(\.limit) == [Money(minorUnits: 50_00, currency: .PLN)])
    #expect(try await f.rules.rules().map(\.categoryID) == [F.fees.id])
    #expect(try await f.imports.mappings(source: .saldo).map(\.targetID) == [F.fees.id])
  }

  @Test("R-CAT-3: deleting a parent moves its children up to top level")
  func deleteParent() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.food))
    // Reassigning to one of its own children works: children move up first.
    try await f.categories.delete(F.food.id, reassignTo: F.groceries.id)
    let all = try await f.categories.categories(kind: .expense, includeArchived: true)
    #expect(!all.map(\.id).contains(F.food.id))
    #expect(all.first { $0.id == F.groceries.id }?.parentID == nil)
    #expect(all.first { $0.id == F.eatingOut.id }?.parentID == nil)
    #expect(try await f.txns.transaction(F.id(100))?.txn.categoryID == F.groceries.id)
  }
}
