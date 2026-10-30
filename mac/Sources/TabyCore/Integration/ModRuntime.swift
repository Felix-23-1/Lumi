// Integrator (Paket 3): führt Mods aus – Kurzbefehle über `shortcuts`,
// Skripte in der JavaScript-Sandbox. Läuft nur, wenn der Mod eingeschaltet
// und seine aktuelle Fassung freigegeben ist (ModLibrary.isRunnable).
import Foundation

/// Aktionen, die der Host von Lumi-Diensten braucht (Fokus, Wecker, Gewohnheiten, Nachrichten, Mail).
/// Nicht gesetzt = nicht verfügbar. Die Rechte prüft die Sandbox vorher.
struct ModHostActions {
  var checkHabit: ((String) async throws -> Habit)?
  var startFocus: ((Int?) async throws -> Void)?
  var stopFocus: (() async -> Void)?
  var focusIsRunning: (() -> Bool)?
  var startTimer: ((Int, String) async throws -> Void)?
  var recentMessages: ((Int) async -> [JSONValue])?
  var openMailDraft: ((MailDraft) async throws -> Void)?
  /// Aufgabe erledigen über den App-Weg (Rückgängig, Notion-Rückschreiben); siehe CoreServices.modHostActions.
  var completeTask: ((String) async throws -> Void)?
}

/// Lumi-Seite für Skript-Mods (die Sandbox prüft die Rechte vorher).
final class StoreModHost: ModHostAPI, @unchecked Sendable {
  private let store: Store
  private let calendar: () -> ToolCalendarAccess
  private let notifier: Notifier
  private let onChange: () -> Void
  /// Setzt einen Mod-Kurztext in der Insel (Paket 8); modId + Text + Dauer in Sekunden.
  private let onIslandText: (String, String, Double) -> Void
  private let modId: String
  private let actions: ModHostActions
  private let mods: ModLibrary?

  init(store: Store, calendar: @escaping () -> ToolCalendarAccess, notifier: Notifier, onChange: @escaping () -> Void,
       modId: String = "", onIslandText: @escaping (String, String, Double) -> Void = { _, _, _ in },
       actions: ModHostActions = ModHostActions(), mods: ModLibrary? = nil) {
    self.store = store
    self.calendar = calendar
    self.notifier = notifier
    self.onChange = onChange
    self.modId = modId
    self.onIslandText = onIslandText
    self.actions = actions
    self.mods = mods
  }

  func listTasks() async throws -> [TabyTask] { try store.tasks.list() }

  func addTask(title: String, due: String?) async throws -> TabyTask {
    let t = try store.tasks.add(title: title, notes: nil, due: due)
    onChange()
    return t
  }

  func completeTask(id: String) async throws {
    // Nie direkt im Store: nur der App-Weg schreibt auch nach Notion und legt den Rückgängig-Eintrag an.
    guard let complete = actions.completeTask else { throw ScriptBridgeError.unavailable }
    try await complete(id)
    onChange()
  }

  func listNotes() async throws -> [Note] { try store.notes.list() }

  func addNote(title: String, content: String) async throws -> Note {
    let n = try store.notes.add(title: title, content: content)
    onChange()
    return n
  }

