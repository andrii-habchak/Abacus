import AbacusDomain
import Foundation

/// Backup of all data to one file and restore from it (R-SET-2). The store implements it (WP A5:
/// `SQLiteBackup` has exactly these two methods); the Settings window only calls it.
public protocol BackupService: Sendable {
  /// Writes every table to `url`, replacing an existing file.
  func export(to url: URL) async throws
  /// Replaces all data with the backup's (all or nothing). Callers confirm first.
  func restore(from url: URL) async throws
}

/// One automatic or manual snapshot, as the Settings list shows it (N1).
public struct BackupEntry: Identifiable, Sendable, Equatable {
  public var url: URL
  public var date: Date
  /// "Automatic", "Manual", "Before migration", "Before AI write", "Before restore".
  public var reason: String
  public var id: String { url.lastPathComponent }

  public init(url: URL, date: Date, reason: String) {
    self.url = url
    self.date = date
    self.reason = reason
  }
}

/// Automatic snapshots in a backup folder (N1; the store's `BackupStore`). Restoring one goes
/// through `BackupService.restore(from:)`.
public protocol SnapshotService: Sendable {
  func list() async -> [BackupEntry]
  /// "Back up now".
  func backUpNow() async throws -> BackupEntry
  /// Safety copy before a restore replaces everything; failures are ignored by callers.
  func backUpBeforeRestore() async throws
  func folder() async -> URL
  /// The second folder, if one is chosen.
  func mirrorFolder() async -> URL?
  /// The snapshots currently in the second folder.
  func mirrorCount() async -> Int
  func setMirrorFolder(_ folder: URL?) async
}

/// Where the database file lives (R-SET-1, "Data folder").
public protocol DataLocationService: Sendable {
  func databaseURL() async -> URL
  /// Moves the database into `folder` and uses it from there on.
  func moveDatabase(to folder: URL) async throws
}

/// The last backup export date as B1 kept it, in `UserDefaults` (key `lastBackupExport`), before
/// `SettingKey.lastBackupExport` existed. Read once at launch and moved into the database
/// (R-SET-2); `none` when there is nothing to migrate (previews, tests, demo databases).
public struct LegacyLastExport: Sendable {
  public var load: @Sendable () -> Date?
  public var clear: @Sendable () -> Void

  public init(load: @escaping @Sendable () -> Date?, clear: @escaping @Sendable () -> Void) {
    self.load = load
    self.clear = clear
  }

  public static let defaultsKey = "lastBackupExport"

  public static func userDefaults(_ defaults: UserDefaults = .standard, key: String = defaultsKey) -> LegacyLastExport {
    let box = DefaultsBox(defaults)
    return LegacyLastExport(
      load: { box.defaults.object(forKey: key) as? Date },
      clear: { box.defaults.removeObject(forKey: key) })
  }

  public static let none = LegacyLastExport(load: { nil }, clear: {})

  public static func inMemory(_ initial: Date?) -> LegacyLastExport {
    let box = LockedBox(initial)
    return LegacyLastExport(load: { box.value }, clear: { box.value = nil })
  }
}

/// `UserDefaults` is thread-safe; the box only tells the compiler so.
final class DefaultsBox: @unchecked Sendable {
  let defaults: UserDefaults
  init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// A tiny thread-safe box for in-memory fakes.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

// MARK: - Preview / test implementations

public enum DataServiceError: Error, Equatable, Sendable, LocalizedError {
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}

/// Records calls instead of touching files. Used by previews and tests until A5's store is wired.
public actor PreviewBackupService: BackupService {
  public private(set) var exports: [URL] = []
  public private(set) var restores: [URL] = []
  private let failure: DataServiceError?

  public init(failure: DataServiceError? = nil) {
    self.failure = failure
  }

  public func export(to url: URL) async throws {
    if let failure { throw failure }
    exports.append(url)
  }

  public func restore(from url: URL) async throws {
    if let failure { throw failure }
    restores.append(url)
  }
}

public actor PreviewDataLocationService: DataLocationService {
  private var url: URL
  public private(set) var moves: [URL] = []

  public init(url: URL = PreviewDataLocationService.defaultURL) {
    self.url = url
  }

  /// `~/Library/Application Support/Abacus/abacus.sqlite`, without creating anything.
  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Abacus/abacus.sqlite")
  }

  public func databaseURL() async -> URL { url }

  public func moveDatabase(to folder: URL) async throws {
    moves.append(folder)
    url = folder.appending(path: url.lastPathComponent)
  }
}

/// In-memory snapshots (previews, tests).
public actor PreviewSnapshotService: SnapshotService {
  private var entries: [BackupEntry]
  private var mirror: URL?
  private let now: Date

  public init(entries: [BackupEntry]? = nil, mirror: URL? = nil, now: Date = Date()) {
    self.now = now
    self.mirror = mirror
    self.entries =
      entries ?? [
        BackupEntry(url: URL(filePath: "/tmp/abacus-20261103T080000Z-auto.abacus"), date: now.addingTimeInterval(-3600), reason: "Automatic"),
        BackupEntry(url: URL(filePath: "/tmp/abacus-20261102T080000Z-premigration.abacus"), date: now.addingTimeInterval(-90_000), reason: "Before migration"),
      ]
  }

  public func list() async -> [BackupEntry] { entries }

  public func backUpNow() async throws -> BackupEntry {
    let entry = BackupEntry(url: URL(filePath: "/tmp/abacus-\(entries.count)-manual.abacus"), date: now, reason: "Manual")
    entries.insert(entry, at: 0)
    return entry
  }

  public func backUpBeforeRestore() async throws {}
  public func folder() async -> URL { URL(filePath: "/tmp/Backups") }
  public func mirrorFolder() async -> URL? { mirror }
  public func mirrorCount() async -> Int { mirror == nil ? 0 : entries.count }
  public func setMirrorFolder(_ folder: URL?) async { mirror = folder }
}

/// `SettingsRepository` over a dictionary (previews, tests).
public actor InMemorySettingsRepository: SettingsRepository {
  public private(set) var values: [SettingKey: String]
  public private(set) var writes = 0

  public init(_ values: [SettingKey: String] = [:]) {
    self.values = values
  }

  /// The preview data set's settings.
  public static func preview() -> InMemorySettingsRepository {
    var values: [SettingKey: String] = [:]
    for setting in PreviewData.settings {
      if let key = SettingKey(rawValue: setting.id) { values[key] = setting.value }
    }
    return InMemorySettingsRepository(values)
  }

  public func value(_ key: SettingKey) async throws -> String? { values[key] }

  public func set(_ key: SettingKey, _ value: String) async throws {
    values[key] = value
    writes += 1
  }
}
