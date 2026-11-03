import AbacusDomain
import Foundation
import Observation

/// Settings › Data (R-SET-1 data folder, R-SET-2 backup): database location, Export backup…,
/// Restore from backup… with a "Replace all data with …?" confirmation, last export date.
@MainActor
@Observable
public final class DataSettingsModel {
  public private(set) var databaseURL: URL?
  /// Day of the last backup export (`SettingKey.lastBackupExport`, R-SET-2).
  public private(set) var lastExport: Day?
  public private(set) var isWorking = false
  /// A backup chosen for restore, waiting for the user's confirmation.
  public var pendingRestore: URL?
  /// Automatic snapshots, newest first (N1).
  public private(set) var snapshots: [BackupEntry] = []
  public private(set) var snapshotFolder: URL?
  public private(set) var mirrorFolder: URL?
  public private(set) var mirrorCount = 0
  /// A snapshot chosen in the list, waiting for the restore confirmation.
  public var pendingSnapshot: BackupEntry?
  /// The outcome of the last action, shown under the buttons.
  public private(set) var message: String?
  public private(set) var messageIsError = false

  @ObservationIgnored let environment: AppEnvironment
  /// Called after a successful restore so every screen reloads.
  @ObservationIgnored public var onRestore: (@MainActor () async -> Void)?

  public init(environment: AppEnvironment) {
    self.environment = environment
  }

  private var formats: Formats { environment.formats }

  public func load() async {
    databaseURL = await environment.dataLocation.databaseURL()
    lastExport = await loadLastExport()
    await loadSnapshots()
  }

  /// Whether this session takes automatic snapshots (false for demo databases and previews).
  public var hasSnapshots: Bool { environment.snapshots != nil }

  public func loadSnapshots() async {
    guard let service = environment.snapshots else { return }
    snapshots = await service.list()
    snapshotFolder = await service.folder()
    mirrorFolder = await service.mirrorFolder()
    mirrorCount = await service.mirrorCount()
  }

  /// The stored day; a date B1 kept in `UserDefaults` is moved into the database once.
  private func loadLastExport() async -> Day? {
    let stored = (try? await environment.settings.value(.lastBackupExport)).flatMap { Day($0) }
    let legacy = environment.legacyLastExport
    guard let date = legacy.load() else { return stored }
    if let stored {
      legacy.clear()
      return stored
    }
    let day = Day(date, calendar: formats.calendar)
    do {
      try await environment.settings.set(.lastBackupExport, day.string)
      legacy.clear()
    } catch {
      // Kept in UserDefaults; the next launch tries again.
    }
    return day
  }

  // MARK: Labels

  /// "~/Library/Application Support/Abacus/abacus.sqlite".
  public var databasePath: String {
    guard let url = databaseURL else { return "" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = url.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  public var backupNote: String {
    let base = "One file with all accounts, transactions, categories, budgets, events, rules and rates."
    guard let lastExport else { return base + " Not exported yet." }
    return base + " Last export: \(formats.day(lastExport))."
  }

  /// "abacus-backup-2026-10-21.abacus".
  public var suggestedBackupName: String {
    "abacus-backup-\(environment.today().string).\(Self.backupExtension)"
  }

  public static let backupExtension = "abacus"

  /// "~/Library/Application Support/Abacus/Backups".
  public var snapshotFolderPath: String { Self.abbreviated(snapshotFolder) }

  public var mirrorFolderPath: String { mirrorFolder.map { Self.abbreviated($0) } ?? "Not set" }

  /// "Automatic snapshots on launch (every 24 h); 14 daily, 6 monthly and the last 3 before a migration are kept."
  public static let snapshotNote =
    "A snapshot is taken at launch when the newest is older than a day, and before every database migration. "
    + "The newest of each of the last 14 days and 6 months is kept, plus the last 3 taken before a migration."

  public var mirrorNote: String {
    guard mirrorFolder != nil else {
      return "A copy on the same disk is not disaster recovery. Pick an iCloud Drive or external disk folder for a second copy."
    }
    return "Every snapshot is also copied here (\(mirrorCount) there now)."
  }

  /// "3 Nov 2026, 09:00".
  public func stamp(_ date: Date) -> String {
    "\(formats.day(of: date)), \(formats.time(date))"
  }

  static func abbreviated(_ url: URL?) -> String {
    guard let url else { return "" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
  }

  /// "Replace all data with “abacus-backup-2026-10-14.abacus”?"
  public var restoreTitle: String {
    "Replace all data with “\(pendingRestore?.lastPathComponent ?? "")”?"
  }

  public static let restoreMessage =
    "Everything currently in Abacus is replaced by the backup. Export a backup first if you might need today's data."

  // MARK: Actions

  /// Export backup… → the file the user picked (R-SET-2).
  public func export(to url: URL) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await environment.backup.export(to: url)
      let day = Day(environment.now(), calendar: formats.calendar)
      lastExport = day
      show("Exported to \(url.lastPathComponent).")
      do {
        try await environment.settings.set(.lastBackupExport, day.string)
      } catch {
        show("Exported to \(url.lastPathComponent). Couldn't record the export date.")
      }
    } catch {
      show("Couldn't export the backup: \(error.localizedDescription)", error: true)
    }
  }

  /// Back up now: a manual snapshot into the backup folder (and the second one).
  public func backUpNow() async {
    guard let service = environment.snapshots else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let entry = try await service.backUpNow()
      show("Backed up as \(entry.url.lastPathComponent).")
    } catch {
      show("Couldn't back up: \(error.localizedDescription)", error: true)
    }
    await loadSnapshots()
  }

