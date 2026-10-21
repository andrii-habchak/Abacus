import AbacusDomain
import AbacusFX
import AbacusFeatures
import Foundation
import Testing

/// Expected values use the preview rates (1 PLN = 11.30, 1 EUR = 48.50, 1 USD = 41.60 UAH) and
/// round each day's amounts per currency.
@Suite("Transactions · list content")
struct TransactionListContentTests {
  let reference = TransactionsReference(
    accounts: PreviewData.accounts, categories: PreviewData.categories, events: PreviewData.events)
  let converter = RateTable.transactionsPreview
  let today = PreviewData.today

  func rows(_ query: TxnQuery = .lastThirtyDays(today: PreviewData.today)) async throws -> [TxnWithLines] {
    try await TransactionsPreviewStore.preview().transactions.transactions(matching: query)
  }

  func content(
    _ rows: [TxnWithLines], in currency: Currency = .PLN, categoryFilter: Set<UUID>? = nil,
    refundsReduceSpending: Bool = false, converter: (any CurrencyConverter)? = nil
  ) -> TransactionListContent {
    TransactionListContent(
      rows: rows, reference: reference, displayCurrency: currency, converter: converter ?? self.converter,
      today: today, categoryFilter: categoryFilter, refundsReduceSpending: refundsReduceSpending)
  }

  func pln(_ text: String) -> Money { Money(Decimal(string: text)!, .PLN) }

  // MARK: Grouping (R-LIST-4)

  @Test("R-LIST-4: rows grouped by day in the fetched order, with day titles")
  func grouping() async throws {
    let list = content(try await rows())
    #expect(list.days.count == 14)
    #expect(list.days.first?.title == "Wednesday, 21 October")
    #expect(list.days.first?.rows.map(\.title) == ["Bolt", "City Pharmacy"])
    #expect(list.days.last?.day == Day("2026-09-23"))
    #expect(list.days.map(\.day) == list.days.map(\.day).sorted(by: >))
    #expect(list.days.flatMap(\.rows).count == 16)

    var oldest = TxnQuery.lastThirtyDays(today: today)
    oldest.newestFirst = false
    let ascending = content(try await rows(oldest))
    #expect(ascending.days.first?.rows.first?.title == "Auchan")
  }

  @Test("R-LIST-4: a day outside the current year shows its year")
  func dayTitleYear() async throws {
    var txn = PreviewData.txns[0]
    txn.occurredAt = Day("2025-12-29")!.date().addingTimeInterval(3600 * 9)
    let list = content([TxnWithLines(txn: txn, lines: [])])
    #expect(list.days.first?.title == "Monday, 29 December 2025")
  }

  @Test("R-LIST-4: day net in the display currency, refunds and attached records included")
  func dayNet() async throws {
    let list = content(try await rows())
    func net(_ day: String) -> String? { list.days.first { $0.day == Day(day) }?.netText }
    #expect(net("2026-10-21") == "−zł\u{00A0}54.60")
    // Orange −35.00 and the Zalando refund +120.00.
    #expect(net("2026-10-08") == "+zł\u{00A0}85.00")
    // Transfer only: neutral.
    #expect(net("2026-10-20") == "+zł\u{00A0}0.00")
    // Lidl −86.40 with +2.00 cashback.
    #expect(net("2026-10-05") == "−zł\u{00A0}84.40")
    // Café du Parc ₴440.00 → zł\u{00A0}38.94.
    #expect(net("2026-10-18") == "−zł\u{00A0}38.94")
    // The ₴22.00 transfer fee → zł\u{00A0}1.95.
    #expect(net("2026-10-15") == "−zł\u{00A0}1.95")
  }

  // MARK: Rows (R-LIST-4, R-CUR-4, R-TX-4/5/6)

  func row(_ n: Int, in list: TransactionListContent) -> TransactionListContent.Row? {
    list.days.flatMap(\.rows).first { $0.id == PreviewData.id(n) }
  }

