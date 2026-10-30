// Repositories für Paket 4: Tagesplan, Wochenziele, Stand des Wochenrückblicks
// und Auswertungen (Fokus-Minuten, Habit-Haken je Zeitraum). Zeiten sind lokale
// ISO-Strings; Datumsbereiche sind inklusiv ("YYYY-MM-DD").
import Foundation

// MARK: - Tagesplan

public final class DayPlanRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  public func get(_ date: String) throws -> DayPlan? {
    guard let row = try db.query("SELECT json FROM day_plans WHERE date = ?", [.text(date)]).first else {
      return nil
    }
    return try JSONDecoder().decode(DayPlan.self, from: Data(row.text("json").utf8))
  }

  /// Legt den Tagesplan an oder ersetzt ihn.
  public func save(_ plan: DayPlan) throws {
    let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    try db.run(
      "INSERT INTO day_plans (date, json) VALUES (?, ?) ON CONFLICT(date) DO UPDATE SET json = excluded.json",
      [.text(plan.date), .text(json)])
  }

  public func delete(_ date: String) throws {
    try db.run("DELETE FROM day_plans WHERE date = ?", [.text(date)])
  }
}

// MARK: - Wochenziele

public final class WeeklyGoalsRepository: @unchecked Sendable {
  /// Höchstens so viele Ziele je Woche.
  public static let maxGoals = 3
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toGoal(_ r: SQLRow) -> WeeklyGoal {
    WeeklyGoal(id: r.text("id"), week: r.text("week"), text: r.text("text"), done: r.bool("done"))
  }

  /// Ziele einer Woche in Anlage-Reihenfolge.
  public func list(week: String) throws -> [WeeklyGoal] {
    try db.query("SELECT * FROM weekly_goals WHERE week = ? ORDER BY created_at, rowid", [.text(week)])
      .map(toGoal)
  }

  /// Ersetzt die Ziele einer Woche. Texte werden getrimmt, leere übersprungen,
  /// höchstens drei übernommen.
  @discardableResult
  public func replace(week: String, texts: [String], now: String) throws -> [WeeklyGoal] {
    let cleaned = texts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(Self.maxGoals)
    try db.transaction {
      try db.run("DELETE FROM weekly_goals WHERE week = ?", [.text(week)])
      for text in cleaned {
        try db.run(
          "INSERT INTO weekly_goals (id, week, text, done, created_at) VALUES (?, ?, ?, 0, ?)",
          [.text(StoreIds.make()), .text(week), .text(text), .text(now)])
      }
    }
    return try list(week: week)
  }

  /// Setzt den Erledigt-Stand; nil, wenn es das Ziel nicht gibt.
  @discardableResult
  public func setDone(_ id: String, _ done: Bool) throws -> WeeklyGoal? {
    try db.run("UPDATE weekly_goals SET done = ? WHERE id = ?", [.of(done), .text(id)])
    return try db.query("SELECT * FROM weekly_goals WHERE id = ?", [.text(id)]).first.map(toGoal)
  }
}

// MARK: - Stand des Wochenrückblicks

public final class WeeklyReviewStateRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  /// Zustand der Wochenfrage; `date` des Ergebnisses ist der Montag der Woche.
  public func get(_ week: String) throws -> DayEndRecord? {
    try db.query("SELECT * FROM weekly_review WHERE week = ?", [.text(week)]).first.map { r in
      DayEndRecord(date: r.text("week"), state: DayEndState(rawValue: r.text("state")) ?? .none,
                   snoozeUntil: r.string("snooze_until"))
    }
  }

  public func set(_ week: String, state: DayStartState, snoozeUntil: String?) throws {
    try db.run(
      "INSERT INTO weekly_review (week, state, snooze_until) VALUES (?, ?, ?) "
        + "ON CONFLICT(week) DO UPDATE SET state = excluded.state, snooze_until = excluded.snooze_until",
      [.text(week), .text(state.rawValue), .of(snoozeUntil)])
  }
}

// MARK: - Auswertungen für den Rückblick

public final class WeeklyStatsRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  /// Minuten abgeschlossener Arbeitssitzungen, die von `from` bis `to` (beide
  /// inklusiv, "YYYY-MM-DD") begonnen wurden.
  public func focusMinutes(from: String, to: String) throws -> Int {
    let n = try db.query(
      "SELECT COALESCE(SUM(minutes), 0) AS n FROM focus_sessions "
        + "WHERE phase = ? AND completed = 1 AND substr(started_at, 1, 10) >= ? AND substr(started_at, 1, 10) <= ?",
      [.text(FocusSession.Phase.work.rawValue), .text(from), .text(to)]
    ).first?.int("n") ?? 0
    return Int(n)
  }

  /// Abgehakte Tage eines Habits im Zeitraum (inklusiv), aufsteigend.
  public func habitCheckDates(habitId: String, from: String, to: String) throws -> [String] {
    try db.query(
      "SELECT date FROM habit_checks WHERE habit_id = ? AND date >= ? AND date <= ? ORDER BY date",
      [.text(habitId), .text(from), .text(to)]
    ).map { $0.text("date") }
  }
}
