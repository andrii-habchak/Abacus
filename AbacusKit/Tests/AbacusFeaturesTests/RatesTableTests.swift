import AbacusDomain
import AbacusFeatures
import Foundation
import Testing

@Suite("Rates table (B1)")
struct RatesTableTests {
  let today = B1Fixture.today

  func table(_ overrides: [FXOverride] = []) -> RatesTable {
    RatesTable(rates: B1Fixture.rates, overrides: overrides)
  }

  func decimal(_ text: String) -> Decimal { Decimal(string: text)! }

  func rounded(_ value: Decimal, _ places: Int = 4) -> Decimal {
    var input = value
    var output = Decimal()
    NSDecimalRound(&output, &input, places, .plain)
    return output
  }

  @Test("R-FX-5 rows list every currency except the Show in one")
  func rowsExceptShowIn() {
    #expect(table().rows(showIn: .UAH, on: today).map(\.currency) == [.PLN, .EUR, .USD])
    #expect(table().rows(showIn: .EUR, on: today).map(\.currency) == [.UAH, .PLN, .USD])
  }

  @Test("R-FX-5 a day without rates uses the last published one; cross rates go through UAH")
  func crossRates() throws {
    let rows = table().rows(showIn: .EUR, on: today)
    let pln = try #require(rows.first { $0.currency == .PLN })
    #expect(rounded(pln.rate) == decimal("0.2330"))  // 11.30 / 48.50
    let uah = try #require(rows.first { $0.currency == .UAH })
    #expect(rounded(uah.rate) == decimal("0.0206"))
    #expect(table().officialDay(onOrBefore: today) == Day("2026-10-20"))
  }

  @Test("R-FX-5 day change compares with the previous official day")
  func dayChange() throws {
    let eur = try #require(table().rows(showIn: .UAH, on: today).first { $0.currency == .EUR })
    // (48.50 − 48.40) / 48.40 = +0.2066 %
    #expect(rounded(try #require(eur.changePercent), 4) == decimal("0.2066"))
    // On Monday the previous official day is Friday.
    let monday = try #require(table().changePercent(from: .PLN, to: .UAH, on: Day("2026-10-19")!))
    #expect(rounded(monday, 4) == decimal("1.8182"))
  }

  @Test("R-FX-5 30-day series has one point per calendar day from the first known rate")
  func series() {
    let points = table().series(from: .EUR, to: .UAH, endingOn: today, days: 30)
    #expect(points.map(\.day.string) == ["2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21"])
    #expect(points[1].rate == decimal("48.00"))  // Saturday repeats Friday
  }

  @Test("R-FX-2 a manual rate wins for its days and marks the row Manual")
  func manualWins() throws {
    let manual = B1Fixture.override(.EUR, .UAH, "49.00", from: "2026-10-21")
    let rows = table([manual]).rows(showIn: .UAH, on: today)
    let eur = try #require(rows.first { $0.currency == .EUR })
    #expect(eur.rate == decimal("49.00"))
    #expect(eur.source == .manual)
    #expect(rows.first { $0.currency == .PLN }?.source == .nbu)
    // Against UAH, so cross rates through UAH use it too.
    let pln = try #require(table([manual]).rows(showIn: .EUR, on: today).first { $0.currency == .PLN })
    #expect(pln.source == .manual)
  }

  @Test("R-FX-2 one-day manual rates apply on that day only; inverse pairs count")
  func manualScope() throws {
    let oneDay = B1Fixture.override(.EUR, .UAH, "48.20", from: "2026-10-19", until: "2026-10-19")
    let t = table([oneDay])
    #expect(t.quote(from: .EUR, to: .UAH, on: Day("2026-10-19")!)?.source == .manual)
    #expect(t.quote(from: .EUR, to: .UAH, on: Day("2026-10-20")!)?.source == .nbu)
    #expect(t.quote(from: .EUR, to: .UAH, on: Day("2026-10-20")!)?.rate == decimal("48.50"))

    let inverse = B1Fixture.override(.UAH, .USD, "0.025", from: "2026-10-01")
    let usd = try #require(table([inverse]).quote(from: .USD, to: .UAH, on: today))
    #expect(usd.rate == decimal("40"))
    #expect(usd.source == .manual)
  }

  @Test("R-FX-2 the fetched-rate hint ignores manual rates")
  func fetchedIgnoresManual() {
    let manual = B1Fixture.override(.EUR, .UAH, "49.00", from: "2026-10-01")
    #expect(table([manual]).fetchedRate(from: .EUR, to: .UAH, on: today) == decimal("48.50"))
  }

  @Test("R-FX-5 no rows without any known rate")
  func empty() {
    #expect(RatesTable(rates: [], overrides: []).rows(showIn: .UAH, on: today).isEmpty)
  }
}
