import Foundation
import SQLiteData

/// Why a snapshot was taken. Stored in the file name.
public enum SnapshotReason: String, Sendable, CaseIterable {
  /// On launch, when the newest snapshot is older than a day.
  case automatic = "auto"
  /// "Back up now" in Settings.
  case manual
  /// Right before a migration changes the schema.
  case preMigration = "premigration"
  /// Right before the MCP server's first write of a session.
  case preWrite = "prewrite"
  /// Right before a restore replaces all data.
  case preRestore = "prerestore"
}

/// One snapshot file in a backup folder.
public struct BackupSnapshot: Sendable, Equatable, Identifiable {
  public var url: URL
  public var date: Date
  public var reason: SnapshotReason
  public var id: String { url.lastPathComponent }
}

/// R-SET-2: automatic snapshots of the database in a folder (default
/// `~/Library/Application Support/Abacus/Backups/`), optionally mirrored into a second folder
/// (iCloud Drive, an external disk). A snapshot is a complete SQLite copy with the app's schema
/// (readable by `SQLiteBackup.restore`); files are named `abacus-<UTC time>-<reason>.abacus`.
///
/// Retention: the newest snapshot of each of the last 14 days and of each of the last 6 months
/// (any reason except pre-migration), plus the last 3 pre-migration snapshots. Pruning applies
/// to both folders.
public struct BackupStore: Sendable {
  public static let fileExtension = "abacus"
  public static let dailyKept = 14
  public static let monthlyKept = 6
  public static let preMigrationKept = 3
  /// An automatic snapshot is due when the newest one is older than this.
  public static let interval: TimeInterval = 24 * 3600

  public let folder: URL
  /// A second folder that gets a copy of every snapshot; nil when none is chosen.
  public let mirror: URL?
  private let calendar: Calendar

  public init(folder: URL, mirror: URL? = nil, calendar: Calendar = .current) {
    self.folder = folder
    self.mirror = mirror
    self.calendar = calendar
  }

  /// `Backups` next to the default database file.
  public static func defaultFolder() throws -> URL {
    try AbacusDatabase.defaultURL().deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
  }

  /// The app's store: the default folder and the mirror remembered in `defaults`.
  public static func standard(defaults: UserDefaults = .standard) throws -> BackupStore {
    BackupStore(folder: try defaultFolder(), mirror: BackupLocation.mirror(in: defaults))
  }

  // MARK: Taking snapshots

  /// Writes a snapshot of `database` named for `now` and `reason`, copies it to the mirror
  /// (a mirror failure does not fail the snapshot), then prunes. This is the
  /// API the MCP server calls before a session's first write: `snapshot(of: db, reason: .preWrite)`.
  @discardableResult
  public func snapshot(
    of database: any DatabaseWriter, reason: SnapshotReason, now: Date = Date()
  ) async throws -> BackupSnapshot {
    try snapshotNow(of: database, reason: reason, now: now)
  }

