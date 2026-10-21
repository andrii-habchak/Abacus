import AbacusDomain
import Foundation
import Testing

@Suite("Calc: net worth")
struct CalcNetWorthTests {
  let pln = Fx.account(1, .PLN, .bank, opening: 1_000_00)
  let eur = Fx.account(2, .EUR, .savings, opening: 100_00)
  let card = Fx.account(3, .PLN, .creditCard, opening: -300_00)
  let archived = Fx.account(4, .PLN, .bank, opening: 9_999_00, archived: true)

  var converter: FakeConverter {
    FakeConverter(
      [("2026-08-31", .EUR, .PLN, "4.20"), ("2026-09-30", .EUR, .PLN, "4.30")],
      latest: [(.EUR, .PLN, "4.25")], latestDay: "2026-10-20")
  }

  @Test("R-HOME-1: net worth = assets − liabilities at the latest rate")
  func assetsMinusLiabilities() {
    let result = Calc.netWorth(
      accounts: [pln, eur, card], txns: [], currency: .PLN, converter: converter, calendar: Fx.calendar)
    #expect(result.assets.minorUnits == 1_000_00 + 425_00)
    #expect(result.liabilities.minorUnits == 300_00)
    #expect(result.total.minorUnits == 1_125_00)
    #expect(result.unconverted.isEmpty)
    #expect(result.accounts.map(\.converted?.minorUnits) == [1_000_00, 425_00, -300_00])
    #expect(result.accounts.map(\.isLiability) == [false, false, true])
  }

  @Test("R-ACC-4: archived accounts are excluded from net worth")
  func archivedExcluded() {
    let result = Calc.netWorth(
      accounts: [pln, archived], txns: [Fx.income(1_00, archived, on: "2026-10-01")], currency: .PLN,
      converter: converter, calendar: Fx.calendar)
    #expect(result.total.minorUnits == 1_000_00)
    #expect(result.accounts.map(\.accountID) == [pln.id])
  }

  @Test("R-ACC-4: a transfer from an archived account still counts on the active side")
  func transferFromArchived() {
    let t = Fx.transfer(50_00, from: archived, to: pln, on: "2026-10-01")
    let result = Calc.netWorth(accounts: [pln, archived], txns: [t], currency: .PLN, converter: converter, calendar: Fx.calendar)
    #expect(result.total.minorUnits == 1_050_00)
  }

  @Test("R-FX-3: a balance without a rate is marked unconverted, never taken at 1")
  func missingRate() {
    let usd = Fx.account(5, .USD, opening: 10_00)
    let result = Calc.netWorth(accounts: [pln, usd], txns: [], currency: .PLN, converter: converter, calendar: Fx.calendar)
    #expect(result.total.minorUnits == 1_000_00)
    #expect(result.accounts.last?.converted == nil)
    #expect(result.accounts.last?.balance == Money(minorUnits: 10_00, currency: .USD))
    #expect(result.unconverted.count == 1)
    #expect(result.unconverted.missingRates == [MissingRate(from: .USD, to: .PLN, day: nil)])
  }

  @Test("R-HOME-1: monthly series — month ends at that day's rate, the last point today at the latest rate")
  func series() {
    let txns = [
      Fx.income(200_00, pln, on: "2026-09-15"),
      Fx.expense(50_00, pln, on: "2026-10-05"),
      Fx.expense(10_00, eur, on: "2026-10-10"),
      Fx.income(999_00, pln, on: "2026-10-25"),  // after today: not in today's point
    ]
    let series = Calc.netWorthSeries(
      accounts: [pln, eur, card], txns: txns, currency: .PLN, converter: converter,
      today: Day("2026-10-21")!, monthEnds: 2, calendar: Fx.calendar)
    #expect(series.points.map(\.day.string) == ["2026-08-31", "2026-09-30", "2026-10-21"])
    #expect(series.points.map(\.isToday) == [false, false, true])
    // Aug 31: 1000 + 100 EUR × 4.20 − 300
    #expect(series.points[0].value.minorUnits == 1_000_00 + 420_00 - 300_00)
    #expect(series.points[0].netWorth.rateDate == .day(Day("2026-08-31")!))
    // Sep 30: 1200 + 100 EUR × 4.30 − 300
    #expect(series.points[1].value.minorUnits == 1_200_00 + 430_00 - 300_00)
    // Today: 1150 + 90 EUR × 4.25 − 300
    #expect(series.points[2].value.minorUnits == 1_150_00 + 382_50 - 300_00)
    #expect(series.points[2].netWorth.rateDate == .latest)
    #expect(series.today == series.points.last)
    #expect(series.changeSincePreviousMonthEnd?.minorUnits == (1_150_00 + 382_50) - (1_200_00 + 430_00))
  }

  @Test("R-HOME-1: the default series has 12 points ending today")
  func seriesDefaultLength() {
    let series = Calc.netWorthSeries(
      accounts: [pln], txns: [], currency: .PLN, converter: converter, today: Day("2026-10-21")!, calendar: Fx.calendar)
    #expect(series.points.count == 12)
    #expect(series.points.first?.day.string == "2025-11-30")
  }

  @Test("R-FX-3: a month end before any known rate is marked unconverted")
  func seriesMissingEarlyRate() {
    let series = Calc.netWorthSeries(
      accounts: [pln, eur], txns: [], currency: .PLN, converter: converter, today: Day("2026-10-21")!,
      monthEnds: 3, calendar: Fx.calendar)
    #expect(series.points[0].netWorth.unconverted.missingRates == [MissingRate(from: .EUR, to: .PLN, day: Day("2026-07-31")!)])
    #expect(series.points[0].value.minorUnits == 1_000_00)
    #expect(series.points[1].netWorth.unconverted.isEmpty)
  }
}
