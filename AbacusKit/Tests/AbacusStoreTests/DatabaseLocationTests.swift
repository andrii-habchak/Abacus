import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// A temporary folder removed at the end of the test.
final class TemporaryFolder {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(path: "abacus-c2-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func folder(_ name: String) throws -> URL {
    let folder = url.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Database location and move (C2)")
struct DatabaseLocationTests {
  func seeded(at url: URL) throws -> any DatabaseWriter {
    let database = try AbacusDatabase.open(at: url)
    try database.write { db in
      try db.seed {
        Account(id: StoreFixture.id(1), name: "Cash", currency: .PLN, kind: .cash, openingBalanceMinor: 0, openingDate: StoreFixture.at("2026-01-01"))
        AbacusDomain.Category(id: StoreFixture.id(2), name: "Food", kind: .expense)
        Txn(
          id: StoreFixture.id(3), type: .expense, occurredAt: StoreFixture.at("2026-02-01"), accountID: StoreFixture.id(1),
          amountMinor: 12_00, categoryID: StoreFixture.id(2), payee: "Shop")
      }
    }
    return database
  }

  @Test("R-SET-1 the copy holds every row, including changes still in the WAL; the original stays")
  func copyIsComplete() throws {
    let temp = try TemporaryFolder()
    let source = try temp.folder("old").appending(path: AbacusDatabase.fileName)
    let database = try seeded(at: source)
    // A write after the last checkpoint lives in the WAL only.
    try database.write { db in
      try AppSetting.upsert { AppSetting(.displayCurrency, value: "PLN") }.execute(db)
    }
    let target = try AbacusDatabase.copy(database, toFolder: try temp.folder("new"))
    #expect(target.lastPathComponent == "abacus.sqlite")
    #expect(FileManager.default.fileExists(atPath: source.path))

    let copy = try AbacusDatabase.open(at: target)
    defer { try? copy.close() }
    let (txns, setting) = try copy.read { db in
      (try Txn.fetchCount(db), try AppSetting.where { $0.id.eq("displayCurrency") }.fetchOne(db)?.value)
    }
    #expect(txns == 1)
    #expect(setting == "PLN")
    // The original keeps working.
    #expect(try database.read { try Account.fetchCount($0) } == 1)
  }

  @Test("R-SET-1 an existing abacus.sqlite in the folder is never overwritten")
  func refusesExistingFile() throws {
    let temp = try TemporaryFolder()
    let database = try seeded(at: try temp.folder("old").appending(path: AbacusDatabase.fileName))
    let target = try temp.folder("new")
    let existing = target.appending(path: AbacusDatabase.fileName)
    try Data("not ours".utf8).write(to: existing)
    #expect(throws: AbacusDatabase.MoveError.fileExists("new")) {
      try AbacusDatabase.copy(database, toFolder: target)
    }
    #expect(try Data(contentsOf: existing) == Data("not ours".utf8))
  }

  @Test("R-SET-1 the same folder, a missing folder and an in-memory database are refused")
  func refusals() throws {
    let temp = try TemporaryFolder()
    let old = try temp.folder("old")
    let database = try seeded(at: old.appending(path: AbacusDatabase.fileName))
    #expect(throws: AbacusDatabase.MoveError.sameFolder) {
      try AbacusDatabase.copy(database, toFolder: old)
    }
    #expect(throws: AbacusDatabase.MoveError.notAFolder("missing")) {
      try AbacusDatabase.copy(database, toFolder: temp.url.appending(path: "missing"))
    }
    #expect(throws: AbacusDatabase.MoveError.notAFile) {
      try AbacusDatabase.copy(try AbacusDatabase.open(at: nil), toFolder: try temp.folder("new"))
    }
    #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "new/abacus.sqlite").path))
  }

  @Test("R-SET-1 the remembered file is used when it exists, else the default location")
  func resolve() throws {
    let temp = try TemporaryFolder()
    let suite = "abacus-c2-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let defaultURL = try AbacusDatabase.defaultURL()
    #expect(try DatabaseLocation.resolve(defaults: defaults) == defaultURL)

    let file = try temp.folder("data").appending(path: AbacusDatabase.fileName)
    DatabaseLocation.remember(file, in: defaults)
    #expect(DatabaseLocation.remembered(in: defaults)?.path == file.standardizedFileURL.path)
    // Not there (a disconnected drive): the default, without forgetting the folder.
    #expect(try DatabaseLocation.resolve(defaults: defaults) == defaultURL)
    #expect(DatabaseLocation.remembered(in: defaults) != nil)
    try Data().write(to: file)
    #expect(try DatabaseLocation.resolve(defaults: defaults).path == file.standardizedFileURL.path)

    // Moving back to the default location stores nothing.
    DatabaseLocation.remember(defaultURL, in: defaults)
    #expect(DatabaseLocation.remembered(in: defaults) == nil)
  }
}
