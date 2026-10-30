// Port von src/main/planner/job-schedule.ts: nächste/letzte Fälligkeit einer JobRule.
// Sommerzeit- und Mitternacht-sicher: gerechnet wird über Kalender-Komponenten
// (Tag + Uhrzeit), nie über feste Sekunden-Abstände.
import Foundation

public enum JobSchedule {
  /// Nächste Fälligkeit streng nach `now`.
  public static func nextDue(_ rule: JobRule, now: Date) -> Date? {
    search(rule, now: now, forward: true)
  }

  /// Letzte Fälligkeit auf oder vor `now` (Nachholen/Überspringen nach Neustart).
  public static func lastDue(_ rule: JobRule, now: Date) -> Date? {
    search(rule, now: now, forward: false)
  }

  /// Wochentag-Abgleich. Vertrag: 0 = Sonntag … 6 = Samstag (wie JS `getDay()`).
  /// BAUPLAN/TS nutzten ISO 1…7 (7 = Sonntag); 1…6 sind in beiden gleich, daher gilt
  /// 7 zusätzlich als Sonntag, damit beide Schreibweisen funktionieren.
  static func matches(days: [Int], date: Date) -> Bool {
    let jsDay = LocalTime.calendar.component(.weekday, from: date) - 1
    return days.contains(jsDay) || (jsDay == 0 && days.contains(7))
  }

  private static func search(_ rule: JobRule, now: Date, forward: Bool) -> Date? {
    switch rule {
    case .once(let at):
      guard let d = LocalTime.parse(at) else { return nil }
      return forward ? (d > now ? d : nil) : (d <= now ? d : nil)
    case .daily(let time):
      return scan(days: nil, time: time, now: now, forward: forward)
    case .weekly(let days, let time):
      return scan(days: days, time: time, now: now, forward: forward)
    }
  }

  private static func scan(days: [Int]?, time: String, now: Date, forward: Bool) -> Date? {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    let cal = LocalTime.calendar
    for i in 0...7 {
      guard let day = cal.date(byAdding: .day, value: forward ? i : -i, to: now) else { continue }
      var comps = cal.dateComponents([.year, .month, .day], from: day)
      comps.hour = parts[0]
      comps.minute = parts[1]
      comps.second = 0
      guard let candidate = cal.date(from: comps) else { continue }
      let inDirection = forward ? candidate > now : candidate <= now
      if inDirection && (days.map { matches(days: $0, date: candidate) } ?? true) { return candidate }
    }
    return nil
  }
}
