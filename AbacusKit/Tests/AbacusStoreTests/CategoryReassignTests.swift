import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// "Re-assign…" of a category (C33): one database transaction, same kind only.
@Suite("Category re-assign")
struct CategoryReassignTests {
  typealias F = StoreFixture

  /// Food (parent) with Groceries and Eating out; Transport and Fees; transactions, lines, a
  /// rule, a mapping and budget limits on Groceries / Transport.
  func seeded() async throws -> F {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries))
    try await f.insert(
      F.expense(101, "2026-03-03", 20_00, F.food),
      lines: [AttachedRecord(txnID: F.id(101), categoryID: F.eatingOut.id, amountMinor: 1_00)])
    try await f.insert(F.expense(102, "2026-03-04", 30_00, F.transport))
    try await f.insert(F.transfer(103, "2026-03-05", from: F.bank, to: F.card, 5_00))
    try await f.insert(F.income(104, "2026-03-06", 99_00, F.salary))
    try await f.rules.save(CategoryRule(pattern: "lidl", categoryID: F.groceries.id))
    try await f.rules.save(CategoryRule(pattern: "bolt", categoryID: F.transport.id))
    try await f.database.write { db in
      try db.seed { ImportMapping(source: .saldo, kind: .category, externalKey: "Shop", targetID: F.groceries.id) }
    }
    let plan = BudgetPlan(id: F.id(200), effectiveMonth: "2026-01")
    try await f.budgets.save(
      plan,
      allocations: [
        BudgetAllocation(planID: plan.id, categoryID: F.groceries.id, limitMinor: 100_00, currency: .PLN),
        BudgetAllocation(planID: plan.id, categoryID: F.transport.id, limitMinor: 50_00, currency: .PLN),
      ])
    return f
  }

  func categoryOf(_ f: F, _ n: Int) async throws -> UUID? { try await f.txns.transaction(F.id(n))?.txn.categoryID }

  @Test("The impact counts a parent together with its subcategories, budget limits included")
  func impact() async throws {
    let f = try await seeded()
    let child = try await f.categories.reassignImpact(of: F.groceries.id)
    #expect(child == CategoryReassignImpact(transactions: 1, attachedRecords: 0, rules: 1, importMappings: 1, budgetLimits: 1))
    let parent = try await f.categories.reassignImpact(of: F.food.id)
    #expect(parent == CategoryReassignImpact(transactions: 2, attachedRecords: 1, rules: 1, importMappings: 1, budgetLimits: 1))
    await #expect(throws: RepositoryError.notFound) { try await f.categories.reassignImpact(of: F.id(999)) }
  }

  @Test("A leaf moves its transactions, rules and mappings; budget limits stay")
  func leaf() async throws {
    let f = try await seeded()
    let moved = try await f.categories.reassign(
      from: F.groceries.id, to: F.fees.id, repointRules: true, archiveAfterwards: false)
    #expect(moved.transactions == 1 && moved.rules == 1 && moved.importMappings == 1)
    #expect(try await categoryOf(f, 100) == F.fees.id)
    #expect(try await categoryOf(f, 101) == F.food.id)  // the parent's own row is not touched
    #expect(try await categoryOf(f, 102) == F.transport.id)
    #expect(try await f.rules.rules().first { $0.pattern == "lidl" }?.categoryID == F.fees.id)
    #expect(try await f.imports.mappings(source: .saldo).map(\.targetID) == [F.fees.id])
    let limits = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 3))).allocations
    #expect(Set(limits.map(\.categoryID)) == [F.groceries.id, F.transport.id])
    let all = try await f.categories.categories(kind: .expense, includeArchived: true)
    #expect(all.contains { $0.id == F.groceries.id && !$0.isArchived })
  }

  @Test("A parent moves its own and its subcategories' transactions and attached lines")
  func parent() async throws {
    let f = try await seeded()
    let moved = try await f.categories.reassign(
      from: F.food.id, to: F.transport.id, repointRules: true, archiveAfterwards: false)
    #expect(moved.transactions == 2 && moved.attachedRecords == 1)
    #expect(try await categoryOf(f, 100) == F.transport.id)
    #expect(try await categoryOf(f, 101) == F.transport.id)
    let lines = try #require(try await f.txns.transaction(F.id(101))).lines
    #expect(lines.map(\.categoryID) == [F.transport.id])
    // The subcategories stay (empty).
    let all = try await f.categories.categories(kind: .expense, includeArchived: false)
    #expect(all.contains { $0.id == F.groceries.id } && all.contains { $0.id == F.eatingOut.id })
  }

  @Test("Rules and mappings stay when the option is off")
  func keepsRules() async throws {
    let f = try await seeded()
    let moved = try await f.categories.reassign(
      from: F.groceries.id, to: F.fees.id, repointRules: false, archiveAfterwards: false)
    #expect(moved.rules == 0 && moved.importMappings == 0)
    #expect(try await categoryOf(f, 100) == F.fees.id)
    #expect(try await f.rules.rules().first { $0.pattern == "lidl" }?.categoryID == F.groceries.id)
    #expect(try await f.imports.mappings(source: .saldo).map(\.targetID) == [F.groceries.id])
  }

  @Test("Archive afterwards archives the category, and a parent with its subcategories")
  func archives() async throws {
    let f = try await seeded()
    try await f.categories.reassign(from: F.food.id, to: F.fees.id, repointRules: true, archiveAfterwards: true)
    let active = try await f.categories.categories(kind: .expense, includeArchived: false).map(\.id)
    #expect(active == [F.fees.id, F.transport.id])
    #expect(try await categoryOf(f, 101) == F.fees.id)
  }

  @Test("Transfers and rows of other categories are untouched")
  func untouched() async throws {
    let f = try await seeded()
    try await f.categories.reassign(from: F.groceries.id, to: F.fees.id, repointRules: true, archiveAfterwards: false)
    #expect(try await categoryOf(f, 103) == nil)
    #expect(try await categoryOf(f, 104) == F.salary.id)
  }

  @Test("A target of another kind, itself or its own subcategory is rejected, and nothing changes")
  func rejected() async throws {
    let f = try await seeded()
    await #expect(throws: RepositoryError.kindMismatch) {
      try await f.categories.reassign(from: F.groceries.id, to: F.salary.id, repointRules: true, archiveAfterwards: true)
    }
    await #expect(throws: RepositoryError.invalidReassignTarget) {
      try await f.categories.reassign(from: F.food.id, to: F.food.id, repointRules: true, archiveAfterwards: false)
    }
    await #expect(throws: RepositoryError.invalidReassignTarget) {
      try await f.categories.reassign(from: F.food.id, to: F.eatingOut.id, repointRules: true, archiveAfterwards: false)
    }
    await #expect(throws: RepositoryError.notFound) {
      try await f.categories.reassign(from: F.food.id, to: F.id(999), repointRules: true, archiveAfterwards: false)
    }
    #expect(try await categoryOf(f, 100) == F.groceries.id)
    #expect(try await categoryOf(f, 101) == F.food.id)
    #expect(try await f.categories.categories(kind: .expense, includeArchived: false).count == 5)
  }

  @Test("A failure in the middle rolls everything back")
  func atomic() async throws {
    let f = try await seeded()
    // Rules are re-pointed after the transactions: make that step fail.
    try await f.database.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER failRuleUpdate BEFORE UPDATE ON categoryRules
          BEGIN SELECT RAISE(ABORT, 'boom'); END
          """)
    }
    await #expect(throws: (any Error).self) {
      try await f.categories.reassign(from: F.groceries.id, to: F.fees.id, repointRules: true, archiveAfterwards: true)
    }
    #expect(try await categoryOf(f, 100) == F.groceries.id)
    #expect(try await f.rules.rules().first { $0.pattern == "lidl" }?.categoryID == F.groceries.id)
    #expect(try await f.categories.categories(kind: .expense, includeArchived: false).count == 5)
  }

  // MARK: Built-in Uncategorised target (C39)

  @Test("A nil target clears the category of the transactions and lines; rules and mappings stay")
  func toUncategorised() async throws {
    let f = try await seeded()
    let moved = try await f.categories.reassign(from: F.food.id, to: nil, repointRules: true, archiveAfterwards: false)
    #expect(moved.transactions == 2 && moved.attachedRecords == 1)
    #expect(moved.rules == 0 && moved.importMappings == 0)
    #expect(try await categoryOf(f, 100) == nil)
    #expect(try await categoryOf(f, 101) == nil)
    let lines = try #require(try await f.txns.transaction(F.id(101))).lines
    #expect(lines.map(\.categoryID) == [nil])
    // Rules and mappings keep pointing at the old category, whatever the option says.
    #expect(try await f.rules.rules().first { $0.pattern == "lidl" }?.categoryID == F.groceries.id)
    #expect(try await f.imports.mappings(source: .saldo).map(\.targetID) == [F.groceries.id])
    // Other rows and the budget are untouched.
    #expect(try await categoryOf(f, 102) == F.transport.id)
    #expect(try await categoryOf(f, 104) == F.salary.id)
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 3))?.allocations.count == 2)
  }

  @Test("A nil target keeps the kind: an income category only touches its own rows")
  func uncategorisedKind() async throws {
    let f = try await seeded()
    try await f.categories.reassign(from: F.salary.id, to: nil, repointRules: false, archiveAfterwards: false)
    #expect(try await categoryOf(f, 104) == nil)
    #expect(try await categoryOf(f, 100) == F.groceries.id)
    #expect(try await categoryOf(f, 102) == F.transport.id)
  }

  @Test("A nil target can archive the category afterwards")
  func uncategorisedArchive() async throws {
    let f = try await seeded()
    try await f.categories.reassign(from: F.groceries.id, to: nil, repointRules: true, archiveAfterwards: true)
    let active = try await f.categories.categories(kind: .expense, includeArchived: false).map(\.id)
    #expect(!active.contains(F.groceries.id))
    #expect(try await categoryOf(f, 100) == nil)
  }

  @Test("A nil target for a missing category is rejected")
  func uncategorisedMissing() async throws {
    let f = try await seeded()
    await #expect(throws: RepositoryError.notFound) {
      try await f.categories.reassign(from: F.id(999), to: nil, repointRules: true, archiveAfterwards: false)
    }
  }
}
