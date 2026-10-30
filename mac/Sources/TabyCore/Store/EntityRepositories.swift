// Repositories für Aufgaben, Notizen, Habits und lokale Termine (Port von
// src/main/store/repositories/{tasks,notes,habits,events}.ts). Zeiten sind
// lokale, zonenlose ISO-Strings aus der injizierten Uhr.
import Foundation

/// Teil-Aktualisierung eines optionalen Feldes: unverändert lassen, oder
/// setzen (nil = leeren).
public enum FieldChange<T: Equatable & Sendable>: Equatable, Sendable {
  case keep
  case set(T?)
}

// MARK: - Aufgaben

/// Nächste Fälligkeit wiederholter Aufgaben (reine Datumsarithmetik, Uhrzeit bleibt erhalten).
enum TaskRecurrenceMath {
  private static var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  private static func ymd(_ date: String) -> (y: Int, m: Int, d: Int)? {
    let p = date.prefix(10).split(separator: "-")
    guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
    return (y, m, d)
  }

  private static func isWeekend(_ date: String) -> Bool {
    guard let c = ymd(date), let d = utc.date(from: DateComponents(year: c.y, month: c.m, day: c.d)) else { return false }
    let weekday = utc.component(.weekday, from: d)  // 1 = Sonntag, 7 = Samstag
    return weekday == 1 || weekday == 7
  }

  /// Ein Schritt ab `date` ("YYYY-MM-DD"). Monat: gleicher Tag, am Monatsende gekürzt.
  static func step(_ date: String, _ r: TaskRecurrence) -> String {
    switch r {
    case .daily: return StoreDates.shiftDateOnly(date, 1)
    case .weekly: return StoreDates.shiftDateOnly(date, 7)
    case .weekdays:
      var next = StoreDates.shiftDateOnly(date, 1)
      while isWeekend(next) { next = StoreDates.shiftDateOnly(next, 1) }
      return next
    case .monthly:
      guard let c = ymd(date) else { return date }
      let (ny, nm) = c.m == 12 ? (c.y + 1, 1) : (c.y, c.m + 1)
      // Letzter Tag des Zielmonats: einen Tag vor dem ersten des Folgemonats.
      let (fy, fm) = nm == 12 ? (ny + 1, 1) : (ny, nm + 1)
      let lastDay = ymd(StoreDates.shiftDateOnly(String(format: "%04d-%02d-01", fy, fm), -1))?.d ?? c.d
      return String(format: "%04d-%02d-%02d", ny, nm, min(c.d, lastDay))
    }
  }

  /// Basis ist die alte Fälligkeit (sonst heute). Ein Schritt, dann weiter, bis die Aufgabe nicht mehr vor heute liegt.
  static func nextDue(old due: String?, _ r: TaskRecurrence, today: String) -> String {
    var next = step(due.map { String($0.prefix(10)) } ?? today, r)
    while next < today { next = step(next, r) }
    let time = due.map { $0.count > 10 ? String($0.dropFirst(10)) : "" } ?? ""
    return next + time
  }
}

