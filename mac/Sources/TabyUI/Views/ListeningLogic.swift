// Reine Logik für die Mitschrift im Meeting (ohne SwiftUI): Einwilligung, Gruppen und
// Vorauswahl der Aufgaben-Kandidaten, Bearbeiten, Zählen und Zeitanzeige.
// Alles hier ist in ListeningChecks prüfbar.
import Foundation
import TabyCore

enum ListeningLogic {
  /// Ankündigungssatz, den der Nutzer den anderen Teilnehmern schickt (kopierbar).
  static let announcement = "Ich lasse dieses Gespräch lokal von meinem Assistenten mitschreiben (nur Text, kein Ton wird gespeichert). Ist das für alle okay?"
  static let allHint = "Alle Teilnehmer müssen einverstanden sein. Nur Text wird gespeichert, kein Ton."
  static let consentLabel = "Ich habe alle informiert und sie sind einverstanden"

  static func modeTitle(_ mode: MeetingListenMode) -> String {
    switch mode {
    case .onlyMe: "Nur ich (Mikrofon)"
    case .everyone: "Alle (Mikrofon + Ton der anderen)"
    }
  }

  /// „Nur ich“ startet immer; „Alle“ erst mit gesetztem Häkchen.
  static func canStart(mode: MeetingListenMode, consent: Bool) -> Bool {
    mode == .onlyMe || consent
  }

  /// Wert für `consentGiven`: wahr nur bei „Alle“ mit Häkchen.
  static func consentGiven(mode: MeetingListenMode, consent: Bool) -> Bool {
    mode == .everyone && consent
  }

  /// Klare Zusagen und Merker gehören zu „Sicher“, Vermutungen zu „Unklar“.
  static func isSure(_ c: ActionCandidate) -> Bool { c.confidence != .guess }

  static func sure(_ items: [ActionCandidate]) -> [ActionCandidate] { items.filter(isSure) }

  static func unclear(_ items: [ActionCandidate]) -> [ActionCandidate] { items.filter { !isSure($0) } }

  /// Vorgewählt sind nur die sicheren Kandidaten.
  static func preselected(_ items: [ActionCandidate]) -> Set<String> {
    Set(sure(items).map(\.id))
  }

  static func toggled(_ selected: Set<String>, _ id: String) -> Set<String> {
    var out = selected
    if out.contains(id) { out.remove(id) } else { out.insert(id) }
    return out
  }

  /// Gewählte Kandidaten in Listenreihenfolge. Ohne Text fallen sie weg (nichts Leeres anlegen).
  static func chosen(_ items: [ActionCandidate], _ selected: Set<String>) -> [ActionCandidate] {
    items.filter { selected.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  /// Ändert eine Zeile (Text, Zuständige, Fälligkeit); andere Zeilen bleiben gleich.
  static func edit(_ items: [ActionCandidate], id: String, _ change: (inout ActionCandidate) -> Void) -> [ActionCandidate] {
    items.map { c in
      guard c.id == id else { return c }
      var out = c
      change(&out)
      return out
    }
  }

  /// Zuständige zur Auswahl: „Ich“, die Namen aus den Kandidaten, „Unklar“ (nil).
  static func ownerOptions(_ items: [ActionCandidate]) -> [String?] {
    var names: [String] = []
    for owner in items.compactMap(\.owner) where owner.lowercased() != "ich" && !names.contains(owner) {
      names.append(owner)
    }
    return ["ich"] + names + [nil]
  }

  static func ownerLabel(_ owner: String?) -> String {
    guard let owner else { return "Unklar" }
    return owner.lowercased() == "ich" ? "Ich" : owner
  }

  /// Fälligkeit als Datum im Format "YYYY-MM-DD"; das Datum im Kalender kommt aus `LocalTime`.
  static func dueDate(_ due: String?, today: String) -> Date {
    LocalTime.parse("\(LocalTime.datePart(due ?? today))T12:00") ?? Date()
  }

  static func dueString(_ date: Date) -> String {
    LocalTime.datePart(LocalTime.format(date))
  }

  static func acceptLabel(_ n: Int) -> String { "Ausgewählte anlegen (\(n))" }

  static func acceptedText(_ n: Int) -> String {
    switch n {
    case 0: "Keine Aufgabe angelegt"
    case 1: "1 Aufgabe angelegt"
    default: "\(n) Aufgaben angelegt"
    }
  }

  static func linesText(_ n: Int) -> String {
    n == 1 ? "1 Zeile" : "\(n) Zeilen"
  }

  /// Laufzeit "mm:ss" zwischen Start und jetzt (beide als lokale Zeit "YYYY-MM-DDTHH:mm").
  static func elapsedText(startedAt: String, now: String) -> String {
    guard let s = LocalTime.parse(startedAt), let n = LocalTime.parse(now) else { return "00:00" }
    return FocusClock.format(Int(n.timeIntervalSince(s).rounded(.down)))
  }
}
