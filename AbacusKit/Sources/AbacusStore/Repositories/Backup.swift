import AbacusDomain
import Foundation
import SQLiteData

/// R-SET-2: backup of all data to one file (a SQLite database with the app's schema and
/// migration history) and restore from it.
public struct SQLiteBackup: Sendable {
  public let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  /// Writes a consistent copy of every table to `url` (replacing an existing file).
  public func export(to url: URL) async throws {
    let fileManager = FileManager.default
    let temporary = url.deletingLastPathComponent()
      .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).partial")
    defer { try? fileManager.removeItem(at: temporary) }
    let destination = try DatabaseQueue(path: temporary.path)
    try database.backup(to: destination)
    try destination.close()
    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: url)
    }
  }

  /// Replaces all data with the backup's, in one transaction (all or nothing). The backup is
  /// first brought up to the current schema on a temporary copy; a file that is not an Abacus
  /// database, or comes from a newer app version, is rejected and nothing changes.
  public func restore(from url: URL) async throws {
    let fileManager = FileManager.default
    let copy = fileManager.temporaryDirectory.appending(path: "abacus-restore-\(UUID().uuidString).sqlite")
    defer { try? fileManager.removeItem(at: copy) }
    try fileManager.copyItem(at: url, to: copy)
    try Self.prepare(copy)

    try await database.writeWithoutTransaction { db in
      try db.execute(sql: "ATTACH DATABASE ? AS backup", arguments: [copy.path])
      defer { try? db.execute(sql: "DETACH DATABASE backup") }
      try db.inTransaction {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        let tables = try Self.dataTables(db, schema: "main")
        for table in tables.reversed() {
          try db.execute(sql: "DELETE FROM main.\(table.quotedDatabaseIdentifier)")
        }
        for table in tables {
          let columns = try db.columns(in: table, in: "main").map(\.name.quotedDatabaseIdentifier)
            .joined(separator: ", ")
          try db.execute(
            sql: """
              INSERT INTO main.\(table.quotedDatabaseIdentifier) (\(columns)) \
              SELECT \(columns) FROM backup.\(table.quotedDatabaseIdentifier)
              """)
        }
        return .commit
      }
    }
  }

  /// Validates the copied backup and migrates it to the current schema.
  private static func prepare(_ url: URL) throws {
    let migrator = AbacusDatabase.migrator()
    let queue: DatabaseQueue
    do {
      queue = try DatabaseQueue(path: url.path)
      let looksValid = try queue.read { db in
        try db.tableExists("grdb_migrations") && db.tableExists("txns")
      }
      guard looksValid else { throw StoreError.invalidBackup }
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.invalidBackup
    }
    if try queue.read({ try migrator.hasBeenSuperseded($0) }) {
      throw StoreError.backupFromNewerVersion
    }
    try migrator.migrate(queue)
    try queue.close()
  }

  /// App tables of a schema, parents before children (by foreign keys).
  static func dataTables(_ db: Database, schema: String) throws -> [String] {
    let names = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM \(schema).sqlite_master WHERE type = 'table' \
        AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name
        """)
    var parents: [String: Set<String>] = [:]
    for name in names {
      let referenced = try db.foreignKeys(on: name, in: schema).map(\.destinationTable)
      parents[name] = Set(referenced).subtracting([name]).intersection(names)
    }
    var ordered: [String] = []
    var remaining = Set(names)
    while !remaining.isEmpty {
      let ready = remaining.filter { parents[$0, default: []].isSubset(of: Set(ordered)) }.sorted()
      guard !ready.isEmpty else {
        ordered += remaining.sorted()
        break
      }
      ordered += ready
      remaining.subtract(ready)
    }
    return ordered
  }
}
