// Neuplanung des Tages: Läuft ein Aufgaben-Block, rutschen spätere Aufgaben mit Uhrzeit dahinter.
// Reine Rechnung (kein Modell, keine Uhr): Eingabe sind Aufgaben, Ende des laufenden Blocks und Termine.
import Foundation

public enum TaskReflow {
  public struct Move: Equatable, Sendable {
    public let id: String
    public let due: String
  }

  /// Schrittweite, auf die verschobene Zeiten aufgerundet werden.
  static let stepMinutes = 5

  /// Neue Fälligkeiten für offene Aufgaben desselben Tages mit Uhrzeit, die vom Block verdrängt werden.
  /// Reihenfolge nach bisheriger Zeit; Aufgaben ohne Uhrzeit und andere Tage bleiben unberührt.
  /// `busy` sind feste Termine, die nie überlappt werden. Dauer je Aufgabe: `minutes`, sonst `defaultMinutes`.
  public static func moves(tasks: [TabyTask], excluding runningId: String?, blockEnd: Date, defaultMinutes: Int,
                           busy: [DateInterval]) -> [Move] {
    let day = LocalTime.datePart(LocalTime.format(blockEnd))
    let candidates = tasks
      .filter { !$0.done && $0.id != runningId }
      .compactMap { t -> (TabyTask, Date)? in
        guard let due = t.due, due.count > 10, LocalTime.datePart(due) == day, let d = LocalTime.parse(due) else { return nil }
        return (t, d)
      }
      .sorted { ($0.1, $0.0.title) < ($1.1, $1.0.title) }
    let sortedBusy = busy.sorted { $0.start < $1.start }
    var cursor = blockEnd
    var out: [Move] = []
    for (task, due) in candidates {
      let length = TimeInterval(max(1, task.minutes ?? defaultMinutes) * 60)
      var start = max(due, cursor)
      if start > due { start = roundedUp(start) }
      for b in sortedBusy where start < b.end && start.addingTimeInterval(length) > b.start { start = roundedUp(b.end) }
      if start > due {
        let due = LocalTime.format(start)
        guard LocalTime.datePart(due) == day else { break }  // shortcut: nichts über Mitternacht schieben
        out.append(Move(id: task.id, due: due))
      }
      cursor = start.addingTimeInterval(length)
    }
    return out
  }

  private static func roundedUp(_ d: Date) -> Date {
    let step = TimeInterval(stepMinutes * 60)
    return Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
  }

  /// Feste Termine des Tages als Intervalle (ganztägige und endlose zählen nicht).
  public static func busy(_ events: [CalendarEvent]) -> [DateInterval] {
    events.compactMap { e in
      guard !e.allDay, let s = LocalTime.parse(e.start), let end = e.end.flatMap(LocalTime.parse), end > s else { return nil }
      return DateInterval(start: s, end: end)
    }
  }
}

extension PlannerChecks {
  static let reflowChecks: [CheckCase] = {
    func t(_ id: String, _ due: String?, _ minutes: Int? = nil, done: Bool = false) -> TabyTask {
      TabyTask(id: id, title: id, due: due, done: done, createdAt: "2026-01-01T00:00", minutes: minutes)
    }
    func end(_ s: String) -> Date { LocalTime.parse(s)! }
    return [
      CheckCase("Neuplanung: Aufgaben, die der Block verdrängt, rutschen dahinter; spätere bleiben") {
        let m = TaskReflow.moves(tasks: [t("a", "2026-10-27T10:00", 30), t("b", "2026-10-27T10:30", 60), t("c", "2026-10-27T15:00")],
                                 excluding: "x", blockEnd: end("2026-10-27T10:20"), defaultMinutes: 30, busy: [])
        try expectEqual(m, [.init(id: "a", due: "2026-10-27T10:20"), .init(id: "b", due: "2026-10-27T10:50")])
      },
      CheckCase("Neuplanung: Termine werden übersprungen; ohne Uhrzeit, anderer Tag und erledigt bleiben") {
        let busy = [DateInterval(start: end("2026-10-27T11:00"), end: end("2026-10-27T12:00"))]
        let m = TaskReflow.moves(tasks: [t("a", "2026-10-27T10:00", 30), t("n", "2026-10-27"), t("o", "2026-10-28T10:00"),
                                         t("d", "2026-10-27T10:10", done: true)],
                                 excluding: nil, blockEnd: end("2026-10-27T10:20"), defaultMinutes: 30, busy: busy)
        try expectEqual(m, [.init(id: "a", due: "2026-10-27T10:20")])
        let m2 = TaskReflow.moves(tasks: [t("a", "2026-10-27T10:30", 30)], excluding: nil,
                                  blockEnd: end("2026-10-27T10:45"), defaultMinutes: 30, busy: busy)
        try expectEqual(m2, [.init(id: "a", due: "2026-10-27T12:00")], "10:45–11:15 überlappt den Termin")
      },
      CheckCase("Neuplanung: nichts wird über Mitternacht geschoben") {
        let m = TaskReflow.moves(tasks: [t("a", "2026-10-27T23:00", 30), t("b", "2026-10-27T23:20", 30)], excluding: nil,
                                 blockEnd: end("2026-10-27T23:50"), defaultMinutes: 30, busy: [])
        try expectEqual(m, [.init(id: "a", due: "2026-10-27T23:50")])
      },
    ]
  }()
}
