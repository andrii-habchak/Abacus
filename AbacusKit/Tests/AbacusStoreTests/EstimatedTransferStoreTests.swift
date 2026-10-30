import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C38: schema v16 (`txns.isEstimatedTransferAmount`, `importTxnSnapshots`) and what the store keeps
/// for undo when an import turns an existing transaction into one side of a transfer.
@Suite("Estimated transfer amounts (v16)")
struct EstimatedTransferStoreTests {
  typealias F = StoreFixture

  @Test("v16 adds the flag and the snapshot table to a v15 database, rows stay unflagged, running again is a no-op")
  func migration() throws {
    let queue = try DatabaseQueue()
    try AbacusDatabase.migrator().migrate(queue, upTo: "v15: txns.refundOfID")
    try queue.write { db in
      let before = try db.columns(in: "txns").contains { $0.name == "isEstimatedTransferAmount" }
      #expect(!before)
      try db.execute(
        sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES ('a1', 'A', 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#)
      try db.execute(
        sql: #"INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "createdAt") VALUES ('t1', 'expense', '2026-03-01 12:00:00.000', 'a1', 100, '2026-03-01 12:00:00.000')"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    try queue.read { db in
      let hasColumn = try db.columns(in: "txns").contains { $0.name == "isEstimatedTransferAmount" }
      let unflagged = try Int.fetchOne(db, sql: #"SELECT count(*) FROM "txns" WHERE "isEstimatedTransferAmount" = 0"#)
      let snapshots = try Int.fetchOne(db, sql: #"SELECT count(*) FROM "importTxnSnapshots""#)
      #expect(hasColumn)
      #expect(unflagged == 1)
      #expect(snapshots == 0)
    }
  }

  @Test("v16 is safe on a database that already has the column and the table")
  func migrationIdempotentOnExistingColumn() throws {
    let queue = try DatabaseQueue()
    try AbacusDatabase.migrator().migrate(queue, upTo: "v15: txns.refundOfID")
    try queue.write { db in
      try db.execute(
        sql: #"ALTER TABLE "txns" ADD COLUMN "isEstimatedTransferAmount" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    let exists = try queue.read { db in try db.tableExists("importTxnSnapshots") }
    #expect(exists)
  }

  @Test("the flag survives the repository and a transaction round-trips through the snapshot encoding")
  func flagAndSnapshotRoundTrip() async throws {
    let f = try F()
    try f.seedBasics()
    let transfer = Txn(
      id: F.id(100), type: .transfer, occurredAt: F.at("2026-03-02"), accountID: F.bank.id, amountMinor: 100_00,
      toAccountID: F.card.id, toAmountMinor: 25_00, payee: "Own", isEstimatedTransferAmount: true)
    try await f.insert(transfer)
    let loaded = try #require(try await f.txns.transaction(transfer.id)).txn
    #expect(loaded.isEstimatedTransferAmount)
    let snapshot = try ImportTxnSnapshot(batchID: UUID(), txn: loaded)
    let decoded = try snapshot.txn()
    #expect(decoded == loaded)
  }

  @Test("the candidate lookup lists transactions of the account in the window with the refusal reasons")
  func candidates() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.income(100, "2026-03-02", 50_00, F.salary))
    try await f.insert(F.income(101, "2026-03-20", 50_00, F.salary))
    let repo = SQLiteTransferCounterpartRepository(database: f.database, calendar: F.calendar)
    let found = try await repo.counterpartCandidates(accountID: F.bank.id, from: Day("2026-03-01")!, to: Day("2026-03-05")!)
    #expect(found.map(\.id) == [F.id(100)])
    #expect(found.first?.refusal == nil)
    #expect(found.first?.currency == .PLN)
    let none = try await repo.estimatedTransfers(accountID: F.bank.id, from: Day("2026-03-01")!, to: Day("2026-03-31")!)
    #expect(none.isEmpty)
  }

  @Test("undo restores an absorbed transaction and deletes the snapshot with the batch")
  func commitKeepsOriginalAndUndoRestores() async throws {
    let f = try F()
    try f.seedBasics()
    let income = F.income(100, "2026-03-02", 25_00, F.salary, account: F.card, payee: "In")
    try await f.insert(income)
    var changed = income
    changed.type = .transfer
    changed.accountID = F.bank.id
    changed.amountMinor = 100_00
    changed.toAccountID = F.card.id
    changed.toAmountMinor = 25_00
    changed.categoryID = nil
    let batch = ImportBatch(source: .pko, fileName: "f.csv")
    let commit = ImportCommit(batch: batch, updatedTxns: [changed], absorbedOriginals: [income])
    try await f.imports.commit(commit)
    let during = try #require(try await f.txns.transaction(income.id)).txn
    #expect(during.type == .transfer)
    let snapshots = try await f.database.read { try ImportTxnSnapshot.fetchAll($0) }
    #expect(snapshots.count == 1 && snapshots.first?.txnID == income.id)

    try await f.imports.undo(batch.id)
    let after = try #require(try await f.txns.transaction(income.id)).txn
    #expect(after.type == .income && after.accountID == F.card.id && after.amountMinor == 25_00)
    #expect(after.categoryID == F.salary.id)
    let left = try await f.database.read { try ImportTxnSnapshot.fetchCount($0) }
    #expect(left == 0)
  }

  @Test("a transaction deleted after the import is not brought back by undo")
  func undoSkipsDeleted() async throws {
    let f = try F()
    try f.seedBasics()
    let income = F.income(100, "2026-03-02", 25_00, F.salary, account: F.card)
    try await f.insert(income)
    var changed = income
    changed.type = .transfer
    changed.accountID = F.bank.id
    changed.toAccountID = F.card.id
    changed.toAmountMinor = 25_00
    let batch = ImportBatch(source: .pko, fileName: "f.csv")
    try await f.imports.commit(ImportCommit(batch: batch, updatedTxns: [changed], absorbedOriginals: [income]))
    try await f.txns.delete(income.id)
    try await f.imports.undo(batch.id)
    #expect(try await f.txns.transaction(income.id) == nil)
  }
}
