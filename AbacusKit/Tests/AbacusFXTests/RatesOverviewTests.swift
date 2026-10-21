import AbacusDomain
import Foundation
import Testing

@testable import AbacusFX

@Suite("Rates screen helpers (R-FX-5, R-FX-2)")
struct RatesOverviewTests {
  let table = RateTable(rates: januaryRates)

  @Test("R-FX-5: day change compares with the previous official day")
  func dayChange() throws {
    let change = try #require(table.dayChange(from: .EUR, to: .UAH, on: d("2024-01-16")))
    #expect(change.current.rate == dec("41.4763") && change.current.day == d("2024-01-16"))
    #expect(change.previous.rate == dec("41.3879") && change.previous.day == d("2024-01-15"))
    #expect(change.direction == .up)
    #expect(change.delta == dec("0.0884"))
    #expect(change.percent == dec("0.0884") / dec("41.3879") * 100)

    // On a Monday the previous official day is Friday; on a Saturday, Friday vs Thursday.
    #expect(table.dayChange(from: .EUR, to: .UAH, on: d("2024-01-15"))?.previous.day == d("2024-01-12"))
    let saturday = try #require(table.dayChange(from: .USD, to: .UAH, on: d("2024-01-13")))
    #expect(saturday.current.day == d("2024-01-12") && saturday.previous.day == d("2024-01-11"))
    #expect(saturday.direction == .down)
    // Nothing before the first day; same currency has no change.
    #expect(table.dayChange(from: .EUR, to: .UAH, on: d("2024-01-10")) == nil)
    #expect(table.dayChange(from: .EUR, to: .EUR, on: d("2024-01-16")) == nil)
  }

  @Test("R-FX-5: 30-day series has one point per calendar day, weekends repeat Friday")
  func series() {
    let points = table.series(from: .PLN, to: .UAH, endingOn: d("2024-01-16"))
    #expect(points.map(\.day) == (10...16).map { d("2024-01-\($0)") })  // nothing before the 10th
    #expect(points.first { $0.day == d("2024-01-14") }?.rate == dec("9.6008"))

    var long: [FXRate] = []
    var day = d("2023-12-01")
    while day <= d("2024-01-16") {
      long += official(day.string, usd: 37, eur: 41, pln: 9)
      day = day.adding(days: 1, calendar: utc)
    }
    let full = RateTable(rates: long).series(from: .EUR, to: .USD, endingOn: d("2024-01-16"))
    #expect(full.count == 30)
    #expect(full.first?.day == d("2023-12-18") && full.last?.day == d("2024-01-16"))
  }

  @Test("R-FX-5 R-FX-2: today's rates in the chosen currency, manual rows badged")
  func rows() throws {
    var table = table
    let manual = FXOverride.onDay(d("2024-01-16"), base: .USD, quote: .PLN, rate: dec("3.95"))
    table.setOverrides([manual])
    let rows = RatesOverview.rows(table, showIn: .PLN, on: d("2024-01-16"))
    #expect(rows.map(\.currency) == [.UAH, .EUR, .USD])
    #expect(rows.allSatisfy { $0.showIn == .PLN && $0.series.count == 7 })
    let eur = try #require(rows.first { $0.currency == .EUR })
    #expect(eur.quote.rate == dec("41.4763") / dec("9.5057"))  // "1 EUR = 4.36… PLN"
    #expect(eur.badge == "NBU")
    #expect(eur.change?.previous.day == d("2024-01-15"))
    let usd = try #require(rows.first { $0.currency == .USD })
    #expect(usd.quote.rate == dec("3.95") && usd.badge == "Manual")
    #expect(RatesOverview.rows(RateTable(), showIn: .UAH, on: d("2024-01-16")).isEmpty)
  }

  @Test("R-FX-2: manual rate list describes \"on <day> only\" and \"from <day> until changed\"")
  func overrideScope() {
    let one = FXOverride.onDay(d("2024-01-15"), base: .EUR, quote: .PLN, rate: dec("4.3"), note: "card")
    let open = FXOverride.from(d("2024-01-15"), base: .EUR, quote: .PLN, rate: dec("4.3"))
    let bounded = FXOverride(base: .EUR, quote: .PLN, rateE8: 430_000_000, fromDay: "2024-01-15", untilDay: "2024-01-20")
    #expect(one.scope == .singleDay(d("2024-01-15")) && one.note == "card")
    #expect(open.scope == .fromDay(d("2024-01-15")))
    #expect(bounded.scope == .range(d("2024-01-15"), d("2024-01-20")))
    #expect(one.rate == dec("4.3") && one.rateE8 == 430_000_000)
  }
}
