import AbacusDomain
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// N5d: the Forecast tab's model (R-REC-13…15, R-REC-19, R-REC-20) over an in-memory database.
/// Synthetic data only.
private enum FC {
  static let today = Day("2026-11-10")!
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }
  static let format = DashboardFormat(locale: Locale(identifier: "en_GB"), calendar: calendar)

  static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
  static let opened = Day("2026-01-01")!.date(calendar: calendar)
  static let main = Account(
    id: id(1), name: "Main account", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00, openingDate: opened)
  static let savings = Account(
    id: id(2), name: "Savings", currency: .PLN, kind: .savings, openingBalanceMinor: 5_000_00, openingDate: opened,
    position: 1)
  static let euro = Account(
    id: id(3), name: "Euro account", currency: .EUR, kind: .bank, openingBalanceMinor: 100_00, openingDate: opened,
    position: 2)
  static let rent = ScheduledItem(
    id: id(10), type: .expense, accountID: main.id, amountMinor: 800_00, payee: "Rent", unit: .month,
    startDay: "2026-10-15")
  static let salary = ScheduledItem(
    id: id(11), type: .income, accountID: main.id, amountMinor: 1_000_00, payee: "Salary", unit: .month,
    startDay: "2027-01-05")

  /// 1 PLN = 10 UAH, 1 EUR = 40 UAH (so 1 EUR = 4 PLN).
  struct Rates: CurrencyConverter {
    let toUAH: [Currency: Decimal] = [.UAH: 1, .PLN: 10, .EUR: 40, .USD: 37]
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? { latestRate(from: from, to: to) }
    func latestRate(from: Currency, to: Currency) -> Decimal? {
      guard let a = toUAH[from], let b = toUAH[to] else { return nil }
      return a / b
    }
    var latestDay: Day? { Day("2026-11-09") }
  }

}

@MainActor
@Suite("N5d Forecast tab")
struct ForecastModelTests {
  struct Fixture {
    let database: any DatabaseWriter
    let dependencies: ForecastDependencies

    @MainActor
    func model(_ currency: Currency = .PLN) async -> ForecastModel {
      let model = ForecastModel(dependencies: dependencies, displayCurrency: currency)
      await model.load()
      return model
    }
  }

  func fixture(items: [ScheduledItem] = [FC.rent, FC.salary]) throws -> Fixture {
    let database = try AbacusDatabase.open(at: nil)
    try database.write { db in
      for account in [FC.main, FC.savings, FC.euro] { try Account.insert { account }.execute(db) }
      for item in items { try ScheduledItem.insert { item }.execute(db) }
    }
    let dependencies = ForecastDependencies.database(
      database, rates: { FC.Rates() }, today: { FC.today }, format: FC.format)
    return Fixture(database: database, dependencies: dependencies)
  }

  // MARK: R-REC-14

  @Test("R-REC-14: horizon 30/60/90, default 90 or the forecastHorizonDays setting")
  func horizon() async throws {
    let f = try fixture()
    let model = await f.model()
    #expect(model.phase == .loaded)
    #expect(model.horizonDays == 90)
    #expect(model.projection?.points.count == 91)
    #expect(model.projection?.end?.day == FC.today.plusDays(90))
    model.horizonDays = 30
    #expect(model.projection?.points.count == 31)

    try await SQLiteSettingsRepository(database: f.database).set(.forecastHorizonDays, "60")
    let fromSetting = await f.model()
    #expect(fromSetting.horizonDays == 60)
    #expect(fromSetting.projection?.points.count == 61)
  }

  @Test("R-REC-14, R-REC-13: net worth in the display currency at today's rates; an account in its own currency")
  func seriesSelection() async throws {
    let f = try fixture()
    let model = await f.model(.PLN)
    // 1 000 + 5 000 + 100 EUR × 4.
    #expect(model.projection?.currency == .PLN)
    #expect(model.projection?.now?.valueMinor == 6_400_00)
    let afterRent = model.projection?.points.first { $0.day == Day("2026-11-15")! }
    #expect(afterRent?.valueMinor == 5_600_00)
    #expect(model.seriesChoices.map(\.title) == ["Net worth (PLN)", "Main account (PLN)", "Savings (PLN)", "Euro account (EUR)"])

    model.displayCurrency = .EUR
    #expect(model.projection?.now?.valueMinor == 1_600_00)

    model.series = .account(FC.euro.id)
    #expect(model.seriesCurrency == .EUR)
    #expect(model.projection?.points.allSatisfy { $0.valueMinor == 100_00 } == true)
    model.series = .account(FC.main.id)
    #expect(model.seriesCurrency == .PLN)
    #expect(model.projection?.now?.valueMinor == 1_000_00)
    #expect(model.projection?.lowest?.valueMinor == -600_00)
  }

