// Werkzeuge für Aufgaben, Notizen, Habits und Aufträge (Port von
// src/main/tools/{tasks,notes,habits,jobs}.ts). Gleiche Namen, Schemata und
// Fehlercodes wie in TS.
import Foundation

typealias ToolHandler = (ToolContext, ToolArgs) async throws -> JSONValue

enum ToolSchema {
  static func object(_ props: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
    var o: [String: JSONValue] = ["type": "object", "properties": .object(props), "additionalProperties": false]
    if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
    return .object(o)
  }

  static func string(_ description: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["type": "string"]
    if let description { o["description"] = .string(description) }
    return .object(o)
  }

  static let idOnly = object(["id": string("ID")], required: ["id"])
}

private func notFound(_ what: String, _ id: String) -> JSONValue {
  ToolJSON.failure(code: "NOT_FOUND", error: "\(what) \"\(id)\" nicht gefunden")
}

/// Ordnername (Groß/Klein egal) → Ordner-ID. Gibt es den Namen in mehreren Kategorien, zählt die
/// Kategorie der Aufgabe (`category`, nil = keine). Unbekannt: Fehler mit den vorhandenen Namen.
private func resolveFolder(_ ctx: ToolContext, _ name: String, category: String?) throws -> String {
  let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
  let named = try ctx.store.taskFolders.list().filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
  if let folder = named.first(where: { $0.categoryId == category }) ?? (named.count == 1 ? named[0] : nil) {
    return folder.id
  }
  if named.count > 1 {
    throw ToolValidationError("Ordner \"\(trimmed)\" gibt es in mehreren Kategorien. Bitte eine Kategorie angeben.")
  }
  let existing = try ctx.store.taskFolders.list().map(\.name)
  let known = existing.isEmpty ? "keine" : existing.joined(separator: ", ")
  throw ToolValidationError("Ordner \"\(trimmed)\" gibt es nicht. Vorhandene Ordner: \(known)")
}

/// Kategorie-Kennung aus dem Werkzeugwert ("" = keine). Unbekannt: Fehler mit den erlaubten Kategorien.
private func resolveCategory(_ ctx: ToolContext, _ raw: String?) throws -> String? {
  guard let id = TaskCategoryRules.normalize(raw) else { return nil }
  let defs = try ctx.store.settings.get().taskCategories
  guard defs.contains(where: { $0.id == id }) else { throw ToolValidationError(TaskCategoryRules.unknownMessage(id, in: defs)) }
  return id
}

// MARK: - Aufgaben

private let categoryHelp = "Kategorie-Kennung aus den Einstellungen (Systemprompt „Kategorien“, z. B. \"arbeit\"); \"\" = keine Kategorie"

private let recurrenceHelp = "Wiederholung: \"täglich\", \"werktags\", \"wöchentlich\", \"monatlich\" (oder daily, weekdays, weekly, monthly); \"\" = keine"

/// Wiederholung aus dem Werkzeugwert; "" = keine Wiederholung (nil).
private func parseRecurrence(_ raw: String) throws -> TaskRecurrence? {
  let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
  if key.isEmpty { return nil }
  let german: [String: TaskRecurrence] = ["täglich": .daily, "werktags": .weekdays, "wöchentlich": .weekly,
                                          "monatlich": .monthly]
  if let r = german[key] ?? TaskRecurrence(rawValue: key) { return r }
  throw ToolValidationError("\"recurrence\" muss täglich, werktags, wöchentlich, monatlich oder leer sein")
}

private let minutesSchema: JSONValue = .object([
  "type": "integer", "description": .string("Geschätzte Dauer in Minuten (1-600), bei update null = entfernen")])

private func parseStatus(_ raw: String) throws -> TaskStatus {
  let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
  let names: [String: TaskStatus] = ["": .open, "offen": .open, "in bearbeitung": .inProgress,
                                     "info fehlt": .needsInfo, "fehlende info": .needsInfo]
  if let s = names[key] ?? TaskStatus(rawValue: raw) { return s }
  throw ToolValidationError("\"status\" muss offen, in Bearbeitung oder Info fehlt sein")
}

