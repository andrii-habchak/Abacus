import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// Counts the editor's rate requests.
actor RateRequests {
  private(set) var days: [[Day]] = []
  func record(_ days: [Day]) { self.days.append(days) }
}

@MainActor
@Suite("Editor rates for old days (C2)")
struct EditorRatesTests {
  /// Tue 10 Mar 2026: 1 EUR = 45.00 UAH, 1 PLN = 10.50 UAH → 1 EUR = 4.2857 PLN.
  static let march10 = Day(year: 2026, month: 3, day: 10)
  static let marchRates = [
    B1Fixture.rate("2026-03-10", .EUR, "45.00"), B1Fixture.rate("2026-03-10", .PLN, "10.50"),
    B1Fixture.rate("2026-03-10", .USD, "39.00"),
  ]

  static func noon(_ day: Day) -> Date {
    Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
  }

  struct Harness {
    let model: TransactionEditorModel
    let refresher: RateRefresher
    let requests: RateRequests
  }

  /// An editor whose rates come from a refresher holding only October rates; the source knows
  /// March too.
  func harness(
    autoRefresh: Bool = true, settings: [SettingKey: String] = TransactionEditorDependencies.previewSettings
  ) async -> Harness {
    let store = InMemoryRateStore(rates: B1Fixture.rates)
    let refresher = RateRefresher(
      store: store, source: StubSource(rates: Self.marchRates + B1Fixture.rates), autoRefresh: autoRefresh,
      calendar: B1Fixture.calendar, now: { B1Fixture.at(15) })
    await refresher.loadCache()
    let requests = RateRequests()
    var dependencies = TransactionEditorDependencies.preview(settings: settings)
    dependencies.converter = await refresher.table
    dependencies.requestRates = { days in
      await requests.record(days)
      await refresher.ensureRates(for: days)
      return await refresher.table
    }
    let model = TransactionEditorModel(mode: .new, dependencies: dependencies)
    await model.load()
    return Harness(model: model, refresher: refresher, requests: requests)
  }

  @Test("R-EDIT-4, R-FX-1 an old day loads its rate and Charged to account pre-fills")
  func oldDayPrefills() async {
    let h = await harness()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "EUR"
    model.amountText = "10"
    model.occurredAt = Self.noon(Self.march10)
    // Nothing known before October yet.
    #expect(model.chargedText == "")
    await model.waitForRates()
    #expect(model.chargedText == "42.86")
    #expect(model.chargedHint.hasPrefix("Estimated at the NBU rate 1 EUR = 4.2857 PLN."))
    #expect(await h.requests.days.contains([Self.march10]))
  }

  @Test("R-EDIT-4 a charged amount typed by the user is kept when the rate arrives")
  func typedAmountKept() async {
    let h = await harness()
    let model = h.model
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "EUR"
    model.amountText = "10"
    model.chargedText = "43.00"
    model.occurredAt = Self.noon(Self.march10)
    await model.waitForRates()
    #expect(model.chargedText == "43.00")
    #expect(model.estimatedChargedMinor == 42_86)
  }

  @Test("R-FX-1, D25 with automatic updates off nothing is fetched; the day waits for Refresh rates")
  func autoRefreshOff() async {
    let h = await harness(autoRefresh: false)
    let model = h.model
    model.occurredAt = Self.noon(Self.march10)
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "EUR"
    model.amountText = "10"
    await model.waitForRates()
    #expect(model.chargedText == "")
    #expect(await h.refresher.status.pendingDays == 1)
  }

  @Test("D24 currencies without rates and same-currency amounts ask for nothing")
  func noRequestOutsideRateCurrencies() async {
    // Starts in PLN on PKO Personal: nothing foreign, nothing asked.
    let h = await harness(settings: [.lastTxnCurrency: "PLN", .lastAccountID: PreviewData.pkoPersonal.id.uuidString])
    let model = h.model
    model.occurredAt = Self.noon(Self.march10)
    model.currencyCode = "HUF"
    model.amountText = "3990"
    await model.waitForRates()
    #expect(await h.requests.days.isEmpty)
    #expect(model.chargedText == "")
    // Each day is asked for once.
    model.currencyCode = "EUR"
    model.currencyCode = "USD"
    await model.waitForRates()
    #expect(await h.requests.days == [[Self.march10]])
  }

  @Test("R-EDIT-4, R-FX-1 the live session's editor asks the app's refresher")
  func liveSession() async throws {
    let database = try AbacusDatabase.open(at: nil)
    try await SQLiteRateStore(database: database).save(B1Fixture.rates)
    let s = AppSession.live(
      database: database, source: StubSource(rates: Self.marchRates), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats)
    await s.start()
    defer { s.stop() }
    await s.waitForLaunchFetch()
    await s.loadSampleData()
    let model = TransactionEditorModel(mode: .new, dependencies: s.editorDependencies)
    await model.load()
    model.accountID = PreviewData.pkoPersonal.id
    model.currencyCode = "EUR"
    model.amountText = "10"
    model.occurredAt = Self.noon(Self.march10)
    await model.waitForRates()
    #expect(model.chargedText == "42.86")
    let stored = try await SQLiteRateStore(database: database).rates(from: Self.march10, to: Self.march10)
    #expect(stored.count == 3)
  }
}
