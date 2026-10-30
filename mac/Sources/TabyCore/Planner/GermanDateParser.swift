// Offline-Erkennung deutscher Datums- und Uhrzeitangaben (ohne Modell, ohne Netz)
// für die Schnellerfassung. Erkannt werden: heute, morgen, übermorgen, Wochentage
// (nächstes Vorkommen, "am Freitag"), "nächste Woche" (Montag), "in 3 Tagen",
// "in 2 Wochen", "15.10.", "15.10.2026", "um 15 Uhr", "15:30", "15 Uhr 30".
import Foundation

public enum GermanDateParser {
  /// Liefert den Titel ohne die erkannte Angabe und die Fälligkeit ("YYYY-MM-DD" oder
  /// "YYYY-MM-DDTHH:mm"). Ohne Treffer: Text unverändert, Fälligkeit nil.
  /// Nur Uhrzeit ohne Datum gilt für heute.
  public static func parse(_ text: String, now: Date) -> (title: String, due: String?) {
    let cal = LocalTime.calendar
    let today = cal.startOfDay(for: now)
    let currentWeekday = cal.component(.weekday, from: today)  // 1 = Sonntag

    func offset(_ days: Int) -> Date? { cal.date(byAdding: .day, value: days, to: today) }

    /// Nächstes Vorkommen des Wochentags, strikt nach heute (heute gilt erst in einer Woche).
    func nextWeekday(_ weekday: Int) -> Date? {
      let delta = (weekday - currentWeekday + 7) % 7
      return offset(delta == 0 ? 7 : delta)
    }

    func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date? {
      guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
            cal.component(.month, from: date) == m, cal.component(.day, from: date) == d else { return nil }
      return date
    }

    let weekdays = ["montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6,
                    "samstag": 7, "sonnabend": 7, "sonntag": 1]

    // Jede Regel: Muster, Auswertung der Gruppen (Gruppe 0 = ganzer Treffer).
    let dateRules: [(pattern: String, resolve: ([String]) -> Date?)] = [
      (#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4})?(?!\d)"#, { g in
        guard let d = Int(g[1]), let m = Int(g[2]) else { return nil }
        if let y = Int(g[3]) { return makeDate(y, m, d) }
        let year = cal.component(.year, from: today)
        guard let thisYear = makeDate(year, m, d) else { return nil }
        return thisYear < today ? makeDate(year + 1, m, d) : thisYear
      }),
      (#"(?<!\p{L})übermorgen(?!\p{L})"#, { _ in offset(2) }),
      // "am Morgen", "guten Morgen", "jeden Morgen" meinen das Substantiv, nicht den nächsten Tag.
      (#"(?<!\p{L})(?<!am\s)(?<!vom\s)(?<!guten\s)(?<!jeden\s)(?<!dem\s)(?<!den\s)morgen(?!\p{L})"#, { _ in offset(1) }),
      (#"(?<!\p{L})heute(?!\p{L})"#, { _ in offset(0) }),
      (#"(?<!\p{L})in\s+(\d{1,3})\s+(Tage|Tagen|Woche|Wochen)(?!\p{L})"#, { g in
        guard let n = Int(g[1]) else { return nil }
        return offset(g[2].lowercased().hasPrefix("woche") ? 7 * n : n)
      }),
      (#"(?<!\p{L})nächste[nr]?\s+Woche(?!\p{L})"#, { _ in nextWeekday(2) }),
      (#"(?<!\p{L})(?:am\s+|nächsten?\s+)?(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonnabend|Sonntag)(?!\p{L})"#,
       { g in weekdays[g[1].lowercased()].flatMap(nextWeekday) }),
    ]

    var rest = text
    var date: Date? = nil
    for rule in dateRules where date == nil {
      guard let m = match(rule.pattern, in: rest), let found = rule.resolve(m.groups) else { continue }
      date = found
      rest = cut(rest, m.range)
    }

    var time: (hour: Int, minute: Int)? = nil
    // Stunde mit "Uhr" oder ":" ; "15 Uhr 30" und "15:30" sind gleichwertig.
    if let m = match(#"(?<![\p{L}\d])(?:um\s+)?(\d{1,2})(?::(\d{2})|\s*Uhr(?:\s+(\d{2}))?)(?!\d)"#, in: rest),
       let h = Int(m.groups[1]) {
      let minuteText = m.groups[2].isEmpty ? m.groups[3] : m.groups[2]
      let minute = minuteText.isEmpty ? 0 : Int(minuteText) ?? -1
      if (0...23).contains(h), (0...59).contains(minute) {
        time = (h, minute)
        rest = cut(rest, m.range)
      }
    }

    guard date != nil || time != nil else { return (text, nil) }
    let day = date ?? today
    let c = cal.dateComponents([.year, .month, .day], from: day)
    var due = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    if let time { due += String(format: "T%02d:%02d", time.hour, time.minute) }

    let title = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-").union(.whitespaces))
    return (title, due)
  }

  private static func match(_ pattern: String, in s: String) -> (groups: [String], range: NSRange)? {
    guard let re = RegexCache.compile(pattern, options: [.caseInsensitive]) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let groups = (0..<m.numberOfRanges).map { i -> String in
      let r = m.range(at: i)
      return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
    return (groups, m.range)
  }

  private static func cut(_ s: String, _ range: NSRange) -> String {
    (s as NSString).replacingCharacters(in: range, with: " ")
  }
}