public final class TasksRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toTask(_ r: SQLRow) -> TabyTask {
    TabyTask(id: r.text("id"), title: r.text("title"), notes: r.string("notes"), due: r.string("due"),
             done: r.bool("done"), doneAt: r.string("done_at"), createdAt: r.text("created_at"),
             category: r.string("category").flatMap(TaskCategory.init(rawValue:)), folderId: r.string("folder_id"),
             recurrence: r.string("recurrence").flatMap(TaskRecurrence.init(rawValue:)),
             minutes: r.int("minutes").map(Int.init),
             status: r.string("status").flatMap(TaskStatus.init(rawValue:)) ?? .open,
             tags: TagRules.decode(r.string("tags")))
  }

  @discardableResult
  public func add(title: String, notes: String? = nil, due: String? = nil, folderId: String? = nil,
                  category: TaskCategory? = nil, recurrence: TaskRecurrence? = nil,
                  minutes: Int? = nil, tags: [String] = []) throws -> TabyTask {
    let tags = TagRules.normalize(tags)
    let task = TabyTask(id: StoreIds.make(), title: title, notes: notes, due: due, createdAt: StoreDates.now(clock),
                        category: category, folderId: folderId, recurrence: recurrence, minutes: minutes, tags: tags)
    try db.run("""
      INSERT INTO tasks (id, title, notes, due, done, done_at, created_at, folder_id, category, recurrence, minutes, tags)
      VALUES (?, ?, ?, ?, 0, NULL, ?, ?, ?, ?, ?, ?)
      """, [.text(task.id), .text(title), .of(notes), .of(due), .text(task.createdAt), .of(folderId),
            .of(category?.rawValue), .of(recurrence?.rawValue), .minutesValue(minutes), .of(TagRules.encode(tags))])
    return task
  }

  public func list() throws -> [TabyTask] {
    try db.query("SELECT * FROM tasks ORDER BY created_at, rowid").map(toTask)
  }

  public func get(_ id: String) throws -> TabyTask? {
    try db.query("SELECT * FROM tasks WHERE id = ?", [.text(id)]).first.map(toTask)
  }

  public func update(_ id: String, title: String? = nil, notes: FieldChange<String> = .keep,
                     due: FieldChange<String> = .keep, category: FieldChange<TaskCategory> = .keep,
                     folderId: FieldChange<String> = .keep,
                     recurrence: FieldChange<TaskRecurrence> = .keep,
                     minutes: FieldChange<Int> = .keep, status: TaskStatus? = nil,
                     tags: [String]? = nil) throws -> TabyTask? {
    guard var t = try get(id) else { return nil }
    if let title { t.title = title }
    if case .set(let v) = notes { t.notes = v }
    if case .set(let v) = due { t.due = v }
    if case .set(let v) = category { t.category = v }
    if case .set(let v) = folderId { t.folderId = v }
    if case .set(let v) = recurrence { t.recurrence = v }
    if case .set(let v) = minutes { t.minutes = v }
    if let status { t.status = status }
    if let tags { t.tags = TagRules.normalize(tags) }
    try db.run("UPDATE tasks SET title = ?, notes = ?, due = ?, category = ?, folder_id = ?, recurrence = ?, minutes = ?, status = ?, tags = ? WHERE id = ?",
               [.text(t.title), .of(t.notes), .of(t.due), .of(t.category?.rawValue), .of(t.folderId),
                .of(t.recurrence?.rawValue), .minutesValue(t.minutes),
                .text(t.status.rawValue), .of(TagRules.encode(t.tags)), .text(id)])
    return try get(id)
  }

  /// Vertrags-Patch: nil = unverändert, leerer Text bei notes/due/category = leeren.
  public func update(_ id: String, _ patch: TaskPatch) throws -> TabyTask? {
    func change(_ v: String?) -> FieldChange<String> {
      guard let v else { return .keep }
      return .set(v.isEmpty ? nil : v)
    }
    func categoryChange(_ v: String?) -> FieldChange<TaskCategory> {
      guard let v else { return .keep }
      return .set(v.isEmpty ? nil : TaskCategory(rawValue: v))
    }
    func recurrenceChange(_ v: String?) -> FieldChange<TaskRecurrence> {
      guard let v else { return .keep }
      if v.isEmpty { return .set(nil) }
      return TaskRecurrence(rawValue: v).map { .set($0) } ?? .keep
    }
    return try update(id, title: patch.title, notes: change(patch.notes), due: change(patch.due),
                      category: categoryChange(patch.category), folderId: change(patch.folderId),
                      recurrence: recurrenceChange(patch.recurrence),
                      minutes: patch.minutes.map { .set($0 > 0 ? $0 : nil) } ?? .keep,
                      status: patch.status.flatMap { $0.isEmpty ? .open : TaskStatus(rawValue: $0) },
                      tags: patch.tags)
  }

  /// Die nächste Aufgabe einer wiederholten Aufgabe (`followup_id`), nil wenn keine angelegt wurde.
  private func followupId(of id: String) throws -> String? {
    try db.query("SELECT followup_id FROM tasks WHERE id = ?", [.text(id)]).first?.string("followup_id")
  }

  /// Erledigt die Aufgabe; eine wiederholte Aufgabe legt dabei genau eine nächste offene Aufgabe an
  /// (ihre ID steht in `followup_id`). Existiert sie noch, entsteht keine zweite.
  public func complete(_ id: String) throws -> TabyTask? {
    guard let task = try get(id) else { return nil }
    try db.transaction {
      var followup: String? = nil
      if let r = task.recurrence, !task.done {
        let existing = try followupId(of: id)
        if try existing.flatMap({ try get($0) }) == nil {
          let due = TaskRecurrenceMath.nextDue(old: task.due, r, today: StoreDates.today(clock))
          followup = try add(title: task.title, notes: task.notes, due: due, folderId: task.folderId,
                             category: task.category, recurrence: r).id
        }
      }
      try db.run("UPDATE tasks SET done = 1, done_at = ?, followup_id = COALESCE(?, followup_id) WHERE id = ?",
                 [.text(StoreDates.now(clock)), .of(followup), .text(id)])
    }
    return try get(id)
  }

  /// Ist die Folgeaufgabe noch so, wie `complete` sie angelegt hat (gleiche Angaben, keine Notizen daran)?
  /// Nur dann darf Rückgängig sie entfernen; sonst gehört sie dem Nutzer und bleibt.
  private func followupUntouched(_ next: TabyTask, of task: TabyTask) throws -> Bool {
    guard let r = task.recurrence, let doneAt = task.doneAt else { return false }
    let plannedDue = TaskRecurrenceMath.nextDue(old: task.due, r, today: String(LocalTime.datePart(doneAt)))
    let hasNotes = try !db.query("SELECT id FROM notes WHERE task_id = ? LIMIT 1", [.text(next.id)]).isEmpty
    return next.title == task.title && (next.notes ?? "") == (task.notes ?? "") && next.due == plannedDue
      && next.category == task.category && next.folderId == task.folderId && next.recurrence == r && !hasNotes
  }

  /// Macht das Erledigen rückgängig. Die nächste Aufgabe wird entfernt, solange sie unberührt (offen) ist;
  /// wurde sie schon erledigt oder bearbeitet (Titel, Notizen, Fälligkeit …), bleibt sie und verhindert
  /// beim erneuten Erledigen eine zweite.
  public func reopen(_ id: String) throws -> TabyTask? {
    guard let task = try get(id) else { return nil }
    // Ohne eigene Transaktion: läuft auch innerhalb der Rückgängig-Transaktion.
    if let f = try followupId(of: id), let next = try get(f), !next.done, try followupUntouched(next, of: task) {
      try db.run("UPDATE notes SET task_id = NULL WHERE task_id = ?", [.text(f)])
      try db.run("DELETE FROM tasks WHERE id = ?", [.text(f)])
      try db.run("UPDATE tasks SET followup_id = NULL WHERE id = ?", [.text(id)])
    }
    try db.run("UPDATE tasks SET done = 0, done_at = NULL WHERE id = ?", [.text(id)])
    // Wieder offen: bestätigte Erinnerungen, deren Zeit noch vor uns liegt, dürfen wieder auslösen.
    try db.run("UPDATE reminders SET acknowledged_at = NULL WHERE source = ? AND source_ref = ? "
               + "AND acknowledged_at IS NOT NULL AND due_at > ?",
               [.text(ReminderSource.task.rawValue), .text(id), .text(StoreDates.now(clock))])
    return try get(id)
  }

  /// Löscht die Aufgabe; ihre Notizen bleiben erhalten und verlieren nur die Zuordnung.
  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.transaction {
      try db.run("UPDATE notes SET task_id = NULL WHERE task_id = ?", [.text(id)])
      try db.run("DELETE FROM task_priority WHERE task_id = ?", [.text(id)])
      return try db.run("DELETE FROM tasks WHERE id = ?", [.text(id)]) > 0
    }
  }
}

