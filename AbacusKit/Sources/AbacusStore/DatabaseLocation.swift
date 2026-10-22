import Foundation
import SQLiteData

/// Where the app database file lives (R-SET-1, Settings › Data › Data folder). A folder chosen
/// with "Change…" is remembered outside the database, in `UserDefaults`; at launch the
/// remembered file is used when it exists, else the default location.
public enum DatabaseLocation {
  /// `UserDefaults` key holding the database file's path when it is not the default one.
  public static let defaultsKey = "AbacusDatabaseFile"

  /// The remembered database file, if any (whether or not it exists).
  public static func remembered(in defaults: UserDefaults) -> URL? {
    guard let path = defaults.string(forKey: defaultsKey), !path.isEmpty else { return nil }
    return URL(filePath: path)
  }

  /// The file to open at launch: the remembered one when it exists, otherwise the default
  /// (a folder on a disconnected drive falls back without forgetting it).
  public static func resolve(defaults: UserDefaults = .standard) throws -> URL {
    if let url = remembered(in: defaults), FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return try AbacusDatabase.defaultURL()
  }

  /// Remembers `file` for the next launch; the default location is stored as no value.
  public static func remember(_ file: URL, in defaults: UserDefaults) {
    if let fallback = try? AbacusDatabase.defaultURL(), samePath(fallback, file) {
      defaults.removeObject(forKey: defaultsKey)
    } else {
      defaults.set(file.standardizedFileURL.path, forKey: defaultsKey)
    }
  }

  static func samePath(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

extension AbacusDatabase {
  /// The database file's name in every data folder.
  public static let fileName = "abacus.sqlite"

  /// Why a database could not be moved to another folder. The original is never touched.
  public enum MoveError: Error, Equatable, Sendable, LocalizedError {
    /// The database is in memory (tests, previews).
    case notAFile
    case sameFolder
    case notAFolder(String)
    case notWritable(String)
    /// The folder already has an `abacus.sqlite`; it is never overwritten.
    case fileExists(String)
    /// The copy did not open, migrate or match the original.
    case verificationFailed(String)

    public var errorDescription: String? {
      switch self {
      case .notAFile: "This database isn't stored in a file"
      case .sameFolder: "The database is already in this folder"
      case .notAFolder(let name): "“\(name)” isn't a folder"
      case .notWritable(let name): "Abacus can't write to “\(name)”"
      case .fileExists(let name):
        "“\(AbacusDatabase.fileName)” already exists in “\(name)”; move that file away or choose another folder"
      case .verificationFailed(let reason): "the copy couldn't be verified (\(reason))"
      }
    }
  }

  /// Copies the live `database` into `folder` as `abacus.sqlite` and checks the copy: it opens,
  /// migrates, passes an integrity check and has the same row count in every table. Returns the
  /// new file, closed. On any failure the partial copy is removed and the error thrown; the
  /// original database and its file are never changed.
  ///
  /// The copy uses SQLite's online backup, which reads one consistent snapshot including
  /// changes still in the WAL, after a passive checkpoint.
  public static func copy(_ database: any DatabaseWriter, toFolder folder: URL) throws -> URL {
    let path = database.path
    guard !path.isEmpty, path != ":memory:", FileManager.default.fileExists(atPath: path) else {
      throw MoveError.notAFile
    }
    let folder = folder.standardizedFileURL
    let name = folder.lastPathComponent
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw MoveError.notAFolder(name)
    }
    let target = folder.appending(path: fileName)
    if DatabaseLocation.samePath(target, URL(filePath: path))
      || DatabaseLocation.samePath(folder, URL(filePath: path).deletingLastPathComponent())
    {
      throw MoveError.sameFolder
    }
    guard FileManager.default.isWritableFile(atPath: folder.path) else { throw MoveError.notWritable(name) }
    guard !companionFiles(of: target).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw MoveError.fileExists(name)
    }

    do {
      _ = try? database.writeWithoutTransaction { try $0.checkpoint(.passive) }
      let destination = try DatabaseQueue(path: target.path)
      do {
        try database.backup(to: destination)
        try destination.close()
      } catch {
        try? destination.close()
        throw error
      }
      try verify(copy: target, against: database)
      return target
    } catch {
      try? removeFiles(at: target)
      if let moveError = error as? MoveError { throw moveError }
      throw MoveError.verificationFailed(error.localizedDescription)
    }
  }

  /// Opens (and migrates) the copy, then compares it with the original.
  static func verify(copy url: URL, against original: any DatabaseWriter) throws {
    let copy = try open(at: url)
    defer { try? copy.close() }
    let integrity = try copy.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }
    guard integrity == "ok" else { throw MoveError.verificationFailed("integrity check: \(integrity ?? "no answer")") }
    let originalCounts = try original.read { try rowCounts($0) }
    let copyCounts = try copy.read { try rowCounts($0) }
    guard originalCounts == copyCounts else { throw MoveError.verificationFailed("row counts differ") }
  }

  /// Row count of every table (SQLite's own tables excluded).
  static func rowCounts(_ db: Database) throws -> [String: Int] {
    let tables = try String.fetchAll(
      db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    var counts: [String: Int] = [:]
    for table in tables {
      counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
    }
    return counts
  }

  /// The database file and its `-wal` / `-shm` companions.
  static func companionFiles(of url: URL) -> [URL] {
    [url, URL(filePath: url.path + "-wal"), URL(filePath: url.path + "-shm")]
  }

  /// Deletes a database file and its `-wal` / `-shm` companions (after a move).
  public static func removeFiles(at url: URL) throws {
    for file in companionFiles(of: url) where FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
}
