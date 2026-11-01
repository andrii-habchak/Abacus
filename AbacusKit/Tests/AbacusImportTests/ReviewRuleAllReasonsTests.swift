import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C46: every Needs review reason whose resolution a rule can express proposes that rule (C42 did
/// it for "Unknown operation type" only): a transfer to an own account in another currency
/// (amount unknown) and an unpaired transfer half. The rule is saved on commit and, on the next
/// import, a matching rule marks the card's suggestion (those reasons are not resolved silently:
/// the amount on the other account, or the missing half, still needs the user). Synthetic data only.
@Suite("Rules from every review reason (C46)")
struct ReviewRuleAllReasonsTests {
  typealias F = PipelineFixture

  static let gifts = AbacusDomain.Category(id: F.id(50), name: "Gifts", kind: .expense)

  /// Money in on the PLN account from the own USD account (found by its number); the PLN amount is
  /// known, the USD amount is not → "Transfer to an own account in another currency".
  private static func plnIn(_ day: String, _ amount: String, ref: String) -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 55 5555 5555 5555 5555 5555 5555","Nazwa nadawcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
  }

  private func pkoDB() -> FakeDB {
    let db = FakeDB()
    db.accounts = [F.pkoAccount, F.pkoUSD]
    db.categories = [F.groceries, F.salary]
    return db
  }

  private func pln(_ db: FakeDB, _ rows: [String], file: String = "pln.csv") async throws -> ImportPreview {
    try await db.pipeline().preview(data: F.pko(rows), fileName: file, targetAccountID: F.pkoAccount.id)
  }

  // MARK: Transfer to an own account in another currency

  @Test("transfer amount unknown, resolved as a transfer with the other side: a transfer rule is proposed, saved and suggests the transfer next time")
  func transferAmountUnknownTransfer() async throws {
    let db = pkoDB()
    var first = try await pln(db, [Self.plnIn("2026-02-10", "400.00", ref: "1")])
    let id = try #require(first.rows.first).id
    #expect(first.row(id)?.review?.reason == .transferAmountUnknown)
    let counterpart = TransferCounterpart(accountID: F.pkoUSD.id, kind: .estimated(rate: Decimal(string: "0.25")!), amountMinor: 100_00)
    let applied = first.setTransfer(toAccount: F.pkoUSD.id, counterpart: counterpart, forRow: id)
    #expect(applied)
    let resolved = try #require(first.row(id))
    #expect(resolved.learnedAction == .transfer(F.pkoUSD.id))
    #expect(resolved.rulePattern == "jan przyklad")
    #expect(first.rulesToSave == [RuleProposal(pattern: "jan przyklad", action: .transfer(F.pkoUSD.id), rowCount: 1)])

    try await db.pipeline().commit(first)
    let rule = try #require(db.rules.first)
    #expect(rule.action == .transfer && rule.transferAccountID == F.pkoUSD.id && rule.pattern == "jan przyklad")
    #expect(rule.origin == .imported)

    // Next import: the card is still there (the USD amount is unknown again), but the rule marks
    // "Transfer to my account" with that account as the suggestion.
    var second = try await pln(db, [Self.plnIn("2026-03-10", "800.00", ref: "2")], file: "pln2.csv")
    let next = try #require(second.rows.first)
    #expect(next.review?.reason == .transferAmountUnknown)
    #expect(next.review?.suggested == .transfer(accountID: F.pkoUSD.id))
    #expect(next.review?.suggestedByRule == rule.id)
    // "Use suggestions" cannot apply a transfer whose amount is unknown: the card stays open
    // without an error (the user gives the other side).
    second.acceptSuggestedReviewChoices()
    #expect(second.row(next.id)?.review?.choice == nil)
    #expect(second.issues.isEmpty)
    #expect(second.rulesToSave.isEmpty)
  }

  @Test("transfer amount unknown, recorded as income with a category: a category rule is proposed and suggests it next time")
  func transferAmountUnknownRecord() async throws {
    let db = pkoDB()
    var first = try await pln(db, [Self.plnIn("2026-02-10", "400.00", ref: "1")])
    let id = try #require(first.rows.first).id
    first.setReviewChoice(.record(.income, categoryID: F.salary.id), forRow: id)
    #expect(first.rulesToSave == [RuleProposal(pattern: "jan przyklad", categoryID: F.salary.id, rowCount: 1)])
    try await db.pipeline().commit(first)
    #expect(db.rules.first?.categoryID == F.salary.id)

    var second = try await pln(db, [Self.plnIn("2026-03-10", "800.00", ref: "2")], file: "pln2.csv")
    let next = try #require(second.rows.first)
    #expect(next.review?.suggested == .record(.income, categoryID: F.salary.id))
    second.acceptSuggestedReviewChoices()
    #expect(second.row(next.id)?.category == .existing(F.salary.id))
    #expect(second.row(next.id)?.type == .income)
    // Applied by an existing rule: nothing new to save.
    #expect(second.rulesToSave.isEmpty)
  }

  @Test("transfer amount unknown, sent to a debt: a debt rule is proposed")
  func transferAmountUnknownDebt() async throws {
    let db = pkoDB()
    var first = try await pln(db, [Self.plnIn("2026-02-10", "400.00", ref: "1")])
    let id = try #require(first.rows.first).id
    first.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .PLN)), forRow: id)
    #expect(first.rulesToSave == [RuleProposal(pattern: "jan przyklad", action: .debt(person: "Ann"), rowCount: 1)])
  }

  // MARK: Unpaired transfer half

  private static func saldoFriend(_ id: Int, _ day: String, _ amount: String) -> [String] {
    [
      "\(id),\(day)T10:00:00,To a friend,Bank UAH,BANK_ACCOUNTS,0,CREDIT,\(amount),UAH",
      "\(id),\(day)T10:00:00,Money on the way,Money on the way,MONEY_ON_THE_WAY,0,DEBIT,\(amount),UAH",
    ]
  }

  @Test("unpaired half recorded as an expense with a category: a category rule is proposed, saved and suggested next import")
  func unpairedHalfRecord() async throws {
    let db = FakeDB()
    db.categories = [Self.gifts]
    var first = try await db.pipeline().preview(data: F.saldo(Self.saldoFriend(3, "2025-05-03", "200.00")), fileName: "s1.csv")
    let row = try #require(first.rows.first { $0.review != nil })
    #expect(row.review?.reason == .unpairedTransferHalf(.outgoing))
    first.setReviewChoice(.record(.expense, categoryID: Self.gifts.id), forRow: row.id)
    #expect(first.row(row.id)?.learnedAction == .category(Self.gifts.id))
    #expect(first.rulesToSave == [RuleProposal(pattern: "to a friend", categoryID: Self.gifts.id, rowCount: 1)])
    try await db.pipeline().commit(first)
    #expect(db.rules.first?.categoryID == Self.gifts.id && db.rules.first?.pattern == "to a friend")

    let second = try await db.pipeline().preview(data: F.saldo(Self.saldoFriend(9, "2025-06-20", "50.00")), fileName: "s2.csv")
    let next = try #require(second.rows.first { $0.review != nil })
    #expect(next.review?.suggested == .record(.expense, categoryID: Self.gifts.id))
  }

  @Test("unpaired half sent to a debt proposes a debt rule; pairing or skipping proposes nothing")
  func unpairedHalfDebtAndPair() async throws {
    let db = FakeDB()
    db.categories = [Self.gifts]
    var preview = try await db.pipeline().preview(data: F.saldo(Self.saldoFriend(3, "2025-05-03", "200.00")), fileName: "s1.csv")
    let row = try #require(preview.rows.first { $0.review != nil })
    preview.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .UAH)), forRow: row.id)
    #expect(preview.rulesToSave == [RuleProposal(pattern: "to a friend", action: .debt(person: "Ann"), rowCount: 1)])
    preview.setReviewChoice(.skip, forRow: row.id)
    #expect(preview.rulesToSave.isEmpty && preview.row(row.id)?.learnedAction == nil)
    preview.setReviewChoice(.record(.expense, categoryID: nil), forRow: row.id)
    #expect(preview.rulesToSave.isEmpty)
  }

  // MARK: Unknown operation type, pre-filled suggestion

  @Test("an unknown type accepted with Use suggestions, then given a category, still proposes the rule")
  func suggestedThenCategory() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries]
    let row = #""2026-02-10","2026-02-10","Operacja specjalna","-30.00","PLN","+1000.00","Tytuł: ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH","","","","","""#
    var preview = try await db.pipeline().preview(data: F.pko([row]), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let id = try #require(preview.rows.first).id
    preview.acceptSuggestedReviewChoices()
    #expect(preview.row(id)?.review?.choice == .record(.expense, categoryID: nil))
    #expect(preview.rulesToSave.isEmpty)
    preview.setReviewChoice(.record(.expense, categoryID: F.groceries.id), forRow: id)
    #expect(preview.rulesToSave == [RuleProposal(pattern: "zaklad ubezpieczen spolecznych", categoryID: F.groceries.id, rowCount: 1)])
  }
}
