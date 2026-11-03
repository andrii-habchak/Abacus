import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// R-SET-2 (N1): Settings › Data snapshots. Temporary database, folders and defaults only.
@MainActor
@Suite("Snapshot settings (N1)")
struct SnapshotSettingsTests {
  struct Setup {
    let model: DataSettingsModel
    let backup: PreviewBackupService
    let folder: URL
    let defaults: UserDefaults
  }

  static func setup() throws -> Setup {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let defaults = UserDefaults(suiteName: "abacus-tests-\(UUID().uuidString)")!
    let database = try AbacusDatabase.open(at: nil)
    var environment = AppEnvironment.preview()
    let backup = PreviewBackupService()
    environment.backup = backup
    environment.snapshots = LiveSnapshots(database: database, defaults: DefaultsBox(defaults), folder: folder)
    return Setup(model: DataSettingsModel(environment: environment), backup: backup, folder: folder, defaults: defaults)
  }

  @Test("R-SET-2: Back up now adds a manual snapshot to the list")
  func backUpNow() async throws {
    let s = try Self.setup()
    await s.model.load()
    #expect(s.model.snapshots.isEmpty)
    await s.model.backUpNow()
    #expect(s.model.snapshots.map(\.reason) == ["Manual"])
    #expect(s.model.messageIsError == false)
    #expect(FileManager.default.fileExists(atPath: s.model.snapshots[0].url.path))
  }

  @Test("R-SET-2: restoring a snapshot asks first, saves today's data, then replaces everything")
  func restoreSnapshot() async throws {
    let s = try Self.setup()
    await s.model.backUpNow()
    let entry = try #require(s.model.snapshots.first)
    s.model.askRestore(snapshot: entry)
    #expect(await s.backup.restores.isEmpty)
    await s.model.confirmSnapshotRestore()
    #expect(await s.backup.restores.map(\.lastPathComponent) == [entry.url.lastPathComponent])
    #expect(Set(s.model.snapshots.map(\.reason)) == ["Manual", "Before restore"])
    #expect(s.model.pendingSnapshot == nil)
  }

  @Test("R-SET-2: cancelling a snapshot restore changes nothing")
  func cancelRestore() async throws {
    let s = try Self.setup()
    await s.model.backUpNow()
    s.model.askRestore(snapshot: s.model.snapshots[0])
    s.model.cancelSnapshotRestore()
    #expect(await s.backup.restores.isEmpty)
    #expect(s.model.snapshots.count == 1)
  }

  @Test("R-SET-2: the second folder is remembered and receives snapshots")
  func secondFolder() async throws {
    let s = try Self.setup()
    let mirror = FileManager.default.temporaryDirectory
      .appending(path: "abacus-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    await s.model.setMirrorFolder(mirror)
    #expect(s.model.mirrorFolder?.standardizedFileURL == mirror.standardizedFileURL)
    await s.model.backUpNow()
    #expect(s.model.mirrorCount == 1)
    await s.model.setMirrorFolder(nil)
    #expect(s.model.mirrorFolder == nil)
    #expect(BackupLocation.mirror(in: s.defaults) == nil)
  }

  @Test("R-SET-2: a session without snapshots (demo database) shows none")
  func noSnapshotsForDemo() async {
    let model = DataSettingsModel(environment: .preview().withoutSnapshots())
    await model.load()
    #expect(model.hasSnapshots == false)
  }
}

extension AppEnvironment {
  fileprivate func withoutSnapshots() -> AppEnvironment {
    var copy = self
    copy.snapshots = nil
    return copy
  }
}