private let priorityHelp = "Priorität: \"hoch\", \"mittel\", \"niedrig\"; \"\" = keine Priorität"

private func parsePriority(_ raw: String) throws -> TaskPriority {
  let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
  let names: [String: TaskPriority] = ["": .none, "keine": .none, "hoch": .high, "wichtig": .high,
                                       "mittel": .medium, "normal": .medium, "niedrig": .low, "gering": .low]
  if let p = names[key] ?? TaskPriority(rawValue: key) { return p }
  throw ToolValidationError("\"priority\" muss hoch, mittel, niedrig oder leer sein")
}

private let tagsSchema: JSONValue = .object([
  "type": "array", "items": .object(["type": "string"]),
  "description": .string("Kennzeichen ohne #, z. B. [\"kunde-x\", \"angebot\"]; bei update ersetzt die Liste alle, [] entfernt alle")])

private func parseTags(_ args: ToolArgs) throws -> [String]? {
  guard let v = args.raw["tags"], v != .null else { return nil }
  guard case .array(let items) = v else { throw ToolValidationError("\"tags\" muss eine Liste von Texten sein") }
  return try items.map { item in
    guard case .string(let s) = item else { throw ToolValidationError("\"tags\" darf nur Texte enthalten") }
    return s
  }
}

private func parseMinutes(_ args: ToolArgs) throws -> Int? {
  guard let v = args.raw["minutes"], v != .null else { return nil }
  guard case .number(let n) = v, n.rounded() == n, (1...600).contains(n) else {
    throw ToolValidationError("\"minutes\" muss eine ganze Zahl von 1 bis 600 sein")
  }
  return Int(n)
}

