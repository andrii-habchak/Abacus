import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@MainActor
@Suite("Exchange rates screen (B1)")
struct RatesModelTests {
  func model(_ setup: B1Fixture.Setup) -> RatesModel {
    let env = setup.environment
    return RatesModel(store: env.rateStore, service: env.rates, today: env.today, now: env.now, formats: env.formats)
  }

  @Test("R-FX-5 rows read “1 X = r Y” with day change and source badge")
  func rows() async throws {
    let m = model(B1Fixture.setup())
    await m.load()
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(eur.rateText == "1 EUR = 48.5000 UAH")
    #expect(eur.changeText == "▲ 0.21%")
    #expect(eur.trend == .up)
    #expect(eur.badge == "NBU" && !eur.isManual)
    #expect(eur.series.count == 6)
  }

  @Test("R-FX-5 a change that rounds to 0.00% is flat, not up or down")
  func flatChange() async throws {
    let rates = B1Fixture.rates + [B1Fixture.rate("2026-10-21", .EUR, "48.5001")]
    let store = InMemoryRateStore(rates: rates)
    let service = PreviewRatesService(store: store, status: RatesStatus())
    let m = RatesModel(
      store: store, service: service, today: { B1Fixture.today }, now: { B1Fixture.at(15) },
      formats: B1Fixture.formats)
    await m.load()
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(eur.changeText == "0.00%")
    #expect(eur.trend == .flat)
  }

  @Test("R-FX-5 Show in switches the base of every row")
  func showIn() async {
    let m = model(B1Fixture.setup())
    await m.load()
    m.showIn = .PLN
    #expect(m.rows.map(\.currency) == [.UAH, .EUR, .USD])
    #expect(m.rows.first { $0.currency == .EUR }?.rateText == "1 EUR = 4.2920 PLN")
  }

  @Test("R-FX-5 updated label: today, just now, yesterday, never")
  func updatedLabel() async {
    let today = model(B1Fixture.setup(lastUpdate: B1Fixture.at(9), now: B1Fixture.at(15)))
    await today.load()
    #expect(today.updatedLabel == "Updated today 09:00 · NBU rates for 20 Oct 2026")

    let justNow = model(B1Fixture.setup(lastUpdate: B1Fixture.at(15), now: B1Fixture.at(15)))
    await justNow.load()
    #expect(justNow.updatedLabel == "Updated just now · NBU rates for 20 Oct 2026")

    let yesterday = model(B1Fixture.setup(lastUpdate: B1Fixture.at(9, day: 20), now: B1Fixture.at(15)))
    await yesterday.load()
    #expect(yesterday.updatedLabel == "Updated yesterday 09:00 · NBU rates for 20 Oct 2026")

    let never = model(B1Fixture.setup(lastUpdate: nil))
    await never.load()
    #expect(never.updatedLabel == "Not updated yet · NBU rates for 20 Oct 2026")
  }

  @Test("R-FX-1 Refresh rates fetches on demand and updates the label")
  func refresh() async {
    let setup = B1Fixture.setup(lastUpdate: B1Fixture.at(9), now: B1Fixture.at(15))
    let m = model(setup)
    await m.load()
    #expect(m.refreshLabel == "Refresh rates")
    await m.refresh()
    #expect(await setup.service.refreshCount == 1)
    #expect(m.updatedLabel.hasPrefix("Updated just now"))
    #expect(!m.isRefreshing)
    #expect(m.offlineMessage == nil)
  }

  @Test("R-FX-4 a failed fetch shows the banner with the last known day; Try again clears it")
  func offline() async {
    let setup = B1Fixture.setup(offline: true)
    let m = model(setup)
    await m.load()
    #expect(m.offlineMessage == "Couldn't reach the rate service. Amounts use the last known rates, from 20 Oct 2026.")
    #expect(!m.rows.isEmpty)  // last known rates are still shown
    await setup.service.setOffline(false)
    await m.refresh()
    #expect(m.offlineMessage == nil)
  }

  @Test("R-FX-4 the shell hears every status change")
  func statusCallback() async {
    let m = model(B1Fixture.setup())
    var heard: [RatesStatus] = []
    m.onStatusChange = { heard.append($0) }
    await m.load()
    await m.refresh()
    #expect(heard.count == 2)
    #expect(heard.last?.latestDay == Day("2026-10-20"))
  }

  @Test("R-FX-2 manual rates list: pair, one day / from a day, note, remove label")
  func overrideRows() async {
    let setup = B1Fixture.setup(overrides: [
      B1Fixture.override(.EUR, .UAH, "48.2", from: "2026-10-15", until: "2026-10-15", note: "Hotel"),
      B1Fixture.override(.USD, .PLN, "3.9123", from: "2026-10-01"),
    ])
    let m = model(setup)
    await m.load()
    #expect(m.overrideRows.map(\.pair) == ["1 EUR = 48.20 UAH", "1 USD = 3.9123 PLN"])
    #expect(m.overrideRows.map(\.applies) == ["Manual · on 15 Oct 2026 only", "Manual · from 1 Oct 2026 until changed"])
    #expect(m.overrideRows[0].note == "Hotel")
    #expect(m.overrideRows[0].removeLabel == "Remove manual rate EUR/UAH")
  }

