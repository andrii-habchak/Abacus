import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Backup")
struct BackupTests {
  typealias F = StoreFixture

  static func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: name)
  }

  /// Row counts of every table, to compare databases.
  static func counts(_ database: any DatabaseWriter) throws -> [String: Int] {
    try database.read { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'")
      var counts: [String: Int] = [:]
      for table in tables {
        counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table.quotedDatabaseIdentifier)")
      }
      return counts
    }
  }

  static func seedEverything(_ f: F) async throws {
    try f.seedBasics()
    try await f.insert(
      F.expense(100, "2026-03-02", 10_00, F.groceries, event: F.trip),
      lines: [AttachedRecord(txnID: F.id(100), categoryID: F.fees.id, amountMinor: 1_00)])
    try await f.imports.commit(ImportStoreTests.saldoCommit())
    let plan = BudgetPlan(effectiveMonth: "2026-01", totalMinor: 1_000_00, currency: .PLN)
    try await f.budgets.save(plan, allocations: [BudgetAllocation(planID: plan.id, categoryID: F.food.id, limitMinor: 500_00)])
    try await f.rates.save([FXRate(day: "2026-03-02", base: .EUR, quote: .PLN, rateE8: 425_000_000, provider: "NBU")])
    try await f.rates.save(FXOverride(base: .EUR, quote: .PLN, rateE8: 430_000_000, fromDay: "2026-03-01"))
    try await f.settings.set(.displayCurrency, "PLN")
  }

  @Test("R-SET-2: export writes all tables to one file; restore replaces all data with it")
  func roundTrip() async throws {
    let source = try F()
    try await Self.seedEverything(source)
    let url = Self.temporaryURL("backup.abacus")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try await SQLiteBackup(database: source.database).export(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    // Exporting again overwrites the file.
    try await SQLiteBackup(database: source.database).export(to: url)

    let target = try F()
    try target.seedBasics()
    try await target.insert(F.expense(900, "2026-05-01", 99_00, F.transport))  // replaced by restore
    try await target.settings.set(.refundsReduceSpending, "true")
    try await SQLiteBackup(database: target.database).restore(from: url)

    let expected = try Self.counts(source.database)
    #expect(try Self.counts(target.database) == expected)
    #expect(expected.values.allSatisfy { $0 > 0 })
    #expect(try await target.txns.transaction(F.id(900)) == nil)
    #expect(try await target.txns.transaction(F.id(100))?.lines.count == 1)
    #expect(try await target.settings.displayCurrency() == .PLN)
    #expect(try await target.settings.refundsReduceSpending() == false)
    #expect(try await target.imports.existingFingerprints(["saldo:1"]).count == 1)
  }

  @Test("R-SET-2: a file that is not a backup is rejected and nothing changes")
  func invalidFile() async throws {
    let f = try F()
    try f.seedBasics()
    let url = Self.temporaryURL("not-a-backup.abacus")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("hello".utf8).write(to: url)
    await #expect(throws: StoreError.invalidBackup) { try await SQLiteBackup(database: f.database).restore(from: url) }

    let empty = try DatabaseQueue(path: url.deletingLastPathComponent().appending(path: "empty.sqlite").path)
    try await empty.write { try $0.execute(sql: "CREATE TABLE t (x)") }
    try empty.close()
    await #expect(throws: StoreError.invalidBackup) {
      try await SQLiteBackup(database: f.database).restore(from: url.deletingLastPathComponent().appending(path: "empty.sqlite"))
    }
    #expect(try await f.accounts.accounts(includeArchived: true).count == 3)
  }

  @Test("R-SET-2: a backup from a newer app version is rejected")
  func newerVersion() async throws {
    let source = try F()
    try source.seedBasics()
    try await source.database.write { db in
      try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99: from the future')")
    }
    let url = Self.temporaryURL("future.abacus")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try await SQLiteBackup(database: source.database).export(to: url)

    let target = try F()
    await #expect(throws: StoreError.backupFromNewerVersion) { try await SQLiteBackup(database: target.database).restore(from: url) }
  }

  @Test("R-SET-2: restore works into an on-disk pool database")
  func restoreIntoPool() async throws {
    let source = try F()
    try await Self.seedEverything(source)
    let folder = Self.temporaryURL("pool")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let backupURL = folder.appending(path: "backup.abacus")
    try await SQLiteBackup(database: source.database).export(to: backupURL)

    let pool = try AbacusDatabase.open(at: folder.appending(path: "live.sqlite"))
    try await SQLiteBackup(database: pool).restore(from: backupURL)
    #expect(try Self.counts(pool) == Self.counts(source.database))
  }
}
