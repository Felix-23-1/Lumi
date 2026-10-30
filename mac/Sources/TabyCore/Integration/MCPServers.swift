// Fremde MCP-Server im Chat: Werkzeuge anbieten, schreibende nur mit Bestätigung,
// Ergebnisse als fremder Inhalt. Die Verwaltung (Start, Cache, Leerlauf) liegt in MCPManager.
import Foundation

extension CoreServices {
  /// Werkzeuge der aktivierten Server für diesen Zug. Startet einen Server nur, wenn sein Cache leer ist.
  func mcpRoutesForTurn(_ servers: [MCPServerConfig]) async -> [MCPRoute] {
    await MCPManager.shared.offeredTools(for: servers)
  }

  func mcpToolDefs(_ routes: [MCPRoute]) -> [ToolDef] {
    routes.map { r in
      ToolDef(name: r.offeredName,
              description: "[MCP-Server „\(r.server.name)“] \(r.tool.description)",
              parameters: r.tool.inputSchema)
    }
  }

  /// Führt ein Werkzeug aus. Prüft vorher, ob der Server noch aktiv ist und schreiben darf.
  func mcpCall(_ route: MCPRoute, argumentsJSON: String) async -> JSONValue {
    let allowed = settings.mcpServers.contains {
      $0.id == route.server.id && $0.enabled && ($0.allowWrite || !route.isWrite)
    }
    guard allowed else {
      return ToolJSON.failure(code: "MCP_OFF", error: "Der MCP-Server ist aus oder darf nicht schreiben.")
    }
    let args = JSONValue.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON) ?? .object([:])
    guard case .object = args else {
      return ToolJSON.failure(code: "INVALID_ARGS", error: "Argumente müssen ein Objekt sein")
    }
    do {
      return MCPToolPolicy.resultJSON(try await MCPManager.shared.call(route, arguments: args))
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "MCP-Aufruf fehlgeschlagen."
      return ToolJSON.failure(code: "MCP", error: message)
    }
  }

  func mcpConfirmationSummary(_ route: MCPRoute, argumentsJSON: JSONValue) -> String {
    "MCP-Server „\(route.server.name)“: \(route.tool.name) \(MCPToolPolicy.argumentsSummary(argumentsJSON))"
  }

  /// „Testen“ in den Einstellungen: startet den Server kurz, liefert die Werkzeugnamen.
  public func testMCPServer(_ config: MCPServerConfig) async -> ToolResult<[String]> {
    do {
      return .ok(try await MCPManager.shared.test(config))
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "Der MCP-Server konnte nicht getestet werden."
      return .failure(code: "MCP", error: message)
    }
  }
}