// MARK: - Aufgaben-Ordner

public final class TaskFoldersRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toFolder(_ r: SQLRow) -> TaskFolder {
    TaskFolder(id: r.text("id"), name: r.text("name"), createdAt: r.text("created_at"),
               categoryId: r.string("category_id"))
  }

  /// Nach Name sortiert, Groß/Klein egal.
  public func list() throws -> [TaskFolder] {
    try db.query("SELECT * FROM task_folders ORDER BY name COLLATE NOCASE, rowid").map(toFolder)
  }

  public func get(_ id: String) throws -> TaskFolder? {
    try db.query("SELECT * FROM task_folders WHERE id = ?", [.text(id)]).first.map(toFolder)
  }

  /// Ordner mit diesem Namen (Groß/Klein egal) in genau dieser Kategorie (nil = ohne Kategorie); nil wenn keiner.
  public func find(name: String, categoryId: String?) throws -> TaskFolder? {
    try db.query("SELECT * FROM task_folders WHERE name = ? COLLATE NOCASE AND IFNULL(category_id, '') = ?",
                 [.text(name), .text(categoryId ?? "")]).first.map(toFolder)
  }

  @discardableResult
  public func add(name: String, categoryId: String? = nil) throws -> TaskFolder {
    let folder = TaskFolder(id: StoreIds.make(), name: name, createdAt: StoreDates.now(clock), categoryId: categoryId)
    try db.run("INSERT INTO task_folders (id, name, created_at, category_id) VALUES (?, ?, ?, ?)",
               [.text(folder.id), .text(name), .text(folder.createdAt), .of(categoryId)])
    return folder
  }

  /// Kategorie setzen (nil = keine). Die Eindeutigkeit prüft der Aufrufer (CoreServices).
  public func setCategory(_ id: String, categoryId: String?) throws -> TaskFolder? {
    guard try get(id) != nil else { return nil }
    try db.run("UPDATE task_folders SET category_id = ? WHERE id = ?", [.of(categoryId), .text(id)])
    return try get(id)
  }

  public func rename(_ id: String, name: String) throws -> TaskFolder? {
    guard try get(id) != nil else { return nil }
    try db.run("UPDATE task_folders SET name = ? WHERE id = ?", [.text(name), .text(id)])
    return try get(id)
  }

  /// Löscht den Ordner; seine Aufgaben bleiben und verlieren nur die Zuordnung.
  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.transaction {
      try db.run("UPDATE tasks SET folder_id = NULL WHERE folder_id = ?", [.text(id)])
      return try db.run("DELETE FROM task_folders WHERE id = ?", [.text(id)]) > 0
    }
  }
}