  /// Choose… / Remove for the second folder.
  public func setMirrorFolder(_ folder: URL?) async {
    guard let service = environment.snapshots else { return }
    await service.setMirrorFolder(folder)
    await loadSnapshots()
  }

  /// Restore on a list row: asks first (`pendingSnapshot`), see `confirmSnapshotRestore`.
  public func askRestore(snapshot: BackupEntry) {
    pendingSnapshot = snapshot
  }

  public func cancelSnapshotRestore() {
    pendingSnapshot = nil
  }

  public var snapshotRestoreTitle: String {
    "Replace all data with the snapshot of \(pendingSnapshot.map { stamp($0.date) } ?? "")?"
  }

  /// "Replace all data" for a snapshot: a safety snapshot of today's data first, then the
  /// all-or-nothing restore (R-SET-2).
  public func confirmSnapshotRestore() async {
    guard let entry = pendingSnapshot else { return }
    pendingSnapshot = nil
    isWorking = true
    defer { isWorking = false }
    do {
      try await environment.snapshots?.backUpBeforeRestore()
      try await environment.backup.restore(from: entry.url)
      show("Restored from the snapshot of \(stamp(entry.date)). Today's data was saved as “Before restore”.")
      await loadSnapshots()
      await onRestore?()
    } catch {
      show("Couldn't restore the snapshot: \(error.localizedDescription). Nothing was changed.", error: true)
    }
  }

  /// Restore from backup…: asks first (`pendingRestore`), see `confirmRestore`.
  public func askRestore(from url: URL) {
    pendingRestore = url
  }

  public func cancelRestore() {
    pendingRestore = nil
  }

  /// "Replace all data": replaces everything with the backup, then reloads (R-SET-2).
  public func confirmRestore() async {
    guard let url = pendingRestore else { return }
    pendingRestore = nil
    isWorking = true
    defer { isWorking = false }
    do {
      try await environment.backup.restore(from: url)
      show("Restored from \(url.lastPathComponent).")
      await onRestore?()
    } catch {
      show("Couldn't restore the backup: \(error.localizedDescription). Nothing was changed.", error: true)
    }
  }

  /// Change…: moves the database into `folder` (R-SET-1). On success the app switches to a
  /// new session on the moved file, whose Settings model announces it (`announce`).
  public func moveDatabase(to folder: URL) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await environment.dataLocation.moveDatabase(to: folder)
      databaseURL = await environment.dataLocation.databaseURL()
      show(Self.movedMessage(folder: folder))
    } catch {
      show("Couldn't move the database: \(error.localizedDescription). Nothing was changed.", error: true)
    }
  }

  static func movedMessage(folder: URL) -> String {
    "The database is now in “\(folder.lastPathComponent)”."
  }

  /// Shows the outcome of an action finished by another session's model (the data folder move).
  func announce(_ text: String) {
    show(text)
  }

  private func show(_ text: String, error: Bool = false) {
    message = text
    messageIsError = error
  }
}
