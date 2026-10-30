// Meeting-Begleiter (Paket 4): Vorbereitung vor einem Termin und Stichpunkte
// danach. Reiner Code; Zeiten sind lokale ISO-Strings, `now` kommt als Parameter.
import Foundation

public enum MeetingCompanion {
  /// Bevorzugte Video- und Besprechungsdienste (Host oder Subdomain).
  static let preferredHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]
  /// Wörter, die nicht als Schlüsselwort zählen (deutsch und englisch).
  static let stopwords: Set<String> = [
    "termin", "meeting", "call", "mit", "und", "für", "fuer", "vom", "von", "über", "ueber", "beim", "bei",
    "zum", "zur", "dem", "den", "der", "die", "das", "eine", "einen", "with", "from", "about", "the",
  ]
  /// Höchstens so viele Notizen und Aufgaben pro Karte.
  static let maxNotes = 3
  static let maxTasks = 5
  /// Termine kürzer als so viele Minuten bekommen keine Nachbereitung.
  static let minEndedMinutes = 15

  /// Stabiler Schlüssel: "<sourceId>|<eventId>|<start>".
  public static func key(_ e: CalendarEvent) -> String {
    "\(e.sourceId)|\(e.id)|\(e.start)"
  }

  /// Erster Link aus dem Text: zuerst Zoom, Meet, Teams oder Webex, sonst der
  /// erste https-Link. Satzzeichen am Ende werden entfernt.
  public static func extractLink(_ text: String?) -> String? {
    guard let text = text, !text.isEmpty else { return nil }
    let links = matches(of: #"https://[^\s<>"']+"#, in: text)
      .map(trimLink)
      .filter { URL(string: $0)?.host?.isEmpty == false }
    if let preferred = links.first(where: isPreferred) { return preferred }
    return links.first
  }

  /// Der nächste Termin mit Uhrzeit, der in (now, now + leadMinutes] beginnt
  /// und noch nicht bearbeitet wurde (Schlüssel + "#upcoming").
  public static func upcoming(events: [CalendarEvent], now: String, leadMinutes: Int,
                              handled: Set<String>) -> CalendarEvent? {
    guard let nowMinutes = ProductivityTime.minutes(now) else { return nil }
    return timedEvents(events)
      .filter { ev in
        guard let start = ProductivityTime.minutes(ev.start) else { return false }
        return start > nowMinutes && start <= nowMinutes + leadMinutes && !handled.contains(key(ev) + "#upcoming")
      }
      .min { (ProductivityTime.minutes($0.start) ?? 0) < (ProductivityTime.minutes($1.start) ?? 0) }
  }

  /// Termin mit Uhrzeit, der gerade läuft (Start ≤ jetzt < Ende).
  public static func running(events: [CalendarEvent], now: String) -> CalendarEvent? {
    guard let nowMinutes = ProductivityTime.minutes(now) else { return nil }
    return timedEvents(events).first { ev in
      guard let start = ProductivityTime.minutes(ev.start) else { return false }
      return start <= nowMinutes && nowMinutes < endMinutes(ev, start: start)
    }
  }

  /// Ein Termin mit Uhrzeit, der vor höchstens 30 Minuten endete (Ende ohne
  /// Angabe = Start + 60 Minuten), mindestens 15 Minuten lang war und noch nicht
  /// bearbeitet wurde (Schlüssel + "#ended"). Bei mehreren: der zuletzt endete.
  public static func ended(events: [CalendarEvent], now: String, handled: Set<String>) -> CalendarEvent? {
    guard let nowMinutes = ProductivityTime.minutes(now) else { return nil }
    let candidates: [(event: CalendarEvent, end: Int)] = timedEvents(events).compactMap { ev in
      guard let start = ProductivityTime.minutes(ev.start) else { return nil }
      let end = endMinutes(ev, start: start)
      guard end - start >= minEndedMinutes else { return nil }
      guard end >= nowMinutes - 30, end <= nowMinutes, !handled.contains(key(ev) + "#ended") else { return nil }
      return (ev, end)
    }
    return candidates.max { $0.end < $1.end }?.event
  }

  /// Notizen (höchstens 3) und offene Aufgaben (höchstens 5), die ein Schlüsselwort
  /// aus dem Termintitel (mindestens 4 Buchstaben, ohne Füllwörter) enthalten.
  /// Notizen, deren Kennzeichen im Termintitel vorkommen, zählen auch dazu.
  /// Termin-Notizen (Agenda/Mitschrift) schlagen sich selbst nicht vor.
  public static func related(event: CalendarEvent, notes: [Note], tasks: [TabyTask])
    -> (notes: [MeetingRef], tasks: [MeetingRef]) {
    let words = keywords(event.title)
    let lowerTitle = event.title.lowercased()
    func mentions(_ texts: String...) -> Bool {
      texts.contains { text in
        let lower = text.lowercased()
        return words.contains { lower.contains($0) }
      }
    }
    let matchingNotes = notes
      .filter { note in
        note.meetingKey == nil && (mentions(note.title, note.content)
          || note.tags.contains { $0.count >= 3 && lowerTitle.contains($0.lowercased()) })
      }
      .prefix(maxNotes)
      .map { MeetingRef(id: $0.id, title: $0.title) }
    let matchingTasks = tasks
      .filter { !$0.done && mentions($0.title, $0.notes ?? "") }
      .prefix(maxTasks)
      .map { MeetingRef(id: $0.id, title: $0.title) }
    return (matchingNotes, matchingTasks)
  }

  /// Karte für einen Termin (Vorbereitung oder Nachbereitung).
  public static func brief(event: CalendarEvent, phase: MeetingBrief.Phase, notes: [Note],
                           tasks: [TabyTask], prepNoteId: String? = nil) -> MeetingBrief {
    let related = related(event: event, notes: notes, tasks: tasks)
    return MeetingBrief(id: key(event), phase: phase, title: event.title, start: event.start, end: event.end,
                        link: extractLink(event.notes), notes: related.notes, tasks: related.tasks,
                        prepNoteId: prepNoteId)
  }

  /// Zeilen mit "- ", "* ", "• ", "[ ] ", "- [ ] ", "TODO:" oder "Aufgabe:" werden zu
  /// Aufgabentiteln (Präfix entfernt, getrimmt, nicht leer).
  public static func tasksFromNotes(_ text: String) -> [String] {
    let prefixes = ["- [ ] ", "[ ] ", "- ", "* ", "• ", "TODO:", "Aufgabe:"]
    return text.components(separatedBy: .newlines).compactMap { raw -> String? in
      let line = raw.trimmingCharacters(in: .whitespaces)
      let upper = line.uppercased()
      guard let prefix = prefixes.first(where: { upper.hasPrefix($0.uppercased()) }) else { return nil }
      let title = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? nil : title
    }
  }

  // MARK: - Hilfsfunktionen

  /// Termine mit Uhrzeit (ohne ganztägige und reine Datumsangaben).
  private static func timedEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
    events.filter { !$0.allDay && !LocalTime.isDateOnly($0.start) }
  }

  /// Ende in Minuten; ohne Angabe Start + 60, nie vor dem Start.
  private static func endMinutes(_ ev: CalendarEvent, start: Int) -> Int {
    guard let end = ev.end.flatMap({ ProductivityTime.minutes($0) }) else { return start + 60 }
    return max(end, start)
  }

  private static func keywords(_ title: String) -> [String] {
    var seen = Set<String>()
    var words: [String] = []
    for part in title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) {
      guard part.count >= 4, !stopwords.contains(part), !seen.contains(part) else { continue }
      seen.insert(part)
      words.append(part)
    }
    return words
  }

  private static func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = RegexCache.compile(pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }

  /// Entfernt angehängte Satzzeichen wie ")", ".", ",", ">".
  private static func trimLink(_ link: String) -> String {
    var s = link
    while let last = s.last, ")].,;:!?>\"'".contains(last) {
      s.removeLast()
    }
    return s
  }

  private static func isPreferred(_ link: String) -> Bool {
    guard let host = URL(string: link)?.host?.lowercased() else { return false }
    return preferredHosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }
}

/// Gemeinsame Minutenrechnung für Zeiten "YYYY-MM-DDTHH:mm" (Wanduhrzeit).
enum ProductivityTime {
  static func minutes(_ s: String) -> Int? {
    guard let d = StoreDates.wallClock(s) else { return nil }
    return Int((d.timeIntervalSince1970 / 60).rounded(.down))
  }
}
