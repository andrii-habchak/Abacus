import AbacusDomain
import Foundation
import Testing

@Suite("N5 Subscription detection (R-REC-8, R-REC-16)")
struct SubscriptionDetectorTests {
  let acc = Fx.account(1, .PLN, .card)
  let other = Fx.account(2, .PLN, .card)
  let today = Day("2026-11-03")!

  func txn(
    _ payee: String, _ amount: Int64, _ day: String, _ account: Account? = nil, type: TxnType = .expense,
    category: Int? = nil, refund: Bool = false
  ) -> Txn {
    Txn(
      type: type, occurredAt: Fx.date(day), accountID: (account ?? acc).id, amountMinor: amount,
      categoryID: category.map(Fx.id), isRefund: refund, payee: payee)
  }

  func detect(_ txns: [Txn], accounts: [Account]? = nil, matched: Set<UUID> = [], dismissed: Set<String> = []) -> [SubscriptionSuggestion] {
    SubscriptionDetector.detect(
      txns: txns, accounts: accounts ?? [acc, other], matchedTxnIDs: matched, dismissed: dismissed, today: today,
      calendar: Fx.calendar)
  }

  let monthly: [(String, Int64)] = [("2026-08-05", 49_00), ("2026-09-05", 49_00), ("2026-10-05", 49_00)]

  func rows(_ list: [(String, Int64)], _ payee: String = "Streamly", _ account: Account? = nil, type: TxnType = .expense) -> [Txn] {
    list.map { txn(payee, $0.1, $0.0, account, type: type) }
  }

  @Test("R-REC-8: three monthly rows give a suggestion with next day and medium confidence")
  func threeMonthly() {
    let s = detect(monthly.map { txn("Streamly", $0.1, $0.0, category: 7) })
    #expect(s.count == 1)
    #expect(s[0].period == .monthly)
    #expect(s[0].nextDay.string == "2026-11-05")
    #expect(s[0].confidence == .medium)
    #expect(s[0].categoryID == Fx.id(7))
    #expect(s[0].evidence.count == 3)
    #expect(s[0].amountMinor == 49_00)
  }

  @Test("R-REC-8: four rows with exact amounts are high confidence")
  func high() {
    #expect(detect(rows([("2026-07-05", 49_00)] + monthly)).first?.confidence == .high)
  }

  @Test("R-REC-8: two rows, irregular gaps, amount spread over 10 % give nothing")
  func negatives() {
    #expect(detect(rows(Array(monthly.prefix(2)))).isEmpty)
    #expect(detect(rows([("2026-06-05", 49_00), ("2026-09-20", 49_00), ("2026-10-05", 49_00)])).isEmpty)
    #expect(detect(rows([("2026-08-05", 40_00), ("2026-09-05", 49_00), ("2026-10-05", 60_00)])).isEmpty)
    #expect(detect(rows([("2026-08-05", 49_00), ("2026-09-14", 49_00), ("2026-10-05", 49_00)])).isEmpty)
  }

  @Test("R-REC-8: digits and dates in the description normalise to one key")
  func normalised() {
    let list = [
      txn("CARD *1234 Streamly 05.08", 49_00, "2026-08-05"), txn("Card *5678 STREAMLY 05.09", 49_00, "2026-09-05"),
      txn("card *9 Streamly 05.10", 49_00, "2026-10-05"),
    ]
    #expect(detect(list).count == 1)
    #expect(SubscriptionDetector.normalise("ZAKŁAD  Ubezp. #123 4") == "zaklad ubezp")
    #expect(SubscriptionDetector.key(description: "12 34", type: .expense, currency: .PLN) == nil)
  }

  @Test("R-REC-8: separate accounts give separate suggestions")
  func twoAccounts() {
    #expect(detect(rows(monthly) + rows(monthly, "Streamly", other)).count == 2)
  }

  @Test("R-REC-8: an ended pattern is not suggested")
  func ended() {
    #expect(detect(rows([("2026-02-05", 49_00), ("2026-03-05", 49_00), ("2026-04-05", 49_00)])).isEmpty)
  }

  @Test("R-REC-8: matched rows, refunds, transfers, balance corrections and archived accounts are ignored")
  func ignored() {
    let list = rows(monthly)
    #expect(detect(list, matched: [list[0].id]).isEmpty)
    #expect(detect(monthly.map { txn("Streamly", $0.1, $0.0, refund: true) }).isEmpty)
    #expect(detect(rows(monthly, type: .transfer)).isEmpty)
    var corrections = list
    for i in corrections.indices { corrections[i].isBalanceCorrection = true }
    #expect(detect(corrections).isEmpty)
    let archived = Fx.account(1, .PLN, .card, archived: true)
    #expect(detect(list, accounts: [archived]).isEmpty)
  }

  @Test("R-REC-8: yearly with three rows, weekly, income")
  func periods() {
    #expect(detect(rows([("2024-11-10", 120_00), ("2025-11-10", 120_00), ("2026-11-01", 120_00)], "Domain renewal")).first?.period == .yearly)
    let weekly = ["2026-10-13", "2026-10-20", "2026-10-27", "2026-11-03"].map { ($0, Int64(20_00)) }
    #expect(detect(rows(weekly, "Gym drop-in")).first?.period == .weekly)
    let salary: [(String, Int64)] = [("2026-08-28", 5_000_00), ("2026-09-28", 5_000_00), ("2026-10-28", 5_010_00)]
    let s = detect(rows(salary, "Employer payroll", type: .income))
    #expect(s.first?.type == .income)
    #expect(s.first?.nextDay.string == "2026-11-28")
  }

  @Test("R-REC-16: dismissed patterns are not offered; the id is stable")
  func dismissals() {
    let list = rows(monthly)
    let first = detect(list)[0]
    let id = SubscriptionDetector.dismissalID(accountID: first.accountID, key: first.key)
    #expect(id == first.id)
    #expect(detect(list, dismissed: [id]).isEmpty)
  }

  @Test("R-REC-21: 20 000 transactions are examined in under a second")
  func performance() {
    var list: [Txn] = []
    for i in 0..<20_000 {
      let day = Day("2026-01-01")!.plusDays(i % 300)
      list.append(txn("Merchant \(i % 700) shop", Int64(1_00 + i % 500), day.string))
    }
    let elapsed = ContinuousClock().measure { _ = detect(list) }
    #expect(elapsed < .seconds(1))
  }
}