  func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    await calendar().listAllEvents(from: from, to: to).events
  }

  /// Wird vom Skript-Thread aufgerufen: Notifier ist threadsicher (Fan-out mit
  /// Hop auf den MainActor für die Insel).
  func notify(_ n: TabyNotification) { notifier.send(n) }

  func setIslandText(_ text: String, seconds: Double) { onIslandText(modId, text, seconds) }

  // MARK: Welle C

  func listHabits() async throws -> [Habit] { try store.habits.list() }

  func checkHabit(id: String) async throws -> Habit {
    guard let check = actions.checkHabit else { throw ScriptBridgeError.unavailable }
    let habit = try await check(id)
    onChange()
    return habit
  }

  func startFocus(minutes: Int?) async throws {
    guard let start = actions.startFocus else { throw ScriptBridgeError.unavailable }
    try await start(minutes)
  }

  func stopFocus() async throws {
    guard let stop = actions.stopFocus else { throw ScriptBridgeError.unavailable }
    await stop()
  }

  func focusIsRunning() async throws -> Bool {
    guard let running = actions.focusIsRunning else { throw ScriptBridgeError.unavailable }
    return running()
  }

  func startTimer(minutes: Int, label: String) async throws {
    guard let start = actions.startTimer else { throw ScriptBridgeError.unavailable }
    try await start(minutes, label)
  }

  func recentMessages(limit: Int) async throws -> [JSONValue] {
    guard let recent = actions.recentMessages else { throw ScriptBridgeError.unavailable }
    // Fremder Text: nur als Material, nie als Anweisung (wie bei Werkzeug-Ergebnissen).
    return await recent(limit)
  }

  func openMailDraft(_ draft: MailDraft) async throws {
    guard let open = actions.openMailDraft else { throw ScriptBridgeError.unavailable }
    try await open(draft)
  }

  func storageGet(key: String) async throws -> JSONValue {
    guard let mods else { throw ScriptBridgeError.unavailable }
    return try mods.storageGet(modId, key: key)
  }

  func storageSet(key: String, value: JSONValue) async throws {
    guard let mods else { throw ScriptBridgeError.unavailable }
    try mods.storageSet(modId, key: key, value: value)
  }
}

enum ModRuntime {
  /// Name eines Mod-Werkzeugs im Modell ("mod_" + id, "-" → "_").
  static func toolName(_ id: String) -> String { "mod_" + id.replacingOccurrences(of: "-", with: "_") }

  static func modId(fromTool name: String) -> String? {
    guard name.hasPrefix("mod_") else { return nil }
    return String(name.dropFirst(4)).replacingOccurrences(of: "_", with: "-")
  }

  static func toolDef(_ m: ModManifest) -> ToolDef? {
    guard let tool = m.tool else { return nil }
    return ToolDef(name: toolName(m.id), description: "Mod „\(m.name)“: \(tool.description)", parameters: tool.parameters)
  }

  /// Werkzeug, mit dem das Modell neue Skript-Mods anlegt (immer ausgeschaltet).
  static let createModTool = ToolDef(
    name: "create_mod",
    description: """
      Legt einen neuen Skript-Mod (JavaScript) an. Er ist danach AUSGESCHALTET – der Nutzer prüft Rechte und Code \
      im Reiter „Mods“ und schaltet ihn selbst ein. Das Skript definiert `async function run(input)` und darf nur \
      die globale API `taby` nutzen: taby.tasks.list()/add({title,due})/complete(id), taby.notes.list()/add({title,content}), \
      taby.calendar.events(from,to), taby.notify(title,body), taby.http.get(url) (nur https, nur freigegebene Domains) \
      und console.log. Rechte nur so viele wie nötig.
      """,
    parameters: [
      "type": "object",
      "properties": [
        "id": ["type": "string", "description": "kleinbuchstaben-mit-bindestrich, 3–40 Zeichen"],
        "name": ["type": "string"],
        "description": ["type": "string"],
        "code": ["type": "string", "description": "JavaScript mit async function run(input)"],
        "permissions": [
          "type": "array", "items": ["type": "string"],
          "description": .string(ModPermission.known.sorted().joined(separator: ", ") + ", http:<Domain>"),
        ],
        "tool_description": ["type": "string", "description": "Falls gesetzt: das Modell darf den Mod als Werkzeug nutzen"],
        "triggers": ["type": "array", "items": ["type": "string", "enum": ["focusStarted", "focusFinished", "dayStarted", "dayEnded"]]],
      ],
      "required": ["id", "name", "description", "code"],
    ])

  static func manifest(fromCreateArgs a: JSONValue) -> (ModManifest, String)? {
    guard let id = a["id"]?.stringValue, let name = a["name"]?.stringValue,
          let desc = a["description"]?.stringValue, let code = a["code"]?.stringValue else { return nil }
    let perms = a["permissions"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let triggers = a["triggers"]?.arrayValue?.compactMap { $0.stringValue.flatMap(ModTrigger.init(rawValue:)) } ?? []
    let tool = a["tool_description"]?.stringValue.map { ModTool(description: $0) }
    let m = ModManifest(id: id, name: name, description: desc, author: "Lumi", kind: .script, entry: "main.js",
                        tool: tool, triggers: triggers, permissions: perms)
    return (m, code)
  }
}