  @Test("R-FX-2 the add form prefills the fetched rate and validates")
  func formValidation() async {
    let m = model(B1Fixture.setup())
    await m.load()
    #expect(m.formRateText == "48.5000")
    #expect(m.fetchedHint == "fetched: 48.5000")
    #expect(m.canAddOverride)
    m.formTo = .EUR
    #expect(m.formError == "Pick two different currencies.")
    #expect(!m.canAddOverride)
    m.formTo = .USD
    m.formRateText = "abc"
    #expect(m.formError == "Enter a rate above zero.")
    m.formRateText = "0"
    #expect(!m.canAddOverride)
    m.formRateText = "1,1659"
    #expect(m.formError == nil)
    #expect(m.canAddOverride)
  }

  @Test("R-FX-2 adding “on one day” stores fromDay = untilDay")
  func addOneDay() async throws {
    let setup = B1Fixture.setup()
    let m = model(setup)
    await m.load()
    m.formOneDay = Day("2026-10-15")!
    m.formRateText = "48.20"
    m.formNote = " Rate my bank charged "
    #expect(await m.addOverride())
    let saved = try #require(await setup.store.manual.first)
    #expect(saved.base == .EUR && saved.quote == .UAH)
    #expect(saved.rateE8 == RateScale.scaled(Decimal(string: "48.20")!))
    #expect(saved.fromDay == "2026-10-15")
    #expect(saved.untilDay == "2026-10-15")
    #expect(saved.note == "Rate my bank charged")
    #expect(m.overrideRows.count == 1)
    #expect(m.formNote.isEmpty)
  }

  @Test("R-FX-2 adding “from a day until changed” leaves untilDay empty and wins today")
  func addFromDay() async throws {
    let setup = B1Fixture.setup()
    let m = model(setup)
    await m.load()
    m.formMode = .fromDay
    m.formFromDay = Day("2026-10-01")!
    m.formRateText = "49"
    #expect(await m.addOverride())
    let saved = try #require(await setup.store.manual.first)
    #expect(saved.fromDay == "2026-10-01")
    #expect(saved.untilDay == nil)
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(eur.isManual == true)
    #expect(eur.rateText == "1 EUR = 49.0000 UAH")
  }

  @Test("R-FX-2 removing a manual rate falls back to the fetched one")
  func remove() async throws {
    let manual = B1Fixture.override(.EUR, .UAH, "49", from: "2026-10-01")
    let setup = B1Fixture.setup(overrides: [manual])
    let m = model(setup)
    await m.load()
    #expect(m.rows.first { $0.currency == .EUR }?.isManual == true)
    await m.removeOverride(manual.id)
    #expect(m.overrideRows.isEmpty)
    #expect(await setup.store.manual.isEmpty)
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(eur.badge == "NBU" && !eur.isManual)
    #expect(eur.rateText == "1 EUR = 48.5000 UAH")
  }

  @Test("R-FX-5 a day without rates uses the last published one; cross rates go through UAH")
  func crossRates() async {
    let m = model(B1Fixture.setup())
    await m.load()
    m.showIn = .EUR
    #expect(m.rows.map(\.currency) == [.UAH, .PLN, .USD])
    #expect(m.rows.first { $0.currency == .PLN }?.rateText == "1 PLN = 0.2330 EUR")
    #expect(m.rows.first { $0.currency == .UAH }?.rateText == "1 UAH = 0.0206 EUR")
  }

  @Test("R-FX-5 the 30-day series has a point per calendar day from the first known rate")
  func seriesPoints() async throws {
    let m = model(B1Fixture.setup())
    await m.load()
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(eur.series.map(\.day.string) == ["2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21"])
    #expect(eur.series[1].rate == Decimal(string: "48.00"))  // Saturday repeats Friday
  }

  @Test("R-FX-2 a one-day manual rate does not touch other days; inverse and UAH legs count")
  func manualScope() async throws {
    let past = B1Fixture.override(.EUR, .UAH, "48.20", from: "2026-10-19", until: "2026-10-19")
    let inverse = B1Fixture.override(.UAH, .USD, "0.025", from: "2026-10-01")
    let m = model(B1Fixture.setup(overrides: [past, inverse]))
    await m.load()
    let eur = try #require(m.rows.first { $0.currency == .EUR })
    #expect(!eur.isManual)
    #expect(eur.rateText == "1 EUR = 48.5000 UAH")
    let usd = try #require(m.rows.first { $0.currency == .USD })
    #expect(usd.isManual && usd.badge == "Manual")
    #expect(usd.rateText == "1 USD = 40.0000 UAH")
    // The UAH leg of USD is manual, so USD shown in PLN is manual too.
    m.showIn = .PLN
    #expect(m.rows.first { $0.currency == .USD }?.isManual == true)
  }

  @Test("R-FX-2 the fetched-rate hint ignores manual rates")
  func fetchedHintIgnoresManual() async {
    let m = model(B1Fixture.setup(overrides: [B1Fixture.override(.EUR, .UAH, "49", from: "2026-10-01")]))
    await m.load()
    #expect(m.fetchedHint == "fetched: 48.5000")
  }
}
