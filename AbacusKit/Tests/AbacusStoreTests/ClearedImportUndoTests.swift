import AbacusDomain
import AbacusStore
import Foundation
import Testing

/// N6: undo of an import puts back only what clearing changed (R-CLR-7) and a stale hold the batch
/// deleted (R-CLR-8). Synthetic data only.
@Suite("Undo of clearing (N6)")
struct ClearedImportUndoTests {
  typealias F = StoreFixture

  @Test("R-CLR-7: undo restores the flags, pending mark and booking day of a linked or settled row, keeps later edits")
  func flagsRestored() async throws {
    let f = try F()
    try await f.accounts.save(F.bank)
    let typed = Txn(id: F.id(101), type: .expense, occurredAt: F.at("2026-10-12"), accountID: F.bank.id, amountMinor: 46_00, payee: "Coffee")
    let hold = Txn(
      id: F.id(102), type: .expense, occurredAt: F.at("2026-10-17"), accountID: F.bank.id, amountMinor: 23_40, payee: "Bolt",
      source: .pko, isPendingAtBank: true)
    try await f.txns.save(typed, lines: [])
    try await f.txns.save(hold, lines: [])
    var linked = typed
    linked.isCleared = true
    linked.bookedDay = "2026-10-13"
    var settled = hold
    settled.isPendingAtBank = false
    settled.isCleared = true
    settled.amountMinor = 24_00
    let batch = ImportBatch(source: .pko, fileName: "a.csv", accountID: F.bank.id)
    try await f.imports.commit(
      ImportCommit(
        batch: batch,
        fingerprints: [ImportFingerprint(id: "pko:1", txnID: typed.id), ImportFingerprint(id: "pko:2", txnID: hold.id)],
        updatedTxns: [linked, settled], flagOriginals: [typed, hold]))
    // An edit made after the import must survive the undo.
    var edited = try await #require(f.txns.transaction(typed.id)).txn
    edited.payee = "Coffee beans"
    try await f.txns.save(edited, lines: [])
    try await f.imports.undo(batch.id)
    let a = try await #require(f.txns.transaction(typed.id)).txn
    #expect(!a.isCleared && a.bookedDay == nil && a.payee == "Coffee beans")
    let b = try await #require(f.txns.transaction(hold.id)).txn
    #expect(b.isPendingAtBank && !b.isCleared && b.amountMinor == 23_40)
  }

  @Test("R-CLR-8: a stale hold the import deletes comes back with Undo import")
  func deletedHoldRestored() async throws {
    let f = try F()
    try await f.accounts.save(F.bank)
    let hold = Txn(
      id: F.id(102), type: .expense, occurredAt: F.at("2026-10-08"), accountID: F.bank.id, amountMinor: 23_40, payee: "Bolt",
      source: .pko, isPendingAtBank: true)
    try await f.txns.save(hold, lines: [])
    let batch = ImportBatch(source: .pko, fileName: "a.csv", accountID: F.bank.id)
    try await f.imports.commit(ImportCommit(batch: batch, deletedTxns: [hold]))
    #expect(try await f.txns.transaction(hold.id) == nil)
    try await f.imports.undo(batch.id)
    let back = try await #require(f.txns.transaction(hold.id)).txn
    #expect(back.isPendingAtBank && back.payee == "Bolt" && back.amountMinor == 23_40)
  }

  @Test("R-CLR-7: a snapshot written before v19 decodes as not cleared")
  func oldSnapshots() throws {
    let txn = Txn(type: .expense, occurredAt: F.at("2026-10-12"), accountID: F.bank.id, amountMinor: 100, payee: "X")
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(txn)) as? [String: Any])
    object.removeValue(forKey: "isCleared")
    object.removeValue(forKey: "isToCleared")
    let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    let snapshot = ImportTxnSnapshot(batchID: F.id(1), txnID: txn.id, json: json)
    let decoded = try snapshot.txn()
    #expect(decoded.id == txn.id && !decoded.isCleared && !decoded.isToCleared)
  }
}
