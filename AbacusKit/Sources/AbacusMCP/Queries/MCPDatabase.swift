import AbacusStore
import Foundation
import Synchronization
import SQLiteData

/// How the server opens the app database: never through `AbacusDatabase.open`, because that
/// migrates, and only the app (or the import tool) is allowed to change the schema.
public enum MCPDatabase {
  public enum SchemaState: Equatable, Sendable {
    case current
    /// Migrations of this build that the file has not got yet: open the app once.
    case older(missing: Int)
    /// The file has migrations this build does not know: reads are fine, writes are refused.
    case newer(unknown: Int)
  }

  /// A read-only connection: any write fails inside SQLite itself. A WAL database that no one has
  /// open (the app is closed) has no `-wal`/`-shm` files, and a truly read-only connection cannot
  /// create them ("unable to open database file"). Then a plain connection is kept open for the
  /// life of the process so the files exist, and the read-only one opens beside it.
  public static func openReadOnly(at url: URL) throws -> DatabaseQueue {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ToolError("No database at \(url.path). Start Abacus once, or pass --db <path>.")
    }
    var configuration = Configuration()
    configuration.readonly = true
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    do {
      return try DatabaseQueue(path: url.path, configuration: configuration)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
      var plain = Configuration()
      plain.busyMode = .timeout(5)
      let holder = try DatabaseQueue(path: url.path, configuration: plain)
      try holder.read { _ = try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") }
      walHolders.withLock { $0.append(holder) }
      return try DatabaseQueue(path: url.path, configuration: configuration)
    }
  }

  private static let walHolders = Mutex<[DatabaseQueue]>([])

  /// A read-write connection for the write tools: short transactions, a busy timeout so a write
  /// waits for the app's own transaction instead of failing. Does not migrate.
  public static func openReadWrite(at url: URL) throws -> DatabaseQueue {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ToolError("No database at \(url.path). Start Abacus once, or pass --db <path>.")
    }
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    return try DatabaseQueue(path: url.path, configuration: configuration)
  }

  /// Compares the migrations the file has applied with this build's.
  public static func schemaState(_ database: any DatabaseReader) throws -> SchemaState {
    let known = Set(AbacusDatabase.migrator().migrations)
    let applied = try database.read { db -> Set<String> in
      guard try db.tableExists("grdb_migrations") else { return [] }
      return Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
    }
    let unknown = applied.subtracting(known).count
    if unknown > 0 { return .newer(unknown: unknown) }
    let missing = known.subtracting(applied).count
    return missing > 0 ? .older(missing: missing) : .current
  }

  /// SQLite's change counter for the connection's file: it moves whenever another connection
  /// commits a write (the app uses the same value to notice MCP changes).
  public static func dataVersion(_ database: any DatabaseReader) throws -> Int {
    try database.read { try Int.fetchOne($0, sql: "PRAGMA data_version") ?? 0 }
  }
}
