import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// R-SET-2 (N1): automatic snapshots, retention, the pre-migration snapshot. Everything runs on
/// temporary synthetic databases in temporary folders; the app's own folders are never touched.
@Suite("Backup snapshots")
struct BackupSnapshotTests {
  static func tempFolder() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
  }

  static func store(mirror: URL? = nil) -> BackupStore {
    BackupStore(folder: tempFolder(), mirror: mirror, calendar: calendar)
  }

  static func seeded() throws -> StoreFixture {
    let f = try StoreFixture()
    try f.seedBasics()
    return f
  }

  @Test("R-SET-2: a snapshot is a restorable copy named for its time and reason")
  func snapshotRoundTrip() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    let when = Self.date(2026, 11, 3, 10)
    let snapshot = try await store.snapshot(of: f.database, reason: .manual, now: when)
    #expect(snapshot.url.lastPathComponent == "abacus-20261103T100000Z-manual.abacus")
    #expect(store.list().map(\.id) == [snapshot.id])
    #expect(snapshot.date == when)

    let other = try AbacusDatabase.open(at: nil)
    try await SQLiteBackup(database: other).restore(from: snapshot.url)
    #expect(try BackupTests.counts(other) == BackupTests.counts(f.database))
  }

  @Test("R-SET-2: a launch snapshot is taken only when the newest is older than 24 hours")
  func dueOnlyAfterADay() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    let start = Self.date(2026, 11, 3, 8)
    #expect(try await store.snapshotIfDue(of: f.database, now: start) != nil)
    #expect(try await store.snapshotIfDue(of: f.database, now: start.addingTimeInterval(23 * 3600)) == nil)
    #expect(try await store.snapshotIfDue(of: f.database, now: start.addingTimeInterval(25 * 3600)) != nil)
    #expect(store.list().count == 2)
  }

  @Test("R-SET-2: retention keeps 14 daily and 6 monthly snapshots, the newest of each period")
  func retention() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    // One snapshot a day for 60 days up to 2026-11-03 (two on the last day).
    let last = Self.date(2026, 11, 3)
    for offset in stride(from: 59, through: 0, by: -1) {
      let day = Self.calendar.date(byAdding: .day, value: -offset, to: last)!
      try await store.snapshot(of: f.database, reason: .automatic, now: day)
    }
    try await store.snapshot(of: f.database, reason: .manual, now: Self.date(2026, 11, 3, 18))
    let kept = store.list()
    // The 14 most recent days (10-21...11-03) keep their newest snapshot; of the older ones only
    // September's newest (09-30) stays: the data starts on 09-05, so August has nothing.
    let recent = kept.filter { $0.date >= Self.date(2026, 10, 21, 0) }
    #expect(recent.count == 14)
    #expect(recent.first?.reason == .manual)  // the later of the two on 11-03
    let older = kept.filter { $0.date < Self.date(2026, 10, 21, 0) }
    #expect(older.map { Self.calendar.dateComponents([.month, .day], from: $0.date) } == [DateComponents(month: 9, day: 30)])
  }

  @Test("R-SET-2: the last 3 pre-migration snapshots are kept, apart from the daily ones")
  func safetyKeptSeparately() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    for day in 1...5 {
      try await store.snapshot(of: f.database, reason: .preMigration, now: Self.date(2026, 11, day))
    }
    try await store.snapshot(of: f.database, reason: .automatic, now: Self.date(2026, 11, 6))
    let kept = store.list()
    #expect(kept.filter { $0.reason == .preMigration }.map { Self.calendar.component(.day, from: $0.date) } == [5, 4, 3])
    #expect(kept.filter { $0.reason == .automatic }.count == 1)
  }

  @Test("R-SET-2: manual and safety snapshots do not displace each other within a day")
  func safetySnapshotsKeepManualOnes() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    let when = Self.date(2026, 11, 3)
    try await store.snapshot(of: f.database, reason: .manual, now: when)
    try await store.snapshot(of: f.database, reason: .preRestore, now: when.addingTimeInterval(60))
    try await store.snapshot(of: f.database, reason: .preWrite, now: when.addingTimeInterval(120))
    #expect(Set(store.list().map(\.reason)) == [.manual, .preRestore, .preWrite])
  }

  @Test("R-SET-2: a mirror folder receives every snapshot and is pruned the same way")
  func mirrorFolder() async throws {
    let f = try Self.seeded()
    let mirror = Self.tempFolder()
    let store = Self.store(mirror: mirror)
    for day in 1...5 {
      try await store.snapshot(of: f.database, reason: .preMigration, now: Self.date(2026, 11, day))
    }
    #expect(store.mirrorList().map(\.id) == store.list().map(\.id))
    #expect(store.mirrorList().count == 3)
  }

  @Test("R-SET-2: files that are not snapshots are ignored and never deleted")
  func foreignFilesIgnored() async throws {
    let f = try Self.seeded()
    let store = Self.store()
    try await store.snapshot(of: f.database, reason: .manual, now: Self.date(2026, 11, 3))
    let note = store.folder.appending(path: "notes.txt")
    try "keep".write(to: note, atomically: true, encoding: .utf8)
    try await store.snapshot(of: f.database, reason: .manual, now: Self.date(2026, 11, 4))
    #expect(FileManager.default.fileExists(atPath: note.path))
    #expect(store.list().count == 2)
  }

  // MARK: pre-migration

  /// A database file migrated only up to v16, as an older app version left it.
  static func olderDatabaseFile() throws -> URL {
    let url = tempFolder().appending(path: "abacus.sqlite")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: url.path)
    try AbacusDatabase.migrator().migrate(queue, upTo: "v16: estimated transfer amounts")
    try queue.close()
    return url
  }

  @Test("R-SET-2: opening a database with pending migrations snapshots it first, at the old schema")
  func preMigrationSnapshot() throws {
    let url = try Self.olderDatabaseFile()
    let store = Self.store()
    let database = try AbacusDatabase.open(at: url, backups: store, now: Self.date(2026, 11, 3))
    let snapshots = store.list()
    #expect(snapshots.map(\.reason) == [.preMigration])
    let applied = try database.read { try AbacusDatabase.migrator().appliedMigrations($0) }
    let inSnapshot = try DatabaseQueue(path: snapshots[0].url.path).read { try AbacusDatabase.migrator().appliedMigrations($0) }
    #expect(applied.count == inSnapshot.count + 2)  // v17 and v19 (v18 is reserved)
    #expect(!inSnapshot.contains("v17: transaction moves"))
  }

  @Test("R-SET-2: no pre-migration snapshot for a new database or one that is up to date")
  func noSnapshotWhenNothingToMigrate() throws {
    let store = Self.store()
    let url = Self.tempFolder().appending(path: "abacus.sqlite")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AbacusDatabase.open(at: url, backups: store).close()  // fresh file
    try AbacusDatabase.open(at: url, backups: store).close()  // already current
    #expect(store.list().isEmpty)
  }
}
