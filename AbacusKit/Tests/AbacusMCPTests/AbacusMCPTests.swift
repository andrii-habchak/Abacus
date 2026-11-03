import AbacusMCP
import Foundation
import Testing

@Suite("MCP · protocol and amounts")
struct ProtocolTests {
  let server = MCPServer(
    instructions: "hello",
    tools: [
      MCPTool(name: "echo", description: "Echo", inputSchema: ["type": "object"]) { args in args },
      MCPTool(name: "fail", description: "Fails", inputSchema: ["type": "object"]) { _ in throw ToolError("nope") },
    ])

  func send(_ json: String) async throws -> JSONValue? {
    guard let line = await server.handle(line: json) else { return nil }
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
  }

  @Test("The server has a name")
  func serverName() {
    #expect(AbacusMCP.serverName == "abacus-mcp")
  }

  @Test("initialize answers with the client's protocol version and the tools capability")
  func initialize() async throws {
    let response = try #require(
      try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
    #expect(response["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
    #expect(response["result"]?["serverInfo"]?["name"]?.stringValue == "abacus-mcp")
    #expect(response["result"]?["capabilities"]?["tools"] != nil)
    #expect(response["id"]?.intValue == 1)
  }

  @Test("An unknown protocol version gets the newest one this server speaks")
  func unknownVersion() async throws {
    let response = try #require(
      try await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
    #expect(response["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedVersions[0])
    #expect(response["id"]?.stringValue == "a")
  }

  @Test("Notifications are never answered")
  func notification() async throws {
    #expect(try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
  }

  @Test("tools/list names every tool and marks read-only ones")
  func list() async throws {
    let response = try #require(try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    let tools = try #require(response["result"]?["tools"]?.arrayValue)
    #expect(tools.compactMap { $0["name"]?.stringValue } == ["echo", "fail"])
    #expect(tools[0]["annotations"]?["readOnlyHint"]?.boolValue == true)
  }

  @Test("tools/call returns the handler's JSON as text; a ToolError becomes an isError result")
  func call() async throws {
    let ok = try #require(
      try await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":1}}}"#))
    #expect(ok["result"]?["isError"]?.boolValue == false)
    #expect(ok["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("\"x\" : 1") == true)
    let bad = try #require(try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#))
    #expect(bad["result"]?["isError"]?.boolValue == true)
    #expect(bad["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "nope")
  }

  @Test("Protocol errors: parse error, unknown method, unknown tool")
  func errors() async throws {
    #expect(try await send("{not json")?["error"]?["code"]?.intValue == -32700)
    #expect(try await send(#"{"jsonrpc":"2.0","id":5,"method":"nope"}"#)?["error"]?["code"]?.intValue == -32601)
    #expect(
      try await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"zzz"}}"#)?["error"]?["code"]?.intValue
        == -32602)
  }

  @Test("Amounts are exact decimal strings and parse back")
  func amounts() {
    #expect(Amounts.string(minor: -12345) == "-123.45")
    #expect(Amounts.string(minor: 5) == "0.05")
    #expect(Amounts.string(minor: 100_000) == "1000.00")
    #expect(Amounts.minor(from: "1 234,50") == 123_450)
    #expect(Amounts.minor(from: "-0.5") == -50)
    #expect(Amounts.minor(from: "12.345") == nil)
    #expect(Amounts.minor(from: "abc") == nil)
    #expect(Amounts.minor(from: "") == nil)
  }
}
