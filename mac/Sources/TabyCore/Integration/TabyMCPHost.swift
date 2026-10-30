// Integrator: Werkzeuge der App für externe Agenten (Hermes, Claude) über
// MCP. Läuft auf dem Arbeits-Thread der MCP-Brücke, daher ohne MainActor;
// Speicher und Kalender-Zugang sind threadsicher.
//
// Sicherheit: nur eine feste Liste – lesen und anlegen/abhaken/verschieben,
// NIE löschen (kein delete_*, kein forget_fact, kein cancel_job). Aufträge
// planen (schedule_job) ist ebenfalls ausgeschlossen.
import Foundation

final class TabyMCPHost: MCPToolHost, @unchecked Sendable {
  static let allowed: [String] = [
    "get_overview", "list_tasks", "add_task", "complete_task", "postpone_tasks",
    "list_notes", "search_notes", "add_note",
    "list_events", "add_event", "find_free_time",
    "list_memories",  // remember_fact braucht eine Bestätigung, die MCP nicht zeigen kann
  ]

  private let store: Store
  private let clock: Clock
  private let calendar: () -> ToolCalendarAccess
  /// Nach einer Änderung (UI neu laden, Erinnerungen abgleichen).
  private let onMutation: () -> Void

  init(store: Store, clock: Clock, calendar: @escaping () -> ToolCalendarAccess, onMutation: @escaping () -> Void) {
    self.store = store
    self.clock = clock
    self.calendar = calendar
    self.onMutation = onMutation
  }

  func tools() -> [MCPTool] {
    let readOnly = Set(ToolRegistry.definitions(for: .readOnly).map(\.name))
    return ToolRegistry.definitions
      .filter { Self.allowed.contains($0.name) }
      .map { def in
        MCPTool(name: def.name, title: Self.title(def.name), description: def.description,
                inputSchema: def.parameters, readOnly: readOnly.contains(def.name))
      }
  }

  func call(name: String, arguments: JSONValue) async -> MCPToolResult {
    guard Self.allowed.contains(name) else {
      return MCPToolResult(text: "Werkzeug \"\(name)\" ist für externe Agenten nicht freigegeben.", isError: true)
    }
    let ctx = ToolContext(store: store, calendar: calendar(), mode: .standard, actor: .assistant, clock: clock)
    let result = await ToolRegistry.execute(name: name, args: arguments, ctx: ctx)
    let ok = result["ok"]?.boolValue ?? false
    if ok, !ToolRegistry.readOnlyAllowed.contains(name) { onMutation() }
    return MCPToolResult(text: result.jsonString(), isError: !ok)
  }

  static func title(_ name: String) -> String {
    switch name {
    case "get_overview": "Tagesüberblick"
    case "list_tasks": "Aufgaben auflisten"
    case "add_task": "Aufgabe anlegen"
    case "complete_task": "Aufgabe abhaken"
    case "postpone_tasks": "Aufgaben auf morgen schieben"
    case "list_notes": "Notizen auflisten"
    case "search_notes": "Notizen durchsuchen"
    case "add_note": "Notiz anlegen"
    case "list_events": "Termine auflisten"
    case "add_event": "Termin anlegen (mit Konfliktprüfung)"
    case "find_free_time": "Freie Zeit finden"
    case "list_memories": "Gemerkte Fakten"
    case "remember_fact": "Fakt merken"
    default: name
    }
  }
}
