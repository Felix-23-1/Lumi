// Runde 3: Kurzzeitwecker (nur im Speicher), Rückgängig (Stapel bis 10 Schritte, 30 Minuten)
// und Suche über Aufgaben, Notizen, Termine (±30 Tage), Gedächtnis sowie gecachte Mail und Chats.
// Zeit nur über die injizierte `Clock`.
import Foundation

/// Laufender Wecker mit exaktem Ablauf (`TabyTimer.endsAt` ist auf Minuten gerundet).
struct RunningTimer {
  var timer: TabyTimer
  var end: Date
}

/// Eintrag im Rückgängig-Stapel: Vorher-Zustand nur der betroffenen Zeilen.
struct UndoEntry {
  /// Identität für das gezielte Entfernen nach dem Zurücknehmen (der Stapel kann sich inzwischen geändert haben).
  let id = UUID()
  let snapshot: UndoSnapshot
  let label: String
  let at: Date
}

/// Vorher-Zustand einer rückgängig machbaren Aktion.
enum UndoSnapshot {
  /// Aufgabe, ihre Notion-Verknüpfungen und die IDs ihrer Notizen.
  /// `followupId` = nächste Aufgabe der Wiederholung, `priorityRank` = Platz in der Prioritätsliste.
  case deletedTask(TabyTask, [NotionTaskLink], [String], followupId: String?, priorityRank: Int?)
  case deletedNote(Note)
  /// Zustand der Aufgabe vor dem Erledigen.
  case completedTask(TabyTask, [NotionTaskLink])
  /// Offene Aufgaben mit ihrer alten Fälligkeit.
  case postponed([(id: String, due: String?)])
  /// Ordner und die IDs seiner Aufgaben.
  case deletedFolder(TaskFolder, [String])
  /// Ordner vor dem Ändern seiner Kategorie; zurück = alte Kategorie.
  case folderCategory(TaskFolder)
  /// Termin vor dem Löschen; zurück = mit allen gespeicherten Feldern neu anlegen.
  case deletedEvent(CalendarEvent)
  /// Termin vor dem Verschieben; `newId`/`newSourceId` = Stand nach dem Verschieben (Apple: id hängt am Start).
  case movedEvent(CalendarEvent, newId: String, newSourceId: String)
  /// Auftrag vor dem Stoppen; zurück = wieder eintragen (auch wenn er gelöscht wurde).
  case cancelledJob(Job)
  case deletedMemory(Memory)
  /// Mod-Ordner im Papierkorb (`trash`); zurück = an seinen Platz verschieben.
  case deletedMod(id: String, trash: String)
  /// Notion-Quelle und ihre Verknüpfungen vor dem Entfernen.
  case removedNotionSource(NotionSource, [NotionTaskLink])
  /// Notion-Zugang vor dem Entfernen: Zugang, sein Code (nur im Arbeitsspeicher), Quellen und Verknüpfungen.
  case removedNotionAccount(NotionAccount, token: String?, sources: [NotionSource], links: [NotionTaskLink])
  /// Verlauf vor dem Leeren, in Einfüge-Reihenfolge.
  case clearedChat([StoredChatRow])
  case clearedPlan(DayPlan)
  /// Vorherige Fassung einer Notiz bzw. Aufgabe (`update_note`, `update_task`).
  case updatedNote(Note)
  case updatedTask(TabyTask)
  /// Aufgabe, deren Apple-Erinnerung gelöscht wurde: zurück = Verknüpfung weg, der nächste Abgleich legt sie neu an.
  case unlinkedFromApple(taskId: String)
}

/// Zeile der Nachrichtentabelle, unverändert (für Rückgängig des Verlaufs).
typealias StoredChatRow = (id: String, json: String, createdAt: String)

enum UndoFailure: Error { case failed }

