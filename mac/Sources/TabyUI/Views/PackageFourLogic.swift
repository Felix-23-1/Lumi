// Reine Logik für Paket 4 (ohne SwiftUI): Tagesplan-Blöcke, Meeting-Zeiten,
// Wochenplanung, Dauerangaben, Priorität der Insel-Karten und Datei-Drop.
// Alles hier ist in ViewChecks prüfbar.
import Foundation
import TabyCore

enum DurationText {
  /// "5 h 40 min", "45 min", "2 h".
  static func hm(_ minutes: Int) -> String {
    let m = max(0, minutes)
    let h = m / 60
    let r = m % 60
    if h == 0 { return "\(r) min" }
    if r == 0 { return "\(h) h" }
    return "\(h) h \(r) min"
  }
}

enum PlanLogic {
  enum Status: Equatable { case past, current, upcoming }

  /// Vergleich über "YYYY-MM-DDTHH:mm" (lexikografisch entspricht der Zeit).
  static func status(_ b: PlannedBlock, now: String) -> Status {
    let n = String(now.prefix(16))
    let start = String(b.start.prefix(16))
    let end = String(b.end.prefix(16))
    if end <= n { return .past }
    if start <= n { return .current }
    return .upcoming
  }

  /// "10:00–10:30"
  static func timeRange(_ b: PlannedBlock) -> String {
    "\(GermanDate.time(b.start) ?? "")–\(GermanDate.time(b.end) ?? "")"
  }

  /// "2 passen heute nicht mehr rein"; nil ohne Aufgaben außerhalb des Plans.
  static func unplannedHint(_ n: Int) -> String? {
    switch n {
    case 0: nil
    case 1: "1 passt heute nicht mehr rein"
    default: "\(n) passen heute nicht mehr rein"
    }
  }
}

enum MeetingLogic {
  /// Minuten bis zum Start (kleiner/gleich 0 = jetzt bzw. vorbei); nil bei ungültiger Zeit.
  static func minutesUntil(_ start: String, now: String) -> Int? {
    guard let s = LocalTime.parse(start), let n = LocalTime.parse(now) else { return nil }
    return Int((s.timeIntervalSince(n) / 60).rounded())
  }

  /// "in 8 Min", "jetzt", "in 1 Std. 5 Min", "in 2 Std."
  static func relative(minutes m: Int) -> String {
    if m <= 0 { return "jetzt" }
    if m < 60 { return "in \(m) Min" }
    let h = m / 60
    let r = m % 60
    if r == 0 { return "in \(h) Std." }
    return "in \(h) Std. \(r) Min"
  }

  /// "15:00–16:00" bzw. "15:00", wenn kein Ende bekannt ist.
  static func span(_ m: MeetingBrief) -> String {
    let start = GermanDate.time(m.start) ?? ""
    guard let end = m.end.flatMap({ GermanDate.time($0) }) else { return start }
    return "\(start)–\(end)"
  }

  /// "in 8 Min · 15:00–16:00"
  static func countdownLine(_ m: MeetingBrief, now: String) -> String {
    let rel = relative(minutes: minutesUntil(m.start, now: now) ?? 0)
    return "\(rel) · \(span(m))"
  }

  /// Rückmeldung nach dem Speichern der Stichpunkte.
  static func savedText(taskCount n: Int) -> String {
    switch n {
    case 0: "Notiz gespeichert"
    case 1: "Notiz + 1 Aufgabe gespeichert"
    default: "Notiz + \(n) Aufgaben gespeichert"
    }
  }
}

enum WeeklyLogic {
  /// Bis zu drei getrimmte, nicht leere Ziele.
  static func goals(_ inputs: [String]) -> [String] {
    inputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(3)
      .map { $0 }
  }

  /// "6/7"
  static func habitFraction(_ h: HabitWeek) -> String { "\(h.days)/7" }
}

/// Welche Karte die offene Insel zeigt (Priorität: Tagesstart > Feierabend > Wochenplanung > Meeting > Reiter).
enum IslandCardKind: Equatable {
  case dayStart, dayEnd, weeklyReview, meeting, tab

  func title(tab: TabyTab) -> String {
    switch self {
    case .dayStart: "Briefing"
    case .dayEnd: "Feierabend"
    case .weeklyReview: "Wochenplanung"
    case .meeting: "Meeting"
    case .tab: tab.title
    }
  }
}

enum IslandCardRules {
  static func kind(dayStart: Bool, dayEnd: Bool, weeklyReview: Bool, meeting: Bool) -> IslandCardKind {
    if dayStart { return .dayStart }
    if dayEnd { return .dayEnd }
    if weeklyReview { return .weeklyReview }
    if meeting { return .meeting }
    return .tab
  }

  /// Wochenplanung wird nur gezeigt, wenn der Rückblick auch da ist.
  static func weeklyShown(_ s: AppState?) -> Bool {
    s?.weeklyReviewPrompt == true && s?.weeklyReview != nil
  }

  /// Die Insel bleibt offen, solange eine dieser Fragen beantwortet werden muss.
  static func promptHeld(dayEnd: Bool, weeklyReview: Bool, meeting: Bool) -> Bool {
    dayEnd || weeklyReview || meeting
  }

  /// Läuft gerade eine längere Arbeit (Netzwerk-Scan, Paket-Mitschnitt)? Dann
  /// hält sich die Insel von selbst offen, auch beim Klick nach außen.
  static func isBusy(_ state: AppState?) -> Bool {
    state?.network?.scanning == true || state?.network?.capturing == true
  }
}

enum DropLogic {
  static let maxFiles = 3

  /// Höchstens drei Dateien, leere Pfade fallen weg.
  static func limited(_ paths: [String]) -> [String] {
    Array(paths.filter { !$0.isEmpty }.prefix(maxFiles))
  }
}
