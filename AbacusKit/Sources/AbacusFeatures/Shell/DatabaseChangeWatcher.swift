import Foundation
import SQLiteData
import notify
import os

#if canImport(AppKit)
  import AppKit
#endif

/// Notices writes to the app's database file by another process (`abacus-mcp`, `abacus-import`)
/// and asks the session to reload its screens (roadmap N2, app side: the app shows what the
/// MCP server and the importer wrote without a relaunch).
///
/// How a foreign write is recognised: SQLite's `PRAGMA data_version` on a connection changes
/// when *any other* connection commits, never for that connection's own commits.
/// - A dedicated read-only connection to the file is polled about once a second while the app
///   is active. It is cheap and never waits for the app's writer, but it also sees the app's
///   own commits, so it only says "something changed".
/// - Only then is `data_version` read on the app's writer connection (outside a transaction).
///   The writer's value moves only for commits by other connections, i.e. other processes: a
///   change there triggers the reload; the app's own saves never do.
/// - The Darwin notification `ChangeNotification.name` (posted by `abacus-mcp` after each
///   commit) runs the same check at once; the poll is the safety net.
/// - Becoming active runs the check too (polling is paused in the background), so changes
///   made while the app was away appear when it is brought forward.
@MainActor
public final class DatabaseChangeWatcher {
  /// Posted by `abacus-mcp` after every committed write (`AbacusMCP.ChangeNotification.name`).
  public static let darwinNotificationName = "io.github.andrii-habchak.Abacus.database-changed"

  private let database: any DatabaseWriter
  private let interval: Duration
  private let onChange: @MainActor () async -> Void
  private var reader: DatabaseQueue?
  private var readerVersion: Int?
  private var writerVersion: Int?
  private var pollTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var notifyToken: Int32?
  private var running: Task<Bool, Never>?
  private(set) var isRunning = false
  /// How many reloads the watcher asked for (tests, logging).
  public private(set) var reloadCount = 0

  static let log = Logger(subsystem: "io.github.andrii-habchak.Abacus", category: "DatabaseChangeWatcher")

  /// - Parameters:
  ///   - database: the app's database (its writer connection is the one asked in the end).
  ///   - observeApplication: follow `NSApplication` active/inactive and pause the poll in the
  ///     background (the app; without a running `NSApplication` nothing is polled); false
  ///     polls all the time (tests).
  ///   - onChange: the reload; runs on the main actor, never twice at once.
  public init(
    database: any DatabaseWriter, interval: Duration = .seconds(1), observeApplication: Bool = true,
    onChange: @escaping @MainActor () async -> Void
  ) {
    self.database = database
    self.interval = interval
    self.onChange = onChange
    self.observeApplication = observeApplication
  }

  private let observeApplication: Bool

  isolated deinit {
    stop()
  }

  /// Opens the read connection, records the current versions and starts listening. A database
  /// in memory has no file another process could write: nothing starts.
  public func start() async {
    guard !isRunning else { return }
    let path = database.path
    guard !path.isEmpty, path != ":memory:", FileManager.default.fileExists(atPath: path) else { return }
    isRunning = true
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(1)
    configuration.label = "DatabaseChangeWatcher"
    reader = try? DatabaseQueue(path: path, configuration: configuration)
    readerVersion = await readVersion(reader)
    writerVersion = await writerDataVersion()
    observeDarwinNotification()
    #if canImport(AppKit)
      if observeApplication {
        // Not an app (command-line tests): no poll, the notification and `checkNow()` only.
        guard let application = NSApp else { return }
        let center = NotificationCenter.default
        observers.append(
          center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
          })
        observers.append(
          center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.stopPolling() }
          })
        if application.isActive { startPolling() }
        return
      }
    #endif
    startPolling()
  }

  /// Stops polling and listening; the read connection is closed.
  public func stop() {
    isRunning = false
    stopPolling()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    if let notifyToken { notify_cancel(notifyToken) }
    notifyToken = nil
    reader = nil
  }

  /// Checks once: true when another process wrote since the last check, in which case the
  /// reload ran. `force` skips the read-connection shortcut (notification, becoming active).
  /// Checks run one after another, never overlapping (poll, notification and activation can
  /// coincide).
  @discardableResult
  public func checkNow(force: Bool = false) async -> Bool {
    guard isRunning else { return false }
    let previous = running
    let task = Task { @MainActor [weak self] () -> Bool in
      _ = await previous?.value
      guard let self, self.isRunning else { return false }
      return await self.checkOnce(force: force)
    }
    running = task
    return await task.value
  }

  private func checkOnce(force: Bool) async -> Bool {
    let current = await readVersion(reader)
    if !force, let current, current == readerVersion { return false }
    readerVersion = current
    let writer = await writerDataVersion()
    guard let writer, writer != writerVersion else { return false }
    writerVersion = writer
    reloadCount += 1
    Self.log.info("Database changed by another process; reloading screens")
    await onChange()
    return true
  }

  // MARK: Polling

  private func startPolling() {
    guard isRunning, pollTask == nil else { return }
    let interval = interval
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { return }
        await self.checkNow()
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  private func becameActive() {
    guard isRunning else { return }
    startPolling()
    Task { await checkNow(force: true) }
  }

  // MARK: Versions

  private func readVersion(_ reader: DatabaseQueue?) async -> Int? {
    guard let reader else { return nil }
    return try? await reader.read { try Int.fetchOne($0, sql: "PRAGMA data_version") }
  }

  /// `data_version` of the app's writer connection, outside a transaction: it moves only for
  /// commits made by other connections.
  private func writerDataVersion() async -> Int? {
    try? await database.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA data_version") }
  }

  // MARK: Darwin notification

  private func observeDarwinNotification() {
    var token: Int32 = 0
    let status = notify_register_dispatch(Self.darwinNotificationName, &token, .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.checkNow(force: true) }
      }
    }
    if status == NOTIFY_STATUS_OK { notifyToken = token }
  }
}
