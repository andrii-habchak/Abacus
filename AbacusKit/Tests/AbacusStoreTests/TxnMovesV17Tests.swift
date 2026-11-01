import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C48: schema v17 (`txnMoves`): migration from v16, CloudKit-safe shape, rows go with their transaction.
@Suite("Transaction moves (v17)")
struct TxnMovesV17Tests {
  @Test("v17 adds the table to a v16 database, keeps its data, runs again as a no-op; no UNIQUE, CASCADE / SET NULL only")
  func migration() throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try AbacusDatabase.migrator().migrate(queue, upTo: "v16: estimated transfer amounts")
    try queue.write { db in
      #expect(try !db.tableExists("txnMoves"))
      try db.execute(
        sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES ('a1', 'A', 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#)
      try db.execute(
        sql: #"INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "createdAt") VALUES ('t1', 'expense', '2026-03-01 12:00:00.000', 'a1', 100, '2026-03-01 12:00:00.000')"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    try queue.write { db in
      #expect(try db.tableExists("txnMoves"))
      #expect(try db.columns(in: "txnMoves").map(\.name) == ["id", "txnID", "batchID", "fromAccountID", "toAccountID", "movedAt"])
      #expect(try db.indexes(on: "txnMoves").filter { $0.name.hasPrefix("idx_") }.allSatisfy { !$0.isUnique })
      let actions = try String.fetchAll(db, sql: #"SELECT "on_delete" FROM pragma_foreign_key_list('txnMoves') ORDER BY "from""#)
      #expect(actions == ["SET NULL", "CASCADE"])
      #expect(try Int.fetchOne(db, sql: #"SELECT count(*) FROM "txns""#) == 1)
      // A trace goes with its transaction.
      try db.execute(
        sql: #"INSERT INTO "txnMoves" ("id", "txnID", "fromAccountID", "toAccountID", "movedAt") VALUES ('m1', 't1', 'a1', 'a2', '2026-04-01 10:00:00.000')"#)
      try db.execute(sql: #"DELETE FROM "txns" WHERE "id" = 't1'"#)
      #expect(try Int.fetchOne(db, sql: #"SELECT count(*) FROM "txnMoves""#) == 0)
    }
  }
}