  @Test("R-LIST-4: expense row with event badge, note · time and the charged original amount")
  func expenseRow() async throws {
    let row = try #require(row(405, in: content(try await rows())))
    #expect(row.title == "Café du Parc")
    #expect(row.badges.map(\.label) == ["Lyon trip"])
    #expect(row.subtitle == "Lunch with the team · 13:20")
    #expect(row.category == "Food › Eating out")
    #expect(row.account == "Monobank Black")
    #expect(row.amount == "−₴440.00")
    #expect(row.tone == .outflow)
    #expect(row.amountDetail == "Charged €10.00")
    #expect(row.icon.symbol == "E")
    #expect(row.icon.colorHex == "#1E9E7E")
  }

  @Test("R-TX-4: refund is green with a Refund badge; pending holds get a Pending badge")
  func badges() async throws {
    let list = content(try await rows())
    let refund = try #require(row(410, in: list))
    #expect(refund.amount == "+zł\u{00A0}120.00")
    #expect(refund.tone == .inflow)
    #expect(refund.badges.map(\.kind) == [.refund])
    #expect(refund.subtitle == "Returned jacket · 10:12")
    let pending = try #require(row(401, in: list))
    #expect(pending.badges.map(\.label) == ["Pending"])
    #expect(pending.subtitle == "15:07")
    let salary = try #require(row(408, in: list))
    #expect(salary.amount == "+€3,200.00")
    #expect(salary.tone == .inflow)
  }

  @Test("R-TX-5: transfers show From → To and the received amount in another currency")
  func transfers() async throws {
    let list = content(try await rows())
    let atm = try #require(row(403, in: list))
    #expect(atm.category == "Transfer")
    #expect(atm.account == "PKO Personal → Cash PLN")
    #expect(atm.amount == "−zł\u{00A0}500.00")
    #expect(atm.amountDetail == "→ Cash PLN")
    #expect(atm.tone == .transfer)
    #expect(atm.icon.symbol == "⇄")
    let toEUR = try #require(row(406, in: list))
    #expect(toEUR.amount == "−₴4,400.00")
    #expect(toEUR.amountDetail == "→ +€100.00")
  }

  @Test("R-TX-6: attached records are nested under their row")
  func nestedLines() async throws {
    let list = content(try await rows())
    let fee = try #require(row(406, in: list)?.lines.first)
    #expect(fee.label == "Transfer fee")
    #expect(fee.category == "Fees")
    #expect(fee.amount == "−₴22.00")
    #expect(fee.tone == .outflow)
    let cashback = try #require(row(411, in: list)?.lines.first)
    #expect(cashback.label == "Cashback")
    #expect(cashback.amount == "+zł\u{00A0}2.00")
    #expect(cashback.tone == .inflow)
  }

  // MARK: Totals (R-LIST-5)

  @Test("R-LIST-5: footer totals converted at each day's rate (refunds as income by default)")
  func totals() async throws {
    let list = content(try await rows())
    #expect(list.totals.count == 16)
    #expect(list.totals.countLabel == "16 transactions")
    // Salary €3,200 → 13,734.51; Zalando refund 120.00; cashback 2.00.
    #expect(list.totals.income == pln("13856.51"))
    // PLN 4,545.65 + ₴440 (38.94) + €14.20 (60.95) + ₴640 (56.64) + ₴22 fee (1.95).
    #expect(list.totals.expense == pln("4704.13"))
    #expect(list.totals.net == pln("9152.38"))
    #expect(list.incomeText == "zł\u{00A0}13,856.51")
    #expect(list.expenseText == "zł\u{00A0}4,704.13")
    #expect(list.netText == "+zł\u{00A0}9,152.38")
    #expect(list.totals.unconverted == 0)
  }

  @Test("R-LIST-5 / R-SET-3: with refunds reducing spending the refund leaves income")
  func refundsReduceSpending() async throws {
    let list = content(try await rows(), refundsReduceSpending: true)
    #expect(list.totals.income == pln("13736.51"))
    #expect(list.totals.expense == pln("4584.13"))
    #expect(list.totals.net == pln("9152.38"))
  }

