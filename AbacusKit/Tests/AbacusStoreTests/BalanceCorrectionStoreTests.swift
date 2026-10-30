import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C29, R-ACC-4: `txns.isBalanceCorrection` (schema v14) survives the store and the SQL report
/// query skips it.
@Suite("Balance correction flag (v14)")
struct BalanceCorrectionStoreTests {
  typealias F = StoreFixture

  @Test("R-ACC-4: the flag round-trips and defaults to false")
  func roundTrip() async throws {
    let f = try F()
    try f.seedBasics()
    var flagged = F.expense(100, "2026-03-02", 10_00, F.groceries)
    flagged.isBalanceCorrection = true
    try await f.insert(flagged)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries))
    #expect(try await f.txns.transaction(F.id(100))?.txn.isBalanceCorrection == true)
    #expect(try await f.txns.transaction(F.id(101))?.txn.isBalanceCorrection == false)
  }

  @Test("R-ACC-4 / R-LIST-5: the list summary counts a correction but its flows skip it")
  func summarySkipsCorrection() async throws {
    let f = try F()
    try f.seedBasics()
    var flagged = F.expense(100, "2026-03-02", 10_00, F.groceries)
    flagged.isBalanceCorrection = true
    try await f.insert(flagged)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries))
    let summary = try await f.txns.summary(matching: TxnQuery())
    #expect(summary.count == 2)
    #expect(summary.mains.map(\.amountMinor).reduce(0, +) == 20_00)
  }

  @Test("R-ACC-4: v14 adds the column to a v13 database; existing transactions are not corrections; running it again is a no-op")
  func migration() throws {
    let queue = try DatabaseQueue()
    try AbacusDatabase.migrator().migrate(queue, upTo: "v13: accounts drive debts")
    try queue.write { db in
      let before = try db.columns(in: "txns").map(\.name)
      #expect(!before.contains("isBalanceCorrection"))
      try db.execute(
        sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES ('a1', 'A', 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#)
      try db.execute(
        sql: #"INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "createdAt") VALUES ('t1', 'expense', '2026-03-01 12:00:00.000', 'a1', 100, '2026-03-01 12:00:00.000')"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    try queue.read { db in
      let after = try db.columns(in: "txns").map(\.name)
      let flag = try Int.fetchOne(db, sql: #"SELECT "isBalanceCorrection" FROM "txns" WHERE "id" = 't1'"#)
      #expect(after.contains("isBalanceCorrection"))
      #expect(flag == 0)
    }
  }

  @Test("R-ACC-4: the SQL spending report leaves a correction out")
  func spendingQuery() async throws {
    let f = try F()
    try f.seedBasics()
    var flagged = F.expense(100, "2026-03-02", 10_00, F.groceries)
    flagged.isBalanceCorrection = true
    try await f.insert(flagged)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries))
    let report = try await SQLiteReportQueries(database: f.database).monthlySpending(Month("2026-03")!)
    #expect(report.expenses.map(\.amountMinor).reduce(0, +) == 20_00)
  }
}
