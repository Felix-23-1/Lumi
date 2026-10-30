// Pausen aus dem Gedächtnis ("Mittagspause von 12 bis 13 Uhr"): der Tagesplan lässt
// diese Zeit frei. Reiner Code, kein Modell. Ohne Uhrzeit keine Pause; der neueste
// Eintrag mit Stichwort und Uhrzeit gewinnt. Eine negierte neueste Angabe
// ("keine Mittagspause mehr") hebt Pausen auf, ohne auf ältere Einträge zurückzufallen.
// Die Uhrzeit gehört nur zum Stichwort, wenn sie in derselben Klausel steht.
import Foundation

public enum BreakMemoryParser {
  /// Höchstens eine Pause: der neueste Gedächtnis-Eintrag mit Stichwort und Uhrzeit.
  public static func breaks(from memories: [Memory]) -> [(start: String, end: String, label: String)] {
    for memory in memories.sorted(by: { $0.createdAt > $1.createdAt }) {
      guard let parts = keywordParts(withoutDates(memory.text.lowercased())) else { continue }
      if range(of: negationPattern, in: parts.sentence) { return [] }
      if let parsed = parse(memory.text) { return [parsed] }
    }
    return []
  }

  /// Pausen als belegte Termine für `today` ("yyyy-MM-dd"), damit der Plan sie meidet.
  public static func busyEvents(memories: [Memory], today: String) -> [CalendarEvent] {
    breaks(from: memories).map { b in
      CalendarEvent(id: "break#\(b.start)", sourceId: "memory", title: b.label,
                    start: "\(today)T\(b.start)", end: "\(today)T\(b.end)")
    }
  }

  static func parse(_ text: String) -> (start: String, end: String, label: String)? {
    guard let p = keywordParts(withoutDates(text.lowercased())) else { return nil }
    // Klauseln nach dem Stichwort: die erste gehört dazu, die zweite nur als reine Dauer.
    let clauses = p.tail.components(separatedBy: ",")
    let after = clauses[0]
    let nextClause = clauses.count > 1 ? clauses[1] : ""
    // Vor dem Stichwort zählt nur die Klausel direkt davor (nach dem letzten Komma).
    let before = p.head.components(separatedBy: ",").last ?? ""

    let span: (Int, Int)
    if let r = range(after) {
      span = r
    } else if let s = startTime(after) ?? (range(before) == nil ? startTime(before) : nil) {
      // Höchstens ein Tag: „9223372036854775807 Minuten“ darf nicht überlaufen.
      let length = min(duration(after) ?? (startTime(nextClause) == nil ? duration(nextClause) : nil) ?? 60, 1440)
      span = (s, s + length)
    } else {
      return nil  // Dauer ohne Startzeit oder Zeitraum eines anderen Satzteils: keine Pause
    }
    let end = min(span.1, 1439)  // nie über den Tag hinaus (23:59)
    guard span.0 < end else { return nil }
    return (clock(span.0), clock(end), p.label)
  }

  /// Stichwort ("Mittagspause", "Mittag", "Mittagessen", "Pause") im ersten Satz, der es enthält.
  /// Mittagsschlaf zählt nicht, weil nach "Mittag" kein Buchstabe folgen darf.
  private static let keywordPattern = #"(?<!\p{L})(mittag(?:spause|essen)?|pause)(?!\p{L})"#
  /// Nur echte Verneinungen des Stichworts ("keine Mittagspause", "kein Mittag(essen)", "ohne Mittagspause",
  /// "Mittagspause entfällt/fällt weg"). Füllwörter wie "nicht länger" zählen nicht.
  /// Auch "Mittagspause gestrichen", "Mittagspause fällt (heute) aus" und "Mittagspause ist gestrichen".
  private static let negationPattern =
    #"(?<!\p{L})(?:kein(?:e|er|en|em|es)?|ohne)\s+(?:die\s+)?(?:mittag(?:spause|essen)?|pause)(?!\p{L})|(?<!\p{L})(?:mittag(?:spause|essen)?|pause)(?!\p{L})\s+(?:(?:ist|wird)\s+)?(?:entfällt|entfaellt|gestrichen|fällt\s+(?:(?:heute|morgen)\s+)?(?:weg|aus)|faellt\s+(?:(?:heute|morgen)\s+)?(?:weg|aus))"#

