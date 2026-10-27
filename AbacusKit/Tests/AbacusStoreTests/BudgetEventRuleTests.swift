import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Budget plans")
struct BudgetRepositoryTests {
  typealias F = StoreFixture

  @Test("R-BUD-1, D43: a plan has per-category limits, each in its own currency")
  func allocations() async throws {
    let f = try F()
    try f.seedBasics()
    let plan = BudgetPlan(effectiveMonth: "2026-01")
    try await f.budgets.save(plan, allocations: [
      BudgetAllocation(planID: UUID(), categoryID: F.food.id, limitMinor: 2_000_00, currency: .PLN),
      BudgetAllocation(planID: UUID(), categoryID: F.transport.id, limitMinor: 400_00, currency: .EUR),
    ])
    let loaded = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 1)))
    #expect(loaded.plan == plan)
    #expect(loaded.allocations.count == 2)
    #expect(loaded.allocations.allSatisfy { $0.planID == plan.id })
    #expect(Set(loaded.allocations.map(\.limit)) == [
      Money(minorUnits: 2_000_00, currency: .PLN), Money(minorUnits: 400_00, currency: .EUR),
    ])
    // Saving again replaces the allocations.
    try await f.budgets.save(
      plan, allocations: [BudgetAllocation(planID: plan.id, categoryID: F.food.id, limitMinor: 1_000_00, currency: .USD)])
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 1))?.allocations.map(\.limit) == [
      Money(minorUnits: 1_000_00, currency: .USD)
    ])
  }

  @Test("R-BUD-1, D46: the plan's total and its currency round-trip; 0 = no total")
  func total() async throws {
    let f = try F()
    try f.seedBasics()
    let plan = BudgetPlan(effectiveMonth: "2026-01", totalMinor: 15_000_00, currency: .PLN)
    try await f.budgets.save(plan, allocations: [
      BudgetAllocation(planID: plan.id, categoryID: F.food.id, limitMinor: 400_00, currency: .EUR)
    ])
    let loaded = try #require(try await f.budgets.plan(for: Month(year: 2026, month: 3)))
    #expect(loaded.plan.total == Money(minorUnits: 15_000_00, currency: .PLN))
    #expect(loaded.allocations.map(\.limit) == [Money(minorUnits: 400_00, currency: .EUR)])
    let none = BudgetPlan(id: plan.id, effectiveMonth: "2026-01", currency: .EUR)
    try await f.budgets.save(none, allocations: [])
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 1))?.plan.total == nil)
  }

  @Test("R-BUD-3: a plan repeats until changed; a change applies from its month, past months keep theirs")
  func effectiveMonths() async throws {
    let f = try F()
    try f.seedBasics()
    let january = BudgetPlan(effectiveMonth: "2026-01")
    try await f.budgets.save(january, allocations: [])
    #expect(try await f.budgets.plan(for: Month(year: 2025, month: 12)) == nil)
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 6))?.plan.id == january.id)

    let april = BudgetPlan(effectiveMonth: "2026-04")
    try await f.budgets.save(april, allocations: [])
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 3))?.plan.id == january.id)
    #expect(try await f.budgets.plan(for: Month(year: 2026, month: 4))?.plan.id == april.id)
    #expect(try await f.budgets.plan(for: Month(year: 2027, month: 1))?.plan.id == april.id)

    // A second plan for the same month replaces the first.
    let aprilAgain = BudgetPlan(effectiveMonth: "2026-04")
    try await f.budgets.save(aprilAgain, allocations: [])
    #expect(try await f.budgets.plans().map(\.id) == [january.id, aprilAgain.id])
  }

  /// A database file at the v1.0.0 schema (migrations up to v3) with a budget in EUR and one in
  /// PLN, as the owner's database is before installing this build.
  static func preCurrencyDatabase(at url: URL) throws {
    let old = try DatabaseQueue(path: url.path)
    try AbacusDatabase.migrator().migrate(old, upTo: "v3: importBatchID on accounts, categories, events")
    try old.write { db in
      try db.execute(
        sql: """
          INSERT INTO categories (id, name, kind) VALUES ('00000000-0000-0000-0000-000000000010', 'Food', 'expense');
          INSERT INTO categories (id, name, kind) VALUES ('00000000-0000-0000-0000-000000000011', 'Home', 'expense');
          INSERT INTO budgetPlans (id, effectiveMonth, totalMinor, currency) \
          VALUES ('00000000-0000-0000-0000-000000000100', '2026-01', 900000, 'EUR');
          INSERT INTO budgetPlans (id, effectiveMonth, totalMinor, currency) \
          VALUES ('00000000-0000-0000-0000-000000000101', '2026-09', 1000000, 'PLN');
          INSERT INTO budgetAllocations (id, planID, categoryID, limitMinor) VALUES \
          ('00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000010', 40000), \
          ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000010', 180000), \
          ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000011', 574700);
          """)
    }
    try old.close()
  }

  @Test("D43: the v5 migration gives existing limits their plan's currency and keeps everything else")
  func migrationFromPreCurrencySchema() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-v5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "abacus.sqlite")
    try Self.preCurrencyDatabase(at: url)

    // Opening runs the remaining migrations, as the app does on launch.
    let database = try AbacusDatabase.open(at: url)
    let budgets = SQLiteBudgetRepository(database: database)
    let january = try #require(try await budgets.plan(for: Month(year: 2026, month: 5)))
    #expect(january.plan.effectiveMonth == "2026-01")
    #expect(january.allocations.map(\.limit) == [Money(minorUnits: 400_00, currency: .EUR)])
    let september = try #require(try await budgets.plan(for: Month(year: 2026, month: 10)))
    #expect(september.plan.id == F.id(101))
    #expect(september.plan.currency == .PLN)
    #expect(september.plan.total == Money(minorUnits: 10_000_00, currency: .PLN))
    #expect(Set(september.allocations.map(\.limit)) == [
      Money(minorUnits: 1_800_00, currency: .PLN), Money(minorUnits: 5_747_00, currency: .PLN),
    ])
    // The new column is NOT NULL; the app writes and reads it like any other.
    try await budgets.save(
      BudgetPlan(id: F.id(101), effectiveMonth: "2026-09"),
      allocations: [BudgetAllocation(planID: F.id(101), categoryID: F.id(10), limitMinor: 400_00, currency: .EUR)])
    #expect(try await budgets.plan(for: Month(year: 2026, month: 10))?.allocations.map(\.limit) == [
      Money(minorUnits: 400_00, currency: .EUR)
    ])
    // Migrating again is a no-op.
    try AbacusDatabase.migrator().migrate(database)
    #expect(try await budgets.plans().count == 2)
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
