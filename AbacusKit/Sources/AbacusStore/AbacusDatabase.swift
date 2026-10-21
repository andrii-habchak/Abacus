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
  public static func open(at url: URL?) throws -> any DatabaseWriter {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database: any DatabaseWriter
    if let url {
      database = try DatabasePool(path: url.path, configuration: configuration)
    } else {
      database = try DatabaseQueue(configuration: configuration)
    }
    try migrator().migrate(database)
    return database
  }
}
