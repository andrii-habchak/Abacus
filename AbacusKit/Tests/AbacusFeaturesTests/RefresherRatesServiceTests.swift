import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Testing

/// An official source that is always unreachable, or answers with fixed rates.
struct StubSource: OfficialRateSource {
  var name = "NBU"
  var rates: [FXRate]?

  func uahRates(for currencies: [Currency], from: Day, to: Day) async throws -> [FXRate] {
    guard let rates else { throw FXError.transport("offline") }
    return rates.filter { $0.day >= from.string && $0.day <= to.string }
  }
}

@MainActor
@Suite("Rates screen over the real refresher (B1)")
struct RefresherRatesServiceTests {
  func model(source: StubSource, overrides: [FXOverride] = []) -> (RatesModel, InMemoryRateStore) {
    let store = InMemoryRateStore(rates: B1Fixture.rates, overrides: overrides)
    let now = B1Fixture.at(15)
    let refresher = RateRefresher(store: store, source: source, calendar: B1Fixture.calendar, now: { now })
    let model = RatesModel(
      store: store, service: RefresherRatesService(refresher: refresher), today: { B1Fixture.today },
      now: { now }, formats: B1Fixture.formats)
    return (model, store)
  }

  @Test("R-FX-4 an unreachable rate service keeps the last known rates and shows the banner")
  func offline() async {
    let (m, _) = model(source: StubSource(rates: nil))
    await m.load()
    await m.refresh()
    #expect(m.offlineMessage == "Couldn't reach the rate service. Amounts use the last known rates, from 20 Oct 2026.")
    #expect(m.rows.first { $0.currency == .EUR }?.rateText == "1 EUR = 48.5000 UAH")
  }

  @Test("R-FX-1 Refresh rates stores the fetched day and updates the screen")
  func refresh() async {
    let today = B1Fixture.rate("2026-10-21", .EUR, "48.80")
    let (m, store) = model(source: StubSource(rates: [today]))
    await m.load()
    await m.refresh()
    #expect(m.offlineMessage == nil)
    #expect(await store.fetched.contains { $0.day == "2026-10-21" && $0.base == .EUR })
    #expect(m.rows.first { $0.currency == .EUR }?.rateText == "1 EUR = 48.8000 UAH")
    #expect(m.updatedLabel == "Updated just now · NBU rates for 21 Oct 2026")
  }

  @Test("R-FX-2 manual rates saved through the refresher reach the store")
  func overrides() async {
    let (m, store) = model(source: StubSource(rates: []))
    await m.load()
    m.formRateText = "49"
    #expect(await m.addOverride())
    #expect(await store.manual.count == 1)
    #expect(m.rows.first { $0.currency == .EUR }?.isManual == true)
    await m.removeOverride(m.overrideRows[0].id)
    #expect(await store.manual.isEmpty)
  }
}
