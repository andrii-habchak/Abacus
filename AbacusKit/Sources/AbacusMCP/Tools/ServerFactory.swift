import AbacusStore
import Foundation

/// Assembles the server for a database file.
public enum ServerFactory {
  public static func make(databaseURL: URL, rates: @escaping RateSource = LiveRates.source) throws -> MCPServer {
    let database = try MCPDatabase.openReadOnly(at: databaseURL)
    switch try MCPDatabase.schemaState(database) {
    case .current: break
    case .newer(let unknown):
      StdioTransport.log("abacus-mcp: the database has \(unknown) newer migration(s) than this build; reading anyway")
    case .older(let missing):
      throw ToolError("The database needs \(missing) migration(s) this build would apply; open Abacus once, then retry.")
    }
    let queries = AbacusQueries(database: database, rates: rates)
    return MCPServer(instructions: AbacusMCP.instructions, tools: ReadTools.all(queries))
  }
}
