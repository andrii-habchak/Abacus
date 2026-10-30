import AbacusDomain
import Foundation
import Testing

/// C30, R-TX-4: a refund linked to its original always nets the original's category (a negative
/// expense on the refund's own day), whatever R-SET-3 says; an unlinked refund follows R-SET-3.
@Suite("Calc: linked refunds (R-TX-4, C30)")
struct CalcLinkedRefundTests {
  let pln = Fx.account(1, .PLN)
  let eur = Fx.account(2, .EUR)
  let travel = Fx.category(10)
  let shop = Fx.category(11)
  var categories: [AbacusDomain.Category] { [travel, shop] }
  var converter: FakeConverter {
    FakeConverter([("2026-09-01", .EUR, .PLN, "4.00"), ("2026-10-15", .EUR, .PLN, "4.50")], latest: [(.EUR, .PLN, "4.50")])
  }

  let originalID = Fx.id(500)

  /// 450 spent in September on Travel, refunded in October (linked), plus an unlinked 20 refund on Shop.
  func txns(linked: Bool = true) -> [TxnWithLines] {
    var refund = Fx.expense(450_00, pln, on: "2026-10-10", category: travel, refund: true)
    if linked { refund.txn.refundOfID = originalID }
    return [
      Fx.expense(450_00, pln, on: "2026-09-12", category: travel, id: originalID),
      refund,
      Fx.expense(20_00, pln, on: "2026-10-11", category: shop, refund: true),
    ]
  }

  @Test("the entry is a negative expense under the original's category, with the setting off and on")
  func entry() {
    for reduce in [false, true] {
      let refund = txns()[1]
      let entries = Calc.reportEntries(
        of: refund, currency: .PLN, categories: CategoryTree(categories), refundsReduceSpending: reduce,
        calendar: Fx.calendar)
      #expect(entries.count == 1)
      #expect(entries[0].kind == .expense && entries[0].key == .category(travel.id))
      #expect(entries[0].amount.minorUnits == -450_00)
      #expect(entries[0].day == Day("2026-10-10"))
    }
  }

  @Test("an unlinked refund still follows R-SET-3")
  func unlinked() {
    let refund = txns(linked: false)[1]
    let off = Calc.reportEntries(
      of: refund, currency: .PLN, categories: CategoryTree(categories), refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(off[0].kind == .income && off[0].key == .refunds)
    let on = Calc.reportEntries(
      of: refund, currency: .PLN, categories: CategoryTree(categories), refundsReduceSpending: true, calendar: Fx.calendar)
    #expect(on[0].kind == .expense && on[0].amount.minorUnits == -450_00)
  }

  @Test("donut: October's Travel is -450 (the refund month), September's stays 450; the unlinked refund follows the setting")
  func donut() {
    for reduce in [false, true] {
      let october = Calc.expensesByCategory(
        month: Month("2026-10")!, accounts: [pln], categories: categories, txns: txns(), currency: .PLN,
        converter: converter, refundsReduceSpending: reduce, calendar: Fx.calendar)
      let travelOctober = october.items.first { $0.key == .category(travel.id) }
      #expect(travelOctober?.total.minorUnits == -450_00)
      let shopOctober = october.items.first { $0.key == .category(shop.id) }
      #expect(shopOctober?.total.minorUnits == (reduce ? -20_00 : nil))
      let september = Calc.expensesByCategory(
        month: Month("2026-09")!, accounts: [pln], categories: categories, txns: txns(), currency: .PLN,
        converter: converter, refundsReduceSpending: reduce, calendar: Fx.calendar)
      #expect(september.items.first { $0.key == .category(travel.id) }?.total.minorUnits == 450_00)
    }
  }

  @Test("the income donut has no Refunds row for a linked refund")
  func incomeDonut() {
    let income = Calc.categoryTotals(
      kind: .income, days: nil, accounts: [pln], categories: categories, txns: txns(), currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(income.total.minorUnits == 20_00)  // only the unlinked one
  }

  @Test("list totals and income vs expenses count a linked refund as an expense reduction")
  func totals() {
    let list = Calc.listTotals(
      txns: txns(), accounts: [pln], categories: categories, currency: .PLN, converter: converter,
      refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(list.expense.minorUnits == 0)  // 450 − 450
    #expect(list.income.minorUnits == 20_00)
    let series = Calc.incomeExpenseSeries(
      endingAt: Month("2026-10")!, count: 2, accounts: [pln], categories: categories, txns: txns(), currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(series.months[0].expense.minorUnits == 450_00)
    #expect(series.months[1].expense.minorUnits == -450_00)
  }

  @Test("cross-currency: the refund converts at its own date's rate")
  func crossCurrency() {
    var refund = Fx.expense(100_00, eur, on: "2026-10-16", category: travel, refund: true)
    refund.txn.refundOfID = originalID
    let october = Calc.expensesByCategory(
      month: Month("2026-10")!, accounts: [pln, eur], categories: categories, txns: [refund], currency: .PLN,
      converter: converter, refundsReduceSpending: false, calendar: Fx.calendar)
    #expect(october.items.first?.total.minorUnits == -450_00)  // €100 at 4.50
  }

  @Test("budget: a linked refund reduces the original category's spending in the refund's month")
  func budget() throws {
    let plan = BudgetPlan(id: Fx.id(901), effectiveMonth: "2026-01")
    let allocation = BudgetAllocation(id: Fx.id(910), planID: plan.id, categoryID: travel.id, limitMinor: 1_000_00, currency: .PLN)
    func spent(_ list: [TxnWithLines], month: String, reduce: Bool) throws -> Int64 {
      let status = try #require(
        Calc.budgetStatus(
          month: Month(month)!, plans: [plan], allocations: [allocation], accounts: [pln], categories: categories,
          txns: list, converter: converter, refundsReduceSpending: reduce, currency: .PLN, today: Day("2026-10-21")!,
          calendar: Fx.calendar))
      return try #require(status.lines.first).spent.minorUnits
    }
    for reduce in [false, true] {
      #expect(try spent(txns(), month: "2026-10", reduce: reduce) == -450_00)
      #expect(try spent(txns(), month: "2026-09", reduce: reduce) == 450_00)
      #expect(try spent(txns(linked: false), month: "2026-10", reduce: reduce) == (reduce ? -450_00 : 0))
    }
  }
}