// MARK: - Notizen

public final class NotesRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toNote(_ r: SQLRow) -> Note {
    Note(id: r.text("id"), title: r.text("title"), content: r.text("content"), createdAt: r.text("created_at"),
         updatedAt: r.text("updated_at"), taskId: r.string("task_id"),
         tags: TagRules.decode(r.string("tags")), meetingKey: r.string("meeting_key"))
  }

  @discardableResult
  public func add(title: String, content: String, taskId: String? = nil, tags: [String] = [],
                  meetingKey: String? = nil) throws -> Note {
    let now = StoreDates.now(clock)
    let tags = TagRules.normalize(tags)
    let note = Note(id: StoreIds.make(), title: title, content: content, createdAt: now, updatedAt: now, taskId: taskId,
                    tags: tags, meetingKey: meetingKey)
    try db.run("INSERT INTO notes (id, title, content, created_at, updated_at, task_id, tags, meeting_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
               [.text(note.id), .text(title), .text(content), .text(now), .text(now), .of(taskId),
                .of(TagRules.encode(tags)), .of(meetingKey)])
    return note
  }

  /// Notizen einer Aufgabe, zuletzt geändert zuerst.
  public func list(taskId: String) throws -> [Note] {
    try db.query("SELECT * FROM notes WHERE task_id = ? ORDER BY updated_at DESC, rowid DESC", [.text(taskId)]).map(toNote)
  }

  /// Zuletzt geänderte zuerst.
  public func list() throws -> [Note] {
    try db.query("SELECT * FROM notes ORDER BY updated_at DESC, rowid DESC").map(toNote)
  }

  public func get(_ id: String) throws -> Note? {
    try db.query("SELECT * FROM notes WHERE id = ?", [.text(id)]).first.map(toNote)
  }

  /// Teiltext-Suche in Titel oder Inhalt (LIKE, ohne Groß/Klein bei ASCII).
  public func search(_ query: String) throws -> [Note] {
    let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    let like = SQLValue.text("%\(escaped)%")
    return try db.query(
      "SELECT * FROM notes WHERE title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' ORDER BY updated_at DESC, rowid DESC",
      [like, like]
    ).map(toNote)
  }

  /// Notiz zu einem Termin (Agenda/Mitschrift), nil wenn es keine gibt.
  public func get(meetingKey: String) throws -> Note? {
    try db.query("SELECT * FROM notes WHERE meeting_key = ? ORDER BY rowid LIMIT 1", [.text(meetingKey)]).first.map(toNote)
  }

  public func update(_ id: String, title: String? = nil, content: String? = nil,
                     taskId: FieldChange<String> = .keep, tags: [String]? = nil) throws -> Note? {
    guard var n = try get(id) else { return nil }
    if let title { n.title = title }
    if let content { n.content = content }
    if case .set(let v) = taskId { n.taskId = v }
    if let tags { n.tags = TagRules.normalize(tags) }
    try db.run("UPDATE notes SET title = ?, content = ?, task_id = ?, tags = ?, updated_at = ? WHERE id = ?",
               [.text(n.title), .text(n.content), .of(n.taskId), .of(TagRules.encode(n.tags)),
                .text(StoreDates.now(clock)), .text(id)])
    return try get(id)
  }

  /// Vertrags-Patch: nil = unverändert, "" = Zuordnung lösen, sonst Aufgaben-ID.
  public func update(_ id: String, _ patch: NotePatch) throws -> Note? {
    let task: FieldChange<String> = patch.taskId.map { .set($0.isEmpty ? nil : $0) } ?? .keep
    return try update(id, title: patch.title, content: patch.content, taskId: task, tags: patch.tags)
  }

  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.run("DELETE FROM notes WHERE id = ?", [.text(id)]) > 0
  }
}