enum TaskTools {
  static let defs: [ToolDef] = [
    ToolDef(name: "add_task", description: "Legt eine neue Aufgabe an.", parameters: ToolSchema.object([
      "title": ToolSchema.string("Titel der Aufgabe"),
      "notes": ToolSchema.string("Notiz (optional)"),
      "due": ToolSchema.string("Fälligkeit \"JJJJ-MM-TT\" oder \"JJJJ-MM-TTTHH:mm\" (optional)"),
      "category": ToolSchema.string(categoryHelp),
      "folder": ToolSchema.string("Name eines bestehenden Aufgaben-Ordners (optional, Groß/Klein egal)"),
      "recurrence": ToolSchema.string(recurrenceHelp),
      "minutes": minutesSchema,
      "tags": tagsSchema,
      "priority": ToolSchema.string(priorityHelp),
    ], required: ["title"])),
    ToolDef(name: "list_tasks", description: "Listet alle Aufgaben (mit Ordnername, falls zugeordnet).",
            parameters: ToolSchema.object(["category": ToolSchema.string("Nur Aufgaben dieser Kategorie (Kennung, optional)")])),
    ToolDef(name: "update_task", description: "Ändert Titel, Notiz, Fälligkeit, Kategorie oder Ordner einer Aufgabe.",
            parameters: ToolSchema.object([
              "id": ToolSchema.string("Aufgaben-ID"),
              "title": ToolSchema.string(),
              "notes": ToolSchema.string(),
              "due": ToolSchema.string("\"JJJJ-MM-TT\" oder \"JJJJ-MM-TTTHH:mm\""),
              "category": ToolSchema.string(categoryHelp),
              "folder": ToolSchema.string("Name eines bestehenden Aufgaben-Ordners, \"\" = aus dem Ordner nehmen"),
              "recurrence": ToolSchema.string(recurrenceHelp),
              "minutes": minutesSchema,
              "tags": tagsSchema,
              "priority": ToolSchema.string(priorityHelp),
              "status": ToolSchema.string("Bearbeitungsstand: \"offen\", \"in Bearbeitung\" oder \"Info fehlt\""),
            ], required: ["id"])),
    ToolDef(name: "complete_task", description: "Hakt eine Aufgabe als erledigt ab.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Aufgaben-ID")], required: ["id"])),
    ToolDef(name: "reopen_task", description: "Macht eine erledigte Aufgabe wieder offen.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Aufgaben-ID")], required: ["id"])),
    ToolDef(name: "delete_task", description: "Löscht eine Aufgabe.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Aufgaben-ID")], required: ["id"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "add_task": { ctx, args in
      let title = try args.requireString("title")
      let notes = try args.optionalString("notes")
      let due = try args.optionalLocalDateTime("due")
      let category = try resolveCategory(ctx, try args.optionalString("category"))
      var folderId: String? = nil
      if let name = try args.optionalString("folder"), !name.trimmingCharacters(in: .whitespaces).isEmpty {
        folderId = try resolveFolder(ctx, name, category: category)
      }
      var recurrence: TaskRecurrence? = nil
      if let raw = try args.optionalString("recurrence") { recurrence = try parseRecurrence(raw) }
      let task = try ctx.store.tasks.add(title: title, notes: notes, due: due, folderId: folderId,
                                         category: category.map { TaskCategory(rawValue: $0) }, recurrence: recurrence,
                                         minutes: try parseMinutes(args), tags: try parseTags(args) ?? [],
                                         priority: try parsePriority(try args.optionalString("priority") ?? ""))
      return ToolJSON.ok(["task": ToolJSON.encode(task)])
    },
    "list_tasks": { ctx, args in
      let filter = try resolveCategory(ctx, try args.optionalString("category"))
      let folders = try ctx.store.taskFolders.list()
      let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
      // Wirksame Kategorie wie in der Oberfläche (`TaskCategoryRules.effective`).
      let defs = try ctx.store.settings.get().taskCategories
      let notionCategories = NotionTaskOwnership.categories(store: ctx.store)
      let effective: (TabyTask) -> String? = { task in
        TaskCategoryRules.effective(task, folders: folders, defs: defs, notionCategories: notionCategories)
      }
      let shown = try ctx.store.tasks.list().filter { task in
        guard let filter else { return true }
        return effective(task) == filter
      }
      let tasks: [JSONValue] = shown.map { task in
        guard case .object(var o) = ToolJSON.encode(task) else { return ToolJSON.encode(task) }
        o.removeValue(forKey: "folderId")  // Ordner-ID ist intern; das Modell nutzt den Namen
        if let fid = task.folderId, let name = names[fid] { o["folder"] = .string(name) }
        // Notion-Aufgaben: die Kategorie ist die ihres Zugangs, nicht die gespeicherte.
        if notionCategories[task.id] != nil {
          o["category"] = effective(task).map { JSONValue.string($0) }
        }
        return .object(o)
      }
      return ToolJSON.ok(["tasks": .array(tasks)])
    },
    "update_task": { ctx, args in
      let id = try args.requireId()
      // Notion-Aufgaben gehören zur Kategorie ihres Zugangs; die Kategorie ist dort nicht änderbar.
      if args.has("category"), let label = NotionTaskOwnership.label(taskId: id, store: ctx.store) {
        return ToolJSON.failure(code: "VALIDATION",
                                error: "Notion-Aufgaben gehören zur Kategorie ihres Notion-Zugangs (\(label)). Ändere sie in den Einstellungen.")
      }
      let title = args.has("title") ? try args.requireString("title") : nil
      let notes: FieldChange<String> = args.has("notes") ? .set(try args.optionalString("notes")) : .keep
      let due: FieldChange<String> = args.has("due") ? .set(try args.optionalLocalDateTime("due")) : .keep
      // Ohne `category` im Aufruf gilt die bisherige Kategorie der Aufgabe (für die Ordner-Auflösung).
      var categoryId: String? = try ctx.store.tasks.get(id)?.category?.rawValue
      var category: FieldChange<TaskCategory> = .keep
      if args.has("category") {
        categoryId = try resolveCategory(ctx, try args.optionalString("category"))
        category = .set(categoryId.map { TaskCategory(rawValue: $0) })
      }
      var folder: FieldChange<String> = .keep
      if args.has("folder") {
        let name = try args.optionalString("folder") ?? ""
        var folderId: String? = nil
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { folderId = try resolveFolder(ctx, name, category: categoryId) }
        folder = .set(folderId)
      }
      var recurrence: FieldChange<TaskRecurrence> = .keep
      if args.has("recurrence") {
        recurrence = .set(try parseRecurrence(try args.optionalString("recurrence") ?? ""))
      }
      let status = args.has("status") ? try parseStatus(try args.optionalString("status") ?? "") : nil
      let minutes: FieldChange<Int> = args.has("minutes") ? .set(try parseMinutes(args)) : .keep
      let priority = args.has("priority") ? try parsePriority(try args.optionalString("priority") ?? "") : nil
      guard let task = try ctx.store.tasks.update(id, title: title, notes: notes, due: due, category: category,
                                                  folderId: folder, recurrence: recurrence, minutes: minutes, status: status,
                                                  tags: try parseTags(args), priority: priority) else {
        return notFound("Aufgabe", id)
      }
      return ToolJSON.ok(["task": ToolJSON.encode(task)])
    },
    "complete_task": { ctx, args in
      let id = try args.requireId()
      guard let task = try ctx.store.tasks.complete(id) else { return notFound("Aufgabe", id) }
      return ToolJSON.ok(["task": ToolJSON.encode(task)])
    },
    "reopen_task": { ctx, args in
      let id = try args.requireId()
      guard let task = try ctx.store.tasks.reopen(id) else { return notFound("Aufgabe", id) }
      return ToolJSON.ok(["task": ToolJSON.encode(task)])
    },
    "delete_task": { ctx, args in
      let id = try args.requireId()
      guard try ctx.store.tasks.delete(id) else { return notFound("Aufgabe", id) }
      return ToolJSON.ok()
    },
  ]
}

