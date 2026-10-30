import AbacusDomain
import Foundation
import Testing

/// C29, R-ACC-4: the "Balance correction" booked when an account with a balance is archived is on
/// the account (balance, list) but is neither income nor expense anywhere.
@Suite("Calc: balance corrections stay out of reports (R-ACC-4)")
struct CalcBalanceCorrectionTests {
  let pln = Fx.account(1, .PLN, opening: 1_000_00)
  let groceries = Fx.category(10)
  let salary = Fx.category(40, .income)
  let correctionExpense = Fx.category(60)
  let correctionIncome = Fx.category(61, .income)
  var categories: [AbacusDomain.Category] { [groceries, salary, correctionExpense, correctionIncome] }
  let converter = FakeConverter([], latest: [])

  func correction(_ amount: Int64, income: Bool, on day: String = "2026-10-20") -> TxnWithLines {
    var item =
      income
      ? Fx.income(amount, pln, on: day, category: correctionIncome)
      : Fx.expense(amount, pln, on: day, category: correctionExpense)
    item.txn.isBalanceCorrection = true
    return item
  }

  var ordinary: [TxnWithLines] {
    [
      Fx.income(5_000_00, pln, on: "2026-10-02", category: salary),
      Fx.expense(300_00, pln, on: "2026-10-03", category: groceries),
    ]
  }

  @Test("R-ACC-4: a flagged expense and income give no report entries")
  func noEntries() {
    for item in [correction(700_00, income: false), correction(700_00, income: true)] {
      let entries = Calc.reportEntries(
        of: item, currency: .PLN, categories: CategoryTree(categories), refundsReduceSpending: false,
        calendar: Fx.calendar)
      #expect(entries.isEmpty)
    }
  }

  @Test("R-ACC-4: the category donut (expense and income) ignores corrections")
  func donut() {
    let txns = ordinary + [correction(700_00, income: false), correction(900_00, income: true)]
    for kind in [CategoryKind.expense, .income] {
      let with = Calc.categoryTotals(
        kind: kind, days: nil, accounts: [pln], categories: categories, txns: txns, currency: .PLN,
        converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
      let without = Calc.categoryTotals(
        kind: kind, days: nil, accounts: [pln], categories: categories, txns: ordinary, currency: .PLN,
        converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
      #expect(with == without)
    }
  }

  @Test("R-ACC-4: income vs expenses and the list totals ignore corrections")
  func incomeVsExpenses() {
    let txns = ordinary + [correction(700_00, income: false), correction(900_00, income: true)]
    let series = Calc.incomeExpenseSeries(
      endingAt: Month("2026-10")!, count: 1, accounts: [pln], categories: categories, txns: txns, currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(series.months[0].income.minorUnits == 5_000_00)
    #expect(series.months[0].expense.minorUnits == 300_00)
    let totals = Calc.listTotals(
      txns: txns, accounts: [pln], categories: categories, currency: .PLN, converter: converter,
      refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(totals.income.minorUnits == 5_000_00 && totals.expense.minorUnits == 300_00)
  }

  @Test("R-ACC-4, R-BUD-2: the budget does not count a correction, even in a limited category")
  func budget() throws {
    let plan = BudgetPlan(id: Fx.id(901), effectiveMonth: "2026-01")
    let limit = BudgetAllocation(
      id: Fx.id(910), planID: plan.id, categoryID: correctionExpense.id, limitMinor: 100_00, currency: .PLN)
    let status = try #require(
      Calc.budgetStatus(
        month: Month("2026-10")!, plans: [plan], allocations: [limit], accounts: [pln], categories: categories,
        txns: ordinary + [correction(700_00, income: false)], converter: converter, refundsReduceSpending: false,
        currency: .PLN, today: Day("2026-10-21")!, calendar: Fx.calendar))
    #expect(status.lines.first?.spent.minorUnits == 0)
  }

  @Test("R-ACC-3, R-ACC-4: the correction still moves the account balance to zero")
  func balanceStillMoves() {
    let txns = [correction(1_000_00, income: false)]
    let balances = Calc.balances(accounts: [pln], txns: txns, through: Day("2026-10-21")!, calendar: Fx.calendar)
    #expect(balances[pln.id]?.minorUnits == 0)
  }
}
