// Privates nebenbei: Einkauf und Privates landen als Erinnerungen in einer
// gewählten Apple-Liste, nicht als Lumi-Aufgaben. Reine Logik gegen
// RemindersBackend; geprüft in PrivateAndFollowUpChecks.swift.
import Foundation

public enum PrivateListTools {
  public static let noListMessage = "Bitte in den Einstellungen eine Liste für Privates wählen."
  static let maxItems = 50

  public static let definitions: [ToolDef] = [
    ToolDef(
      name: "add_to_private_list",
      description: "Legt Einkaufs- oder Privat-Punkte als Erinnerungen in der Liste für Privates an (Apple Erinnerungen, keine Lumi-Aufgabe).",
      parameters: ToolSchema.object([
        "items": ["type": "array", "items": ["type": "string"], "description": "Je ein Punkt, z. B. Milch"],
      ], required: ["items"])),
    ToolDef(
      name: "list_private_list",
      description: "Listet die offenen Punkte der Liste für Privates.",
      parameters: ToolSchema.object()),
  ]

  /// `listId` leer = keine Liste gewählt. Vor jedem Zugriff prüfen, damit nichts ohne Ziel angelegt wird.
  public static func execute(name: String, argumentsJSON: String, listId: String,
                             backend: RemindersBackend) async -> JSONValue {
    guard !listId.isEmpty else { return ToolJSON.failure(code: "NO_LIST", error: noListMessage) }
    do {
      let args = try parseArgs(argumentsJSON)
      guard await backend.requestAccess() else {
        return ToolJSON.failure(code: "ACCESS", error: "Kein Zugriff auf Erinnerungen. Bitte in den Systemeinstellungen freigeben.")
      }
      switch name {
      case "add_to_private_list": return try await add(args, listId: listId, backend: backend)
      case "list_private_list": return try await list(listId: listId, backend: backend)
      default: return ToolJSON.failure(code: "UNKNOWN_TOOL", error: "Unbekanntes Werkzeug \"\(name)\"")
      }
    } catch {
      return failureJSON(error)
    }
  }

  static func add(_ args: ToolArgs, listId: String, backend: RemindersBackend) async throws -> JSONValue {
    guard case .array(let raw)? = args.raw["items"] else {
      throw ToolValidationError("\"items\" muss eine Liste von Texten sein")
    }
    let items = raw.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !items.isEmpty else { throw ToolValidationError("\"items\" enthält keinen Eintrag") }
    guard items.count <= maxItems else { throw ToolValidationError("Höchstens \(maxItems) Punkte auf einmal") }
    for item in items {
      _ = try await backend.create(ExternalReminder(id: "", title: item), listId: listId)
    }
    return ToolJSON.ok(["added": .number(Double(items.count)), "items": .array(items.map { .string($0) })])
  }

  static func list(listId: String, backend: RemindersBackend) async throws -> JSONValue {
    let open = try await backend.fetchAll(listIds: [listId]).filter { !$0.done }
    return ToolJSON.ok([
      "items": .array(open.map { .object(["id": .string($0.id), "title": .string($0.title)]) }),
      "count": .number(Double(open.count)),
    ])
  }

  static func parseArgs(_ text: String) throws -> ToolArgs {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return ToolArgs([:]) }
    guard let value = JSONValue.parse(trimmed) else { throw ToolValidationError("Argumente sind kein gültiges JSON") }
    return try ToolArgs.from(value)
  }

  static func failureJSON(_ error: Error) -> JSONValue {
    if let e = error as? ToolValidationError { return ToolJSON.failure(code: "INVALID_ARGS", error: e.message) }
    let message = (error as? LocalizedError)?.errorDescription ?? "Erinnerungen konnten nicht geändert werden."
    return ToolJSON.failure(code: "REMINDERS", error: message)
  }
}
