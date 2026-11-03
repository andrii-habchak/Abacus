import AbacusStore
import CoreFoundation
import Foundation
import SQLiteData

/// Takes a restorable copy of the database before a session's first write. The real
/// implementation is N1's snapshot API (wired after N1 merges); tests pass a fake.
public protocol SnapshotProvider: Sendable {
  /// Returns a short description of the snapshot (for the log), or throws; a thrown error stops
  /// the write.
  func snapshot(of database: any DatabaseWriter, reason: String) async throws -> String
}

/// Tells the running app that the database changed, so it reloads at once instead of at its next
/// poll of `PRAGMA data_version`.
public protocol ChangeNotifier: Sendable {
  func databaseChanged()
}

public struct NoNotifier: ChangeNotifier {
  public init() {}
  public func databaseChanged() {}
}

/// Posts a Darwin notification (`ChangeNotification.name`); the app registers for it with
/// `CFNotificationCenterGetDarwinNotifyCenter` or `notify_register_dispatch`.
public struct DarwinNotifier: ChangeNotifier {
  public init() {}
  public func databaseChanged() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(ChangeNotification.name as CFString), nil, nil, true)
  }
}

public enum ChangeNotification {
  /// Posted after every committed write from the MCP server.
  public static let name = "io.github.andrii-habchak.Abacus.database-changed"
}

/// One line per write, appended to a file next to the database (never inside it).
public struct WriteLog: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  /// `<folder of the database>/MCP/write-log.jsonl`.
  public static func beside(database: URL) -> WriteLog {
    WriteLog(url: database.deletingLastPathComponent().appending(path: "MCP", directoryHint: .isDirectory).appending(path: "write-log.jsonl"))
  }

  public func append(tool: String, summary: String, outcome: String, snapshot: String? = nil, at date: Date = Date()) {
    var entry: [String: JSONValue] = [
      "at": .string(ISO8601DateFormatter().string(from: date)), "tool": .string(tool), "summary": .string(summary),
      "outcome": .string(outcome),
    ]
    if let snapshot { entry["snapshot"] = .string(snapshot) }
    guard let line = try? JSONValue.object(entry).serialized() else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data((line + "\n").utf8))
    } else {
      try? Data((line + "\n").utf8).write(to: url)
    }
  }

  public func lines() -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }
}
