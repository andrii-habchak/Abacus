import AbacusStore
import Foundation
import SQLiteData

/// The database file in use and "Change…" (R-SET-1): copies the database into the chosen
/// folder and verifies the copy (`AbacusDatabase.copy`), opens it, lets the app switch every
/// screen to it, remembers the folder for the next launch and only then deletes the old file.
/// Any failure before the switch leaves the old database in use, unchanged, and the folder
/// setting as it was.
public actor LiveDataLocation: DataLocationService {
  private var database: any DatabaseWriter
  /// Remembers the new file for the next launch; nil for a demo database given on the command
  /// line, so a demo never changes which file the app opens next time.
  private let remember: (@Sendable (URL) -> Void)?
  /// Replaces the running session with one on the new database; false when nothing can switch.
  private let switchTo: @Sendable (any DatabaseWriter) async -> Bool

  public init(
    database: any DatabaseWriter, remember: (@Sendable (URL) -> Void)?,
    switchTo: @escaping @Sendable (any DatabaseWriter) async -> Bool
  ) {
    self.database = database
    self.remember = remember
    self.switchTo = switchTo
  }

  public func databaseURL() async -> URL { URL(filePath: database.path) }

  public func moveDatabase(to folder: URL) async throws {
    let old = database
    let oldURL = URL(filePath: old.path)
    let newURL = try AbacusDatabase.copy(old, toFolder: folder)
    let opened: any DatabaseWriter
    do {
      opened = try AbacusDatabase.open(at: newURL)
    } catch {
      try? AbacusDatabase.removeFiles(at: newURL)
      throw AbacusDatabase.MoveError.verificationFailed(error.localizedDescription)
    }
    guard await switchTo(opened) else {
      try? opened.close()
      try? AbacusDatabase.removeFiles(at: newURL)
      throw DataServiceError.failed("Abacus couldn't switch to the new folder")
    }
    database = opened
    remember?(newURL)
    // The old file is gone only after everything runs on the copy.
    try? old.close()
    try? AbacusDatabase.removeFiles(at: oldURL)
  }
}
