// Reine Datumsarithmetik auf "YYYY-MM-DD" (Port von src/main/store/dateUtil.ts)
// und Streak-Berechnung (Port von src/main/store/streak.ts). Gerechnet wird in
// UTC, damit Tageswechsel nicht von Sommerzeit/Zeitzone abhängen.
import Foundation

public enum StoreDates {
  private static var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }

  private static func components(_ date: String) -> DateComponents? {
    let parts = date.prefix(10).split(separator: "-")
    guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
    return DateComponents(year: y, month: m, day: d)
  }

  /// Verschiebt ein Datum "YYYY-MM-DD" um `days` Tage (ungültig → unverändert).
  public static func shiftDateOnly(_ date: String, _ days: Int) -> String {
    let cal = utc
    guard let comps = components(date), let d = cal.date(from: comps),
          let shifted = cal.date(byAdding: .day, value: days, to: d) else { return date }
    let c = cal.dateComponents([.year, .month, .day], from: shifted)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// Wanduhrzeit eines lokalen ISO-Strings ("YYYY-MM-DD", "YYYY-MM-DDTHH:mm",
  /// "YYYY-MM-DDTHH:mm:ss") als Zeitpunkt in UTC. Für Vergleiche/Abstände
  /// zwischen lokalen Zeiten, unabhängig von Zeitzone und Sommerzeit-Lücken.
  public static func wallClock(_ s: String) -> Date? {
    guard var comps = components(s) else { return nil }
    if s.count > 10 {
      let rest = s.dropFirst(10)
      guard rest.first == "T" else { return nil }
      let t = rest.dropFirst().split(separator: ":")
      guard t.count == 2 || t.count == 3, let h = Int(t[0]), let mi = Int(t[1]) else { return nil }
      comps.hour = h; comps.minute = mi
      if t.count == 3 { guard let sec = Int(t[2]) else { return nil }; comps.second = sec }
    }
    return utc.date(from: comps)
  }

  /// Heutiges lokales Datum laut Uhr.
  public static func today(_ clock: Clock) -> String { LocalTime.formatDate(clock.now()) }

  /// Jetzt als lokaler ISO-String laut Uhr.
  public static func now(_ clock: Clock) -> String { LocalTime.format(clock.now()) }
}

public enum HabitStreak {
  /// Zählt aufeinanderfolgende abgehakte Tage rückwärts, beginnend bei `today`
  /// (falls heute schon abgehakt) oder bei gestern (falls noch nicht). So
  /// bricht eine Streak nicht ab, bevor der Tag zu Ende ist.
  public static func compute(_ checkedDates: [String], today: String) -> Int {
    let checked = Set(checkedDates)
    var cursor = checked.contains(today) ? today : StoreDates.shiftDateOnly(today, -1)
    var streak = 0
    while checked.contains(cursor) {
      streak += 1
      cursor = StoreDates.shiftDateOnly(cursor, -1)
    }
    return streak
  }
}
