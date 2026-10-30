// Konflikt-Wächter (BAUPLAN.md Abschnitt 7), Port von
// src/main/store/conflicts.ts: reine Funktionen, keine DB, keine Uhr. Von
// add_event UND von der Oberfläche beim manuellen Eintragen genutzt.
import Foundation

/// Fehlt `end`, gilt start + 60 Minuten.
private let defaultEventDuration: TimeInterval = 60 * 60

private func eventRange(start: String, end: String?) -> (start: Date, end: Date)? {
  guard let s = StoreDates.wallClock(start) else { return nil }
  if let end, let e = StoreDates.wallClock(end) { return (s, e) }
  return (s, s.addingTimeInterval(defaultEventDuration))
}

/// Zwei Termine mit Uhrzeit überschneiden sich, wenn startA < endB && startB < endA.
/// Ganztägige Termine (neu oder bestehend) sind nie ein Konflikt; gleicher
/// Start ergibt `.sameStart`, sonst `.overlap`.
///
/// `bufferMinutes` > 0: Überschneidet sich nichts, aber der Abstand zu einem
/// bestehenden Termin ist kleiner als der Puffer (Start oder Ende zu nah am
/// anderen Termin), ergibt das `.tooClose`. Genau der Puffer gilt als ausreichend.
public func findConflicts(_ newEvent: NewEvent, _ existing: [CalendarEvent], bufferMinutes: Int = 0) -> [Conflict] {
  if LocalTime.isDateOnly(newEvent.start) { return [] }
  guard let a = eventRange(start: newEvent.start, end: newEvent.end) else { return [] }
  let bufferSeconds = TimeInterval(max(0, bufferMinutes)) * 60
  var conflicts: [Conflict] = []
  for ev in existing {
    if ev.allDay || LocalTime.isDateOnly(ev.start) { continue }
    guard let b = eventRange(start: ev.start, end: ev.end) else { continue }
    if a.start < b.end && b.start < a.end {
      conflicts.append(Conflict(with: ev, kind: a.start == b.start ? .sameStart : .overlap))
      continue
    }
    guard bufferSeconds > 0 else { continue }
    // Ohne Überschneidung liegt einer der beiden Termine vollständig vor dem anderen.
    let gap = a.end <= b.start ? b.start.timeIntervalSince(a.end) : a.start.timeIntervalSince(b.end)
    if gap < bufferSeconds { conflicts.append(Conflict(with: ev, kind: .tooClose)) }
  }
  return conflicts
}

/// Ganztägige Termine am selben Kalendertag wie `newEvent`: kein Konflikt,
/// aber ein Hinweis (`info`), den add_event zusätzlich mitgibt.
public func allDayNotices(_ newEvent: NewEvent, _ existing: [CalendarEvent]) -> [CalendarEvent] {
  let day = LocalTime.datePart(newEvent.start)
  return existing.filter { $0.allDay && LocalTime.datePart($0.start) == day }
}

/// Konflikte innerhalb einer Terminliste (jedes Paar einmal), für den Überblick.
public func pairwiseConflicts(_ events: [CalendarEvent]) -> [Conflict] {
  var conflicts: [Conflict] = []
  for (i, candidate) in events.enumerated() {
    let rest = Array(events[(i + 1)...])
    conflicts += findConflicts(NewEvent(title: candidate.title, start: candidate.start, end: candidate.end), rest)
  }
  return conflicts
}
