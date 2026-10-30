import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// C35: an incoming import row that looks like the refund of an expense is offered as one, on the
/// SQLite store with synthetic PKO rows (existing expenses, and expenses of the same file).
@Suite("Import refund suggestions (C35)")
struct RefundSuggestionTests {
  typealias F = PipelineFixture

  struct Env {
    let database: any DatabaseWriter

    init() throws { database = try AbacusDatabase.open(at: nil) }

    var calendar: Calendar { F.calendar }
    var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: calendar) }
    var refunds: SQLiteRefundRepository { SQLiteRefundRepository(database: database, calendar: calendar) }

    var pipeline: ImportPipeline {
      ImportPipeline(
        store: SQLiteImportStore(database: database, calendar: calendar), accounts: accounts,
        categories: SQLiteCategoryRepository(database: database), events: SQLiteEventRepository(database: database),
        rules: SQLiteRuleRepository(database: database, calendar: calendar), calendar: calendar, refunds: refunds)
    }

    /// The PKO account and the categories every test uses.
    func seed() async throws {
      try await accounts.save(F.pkoAccount)
      try await SQLiteCategoryRepository(database: database).save(F.groceries)
      try await SQLiteCategoryRepository(database: database).save(F.taxi)
    }

    @discardableResult
    func expense(
      _ day: String, _ minor: Int64, _ payee: String = "GROCERY EXAMPLE", category: AbacusDomain.Category? = F.groceries,
      account: Account.ID = F.pkoAccount.id
    ) async throws -> Txn {
      let txn = Txn(
        type: .expense, occurredAt: F.date(day), accountID: account, amountMinor: minor, categoryID: category?.id,
        payee: payee, source: .manual)
      try await txns.save(txn, lines: [])
      return txn
    }

    func preview(_ rows: [String]) async throws -> ImportPreview {
      try await pipeline.preview(data: F.pko(rows), fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    }

    func allTxns() async throws -> [Txn] { try await txns.transactions(matching: TxnQuery()).map(\.txn) }

    func txn(_ id: Txn.ID) async throws -> Txn? { try await allTxns().first { $0.id == id } }

    func balance() async throws -> Int64 {
      try await accounts.balances(asOf: Day("2100-01-01")!)[F.pkoAccount.id] ?? 0
    }
  }

  /// A card payment (`-45.00`) or a card refund (`+45.00`).
  static func card(_ day: String, _ amount: String, _ merchant: String = "GROCERY EXAMPLE", ref: String = "1") -> String {
    #""\#(day)","\#(day)","Płatność kartą","\#(amount)","PLN","+100.00","Tytuł:  0000000000000000000000\#(ref) ","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","Data wykonania operacji: \#(day)","Oryginalna kwota operacji: \#(amount.dropFirst())","Numer karty: 000000******0000","""#
  }

  /// An incoming bank transfer (an income row).
  static func income(_ day: String, _ amount: String, _ name: String = "GROCERY EXAMPLE", ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 11 1111 1111 1111 1111 1111 1111","Nazwa nadawcy: \#(name)","Tytuł: ZWROT \#(ref)","","","""#
  }

  static func refundRow(_ preview: ImportPreview) throws -> PreviewRow {
    try #require(preview.rows.first { $0.canBeRefund })
  }

  // MARK: Offered or not

  @Test("a card refund with the same description and amount as an earlier expense is offered as its refund")
  func offeredForCardRefund() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    let preview = try await env.preview([Self.card("2026-01-12", "+45.00")])
    let row = try Self.refundRow(preview)
    #expect(row.refundOffer?.ref == .existing(original.id))
    #expect(row.refundOffer?.categoryID == F.groceries.id)
    #expect(row.refundOf == nil && !row.refundDeclined)
    #expect(preview.refundProbe(forRow: row.id)?.amountMinor == 45_00)
  }

  @Test("an incoming transfer (income row) is offered too, and the description match ignores case")
  func offeredForIncomeRow() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    let preview = try await env.preview([Self.income("2026-01-12", "45.00", "grocery example")])
    #expect(try Self.refundRow(preview).refundOffer?.ref == .existing(original.id))
  }

  @Test("no suggestion: amount differs, description differs, expense too old or after the refund")
  func notOffered() async throws {
    let env = try Env()
    try await env.seed()
    try await env.expense("2026-01-05", 45_00)
    // Another amount.
    var preview = try await env.preview([Self.card("2026-01-12", "+44.00")])
    #expect(try Self.refundRow(preview).refundOffer == nil)
    // Another description.
    preview = try await env.preview([Self.card("2026-01-12", "+45.00", "OTHER SHOP")])
    #expect(try Self.refundRow(preview).refundOffer == nil)
    // More than 60 days after the purchase.
    preview = try await env.preview([Self.card("2026-04-10", "+45.00")])
    #expect(try Self.refundRow(preview).refundOffer == nil)
    // Before the purchase.
    preview = try await env.preview([Self.card("2026-01-02", "+45.00")])
    #expect(try Self.refundRow(preview).refundOffer == nil)
  }

  @Test("an expense that is already fully refunded is not offered; a partly refunded one needs the remaining amount")
  func fullyRefunded() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    let earlier = Txn(
      type: .income, occurredAt: F.date("2026-01-08"), accountID: F.pkoAccount.id, amountMinor: 45_00, payee: "GROCERY EXAMPLE")
    try await env.txns.save(earlier, lines: [])
    try await env.refunds.linkRefund(earlier.id, to: original.id)
    var preview = try await env.preview([Self.card("2026-01-12", "+45.00")])
    #expect(try Self.refundRow(preview).refundOffer == nil)

    // 20.00 of a second expense is refunded: 25.00 remains and is what the row must equal.
    let second = try await env.expense("2026-01-06", 45_00, "SECOND SHOP")
    let part = Txn(
      type: .income, occurredAt: F.date("2026-01-09"), accountID: F.pkoAccount.id, amountMinor: 20_00, payee: "SECOND SHOP")
    try await env.txns.save(part, lines: [])
    try await env.refunds.linkRefund(part.id, to: second.id)
    preview = try await env.preview([Self.card("2026-01-12", "+25.00", "SECOND SHOP")])
    #expect(try Self.refundRow(preview).refundOffer?.ref == .existing(second.id))
    preview = try await env.preview([Self.card("2026-01-12", "+45.00", "SECOND SHOP")])
    #expect(try Self.refundRow(preview).refundOffer == nil)
  }

  @Test("transfers, outgoing rows and rows that already exist are never offered")
  func ineligibleRows() async throws {
    let env = try Env()
    try await env.seed()
    try await env.accounts.save(
      Account(id: F.id(7), name: "Savings", currency: .PLN, kind: .savings, openingDate: F.date("2026-01-01", 0)))
    try await env.expense("2026-01-05", 45_00)
    var preview = try await env.preview([Self.card("2026-01-12", "+45.00"), Self.card("2026-01-12", "-45.00", ref: "2")])
    let refund = try Self.refundRow(preview)
    #expect(preview.rows.filter(\.canBeRefund).count == 1)
    #expect(refund.refundOffer != nil)
    // The same row made a transfer to another account: not a refund any more.
    preview.setTransfer(toAccount: F.id(7), forRow: refund.id)
    #expect(preview.row(refund.id)?.canBeRefund == false)
    #expect(preview.row(refund.id)?.refundOffer == nil)
    // A debt record is not offered either.
    var debtPreview = try await env.preview([Self.income("2026-01-12", "45.00")])
    let id = try #require(debtPreview.rows.first?.id)
    let choice = try #require(debtPreview.suggestedDebtChoice(forRow: id, person: "Ann"))
    debtPreview.setDebt(choice, forRow: id)
    #expect(debtPreview.row(id)?.canBeRefund == false)
    // Once imported, the same file offers nothing (the row is already imported).
    let committed = try await env.preview([Self.card("2026-01-12", "+45.00")])
    try await env.pipeline.commit(committed)
    preview = try await env.preview([Self.card("2026-01-12", "+45.00")])
    #expect(preview.rows.first?.status == .alreadyImported)
    #expect(preview.rows.first?.canBeRefund == false && preview.rows.first?.refundOffer == nil)
  }

  // MARK: Accept, commit, undo

  @Test("Accept: the committed row is an expense refund linked to the expense, in its category, and the balance is unchanged")
  func acceptCommits() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    let before = try await env.balance()
    var preview = try await env.preview([Self.income("2026-01-12", "45.00")])
    let row = try Self.refundRow(preview)
    let offer = try #require(row.refundOffer)
    #expect(row.needsCategory)
    let ok1 = preview.acceptRefund(offer, forRow: row.id)
    #expect(ok1)
    let accepted = try #require(preview.row(row.id))
    #expect(accepted.refundOf?.ref == .existing(original.id) && accepted.refundOffer == nil)
    #expect(accepted.type == .expense && accepted.category == .existing(F.groceries.id))
    #expect(!accepted.needsCategory && preview.uncategorisedCount == 0)
    #expect(accepted.categorySource == .notApplicable && accepted.rulePattern == nil)

    let summary = try await env.pipeline.commit(preview)
    #expect(summary.refundsLinked == 1)
    #expect(summary.lines.contains { $0.contains("linked as the refund") })
    let imported = try #require(try await env.allTxns().first { $0.id != original.id })
    #expect(imported.type == .expense && imported.isRefund)
    #expect(imported.refundOfID == original.id && imported.categoryID == F.groceries.id)
    #expect(imported.amountMinor == 45_00)
    // Money still comes in: the balance rises by the refund, like an income would.
    #expect(try await env.balance() == before + 45_00)
    // The link shows from both sides.
    let links = try await env.refunds.refundLinks(for: [original.id, imported.id])
    #expect(links.refundsByOriginal[original.id]?.map(\.refundID) == [imported.id])
    #expect(links.originalByRefund[imported.id]?.originalID == original.id)

    // The same file again: already imported, nothing offered, nothing to commit.
    let again = try await env.preview([Self.income("2026-01-12", "45.00")])
    #expect(again.rows.first?.status == .alreadyImported && again.transactionsToCreate == 0)
  }

  @Test("Accept on a card refund row: it stays an expense refund and takes the expense's category, not the file's or a rule's")
  func acceptCardRefundKeepsOriginalCategory() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00, category: F.taxi)
    var preview = try await env.preview([Self.card("2026-01-12", "+45.00")])
    let row = try Self.refundRow(preview)
    preview.setCategory(F.groceries.id, forRow: row.id)
    #expect(preview.row(row.id)?.category == .existing(F.groceries.id))
    #expect(preview.rulesToSave.count == 1)
    let ok2 = preview.acceptRefund(try #require(preview.row(row.id)?.refundOffer), forRow: row.id)
    #expect(ok2)
    #expect(preview.row(row.id)?.category == .existing(F.taxi.id))
    // The category pick is no longer a rule to learn.
    #expect(preview.rulesToSave.isEmpty && preview.row(row.id)?.rulePattern == nil)
    try await env.pipeline.commit(preview)
    let imported = try #require(try await env.allTxns().first { $0.id != original.id })
    #expect(imported.refundOfID == original.id && imported.categoryID == F.taxi.id && imported.isRefund)
    #expect(try await env.rulesCount() == 0)
  }

  @Test("undo of the import removes the refund and leaves the expense; undo of the expense's batch unlinks a refund imported later")
  func undoSemantics() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    var preview = try await env.preview([Self.income("2026-01-12", "45.00")])
    let row = try Self.refundRow(preview)
    preview.acceptRefund(try #require(row.refundOffer), forRow: row.id)
    let summary = try await env.pipeline.commit(preview)
    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().map(\.id) == [original.id])
    #expect(try await env.refunds.refundLinks(for: [original.id]).refundsByOriginal.isEmpty)
    // The undone file can be imported again and offered again.
    let again = try await env.preview([Self.income("2026-01-12", "45.00")])
    #expect(try Self.refundRow(again).refundOffer?.ref == .existing(original.id))

    // An expense imported in batch 1, its refund (same description) in batch 2: undoing batch 1
    // removes the expense and unlinks the refund, which keeps its category.
    let first = try await env.pipeline.commit(try await env.preview([Self.card("2026-02-01", "-30.00", "SHOP TWO", ref: "5")]))
    var second = try await env.preview([Self.income("2026-02-05", "30.00", "SHOP TWO", ref: "6")])
    let secondRow = try Self.refundRow(second)
    let offer = try #require(secondRow.refundOffer)
    second.setCategory(F.taxi.id, forRow: secondRow.id)
    second.acceptRefund(offer, forRow: secondRow.id)
    try await env.pipeline.commit(second)
    let linked = try #require(try await env.allTxns().first { $0.refundOfID != nil })
    #expect(linked.categoryID == offer.categoryID)
    try await env.pipeline.undo(first.batch.id)
    let orphan = try #require(try await env.txn(linked.id))
    #expect(orphan.refundOfID == nil && orphan.isRefund && orphan.type == .expense)
  }

  // MARK: Not a refund, choose another

  @Test("Not a refund: an ordinary income row that needs a category; the suggestion does not come back")
  func declined() async throws {
    let env = try Env()
    try await env.seed()
    try await env.expense("2026-01-05", 45_00)
    var preview = try await env.preview([Self.income("2026-01-12", "45.00")])
    let row = try Self.refundRow(preview)
    preview.declineRefund(forRow: row.id)
    #expect(preview.row(row.id)?.refundDeclined == true && preview.row(row.id)?.refundOffer == nil)
    #expect(preview.row(row.id)?.type == .income)
    // Other edits recompute without bringing it back.
    preview.setCategory(nil, forRow: row.id)
    preview.setCategory(F.groceries.id, forRow: row.id)
    #expect(preview.row(row.id)?.refundOffer == nil && preview.row(row.id)?.refundOf == nil)
    // A declined row cannot be accepted by mistake of an old offer? Accept still works explicitly after a reset.
    preview.resetRefund(forRow: row.id)
    #expect(preview.row(row.id)?.refundOffer != nil)
    preview.declineRefund(forRow: row.id)
    try await env.pipeline.commit(preview)
    let imported = try #require(try await env.allTxns().first { $0.type == .income })
    #expect(imported.refundOfID == nil && !imported.isRefund && imported.categoryID == F.groceries.id)
  }

  @Test("Choose another: the options list expenses of the account, the user can accept one the importer did not suggest")
  func chooseAnother() async throws {
    let env = try Env()
    try await env.seed()
    let best = try await env.expense("2026-01-05", 45_00)
    let other = try await env.expense("2026-01-08", 60_00, "ANOTHER SHOP", category: F.taxi)
    // The refund is 40.00: nothing is suggested, but both expenses can take it.
    var preview = try await env.preview([Self.income("2026-01-12", "40.00", "SOMEONE ELSE")])
    let row = try Self.refundRow(preview)
    #expect(row.refundOffer == nil)
    let options = try await env.pipeline.refundOptions(for: preview, row: row.id)
    #expect(Set(options.map(\.ref)) == [.existing(best.id), .existing(other.id)])
    // Searching drops the date window and filters by description.
    let found = try await env.pipeline.refundOptions(for: preview, row: row.id, matching: "another")
    #expect(found.map(\.ref) == [.existing(other.id)])
    let choice = try #require(found.first)
    let ok3 = preview.acceptRefund(choice, forRow: row.id)
    #expect(ok3)
    #expect(preview.row(row.id)?.category == .existing(F.taxi.id))
    try await env.pipeline.commit(preview)
    let imported = try #require(try await env.allTxns().first { $0.refundOfID != nil })
    #expect(imported.refundOfID == other.id && imported.categoryID == F.taxi.id && imported.amountMinor == 40_00)
  }

  @Test("an option that would exceed the expense, or is in another currency, is refused")
  func capAndCurrency() async throws {
    let env = try Env()
    try await env.seed()
    let original = try await env.expense("2026-01-05", 45_00)
    var preview = try await env.preview([
      Self.income("2026-01-12", "30.00", "GROCERY EXAMPLE", ref: "1"), Self.income("2026-01-13", "30.00", "GROCERY EXAMPLE", ref: "2"),
    ])
    let rows = preview.rows.filter(\.canBeRefund)
    #expect(rows.count == 2)
    let choice = ImportRefundOriginal(
      ref: .existing(original.id), payee: "GROCERY EXAMPLE", occurredAt: original.occurredAt, amountMinor: 45_00,
      currency: .PLN, remainingMinor: 45_00, categoryID: F.groceries.id)
    let ok4 = preview.acceptRefund(choice, forRow: rows[0].id)
    #expect(ok4)
    // 30 + 30 > 45: the second is refused, the first stays.
    let ok5 = preview.acceptRefund(choice, forRow: rows[1].id)
    #expect(!ok5)
    #expect(preview.row(rows[0].id)?.refundOf != nil && preview.row(rows[1].id)?.refundOf == nil)
    var euro = choice
    euro.currency = .EUR
    let ok6 = preview.acceptRefund(euro, forRow: rows[1].id)
    #expect(!ok6)
    // A row cannot be accepted as a refund of an expense that does not exist.
    var ghost = choice
    ghost.ref = .row("nope")
    let ok7 = preview.acceptRefund(ghost, forRow: rows[1].id)
    #expect(!ok7)
  }

  // MARK: Rows of the same file

  @Test("a purchase and its refund in one file: the refund is offered, linked after the commit, in the purchase's category")
  func sameFile() async throws {
    let env = try Env()
    try await env.seed()
    // Refund listed before the purchase: the order of rows does not matter.
    let rows = [Self.card("2026-02-03", "+19.99", "TICKETS EXAMPLE", ref: "2"), Self.card("2026-02-01", "-19.99", "TICKETS EXAMPLE", ref: "1")]
    var preview = try await env.preview(rows)
    let refund = try #require(preview.rows.first { $0.canBeRefund })
    let purchase = try #require(preview.rows.first { !$0.canBeRefund })
    #expect(refund.refundOffer?.ref == .row(purchase.id))
    preview.setCategory(F.taxi.id, forRow: purchase.id)
    preview.acceptRefund(try #require(preview.row(refund.id)?.refundOffer), forRow: refund.id)
    #expect(preview.row(refund.id)?.category == .existing(F.taxi.id))
    // The purchase is now spoken for: it cannot be offered to another row.
    #expect(preview.uncategorisedCount == 0)
    let summary = try await env.pipeline.commit(preview)
    #expect(summary.refundsLinked == 1 && summary.created == 2)
    let all = try await env.allTxns()
    let imported = try #require(all.first { $0.refundOfID != nil })
    let bought = try #require(all.first { $0.refundOfID == nil })
    #expect(imported.refundOfID == bought.id && imported.isRefund && imported.categoryID == F.taxi.id)
    #expect(bought.categoryID == F.taxi.id && !bought.isRefund)

    // Undo removes both, no dangling link.
    try await env.pipeline.undo(summary.batch.id)
    #expect(try await env.allTxns().isEmpty)
    // Re-import of the whole file: both rows are already imported once it is committed again.
    let again = try await env.pipeline.commit(try await env.preview(rows))
    #expect(again.created == 2)
    let repeated = try await env.preview(rows)
    #expect(repeated.rows.allSatisfy { $0.status == .alreadyImported })
  }

  @Test("in-file purchases: a learned category follows, different amounts and a purchase on another day window are not offered")
  func sameFileEdges() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.preview([
      Self.card("2026-02-01", "-19.99", "TICKETS EXAMPLE", ref: "1"), Self.card("2026-02-03", "+10.00", "TICKETS EXAMPLE", ref: "2"),
      Self.card("2026-05-03", "+19.99", "TICKETS EXAMPLE", ref: "3"),
    ])
    let refunds = preview.rows.filter(\.canBeRefund)
    #expect(refunds.count == 2)
    #expect(refunds.allSatisfy { $0.refundOffer == nil })
    // 10.00 can still be chosen as a part of the purchase.
    let part = try #require(refunds.first { $0.amountMinor == 10_00 })
    let options = preview.fileRefundOptions(forRow: part.id)
    #expect(options.count == 1 && options[0].remainingMinor == 19_99)
    let ok8 = preview.acceptRefund(options[0], forRow: part.id)
    #expect(ok8)
    // 19.99 in May is outside the window; a search drops it.
    let late = try #require(refunds.first { $0.amountMinor == 19_99 })
    #expect(preview.fileRefundOptions(forRow: late.id).isEmpty)
    // The remaining 9.99 of the purchase cannot take the late 19.99 refund.
    #expect(preview.fileRefundOptions(forRow: late.id, matching: "tickets").isEmpty)
  }

  @Test("a purchase in the file that the user turns into a transfer or skips can no longer be the original")
  func originalChanges() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.preview([
      Self.card("2026-02-01", "-19.99", "TICKETS EXAMPLE", ref: "1"), Self.card("2026-02-03", "+19.99", "TICKETS EXAMPLE", ref: "2"),
    ])
    let refund = try #require(preview.rows.first { $0.canBeRefund })
    let purchase = try #require(preview.rows.first { !$0.canBeRefund })
    preview.acceptRefund(try #require(refund.refundOffer), forRow: refund.id)
    #expect(preview.row(refund.id)?.refundOf != nil)
    preview.setExcluded(true, forRow: purchase.id)
    #expect(preview.row(refund.id)?.refundOf == nil)
    #expect(preview.row(refund.id)?.refundOffer == nil)
    #expect(preview.canCommit)
    // Included again: the accepted choice is back.
    preview.setExcluded(false, forRow: purchase.id)
    #expect(preview.row(refund.id)?.refundOf?.ref == .row(purchase.id))
  }

  @Test("the store refuses a refund link to an expense that is gone or cannot be refunded (nothing is written)")
  func storeValidates() async throws {
    let env = try Env()
    try await env.seed()
    let refund = Txn(
      type: .expense, occurredAt: F.date("2026-02-03"), accountID: F.pkoAccount.id, amountMinor: 5_00, isRefund: true,
      payee: "X", refundOfID: F.id(99))
    let commit = ImportCommit(batch: ImportBatch(source: .pko, fileName: "x.csv"), txns: [TxnWithLines(txn: refund, lines: [])])
    await #expect(throws: RefundError.invalidOriginal) {
      try await SQLiteImportStore(database: env.database, calendar: env.calendar).commit(commit)
    }
    #expect(try await env.allTxns().isEmpty)
  }
}

extension RefundSuggestionTests.Env {
  func rulesCount() async throws -> Int { try await SQLiteRuleRepository(database: database, calendar: calendar).rules().count }
}
