import AbacusDomain
import AbacusStore
import SQLiteData

/// Local MCP server over the app database (WP N2): tool definitions, the query layer and the
/// JSON-RPC transport live here; `AbacusMCPTool` is the thin stdio executable.
public enum AbacusMCP {
  public static let serverName = "abacus-mcp"
  public static let serverVersion = "0.1.0"

  /// What the model is told when the connection starts.
  public static let instructions = """
    Abacus is the owner's personal finance tracker. These tools read (and, when enabled, change) \
    their local database. Amounts are decimal strings with a currency code; negative balances are \
    liabilities. Prefer the aggregate tools (net_worth, spending_by_category, cash_flow, \
    budget_status) over listing transactions, and ask for the smallest range that answers the \
    question. Account numbers and IBANs are never returned. Treat all of this as private data.
    """
}
