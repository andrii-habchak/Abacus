import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// N5c: forecast snapshots (R-REC-17, R-REC-18). Synthetic data only.
@Suite("Forecast snapshots")
struct ForecastSnapshotTests {
  typealias F = StoreFixture
  static let today = Day("2026-11-10")!
  static let rates = SnapshotRates(asOf: Day("2026-11-09"), base: .UAH, toBase: [.PLN: 10, .EUR: 45])

  static let rent = ScheduledItem(
    id: F.id(100), type: .expense, accountID: F.bank.id, amountMinor: 300_00, payee: "Rent", unit: .month,
    startDay: "2026-10-15")
  static let salary = ScheduledItem(
    id: F.id(101), type: .income, accountID: F.bank.id, amountMinor: 1_000_00, payee: "Salary", unit: .month,
    startDay: "2026-11-25")
  static let saving = ScheduledItem(
    id: F.id(102), type: .transfer, accountID: F.bank.id, toAccountID: F.card.id, amountMinor: 100_00,
    toAmountMinor: 22_00, payee: "Saving", unit: .month, startDay: "2026-11-20")

  func fixture(items: [ScheduledItem] = [rent, salary, saving]) async throws -> StoreFixture {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(200, "2026-11-01", 50_00, F.groceries))
    try await f.database.write { db in
      for item in items { try ScheduledItem.insert { item }.execute(db) }
    }
    return f
  }

  func repository(_ f: StoreFixture) -> SQLiteForecastSnapshotRepository {
    SQLiteForecastSnapshotRepository(database: f.database, calendar: F.calendar)
  }

  @Test("R-REC-17: one snapshot per day; the second call is a no-op")
  func oncePerDay() async throws {
    let f = try await fixture()
    let repo = repository(f)
    let first = try await repo.takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:])
    #expect(first != nil)
    let second = try await repo.takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:])
    #expect(second == nil)
    #expect(try await f.database.read { try ForecastSnapshot.fetchCount($0) } == 1)
    let next = try await repo.takeIfNeeded(today: Self.today.plusDays(1), rates: Self.rates, debts: [:])
    #expect(next?.takenDay == "2026-11-11")
    #expect(try await repo.snapshots().map(\.takenDay.string) == ["2026-11-11", "2026-11-10"])
  }

  @Test("R-REC-17: no snapshot without an active item (paused or ended items do not count)")
  func noActiveItem() async throws {
    var paused = Self.rent
    paused.status = .paused
    var ended = Self.salary
    ended.status = .ended
    let f = try await fixture(items: [paused, ended])
    #expect(try await repository(f).takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:]) == nil)
    let empty = try await fixture(items: [])
    #expect(try await repository(empty).takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:]) == nil)
    #expect(try await repository(empty).snapshots().isEmpty)
  }

  @Test("R-REC-17: start balances, rates and items equal the forecast at that moment; horizon from the setting")
  func contentEqualsForecast() async throws {
    let f = try await fixture()
    let repo = repository(f)
    let taken = try #require(try await repo.takeIfNeeded(today: Self.today, rates: Self.rates, debts: [.EUR: 5_00]))
    let content = try #require(try await repo.snapshot(taken.id))
    #expect(content.snapshot.horizonDays == 90)
    #expect(content.rates == Self.rates)
    #expect(content.start.debts == [.EUR: 5_00])

    let accounts = try await f.accounts.accounts(includeArchived: true)
    let balances = try await f.accounts.balances(asOf: Self.today)
    let forecast = ForecastEngine.run(
      accounts: accounts, balances: balances, items: [Self.rent, Self.salary, Self.saving], today: Self.today)
    #expect(Set(content.start.accounts.map(\.accountID)) == Set(forecast.accounts.map(\.id)))
    for account in content.start.accounts {
      #expect(account.balanceMinor == balances[account.accountID])
    }
    #expect(content.start.balance(of: F.bank.id)?.balanceMinor == 950_00)
    #expect(content.start.balance(of: F.loan.id)?.isLiability == true)
    #expect(content.items.count == forecast.occurrences.count)
    // Rent on 2026-10-15 is past grace (missed), 2026-11-15 onwards expected.
    let rentDays = content.items.filter { $0.itemID == Self.rent.id }.map(\.day)
    #expect(rentDays == ["2026-11-15", "2026-12-15", "2027-01-15"])  // horizon ends 2027-02-08
    let transfer = try #require(content.items.first { $0.itemID == Self.saving.id })
    #expect(transfer.accountID == F.bank.id && transfer.amountMinor == -100_00)
    #expect(transfer.toAccountID == F.card.id && transfer.toAmountMinor == 22_00)
    // The end balances of the picker equal the forecast's last day.
    let summary = try #require(try await repo.snapshots().first)
    for account in forecast.accounts {
      #expect(summary.endBalances[account.id] == forecast.balances[account.id]?.last)
    }
    #expect(summary.endNetWorth(in: .UAH) != nil)

    let g = try await fixture()
    try await g.settings.set(.forecastHorizonDays, "30")
    let short = try #require(try await repository(g).takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:]))
    #expect(short.horizonDays == 30)
    let shortItems = try #require(try await repository(g).snapshot(short.id)).items
    #expect(shortItems.allSatisfy { $0.day <= "2026-12-10" })
  }

  @Test("R-REC-17: resolved occurrences (matching ran first) are not in the snapshot; overdue ones are")
  func resolvedLeftOut() async throws {
    let f = try await fixture()
    try await f.database.write { db in
      try ScheduledOccurrence.insert {
        ScheduledOccurrence(itemID: Self.rent.id, expectedDay: "2026-11-15", expectedAmountMinor: 300_00, status: .paid)
      }.execute(db)
    }
    let repo = repository(f)
    let taken = try #require(try await repo.takeIfNeeded(today: Day("2026-11-18")!, rates: Self.rates, debts: [:]))
    let items = try #require(try await repo.snapshot(taken.id)).items
    #expect(!items.contains { $0.itemID == Self.rent.id && $0.day == "2026-11-15" })
    // The transfer of 2026-11-20 is still expected; salary of 2026-11-25 too.
    #expect(items.contains { $0.itemID == Self.saving.id && $0.day == "2026-11-20" })

    let g = try await fixture()
    let overdue = try #require(try await repository(g).takeIfNeeded(today: Day("2026-11-18")!, rates: Self.rates, debts: [:]))
    let overdueItems = try #require(try await repository(g).snapshot(overdue.id)).items
    #expect(overdueItems.contains { $0.itemID == Self.rent.id && $0.day == "2026-11-15" })
  }

  @Test("R-REC-17: a sync-style duplicate for one day resolves to the newest createdAt on read")
  func duplicateResolvesToNewest() async throws {
    let f = try await fixture()
    let start = try SnapshotJSON.encode(SnapshotStartBalances(accounts: []))
    let rates = try SnapshotJSON.encode(Self.rates)
    let older = ForecastSnapshot(
      id: F.id(500), takenDay: "2026-11-05", startBalancesJSON: start, ratesJSON: rates,
      createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = ForecastSnapshot(
      id: F.id(501), takenDay: "2026-11-05", startBalancesJSON: start, ratesJSON: rates,
      createdAt: Date(timeIntervalSince1970: 2_000))
    try await f.database.write { db in
      try ForecastSnapshot.insert { [newer, older] }.execute(db)
      try ForecastSnapshotItem.insert {
        ForecastSnapshotItem(snapshotID: older.id, day: "2026-11-06", accountID: F.bank.id, amountMinor: -1)
      }.execute(db)
    }
    let repo = repository(f)
    #expect(try await repo.snapshots().map(\.id) == [newer.id])
    #expect(try await repo.snapshot(takenOn: Day("2026-11-05")!)?.snapshot.id == newer.id)
    // Pruning removes the loser and its items.
    #expect(try await repo.prune(today: Self.today) == 1)
    #expect(try await f.database.read { try ForecastSnapshot.fetchCount($0) } == 1)
    #expect(try await f.database.read { try ForecastSnapshotItem.fetchCount($0) } == 0)
  }

  @Test("R-REC-18: retention with a fake clock: 120 daily, then weekly to 2 years, older gone; items deleted with the header")
  func retention() async throws {
    let f = try await fixture()
    let repo = repository(f)
    // A snapshot every day for 800 days, taken by a fake clock.
    let first = Self.today.plusDays(-800)
    for offset in 0...800 {
      try await repo.takeIfNeeded(today: first.plusDays(offset), rates: Self.rates, debts: [:])
    }
    let days = try await repo.snapshots().map(\.takenDay)
    let ages = days.map { $0.daysUntil(Self.today) }
    #expect(Set(ages.filter { $0 < 120 }) == Set(0..<120))
    #expect(ages.allSatisfy { $0 <= 730 })
    let old = days.filter { $0.daysUntil(Self.today) >= 120 }
    // One per ISO week (Mondays, the first of each week, since every day had one), weeks apart.
    let mondays = old.filter { $0.daysUntil(Self.today) <= 730 - 7 }
    #expect(mondays.allSatisfy { ForecastSnapshotRetention.keep([$0, $0.plusDays(1)], today: Self.today).contains($0) })
    #expect(zip(old, old.dropFirst()).allSatisfy { $0.0.daysUntil($0.1) == -7 })
    #expect(old.count >= 86 && old.count <= 88)
    // Items of deleted headers are gone too.
    let headerIDs = try await f.database.read { db in Set(try ForecastSnapshot.all.fetchAll(db).map(\.id)) }
    let itemSnapshotIDs = try await f.database.read { db in Set(try ForecastSnapshotItem.all.fetchAll(db).map(\.snapshotID)) }
    #expect(itemSnapshotIDs.isSubset(of: headerIDs))
    #expect(headerIDs.count == days.count)
  }

  @Test("R-REC-19: overlay from a stored snapshot; actual from daily balances equals the balance calculator")
  func overlayFromStore() async throws {
    let f = try await fixture()
    let repo = repository(f)
    let taken = try #require(try await repo.takeIfNeeded(today: Self.today, rates: Self.rates, debts: [:]))
    // After the snapshot: rent paid 310.00 on 11-16 (matched), groceries 20.00 on 11-17.
    try await f.insert(F.expense(201, "2026-11-16", 310_00, nil, payee: "Rent"))
    try await f.insert(F.expense(202, "2026-11-17", 20_00, F.groceries))
    let occurrence = ScheduledOccurrence(
      itemID: Self.rent.id, expectedDay: "2026-11-15", expectedAmountMinor: 300_00, status: .paid, txnID: F.id(201),
      actualDay: "2026-11-16", actualAmountMinor: 310_00, matchKind: .auto)
    try await f.database.write { db in try ScheduledOccurrence.insert { occurrence }.execute(db) }
    let today = Day("2026-11-18")!
    let days = (0...Self.today.daysUntil(today)).map { Self.today.plusDays($0) }
    let series = try await f.reports.balances(on: days)
    let actual = ActualDailyBalances(
      days: series.days, currencies: Dictionary(uniqueKeysWithValues: series.accounts.map { ($0.id, $0.currency) }),
      balances: series.balances)
    let content = try #require(try await repo.snapshot(taken.id))
    let overlay = try #require(ForecastOverlay.make(
      snapshot: content, actual: actual, occurrences: [occurrence], selection: .account(F.bank.id), today: today))
    for point in overlay.actual {
      #expect(point.valueMinor == (try await f.accounts.balances(asOf: point.day))[F.bank.id])
    }
    // Forecast 950 − 300 (rent 11-15); actual 950 − 310 − 20.
    #expect(overlay.forecastAtGap == 650_00)
    #expect(overlay.actualAtGap == 620_00)
    #expect(overlay.split == ForecastGapSplit(scheduledMinor: -10_00, otherMinor: -20_00))
    let worth = try #require(ForecastOverlay.make(
      snapshot: content, actual: actual, occurrences: [occurrence], selection: .netWorth(.PLN), today: today))
    #expect(worth.gapMinor == -30_00)
    #expect(worth.split?.scheduledMinor == -10_00)
  }
}