  func snapshotNow(of database: any DatabaseWriter, reason: SnapshotReason, now: Date) throws -> BackupSnapshot {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = Self.fileName(date: now, reason: reason)
    let url = folder.appending(path: name)
    try SQLiteBackup(database: database).exportNow(to: url)
    if let mirror {
      do {
        try fileManager.createDirectory(at: mirror, withIntermediateDirectories: true)
        let target = mirror.appending(path: name)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: url, to: target)
      } catch {
        // The primary snapshot stands; the Settings list shows what the mirror holds.
      }
    }
    prune(now: now)
    return BackupSnapshot(url: url, date: Self.truncated(now), reason: reason)
  }

  /// Takes an `.automatic` snapshot when none exists in the last 24 hours. Returns it, or nil
  /// when nothing was due.
  @discardableResult
  public func snapshotIfDue(of database: any DatabaseWriter, now: Date = Date()) async throws -> BackupSnapshot? {
    if let newest = list().first, now.timeIntervalSince(newest.date) < Self.interval { return nil }
    return try await snapshot(of: database, reason: .automatic, now: now)
  }

  // MARK: Listing and pruning

  /// Snapshots in the primary folder, newest first. Foreign files are ignored.
  public func list() -> [BackupSnapshot] {
    Self.list(in: folder)
  }

  /// Snapshots in the mirror folder, newest first (empty without a mirror).
  public func mirrorList() -> [BackupSnapshot] {
    mirror.map { Self.list(in: $0) } ?? []
  }

  static func list(in folder: URL) -> [BackupSnapshot] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap(parse).sorted { $0.date > $1.date }
  }

  /// Deletes snapshots outside the retention rules in both folders. Best effort.
  public func prune(now: Date = Date()) {
    for directory in [folder, mirror].compactMap({ $0 }) {
      let snapshots = Self.list(in: directory)
      let keep = retained(snapshots)
      for snapshot in snapshots where !keep.contains(snapshot.id) {
        try? FileManager.default.removeItem(at: snapshot.url)
      }
    }
  }

  /// File names that survive pruning.
  func retained(_ snapshots: [BackupSnapshot]) -> Set<String> {
    var keep = Set<String>()
    keep.formUnion(snapshots.filter { $0.reason == .preMigration }.prefix(Self.preMigrationKept).map(\.id))
    let rotating = snapshots.filter { $0.reason != .preMigration }  // newest first
    var days = Set<DateComponents>()
    var months = Set<DateComponents>()
    for snapshot in rotating {
      let parts = calendar.dateComponents([.year, .month, .day], from: snapshot.date)
      let month = DateComponents(year: parts.year, month: parts.month)
      if days.count < Self.dailyKept, days.insert(parts).inserted { keep.insert(snapshot.id) }
      if months.count < Self.monthlyKept, months.insert(month).inserted { keep.insert(snapshot.id) }
    }
    return keep
  }

  // MARK: File names

  static func truncated(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }

  static func fileName(date: Date, reason: SnapshotReason) -> String {
    "abacus-\(stamp(date))-\(reason.rawValue).\(fileExtension)"
  }

  /// `20261103T101500Z`, UTC.
  static func stamp(_ date: Date) -> String {
    let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!,
      parts.second!)
  }

  private static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static func parse(_ url: URL) -> BackupSnapshot? {
    guard url.pathExtension == fileExtension else { return nil }
    let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
    guard parts.count == 3, parts[0] == "abacus", let reason = SnapshotReason(rawValue: String(parts[2])),
      let date = date(fromStamp: String(parts[1]))
    else { return nil }
    return BackupSnapshot(url: url, date: date, reason: reason)
  }

  static func date(fromStamp text: String) -> Date? {
    guard text.count == 16, text.hasSuffix("Z"), text[text.index(text.startIndex, offsetBy: 8)] == "T" else { return nil }
    let digits = text.filter(\.isNumber)
    guard digits.count == 14 else { return nil }
    func number(_ range: Range<Int>) -> Int {
      let start = digits.index(digits.startIndex, offsetBy: range.lowerBound)
      let end = digits.index(digits.startIndex, offsetBy: range.upperBound)
      return Int(digits[start..<end])!
    }
    var parts = DateComponents()
    parts.year = number(0..<4)
    parts.month = number(4..<6)
    parts.day = number(6..<8)
    parts.hour = number(8..<10)
    parts.minute = number(10..<12)
    parts.second = number(12..<14)
    return utc.date(from: parts)
  }
}

/// Where the optional second backup folder is remembered (outside the database, like the data
/// folder: it is a per-Mac choice and the database may be restored from a backup).
public enum BackupLocation {
  public static let mirrorKey = "AbacusBackupMirrorFolder"

  public static func mirror(in defaults: UserDefaults) -> URL? {
    guard let path = defaults.string(forKey: mirrorKey), !path.isEmpty else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  /// Remembers `folder`; nil forgets it.
  public static func setMirror(_ folder: URL?, in defaults: UserDefaults) {
    if let folder { defaults.set(folder.standardizedFileURL.path, forKey: mirrorKey) } else {
      defaults.removeObject(forKey: mirrorKey)
    }
  }
}
