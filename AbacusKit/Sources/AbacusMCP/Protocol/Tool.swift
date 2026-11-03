import Foundation

/// A tool failure the AI client should see as the tool's own error (bad arguments, a refused
/// write, a missing record), not as a protocol error.
public struct ToolError: Error, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// One MCP tool: a name, a description for the model, a JSON Schema for its arguments and the
/// handler. `isWrite` tools are only offered when the server runs with writes enabled.
public struct MCPTool: Sendable {
  public let name: String
  public let description: String
  public let inputSchema: JSONValue
  public let isWrite: Bool
  public let handler: @Sendable (JSONValue) async throws -> JSONValue

  public init(
    name: String, description: String, inputSchema: JSONValue, isWrite: Bool = false,
    handler: @escaping @Sendable (JSONValue) async throws -> JSONValue
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.isWrite = isWrite
    self.handler = handler
  }

  var listing: JSONValue {
    [
      "name": .string(name), "description": .string(description), "inputSchema": inputSchema,
      "annotations": ["readOnlyHint": .bool(!isWrite)],
    ]
  }
}

/// Builders for the small JSON Schemas the tools declare.
enum Schema {
  static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
    if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
    return .object(schema)
  }

  static func string(_ description: String, options: [String]? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
    if let options { schema["enum"] = .array(options.map(JSONValue.string)) }
    return .object(schema)
  }

  static func integer(_ description: String) -> JSONValue {
    ["type": "integer", "description": .string(description)]
  }

  static func boolean(_ description: String) -> JSONValue {
    ["type": "boolean", "description": .string(description)]
  }

  static func array(of item: JSONValue, _ description: String) -> JSONValue {
    ["type": "array", "items": item, "description": .string(description)]
  }
}

/// Typed access to a tool's arguments with clear errors for the model.
struct Arguments {
  let raw: JSONValue

  init(_ raw: JSONValue) { self.raw = raw }

  func string(_ key: String) -> String? {
    guard let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  func requiredString(_ key: String) throws -> String {
    guard let value = string(key) else { throw ToolError("Missing argument “\(key)”") }
    return value
  }

  func int(_ key: String) -> Int? { raw[key]?.intValue }
  func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
  func strings(_ key: String) -> [String] { raw[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
}
