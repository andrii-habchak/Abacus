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

/// Where the database file lives (R-SET-1, "Data folder").
public protocol DataLocationService: Sendable {
  func databaseURL() async -> URL
  /// Moves the database into `folder` and uses it from there on.
  func moveDatabase(to folder: URL) async throws
}

/// The date of the last backup export ("Last export: 14 Oct 2026"). Kept outside the database
/// until a `SettingKey` exists for it (see docs/status/B1.md).
public struct LastExportStore: Sendable {
  public var load: @Sendable () -> Date?
  public var save: @Sendable (Date) -> Void

  public init(load: @escaping @Sendable () -> Date?, save: @escaping @Sendable (Date) -> Void) {
    self.load = load
    self.save = save
  }

  public static func userDefaults(key: String = "lastBackupExport") -> LastExportStore {
    LastExportStore(
      load: { UserDefaults.standard.object(forKey: key) as? Date },
      save: { UserDefaults.standard.set($0, forKey: key) })
  }

  public static func inMemory(_ initial: Date? = nil) -> LastExportStore {
    let box = LockedBox(initial)
    return LastExportStore(load: { box.value }, save: { box.value = $0 })
  }
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
