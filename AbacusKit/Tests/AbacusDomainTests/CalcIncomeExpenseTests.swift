import AbacusDomain
import Foundation
import Testing

@Suite("Calc: income vs expenses by month")
struct CalcIncomeExpenseTests {
  let pln = Fx.account(1, .PLN)
  let eur = Fx.account(2, .EUR)
  let usd = Fx.account(3, .USD)
  let groceries = Fx.category(10)
  let salary = Fx.category(40, .income)
  let cashback = Fx.category(41, .income)
  var categories: [AbacusDomain.Category] { [groceries, salary, cashback] }

  /// EUR→PLN 4.00 on Oct 1, 4.50 from Oct 15.
  var converter: FakeConverter {
    FakeConverter([("2026-10-01", .EUR, .PLN, "4.00"), ("2026-10-15", .EUR, .PLN, "4.50")], latest: [(.EUR, .PLN, "4.50")])
  }

  var txns: [TxnWithLines] {
    [
      Fx.income(5_000_00, pln, on: "2026-09-10", category: salary),
      Fx.expense(300_00, pln, on: "2026-09-12", category: groceries),
      Fx.income(1_000_00, eur, on: "2026-10-02", category: salary),  // 4,000.00 PLN
      Fx.expense(10_00, eur, on: "2026-10-20", category: groceries),  // 45.00 PLN
      Fx.expense(40_00, pln, on: "2026-10-03", category: groceries, lines: [Fx.line(1_00, .income, category: cashback)]),
      Fx.expense(20_00, pln, on: "2026-10-07", category: groceries, refund: true),
      Fx.transfer(100_00, from: pln, to: eur, received: 25_00, on: "2026-10-11"),
      Fx.expense(999_00, pln, on: "2025-10-31", category: groceries),  // before the window
      Fx.expense(999_00, pln, on: "2026-11-01", category: groceries),  // after it
    ]
  }

  func series(refundsReduceSpending: Bool = false, txns: [TxnWithLines]? = nil, accounts: [Account]? = nil)
    -> IncomeExpenseSeries
  {
    Calc.incomeExpenseSeries(
      endingAt: Month("2026-10")!, accounts: accounts ?? [pln, eur], categories: categories, txns: txns ?? self.txns,
      currency: .PLN, converter: converter, refundsReduceSpending: refundsReduceSpending, calendar: Fx.calendar)
  }

  @Test("R-HOME-6: twelve months ending at the given one, oldest first, empty months at zero")
  func twelveMonths() {
    let result = series()
    #expect(result.months.map(\.month.string).first == "2025-11")
    #expect(result.months.map(\.month.string).last == "2026-10")
    #expect(result.months.count == 12)
    #expect(result.months.prefix(10).allSatisfy { $0.income.minorUnits == 0 && $0.expense.minorUnits == 0 })
    #expect(result.months.allSatisfy { $0.income.currency == .PLN && $0.expense.currency == .PLN })
  }

  @Test("R-HOME-6, R-FX-3, R-TX-5, R-TX-6: day rates, records by kind, transfers left out, refund as income with the setting off")
  func monthTotals() throws {
    let result = series()
    let september = try #require(result.months.first { $0.month.string == "2026-09" })
    #expect(september.income.minorUnits == 5_000_00)
    #expect(september.expense.minorUnits == 300_00)
    #expect(september.net.minorUnits == 4_700_00)
    let october = try #require(result.months.last)
    #expect(october.income.minorUnits == 4_000_00 + 1_00 + 20_00)
    #expect(october.expense.minorUnits == 45_00 + 40_00)
    #expect(result.unconverted.isEmpty)
  }

  @Test("R-HOME-6, R-SET-3: the refund setting moves a refund between income and expenses; the net stays")
  func refundSetting() throws {
    let off = try #require(series(refundsReduceSpending: false).months.last)
    let on = try #require(series(refundsReduceSpending: true).months.last)
    #expect(on.income.minorUnits == off.income.minorUnits - 20_00)
    #expect(on.expense.minorUnits == off.expense.minorUnits - 20_00)
    #expect(on.net == off.net)
  }

  @Test("R-HOME-6: the month totals equal the donuts' totals")
  func matchesDonuts() throws {
    let october = try #require(series().months.last)
    let days = Month("2026-10")!.firstDay...Day("2026-10-31")!
    for (kind, total) in [(CategoryKind.income, october.income), (.expense, october.expense)] {
      let donut = Calc.categoryTotals(
        kind: kind, days: days, accounts: [pln, eur], categories: categories, txns: txns, currency: .PLN,
        converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
      #expect(donut.total == total)
    }
  }

  @Test("D27: an amount without a rate is left out and reported, never taken at 1")
  func missingRate() throws {
    let result = series(
      txns: [Fx.expense(10_00, usd, on: "2026-10-05", category: groceries), Fx.expense(5_00, pln, on: "2026-10-05")],
      accounts: [pln, usd])
    #expect(result.months.last?.expense.minorUnits == 5_00)
    #expect(result.unconverted.missingRates == [MissingRate(from: .USD, to: .PLN, day: Day("2026-10-05")!)])
  }
}
