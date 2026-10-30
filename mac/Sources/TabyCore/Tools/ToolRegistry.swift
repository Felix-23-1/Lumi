// Dispatcher (Port von src/main/tools/index.ts): strenge Validierung →
// Lesemodus-Wächter → Werkzeug → Protokoll. BAUPLAN Abschnitt 7: read-only
// erlaubt nur Lesewerkzeuge + add_task + add_note; jede ausgeführte Änderung
// (und jeder Fehlschlag) landet in action_log.
import Foundation

public enum ToolRegistry {
  /// Alle Werkzeuge: die 21 aus BAUPLAN Abschnitt 7 (ohne Habits), find_free_time (Paket 1),
  /// remember_fact/list_memories/forget_fact und postpone_tasks (Paket 2).
  public static let definitions: [ToolDef] =
    OverviewTools.defs + TaskTools.defs + NoteTools.defs + EventTools.defs
    + FreeTimeTools.defs + JobTools.defs + MemoryTools.defs + PostponeTools.defs + AssistantTools.defs
    + ContactTools.defs

  static let handlers: [String: ToolHandler] = {
    var h: [String: ToolHandler] = [:]
    for part in [OverviewTools.handlers, TaskTools.handlers, NoteTools.handlers,
                 EventTools.handlers, FreeTimeTools.handlers, JobTools.handlers, MemoryTools.handlers,
                 PostponeTools.handlers, AssistantTools.handlers, ContactTools.handlers] {
      h.merge(part) { a, _ in a }
    }
    return h
  }()

  /// Im JobMode read-only erlaubt: Lesewerkzeuge + add_task + add_note + list_memories.
  public static let readOnlyAllowed: Set<String> = [
    "get_overview", "list_tasks", "add_task", "list_notes", "search_notes", "add_note",
    "list_events", "list_calendars", "find_free_time", "list_jobs", "list_memories",
    "list_messages", "list_habits", "show_plan", "list_weekly_goals",
  ]

  /// Nur echte Änderungen landen (auch bei Erfolg) im Protokoll.
  public static let mutatingTools: Set<String> = [
    "add_task", "update_task", "complete_task", "reopen_task", "delete_task", "add_note", "update_note",
    "delete_note", "add_event", "delete_event", "move_event", "schedule_job", "cancel_job",
    "remember_fact", "forget_fact", "postpone_tasks",
    "check_habit", "add_habit", "send_message", "start_focus", "stop_focus", "plan_day",
  ]

  /// Werkzeuge, die nur nach Bestätigung durch den Nutzer laufen (Löschen/Verschieben).
  /// Die Bestätigung selbst setzt der Dienst (CoreServices) durch.
  public static let confirmationRequired: Set<String> = [
    "delete_task", "delete_note", "cancel_job", "forget_fact", "delete_event", "move_event",
    "remember_fact", "send_message", "save_vault_note", "find_secret",
  ]

  /// Werkzeuge, die dem Modell im jeweiligen Modus angeboten werden.
  public static func definitions(for mode: JobMode) -> [ToolDef] {
    mode == .readOnly ? definitions.filter { readOnlyAllowed.contains($0.name) } : definitions
  }

  private static func log(_ ctx: ToolContext, _ name: String, _ args: JSONValue, ok: Bool, error: String?) {
    _ = try? ctx.store.actionLog.log(actor: ctx.actor, tool: name, args: args, ok: ok, error: error)
  }

