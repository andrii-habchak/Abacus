import AbacusDomain
import Foundation
import Testing

@testable import AbacusFX

/// Official `1 X = r UAH` rates for one day, as the providers return them.
func official(
  _ day: String, usd: Decimal, eur: Decimal, pln: Decimal, provider: String = "NBU",
  fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> [FXRate] {
  [(Currency.USD, usd), (.EUR, eur), (.PLN, pln)].map { currency, rate in
    FXRate(
      day: day, base: currency, quote: .UAH, rateE8: RateScale.scaled(rate), provider: provider,
      fetchedAt: fetchedAt)
  }
}

/// NBU rates of 10–16 Jan 2024 (13/14 are a weekend: no rows).
let januaryRates: [FXRate] =
  official("2024-01-10", usd: 38.2253, eur: 41.8185, pln: 9.6305)
  + official("2024-01-11", usd: 38.1923, eur: 41.8015, pln: 9.6294)
  + official("2024-01-12", usd: 37.9982, eur: 41.741, pln: 9.6008)
  + official("2024-01-15", usd: 37.8386, eur: 41.3879, pln: 9.4881)
  + official("2024-01-16", usd: 37.8641, eur: 41.4763, pln: 9.5057)

func dec(_ string: String) -> Decimal { Decimal(string: string)! }

@Suite("RateTable conversion (R-FX-1/2/3, R-CUR-2/3)")
struct RateTableTests {
  let table = RateTable(rates: januaryRates)

  @Test("R-FX-1: X→UAH is the NBU number, UAH→X its inverse, same currency is 1")
  func pivotRates() {
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == dec("41.3879"))
    #expect(table.rate(from: .UAH, to: .EUR, on: d("2024-01-15")) == 1 / dec("41.3879"))
    #expect(table.rate(from: .PLN, to: .PLN, on: d("1999-01-01")) == 1)
  }

  @Test("R-FX-3: cross rates go through UAH on the transaction's day")
  func crossRates() {
    #expect(table.rate(from: .EUR, to: .PLN, on: d("2024-01-15")) == dec("41.3879") / dec("9.4881"))
    #expect(table.rate(from: .USD, to: .EUR, on: d("2024-01-10")) == dec("38.2253") / dec("41.8185"))
    // Different days give different rates: past periods stay stable (D8).
    #expect(table.rate(from: .EUR, to: .PLN, on: d("2024-01-10"))
      != table.rate(from: .EUR, to: .PLN, on: d("2024-01-16")))
  }

  @Test("R-FX-1: weekend and holiday use the most recent earlier rate; before any data → nil")
  func weekendFallback() throws {
    let saturday = try #require(table.quote(from: .EUR, to: .USD, on: d("2024-01-13")))
    #expect(saturday.rate == dec("41.741") / dec("37.9982"))
    #expect(saturday.day == d("2024-01-12"))
    #expect(saturday.source == .official(provider: "NBU"))
    #expect(table.rate(from: .PLN, to: .UAH, on: d("2024-01-14")) == dec("9.6008"))
    // After the last known day the last rate is kept (offline, R-FX-4).
    #expect(table.rate(from: .PLN, to: .UAH, on: d("2024-03-01")) == dec("9.5057"))
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-09")) == nil)
    #expect(table.rate(from: .UAH, to: .UAH, on: d("2024-01-09")) == 1)
  }

  @Test("R-FX-3: net worth uses the latest rate; latestDay is the newest official day (R-FX-4)")
  func latest() {
    #expect(table.latestDay == d("2024-01-16"))
    #expect(table.latestRate(from: .EUR, to: .UAH) == dec("41.4763"))
    var withToday = table
    withToday.today = d("2024-01-20")
    #expect(withToday.latestRate(from: .USD, to: .PLN) == dec("37.8641") / dec("9.5057"))
    #expect(RateTable().latestRate(from: .EUR, to: .UAH) == nil)
    #expect(RateTable().latestDay == nil)
  }

  @Test("R-CUR-2 R-CUR-3: convert keeps the original, rounds the result to minor units (banker's)")
  func convertMoney() {
    let amount = Money(minorUnits: 10_000, currency: .EUR)  // €100.00
    let uah = table.convert(amount, to: .UAH, on: d("2024-01-15"))
    #expect(uah == Money(minorUnits: 413_879, currency: .UAH))
    #expect(amount == Money(minorUnits: 10_000, currency: .EUR))
    // 1 PLN at EUR: 9.4881 / 41.3879 = 0.22924…  → 0.23
    #expect(table.convert(Money(minorUnits: 100, currency: .PLN), to: .EUR, on: d("2024-01-15"))
      == Money(minorUnits: 23, currency: .EUR))
    // 0.005 → 0 and 0.015 → 0.02 with banker's rounding: 1 UAH at EUR = 0.0241…, so use a
    // manual 1 EUR = 0.5 UAH to hit exact halves.
    let half = RateTable(overrides: [
      FXOverride(base: .UAH, quote: .EUR, rateE8: 50_000_000, fromDay: "2024-01-01")
    ])
    #expect(half.convert(Money(minorUnits: 1, currency: .UAH), to: .EUR, on: d("2024-01-02"))
      == Money(minorUnits: 0, currency: .EUR))
    #expect(half.convert(Money(minorUnits: 3, currency: .UAH), to: .EUR, on: d("2024-01-02"))
      == Money(minorUnits: 2, currency: .EUR))
    #expect(table.convertAtLatest(amount, to: .UAH) == Money(minorUnits: 414_763, currency: .UAH))
    #expect(RateTable().convert(amount, to: .UAH, on: d("2024-01-15")) == nil)
  }

  @Test("Two providers for one day: the most recently fetched rate is kept")
  func duplicateDays() {
    var table = RateTable(rates: official("2024-01-15", usd: 1, eur: 2, pln: 3, provider: "NBU",
      fetchedAt: Date(timeIntervalSince1970: 100)))
    table.merge(official("2024-01-15", usd: 4, eur: 5, pln: 6, provider: "Frankfurter/NBU",
      fetchedAt: Date(timeIntervalSince1970: 200)))
    table.merge(official("2024-01-15", usd: 7, eur: 8, pln: 9, provider: "NBU",
      fetchedAt: Date(timeIntervalSince1970: 50)))
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == 5)
    #expect(table.officialRates.count == 3)
  }

  @Test("Rates quoted as UAH→X are accepted; pairs without UAH are ignored")
  func normalisesInput() {
    let table = RateTable(rates: [
      FXRate(day: "2024-01-15", base: .UAH, quote: .EUR, rateE8: 2_500_000, provider: "NBU"),
      FXRate(day: "2024-01-15", base: .EUR, quote: .USD, rateE8: 110_000_000, provider: "x"),
    ])
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == 40)
    #expect(table.rate(from: .EUR, to: .USD, on: d("2024-01-15")) == nil)
  }
}