// MARK: - Notizen

private let taskRefHelp = "Aufgabe (ID oder exakter Titel), optional"

/// Aufgabe aus dem Werkzeugwert (ID oder exakter Titel). Unbekannt: Fehler.
private func resolveTask(_ ctx: ToolContext, _ raw: String) throws -> String {
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if let task = try ctx.store.tasks.get(value) { return task.id }
  if let task = try ctx.store.tasks.list().first(where: { $0.title == value }) { return task.id }
  throw ToolValidationError("Aufgabe \"\(value)\" nicht gefunden")
}

enum NoteTools {
  static let defs: [ToolDef] = [
    ToolDef(name: "add_note", description: "Legt eine neue Notiz an.", parameters: ToolSchema.object([
      "title": ToolSchema.string(), "content": ToolSchema.string(), "task": ToolSchema.string(taskRefHelp),
      "tags": tagsSchema,
    ], required: ["title", "content"])),
    ToolDef(name: "list_notes", description: "Listet alle Notizen (mit zugeordneter Aufgabe).", parameters: ToolSchema.object()),
    ToolDef(name: "search_notes", description: "Sucht Notizen nach Titel oder Inhalt.",
            parameters: ToolSchema.object(["query": ToolSchema.string("Suchbegriff")], required: ["query"])),
    ToolDef(name: "update_note", description: "Ändert Titel, Inhalt oder die Aufgabe einer Notiz.",
            parameters: ToolSchema.object([
              "id": ToolSchema.string("Notiz-ID"), "title": ToolSchema.string(), "content": ToolSchema.string(),
              "task": ToolSchema.string("\(taskRefHelp); \"\" löst die Zuordnung"),
              "tags": tagsSchema,
            ], required: ["id"])),
    ToolDef(name: "delete_note", description: "Löscht eine Notiz.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Notiz-ID")], required: ["id"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "add_note": { ctx, args in
      let title = try args.requireString("title")
      let content = try args.requireString("content")
      var taskId: String?
      if let raw = try args.optionalString("task"), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
        taskId = try resolveTask(ctx, raw)
      }
      return ToolJSON.ok(["note": ToolJSON.encode(try ctx.store.notes.add(title: title, content: content, taskId: taskId,
                                                                       tags: try parseTags(args) ?? []))])
    },
    "list_notes": { ctx, _ in
      let titles = Dictionary(try ctx.store.tasks.list().map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
      let notes: [JSONValue] = try ctx.store.notes.list().map { note in
        var obj = ToolJSON.encode(note)
        if let tid = note.taskId, let title = titles[tid], case .object(var o) = obj {
          o["task_title"] = .string(title)
          obj = .object(o)
        }
        return obj
      }
      return ToolJSON.ok(["notes": .array(notes)])
    },
    "search_notes": { ctx, args in
      let query = try args.requireString("query")
      return ToolJSON.ok(["notes": ToolJSON.encode(try ctx.store.notes.search(query))])
    },
    "update_note": { ctx, args in
      let id = try args.requireId()
      let title = args.has("title") ? try args.requireString("title") : nil
      let content = args.has("content") ? try args.requireString("content") : nil
      var task: FieldChange<String> = .keep
      if let raw = try args.optionalString("task") {
        task = .set(raw.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try resolveTask(ctx, raw))
      }
      guard let note = try ctx.store.notes.update(id, title: title, content: content, taskId: task,
                                                  tags: try parseTags(args)) else {
        return notFound("Notiz", id)
      }
      return ToolJSON.ok(["note": ToolJSON.encode(note)])
    },
    "delete_note": { ctx, args in
      let id = try args.requireId()
      guard try ctx.store.notes.delete(id) else { return notFound("Notiz", id) }
      return ToolJSON.ok()
    },
  ]
}