  /// Führt ein Werkzeug aus. Ergebnis ist immer ein Objekt mit `ok`; bei
  /// Fehlern zusätzlich `code` (UNKNOWN_TOOL, READ_ONLY, INVALID_ARGS,
  /// NOT_FOUND, CONFLICT, NO_WRITE_PROVIDER, CALENDAR_ERROR, ERROR) und `error`.
  public static func execute(name: String, args: JSONValue, ctx: ToolContext) async -> JSONValue {
    guard let handler = handlers[name] else {
      let error = "Unbekanntes Werkzeug \"\(name)\""
      log(ctx, name, args, ok: false, error: error)
      return ToolJSON.failure(code: "UNKNOWN_TOOL", error: error)
    }
    if ctx.mode == .readOnly && !readOnlyAllowed.contains(name) {
      let error = "Werkzeug \"\(name)\" ist im Lesemodus gesperrt"
      log(ctx, name, args, ok: false, error: error)
      return ToolJSON.failure(code: "READ_ONLY", error: error)
    }
    do {
      let parsed = try ToolArgs.from(args)
      let result = try await handler(ctx, parsed)
      let ok = result["ok"]?.boolValue ?? false
      if mutatingTools.contains(name) || !ok {
        log(ctx, name, args, ok: ok, error: ok ? nil : (result["error"]?.stringValue ?? ""))
      }
      return result
    } catch let e as ToolValidationError {
      log(ctx, name, args, ok: false, error: e.message)
      return ToolJSON.failure(code: "INVALID_ARGS", error: e.message)
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      log(ctx, name, args, ok: false, error: message)
      return ToolJSON.failure(code: "ERROR", error: message)
    }
  }

  /// Wie `execute`, mit den Argumenten als JSON-Text (so liefert sie das
  /// Modell in `tool_calls[].function.arguments`). Leerer Text gilt als {}.
  public static func execute(name: String, argumentsJSON: String, ctx: ToolContext) async -> JSONValue {
    let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return await execute(name: name, args: [:], ctx: ctx) }
    guard let args = JSONValue.parse(trimmed) else {
      let error = "Argumente sind kein gültiges JSON"
      log(ctx, name, .string(argumentsJSON), ok: false, error: error)
      return ToolJSON.failure(code: "INVALID_ARGS", error: error)
    }
    return await execute(name: name, args: args, ctx: ctx)
  }

  /// Typisierte Sicht auf ein Werkzeug-Ergebnis: Nutzlast unter `key`.
  public static func typed<T: Decodable>(_ result: JSONValue, key: String, as type: T.Type = T.self) -> ToolResult<T> {
    if result["ok"]?.boolValue == true {
      if let v = result[key].flatMap({ ToolJSON.decode(T.self, from: $0) }) { return .ok(v) }
      return .failure(code: "ERROR", error: "Unerwartete Antwort des Werkzeugs")
    }
    return .failure(code: result["code"]?.stringValue ?? "ERROR", error: result["error"]?.stringValue ?? "Fehler")
  }

  /// Typisierte Sicht auf ein Ergebnis ohne Nutzlast (delete_*, cancel_job).
  public static func empty(_ result: JSONValue) -> ToolResult<Empty> {
    if result["ok"]?.boolValue == true { return .ok(Empty()) }
    return .failure(code: result["code"]?.stringValue ?? "ERROR", error: result["error"]?.stringValue ?? "Fehler")
  }

  /// add_event über den Dispatcher (mit Protokoll und Lesemodus-Wächter),
  /// Ergebnis als Vertragstyp – für die Oberfläche (manuelles Eintragen).
  public static func addEvent(_ req: AddEventRequest, ctx: ToolContext) async -> AddEventResult {
    var args: [String: JSONValue] = ["title": .string(req.event.title), "start": .string(req.event.start)]
    if let end = req.event.end { args["end"] = .string(end) }
    if let notes = req.event.notes { args["notes"] = .string(notes) }
    if req.allowConflict { args["allow_conflict"] = true }
    return EventTools.fromJSON(await execute(name: "add_event", args: .object(args), ctx: ctx))
  }
}

/// Einstieg für die Agent-Schleife: führt `name` mit `args` aus (siehe
/// `ToolRegistry.execute`).
public func executeTool(name: String, args: JSONValue, ctx: ToolContext) async -> JSONValue {
  await ToolRegistry.execute(name: name, args: args, ctx: ctx)
}
