// Port von src/main/planner/daily-state.ts: Tagesstart-Zustandsautomat nach BAUPLAN 9.
// Reine Funktionen; `now` kommt vom Aufrufer (injizierte Clock).
import Foundation

/// Woher geprüft wird: `.restart` = App-Start/Anmeldung oder (falls eingestellt) Entsperren.
public enum DayStartTrigger: Sendable {
  case tick, restart
}

public enum DayStartMachine {
  /// Minuten bis zur erneuten Frage nach "Später".
  public static let snoozeMinutes = 30

  /// Ein neuer Kalendertag beginnt immer bei `.none`.
  public static func forToday(_ state: DailyState, now: Date) -> DailyState {
    let today = LocalTime.formatDate(now)
    return state.date == today ? state : DailyState(date: today, state: .none)
  }

  /// - none                        → zeigen, state = asked
  /// - asked + restart             → erneut zeigen (unbeantwortet geschlossen)
  /// - asked + tick                → nichts
  /// - snoozed, now >= snoozeUntil → erneut zeigen, state = asked
  /// - done / skipped              → nie
  public static func evaluate(_ state: DailyState, now: Date, trigger: DayStartTrigger = .tick)
    -> (state: DailyState, showQuestion: Bool)
  {
    let s = forToday(state, now: now)
    switch s.state {
    case .none:
      return (DailyState(date: s.date, state: .asked), true)
    case .asked where trigger == .restart:
      return (s, true)
    case .snoozed:
      if let until = s.snoozeUntil.flatMap(LocalTime.parse), now >= until {
        return (DailyState(date: s.date, state: .asked), true)
      }
      return (s, false)
    default:
      return (s, false)
    }
  }

  public static func answer(_ answer: DayStartAnswer, state: DailyState, now: Date) -> DailyState {
    var s = forToday(state, now: now)
    switch answer {
    case .yes:
      s.state = .done
    case .later:
      s.state = .snoozed
      let until = LocalTime.calendar.date(byAdding: .minute, value: snoozeMinutes, to: now) ?? now
      s.snoozeUntil = LocalTime.format(until)
    case .skip:
      s.state = .skipped
    }
    return s
  }
}
