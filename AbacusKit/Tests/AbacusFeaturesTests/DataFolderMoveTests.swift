import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

@MainActor
@Suite("Data folder Change… (C2)")
struct DataFolderMoveTests {
  /// A temporary root with an `old` folder holding a database with sample data, and a
  /// separate `UserDefaults` suite; both removed by `cleanUp()`.
  struct Setup {
    let root: URL
    let oldFile: URL
    let defaults: UserDefaults
    let suite: String
    let database: any DatabaseWriter

    func folder(_ name: String) throws -> URL {
      let url = root.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func cleanUp() {
      try? database.close()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
  }

  func setup() async throws -> Setup {
    let root = FileManager.default.temporaryDirectory.appending(path: "abacus-c2-\(UUID().uuidString)")
    let old = root.appending(path: "old", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let file = old.appending(path: AbacusDatabase.fileName)
    let database = try AbacusDatabase.open(at: file)
    _ = try await SampleData.loadIfEmpty(into: database)
    let suite = "abacus-c2-\(UUID().uuidString)"
    return Setup(
      root: root, oldFile: file, defaults: UserDefaults(suiteName: suite)!, suite: suite, database: database)
  }

  func session(_ setup: Setup, remember: Bool = true) -> AppSession {
    AppSession.live(
      database: setup.database, source: StubSource(rates: nil), calendar: B1Fixture.calendar,
      now: { B1Fixture.at(15) }, formats: B1Fixture.formats,
      locationDefaults: remember ? setup.defaults : nil)
  }

  @Test("R-SET-1 Change… moves the database, remembers the folder and reopens every screen on it")
  func move() async throws {
    let setup = try await setup()
    defer { setup.cleanUp() }
    let first = session(setup)
    let host = AppSessionHost(first)
    await first.start()
    first.app.section = .accounts
    let target = try setup.folder("new")

    await first.app.data.moveDatabase(to: target)

    let next = host.session
    defer { next.stop() }
    #expect(next !== first)
    #expect(first.app.data.messageIsError == false)
    let newFile = target.appending(path: AbacusDatabase.fileName)
    #expect(next.app.data.databaseURL?.standardizedFileURL.path == newFile.standardizedFileURL.path)
    #expect(next.app.data.message == "The database is now in “new”.")
    #expect(next.app.section == .accounts)
    // The data came along; the old file is gone; the next launch opens the new one.
    await next.transactions.load()
    #expect(next.transactions.reference.accounts.count == PreviewData.accounts.count + DebtSample.accounts.count)
    #expect(!FileManager.default.fileExists(atPath: setup.oldFile.path))
    #expect(!FileManager.default.fileExists(atPath: setup.oldFile.path + "-wal"))
    #expect(try DatabaseLocation.resolve(defaults: setup.defaults).path == newFile.standardizedFileURL.path)
  }

  @Test("R-SET-1 a failed move keeps the old database, the old folder setting and shows an error")
  func failureChangesNothing() async throws {
    let setup = try await setup()
    defer { setup.cleanUp() }
    let first = session(setup)
    let host = AppSessionHost(first)
    await first.start()
    defer { first.stop() }
    let target = try setup.folder("taken")
    let existing = target.appending(path: AbacusDatabase.fileName)
    try Data("someone else's file".utf8).write(to: existing)

    await first.app.data.moveDatabase(to: target)

    #expect(host.session === first)
    #expect(first.app.data.messageIsError)
    #expect(
      first.app.data.message
        == "Couldn't move the database: “abacus.sqlite” already exists in “taken”; move that file away or choose another folder. Nothing was changed."
    )
    #expect(first.app.data.databaseURL?.path == setup.oldFile.path)
    #expect(try Data(contentsOf: existing) == Data("someone else's file".utf8))
    #expect(DatabaseLocation.remembered(in: setup.defaults) == nil)
    // The old database is still in use.
    await first.transactions.load()
    #expect(first.transactions.reference.accounts.count == PreviewData.accounts.count + DebtSample.accounts.count)
    #expect(try await setup.database.read { try Account.fetchCount($0) } == PreviewData.accounts.count + DebtSample.accounts.count)
  }

  @Test("R-SET-1 without a window to switch, the copy is removed and the old file kept")
  func noHostChangesNothing() async throws {
    let setup = try await setup()
    defer { setup.cleanUp() }
    let first = session(setup)
    await first.start()
    defer { first.stop() }
    let target = try setup.folder("new")

    await first.app.data.moveDatabase(to: target)

    #expect(first.app.data.messageIsError)
    #expect(!FileManager.default.fileExists(atPath: target.appending(path: AbacusDatabase.fileName).path))
    #expect(FileManager.default.fileExists(atPath: setup.oldFile.path))
    #expect(DatabaseLocation.remembered(in: setup.defaults) == nil)
  }

  @Test("R-SET-1 a demo database (command-line path) moves without changing the remembered folder")
  func demoDatabaseNotRemembered() async throws {
    let setup = try await setup()
    defer { setup.cleanUp() }
    let first = session(setup, remember: false)
    let host = AppSessionHost(first)
    await first.start()
    await first.app.data.moveDatabase(to: try setup.folder("new"))
    defer { host.session.stop() }
    #expect(host.session !== first)
    #expect(DatabaseLocation.remembered(in: setup.defaults) == nil)
  }
}
