import AbacusStore
import Foundation
import SQLiteData

/// The app's snapshots (N1): `BackupStore` in `~/Library/Application Support/Abacus/Backups`
/// with the second folder remembered in `UserDefaults`.
public actor LiveSnapshots: SnapshotService {
  private let database: any DatabaseWriter
  private let defaults: DefaultsBox
  private let folderURL: URL?

  /// `folder` overrides the default Backups folder (tests).
  init(database: any DatabaseWriter, defaults: DefaultsBox, folder: URL? = nil) {
    self.database = database
    self.defaults = defaults
    self.folderURL = folder
  }

  private func store() throws -> BackupStore {
    BackupStore(
      folder: try folderURL ?? BackupStore.defaultFolder(), mirror: BackupLocation.mirror(in: defaults.defaults))
  }

  /// On launch: a snapshot when the newest is older than a day (best effort).
  public func snapshotIfDue() async {
    _ = try? await store().snapshotIfDue(of: database)
  }

  public func list() async -> [BackupEntry] {
    ((try? store())?.list() ?? []).map(Self.entry)
  }

  public func backUpNow() async throws -> BackupEntry {
    Self.entry(try await store().snapshot(of: database, reason: .manual))
  }

  /// Not pruned, so the snapshot about to be restored cannot be deleted by it.
  public func backUpBeforeRestore() async throws {
    _ = try await store().snapshot(of: database, reason: .preRestore, prune: false)
  }

  public func folder() async -> URL { (try? folderURL ?? BackupStore.defaultFolder()) ?? URL(filePath: "/") }

  public func mirrorFolder() async -> URL? { BackupLocation.mirror(in: defaults.defaults) }

  public func mirrorCount() async -> Int { (try? store())?.mirrorList().count ?? 0 }

  public func setMirrorFolder(_ folder: URL?) async {
    BackupLocation.setMirror(folder, in: defaults.defaults)
  }

  static func entry(_ snapshot: BackupSnapshot) -> BackupEntry {
    BackupEntry(url: snapshot.url, date: snapshot.date, reason: label(snapshot.reason))
  }

  static func label(_ reason: SnapshotReason) -> String {
    switch reason {
    case .automatic: "Automatic"
    case .manual: "Manual"
    case .preMigration: "Before migration"
    case .preWrite: "Before AI write"
    case .preRestore: "Before restore"
    }
  }
}