  // MARK: R-REC-15

  @Test("R-REC-15: first day below zero per account with the causing item, lowest point and recovery")
  func warnings() async throws {
    let f = try fixture()
    let model = await f.model()
    let warning = try #require(model.warnings.first)
    #expect(model.warnings.count == 1)
    #expect(warning.accountID == FC.main.id)
    #expect(warning.day == Day("2026-12-15")!)
    #expect(warning.balanceMinor == -600_00)
    #expect(warning.lowestMinor == -600_00)
    #expect(warning.backAboveZero == Day("2027-01-05")!)
    #expect(warning.causes.map(\.name) == ["Rent"])
    let text = model.text(warning)
    #expect(text.hasPrefix("Main account goes below 0 on 15 Dec"))
    #expect(text.contains("back above 0 on 5 Jan"))
    #expect(text.hasSuffix("after “Rent”."))
    // Net worth's lowest point stays positive; no warning for savings.
    #expect((model.projection?.lowest?.valueMinor ?? 0) > 0)
  }

  // MARK: R-REC-13 debts

  @Test("R-REC-13: debts counted in net worth are added at today's value; others are not")
  func debtsInNetWorth() async throws {
    let f = try fixture()
    let counted = Debt(id: FC.id(20), personName: "Sample Person", countsInNetWorth: true)
    let ignored = Debt(id: FC.id(21), personName: "Other Person", countsInNetWorth: false)
    try await f.database.write { db in
      try Debt.insert { counted }.execute(db)
      try Debt.insert { ignored }.execute(db)
      try DebtRecord.insert {
        DebtRecord(debtID: counted.id, kind: .lent, day: "2026-11-01", amountMinor: 50_00, currency: .EUR)
      }.execute(db)
      try DebtRecord.insert {
        DebtRecord(debtID: ignored.id, kind: .lent, day: "2026-11-01", amountMinor: 999_00, currency: .PLN)
      }.execute(db)
      // A record after today does not count yet.
      try DebtRecord.insert {
        DebtRecord(debtID: counted.id, kind: .lent, day: "2026-11-20", amountMinor: 10_00, currency: .EUR)
      }.execute(db)
    }
    let model = await f.model(.PLN)
    // 6 400 + 50 EUR × 4, held flat for the horizon.
    #expect(model.projection?.now?.valueMinor == 6_600_00)
    // Rent ×3 and salary ×2 up to 8 Feb.
    let end: Int64 = 6_600_00 - 3 * 800_00 + 2 * 1_000_00
    #expect(model.projection?.end?.valueMinor == end)
    // An account series never includes debts.
    model.series = .account(FC.main.id)
    #expect(model.projection?.now?.valueMinor == 1_000_00)
  }

  // MARK: R-REC-19 overlay

  @Test("R-REC-19: picking a past forecast draws actual vs that forecast with the gap; none removes it")
  func overlaySelection() async throws {
    let f = try fixture()
    let taken = Day("2026-10-31")!
    let rates = SnapshotRates(asOf: taken, base: .UAH, toBase: [.PLN: 10, .EUR: 40])
    let snapshots = SQLiteForecastSnapshotRepository(database: f.database, calendar: FC.calendar)
    let snapshot = try #require(try await snapshots.takeIfNeeded(today: taken, rates: rates, debts: [:]))
    // Unscheduled spending after the snapshot: the whole gap is "everything else".
    try await f.database.write { db in
      try Txn.insert {
        Txn(
          type: .expense, occurredAt: Day("2026-11-05")!.date(calendar: FC.calendar).addingTimeInterval(43_200),
          accountID: FC.main.id, amountMinor: 30_00, payee: "Groceries")
      }.execute(db)
    }
    let model = await f.model(.PLN)
    #expect(model.overlay == nil)
    #expect(model.snapshots.map(\.id) == [snapshot.id])
    #expect(model.label(model.snapshots[0]).hasPrefix("31 Oct · 10 days ago"))

    await model.selectSnapshot(snapshot.id)
    let overlay = try #require(model.overlay)
    #expect(overlay.currency == .PLN)
    #expect(overlay.gapDay == FC.today)
    #expect(overlay.gapMinor == -30_00)
    #expect(overlay.split == ForecastGapSplit(scheduledMinor: 0, otherMinor: -30_00))
    #expect(overlay.actual.first?.day == taken)
    #expect(overlay.actual.last?.day == FC.today)
    #expect(overlay.forecast.count == 91)
    #expect(model.otherPerDayMinor == -3_00)

    model.series = .account(FC.euro.id)
    #expect(model.overlay?.currency == .EUR)
    #expect(model.overlay?.gapMinor == 0)

    // Reload keeps the chosen snapshot.
    await model.load()
    #expect(model.selectedSnapshotID == snapshot.id)
    #expect(model.overlay != nil)

    await model.selectSnapshot(nil)
    #expect(model.overlay == nil)
    #expect(model.selectedSnapshot == nil)
  }

