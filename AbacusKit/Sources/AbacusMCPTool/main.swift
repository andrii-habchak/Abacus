import AbacusMCP
import AbacusStore
import Foundation

// Stdio entry point of the local MCP server (`abacus-mcp`).
//
//   abacus-mcp [--db <path>]
//
// Reads the app database (default ~/Library/Application Support/Abacus/abacus.sqlite) through a
// read-only connection. `--db` points at another file, for example a scratch copy. Protocol
// messages go to standard output, diagnostics to standard error.

var databasePath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--db": databasePath = arguments.popFirst()
  case "--help", "-h":
    print("usage: abacus-mcp [--db <path>]")
    exit(0)
  default:
    StdioTransport.log("abacus-mcp: unknown argument \(argument)")
    exit(2)
  }
}

do {
  let url = try databasePath.map { URL(fileURLWithPath: $0) } ?? AbacusDatabase.defaultURL()
  let server = try ServerFactory.make(databaseURL: url)
  await StdioTransport.run(server)
} catch {
  StdioTransport.log("abacus-mcp: \(error)")
  exit(1)
}
