import AbacusStore
import Foundation

/// How the write tools are wired; nil leaves the server read-only.
public struct WriteConfiguration: Sendable {
  public var snapshots: any SnapshotProvider
  public var notifier: any ChangeNotifier
  public var log: WriteLog?
  public var maxRows: Int

  public init(
    snapshots: any SnapshotProvider, notifier: any ChangeNotifier = DarwinNotifier(), log: WriteLog? = nil,
    maxRows: Int = WriteSession.defaultMaxRows
  ) {
    self.snapshots = snapshots
    self.notifier = notifier
    self.log = log
    self.maxRows = maxRows
  }
}

/// Assembles the server for a database file.
public enum ServerFactory {
  public static func make(
    databaseURL: URL, rates: @escaping RateSource = LiveRates.source, writes: WriteConfiguration? = nil
  ) throws -> MCPServer {
    let database = try MCPDatabase.openReadOnly(at: databaseURL)
    switch try MCPDatabase.schemaState(database) {
    case .current: break
    case .newer(let unknown):
      StdioTransport.log("abacus-mcp: the database has \(unknown) newer migration(s) than this build; reading anyway")
    case .older(let missing):
      throw ToolError("The database needs \(missing) migration(s) this build would apply; open Abacus once, then retry.")
    }
    var tools = ReadTools.all(AbacusQueries(database: database, rates: rates))
    var instructions = AbacusMCP.instructions
    if let writes {
      let session = WriteSession(
        database: try MCPDatabase.openReadWrite(at: databaseURL), snapshots: writes.snapshots, notifier: writes.notifier,
        log: writes.log ?? .beside(database: databaseURL), maxRows: writes.maxRows)
      tools += WriteTools.all(session: session, rates: rates)
      instructions += """


        Write tools are enabled. Every write is two steps: the first call only proposes (describe it to the \
        owner in plain words and wait for their approval), the second call with confirm_token executes. \
        Never confirm on the owner's behalf. A snapshot of the database is taken before the first write.
        """
    }
    return MCPServer(instructions: instructions, tools: tools)
  }
}
