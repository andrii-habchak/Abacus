import Foundation
import SQLiteData

/// Opens and migrates the app database.
public enum AbacusDatabase {
  /// `~/Library/Application Support/Abacus/abacus.sqlite`
  public static func defaultURL() throws -> URL {
    let folder = try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "Abacus", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: "abacus.sqlite")
  }

  /// A migrated database at `url`, or in memory when `url` is nil (tests, previews).
  ///
  /// With `backups` (the app passes its own store for its own file only), an existing database
  /// that has migrations pending is snapshotted first (`.preMigration`, kept separately). The
  /// snapshot is best effort: when it cannot be written, the migration still runs.
  public static func open(at url: URL?, backups: BackupStore? = nil, now: Date = Date()) throws -> any DatabaseWriter {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database: any DatabaseWriter
    if let url {
      database = try DatabasePool(path: url.path, configuration: configuration)
    } else {
      database = try DatabaseQueue(configuration: configuration)
    }
    let migrator = migrator()
    if let backups, try database.read({ try migrator.hasPendingMigrationsOnExistingData($0) }) {
      _ = try? backups.snapshotNow(of: database, reason: .preMigration, now: now)
    }
    try migrator.migrate(database)
    return database
  }
}

extension DatabaseMigrator {
  /// True when the database already holds data from an earlier schema version and a newer
  /// migration has not run yet (a brand-new file has nothing to protect).
  func hasPendingMigrationsOnExistingData(_ db: Database) throws -> Bool {
    let completed = try completedMigrations(db)
    return !completed.isEmpty && completed.count < migrations.count
  }
}
