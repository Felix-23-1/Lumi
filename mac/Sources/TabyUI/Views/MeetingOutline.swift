// Gliederung der Termin-Notiz für die Meeting-Karte: Abschnitte („## “) mit Unterabschnitten
// („### “) und Einträgen aus dem Markdown der Notiz. Dazu „Noch im Meeting“: lokal je Termin
// gemerkt, Ablauf über die injizierte Uhr. Reine Logik, in MeetingPrepChecks geprüft.
import Foundation
import TabyCore

enum MeetingOutline {
  struct Sub: Equatable {
    var heading: String
    var items: [String]
  }

  struct Section: Equatable, Identifiable {
    var heading: String
    var subs: [Sub]
    var id: String { heading }
  }

  /// Gliedert Markdown. Ein „# “-Kopf fällt weg, Einträge ohne Abschnitt landen in einem Abschnitt ohne Namen.
  static func parse(_ content: String) -> [Section] {
    var out: [Section] = []
    for raw in content.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("### ") {
        ensureSection(&out)
        out[out.count - 1].subs.append(Sub(heading: plain(line.dropFirst(4)), items: []))
      } else if line.hasPrefix("## ") {
        out.append(Section(heading: plain(line.dropFirst(3)), subs: []))
      } else if let item = item(line) {
        ensureSection(&out)
        if out[out.count - 1].subs.isEmpty { out[out.count - 1].subs.append(Sub(heading: "", items: [])) }
        out[out.count - 1].subs[out[out.count - 1].subs.count - 1].items.append(item)
      }
    }
    return out.filter { section in section.subs.contains { !$0.items.isEmpty } }
  }

  /// Namen für die Vorher-Ansicht: Agenda → „Worum geht es“, Offene Punkte → „Offene Aufgaben“,
  /// Mitschrift → „Notizen“. Unbekannte Abschnitte bleiben, wie sie sind.
  static func preparation(_ sections: [Section]) -> [Section] {
    let names = ["Agenda": "Worum geht es", "Offene Punkte": "Offene Aufgaben", "Mitschrift": "Notizen"]
    return sections.map { Section(heading: names[$0.heading] ?? $0.heading, subs: $0.subs) }
  }

  /// Der Abschnitt „Zusammenfassung“ einer Notiz, nil wenn es ihn nicht gibt.
  static func summary(in content: String) -> Section? {
    parse(content).first { $0.heading == "Zusammenfassung" }
  }

  private static func ensureSection(_ out: inout [Section]) {
    if out.isEmpty { out.append(Section(heading: "", subs: [])) }
  }

  /// Eintrag einer Zeile: ohne Aufzählungszeichen und Kästchen; Überschriften „#“ und leere Zeilen fallen weg.
  private static func item(_ line: String) -> String? {
    guard !line.hasPrefix("#") else { return nil }
    var s = line
    if let p = ["- ", "* ", "• "].first(where: { s.hasPrefix($0) }) { s = String(s.dropFirst(p.count)) }
    s = s.trimmingCharacters(in: .whitespaces)
    for box in ["[ ] ", "[x] ", "[X] "] where s.hasPrefix(box) { s = String(s.dropFirst(box.count)) }
    s = s.trimmingCharacters(in: .whitespaces)
    return s.isEmpty || s == "-" ? nil : s
  }

  private static func plain(_ s: Substring) -> String {
    s.trimmingCharacters(in: CharacterSet(charactersIn: " *:"))
  }
}

/// „Noch im Meeting“: je Termin lokal gemerkt. Wert „open“ = läuft, bis „Meeting beendet“;
/// sonst das Ende als lokaler ISO-String. Ablauf nur über die übergebene Zeit (`now`).
enum MeetingLive {
  static let open = "open"
  /// Dauer-Chips für „fertig um …“ in Minuten.
  static let durations = [15, 30, 60]

  static func key(_ id: String) -> String { "meetingStillIn|" + id }

  static func stored(_ id: String, defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: key(id))
  }

  static func isRunning(_ id: String, now: String, defaults: UserDefaults = .standard) -> Bool {
    guard let value = stored(id, defaults: defaults) else { return false }
    if value == open { return true }
    guard let until = LocalTime.parse(value), let n = LocalTime.parse(now) else { return false }
    return until > n
  }

  /// Startet „Noch im Meeting“: mit Minuten bis zum Ende, ohne Minuten offen.
  static func start(_ id: String, now: String, minutes: Int?, defaults: UserDefaults = .standard) {
    guard let minutes else { defaults.set(open, forKey: key(id)); return }
    guard let n = LocalTime.parse(now) else { return }
    defaults.set(LocalTime.format(n.addingTimeInterval(TimeInterval(minutes * 60))), forKey: key(id))
  }

  static func clear(_ id: String, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(id))
  }

  /// „bis 16:45“ bzw. „bis du es beendest“ für die Karte.
  static func line(_ id: String, defaults: UserDefaults = .standard) -> String {
    guard let value = stored(id, defaults: defaults), value != open else { return "Läuft, bis du es beendest" }
    return "Läuft bis \(GermanDate.time(value) ?? value)"
  }
}
