import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// N6: what an import marks cleared (R-CLR-7). Synthetic fixtures only.
@Suite("Import clears rows (N6)")
struct ClearedImportTests {
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

  @Test("R-CLR-7: PKO rows are created cleared on the statement's account; a hold is created pending and uncleared")
  func pkoRowsAndHolds() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(db, F.data("pko", "all-types"))
    let pending = db.txns.filter(\.isPendingAtBank)
    #expect(!pending.isEmpty)
    #expect(pending.allSatisfy { !$0.isCleared && !$0.isToCleared })
    let booked = db.txns.filter { !$0.isPendingAtBank }
    #expect(!booked.isEmpty)
    for txn in booked {
      #expect(txn.isCleared == (txn.accountID == F.pkoAccount.id), "\(txn.payee)")
      // A transfer's other side is not confirmed by this statement.
      #expect(!txn.isToCleared, "\(txn.payee)")
    }
  }

  @Test("R-CLR-7: a settled hold becomes cleared and not pending, and keeps what it was in a snapshot list")
  func settledHold() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    _ = try await importPKO(db, F.data("pko", "all-types"))
    let pending = try #require(db.txns.first { $0.isPendingAtBank })
    _ = try await importPKO(db, F.data("pko", "settled-later"))
    let settled = try #require(db.txns.first { $0.id == pending.id })
    #expect(!settled.isPendingAtBank && settled.isCleared)
    let commit = try #require(db.commits.last)
    #expect(commit.flagOriginals.map(\.id) == [pending.id])
    #expect(commit.flagOriginals[0].isPendingAtBank && !commit.flagOriginals[0].isCleared)
  }

  @Test("R-CLR-7: every row of a Saldo import is cleared, a transfer on both sides")
  func saldoRows() async throws {
    let db = FakeDB()
    _ = try await db.pipeline().commit(try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv"))
    #expect(!db.txns.isEmpty)
    #expect(db.txns.allSatisfy { $0.isCleared })
    let transfers = db.txns.filter { $0.type == .transfer && $0.toAccountID != nil }
    #expect(!transfers.isEmpty)
    #expect(transfers.allSatisfy { $0.isToCleared })
  }

  private func statement() -> Data {
    F.pko([card("2026-01-13", "2026-01-15", "-17.35", "+1148.91", "GROCERY STORE", ref: "G1")])
  }

  @Test("R-CLR-7: a bank row matching a hand-typed, uncleared row defaults to Link; the row ends cleared with the booking day, other fields untouched")
  func handTypedConfirmed() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let typed = Txn(
      type: .expense, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 17_35,
      payee: "Grocery store", note: "mine", source: .manual)
    db.txns = [typed]
    let preview = try await db.pipeline().preview(data: statement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let row = try #require(preview.rows.first)
    #expect(row.status == .possibleDuplicate)
    #expect(row.duplicate?.action == .link)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.linked == 1 && summary.confirmed == 1)
    #expect(summary.lines.contains { $0.contains("confirmed by the bank") })
    #expect(db.txns.count == 1)
    let linked = db.txns[0]
    #expect(linked.isCleared && linked.bookedDay == "2026-01-15")
    #expect(linked.payee == "Grocery store" && linked.note == "mine" && linked.amountMinor == 17_35)
    #expect(db.txn(fingerprint: row.source.fingerprints[0])?.id == typed.id)
    #expect(db.commits.last?.flagOriginals.map(\.id) == [typed.id])
  }

  @Test("R-CLR-7: Skip leaves the hand-typed row uncleared; a Saldo row or an already cleared row keeps the Skip default")
  func skipAndSaldoDefault() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.txns = [Txn(type: .expense, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 17_35, payee: "Grocery store", source: .manual)]
    var preview = try await db.pipeline().preview(data: statement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    preview.setDuplicateAction(.skip, forRow: preview.rows[0].id)
    _ = try await db.pipeline().commit(preview)
    #expect(!db.txns[0].isCleared)

    for existing in [
      Txn(type: .expense, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 17_35, payee: "Grocery store", source: .saldo),
      Txn(type: .expense, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 17_35, payee: "Grocery store", source: .manual, isCleared: true),
    ] {
      let other = FakeDB()
      other.accounts = [F.pkoAccount]
      other.txns = [existing]
      let preview = try await other.pipeline().preview(data: statement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
      #expect(preview.rows[0].duplicate?.action == .skip)
    }
  }

  @Test("R-CLR-7: re-importing the same file changes nothing")
  func reimport() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.txns = [Txn(type: .expense, occurredAt: F.date("2026-01-12"), accountID: F.pkoAccount.id, amountMinor: 17_35, payee: "Grocery store", source: .manual)]
    let first = try await db.pipeline().preview(data: statement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    _ = try await db.pipeline().commit(first)
    let snapshot = db.txns
    let again = try await db.pipeline().preview(data: statement(), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    #expect(again.counts.alreadyImported == 1)
    let summary = try await db.pipeline().commit(again)
    #expect(summary.created == 0 && summary.confirmed == 0)
    #expect(db.txns == snapshot)
  }
}