  @Test("R-LIST-5 / D22: an income record in an expense category is a refund line")
  func refundLine() {
    let txn = Txn(
      id: PreviewData.id(900), type: .expense, occurredAt: Day("2026-10-20")!.date(),
      accountID: PreviewData.pkoPersonal.id, amountMinor: 100_00, categoryID: PreviewData.id(212),
      payee: "Shop")
    let refundLine = AttachedRecord(
      txnID: txn.id, kind: .income, categoryID: PreviewData.id(212), amountMinor: 30_00, note: "Returned item")
    let row = [TxnWithLines(txn: txn, lines: [refundLine])]
    let asIncome = content(row)
    #expect(asIncome.totals.income == pln("30"))
    #expect(asIncome.totals.expense == pln("100"))
    let reducing = content(row, refundsReduceSpending: true)
    #expect(reducing.totals.income == pln("0"))
    #expect(reducing.totals.expense == pln("70"))
  }

  @Test("R-LIST-5: an income reversal subtracts from income")
  func reversal() {
    let txn = Txn(
      type: .income, occurredAt: Day("2026-10-20")!.date(), accountID: PreviewData.pkoPersonal.id,
      amountMinor: 50_00, categoryID: PreviewData.id(251), isRefund: true, payee: "Salary correction")
    let list = content([TxnWithLines(txn: txn, lines: [])])
    #expect(list.totals.income == pln("-50"))
    #expect(list.days.first?.rows.first?.badges.map(\.label) == ["Reversal"])
    #expect(list.days.first?.rows.first?.amount == "−zł\u{00A0}50.00")
  }

  @Test("R-LIST-5: with a category filter only the matching parts count")
  func categoryFilteredTotals() async throws {
    let tree = reference.categories
    let food = tree.expanded([PreviewData.id(201)])
    let foodList = content(try await rows(TxnQuery(fromDay: Day("2026-09-22"), toDay: today, categoryIDs: [PreviewData.id(201)])), categoryFilter: food)
    #expect(foodList.totals.count == 5)
    // Groceries 17.35 + 86.40 + 142.30 and eating out ₴440 (38.94) + ₴640 (56.64); the
    // cashback line (Cashback) does not count.
    #expect(foodList.totals.expense == pln("341.63"))
    #expect(foodList.totals.income == pln("0"))

    let fees: Set<UUID> = [PreviewData.id(213)]
    let feeList = content(try await rows(TxnQuery(fromDay: Day("2026-09-22"), toDay: today, categoryIDs: fees)), categoryFilter: fees)
    #expect(feeList.totals.count == 1)
    #expect(feeList.totals.expense == pln("1.95"))
  }

  @Test("R-LIST-5 / R-FX-3: the display currency switch converts every day at its rate")
  func otherCurrency() async throws {
    let list = content(try await rows(), in: .UAH)
    // 13,856.51 PLN-equivalent income in UAH: €3,200 × 48.50 + (120 + 2) × 11.30.
    #expect(list.totals.income == Money(Decimal(string: "156578.60")!, .UAH))
    #expect(list.incomeText == "₴156,578.60")
  }

  @Test("R-FX-4: amounts without a known rate are left out and counted")
  func missingRate() async throws {
    let noRates = RateTable()
    let list = content(try await rows(), converter: noRates)
    // Only the PLN buckets convert (identity); UAH and EUR days are counted as unconverted.
    #expect(list.totals.expense == pln("4545.65"))
    #expect(list.totals.unconverted == 5)
  }

  @Test("R-LIST-5: empty list")
  func empty() {
    let list = content([])
    #expect(list.isEmpty)
    #expect(list.totals.countLabel == "0 transactions")
    #expect(list.netText == "+zł\u{00A0}0.00")
  }
}
