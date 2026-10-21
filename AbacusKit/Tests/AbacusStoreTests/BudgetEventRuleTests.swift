import AbacusDomain
import AbacusStore
import Foundation
import Testing

@Suite("Budget plans")
struct BudgetRepositoryTests {
  typealias F = StoreFixture

  @Test("R-BUD-1: a plan has a total and per-category allocations")
  func allocations() async throws {
    let f = try F()
    try f.seedBasics()
    let plan = BudgetPlan(effectiveMonth: "2026-01", totalMinor: 5_000_00, currency: .PLN)
    try await f.budgets.save(plan, allocations: [
      BudgetAllocation(planID: UUID(), categoryID: F.food.id, limitMinor: 2_000_00),
      BudgetAllocation(planID: UUID(), categoryID: F.transport.id, limitMinor: 500_00),
    ])
    let loaded = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 1)))
    #expect(loaded.plan == plan)
    #expect(loaded.allocations.count == 2)
    #expect(loaded.allocations.allSatisfy { $0.planID == plan.id })
    // Saving again replaces the allocations.
    try await f.budgets.save(plan, allocations: [BudgetAllocation(planID: plan.id, categoryID: F.food.id, limitMinor: 1_000_00)])
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 1))?.allocations.map(\.limitMinor) == [1_000_00])
  }

  @Test("R-BUD-3: a plan repeats until changed; a change applies from its month, past months keep theirs")
  func effectiveMonths() async throws {
    let f = try F()
    try f.seedBasics()
    let january = BudgetPlan(effectiveMonth: "2026-01", totalMinor: 5_000_00, currency: .PLN)
    try await f.budgets.save(january, allocations: [])
    #expect(try await f.budgets.plan(for: Month(year: 2025, month: 12)) == nil)
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 6))?.plan.id == january.id)

    let april = BudgetPlan(effectiveMonth: "2026-04", totalMinor: 6_000_00, currency: .PLN)
    try await f.budgets.save(april, allocations: [])
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 3))?.plan.id == january.id)
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 4))?.plan.id == april.id)
    #expect(try await f.budgets.plan(for: Month(year: 2027, month: 1))?.plan.totalMinor == 6_000_00)

    // A second plan for the same month replaces the first.
    let aprilAgain = BudgetPlan(effectiveMonth: "2026-04", totalMinor: 7_000_00, currency: .EUR)
    try await f.budgets.save(aprilAgain, allocations: [])
    #expect(try await f.budgets.plans().map(\.id) == [january.id, aprilAgain.id])
  }
}

@Suite("Events")
struct EventRepositoryTests {
  typealias F = StoreFixture

  @Test("R-EVT-1: save, archive, list")
  func crud() async throws {
    let f = try F()
    try f.seedBasics()
    let move = Event(name: "Relocation")
    try await f.events.save(move)
    #expect(try await f.events.events(includeArchived: false).map(\.id) == [F.trip.id, move.id])
    try await f.events.setArchived(F.trip.id, true)
    #expect(try await f.events.events(includeArchived: false).map(\.id) == [move.id])
    #expect(try await f.events.events(includeArchived: true).count == 2)
  }

  @Test("R-EVT-2: delete clears the event from its transactions; active events by date")
  func deleteAndActive() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 10_00, F.groceries, event: F.trip))
    #expect(try await f.events.activeEvents(on: Day("2026-03-10")!).map(\.id) == [F.trip.id])
    #expect(try await f.events.activeEvents(on: Day("2026-03-11")!).isEmpty)
    try await f.events.delete(F.trip.id)
    #expect(try await f.txns.transaction(F.id(100))?.txn.eventID == nil)
    #expect(try await f.events.events(includeArchived: true).isEmpty)
  }
}

@Suite("Categorisation rules")
struct RuleRepositoryTests {
  typealias F = StoreFixture

  @Test("R-IMP-8: rules are stored, ordered, counted and deleted")
  func rules() async throws {
    let f = try F()
    try f.seedBasics()
    let uber = CategoryRule(pattern: "uber", categoryID: F.transport.id, position: 1)
    let zabka = CategoryRule(pattern: "żabka", accountID: F.bank.id, categoryID: F.groceries.id, origin: .imported, position: 0)
    try await f.rules.save(uber)
    try await f.rules.save(zabka)
    #expect(try await f.rules.rules().map(\.id) == [zabka.id, uber.id])
    try await f.rules.recordHit(uber.id)
    try await f.rules.recordHit(uber.id)
    #expect(try await f.rules.rules().last?.hitCount == 2)
    try await f.rules.delete(zabka.id)
    #expect(try await f.rules.rules().map(\.id) == [uber.id])
    await #expect(throws: RepositoryError.notFound) { try await f.rules.recordHit(zabka.id) }
  }
}

@Suite("Settings")
struct SettingsRepositoryTests {
  typealias F = StoreFixture

  @Test("R-SET-3: refunds reduce spending is off by default")
  func refundsDefault() async throws {
    let f = try F()
    #expect(try await f.settings.refundsReduceSpending() == false)
    try await f.settings.set(.refundsReduceSpending, "true")
    #expect(try await f.settings.refundsReduceSpending() == true)
    try await f.settings.set(.refundsReduceSpending, "false")
    #expect(try await f.settings.value(.refundsReduceSpending) == "false")
  }

  @Test("R-SET-1: display currency defaults to UAH and is remembered; rates refresh defaults on")
  func defaults() async throws {
    let f = try F()
    #expect(try await f.settings.displayCurrency() == .UAH)
    #expect(try await f.settings.ratesAutoRefresh())
    try await f.settings.set(.displayCurrency, "PLN")
    #expect(try await f.settings.displayCurrency() == .PLN)
    #expect(try await f.settings.value(.lastAccountID) == nil)
  }
}
