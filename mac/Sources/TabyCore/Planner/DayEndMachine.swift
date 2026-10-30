// Tagesabschluss ("Tagesende"): Zustandsautomat am Abend, Gegenstück zum Tagesstart.
// Reine Funktionen; `now` und die Uhrzeit kommen vom Aufrufer (injizierte Clock).
import Foundation

public enum DayEndMachine {
  /// Minuten bis zur erneuten Frage nach "Später".
  public static let snoozeMinutes = 30
  /// Ersatzzeit, falls die eingestellte Uhrzeit nicht lesbar ist.
  public static let fallbackTime = "20:00"

  /// Ein neuer Kalendertag beginnt immer bei `.none`.
  public static func forToday(_ record: DayEndRecord?, now: Date) -> DayEndRecord {
    let today = LocalTime.formatDate(now)
    guard let record, record.date == today else { return DayEndRecord(date: today, state: .none) }
    return record
  }

  /// Uhrzeit "HH:mm" des Tages von `now` als Zeitpunkt (nil, wenn nicht lesbar).
  static func configuredMoment(time: String, now: Date) -> Date? {
    let today = LocalTime.formatDate(now)
    return LocalTime.parse("\(today)T\(time)") ?? LocalTime.parse("\(today)T\(fallbackTime)")
  }

  /// true, wenn die Entscheidung von der Zahl offener Aufgaben abhängt
  /// (Aufrufer muss sie dann vorher lesen). Nur einmal am Tag, bis der Zustand wechselt.
  public static func needsOpenTasks(_ record: DayEndRecord?, now: Date, time: String, enabled: Bool) -> Bool {
    guard enabled else { return false }
    let s = forToday(record, now: now)
    guard s.state == .none, let moment = configuredMoment(time: time, now: now) else { return false }
    return now >= moment
  }

  /// - Vor der Uhrzeit oder deaktiviert     → nichts
  /// - none, offene Aufgaben                → zeigen, state = asked
  /// - none, keine offenen Aufgaben         → state = done, nicht zeigen
  /// - asked + restart                      → erneut zeigen (unbeantwortet geschlossen)
  /// - asked + tick                         → nichts
  /// - snoozed, now >= snoozeUntil          → erneut zeigen, state = asked
  /// - done / skipped                       → nie
  public static func evaluate(
    _ record: DayEndRecord?, now: Date, time: String, enabled: Bool,
    trigger: DayStartTrigger = .tick, hasOpenTasks: Bool
  ) -> (record: DayEndRecord, showQuestion: Bool) {
    let s = forToday(record, now: now)
    guard enabled, let moment = configuredMoment(time: time, now: now), now >= moment else {
      return (s, false)
    }
    switch s.state {
    case .none:
      if hasOpenTasks {
        return (DayEndRecord(date: s.date, state: .asked), true)
      }
      return (DayEndRecord(date: s.date, state: .done), false)
    case .asked where trigger == .restart:
      return (s, true)
    case .snoozed:
      if let until = s.snoozeUntil.flatMap(LocalTime.parse), now >= until {
        return (DayEndRecord(date: s.date, state: .asked), true)
      }
      return (s, false)
    default:
      return (s, false)
    }
  }

  /// moveAllToTomorrow/done → done; later → snoozed (+30 min); skip → skipped.
  /// Das Verschieben der Aufgaben übernimmt der Orchestrator, nicht dieser Automat.
  public static func answer(_ answer: DayEndAnswer, record: DayEndRecord?, now: Date) -> DayEndRecord {
    var s = forToday(record, now: now)
    switch answer {
    case .moveAllToTomorrow, .done:
      s.state = .done
      s.snoozeUntil = nil
    case .later:
      s.state = .snoozed
      let until = LocalTime.calendar.date(byAdding: .minute, value: snoozeMinutes, to: now) ?? now
      s.snoozeUntil = LocalTime.format(until)
    case .skip:
      s.state = .skipped
      s.snoozeUntil = nil
    }
    return s
  }
}