// MARK: - Aufträge

enum JobTools {
  static let defs: [ToolDef] = [
    ToolDef(
      name: "schedule_job",
      description:
        "Legt einen wiederkehrenden (oder einmaligen) Auftrag an, den der Planer später im Lesemodus ausführt.",
      parameters: ToolSchema.object([
        "name": ToolSchema.string(),
        "prompt": ToolSchema.string("Anweisung, die der Planer zur Zeit ausführt"),
        "rule": [
          "type": "object",
          "description":
            "{type:\"daily\",time:\"HH:mm\"} | {type:\"weekly\",days:[1-7],time:\"HH:mm\"} | {type:\"once\",at:\"JJJJ-MM-TTTHH:mm\"}",
          "properties": [
            "type": ["type": "string", "enum": ["daily", "weekly", "once"]],
            "time": ["type": "string"],
            "days": ["type": "array", "items": ["type": "integer"]],
            "at": ["type": "string"],
          ],
          "required": ["type"],
        ],
      ], required: ["name", "prompt", "rule"])),
    ToolDef(name: "list_jobs", description: "Listet alle geplanten Aufträge.", parameters: ToolSchema.object()),
    ToolDef(name: "cancel_job", description: "Stoppt einen geplanten Auftrag; ein schon beendeter wird entfernt.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Auftrags-ID")], required: ["id"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "schedule_job": { ctx, args in
      let name = try args.requireString("name")
      let prompt = try args.requireString("prompt")
      let rule = try args.jobRule()
      return ToolJSON.ok(["job": ToolJSON.encode(try ctx.store.jobs.add(name: name, prompt: prompt, rule: rule))])
    },
    "list_jobs": { ctx, _ in
      ToolJSON.ok(["jobs": ToolJSON.encode(try ctx.store.jobs.list())])
    },
    "cancel_job": { ctx, args in
      let id = try args.requireId()
      guard try ctx.store.jobs.cancel(id) else {
        return ToolJSON.failure(code: "NOT_FOUND", error: "Auftrag \"\(id)\" nicht gefunden oder bereits beendet")
      }
      return ToolJSON.ok()
    },
  ]
}
