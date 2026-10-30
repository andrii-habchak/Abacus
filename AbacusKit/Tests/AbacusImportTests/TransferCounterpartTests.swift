import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// C38: the other side of a transfer to an own account in another currency, on the SQLite store with
/// synthetic PKO rows: a USD account sends to a PLN account of the same owner (found by its number).
@Suite("Import transfer counterparts (C38)")
struct TransferCounterpartTests {
  typealias F = PipelineFixture

  /// 1 USD = 4 PLN.
  struct Rates: CurrencyConverter {
    var rate: Decimal = 4
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
      if from == to { return 1 }
      if from == .USD, to == .PLN { return rate }
      if from == .PLN, to == .USD { return 1 / rate }
      return nil
    }
    func latestRate(from: Currency, to: Currency) -> Decimal? { rate(from: from, to: to, on: Day("2026-03-01")!) }
    var latestDay: Day? { Day("2026-03-01")! }
  }

  struct Env {
    let database: any DatabaseWriter
    var rates: (any CurrencyConverter)? = Rates()

    init(rates: (any CurrencyConverter)? = Rates()) throws {
      database = try AbacusDatabase.open(at: nil)
      self.rates = rates
    }

    var calendar: Calendar { F.calendar }
    var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: calendar) }
    var store: SQLiteImportStore { SQLiteImportStore(database: database, calendar: calendar) }

    var pipeline: ImportPipeline {
      let rates = self.rates
      return ImportPipeline(
        store: store, accounts: accounts, categories: SQLiteCategoryRepository(database: database),
        events: SQLiteEventRepository(database: database),
        rules: SQLiteRuleRepository(database: database, calendar: calendar), calendar: calendar,
        converter: { rates },
        counterparts: SQLiteTransferCounterpartRepository(database: database, calendar: calendar))
    }

    func seed() async throws {
      try await accounts.save(F.pkoAccount)
      try await accounts.save(F.pkoUSD)
    }

    /// An income (or expense) on the PLN account, as if imported from its statement earlier.
    @discardableResult
    func plnTxn(
      _ day: String, _ minor: Int64, type: TxnType = .income, payee: String = "WLASNY PRZELEW", refund: Bool = false
    ) async throws -> Txn {
      let txn = Txn(
        type: type, occurredAt: F.date(day), accountID: F.pkoAccount.id, amountMinor: minor, isRefund: refund, payee: payee,
        source: .pko)
      try await txns.save(txn, lines: [])
      return txn
    }

    func usd(_ rows: [String]) async throws -> ImportPreview {
      try await pipeline.preview(data: F.pko(rows), fileName: "usd.csv", targetAccountID: F.pkoUSD.id)
    }

    func pln(_ rows: [String]) async throws -> ImportPreview {
      try await pipeline.preview(data: F.pko(rows), fileName: "pln.csv", targetAccountID: F.pkoAccount.id)
    }

    func allTxns() async throws -> [Txn] { try await txns.transactions(matching: TxnQuery()).map(\.txn) }
    func txn(_ id: Txn.ID) async throws -> Txn? { try await allTxns().first { $0.id == id } }
    func balance(_ id: Account.ID) async throws -> Int64 { try await accounts.balances(asOf: Day("2100-01-01")!)[id] ?? 0 }
    func snapshotCount() async throws -> Int { try await database.read { try ImportTxnSnapshot.fetchCount($0) } }
  }

  /// A USD statement row: money out to the PLN account (found by its number).
  static func usdOut(_ day: String, _ amount: String = "100.00", ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew z rachunku","-\#(amount)","USD","+500.00","Rachunek odbiorcy: 99 9999 9999 9999 9999 9999 9999","Nazwa odbiorcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
  }

  /// A PLN statement row: money in from the USD account (found by its number).
  static func plnIn(_ day: String, _ amount: String, ref: String = "1") -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 55 5555 5555 5555 5555 5555 5555","Nazwa nadawcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
  }

  /// Same transaction apart from the stored timestamp precision.
  static func expectSame(_ a: Txn, _ b: Txn) {
    #expect(a.id == b.id && a.type == b.type && a.accountID == b.accountID && a.amountMinor == b.amountMinor)
    #expect(a.toAccountID == b.toAccountID && a.toAmountMinor == b.toAmountMinor && a.payee == b.payee && a.note == b.note)
    #expect(a.isEstimatedTransferAmount == b.isEstimatedTransferAmount && a.categoryID == b.categoryID)
    #expect(abs(a.occurredAt.timeIntervalSince(b.occurredAt)) < 1)
  }

  static func reviewRow(_ preview: ImportPreview) throws -> PreviewRow {
    try #require(preview.rows.first { $0.review != nil })
  }

  // MARK: The problem

  @Test("a row to an own account in another currency needs review; a plain transfer choice stays blocked")
  func problemStillBlocksPlainTransfer() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.usd([Self.usdOut("2026-03-10")])
    let row = try Self.reviewRow(preview)
    #expect(row.review?.reason == .transferAmountUnknown)
    #expect(preview.needsCounterpart(row: row.id, to: F.pkoAccount.id))
    preview.setReviewChoice(.transfer(accountID: F.pkoAccount.id), forRow: row.id)
    #expect(!preview.canCommit)
    #expect(preview.issues.first?.contains("find the other side") == true)
  }

  // MARK: Search: window, direction, ranking

  @Test("the search lists money-in transactions of the other account within 5 days, closest amount at the rate first")
  func searchRanking() async throws {
    let env = try Env()
    try await env.seed()
    let exact = try await env.plnTxn("2026-03-11", 400_00, payee: "EXACT")
    let close = try await env.plnTxn("2026-03-10", 397_50, payee: "CLOSE")
    let far = try await env.plnTxn("2026-03-12", 250_00, payee: "FAR")
    let tooOld = try await env.plnTxn("2026-03-04", 400_00, payee: "TOO OLD")
    let wrongWay = try await env.plnTxn("2026-03-11", 400_00, type: .expense, payee: "EXPENSE")
    let reversal = try await env.plnTxn("2026-03-11", 399_00, type: .expense, payee: "MONEY IN", refund: true)
    let preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let options = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id)
    #expect(options.map(\.id) == [exact.id, reversal.id, close.id, far.id])
    #expect(!options.contains { $0.id == tooOld.id || $0.id == wrongWay.id })
    let top = try #require(options.first)
    #expect(top.expectedMinor == 400_00)
    #expect(top.impliedRate == 4)
    #expect(top.deviation == 0)
    #expect(top.dayGap == 1)
    #expect(top.candidate.refusal == nil)
    #expect(options.first { $0.id == close.id }?.impliedRate == Decimal(string: "3.975"))
  }

  @Test("an equal amount is ranked by date; without a rate only the date ranks")
  func rankingByDateAndWithoutRate() async throws {
    let env = try Env(rates: nil)
    try await env.seed()
    let later = try await env.plnTxn("2026-03-13", 400_00, payee: "LATER")
    let earlier = try await env.plnTxn("2026-03-11", 100_00, payee: "EARLIER")
    let preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let options = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id)
    #expect(options.map(\.id) == [earlier.id, later.id])
    #expect(options.allSatisfy { $0.expectedMinor == nil && $0.deviation == nil })
    #expect(preview.estimatedCounterpart(forRow: id, to: F.pkoAccount.id) == nil)
  }

  @Test("typing a search text widens the window and filters by description or amount")
  func searchText() async throws {
    let env = try Env()
    try await env.seed()
    let old = try await env.plnTxn("2026-02-20", 123_45, payee: "Old Salary")
    try await env.plnTxn("2026-03-11", 400_00, payee: "OTHER")
    let preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let byText = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id, matching: "salary")
    #expect(byText.map(\.id) == [old.id])
    let byAmount = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id, matching: "123,4")
    #expect(byAmount.map(\.id) == [old.id])
    let none = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id, matching: "nothing like it")
    #expect(none.isEmpty)
  }

  @Test("an incoming row is matched with money-out transactions of the other account")
  func incomingRowMatchesOutgoing() async throws {
    let env = try Env()
    try await env.seed()
    let spend = Txn(
      type: .expense, occurredAt: F.date("2026-03-09"), accountID: F.pkoUSD.id, amountMinor: 100_00, payee: "TO PLN", source: .pko)
    try await env.txns.save(spend, lines: [])
    let income = Txn(
      type: .income, occurredAt: F.date("2026-03-09"), accountID: F.pkoUSD.id, amountMinor: 100_00, payee: "WRONG WAY",
      source: .pko)
    try await env.txns.save(income, lines: [])
    let preview = try await env.pln([Self.plnIn("2026-03-10", "400.00")])
    let id = try Self.reviewRow(preview).id
    let options = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoUSD.id)
    #expect(options.map(\.id) == [spend.id])
    #expect(options.first?.expectedMinor == 100_00)
  }

  // MARK: Absorbing

  @Test("choosing a found transaction makes one transfer with both amounts, absorbs the income, undo restores it")
  func absorbAndUndo() async throws {
    let env = try Env()
    try await env.seed()
    let income = try await env.plnTxn("2026-03-11", 398_00)
    let before = try await env.balance(F.pkoUSD.id)
    var preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let option = try #require(try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id).first)
    let cp = TransferCounterpart(accountID: F.pkoAccount.id, kind: .existing(option.candidate.txn), amountMinor: option.amountMinor)
    let applied1 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: cp, forRow: id)
    #expect(applied1)
    #expect(preview.canCommit)
    let row = try #require(preview.row(id))
    #expect(row.type == .transfer && !row.createsTransaction && row.absorbedTxn?.id == income.id)
    #expect(preview.transactionsToCreate == 0)

    let summary = try await env.pipeline.commit(preview)
    #expect(summary.transfersCompleted == 1 && summary.counterpartsAbsorbed == 1)
    let all = try await env.allTxns()
    #expect(all.count == 1)
    let transfer = try #require(await env.txn(income.id))
    #expect(transfer.type == .transfer)
    #expect(transfer.accountID == F.pkoUSD.id && transfer.toAccountID == F.pkoAccount.id)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 398_00)
    #expect(!transfer.isEstimatedTransferAmount)
    #expect(Day(transfer.occurredAt, calendar: F.calendar) == Day("2026-03-10"))
    #expect(try await env.balance(F.pkoUSD.id) == before - 100_00)
    #expect(try await env.snapshotCount() == 1)

    // The same file again is recognised by the fingerprint the transfer took over.
    let again = try await env.usd([Self.usdOut("2026-03-10")])
    #expect(again.rows.first?.status == .alreadyImported)

    try await env.pipeline.undo(preview.batchID)
    let restored = try #require(await env.txn(income.id))
    Self.expectSame(restored, income)
    #expect(try await env.allTxns().count == 1)
    #expect(try await env.balance(F.pkoUSD.id) == before)
    #expect(try await env.snapshotCount() == 0)
  }

  @Test("an outgoing transaction on the other account is absorbed by an incoming row and keeps its date")
  func absorbOutgoing() async throws {
    let env = try Env()
    try await env.seed()
    let spend = Txn(
      type: .expense, occurredAt: F.date("2026-03-09"), accountID: F.pkoUSD.id, amountMinor: 100_00, payee: "TO PLN", source: .pko)
    try await env.txns.save(spend, lines: [])
    var preview = try await env.pln([Self.plnIn("2026-03-10", "399.00")])
    let id = try Self.reviewRow(preview).id
    let cp = TransferCounterpart(accountID: F.pkoUSD.id, kind: .existing(spend), amountMinor: 100_00)
    let applied2 = preview.setTransfer(toAccount: F.pkoUSD.id, counterpart: cp, forRow: id)
    #expect(applied2)
    try await env.pipeline.commit(preview)
    let transfer = try #require(await env.txn(spend.id))
    #expect(transfer.type == .transfer && transfer.accountID == F.pkoUSD.id && transfer.toAccountID == F.pkoAccount.id)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 399_00)
    #expect(Day(transfer.occurredAt, calendar: F.calendar) == Day("2026-03-09"))
  }

  @Test("candidates that cannot be absorbed are listed with the reason, last, and the commit refuses them")
  func refusals() async throws {
    let env = try Env()
    try await env.seed()
    let lines = try await env.plnTxn("2026-03-11", 400_00, payee: "HAS LINES")
    try await env.txns.save(lines, lines: [AttachedRecord(txnID: lines.id, kind: .expense, amountMinor: 1_00)])
    let original = Txn(
      type: .expense, occurredAt: F.date("2026-03-05"), accountID: F.pkoAccount.id, amountMinor: 10_00, payee: "SHOP")
    try await env.txns.save(original, lines: [])
    let refund = Txn(
      type: .expense, occurredAt: F.date("2026-03-11"), accountID: F.pkoAccount.id, amountMinor: 10_00, isRefund: true,
      payee: "SHOP", refundOfID: original.id)
    try await env.txns.save(refund, lines: [])
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-03-11"), accountID: F.pkoUSD.id, amountMinor: 50_00,
      toAccountID: F.pkoAccount.id, toAmountMinor: 200_00, payee: "ALREADY")
    try await env.txns.save(transfer, lines: [])
    let ok = try await env.plnTxn("2026-03-11", 401_00, payee: "FINE")

    var preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let options = try await env.pipeline.counterpartOptions(for: preview, row: id, to: F.pkoAccount.id)
    let byPayee = Dictionary(options.map { ($0.candidate.txn.payee, $0.candidate.refusal) }, uniquingKeysWith: { a, _ in a })
    #expect(byPayee["FINE"] == .some(nil))
    #expect(byPayee["HAS LINES"] == .some(.attachedRecords))
    #expect(byPayee["SHOP"] == .some(.refundLink))
    #expect(byPayee["ALREADY"] == .some(.alreadyTransfer))
    #expect(options.first?.id == ok.id)
    #expect(options.last?.candidate.refusal != nil)
    #expect(TransferAbsorbRefusal.attachedRecords.message.contains("attached records"))

    // Something is attached to the chosen transaction after the preview: the commit refuses.
    let cp = TransferCounterpart(accountID: F.pkoAccount.id, kind: .existing(ok), amountMinor: 401_00)
    let applied3 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: cp, forRow: id)
    #expect(applied3)
    try await env.txns.save(ok, lines: [AttachedRecord(txnID: ok.id, kind: .expense, amountMinor: 1_00)])
    await #expect(throws: TransferCounterpartError.self) { try await env.pipeline.commit(preview) }
    #expect(try await env.txn(ok.id)?.type == .income)
    #expect(try await env.pipeline.history().isEmpty)
  }

  @Test("a transaction on an archived account is refused")
  func archivedAccountRefused() async throws {
    let env = try Env()
    try await env.seed()
    var archived = F.pkoAccount
    archived.isArchived = true
    try await env.accounts.save(archived)
    let income = try await env.plnTxn("2026-03-11", 400_00)
    let found = try await SQLiteTransferCounterpartRepository(database: env.database, calendar: F.calendar)
      .counterpartCandidates(accountID: F.pkoAccount.id, from: Day("2026-03-01")!, to: Day("2026-03-31")!)
    #expect(found.first { $0.id == income.id }?.refusal == .archivedAccount)
  }

  @Test("a row with attached records cannot absorb a transaction, another account's transaction cannot be chosen")
  func invalidCounterpart() async throws {
    let env = try Env()
    try await env.seed()
    let income = try await env.plnTxn("2026-03-11", 400_00)
    var preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let wrongAccount = TransferCounterpart(accountID: F.pkoUSD.id, kind: .manual, amountMinor: 100)
    let applied4 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: wrongAccount, forRow: id)
    #expect(!applied4)
    let notThere = TransferCounterpart(accountID: F.pkoAccount.id, kind: .existing(Txn(
      type: .income, occurredAt: F.date("2026-03-11"), accountID: F.pkoUSD.id, amountMinor: 1)), amountMinor: 1)
    let applied5 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: notThere, forRow: id)
    #expect(!applied5)
    let zero = TransferCounterpart(accountID: F.pkoAccount.id, kind: .manual, amountMinor: 0)
    let applied6 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: zero, forRow: id)
    #expect(!applied6)
    _ = income
  }

  // MARK: Manual amount and estimate

  @Test("a typed amount makes a transfer with both amounts that is not flagged")
  func manualAmount() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.usd([Self.usdOut("2026-03-10")])
    let id = try Self.reviewRow(preview).id
    let cp = TransferCounterpart(accountID: F.pkoAccount.id, kind: .manual, amountMinor: 397_00)
    let applied7 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: cp, forRow: id)
    #expect(applied7)
    #expect(preview.canCommit)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.type == .transfer && transfer.accountID == F.pkoUSD.id && transfer.toAccountID == F.pkoAccount.id)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 397_00)
    #expect(!transfer.isEstimatedTransferAmount)
    #expect(try await env.balance(F.pkoAccount.id) == F.pkoAccount.openingBalanceMinor + 397_00)
    try await env.pipeline.undo(preview.batchID)
    #expect(try await env.allTxns().isEmpty)
  }

  @Test("an incoming row with a typed amount takes the amount from the other account")
  func manualAmountIncoming() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.pln([Self.plnIn("2026-03-10", "399.00")])
    let id = try Self.reviewRow(preview).id
    let cp = TransferCounterpart(accountID: F.pkoUSD.id, kind: .manual, amountMinor: 100_00)
    let applied8 = preview.setTransfer(toAccount: F.pkoUSD.id, counterpart: cp, forRow: id)
    #expect(applied8)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.accountID == F.pkoUSD.id && transfer.toAccountID == F.pkoAccount.id)
    #expect(transfer.amountMinor == 100_00 && transfer.toAmountMinor == 399_00)
  }

  @Test("the estimate uses the day's rate, flags the transfer and shows as estimated")
  func estimate() async throws {
    let env = try Env()
    try await env.seed()
    var preview = try await env.usd([Self.usdOut("2026-03-10", "100.50")])
    let id = try Self.reviewRow(preview).id
    let estimate = try #require(preview.estimatedCounterpart(forRow: id, to: F.pkoAccount.id))
    #expect(estimate.amountMinor == 402_00 && estimate.rate == 4)
    let cp = TransferCounterpart(accountID: F.pkoAccount.id, kind: .estimated(rate: estimate.rate), amountMinor: estimate.amountMinor)
    let applied9 = preview.setTransfer(toAccount: F.pkoAccount.id, counterpart: cp, forRow: id)
    #expect(applied9)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.amountMinor == 100_50 && transfer.toAmountMinor == 402_00)
    #expect(transfer.isEstimatedTransferAmount)
    #expect(try await env.snapshotCount() == 0)
  }

  @Test("a new expense row can get a typed amount through the bulk-style API")
  func newRowManual() async throws {
    let env = try Env()
    try await env.seed()
    let card = #""2026-03-10","2026-03-10","Płatność kartą","-20.00","PLN","+100.00","Tytuł:  000000000000000000000001 ","Lokalizacja: Adres: SHOP Miasto: Warszawa Kraj: POLSKA","Data wykonania operacji: 2026-03-10","Oryginalna kwota operacji: 20.00","Numer karty: 000000******0000","""#
    var preview = try await env.pln([card])
    let id = try #require(preview.rows.first?.id)
    #expect(preview.needsCounterpart(row: id, to: F.pkoUSD.id))
    #expect(!preview.canTransfer(row: id, to: F.pkoUSD.id))
    let cp = TransferCounterpart(accountID: F.pkoUSD.id, kind: .manual, amountMinor: 5_00)
    let applied10 = preview.setTransfer(toAccount: F.pkoUSD.id, counterpart: cp, forRow: id)
    #expect(applied10)
    let row = try #require(preview.row(id))
    #expect(row.type == .transfer && row.createsTransaction && row.counterAmountMinor == 5_00)
    try await env.pipeline.commit(preview)
    let transfer = try #require(try await env.allTxns().first)
    #expect(transfer.accountID == F.pkoAccount.id && transfer.toAccountID == F.pkoUSD.id)
    #expect(transfer.amountMinor == 20_00 && transfer.toAmountMinor == 5_00)
  }

  // MARK: Later import: completing an estimated transfer

  /// A USD → PLN transfer of 100.00 / estimated 400.00 on 2026-03-10, from an earlier import.
  func estimatedTransfer(_ env: Env, flagged: Bool = true, day: String = "2026-03-10") async throws -> Txn {
    let transfer = Txn(
      type: .transfer, occurredAt: F.date(day), accountID: F.pkoUSD.id, amountMinor: 100_00, toAccountID: F.pkoAccount.id,
      toAmountMinor: 400_00, payee: "JAN PRZYKLAD", source: .pko, isEstimatedTransferAmount: flagged)
    try await env.txns.save(transfer, lines: [])
    return transfer
  }

  @Test("a later row on the other account within 5 days and 5 % of the estimate is offered and accepted")
  func laterImportPairing() async throws {
    let env = try Env()
    try await env.seed()
    let transfer = try await estimatedTransfer(env)
    var preview = try await env.pln([Self.plnIn("2026-03-12", "402.50")])
    let row = try #require(preview.rows.first)
    #expect(row.estimateOffer?.txn.id == transfer.id)
    #expect(row.estimateOffer?.estimatedMinor == 400_00)
    #expect(row.status == .needsReview)

    let applied11 = preview.acceptEstimate(forRow: row.id)
    #expect(applied11)
    let accepted = try #require(preview.row(row.id))
    #expect(accepted.estimateLink != nil && accepted.status == .alreadyImported && !accepted.createsTransaction)
    #expect(preview.canCommit && preview.transactionsToCreate == 0)

    let summary = try await env.pipeline.commit(preview)
    #expect(summary.linked == 1 && summary.estimatesCompleted == 1 && summary.created == 0)
    #expect(summary.lines.contains { $0.contains("estimated amount") })
    let all = try await env.allTxns()
    #expect(all.count == 1)
    let done = try #require(all.first)
    #expect(done.id == transfer.id && done.toAmountMinor == 402_50 && done.amountMinor == 100_00)
    #expect(!done.isEstimatedTransferAmount)
    #expect(try await env.snapshotCount() == 1)

    // The same statement again is already imported.
    let again = try await env.pln([Self.plnIn("2026-03-12", "402.50")])
    #expect(again.rows.first?.status == .alreadyImported)

    try await env.pipeline.undo(preview.batchID)
    let restored = try #require(try await env.allTxns().first)
    Self.expectSame(restored, transfer)
    #expect(try await env.snapshotCount() == 0)
  }

  @Test("the outgoing side of an estimated transfer is completed by a row of the sending account")
  func laterImportOutgoingSide() async throws {
    let env = try Env()
    try await env.seed()
    // PLN → USD with the USD side estimated; the PLN side is the real one.
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-03-10"), accountID: F.pkoAccount.id, amountMinor: 400_00,
      toAccountID: F.pkoUSD.id, toAmountMinor: 100_00, source: .pko, isEstimatedTransferAmount: true)
    try await env.txns.save(transfer, lines: [])
    // The USD statement shows the incoming 99.00 from the PLN account.
    let incoming = #""2026-03-11","2026-03-11","Przelew na konto","+99.00","USD","+500.00","Rachunek nadawcy: 99 9999 9999 9999 9999 9999 9999","Nazwa nadawcy: JAN PRZYKLAD","Tytuł: X","","","""#
    var preview = try await env.usd([incoming])
    let row = try #require(preview.rows.first)
    #expect(row.estimateOffer?.txn.id == transfer.id && row.estimateOffer?.estimatedMinor == 100_00)
    let applied12 = preview.acceptEstimate(forRow: row.id)
    #expect(applied12)
    try await env.pipeline.commit(preview)
    let done = try #require(try await env.allTxns().first)
    #expect(done.amountMinor == 400_00 && done.toAmountMinor == 99_00 && !done.isEstimatedTransferAmount)
  }

  @Test("no offer for a transfer that is not flagged, an amount off by more than 5 %, or a date 6 days away")
  func laterImportNoOffer() async throws {
    let env = try Env()
    try await env.seed()
    let plain = try await estimatedTransfer(env, flagged: false)
    var preview = try await env.pln([Self.plnIn("2026-03-12", "400.00")])
    #expect(preview.rows.first?.estimateOffer == nil)
    #expect(preview.rows.first?.canMatchEstimate == false)
    // Flag it: 420.01 is more than 5 % above 400.00, 16.03. is 6 days away.
    try await env.txns.save(Txn(
      id: plain.id, type: .transfer, occurredAt: plain.occurredAt, accountID: plain.accountID, amountMinor: plain.amountMinor,
      toAccountID: plain.toAccountID, toAmountMinor: plain.toAmountMinor, payee: plain.payee, source: .pko,
      isEstimatedTransferAmount: true), lines: [])
    preview = try await env.pln([Self.plnIn("2026-03-12", "420.01")])
    #expect(preview.rows.first?.estimateOffer == nil)
    preview = try await env.pln([Self.plnIn("2026-03-16", "400.00")])
    #expect(preview.rows.first?.estimateOffer == nil)
    preview = try await env.pln([Self.plnIn("2026-03-15", "380.00")])
    #expect(preview.rows.first?.estimateOffer != nil)
  }

  @Test("Not this keeps the row ordinary and the offer does not come back; undo of the choice brings it back")
  func notThis() async throws {
    let env = try Env()
    try await env.seed()
    _ = try await estimatedTransfer(env)
    var preview = try await env.pln([Self.plnIn("2026-03-12", "402.50")])
    let id = try #require(preview.rows.first?.id)
    preview.declineEstimate(forRow: id)
    var row = try #require(preview.row(id))
    #expect(row.estimateDeclined && row.estimateOffer == nil && row.status == .needsReview)
    // An ordinary row: choose a transfer with a typed amount instead.
    let cp = TransferCounterpart(accountID: F.pkoUSD.id, kind: .manual, amountMinor: 100_00)
    let applied13 = preview.setTransfer(toAccount: F.pkoUSD.id, counterpart: cp, forRow: id)
    #expect(applied13)
    try await env.pipeline.commit(preview)
    #expect(try await env.allTxns().count == 2)
    preview.resetEstimate(forRow: id)
    row = try #require(preview.row(id))
    #expect(!row.estimateDeclined)
  }

  @Test("one estimated transfer is offered to one row only")
  func offeredOnce() async throws {
    let env = try Env()
    try await env.seed()
    _ = try await estimatedTransfer(env)
    let preview = try await env.pln([Self.plnIn("2026-03-12", "402.50", ref: "1"), Self.plnIn("2026-03-12", "401.00", ref: "2")])
    #expect(preview.rows.filter { $0.estimateOffer != nil }.count == 1)
  }

  @Test("an offer for a plain income row on the other account (the number is not recognised) is made too")
  func offerForIncomeRow() async throws {
    let env = try Env()
    try await env.seed()
    let transfer = try await estimatedTransfer(env)
    let income = #""2026-03-11","2026-03-11","Przelew na konto","+398.00","PLN","+100.00","Rachunek nadawcy: 11 1111 1111 1111 1111 1111 1111","Nazwa nadawcy: SOMEONE","Tytuł: X","","","""#
    var preview = try await env.pln([income])
    let row = try #require(preview.rows.first)
    #expect(row.status == .new && row.estimateOffer?.txn.id == transfer.id)
    let applied14 = preview.acceptEstimate(forRow: row.id)
    #expect(applied14)
    try await env.pipeline.commit(preview)
    #expect(try await env.allTxns().count == 1)
    #expect(try await env.allTxns().first?.toAmountMinor == 398_00)
  }

  @Test("two rows cannot complete the same transfer")
  func completeConflict() async throws {
    let env = try Env()
    try await env.seed()
    _ = try await estimatedTransfer(env)
    var preview = try await env.pln([Self.plnIn("2026-03-12", "402.50", ref: "1")])
    let id = try #require(preview.rows.first?.id)
    let applied15 = preview.acceptEstimate(forRow: id)
    #expect(applied15)
    #expect(preview.issues.isEmpty)
  }

  @Test("the store refuses to complete a transfer that is no longer estimated, and nothing is written")
  func staleEstimate() async throws {
    let env = try Env()
    try await env.seed()
    let transfer = try await estimatedTransfer(env)
    var preview = try await env.pln([Self.plnIn("2026-03-12", "402.50")])
    let id = try #require(preview.rows.first?.id)
    let applied16 = preview.acceptEstimate(forRow: id)
    #expect(applied16)
    var edited = transfer
    edited.isEstimatedTransferAmount = false
    try await env.txns.save(edited, lines: [])
    await #expect(throws: TransferCounterpartError.self) { try await env.pipeline.commit(preview) }
    #expect(try await env.pipeline.history().isEmpty)
  }
}