  // MARK: R-REC-20 accuracy

  @Test("R-REC-20: accuracy per item, scoped to the snapshot or all time; Update amount applies to the item")
  func accuracyApply() async throws {
    let phone = ScheduledItem(
      id: FC.id(12), type: .expense, accountID: FC.main.id, amountMinor: 50_00, payee: "Phone plan", unit: .month,
      startDay: "2026-07-20")
    let f = try fixture(items: [FC.rent, phone])
    try await f.database.write { db in
      for (day, actual, amount) in [
        ("2026-08-20", "2026-08-20", Int64(54_00)), ("2026-09-20", "2026-09-22", 55_00), ("2026-10-20", "2026-10-21", 56_00),
      ] {
        try ScheduledOccurrence.insert {
          ScheduledOccurrence(
            itemID: phone.id, expectedDay: day, expectedAmountMinor: 50_00, status: .paid, actualDay: actual,
            actualAmountMinor: amount, matchKind: .auto)
        }.execute(db)
      }
      try ScheduledOccurrence.insert {
        ScheduledOccurrence(itemID: FC.rent.id, expectedDay: "2026-10-15", expectedAmountMinor: 800_00, status: .missed)
      }.execute(db)
    }
    var changes = 0
    let model = await f.model()
    model.onDataChange = { changes += 1 }
    let accuracy = try #require(model.accuracy)
    #expect(accuracy.overall.paid == 3)
    #expect(accuracy.overall.missed == 1)
    let row = try #require(accuracy.items.first { $0.itemID == phone.id })
    #expect(row.rows.count == 3)
    #expect(row.suggestedAmountMinor == 56_00)
    #expect(model.averageDayShift(row.rows) == 1)
    #expect(model.currency(of: row.item) == .PLN)

    // Scope: since a snapshot of 2026-10-01 only holds October's rows.
    let snapshots = SQLiteForecastSnapshotRepository(database: f.database, calendar: FC.calendar)
    let rates = SnapshotRates(asOf: nil, base: .UAH, toBase: [.PLN: 10, .EUR: 40])
    let snapshot = try #require(try await snapshots.takeIfNeeded(today: Day("2026-10-01")!, rates: rates, debts: [:]))
    await model.load()
    await model.selectSnapshot(snapshot.id)
    #expect(model.accuracyScope == .sinceSnapshot)
    #expect(model.accuracy?.items.first { $0.itemID == phone.id }?.rows.count == 1)
    model.accuracyScope = .allTime
    #expect(model.accuracy?.items.first { $0.itemID == phone.id }?.rows.count == 3)

    model.toggleExpanded(phone.id)
    #expect(model.expandedItems == [phone.id])

    await model.applySuggestion(itemID: phone.id)
    #expect(model.actionError == nil)
    #expect(changes == 1)
    let saved = try await SQLiteScheduledStore(database: f.database).item(phone.id)
    #expect(saved?.amountMinor == 56_00)
    // Past occurrences keep what they were expected with; the suggestion is gone.
    #expect(model.occurrences.filter { $0.itemID == phone.id }.allSatisfy { $0.expectedAmountMinor == 50_00 })
    #expect(model.accuracy?.items.first { $0.itemID == phone.id }?.suggestedAmountMinor == nil)
  }

  @Test("R-REC-15: the day's detail names the scheduled items of that day")
  func detail() async throws {
    let f = try fixture()
    let model = await f.model()
    let text = model.detail(for: Day("2026-11-15")!)
    #expect(text.contains("15 Nov"))
    #expect(text.contains("forecast"))
    #expect(text.hasSuffix("scheduled: Rent"))
  }
}
