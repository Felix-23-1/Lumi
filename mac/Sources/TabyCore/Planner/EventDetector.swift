// Erkennt Termine in Mails und Nachrichten (offline, ohne Modell). Ein Treffer braucht
// eine Uhrzeit und einen Zeitpunkt in der Zukunft; Zahlen und Preise allein zählen nicht.
// Angelegt wird erst, wenn der Nutzer die Karte bestätigt.
import Foundation

public enum EventDetector {
  public struct DetectedEvent: Equatable, Sendable {
    public var title: String
    /// Lokal "YYYY-MM-DDTHH:mm".
    public var start: String
    /// Lokal "YYYY-MM-DDTHH:mm", start + durationMinutes.
    public var end: String
    public var durationMinutes: Int
  }

  /// Erster brauchbarer Termin im Text oder nil. Deutsch zuerst (GermanDateParser), dann
  /// NSDataDetector für übrige Formulierungen wie "March 5, 2030 at 3pm".
  public static func detect(_ text: String, now: Date) -> DetectedEvent? {
    let (body, minutes) = stripDuration(text)
    let german = GermanDateParser.parse(body, now: now)
    var start: Date? = nil
    var title = german.title
    if let due = german.due, due.contains("T") { start = LocalTime.parse(due) }
    if start == nil, let found = foundationDate(in: body) {
      start = found.date
      title = removing(found.range, from: body)
    }
    guard let begin = start, begin > now else { return nil }

    let end = begin.addingTimeInterval(TimeInterval((minutes ?? 60) * 60))
    let cleanTitle = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return DetectedEvent(title: cleanTitle.isEmpty ? "Termin" : cleanTitle, start: LocalTime.format(begin),
                         end: LocalTime.format(end), durationMinutes: minutes ?? 60)
  }

  /// Kurzform für die Chip-Anzeige, z. B. "Fr 10:30" (Wochentag und Uhrzeit).
  public static func chipLabel(_ e: DetectedEvent) -> String {
    guard let date = LocalTime.parse(e.start) else { return e.start }
    let weekday = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][LocalTime.calendar.component(.weekday, from: date) - 1]
    return "\(weekday) \(String(e.start.suffix(5)))"
  }

  /// Nur Treffer mit Uhrzeit zählen (Datum allein ist kein Termin).
  private static func foundationDate(in text: String) -> (date: Date, range: NSRange)? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
    let ns = text as NSString
    for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      guard let date = match.date else { continue }
      let snippet = ns.substring(with: match.range).lowercased()
      let hasTime = snippet.contains(":") || snippet.contains("uhr")
        || snippet.range(of: #"\d\s*(am|pm)\b"#, options: .regularExpression) != nil
      if hasTime { return (date, match.range) }
    }
    return nil
  }

  /// "90 Minuten", "für 2 Stunden" (Min./Std. ebenso). Liefert den Text ohne die Angabe und die Minuten.
  private static func stripDuration(_ text: String) -> (String, Int?) {
    let patterns: [(String, Int, ClosedRange<Int>)] = [
      (#"(?<![\d.,])(?:für\s+)?(\d{1,3})\s*(?:Minuten|Min\.?)(?!\p{L})"#, 1, 1...720),
      (#"(?<![\d.,])(?:für\s+)?(\d{1,2})\s*(?:Stunden|Std\.?)(?!\p{L})"#, 60, 1...12),
    ]
    for (pattern, factor, valid) in patterns {
      guard let re = RegexCache.compile(pattern, options: [.caseInsensitive]) else { continue }
      let ns = text as NSString
      guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
            let n = Int(ns.substring(with: m.range(at: 1))), valid.contains(n) else { continue }
      return (removing(m.range, from: text), n * factor)
    }
    return (text, nil)
  }

  private static func removing(_ range: NSRange, from s: String) -> String {
    (s as NSString).replacingCharacters(in: range, with: " ")
  }
}
