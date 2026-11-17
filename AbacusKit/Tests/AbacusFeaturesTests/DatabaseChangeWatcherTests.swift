import AbacusDomain
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing
import notify

/// N2 (app side): writes by another process reload the app; the app's own writes do not.
/// Two connections on one temporary database file stand for the app and `abacus-mcp`.
@MainActor
@Suite("Database change watcher (N2)")
struct DatabaseChangeWatcherTests {
  /// The app's database (a pool, as in the app) and a second connection to the same file.
  struct Files {
    let folder: URL
    let app: any DatabaseWriter
    let other: DatabaseQueue

    init() throws {
      folder = FileManager.default.temporaryDirectory.appending(path: "abacus-watch-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appending(path: "abacus.sqlite")
      app = try AbacusDatabase.open(at: url)
      other = try DatabaseQueue(path: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
  }

  final class Counter {
    var count = 0
  }

  func watcher(_ files: Files, interval: Duration = .seconds(3600), counter: Counter) -> DatabaseChangeWatcher {
    DatabaseChangeWatcher(database: files.app, interval: interval, observeApplication: false) {
      counter.count += 1
    }
  }

  func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test("N2 a commit by another connection is seen; the app's own writes are not")
  func foreignWriteOnly() async throws {
    let files = try Files()
    defer { files.remove() }
    let counter = Counter()
    let watcher = watcher(files, counter: counter)
    await watcher.start()
    defer { watcher.stop() }

    #expect(await watcher.checkNow() == false)
    // The app's own writes (its writer connection).
    try await SQLiteSettingsRepository(database: files.app).set(.displayCurrency, "USD")
    try await SQLiteSettingsRepository(database: files.app).set(.displayCurrency, "EUR")
    #expect(await watcher.checkNow() == false)
    #expect(await watcher.checkNow(force: true) == false)
    #expect(counter.count == 0)

    // Another process writes.
    try await SQLiteSettingsRepository(database: files.other).set(.displayCurrency, "PLN")
    // (Its return value is not asserted: a notification from a parallel test can run the
    // same check first.)
    await watcher.checkNow()
    #expect(counter.count == 1)
    #expect(watcher.reloadCount == 1)
    // Seen once.
    #expect(await watcher.checkNow() == false)
    #expect(counter.count == 1)
  }

  @Test("N2 the poll notices another connection's commit within a second or so")
  func pollNotices() async throws {
    let files = try Files()
    defer { files.remove() }
    let counter = Counter()
    let watcher = watcher(files, interval: .milliseconds(50), counter: counter)
    await watcher.start()
    defer { watcher.stop() }
    try await SQLiteSettingsRepository(database: files.app).set(.displayCurrency, "USD")
    try await Task.sleep(for: .milliseconds(300))
    #expect(counter.count == 0)
    try await SQLiteSettingsRepository(database: files.other).set(.displayCurrency, "PLN")
    await waitUntil { counter.count > 0 }
    #expect(counter.count == 1)
  }

  @Test("N2 the Darwin notification from abacus-mcp reloads at once")
  func darwinNotification() async throws {
    let files = try Files()
    defer { files.remove() }
    let counter = Counter()
    let watcher = watcher(files, counter: counter)
    await watcher.start()
    defer { watcher.stop() }
    try await SQLiteSettingsRepository(database: files.other).set(.displayCurrency, "PLN")
    notify_post(DatabaseChangeWatcher.darwinNotificationName)
    await waitUntil { counter.count > 0 }
    #expect(counter.count == 1)
  }

  @Test("N2 a database in memory is not watched")
  func inMemory() async throws {
    let counter = Counter()
    let watcher = DatabaseChangeWatcher(database: try AbacusDatabase.open(at: nil), observeApplication: false) {
      counter.count += 1
    }
    await watcher.start()
    #expect(await watcher.checkNow(force: true) == false)
  }

  @Test("N2 the session reloads the list after another process deletes a transaction")
  func sessionReloads() async throws {
    let files = try Files()
    defer { files.remove() }
    _ = try await SampleData.loadIfEmpty(into: files.app)
    let session = AppSession.live(database: files.app, source: StubSource(rates: nil))
    await session.start()
    defer { session.stop() }
    session.transactions.filters = TransactionFilters(dateRange: TransactionFilters.allDates)
    await session.transactions.load()
    let victim = try #require(session.transactions.rows.first?.txn.id)
    #expect(session.transactions.rows.contains { $0.txn.id == victim })
    try await files.other.write { db in
      try Txn.find(victim).delete().execute(db)
    }
    await session.databaseChangedElsewhere()
    #expect(!session.transactions.rows.contains { $0.txn.id == victim })
  }
}
