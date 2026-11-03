import AbacusDomain
import AbacusStore
import SQLiteData

/// Local MCP server over the app database (WP N2): tool definitions, the query layer and the
/// JSON-RPC transport live here; `AbacusMCPTool` is the thin stdio executable.
public enum AbacusMCP {
  public static let serverName = "abacus-mcp"
}
