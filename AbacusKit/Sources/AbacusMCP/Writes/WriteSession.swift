import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData

/// What a write tool intends to do, worked out and validated without changing anything.
public struct WritePlan: Sendable {
  /// One sentence the owner can read and approve ("Delete the 50.00 PLN expense “Corner shop” of 2026-03-05").
  public var summary: String
  /// How many records the write touches (checked against the per-call cap).
  public var rows: Int
  public var execute: @Sendable () async throws -> JSONValue

  public init(summary: String, rows: Int = 1, execute: @escaping @Sendable () async throws -> JSONValue) {
    self.summary = summary
    self.rows = rows
    self.execute = execute
  }
}

/// The safeguards around every write (N2, D69). A write tool never executes on its first call:
/// it returns a proposal with a confirmation token, and only a second call with the same
/// arguments and that token runs it.
///
/// - the database must be on exactly this build's schema (never write to a newer one);
/// - one snapshot per session, before the first write (a failed snapshot stops the write);
/// - at most `maxRows` records per call;
/// - every executed write, and every failure, is logged;
/// - after a commit the app is notified.
public actor WriteSession {
  public static let defaultMaxRows = 200
  public static let tokenLifetime: TimeInterval = 600

  public let database: any DatabaseWriter
  let snapshots: any SnapshotProvider
  let notifier: any ChangeNotifier
  let log: WriteLog
  let maxRows: Int
  let now: @Sendable () -> Date
  private var snapshotName: String?
  private var proposals: [String: (key: String, expires: Date)] = [:]

  public init(
    database: any DatabaseWriter, snapshots: any SnapshotProvider, notifier: any ChangeNotifier = NoNotifier(),
    log: WriteLog, maxRows: Int = WriteSession.defaultMaxRows, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.snapshots = snapshots
    self.notifier = notifier
    self.log = log
    self.maxRows = maxRows
    self.now = now
  }

  /// Runs a tool's plan through propose-then-confirm.
  public func run(tool: String, arguments: JSONValue, plan makePlan: @Sendable () async throws -> WritePlan) async throws -> JSONValue {
    var stripped = arguments.objectValue ?? [:]
    let token = stripped.removeValue(forKey: "confirm_token")?.stringValue
    let key = tool + "|" + ((try? JSONValue.object(stripped).serialized()) ?? "")

    try checkSchema()
    let plan = try await makePlan()
    guard plan.rows <= maxRows else {
      throw ToolError(
        "This would change \(plan.rows) records; one call may change at most \(maxRows). Narrow it down, or do it in the Abacus app.")
    }

    guard let token else {
      let fresh = UUID().uuidString.prefix(8).lowercased()
      pruneProposals()
      proposals[String(fresh)] = (key, now().addingTimeInterval(Self.tokenLifetime))
      return [
        "status": "proposed", "summary": .string(plan.summary), "records_affected": .int(Int64(plan.rows)),
        "confirm_token": .string(String(fresh)),
        "next": "Nothing has been changed. If the owner approves, call this tool again with the same arguments plus confirm_token.",
      ]
    }
    guard let proposal = proposals[token], proposal.key == key, proposal.expires > now() else {
      throw ToolError("The confirm_token is unknown, expired or belongs to different arguments. Call without it to get a new proposal.")
    }
    proposals[token] = nil

    do {
      if snapshotName == nil {
        snapshotName = try await snapshots.snapshot(of: database, reason: "before the first MCP write of this session")
      }
      let result = try await plan.execute()
      log.append(tool: tool, summary: plan.summary, outcome: "done", snapshot: snapshotName)
      notifier.databaseChanged()
      return ["status": "done", "summary": .string(plan.summary), "result": result]
    } catch {
      let described = describeWriteError(error)
      log.append(tool: tool, summary: plan.summary, outcome: "failed: \(described)", snapshot: snapshotName)
      throw described
    }
  }

  func checkSchema() throws {
    switch try MCPDatabase.schemaState(database) {
    case .current: break
    case .newer: throw ToolError("This database is on a newer schema than this build of abacus-mcp; writes are refused. Update abacus-mcp.")
    case .older: throw ToolError("This database has not been migrated by the app yet; open Abacus once. Writes are refused.")
    }
  }

  private func pruneProposals() {
    let current = now()
    proposals = proposals.filter { $0.value.expires > current }
  }
}
