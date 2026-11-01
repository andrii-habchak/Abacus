import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// C40: changing the From and To of a transfer row in the import review, what the row is related
/// to, and the counterpart search over an explicit date window (synthetic PKO rows).
@Suite("Import transfer popup (C40)")
struct ImportTransferEditTests {
  typealias F = PipelineFixture
  typealias Env = TransferCounterpartTests.Env

  static let savings = Account(
    id: F.id(31), name: "Savings PLN", currency: .PLN, kind: .bank, openingDate: F.date("2026-01-01", 0),
    iban: "77 7777 7777 7777 7777 7777 7777")
  static let joint = Account(id: F.id(32), name: "Joint PLN", currency: .PLN, kind: .bank, openingDate: F.date("2026-01-01", 0))
  static let cash = Account(id: F.id(33), name: "Cash PLN", currency: .PLN, kind: .cash, openingDate: F.date("2026-01-01", 0))

  static func seed(_ env: Env) async throws {
    try await env.seed()
    for account in [savings, joint, cash] { try await env.accounts.save(account) }
  }

  /// A PLN statement row: money out to the savings account (found by its number).
  static func toSavings(_ day: String, _ amount: String = "100.00") -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-\#(amount)","PLN","+100.00","Rachunek odbiorcy: 77 7777 7777 7777 7777 7777 7777","Nazwa odbiorcy: JAN PRZYKLAD","Tytuł: OSZCZEDNOSCI","","","""#
  }

  /// A PLN statement row: money out to a shop (an expense).
  static func toShop(_ day: String, _ amount: String = "40.00") -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-\#(amount)","PLN","+100.00","Rachunek odbiorcy: 11 1111 1111 1111 1111 1111 1111","Nazwa odbiorcy: SKLEP","Tytuł: ZAKUPY","","","""#
  }

  static func transferRow(_ preview: ImportPreview) throws -> PreviewRow {
    try #require(preview.rows.first { $0.type == .transfer })
  }

  @Test("a transfer the file gives shows its sides and why it is a transfer; both sides can change")
  func fileTransferBothSides() async throws {
    let env = try Env()
    try await Self.seed(env)
    var preview = try await env.pln([Self.toSavings("2026-03-10")])
    let row = try Self.transferRow(preview)
    let sides = try #require(preview.transferSides(forRow: row.id))
    #expect(sides.from == .existing(F.pkoAccount.id) && sides.to == .existing(Self.savings.id))
    #expect(sides.statementEnd == .from && sides.statementCurrency == .PLN)
    #expect(sides.relations.map(\.kind) == [.accountNumber])
    #expect(Set(preview.statementAccountOptions(forRow: row.id).map(\.id)) == [F.pkoAccount.id, Self.savings.id, Self.joint.id, Self.cash.id])

    let r1 = preview.setTransferAccounts(from: Self.joint.id, to: Self.cash.id, forRow: row.id)
    #expect(r1 == .done)
    let changed = try #require(preview.row(row.id))
    #expect(changed.account == .existing(Self.joint.id) && changed.counterAccount == .existing(Self.cash.id))
    #expect(changed.counterAmountMinor == 100_00)
    #expect(preview.transferSides(forRow: row.id)?.relations.map(\.kind) == [.chosen])
    #expect(preview.canCommit)

    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.type == .transfer && transfer.accountID == Self.joint.id && transfer.toAccountID == Self.cash.id)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 100_00)
  }

  @Test("the statement side stays in the statement's currency; From and To must differ")
  func refusals() async throws {
    let env = try Env()
    try await Self.seed(env)
    var preview = try await env.pln([Self.toSavings("2026-03-10")])
    let row = try Self.transferRow(preview)
    guard case .refused = preview.setTransferAccounts(from: F.pkoUSD.id, to: Self.savings.id, forRow: row.id) else {
      Issue.record("a USD account was accepted for a PLN statement")
      return
    }
    guard case .refused = preview.setTransferAccounts(from: Self.cash.id, to: Self.cash.id, forRow: row.id) else {
      Issue.record("the same account on both sides was accepted")
      return
    }
    #expect(preview.row(row.id)?.account == .existing(F.pkoAccount.id))
    #expect(preview.row(row.id)?.counterAccount == .existing(Self.savings.id))
    let r2 = preview.setTransferAccounts(from: F.pkoAccount.id, to: Self.savings.id, forRow: row.id)
    #expect(r2 == .done)
  }

  @Test("the other side in another currency needs its amount; the found or typed amount completes it")
  func otherCurrencyNeedsCounterpart() async throws {
    let env = try Env()
    try await Self.seed(env)
    var preview = try await env.pln([Self.toSavings("2026-03-10")])
    let row = try Self.transferRow(preview)
    let r3 = preview.setTransferAccounts(from: F.pkoAccount.id, to: F.pkoUSD.id, forRow: row.id)
    #expect(r3 == .needsCounterpart(F.pkoUSD.id))
    #expect(preview.row(row.id)?.counterAccount == .existing(Self.savings.id))
    #expect(preview.counterpartProbe(forRow: row.id, to: F.pkoUSD.id) != nil)
    let r4 = preview.setTransfer(
      toAccount: F.pkoUSD.id, counterpart: TransferCounterpart(accountID: F.pkoUSD.id, kind: .manual, amountMinor: 25_00),
      forRow: row.id)
    #expect(r4)
    let changed = try #require(preview.row(row.id))
    #expect(changed.type == .transfer && changed.counterAccount == .existing(F.pkoUSD.id) && changed.counterAmountMinor == 25_00)
    #expect(preview.transferRelations(forRow: row.id).map(\.kind) == [.typedAmount, .chosen])
    #expect(preview.canCommit)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.accountID == F.pkoAccount.id && transfer.toAccountID == F.pkoUSD.id && transfer.toAmountMinor == 25_00)
  }

  @Test("an expense the user made a transfer moves to another account; a statement side change keeps it")
  func userTransferChanges() async throws {
    let env = try Env()
    try await Self.seed(env)
    var preview = try await env.pln([Self.toShop("2026-03-10")])
    let id = try #require(preview.rows.first).id
    #expect(!preview.canEditTransfer(row: id))
    let r5 = preview.setTransfer(toAccount: Self.savings.id, forRow: id)
    #expect(r5)
    #expect(preview.canEditTransfer(row: id))
    let r6 = preview.setTransferAccounts(from: Self.joint.id, to: Self.cash.id, forRow: id)
    #expect(r6 == .done)
    let row = try #require(preview.row(id))
    #expect(row.account == .existing(Self.joint.id) && row.counterAccount == .existing(Self.cash.id))
    #expect(preview.transferRelations(forRow: id).map(\.kind) == [.chosen])
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.accountID == Self.joint.id && transfer.toAccountID == Self.cash.id && transfer.amountMinor == 40_00)
  }

  @Test("a transfer that takes over a found transaction names it as related")
  func absorbedRelation() async throws {
    let env = try Env()
    try await Self.seed(env)
    let found = try await env.plnTxn("2026-03-11", 398_00)
    var preview = try await env.usd([TransferCounterpartTests.usdOut("2026-03-10")])
    let row = try TransferCounterpartTests.reviewRow(preview)
    let options = try await env.pipeline.counterpartOptions(for: preview, row: row.id, to: F.pkoAccount.id)
    let option = try #require(options.first)
    let counterpart = TransferCounterpart(
      accountID: F.pkoAccount.id, kind: .existing(option.candidate.txn), amountMinor: option.amountMinor)
    let applied = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: counterpart, forRow: row.id)
    #expect(applied)
    let sides = try #require(preview.transferSides(forRow: row.id))
    #expect(sides.statementEnd == .from && sides.to == .existing(F.pkoAccount.id))
    #expect(sides.relations.first?.kind == .absorbs && sides.relations.first?.txn?.id == found.id)
    // The statement side of a USD statement only offers USD accounts.
    #expect(preview.statementAccountOptions(forRow: row.id).map(\.id) == [F.pkoUSD.id])
  }

  @Test("an explicit window with an empty search lists every transaction of the account; same direction is marked")
  func explicitWindowListsAll() async throws {
    let env = try Env()
    try await Self.seed(env)
    let income = try await env.plnTxn("2026-03-10", 398_00)
    let expense = try await env.plnTxn("2026-03-10", 12_00, type: .expense, payee: "BAKERY")
    try await env.plnTxn("2026-03-12", 50_00, payee: "NEXT DAY")
    let preview = try await env.usd([TransferCounterpartTests.usdOut("2026-03-10")])
    let row = try TransferCounterpartTests.reviewRow(preview)
    let day = Day("2026-03-10")!
    let options = try await env.pipeline.counterpartOptions(
      for: preview, row: row.id, to: F.pkoAccount.id, from: day, through: day)
    #expect(options.map(\.id) == [income.id, expense.id])
    #expect(options[0].isUsable && !options[1].isUsable && options[1].isSameDirection)
    let searched = try await env.pipeline.counterpartOptions(
      for: preview, row: row.id, to: F.pkoAccount.id, from: day, through: day.adding(days: 3, calendar: F.calendar),
      matching: "next")
    #expect(searched.map(\.candidate.txn.payee) == ["NEXT DAY"])
    let dayList = try await env.pipeline.transactions(onAccount: F.pkoAccount.id, day: day)
    #expect(Set(dayList.map(\.txn.id)) == [income.id, expense.id])
  }
}