// MARK: - Habits

public final class HabitsRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func checkedDates(_ habitId: String) throws -> [String] {
    try db.query("SELECT date FROM habit_checks WHERE habit_id = ?", [.text(habitId)]).map { $0.text("date") }
  }

  /// streak/checkedToday werden hier im Code berechnet (Uhr injiziert).
  private func toHabit(_ r: SQLRow) throws -> Habit {
    let id = r.text("id")
    let dates = try checkedDates(id)
    let today = StoreDates.today(clock)
    return Habit(id: id, name: r.text("name"), description: r.string("description"), archived: r.bool("archived"),
                 createdAt: r.text("created_at"), streak: HabitStreak.compute(dates, today: today),
                 checkedToday: dates.contains(today))
  }

  @discardableResult
  public func add(name: String, description: String? = nil) throws -> Habit {
    let id = StoreIds.make()
    try db.run("INSERT INTO habits (id, name, description, archived, created_at) VALUES (?, ?, ?, 0, ?)",
               [.text(id), .text(name), .of(description), .text(StoreDates.now(clock))])
    return try get(id)!
  }

  /// Nur nicht archivierte, in Anlage-Reihenfolge.
  public func list() throws -> [Habit] {
    try db.query("SELECT * FROM habits WHERE archived = 0 ORDER BY created_at, rowid").map(toHabit)
  }

  public func get(_ id: String) throws -> Habit? {
    try db.query("SELECT * FROM habits WHERE id = ?", [.text(id)]).first.map(toHabit)
  }

  /// Hakt `date` ("YYYY-MM-DD") ab; doppeltes Abhaken ist wirkungslos.
  public func check(_ id: String, date: String) throws -> Habit? {
    guard try get(id) != nil else { return nil }
    try db.run("INSERT OR IGNORE INTO habit_checks (habit_id, date) VALUES (?, ?)", [.text(id), .text(date)])
    return try get(id)
  }

  /// Nimmt den Haken für `date` zurück.
  public func uncheck(_ id: String, date: String) throws -> Habit? {
    guard try get(id) != nil else { return nil }
    try db.run("DELETE FROM habit_checks WHERE habit_id = ? AND date = ?", [.text(id), .text(date)])
    return try get(id)
  }

  /// Löscht Habit samt Haken.
  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.transaction {
      try db.run("DELETE FROM habit_checks WHERE habit_id = ?", [.text(id)])
      return try db.run("DELETE FROM habits WHERE id = ?", [.text(id)]) > 0
    }
  }

  /// Anzahl gespeicherter Haken (Prüfungen).
  func checkCount(_ id: String) throws -> Int {
    try checkedDates(id).count
  }
}

// MARK: - Lokale Termine (Kalendermodul "local")

public final class EventsRepository: @unchecked Sendable {
  public static let localSourceId = "local"
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toEvent(_ r: SQLRow) -> CalendarEvent {
    CalendarEvent(id: r.text("id"), sourceId: Self.localSourceId, title: r.text("title"), start: r.text("start"),
                  end: r.string("end"), allDay: r.bool("all_day"), notes: r.string("notes"), readOnly: false)
  }

  /// Ganztägig, wenn `start` keine Uhrzeit hat.
  @discardableResult
  public func add(_ input: NewEvent) throws -> CalendarEvent {
    let ev = CalendarEvent(id: StoreIds.make(), sourceId: Self.localSourceId, title: input.title, start: input.start,
                           end: input.end, allDay: LocalTime.isDateOnly(input.start), notes: input.notes)
    try db.run("INSERT INTO local_events (id, title, start, \"end\", all_day, notes) VALUES (?, ?, ?, ?, ?, ?)",
               [.text(ev.id), .text(ev.title), .text(ev.start), .of(ev.end), .of(ev.allDay), .of(ev.notes)])
    return ev
  }

  /// `from` inklusiv, `to` exklusiv (Datum), verglichen mit dem Datumsteil von `start`.
  public func list(from: String, to: String) throws -> [CalendarEvent] {
    try db.query(
      "SELECT * FROM local_events WHERE substr(start, 1, 10) >= ? AND substr(start, 1, 10) < ? ORDER BY start, rowid",
      [.text(from), .text(to)]
    ).map(toEvent)
  }

  public func listAll() throws -> [CalendarEvent] {
    try db.query("SELECT * FROM local_events ORDER BY start, rowid").map(toEvent)
  }

  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.run("DELETE FROM local_events WHERE id = ?", [.text(id)]) > 0
  }
}