  private static func keywordParts(_ text: String) -> (label: String, head: String, tail: String, sentence: String)? {
    for s in text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
      guard let m = s.range(of: keywordPattern, options: .regularExpression) else { continue }
      let label = s[m].hasPrefix("mittag") ? "Mittagspause" : "Pause"
      return (label, String(s[..<m.lowerBound]), String(s[m.upperBound...]), s)
    }
    return nil
  }

  /// Datumsangaben ("12.10.", "12.10.2026") und Jahreszahlen sind keine Uhrzeiten.
  private static func withoutDates(_ t: String) -> String {
    var s = t
    // ISO-Datum zuerst, sonst bliebe "-10-15" stehen und ergäbe eine Uhrzeit. "12.30 Uhr" bleibt Uhrzeit.
    for pattern in [#"\d{4}-\d{2}-\d{2}(?:t\d{2}:\d{2})?"#,
                    #"(?<!\d)(?:3[01]|[12]\d|0?[1-9])\.(?:1[0-2]|0?[1-9])\.(?:\d{4}|\d{2})?(?!\d)(?!\s*uhr)"#,
                    #"(?<!\d)\d{4}(?!\d)"#] {
      s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    // "12.30" ist eine Uhrzeit: der Punkt darf den Satz nicht trennen (keywordParts splittet am Punkt).
    return s.replacingOccurrences(of: #"(?<!\d)(\d{1,2})\.(\d{2})(?!\d)"#, with: "$1:$2", options: .regularExpression)
  }

  private static func range(of pattern: String, in text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  /// "von 12 bis 13 Uhr", "12:30-13:15", "zwischen 12 und 13 Uhr".
  private static func range(_ t: String) -> (Int, Int)? {
    guard let g = groups(#"(?<!\d)(\d{1,2})(?:[:.](\d{2}))?\s*(?:uhr)?\s*(?:bis|und|-|–)\s*(\d{1,2})(?:[:.](\d{2}))?(?!\d)"#, t),
          let s = minutes(g[1], g[2]), let e = minutes(g[3], g[4]), e > s else { return nil }
    return (s, e)
  }

  /// Startzeit ("um 12 Uhr", "12:30"); Zahlen, die eine Dauer oder Teil eines Zeitraums sind, zählen nicht.
  private static func startTime(_ t: String) -> Int? {
    guard let g = groups(#"(?<!\d)(\d{1,2})(?:[:.](\d{2}))?(?!\d)(?!\s*(?:minuten|minute|min|stunden|stunde|std|h)(?!\p{L}))(?!\s*(?:bis|und|-|–)\s*\d)"#, t)
    else { return nil }
    return minutes(g[1], g[2])
  }

  private static func duration(_ t: String) -> Int? {
    if let g = groups(#"(\d+)\s*(?:minuten|minute|min)(?!\p{L})"#, t), let m = Int(g[1] ?? "") { return min(m, 1440) }
    if let g = groups(#"(\d+(?:[.,]\d+)?)\s*(?:stunden|stunde|std|h)(?!\p{L})"#, t),
       let h = Double((g[1] ?? "").replacingOccurrences(of: ",", with: ".")), h.isFinite {
      return Int(min(h * 60, 1440).rounded())
    }
    if groups(#"halbe\s+stunde"#, t) != nil { return 30 }
    if groups(#"(?<!\p{L})ein(?:e|er|en)?\s+stunde"#, t) != nil { return 60 }
    return nil
  }

  /// Capture-Gruppen des ersten Treffers (Index 0 = ganzer Treffer).
  private static func groups(_ pattern: String, _ text: String) -> [String?]? {
    guard let re = RegexCache.compile(pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
      Range(m.range(at: i), in: text).map { String(text[$0]) }
    }
  }

  /// Stunde und optionale Minute zu Minuten seit Mitternacht; 24:00 nur als Ende gültig.
  private static func minutes(_ h: String?, _ m: String?) -> Int? {
    guard let h = h, let hour = Int(h), hour <= 24 else { return nil }
    let minute = m.flatMap { Int($0) } ?? 0
    guard minute < 60, hour * 60 + minute <= 1440 else { return nil }
    return hour * 60 + minute
  }

  private static func clock(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }
}

extension CoreServices {
  /// Heutige Pausen aus dem Gedächtnis als belegte Zeit für die Tagesplanung.
  func breakBusyEvents() -> [CalendarEvent] {
    BreakMemoryParser.busyEvents(memories: (try? store.memories.list()) ?? [],
                                 today: LocalTime.formatDate(clock.now()))
  }
}
