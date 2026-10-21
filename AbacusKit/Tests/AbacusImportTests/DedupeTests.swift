import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// Exact and fuzzy dedupe, pending → settled (R-IMP-3, R-IMP-4, R-IMP-PKO-2, R-IMP-PKO-4).
@Suite("Import dedupe")
struct DedupeTests {
  typealias F = PipelineFixture

  private func card(_ value: String, _ booked: String, _ amount: String, _ balance: String, _ merchant: String, ref: String) -> String {
    #""\#(booked)","\#(value)","Płatność kartą","\#(amount)","PLN","\#(balance)","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  private func hold(_ value: String, _ amount: String, _ merchant: String, ref: String) -> String {
    #""","\#(value)","Blokada","\#(amount)","PLN","W rozliczeniu","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  private func importPKO(_ db: FakeDB, _ data: Data) async throws -> (ImportPreview, ImportSummary) {
    var preview = try await db.pipeline().preview(data: data, fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    preview.acceptSuggestedReviewChoices()
    return (preview, try await db.pipeline().commit(preview))
  }

  // MARK: Exact (R-IMP-3)

  @Test("R-IMP-3: re-importing the same Saldo file finds nothing new")
  func saldoReimport() async throws {
    let db = FakeDB()
    let data = try F.data("saldo", "spec-example")
    try await db.pipeline().commit(try await db.pipeline().preview(data: data, fileName: "s.csv"))
    let again = try await db.pipeline().preview(data: data, fileName: "s.csv")
    #expect(again.counts.new == 0)
    #expect(again.counts.alreadyImported == 3)
    // The opening balance row: the account exists now.
    #expect(again.counts.skipped == 1)
    #expect(again.transactionsToCreate == 0)
    #expect(again.row("saldo:1004")?.detail == "Imported earlier")
  }

  @Test("R-IMP-3: an overlapping PKO export skips the rows already imported")
  func pkoOverlap() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(db, F.data("pko", "all-types"))
    let count = db.txns.count
    let (preview, summary) = try await importPKO(db, F.data("pko", "settled-later"))
    #expect(preview.counts.alreadyImported == 1)
    #expect(summary.created == 0)
    #expect(db.txns.count == count)
  }