@Suite("Manual overrides (R-FX-2)")
struct OverrideTests {
  let base = RateTable(rates: januaryRates)

  func with(_ overrides: FXOverride...) -> RateTable {
    var table = base
    table.setOverrides(overrides)
    return table
  }

  @Test("R-FX-2: a one-day override wins on its day only, and is marked manual")
  func singleDay() throws {
    let manual = FXOverride(
      base: .EUR, quote: .PLN, rateE8: 430_000_000, fromDay: "2024-01-15", untilDay: "2024-01-15")
    let table = with(manual)
    let quote = try #require(table.quote(from: .EUR, to: .PLN, on: d("2024-01-15")))
    #expect(quote.rate == dec("4.3"))
    #expect(quote.source == .manual(overrideID: manual.id))
    #expect(quote.source.badge == "Manual")
    #expect(table.rate(from: .EUR, to: .PLN, on: d("2024-01-16")) == dec("41.4763") / dec("9.5057"))
    #expect(table.rate(from: .EUR, to: .PLN, on: d("2024-01-12")) == dec("41.741") / dec("9.6008"))
    // The inverse pair uses the same override.
    #expect(table.rate(from: .PLN, to: .EUR, on: d("2024-01-15")) == 1 / dec("4.3"))
    // Other pairs are untouched.
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == dec("41.3879"))
  }

  @Test("R-FX-2: \"from this day on\" holds until changed, also beyond the fetched data")
  func fromDay() {
    let table = with(FXOverride(base: .USD, quote: .UAH, rateE8: 4_000_000_000, fromDay: "2024-01-11"))
    #expect(table.rate(from: .USD, to: .UAH, on: d("2024-01-10")) == dec("38.2253"))
    #expect(table.rate(from: .USD, to: .UAH, on: d("2024-01-11")) == 40)
    #expect(table.rate(from: .USD, to: .UAH, on: d("2024-06-30")) == 40)
    // An override against UAH feeds cross rates too.
    #expect(table.rate(from: .USD, to: .PLN, on: d("2024-01-15")) == 40 / dec("9.4881"))
    #expect(table.quote(from: .USD, to: .PLN, on: d("2024-01-15"))?.source.isManual == true)
    #expect(table.latestRate(from: .USD, to: .UAH) == 40)
  }

  @Test("R-FX-2: a later override ends an older open one; a one-day override inside it wins")
  func precedence() {
    let older = FXOverride(base: .EUR, quote: .UAH, rateE8: 4_000_000_000, fromDay: "2024-01-10")
    let oneDay = FXOverride(
      base: .EUR, quote: .UAH, rateE8: 4_200_000_000, fromDay: "2024-01-12", untilDay: "2024-01-12")
    let newer = FXOverride(base: .EUR, quote: .UAH, rateE8: 4_100_000_000, fromDay: "2024-01-15")
    let table = with(newer, oneDay, older)
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-11")) == 40)
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-12")) == 42)
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-13")) == 40)
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-16")) == 41)
    #expect(table.overrides.map(\.id) == [newer.id, oneDay.id, older.id])
    #expect(table.activeOverride(base: .EUR, quote: .UAH, on: d("2024-01-12"))?.id == oneDay.id)
  }

  @Test("R-FX-2: removing an override falls back to the fetched rate")
  func removal() {
    var table = with(FXOverride(base: .EUR, quote: .UAH, rateE8: 4_000_000_000, fromDay: "2024-01-10"))
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == 40)
    table.setOverrides([])
    #expect(table.rate(from: .EUR, to: .UAH, on: d("2024-01-15")) == dec("41.3879"))
  }

  @Test("R-FX-2: the fetched rate is still available next to a manual one")
  func fetchedRateBesideManual() {
    let table = with(FXOverride(base: .EUR, quote: .UAH, rateE8: 4_000_000_000, fromDay: "2024-01-10"))
    #expect(table.quote(from: .EUR, to: .UAH, on: d("2024-01-15"), includeOverrides: false)?.rate
      == dec("41.3879"))
  }

  @Test("R-CUR-1 R-FX-2 R-FX-3: every pair of the four currencies converts; rate() agrees with quote()")
  func fastPathAgrees() {
    let table = with(
      FXOverride(base: .EUR, quote: .PLN, rateE8: 430_000_000, fromDay: "2024-01-12", untilDay: "2024-01-15"),
      FXOverride(base: .UAH, quote: .USD, rateE8: 2_600_000, fromDay: "2024-01-14"))
    for dayText in ["2024-01-09", "2024-01-10", "2024-01-13", "2024-01-15", "2024-01-16", "2024-02-01"] {
      for from in Currency.allCases {
        for to in Currency.allCases {
          #expect(table.rate(from: from, to: to, on: d(dayText))
            == table.quote(from: from, to: to, on: d(dayText))?.rate, "\(from)→\(to) \(dayText)")
          if dayText != "2024-01-09" {
            #expect(table.rate(from: from, to: to, on: d(dayText)) != nil)
          }
        }
      }
    }
  }

  @Test("R-FX-2: overrides work with no fetched rates at all (offline first run)")
  func overridesOnly() {
    let table = RateTable(overrides: [
      FXOverride(base: .PLN, quote: .EUR, rateE8: 23_000_000, fromDay: "2024-02-01")
    ])
    #expect(table.rate(from: .PLN, to: .EUR, on: d("2024-02-03")) == dec("0.23"))
    #expect(table.rate(from: .PLN, to: .EUR, on: d("2024-01-31")) == nil)
    #expect(table.rate(from: .PLN, to: .UAH, on: d("2024-02-03")) == nil)
    #expect(table.latestRate(from: .PLN, to: .EUR) == dec("0.23"))
  }
}

@Suite("RateTable performance (R-NF-2)")
struct RateTablePerformanceTests {
  @Test("R-NF-2: 20 000 date conversions over three years of rates stay well under 200 ms")
  func manyConversions() {
    var rates: [FXRate] = []
    var day = d("2022-01-03")
    for index in 0..<1100 {
      let step = Decimal(index) / 1000
      rates += official(day.string, usd: 27 + step, eur: 30 + step, pln: 7 + step)
      day = day.adding(days: 1, calendar: Calendar(identifier: .gregorian))
    }
    let table = RateTable(
      rates: rates,
      overrides: [FXOverride(base: .EUR, quote: .PLN, rateE8: 450_000_000, fromDay: "2023-06-01")])
    let days = (0..<20_000).map { d("2022-01-03").adding(days: $0 % 1100, calendar: Calendar(identifier: .gregorian)) }
    let clock = ContinuousClock()
    var total = Decimal()
    let elapsed = clock.measure {
      for (index, day) in days.enumerated() {
        let from: Currency = [.EUR, .PLN, .USD][index % 3]
        total += table.rate(from: from, to: .UAH, on: day) ?? 0
      }
    }
    #expect(total > 0)
    #expect(elapsed < .milliseconds(200))
  }
}
