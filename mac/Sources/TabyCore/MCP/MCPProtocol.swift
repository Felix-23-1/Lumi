// Reine JSON-RPC-2.0-Logik für taby-mcp (MCP über stdio).
//
// Eine eingehende Nachricht rein, die Antwort (als JSON-Zeile) oder nil für
// Notifications/Client-Antworten raus. Keine Ein-/Ausgabe, keine Datenbank:
// Werkzeuge kommen aus einem `MCPToolBackend`. Zwei Protokoll-Ären:
//   - Legacy: `initialize`-Handshake (2025-11-25, 2025-06-18, 2025-03-26)
//   - Modern: zustandslos, `_meta["io.modelcontextprotocol/protocolVersion"]`
//     pro Anfrage, `server/discover` (2026-07-28)
import Foundation

public enum MCPProtocol {
  public static let modernVersion = "2026-07-28"
  public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
  public static let defaultLegacyVersion = "2025-11-25"
  public static let serverInfo: JSONValue = .object([
    "name": .string("taby"), "title": .string("Lumi"), "version": .string("2.0.0"),
  ])
  public static let instructions =
    "Lumi liefert den Tagesüberblick des Nutzers und legt auf Wunsch neue Aufgaben an."
  static let discoverTTLms: Double = 3_600_000

  /// Behandelt genau eine eingehende Nachricht.
  /// - Returns: Antwort-JSON (ohne Zeilenumbruch) oder nil, wenn keine Antwort gehört.
  public static func handle(
    _ message: String, backend: MCPToolBackend, log: (String) -> Void = logToStderr
  ) -> String? {
    guard let parsed = JSONValue.parse(message) else {
      return encodeError(id: .null, code: -32700, message: "Parse error")
    }
    guard case .object(let obj) = parsed else {
      return encodeError(id: .null, code: -32600, message: "Invalid Request")
    }
    guard let method = obj["method"]?.stringValue else {
      // Antworten des Clients brauchen keine Antwort; alles andere ist ungültig.
      if obj["result"] != nil || obj["error"] != nil { return nil }
      guard let id = obj["id"] else { return nil }
      return encodeError(id: id, code: -32600, message: "Invalid Request")
    }
    // Ohne id ist es eine Notification (z. B. notifications/initialized): keine Antwort.
    guard let id = obj["id"] else { return nil }

    let params = obj["params"] ?? .object([:])
    let metaVersion = params["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue
    if method != "initialize", let v = metaVersion, v != modernVersion {
      return encodeError(
        id: id, code: -32022, message: "Unsupported protocol version",
        data: .object(["supported": .array([.string(modernVersion)]), "requested": .string(v)]))
    }
    let modern = metaVersion == modernVersion || method == "server/discover"

    do {
      let result: JSONValue
      switch method {
      case "initialize":
        result = try initializeResult(params)
      case "server/discover":
        result = discoverResult()
      case "ping":
        result = withResultType(.object([:]), modern: modern)
      case "tools/list":
        result = withResultType(listResult(backend: backend, log: log), modern: modern)
      case "tools/call":
        result = withResultType(try callResult(params: params, backend: backend, log: log), modern: modern)
      default:
        return encodeError(id: id, code: -32601, message: "Method not found: \(method)")
      }
      return JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).jsonString()
    } catch let error as RPCError {
      return encodeError(id: id, code: error.code, message: error.message)
    } catch {
      return encodeError(id: id, code: -32603, message: "Internal error")
    }
  }

  /// Schreibt nur auf stderr (stdout gehört dem Protokoll).
  public static func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  // MARK: Methoden

  private static func initializeResult(_ params: JSONValue) throws -> JSONValue {
    guard let requested = params["protocolVersion"]?.stringValue else {
      throw RPCError(code: -32602, message: "initialize: protocolVersion fehlt")
    }
    let version = legacyVersions.contains(requested) ? requested : defaultLegacyVersion
    return .object([
      "protocolVersion": .string(version),
      "capabilities": capabilities,
      "serverInfo": serverInfo,
      "instructions": .string(instructions),
    ])
  }

  private static func discoverResult() -> JSONValue {
    .object([
      "resultType": .string("complete"),
      "supportedVersions": .array([.string(modernVersion)]),
      "capabilities": capabilities,
      "_meta": .object(["io.modelcontextprotocol/serverInfo": serverInfo]),
      "instructions": .string(instructions),
      "ttlMs": .number(discoverTTLms),
      "cacheScope": .string("public"),
    ])
  }

  private static func listResult(backend: MCPToolBackend, log: (String) -> Void) -> JSONValue {
    do {
      let tools = try backend.listTools()
      return .object(["tools": .array(tools.map(listJSON))])
    } catch {
      log("taby-mcp: Werkzeugliste nicht verfügbar: \(describe(error))")
      return .object(["tools": .array([])])
    }
  }

  private static func callResult(
    params: JSONValue, backend: MCPToolBackend, log: (String) -> Void
  ) throws -> JSONValue {
    guard let name = params["name"]?.stringValue else {
      throw RPCError(code: -32602, message: "tools/call: name fehlt")
    }
    var arguments: JSONValue = .object([:])
    if let a = params["arguments"], a != .null {
      guard case .object = a else {
        throw RPCError(code: -32602, message: "tools/call: arguments muss ein Objekt sein")
      }
      arguments = a
    }
    let result: MCPToolResult
    do {
      result = try backend.call(name: name, arguments: arguments)
    } catch {
      log("taby-mcp: Aufruf \(name) fehlgeschlagen: \(describe(error))")
      result = MCPToolResult(text: describe(error), isError: true)
    }
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
      "isError": .bool(result.isError),
    ])
  }

  // MARK: Hilfen

  private static var capabilities: JSONValue {
    .object(["tools": .object(["listChanged": .bool(false)])])
  }

  private static func listJSON(_ tool: MCPTool) -> JSONValue {
    .object([
      "name": .string(tool.name),
      "title": .string(tool.title),
      "description": .string(tool.description),
      "inputSchema": tool.inputSchema,
      "annotations": .object([
        "readOnlyHint": .bool(tool.readOnly),
        "destructiveHint": .bool(false),
      ]),
    ])
  }

  private static func withResultType(_ result: JSONValue, modern: Bool) -> JSONValue {
    guard modern, case .object(var o) = result else { return result }
    o["resultType"] = .string("complete")
    return .object(o)
  }

  private static func describe(_ error: Error) -> String {
    if let bridge = error as? MCPBridgeError { return bridge.userText }
    return error.localizedDescription
  }

  private static func encodeError(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> String {
    var e: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
    if let data { e["data"] = data }
    return JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(e)]).jsonString()
  }

  private struct RPCError: Error {
    let code: Int
    let message: String
  }
}