@MainActor
final class TimersUndoState {
  var timers: [RunningTimer] = []
  /// Neueste zuerst, höchstens `CoreServices.undoLimit` Einträge.
  var undo: [UndoEntry] = []
  var loop: Task<Void, Never>?
  /// Lokaler Notion-Zustand (gelöschte Aufgaben, Textstände); nil = noch nicht geladen.
  var notionLocal: NotionLocalState?
}

extension CoreServices {
  static let undoWindow: TimeInterval = 1800
  static let undoLimit = 10
  /// Kennzeichen der Trefferart in `SearchHit.id` (Mail und Chat laufen unter `.note`).
  static let mailHitPrefix = "mail:"
  static let chatHitPrefix = "chat:"
  static let timerLimits = 1...720

  /// Werkzeuge für das Modell (Wecker, Suche). Die Ausführung steht in `timerSearchTool`.
  static let timerSearchToolDefs: [ToolDef] = [
    ToolDef(name: "start_timer",
            description: "Stellt einen Kurzzeitwecker von 1 bis 720 Minuten. Beim Ablauf kommt eine Benachrichtigung.",
            parameters: ToolSchema.object([
              "minutes": ["type": "integer", "description": "Dauer in Minuten (1 bis 720)"],
              "label": ToolSchema.string("Bezeichnung, z. B. \"Pasta\" (Standard: Timer)"),
            ], required: ["minutes"])),
    ToolDef(name: "cancel_timer", description: "Stoppt einen laufenden Timer.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Timer-ID")], required: ["id"])),
    ToolDef(name: "search",
            description: "Sucht in Aufgaben, Notizen, Terminen (30 Tage zurück und voraus) und im Gedächtnis.",
            parameters: ToolSchema.object(["query": ToolSchema.string("Suchbegriff")], required: ["query"])),
  ]

  /// Führt einen der Chat-Werkzeuge aus; nil, wenn der Name nicht zu diesem Abschnitt gehört.
  func timerSearchTool(_ name: String, _ argsJson: String) async -> JSONValue? {
    let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) ?? .object([:])
    switch name {
    case "start_timer":
      let minutes = args["minutes"]?.numberValue ?? 0
      let r = await startTimer(minutes: minutes >= 1 && minutes <= 720 ? Int(minutes) : 0,
                               label: args["label"]?.stringValue ?? "")
      if let t = r.value { return ToolJSON.ok(["timer": ToolJSON.encode(t)]) }
      return ToolJSON.failure(code: "VALIDATION", error: r.errorMessage ?? "Timer nicht möglich.")
    case "cancel_timer":
      let id = args["id"]?.stringValue ?? ""
      guard timersUndo.timers.contains(where: { $0.timer.id == id }) else {
        return ToolJSON.failure(code: "NOT_FOUND", error: "Timer nicht gefunden.")
      }
      await cancelTimer(id)
      return ToolJSON.ok()
    case "search":
      // Fremde Termin-Texte gehen nur verpackt zum Modell (wie bei Mail und Nachrichten).
      let hits = await search(args["query"]?.stringValue ?? "").map(Self.markedForeign)
      return ToolJSON.ok(["hits": ToolJSON.encode(hits), "note": .string(ForeignContent.note)])
    default:
      return nil
    }
  }

  // MARK: - Wecker

  public func startTimer(minutes: Int, label: String) async -> ToolResult<TabyTimer> {
    guard Self.timerLimits.contains(minutes) else {
      return .failure(code: "VALIDATION", error: "Timer gehen von 1 bis 720 Minuten.")
    }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let end = clock.now().addingTimeInterval(TimeInterval(minutes * 60))
    let timer = TabyTimer(id: StoreIds.make(), label: trimmed.isEmpty ? "Timer" : String(trimmed.prefix(60)),
                          endsAt: LocalTime.format(end))
    timersUndo.timers.append(RunningTimer(timer: timer, end: end))
    startTimerLoop()
    emit(.stateChanged)
    return .ok(timer)
  }

  public func cancelTimer(_ id: String) async {
    let before = timersUndo.timers.count
    timersUndo.timers.removeAll { $0.timer.id == id }
    if timersUndo.timers.count != before { emit(.stateChanged) }
  }

  /// Laufende Wecker, der nächste zuerst (für den AppState).
  func timerList() -> [TabyTimer] {
    timersUndo.timers.sorted { $0.end < $1.end }.map(\.timer)
  }

  /// Meldet und entfernt alle abgelaufenen Wecker; liefert sie zurück.
  @discardableResult
  func fireDueTimers() -> [TabyTimer] {
    let now = clock.now()
    let due = timersUndo.timers.filter { $0.end <= now }
    guard !due.isEmpty else { return [] }
    timersUndo.timers.removeAll { $0.end <= now }
    for item in due {
      let note = TabyNotification(title: "⏰ \(item.timer.label)", body: "Zeit ist um.")
      options.systemNotifier.send(note)
      emit(.flash(note))
    }
    emit(.stateChanged)
    return due.map(\.timer)
  }

  /// Prüft beim nächsten Ablauf (höchstens alle 30 Sekunden) und meldet fällige Wecker.
  func startTimerLoop() {
    guard options.plannerInterval != nil else { return }  // Prüfungen laufen ohne Takt
    timersUndo.loop?.cancel()
    timersUndo.loop = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.fireDueTimers()
        let wait = self.nextTimerWait()
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      }
    }
  }

  private func nextTimerWait() -> Double {
    guard let next = timersUndo.timers.map(\.end).min() else { return 30 }
    return min(30, max(1, next.timeIntervalSince(clock.now())))
  }

  // MARK: - Rückgängig

  /// Führt ein Werkzeug aus und merkt sich bei Erfolg den Vorher-Zustand (nur für die Aktionen, die `undoSnapshot` kennt).
  /// Jede Ausführung landet im Audit-Protokoll (Akteur aus `ctx`, sonst `auditActor`).
  func runUndoable(_ name: String, _ args: JSONValue, ctx: ToolContext,
                   auditActor: String? = nil, confirmed: Bool = false) async -> JSONValue {
    let before = await undoSnapshot(name, args, ctx: ctx)
    let result = await ToolRegistry.execute(name: name, args: args, ctx: ctx)
    audit(actor: auditActor ?? AuditActor.of(ctx.actor), tool: name, confirmed: confirmed,
          ok: result["ok"]?.boolValue == true)
    guard result["ok"]?.boolValue == true else { return result }
    if let before { pushUndo(finished(before.0, after: result), before.1) }
    // Jeder Weg, der den Erledigt-Haken ändert (App, Chat, MCP, Rückgängig), schreibt ihn hier nach Notion.
    if let id = args["id"]?.stringValue {
      if name == "complete_task" || name == "reopen_task" {
        syncTaskCheckedToNotion(taskId: id, checked: name == "complete_task")
      }
      // Lokal gelöschte Notion-Aufgabe: ihre Notion-ID merken, sonst legt der Abgleich sie neu an.
      if name == "delete_task", let before, case .deletedTask(_, let links, _, _, _) = before.0 {
        rememberNotionDeleted(links.map(\.notionId))
      }
    }
    return result
  }

  /// Ergänzt, was erst nach der Ausführung feststeht (neue id beim Verschieben).
  private func finished(_ snapshot: UndoSnapshot, after result: JSONValue) -> UndoSnapshot {
    guard case .movedEvent(let old, _, _) = snapshot,
          let ev = result["event"].flatMap({ ToolJSON.decode(CalendarEvent.self, from: $0) }) else { return snapshot }
    return .movedEvent(old, newId: ev.id, newSourceId: ev.sourceId)
  }

  /// Vorher-Zustand samt Bezeichnung; nil für alles, was sich nicht zurücknehmen lässt.
  private func undoSnapshot(_ name: String, _ args: JSONValue, ctx: ToolContext) async -> (UndoSnapshot, String)? {
    switch name {
    case "update_task":
      guard let id = args["id"]?.stringValue, let task = (try? store.tasks.get(id)) ?? nil else { return nil }
      return (.updatedTask(task), "Aufgabe geändert")
    case "update_note":
      guard let id = args["id"]?.stringValue, let note = (try? store.notes.get(id)) ?? nil else { return nil }
      return (.updatedNote(note), "Notiz geändert")
    case "delete_event", "move_event":
      guard let id = args["id"]?.stringValue, let sourceId = args["source_id"]?.stringValue,
            let old = await calendarEvent(id, sourceId: sourceId, ctx: ctx) else { return nil }
      // add_event stellt nur Titel, Zeit und Notiz wieder her; die Bezeichnung sagt das ehrlich.
      if name == "delete_event" { return (.deletedEvent(old), "Termin gelöscht (Titel, Zeit, Notizen)") }
      return (.movedEvent(old, newId: old.id, newSourceId: old.sourceId), "Termin verschoben")
    case "cancel_job":
      guard let id = args["id"]?.stringValue, let job = (try? store.jobs.get(id)) ?? nil else { return nil }
      return (.cancelledJob(job), "Auftrag gestoppt")
    case "forget_fact":
      guard let id = args["id"]?.stringValue,
            let memory = ((try? store.memories.list()) ?? []).first(where: { $0.id == id }) else { return nil }
      return (.deletedMemory(memory), "Fakt vergessen")
    case "delete_task":
      guard let id = args["id"]?.stringValue, let task = (try? store.tasks.get(id)) ?? nil else { return nil }
      let noteIds = ((try? store.notes.list(taskId: id)) ?? []).map(\.id)
      let followup = (try? store.db.query("SELECT followup_id FROM tasks WHERE id = ?", [.text(id)]))?
        .first?.string("followup_id")
      let rankRow = (try? store.db.query("SELECT rank FROM task_priority WHERE task_id = ?", [.text(id)]))?.first
      let rank = rankRow.flatMap { $0.int("rank") }.map { Int($0) }
      return (.deletedTask(task, notionLinks(taskId: id), noteIds, followupId: followup, priorityRank: rank),
              "Aufgabe gelöscht")
    case "complete_task":
      guard let id = args["id"]?.stringValue, let task = (try? store.tasks.get(id)) ?? nil, !task.done
      else { return nil }
      return (.completedTask(task, notionLinks(taskId: id)), "Aufgabe erledigt")
    case "delete_note":
      guard let id = args["id"]?.stringValue, let note = (try? store.notes.get(id)) ?? nil else { return nil }
      return (.deletedNote(note), "Notiz gelöscht")
    case "postpone_tasks":
      let ids = (args["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
      let open = ids.compactMap { (try? store.tasks.get($0)) ?? nil }.filter { !$0.done }
      guard !open.isEmpty else { return nil }
      let label = open.count == 1 ? "1 Aufgabe verschoben" : "\(open.count) Aufgaben verschoben"
      return (.postponed(open.map { (id: $0.id, due: $0.due) }), label)
    default:
      return nil
    }
  }

  /// Termin vor einer Änderung (±7 Tage um heute, denn delete_event/move_event kennen seinen Beginn nicht);
  /// nil, wenn er dort nicht steht – dann gibt es kein Rückgängig.
  /// shortcut: Termine, die weiter entfernt liegen, bekommen keinen Rückgängig-Eintrag.
  private func calendarEvent(_ id: String, sourceId: String, ctx: ToolContext) async -> CalendarEvent? {
    guard let provider = ctx.calendar.activeProviders().first(where: { $0.id == sourceId }) else { return nil }
    let today = StoreDates.today(clock)
    let near = (try? await provider.listEvents(from: StoreDates.shiftDateOnly(today, -7),
                                               to: StoreDates.shiftDateOnly(today, 7))) ?? []
    return near.first { $0.id == id }
  }

  /// Nur die Verknüpfungen dieser Aufgabe (nicht die ganze Tabelle).
  private func notionLinks(taskId: String) -> [NotionTaskLink] {
    notionLinks(column: "task_id", value: taskId)
  }

  /// Verknüpfungen einer Notion-Quelle (vor dem Entfernen der Quelle).
  func notionLinks(sourceId: String) -> [NotionTaskLink] {
    notionLinks(column: "source_id", value: sourceId)
  }

  private func notionLinks(column: String, value: String) -> [NotionTaskLink] {
    let rows = (try? store.db.query("SELECT * FROM notion_task_links WHERE \(column) = ?", [.text(value)])) ?? []
    return rows.map {
      NotionTaskLink(notionId: $0.text("notion_id"), taskId: $0.text("task_id"), sourceId: $0.text("source_id"),
                     group: $0.string("group_name"),
                     meta: NotionTaskMeta(createdAt: $0.string("created_at"), createdBy: $0.string("created_by_name"),
                                          status: $0.string("status")),
                     syncedTitle: $0.string("synced_title"), syncedDue: $0.string("synced_due"))
    }
  }

  /// Legt einen Eintrag oben auf den Stapel; ältere über dem Limit und abgelaufene fallen weg.
  func pushUndo(_ snapshot: UndoSnapshot, _ label: String) {
    timersUndo.undo = liveUndo()
    timersUndo.undo.insert(UndoEntry(snapshot: snapshot, label: label, at: clock.now()), at: 0)
    timersUndo.undo = Array(timersUndo.undo.prefix(Self.undoLimit))
  }

  /// Gültige Einträge, neueste zuerst; abgelaufene werden gleich entfernt.
  private func liveUndo() -> [UndoEntry] {
    let now = clock.now()
    timersUndo.undo.removeAll { now.timeIntervalSince($0.at) >= Self.undoWindow }
    return timersUndo.undo
  }

  /// Bezeichnungen des Stapels, neueste zuerst (für die Leiste mit „+N“).
  func currentUndoLabels() -> [String] {
    liveUndo().map(\.label)
  }

  /// Bezeichnung der letzten Aktion, solange sie rückgängig machbar ist (sonst nil).
  func currentUndoLabel() -> String? {
    currentUndoLabels().first
  }

  /// Ordner löschen, dessen Aufgaben-IDs merken (für `Ordner gelöscht`).
  func recordFolderDeletion(_ folder: TaskFolder, taskIds: [String]) {
    pushUndo(.deletedFolder(folder, taskIds), "Ordner gelöscht")
  }

  /// Vorherige Kategorie eines Ordners merken (für `Ordner-Kategorie geändert`).
  func recordFolderCategory(_ folder: TaskFolder) {
    pushUndo(.folderCategory(folder), "Ordner-Kategorie geändert")
  }

  /// Nimmt den neuesten gültigen Schritt zurück; bei Fehler bleibt er auf dem Stapel.
  public func undoLast() async -> ToolResult<String> {
    guard let entry = liveUndo().first else {
      return .failure(code: "NOTHING", error: "Nichts zum Rückgängigmachen.")
    }
    do {
      try await restoreUndo(entry.snapshot)
    } catch {
      return .failure(code: "ERROR", error: "Rückgängig machen ist fehlgeschlagen.")
    }
    // Nach dem await: genau diesen Eintrag entfernen, nicht den obersten (der kann inzwischen ein anderer sein).
    timersUndo.undo.removeAll { $0.id == entry.id }
    changed()
    return .ok(entry.label)
  }

  /// Termine laufen über die Werkzeuge, Mod-Ordner über das Dateisystem; der Rest in einer Transaktion.
  private func restoreUndo(_ snapshot: UndoSnapshot) async throws {
    switch snapshot {
    case .deletedEvent(let e):
      var args: [String: JSONValue] = ["title": .string(e.title), "start": .string(e.start),
                                       "calendar": .string(e.sourceId), "allow_conflict": .bool(true)]
      if let end = e.end { args["end"] = .string(end) }
      if let notes = e.notes { args["notes"] = .string(notes) }
      try await undoTool("add_event", args)
    case .movedEvent(let old, let newId, let newSourceId):
      var args: [String: JSONValue] = ["id": .string(newId), "source_id": .string(newSourceId),
                                       "start": .string(old.start), "calendar": .string(old.sourceId),
                                       "allow_conflict": .bool(true)]
      if let end = old.end { args["end"] = .string(end) }
      try await undoTool("move_event", args)
    case .deletedMod(_, let trash):
      try restoreModFolder(trash)
    case .removedNotionAccount(let account, let token, let sources, let links):
      try restoreNotionAccount(account, token: token, sources: sources, links: links)
    default:
      try store.db.transaction { try restoreRows(snapshot) }
    }
  }

  /// Werkzeug für das Rückgängig machen ausführen (ohne neuen Rückgängig-Eintrag).
  private func undoTool(_ name: String, _ args: [String: JSONValue]) async throws {
    let result = await ToolRegistry.execute(name: name, args: .object(args), ctx: toolContext(actor: .user))
    guard result["ok"]?.boolValue == true else { throw UndoFailure.failed }
  }

  /// Zeilen zurückschreiben, die Rückgängig-Aktion brauchen (Datenbank).
  private func restoreRows(_ snapshot: UndoSnapshot) throws {
      switch snapshot {
      case .deletedTask(let task, let links, let noteIds, let followupId, let priorityRank):
        var folderId = task.folderId
        if let f = folderId, try store.taskFolders.get(f) == nil { folderId = nil }
        try store.db.run(
          "INSERT OR REPLACE INTO tasks (id, title, notes, due, done, done_at, created_at, category, folder_id, recurrence, followup_id) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [.text(task.id), .text(task.title), .of(task.notes), .of(task.due), .of(task.done), .of(task.doneAt),
           .text(task.createdAt), .of(task.category?.rawValue), .of(folderId), .of(task.recurrence?.rawValue),
           .of(followupId)])
        for noteId in noteIds {
          _ = try store.db.run("UPDATE notes SET task_id = ? WHERE id = ?", [.text(task.id), .text(noteId)])
        }
        // Platz in der Prioritätsliste zurück: Einträge ab dem Platz rücken eins nach hinten.
        if let rank = priorityRank {
          _ = try store.db.run("UPDATE task_priority SET rank = rank + 1 WHERE rank >= ?", [.of(rank)])
          _ = try store.db.run("INSERT OR REPLACE INTO task_priority (task_id, rank) VALUES (?, ?)",
                               [.text(task.id), .of(rank)])
        }
        try restoreLinks(links)
        forgetNotionDeleted(links.map(\.notionId))
      case .deletedNote(let note):
        // Die Aufgabe bleibt verknüpft, solange sie noch existiert.
        var taskId = note.taskId
        if let t = taskId, try store.tasks.get(t) == nil { taskId = nil }
        try store.db.run(
          "INSERT OR REPLACE INTO notes (id, title, content, created_at, updated_at, task_id) VALUES (?, ?, ?, ?, ?, ?)",
          [.text(note.id), .text(note.title), .text(note.content), .text(note.createdAt), .text(note.updatedAt),
           .of(taskId)])
      case .completedTask(let task, let links):
        // Setzt zurück und entfernt eine noch offene Folgeaufgabe der Wiederholung.
        _ = try store.tasks.reopen(task.id)
        try restoreLinks(links)
        syncTaskCheckedToNotion(taskId: task.id, checked: task.done)
      case .postponed(let items):
        for item in items {
          _ = try store.db.run("UPDATE tasks SET due = ? WHERE id = ?", [.of(item.due), .text(item.id)])
        }
      case .deletedFolder(let folder, let taskIds):
        _ = try store.db.run("INSERT INTO task_folders (id, name, created_at, category_id) VALUES (?, ?, ?, ?)",
                             [.text(folder.id), .text(folder.name), .text(folder.createdAt), .of(folder.categoryId)])
        for id in taskIds {
          _ = try store.db.run("UPDATE tasks SET folder_id = ? WHERE id = ?", [.text(folder.id), .text(id)])
        }
      case .folderCategory(let folder):
        _ = try store.taskFolders.setCategory(folder.id, categoryId: folder.categoryId)
      case .updatedNote(let note):
        _ = try store.notes.update(note.id, title: note.title, content: note.content, taskId: .set(note.taskId))
      case .unlinkedFromApple(let taskId):
        try store.reminderLinks.delete(taskId: taskId)
      case .updatedTask(let task):
        _ = try store.tasks.update(task.id, title: task.title, notes: .set(task.notes), due: .set(task.due),
                                   category: .set(task.category), folderId: .set(task.folderId),
                                   recurrence: .set(task.recurrence))
      case .cancelledJob(let job):
        let rule = String(decoding: try JSONEncoder().encode(job.rule), as: UTF8.self)
        try store.db.run(
          "INSERT OR REPLACE INTO jobs (id, name, prompt, rule, mode, enabled, last_run_at, created_at) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          [.text(job.id), .text(job.name), .text(job.prompt), .text(rule), .text(job.mode.rawValue),
           .of(job.enabled ? 1 : 0), .of(job.lastRunAt), .text(job.createdAt)])
      case .deletedMemory(let memory):
        try store.db.run("INSERT OR REPLACE INTO memories (id, text, created_at) VALUES (?, ?, ?)",
                         [.text(memory.id), .text(memory.text), .text(memory.createdAt)])
      case .removedNotionSource(let source, let links):
        try store.notionSources.restore(source)
        try restoreLinks(links)
      case .clearedChat(let rows):
        for r in rows {
          try store.db.run("INSERT OR REPLACE INTO messages (id, json, created_at) VALUES (?, ?, ?)",
                           [.text(r.id), .text(r.json), .text(r.createdAt)])
        }
      case .clearedPlan(let plan):
        try store.dayPlans.save(plan)
      case .deletedEvent, .movedEvent, .deletedMod, .removedNotionAccount:
        break  // oben behandelt
      }
  }

  /// Mod-Ordner aus dem Papierkorb zurück an seinen Platz (nur, wenn dort nichts mehr liegt).
  private func restoreModFolder(_ trash: String) throws {
    let fm = FileManager.default
    let name = (trash as NSString).lastPathComponent
    let target = mods.root.appendingPathComponent(name, isDirectory: true)
    guard fm.fileExists(atPath: trash), !fm.fileExists(atPath: target.path) else { throw UndoFailure.failed }
    try fm.moveItem(atPath: trash, toPath: target.path)
    emit(.stateChanged)
  }

  /// Notion-Verknüpfungen zurückschreiben (Zuordnung und gemerkter Stand).
  func restoreLinks(_ links: [NotionTaskLink]) throws {
    let now = StoreDates.now(clock)
    for l in links {
      try store.notionTaskLinks.upsert(notionId: l.notionId, taskId: l.taskId, sourceId: l.sourceId,
                                       group: l.group, meta: l.meta, now: now)
      if let title = l.syncedTitle {
        try store.notionTaskLinks.setSyncBaseline(notionId: l.notionId, title: title, due: l.syncedDue)
      }
    }
  }

  // MARK: - Suche

  /// Termine ±30 Tage für die Suche: höchstens alle 60 s gelesen, damit jeder Tastendruck
  /// nicht den Kalender liest. Wechselt der Tag oder ändert sich etwas, wird neu gelesen.
  func searchCalendarEvents(today: String) async -> [CalendarEvent] {
    let now = clock.now()
    if let m = searchCalendarMemo, m.day == today, now >= m.at, now.timeIntervalSince(m.at) < 60 {
      return m.events
    }
    let events = await calendarAccess.listAllEvents(from: StoreDates.shiftDateOnly(today, -30),
                                                    to: StoreDates.shiftDateOnly(today, 31)).events
    searchCalendarMemo = (now, today, events)
    return events
  }

  public func search(_ query: String) async -> [SearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    var hits: [SearchHit] = []
    for t in (try? store.tasks.list()) ?? [] {
      if let h = Self.hit(t.id, .task, title: t.title, body: t.notes, date: t.due, q) { hits.append(h) }
    }
    for n in (try? store.notes.list()) ?? [] {
      if let h = Self.hit(n.id, .note, title: n.title, body: n.content, date: nil, q) { hits.append(h) }
    }
    let today = StoreDates.today(clock)
    for e in await searchCalendarEvents(today: today) {
      if let h = Self.hit(e.id, .event, title: e.title, body: e.notes, date: e.start, q) { hits.append(h) }
    }
    for m in (try? store.memories.list()) ?? [] {
      if let h = Self.hit(m.id, .memory, title: m.text, body: nil, date: nil, q) { hits.append(h) }
    }
    // Nur aus dem Speicher: Mail-Übersicht und Chat-Liste, die ohnehin geladen sind (kein Netz, kein Skript).
    if settings.mailEnabled {
      var found = 0
      for m in mailCache?.messages ?? [] where found < Self.cachedHitLimit {
        guard var h = Self.hit(Self.mailHitPrefix + m.id, .note, title: m.subject,
                               body: "\(m.senderName) \(m.senderAddress)", date: m.date, q) else { continue }
        h.title = "Mail: " + h.title
        hits.append(h)
        found += 1
      }
    }
    var chats = 0
    for c in messenger.conversationList() where chats < Self.cachedHitLimit {
      guard var h = Self.hit(Self.chatHitPrefix + c.id, .note, title: c.title, body: c.lastText, date: c.lastAt, q)
      else { continue }
      h.title = "Chat: " + h.title
      hits.append(h)
      chats += 1
    }
    // Vault-Treffer kommen zusätzlich (höchstens MarkdownVault.maxHits), damit die 30 anderen sie nicht verdrängen.
    return Array(hits.prefix(30)) + (await vaultSearch(q))
  }

  /// Höchstens so viele Mail- bzw. Chat-Treffer je Suche.
  static let cachedHitLimit = 10

  /// Treffer aus fremden Terminen, Mails und Chats gehen zum Modell verpackt (Titel und Ausschnitt).
  static func markedForeign(_ hit: SearchHit) -> SearchHit {
    let foreign = hit.kind == .event || hit.id.hasPrefix(mailHitPrefix) || hit.id.hasPrefix(chatHitPrefix)
      || hit.id.hasPrefix(vaultHitPrefix)
    guard foreign else { return hit }
    var h = hit
    h.title = ForeignContent.wrap(hit.title)
    h.snippet = hit.snippet.map(ForeignContent.wrap)
    return h
  }

  private static func hit(_ id: String, _ kind: SearchHit.Kind, title: String, body: String?, date: String?,
                          _ query: String) -> SearchHit? {
    let inTitle = title.range(of: query, options: searchOptions) != nil
    let snippet = body.flatMap { snippetAround($0, query) }
    guard inTitle || snippet != nil else { return nil }
    return SearchHit(id: id, kind: kind, title: title, snippet: snippet, date: date)
  }

  private static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// Ausschnitt von etwa 80 Zeichen um den ersten Treffer; nil ohne Treffer.
  static func snippetAround(_ text: String, _ query: String) -> String? {
    MarkdownVault.snippetAround(text, query)
  }
}