  @Test("R-IMP-3: identical purchases on the same day stay two transactions")
  func identicalSameDay() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let (preview, _) = try await importPKO(db, F.data("pko", "all-types"))
    #expect(preview.rows.filter { $0.source.payee == "COFFEE KIOSK" && $0.status == .new }.count == 2)
    #expect(db.txns.filter { $0.payee == "COFFEE KIOSK" }.count == 2)
  }

  // MARK: Pending → settled (R-IMP-PKO-2, R-IMP-PKO-4)

  @Test("R-IMP-PKO-2, R-IMP-PKO-4: a settled row upgrades the hold: settled amount, purchase day kept, booking day set")
  func holdSettles() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(db, F.data("pko", "all-types"))
    let pending = try #require(db.txns.first { $0.isPendingAtBank })
    let before = db.txns.count

    let (preview, summary) = try await importPKO(db, F.data("pko", "settled-later"))
    let settling = try #require(preview.rows.first { $0.status == .settlesPending })
    #expect(settling.detail == "Settles the pending payment of 2026-01-15")
    #expect(preview.counts.settlesPending == 1)
    #expect(summary.settled == 1)
    #expect(db.txns.count == before)
    let upgraded = try #require(db.txns.first { $0.id == pending.id })
    #expect(!upgraded.isPendingAtBank)
    #expect(upgraded.amountMinor == 23_40)
    #expect(upgraded.occurredAt == pending.occurredAt)
    #expect(upgraded.bookedDay == "2026-01-17")
    #expect(db.txn(fingerprint: settling.source.fingerprints[0])?.id == pending.id)
    #expect(db.fingerprints.values.filter { $0.txnID == pending.id }.count == 2)
  }

  @Test("R-IMP-PKO-2: within 5 % settles, more than 5 %, another merchant or 4 days later does not")
  func holdTolerance() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(
      db,
      F.pko([
        hold("2026-02-10", "-100.00", "HOTEL ALPHA", ref: "H1"),
        hold("2026-02-10", "-100.00", "HOTEL BETA", ref: "H2"),
        hold("2026-02-10", "-50.00", "CINEMA", ref: "H3"),
        hold("2026-02-10", "-30.00", "BAKERY", ref: "H4"),
      ]))
    let (preview, summary) = try await importPKO(
      db,
      F.pko([
        card("2026-02-11", "2026-02-12", "-104.00", "+900.00", "HOTEL ALPHA", ref: "S1"),
        card("2026-02-10", "2026-02-12", "-106.00", "+794.00", "HOTEL BETA", ref: "S2"),
        card("2026-02-10", "2026-02-12", "-50.00", "+744.00", "THEATRE", ref: "S3"),
        card("2026-02-14", "2026-02-15", "-30.00", "+714.00", "BAKERY", ref: "S4"),
      ]))
    #expect(summary.settled == 1)
    #expect(
      preview.rows.map(\.status) == [.settlesPending, .new, .new, .new],
      "\(preview.rows.map { ($0.status, $0.detail ?? "", $0.source.warnings) })")
    let alpha = try #require(db.txns.first { $0.payee == "HOTEL ALPHA" })
    #expect(alpha.amountMinor == 104_00)
    #expect(db.txns.filter(\.isPendingAtBank).count == 3)
  }

  @Test("R-IMP-PKO-2: one hold settles once even if two rows look like it")
  func holdSettlesOnce() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(db, F.pko([hold("2026-02-10", "-12.00", "KIOSK", ref: "H1")]))
    let (preview, _) = try await importPKO(
      db,
      F.pko([
        card("2026-02-10", "2026-02-11", "-12.00", "+988.00", "KIOSK", ref: "S1"),
        card("2026-02-10", "2026-02-11", "-12.00", "+976.00", "KIOSK", ref: "S2"),
      ]))
    #expect(preview.counts.settlesPending == 1)
    #expect(preview.counts.new == 1, "\(preview.rows.map { ($0.status, $0.detail ?? "", $0.source.warnings) })")
  }

  // MARK: Fuzzy (R-IMP-4)

  private func saldoTxn(
    _ day: String, _ amount: Int64, _ payee: String, type: TxnType = .expense, source: TxnSource = .saldo
  ) -> Txn {
    Txn(type: type, occurredAt: F.date(day), accountID: F.pkoAccount.id, amountMinor: amount, payee: payee, source: source)
  }

  private func groceryStatement() -> Data {
    F.pko([card("2026-01-13", "2026-01-14", "-17.35", "+1148.91", "GROCERY STORE", ref: "G1")])
  }

  @Test("R-IMP-4: same account, amount and similar description within 3 days from another source → possible duplicate, skipped by default")
  func fuzzyFlagged() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let existing = saldoTxn("2026-01-11", 17_35, "Grocery store")
    db.txns = [existing]
    let preview = try await db.pipeline().preview(data: groceryStatement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let row = try #require(preview.rows.first)
    #expect(row.status == .possibleDuplicate)
    #expect(row.duplicate?.existing.id == existing.id)
    #expect(row.duplicate?.action == .skip)
    #expect(!row.createsTransaction)
    #expect(preview.counts.possibleDuplicate == 1)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.duplicatesSkipped == 1)
    #expect(db.txns.count == 1)
    #expect(db.fingerprints.isEmpty)
  }

  @Test("R-IMP-4: import anyway creates a transaction; link stores the fingerprint on the existing one")
  func fuzzyActions() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let existing = saldoTxn("2026-01-13", 17_35, "GROCERY")
    db.txns = [existing]
    var preview = try await db.pipeline().preview(data: groceryStatement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    preview.setDuplicateAction(.importAnyway, forRow: preview.rows[0].id)
    #expect(preview.rows[0].createsTransaction)
    #expect(preview.transactionsToCreate == 1)

    preview.setDuplicateAction(.link, forRow: preview.rows[0].id)
    #expect(preview.transactionsToCreate == 0)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.linked == 1)
    #expect(db.txns.count == 1)
    #expect(db.txn(fingerprint: preview.rows[0].source.fingerprints[0])?.id == existing.id)

    // Recognised exactly next time.
    let again = try await db.pipeline().preview(data: groceryStatement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    #expect(again.rows[0].status == .alreadyImported)
  }

  @Test("R-IMP-4: not flagged — same source, other description, 4 days apart, other direction")
  func fuzzyNotFlagged() async throws {
    for existing in [
      saldoTxn("2026-01-13", 17_35, "GROCERY STORE", source: .pko),
      saldoTxn("2026-01-12", 17_35, "Rent"),
      saldoTxn("2026-01-09", 17_35, "GROCERY STORE"),
      saldoTxn("2026-01-13", 17_35, "GROCERY STORE", type: .income),
    ] {
      let db = FakeDB()
      db.accounts = [F.pkoAccount]
      db.txns = [existing]
      let preview = try await db.pipeline().preview(data: groceryStatement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
      #expect(preview.rows[0].status == .new, "\(existing.payee) \(existing.source) \(existing.type)")
    }
  }

  @Test("R-IMP-4: on the same day the description is not required")
  func fuzzySameDay() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.txns = [saldoTxn("2026-01-13", 17_35, "Shopping")]
    let preview = try await db.pipeline().preview(data: groceryStatement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.rows[0].status == .possibleDuplicate)
  }

  @Test("R-IMP-4: a manual entry is also a candidate; one existing transaction matches one row")
  func fuzzyOneToOne() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.txns = [saldoTxn("2026-01-11", 4_50, "coffee", source: .manual)]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let coffees = preview.rows.filter { $0.source.payee == "COFFEE KIOSK" }
    #expect(coffees.map(\.status).sorted { $0.rawValue < $1.rawValue } == [.new, .possibleDuplicate])
  }

  @Test("R-IMP-4: a Saldo transfer covering a PKO ATM withdrawal is a possible duplicate")
  func fuzzyTransfer() async throws {
    let db = FakeDB()
    let cash = Account(id: F.id(14), name: "Cash PLN", currency: .PLN, kind: .cash, openingDate: F.date("2024-01-01"))
    db.accounts = [F.pkoAccount, cash]
    db.txns = [
      Txn(type: .transfer, occurredAt: F.date("2026-01-08"), accountID: F.pkoAccount.id, amountMinor: 200_00,
          toAccountID: cash.id, toAmountMinor: 200_00, payee: "ATM", source: .saldo)
    ]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let atm = try #require(preview.rows.first { $0.source.payee.contains("BANKOMAT") })
    #expect(atm.status == .possibleDuplicate)
  }

  // MARK: Helpers

  @Test("R-IMP-4: description similarity")
  func similarity() {
    #expect(DescriptionSimilarity.isSimilar("GROCERY  STORE", "Grocery store Warsaw"))
    #expect(DescriptionSimilarity.isSimilar("Żabka", "ZABKA Z1234 WARSZAWA"))
    #expect(DescriptionSimilarity.isSimilar("biedronka", "JMP BIEDRONKA123"))
    #expect(DescriptionSimilarity.isSimilar("", "anything"))
    #expect(!DescriptionSimilarity.isSimilar("Rent", "GROCERY STORE"))
    #expect(!DescriptionSimilarity.isSimilar("Taxi 12", "Cafe 12"))
  }

  @Test("R-IMP-PKO-3: account numbers compare without spaces and the PL prefix")
  func accountNumbers() {
    #expect(AccountNumber.normalized("PL 44 4444 4444 4444 4444 4444 4444") == "44444444444444444444444444")
    #expect(AccountNumber.normalized("pl44-4444-4444") == "4444444444")
    #expect(AccountNumber.normalized("44444444444444444444444444") == "44444444444444444444444444")
    #expect(AccountNumber.normalized("DE 89 3704") == "DE893704")
  }

  @Test("R-IMP-PKO-2: amount tolerance is 5 %")
  func tolerance() {
    #expect(PendingSettlement.amountMatches(pending: 100_00, settled: 105_00))
    #expect(PendingSettlement.amountMatches(pending: 100_00, settled: 95_00))
    #expect(!PendingSettlement.amountMatches(pending: 100_00, settled: 106_00))
  }
}
