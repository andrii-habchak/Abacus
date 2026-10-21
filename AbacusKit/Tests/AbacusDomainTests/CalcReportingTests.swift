import AbacusDomain
import Foundation
import Testing

@Suite("Calc: refunds, expenses by category, list totals")
struct CalcReportingTests {
  let pln = Fx.account(1, .PLN)
  let eur = Fx.account(2, .EUR)
  let food = Fx.category(10)
  let groceries = Fx.category(11, parent: 10)
  let eatingOut = Fx.category(12, parent: 10)
  let transport = Fx.category(20)
  let fees = Fx.category(30)
  let salary = Fx.category(40, .income)
  let cashback = Fx.category(41, .income)
  var categories: [AbacusDomain.Category] { [food, groceries, eatingOut, transport, fees, salary, cashback] }

  /// EUR→PLN 4.00 on Oct 1, 4.50 from Oct 15.
  var converter: FakeConverter {
    FakeConverter([("2026-10-01", .EUR, .PLN, "4.00"), ("2026-10-15", .EUR, .PLN, "4.50")], latest: [(.EUR, .PLN, "4.50")])
  }

  // MARK: Refunds

  @Test("R-TX-4, R-SET-3: setting off — a refund is income \"Refunds\", category spending unchanged")
  func refundAsIncome() {
    let refund = Fx.expense(30_00, pln, on: "2026-10-05", category: groceries, refund: true)
    let entries = Calc.reportEntries(of: refund, currency: .PLN, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(entries.map(\.kind) == [.income])
    #expect(entries.map(\.key) == [.refunds])
    #expect(entries.map(\.amount.minorUnits) == [30_00])
  }

  @Test("R-TX-4, R-SET-3: setting on — a refund is subtracted from its category")
  func refundReducesSpending() {
    let refund = Fx.expense(30_00, pln, on: "2026-10-05", category: groceries, refund: true)
    let entries = Calc.reportEntries(of: refund, currency: .PLN, refundsReduceSpending: true, calendar: Fx.calendar)
    #expect(entries.map(\.kind) == [.expense])
    #expect(entries.map(\.key) == [.category(groceries.id)])
    #expect(entries.map(\.amount.minorUnits) == [-30_00])
  }

  @Test("R-TX-4: an income reversal reduces its income category")
  func incomeReversal() {
    let reversal = Fx.income(100_00, pln, on: "2026-10-05", category: salary, reversal: true)
    let entries = Calc.reportEntries(of: reversal, currency: .PLN, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(entries.map(\.kind) == [.income])
    #expect(entries.map(\.amount.minorUnits) == [-100_00])
  }

  @Test("R-TX-5: a transfer is neither income nor expense; its fee is an expense")
  func transferEntries() {
    let t = Fx.transfer(100_00, from: pln, to: eur, received: 25_00, on: "2026-10-05", lines: [Fx.line(2_00, category: fees)])
    let entries = Calc.reportEntries(of: t, currency: .PLN, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(entries.map(\.key) == [.category(fees.id)])
    #expect(entries.map(\.kind) == [.expense])
  }

  @Test("R-TX-4: balances are the same whichever way refunds are counted")
  func refundBalanceUnaffected() {
    let txns = [Fx.expense(30_00, pln, on: "2026-10-05", category: groceries, refund: true)]
    #expect(Calc.balance(of: pln, txns: txns, calendar: Fx.calendar).minorUnits == 30_00)
    let off = Calc.listTotals(txns: txns, accounts: [pln], currency: .PLN, converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    let on = Calc.listTotals(txns: txns, accounts: [pln], currency: .PLN, converter: converter, refundsReduceSpending: true, calendar: Fx.calendar)
    #expect(off.net == on.net)
    #expect(off.income.minorUnits == 30_00 && off.expense.minorUnits == 0)
    #expect(on.income.minorUnits == 0 && on.expense.minorUnits == -30_00)
  }

  // MARK: Donut

  var octoberTxns: [TxnWithLines] {
    [
      Fx.expense(100_00, pln, on: "2026-10-02", category: groceries),
      Fx.expense(40_00, pln, on: "2026-10-03", category: eatingOut, lines: [Fx.line(5_00, category: fees), Fx.line(1_00, .income, category: cashback)]),
      Fx.expense(10_00, pln, on: "2026-10-04", category: food),
      Fx.expense(10_00, eur, on: "2026-10-05", category: transport),  // 40.00 PLN
      Fx.expense(10_00, eur, on: "2026-10-20", category: transport),  // 45.00 PLN
      Fx.expense(7_00, pln, on: "2026-10-06"),
      Fx.expense(20_00, pln, on: "2026-10-07", category: groceries, refund: true),
      Fx.income(5_000_00, pln, on: "2026-10-10", category: salary),
      Fx.transfer(100_00, from: pln, to: eur, received: 25_00, on: "2026-10-11"),
      Fx.expense(999_00, pln, on: "2026-09-30", category: groceries),  // other month
      Fx.expense(999_00, pln, on: "2026-11-01", category: groceries),  // other month
    ]
  }

  @Test("R-HOME-3, R-CAT-2: parents roll up children; attached expense records under their own category")
  func donut() throws {
    let result = Calc.expensesByCategory(
      month: Month("2026-10")!, accounts: [pln, eur], categories: categories, txns: octoberTxns,
      currency: .PLN, converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.unconverted.isEmpty)
    #expect(result.items.map(\.key) == [.category(food.id), .category(transport.id), .uncategorized, .category(fees.id)])
    let foodTotal = try #require(result.items.first)
    #expect(foodTotal.total.minorUnits == 150_00)
    #expect(foodTotal.direct.minorUnits == 10_00)
    #expect(foodTotal.children.map(\.key) == [.category(groceries.id), .category(eatingOut.id)])
    #expect(foodTotal.children.map(\.total.minorUnits) == [100_00, 40_00])
    #expect(result.items.map(\.total.minorUnits) == [150_00, 85_00, 7_00, 5_00])
    #expect(result.total.minorUnits == 247_00)
    #expect(foodTotal.share == Decimal(150_00) / Decimal(247_00))
  }

  @Test("R-FX-3: each expense is converted at its own day's rate")
  func donutRatePerDay() throws {
    let result = Calc.expensesByCategory(
      month: Month("2026-10")!, accounts: [pln, eur], categories: categories, txns: octoberTxns,
      currency: .PLN, converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    let transportTotal = try #require(result.items.first { $0.key == .category(transport.id) })
    #expect(transportTotal.total.minorUnits == 40_00 + 45_00)
  }

  @Test("R-HOME-3, R-SET-3: with the setting on, a refund lowers its category in the donut")
  func donutRefundOn() throws {
    let result = Calc.expensesByCategory(
      month: Month("2026-10")!, accounts: [pln, eur], categories: categories, txns: octoberTxns,
      currency: .PLN, converter: converter, refundsReduceSpending: true, calendar: Fx.calendar)
    let foodTotal = try #require(result.items.first)
    #expect(foodTotal.total.minorUnits == 130_00)
    #expect(foodTotal.children.first?.total.minorUnits == 80_00)
  }

  @Test("R-SET-3: with the setting off, refunds show up as income \"Refunds\"")
  func incomeIncludesRefunds() {
    let result = Calc.categoryTotals(
      kind: .income, days: Month("2026-10")!.firstDay...Day("2026-10-31")!, accounts: [pln, eur],
      categories: categories, txns: octoberTxns, currency: .PLN, converter: converter,
      refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.items.map(\.key) == [.category(salary.id), .refunds, .category(cashback.id)])
    #expect(result.items.map(\.total.minorUnits) == [5_000_00, 20_00, 1_00])
  }

  @Test("R-FX-3: an expense without a rate is skipped and counted, never taken at 1")
  func donutMissingRate() {
    let usd = Fx.account(3, .USD)
    let txns = [Fx.expense(10_00, usd, on: "2026-10-05", category: transport), Fx.expense(5_00, pln, on: "2026-10-05", category: transport)]
    let result = Calc.expensesByCategory(
      month: Month("2026-10")!, accounts: [pln, usd], categories: categories, txns: txns,
      currency: .PLN, converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.total.minorUnits == 5_00)
    #expect(result.unconverted.count == 1)
    #expect(result.unconverted.missingRates == [MissingRate(from: .USD, to: .PLN, day: Day("2026-10-05")!)])
  }

  @Test("R-FX-3: a transaction of an unknown account is skipped and counted")
  func unknownAccount() {
    let ghost = Fx.account(9, .PLN)
    let result = Calc.listTotals(
      txns: [Fx.expense(5_00, ghost, on: "2026-10-05")], accounts: [pln], currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.expense.minorUnits == 0)
    #expect(result.unconverted.unknownAccountIDs == [ghost.id])
  }

  // MARK: List totals

  @Test("R-LIST-5: footer totals — income, expense, net in the display currency")
  func listTotals() {
    let txns = Array(octoberTxns.prefix(9))
    let result = Calc.listTotals(
      txns: txns, accounts: [pln, eur], currency: .PLN, converter: converter,
      refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.count == 9)
    #expect(result.expense.minorUnits == 100_00 + 40_00 + 5_00 + 10_00 + 40_00 + 45_00 + 7_00)
    #expect(result.income.minorUnits == 1_00 + 20_00 + 5_000_00)
    #expect(result.net.minorUnits == result.income.minorUnits - result.expense.minorUnits)
    #expect(result.unconverted.isEmpty)
  }

  @Test("R-LIST-5: totals in EUR convert each day at its rate")
  func listTotalsInEUR() {
    let txns = [Fx.expense(40_00, pln, on: "2026-10-02"), Fx.expense(45_00, pln, on: "2026-10-16"), Fx.expense(3_00, eur, on: "2026-10-16")]
    let result = Calc.listTotals(
      txns: txns, accounts: [pln, eur], currency: .EUR, converter: converter,
      refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(result.expense.minorUnits == 10_00 + 10_00 + 3_00)
  }

  @Test("R-CAT-2: the category tree finds parents and children")
  func categoryTree() {
    let tree = CategoryTree(categories)
    #expect(tree.topLevelID(of: groceries.id) == food.id)
    #expect(tree.topLevelID(of: food.id) == food.id)
    #expect(tree.children(of: food.id).map(\.id) == [groceries.id, eatingOut.id])
    #expect(tree.withChildren(food.id) == [food.id, groceries.id, eatingOut.id])
  }
}
