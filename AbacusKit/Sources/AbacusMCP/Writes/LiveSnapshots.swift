import AbacusStore
import Foundation
import SQLiteData

/// Snapshots through N1's `BackupStore`, reason `.preWrite`.
public struct BackupStoreSnapshots: SnapshotProvider {
  public let store: BackupStore

  public init(store: BackupStore) { self.store = store }

  public func snapshot(of database: any DatabaseWriter, reason: String) async throws -> String {
    try await store.snapshot(of: database, reason: .preWrite).url.lastPathComponent
  }
}

public enum LiveSnapshots {
  /// The app's own database snapshots into the app's Backups folder (no mirror: that setting
  /// belongs to the app). Any other file, such as a `--db` scratch copy, snapshots into an
  /// `MCP-Backups` folder beside it, never into the real Backups folder.
  public static func provider(for database: URL, defaultDatabase: URL? = try? AbacusDatabase.defaultURL()) throws -> any SnapshotProvider {
    BackupStoreSnapshots(store: BackupStore(folder: try folder(for: database, defaultDatabase: defaultDatabase)))
  }

  public static func folder(for database: URL, defaultDatabase: URL?) throws -> URL {
    func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    if let defaultDatabase, resolved(database) == resolved(defaultDatabase) { return try BackupStore.defaultFolder() }
    return database.deletingLastPathComponent().appending(path: "MCP-Backups", directoryHint: .isDirectory)
  }
}
