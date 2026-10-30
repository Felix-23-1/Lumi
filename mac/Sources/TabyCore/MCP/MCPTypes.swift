// MCP-Typen für die Brücke zwischen taby-mcp (stdio, vom MCP-Client gestartet)
// und der laufenden Lumi-App. taby-mcp hat keine Datenbank: Werkzeuge laufen
// in der App (MCPToolHost), die Anfragen kommen über den Unix-Socket.
import Foundation

/// Ein Werkzeug, wie es in `tools/list` erscheint.
public struct MCPTool: Equatable, Sendable {
  public var name: String
  public var title: String
  public var description: String
  public var inputSchema: JSONValue
  public var readOnly: Bool

  public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool) {
    self.name = name
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.readOnly = readOnly
  }
}

/// Ergebnis eines Werkzeugaufrufs (wird als MCP-`content` verpackt).
public struct MCPToolResult: Equatable, Sendable {
  public var text: String
  public var isError: Bool

  public init(text: String, isError: Bool) {
    self.text = text
    self.isError = isError
  }
}

/// App-Seite: liefert die Werkzeuge und führt sie aus. Wird von
/// `MCPBridgeServer` aufgerufen (Verdrahtung durch den Orchestrator).
public protocol MCPToolHost: AnyObject {
  func tools() -> [MCPTool]
  func call(name: String, arguments: JSONValue) async -> MCPToolResult
}

/// taby-mcp-Seite: woher `MCPProtocol` Werkzeuge bezieht. Implementiert von
/// `MCPBridgeClient`; in Prüfungen durch einen Fake ersetzbar.
public protocol MCPToolBackend: AnyObject {
  func listTools() throws -> [MCPTool]
  func call(name: String, arguments: JSONValue) throws -> MCPToolResult
}

/// Fehler auf der taby-mcp-Seite beim Gespräch mit der App.
public enum MCPBridgeError: Error, Equatable, Sendable {
  /// Kein Socket / keine Verbindung: Lumi läuft nicht.
  case appNotRunning
  /// Sonstiger Fehler (Text für den Nutzer).
  case failed(String)

  /// Text, der an den MCP-Client geht.
  public var userText: String {
    switch self {
    case .appNotRunning: return "Lumi läuft nicht. Bitte Lumi starten."
    case .failed(let message): return message
    }
  }
}

public enum MCPBridgeServerError: Error, Equatable {
  case socketPathTooLong(String)
  case socketFailed(String)
}

public enum MCPPaths {
  /// Socket der laufenden App: ~/Library/Application Support/de.felix.taby/taby-mcp.sock
  public static var defaultSocketPath: String {
    NSHomeDirectory() + "/Library/Application Support/de.felix.taby/taby-mcp.sock"
  }
}

extension MCPTool {
  /// Transportform auf dem Socket (ohne MCP-Annotationen; die baut `MCPProtocol`).
  var bridgeJSON: JSONValue {
    .object([
      "name": .string(name),
      "title": .string(title),
      "description": .string(description),
      "inputSchema": inputSchema,
      "readOnly": .bool(readOnly),
    ])
  }

  init?(bridgeJSON v: JSONValue) {
    guard let name = v["name"]?.stringValue, let title = v["title"]?.stringValue,
      let description = v["description"]?.stringValue
    else { return nil }
    self.init(
      name: name, title: title, description: description,
      inputSchema: v["inputSchema"] ?? .object([:]), readOnly: v["readOnly"]?.boolValue ?? false)
  }
}
