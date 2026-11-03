import Foundation

/// A small MCP server: JSON-RPC 2.0 with the `initialize`, `ping`, `tools/list` and `tools/call`
/// methods, one JSON message per line (the stdio transport). Hand-written so the package needs
/// no extra dependency; the protocol surface Abacus uses is this small.
public struct MCPServer: Sendable {
  public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

  public let name: String
  public let version: String
  public let instructions: String
  public let tools: [MCPTool]

  public init(name: String = AbacusMCP.serverName, version: String = AbacusMCP.serverVersion, instructions: String, tools: [MCPTool]) {
    self.name = name
    self.version = version
    self.instructions = instructions
    self.tools = tools
  }

  enum RPCCode {
    static let parse = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
  }

  /// Handles one incoming line; returns the response line, or nil for notifications.
  public func handle(line: String) async -> String? {
    guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
      message.objectValue != nil
    else {
      return Self.error(id: .null, code: RPCCode.parse, message: "Parse error")
    }
    guard let method = message["method"]?.stringValue else {
      // A response to a request we never send; ignore.
      return message["id"] != nil && message["result"] == nil && message["error"] == nil
        ? Self.error(id: message["id"] ?? .null, code: RPCCode.invalidRequest, message: "Missing method") : nil
    }
    guard let id = message["id"] else { return nil }  // notification (notifications/initialized, cancelled, …)
    let params = message["params"] ?? [:]
    switch method {
    case "initialize":
      let requested = params["protocolVersion"]?.stringValue
      let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
      return Self.result(
        id: id,
        [
          "protocolVersion": .string(version),
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": .string(name), "version": .string(self.version)],
          "instructions": .string(instructions),
        ])
    case "ping":
      return Self.result(id: id, [:])
    case "tools/list":
      return Self.result(id: id, ["tools": .array(tools.map(\.listing))])
    case "tools/call":
      guard let toolName = params["name"]?.stringValue else {
        return Self.error(id: id, code: RPCCode.invalidParams, message: "Missing tool name")
      }
      guard let tool = tools.first(where: { $0.name == toolName }) else {
        return Self.error(id: id, code: RPCCode.invalidParams, message: "Unknown tool “\(toolName)”")
      }
      return Self.result(id: id, await call(tool, arguments: params["arguments"] ?? [:]))
    default:
      return Self.error(id: id, code: RPCCode.methodNotFound, message: "Method not found: \(method)")
    }
  }

  /// The `tools/call` result: the tool's JSON as text; failures come back as `isError` results
  /// so the model can read the reason and retry.
  func call(_ tool: MCPTool, arguments: JSONValue) async -> JSONValue {
    do {
      let value = try await tool.handler(arguments)
      return ["content": [["type": "text", "text": .string(try value.serialized(pretty: true))]], "isError": false]
    } catch let error as ToolError {
      return Self.failure(error.description)
    } catch {
      return Self.failure("The tool failed: \(error.localizedDescription)")
    }
  }

  static func failure(_ text: String) -> JSONValue {
    ["content": [["type": "text", "text": .string(text)]], "isError": true]
  }

  static func result(id: JSONValue, _ result: JSONValue) -> String {
    encode(["jsonrpc": "2.0", "id": id, "result": result])
  }

  static func error(id: JSONValue, code: Int, message: String) -> String {
    encode(["jsonrpc": "2.0", "id": id, "error": ["code": .int(Int64(code)), "message": .string(message)]])
  }

  static func encode(_ value: JSONValue) -> String {
    // Single line: the transport frames messages by newline.
    (try? value.serialized()) ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
  }
}

/// Runs a server over standard input and output (newline-delimited JSON). Log text goes to
/// standard error only; standard output carries protocol messages.
public enum StdioTransport {
  public static func run(_ server: MCPServer) async {
    while let line = readLine(strippingNewline: true) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if let response = await server.handle(line: trimmed) {
        print(response)
        fflush(stdout)
      }
    }
  }

  public static func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}
