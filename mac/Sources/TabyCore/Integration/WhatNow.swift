// „Was jetzt?“: wählt nach festen Regeln die nächste Aufgabe und startet dafür
// den Fokus. Reiner Code über die Daten im Speicher, kein Modell, keine Abfrage
// am Kalender.
import Foundation

/// Reine Auswahl, getrennt vom Dienst, damit die Reihenfolge prüfbar ist.
enum WhatNowLogic {
  /// Fest terminierte Aufgaben, deren Uhrzeit in diesen Minuten beginnt, gehen vor.
  static let soonMinutes = 30

  /// Reihenfolge: überfällig (älteste Fälligkeit zuerst), fest terminiert in den nächsten 30 Min,
  /// priorisiert (gemerkte Reihenfolge), heute fällig, sonst die kürzeste (dann älteste) offene.
  static func pick(tasks: [TabyTask], now: String, priority: [String], defaultMinutes: Int) -> WhatNowPick? {
    let today = LocalTime.datePart(now)
    let nowMinutes = AutoPlanner.toMinutes(now) ?? 0
    let open = tasks.filter { !$0.done }
    func byDue(_ a: TabyTask, _ b: TabyTask) -> Bool {
      (a.due ?? "", a.createdAt, a.id) < (b.due ?? "", b.createdAt, b.id)
    }

    let overdue = open.filter { $0.due.map { LocalTime.datePart($0) < today } ?? false }.sorted(by: byDue)
    if let t = overdue.first, let due = t.due {
      return WhatNowPick(task: t, reason: "Überfällig seit \(weekday(LocalTime.datePart(due)))")
    }

    let soon = open.compactMap { task -> (task: TabyTask, start: Int)? in
      guard let due = task.due, due.count >= 16, LocalTime.datePart(due) == today,
            let start = AutoPlanner.toMinutes(due), start >= nowMinutes, start <= nowMinutes + soonMinutes else { return nil }
      return (task, start)
    }.sorted { $0.start < $1.start }
    if let hit = soon.first, let due = hit.task.due {
      return WhatNowPick(task: hit.task, reason: "Termin um \(String(due.dropFirst(11).prefix(5)))")
    }

    if let id = priority.first(where: { id in open.contains { $0.id == id } }),
       let t = open.first(where: { $0.id == id }) {
      return WhatNowPick(task: t, reason: "Priorisiert")
    }

    if let t = open.filter({ $0.due.map { LocalTime.datePart($0) == today } ?? false }).sorted(by: byDue).first {
      return WhatNowPick(task: t, reason: "Heute fällig")
    }

    // Schätzung je Aufgabe einmal berechnen, nicht bei jedem Vergleich neu.
    let shortest = open.map { (task: $0, minutes: AutoPlanner.estimateMinutes($0.title, default: defaultMinutes)) }
      .sorted { a, b in (a.minutes, a.task.createdAt, a.task.id) < (b.minutes, b.task.createdAt, b.task.id) }
    return shortest.first.map { WhatNowPick(task: $0.task, reason: "Kurz erledigt") }
  }

  /// Kurzer deutscher Wochentag zu "YYYY-MM-DD" (UTC-gerechnet, wie der Rest des Planers).
  static func weekday(_ day: String) -> String {
    guard let d = StoreDates.wallClock(day + "T12:00") else { return day }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][cal.component(.weekday, from: d) - 1]
  }
}

extension CoreServices {
  /// Wählt die nächste Aufgabe und startet dafür einen Fokus. Läuft schon einer, passiert nichts.
  public func whatNow() async -> ToolResult<WhatNowPick> {
    if (try? store.focus.current()) != nil { return .failure(code: "BUSY", error: "Fokus läuft schon.") }
    let tasks = (try? store.tasks.list()) ?? []
    let priority = (try? store.taskPriority.list()) ?? []
    let now = LocalTime.format(clock.now())
    guard let pick = WhatNowLogic.pick(tasks: tasks, now: now, priority: priority,
                                       defaultMinutes: settings.planBlockMinutes) else {
      return .failure(code: "EMPTY", error: "Keine offenen Aufgaben.")
    }
    switch await startFocus(taskId: pick.task.id, minutes: nil) {
    case .ok: return .ok(pick)
    case .failure(let code, let error): return .failure(code: code, error: error)
    }
  }
}
