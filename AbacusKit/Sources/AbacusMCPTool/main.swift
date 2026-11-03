import AbacusMCP
import AbacusStore
import Foundation

// Stdio entry point of the local MCP server (`abacus-mcp`).
//
//   abacus-mcp [--db <path>] [--enable-writes] [--max-rows <n>]
//
// Reads the app database (default ~/Library/Application Support/Abacus/abacus.sqlite) through a
// read-only connection. `--db` points at another file, for example a scratch copy.
// `--enable-writes` adds the write tools (each is propose-then-confirm, preceded by a snapshot
// once per session); `--max-rows` caps the records one write call may change. Protocol messages
// go to standard output, diagnostics to standard error.

var databasePath: String?
var enableWrites = false
var maxRows = WriteSession.defaultMaxRows
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--db": databasePath = arguments.popFirst()
  case "--enable-writes": enableWrites = true
  case "--max-rows":
    guard let value = arguments.popFirst().flatMap(Int.init), value > 0 else {
      StdioTransport.log("abacus-mcp: --max-rows needs a positive number")
      exit(2)
    }
    maxRows = value
  case "--help", "-h":
    print("usage: abacus-mcp [--db <path>] [--enable-writes] [--max-rows <n>]")
    exit(0)
  default:
    StdioTransport.log("abacus-mcp: unknown argument \(argument)")
    exit(2)
  }
}

do {
  let url = try databasePath.map { URL(fileURLWithPath: $0) } ?? AbacusDatabase.defaultURL()
  var writes: WriteConfiguration?
  if enableWrites {
    guard let snapshots = LiveSnapshots.provider else {
      throw ToolError("Write tools need the backup snapshot API, which this build does not have yet.")
    }
    writes = WriteConfiguration(snapshots: snapshots, maxRows: maxRows)
  }
  let server = try ServerFactory.make(databaseURL: url, writes: writes)
  await StdioTransport.run(server)
} catch {
  StdioTransport.log("abacus-mcp: \(error)")
  exit(1)
}
