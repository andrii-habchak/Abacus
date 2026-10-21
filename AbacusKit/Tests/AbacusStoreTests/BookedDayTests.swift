import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// `Txn.bookedDay` (schema v2, TA Q22) survives every store path.
@Suite("Booked day")
struct BookedDayTests {
  typealias F = StoreFixture

  static func booked(_ n: Int, purchase: String, booked: String) -> Txn {
    var txn = F.expense(n, purchase, 10_00, F.groceries, payee: "Shop")
    txn.source = .pko
    txn.bookedDay = booked
    return txn
  }

  @Test("R-IMP-PKO-4: bookedDay round-trips through save, list and import commit; dates stay the purchase day")
  func saveAndImport() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(Self.booked(100, purchase: "2026-03-02", booked: "2026-03-04"))
    let txn = Self.booked(101, purchase: "2026-03-03", booked: "2026-03-05")
    try await f.imports.commit(ImportCommit(
      batch: ImportBatch(source: .pko, fileName: "pko.csv"), txns: [TxnWithLines(txn: txn, lines: [])]))

    // Filtered by the purchase day, not the booking day.
    let rows = try await f.txns.transactions(matching: TxnQuery(fromDay: Day("2026-03-02"), toDay: Day("2026-03-03")))
    #expect(rows.map(\.txn.bookedDay) == ["2026-03-05", "2026-03-04"])
  }

  @Test("R-IMP-PKO-2, R-IMP-PKO-4: a settled upgrade can set the booking day of an existing hold")
  func upgrade() async throws {
    let f = try F()
    try f.seedBasics()
    var hold = F.expense(100, "2026-03-02", 10_00, F.groceries)
    hold.isPendingAtBank = true
    try await f.insert(hold)
    var settled = hold
    settled.isPendingAtBank = false
    settled.bookedDay = "2026-03-04"
    try await f.imports.commit(ImportCommit(batch: ImportBatch(source: .pko, fileName: "pko.csv"), updatedTxns: [settled]))
    #expect(try await f.txns.transaction(hold.id)?.txn.bookedDay == "2026-03-04")
  }

  @Test("R-SET-2: backups carry bookedDay; a v1 backup restores with it empty")
  func backup() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let source = try F()
    try source.seedBasics()
    try await source.insert(Self.booked(100, purchase: "2026-03-02", booked: "2026-03-04"))
    let current = folder.appending(path: "current.abacus")
    try await SQLiteBackup(database: source.database).export(to: current)
    let target = try F()
    try await SQLiteBackup(database: target.database).restore(from: current)
    #expect(try await target.txns.transaction(F.id(100))?.txn.bookedDay == "2026-03-04")

    // A backup written before migration v2 has no bookedDay column.
    let oldURL = folder.appending(path: "v1.abacus")
    let old = try DatabaseQueue(path: oldURL.path)
    try AbacusDatabase.migrator().migrate(old, upTo: "v1: initial schema")
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO accounts (id, name, currency, kind, openingDate) \
          VALUES ('00000000-0000-0000-0000-000000000001', 'Bank', 'PLN', 'bank', '2026-01-01 00:00:00.000');
          INSERT INTO txns (id, type, occurredAt, accountID, amountMinor, createdAt) \
          VALUES ('00000000-0000-0000-0000-000000000100', 'expense', '2026-03-02 11:00:00.000', \
          '00000000-0000-0000-0000-000000000001', 500, '2026-03-02 11:00:00.000');
          """)
    }
    try old.close()
    try await SQLiteBackup(database: target.database).restore(from: oldURL)
    let restored = try #require(try await target.txns.transaction(F.id(100)))
    #expect(restored.txn.amountMinor == 5_00)
    #expect(restored.txn.bookedDay == nil)
  }
}
