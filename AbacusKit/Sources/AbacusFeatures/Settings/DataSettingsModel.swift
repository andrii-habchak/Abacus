import AbacusDomain
import Foundation
import Observation

/// Settings › Data (R-SET-1 data folder, R-SET-2 backup): database location, Export backup…,
/// Restore from backup… with a "Replace all data with …?" confirmation, last export date.
@MainActor
@Observable
public final class DataSettingsModel {
  public private(set) var databaseURL: URL?
  public private(set) var lastExport: Date?
  public private(set) var isWorking = false
  /// A backup chosen for restore, waiting for the user's confirmation.
  public var pendingRestore: URL?
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
    lastExport = environment.lastExport.load()
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
    return base + " Last export: \(formats.day(of: lastExport))."
  }

  /// "abacus-backup-2026-10-21.abacus".
  public var suggestedBackupName: String {
    "abacus-backup-\(environment.today().string).\(Self.backupExtension)"
  }

  public static let backupExtension = "abacus"

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
      let now = environment.now()
      environment.lastExport.save(now)
      lastExport = now
      show("Exported to \(url.lastPathComponent).")
    } catch {
      show("Couldn't export the backup: \(error.localizedDescription)", error: true)
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

  /// Change…: moves the database into `folder` (R-SET-1).
  public func moveDatabase(to folder: URL) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await environment.dataLocation.moveDatabase(to: folder)
      databaseURL = await environment.dataLocation.databaseURL()
      show("The database is now in \(folder.lastPathComponent).")
    } catch {
      show("Couldn't move the database: \(error.localizedDescription)", error: true)
    }
  }

  private func show(_ text: String, error: Bool = false) {
    message = text
    messageIsError = error
  }
}
