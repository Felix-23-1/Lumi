// Repositories für Tagesabschluss, Fokus-Sitzungen und gemerkte Fakten
// (Paket 2). Zeiten sind lokale, zonenlose ISO-Strings aus der injizierten Uhr.
import Foundation

/// Lokale Zeit mit Sekunden "YYYY-MM-DDTHH:mm:ss" (für den Fokus-Countdown).
enum SecondsTime {
  static func format(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: date)
  }
}

// MARK: - Tagesabschluss

public final class DayEndRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toRecord(_ r: SQLRow) -> DayEndRecord {
    DayEndRecord(date: r.text("date"), state: DayEndState(rawValue: r.text("state")) ?? .none,
                 snoozeUntil: r.string("snooze_until"))
  }

  public func get(_ date: String) throws -> DayEndRecord? {
    try db.query("SELECT * FROM day_end WHERE date = ?", [.text(date)]).first.map(toRecord)
  }

  /// Legt den Tag an oder ersetzt Zustand und Schlummer-Zeit.
  public func set(_ r: DayEndRecord) throws {
    try db.run(
      "INSERT INTO day_end (date, state, snooze_until) VALUES (?, ?, ?) "
        + "ON CONFLICT(date) DO UPDATE SET state = excluded.state, snooze_until = excluded.snooze_until",
      [.text(r.date), .text(r.state.rawValue), .of(r.snoozeUntil)])
  }
}

// MARK: - Fokus-Sitzungen

public final class FocusRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toSession(_ r: SQLRow) -> FocusSession {
    FocusSession(id: r.text("id"), taskId: r.string("task_id"), title: r.text("title"),
                 phase: FocusSession.Phase(rawValue: r.text("phase")) ?? .work, startedAt: r.text("started_at"),
                 endsAt: r.text("ends_at"), minutes: Int(r.int("minutes") ?? 0), pausedAt: r.string("paused_at"))
  }

  /// Startet eine Sitzung ab jetzt. Eine laufende Sitzung wird vorher beendet
  /// (nicht abgeschlossen).
  @discardableResult
  public func start(taskId: String?, title: String, phase: FocusSession.Phase, minutes: Int) throws -> FocusSession {
    let now = clock.now()
    let mins = max(1, minutes)
    let session = FocusSession(
      id: StoreIds.make(), taskId: taskId, title: title, phase: phase,
      startedAt: SecondsTime.format(now),
      endsAt: SecondsTime.format(now.addingTimeInterval(TimeInterval(mins * 60))), minutes: mins)
    try db.transaction {
      try db.run("UPDATE focus_sessions SET finished_at = ?, completed = 0 WHERE finished_at IS NULL",
                 [.text(SecondsTime.format(now))])
      try db.run(
        "INSERT INTO focus_sessions (id, task_id, title, phase, started_at, ends_at, minutes, finished_at, completed) "
          + "VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0)",
        [.text(session.id), .of(session.taskId), .text(session.title), .text(session.phase.rawValue),
         .text(session.startedAt), .text(session.endsAt), .of(session.minutes)])
    }
    return session
  }

  /// Neueste laufende Sitzung (ohne finished_at).
  public func current() throws -> FocusSession? {
    try db.query("SELECT * FROM focus_sessions WHERE finished_at IS NULL ORDER BY started_at DESC, rowid DESC LIMIT 1")
      .first.map(toSession)
  }

  /// Hält die Sitzung an (nur wenn sie läuft). Der Countdown bleibt auf `endsAt − pausedAt` stehen.
  public func pause(_ id: String) throws {
    try db.run("UPDATE focus_sessions SET paused_at = ? WHERE id = ? AND finished_at IS NULL AND paused_at IS NULL",
               [.text(SecondsTime.format(clock.now())), .text(id)])
  }

  /// Lässt eine angehaltene Sitzung weiterlaufen: das Ende rückt um die Dauer der Pause nach hinten.
  @discardableResult
  public func resume(_ id: String) throws -> FocusSession? {
    guard let s = try db.query("SELECT * FROM focus_sessions WHERE id = ? AND finished_at IS NULL", [.text(id)]).first.map(toSession),
          let paused = s.pausedAt.flatMap(LocalTime.parse), let end = LocalTime.parse(s.endsAt) else { return nil }
    let newEnd = end.addingTimeInterval(max(0, clock.now().timeIntervalSince(paused)))
    try db.run("UPDATE focus_sessions SET paused_at = NULL, ends_at = ? WHERE id = ?",
               [.text(SecondsTime.format(newEnd)), .text(id)])
    return try db.query("SELECT * FROM focus_sessions WHERE id = ?", [.text(id)]).first.map(toSession)
  }

  /// Beendet eine laufende Sitzung; bereits beendete bleiben unverändert.
  public func finish(_ id: String, completed: Bool) throws {
    try db.run("UPDATE focus_sessions SET finished_at = ?, completed = ? WHERE id = ? AND finished_at IS NULL",
               [.text(SecondsTime.format(clock.now())), .of(completed), .text(id)])
  }

  /// Minuten abgeschlossener Arbeitssitzungen, die heute begonnen wurden.
  public func minutesToday() throws -> Int {
    let n = try db.query(
      "SELECT COALESCE(SUM(minutes), 0) AS n FROM focus_sessions "
        + "WHERE phase = ? AND completed = 1 AND substr(started_at, 1, 10) = ?",
      [.text(FocusSession.Phase.work.rawValue), .text(StoreDates.today(clock))]
    ).first?.int("n") ?? 0
    return Int(n)
  }
}

// MARK: - Gemerkte Fakten

public enum MemoryError: Error, LocalizedError, Equatable {
  case empty

  public var errorDescription: String? {
    switch self {
    case .empty: return "Die Erinnerung darf nicht leer sein."
    }
  }
}

public final class MemoriesRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toMemory(_ r: SQLRow) -> Memory {
    Memory(id: r.text("id"), text: r.text("text"), createdAt: r.text("created_at"))
  }

  /// Text wird getrimmt; leerer Text wirft `MemoryError.empty`.
  @discardableResult
  public func add(_ text: String) throws -> Memory {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw MemoryError.empty }
    let memory = Memory(id: StoreIds.make(), text: trimmed, createdAt: StoreDates.now(clock))
    try db.run("INSERT INTO memories (id, text, created_at) VALUES (?, ?, ?)",
               [.text(memory.id), .text(memory.text), .text(memory.createdAt)])
    return memory
  }

  /// Älteste zuerst.
  public func list() throws -> [Memory] {
    try db.query("SELECT * FROM memories ORDER BY created_at, rowid").map(toMemory)
  }

  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.run("DELETE FROM memories WHERE id = ?", [.text(id)]) > 0
  }
}
