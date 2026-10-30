// Nachbereitung nach einem Termin: Text und Empfänger des Mail-Entwurfs.
// Reiner Code; die Mail selbst öffnet MailBackend.openNewDraft (sendet nie).
import Foundation

public enum MeetingFollowUp {
  /// "YYYY-MM-DDTHH:mm" → "dd.MM.yyyy".
  public static func germanDate(_ start: String) -> String {
    let date = LocalTime.datePart(start)
    let parts = date.split(separator: "-")
    guard parts.count == 3 else { return date }
    return "\(parts[2]).\(parts[1]).\(parts[0])"
  }

  public static func subject(title: String, start: String) -> String {
    "Nachbereitung: \(title) (\(germanDate(start)))"
  }

  /// Teilnehmer-Adressen aus EventKit-URLs („mailto:…“). Ohne Adresse, doppelt oder
  /// fremd (https usw.) fällt weg.
  public static func addresses(from urls: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for raw in urls where raw.lowercased().hasPrefix("mailto:") {
      let decoded = String(raw.dropFirst(7)).removingPercentEncoding ?? ""
      let address = decoded.trimmingCharacters(in: .whitespaces)
      guard address.contains("@"), !address.contains(where: \.isWhitespace) else { continue }
      if seen.insert(address.lowercased()).inserted { out.append(address) }
    }
    return out
  }

  /// Stichpunkte-Notiz dieses Termins (so benannt, wenn Lumi sie beim Speichern anlegt).
  public static func meetingNote(_ notes: [Note], title: String, start: String) -> Note? {
    let wanted = "Notizen: \(title) (\(GermanDateText.short(LocalTime.datePart(start))))"
    return notes.first { $0.title == wanted }
  }

  /// Offene Aufgaben, die aus diesem Termin entstanden sind.
  public static func openTasks(_ tasks: [TabyTask], title: String) -> [String] {
    tasks.filter { !$0.done && $0.notes == "Aus: \(title)" }.map(\.title)
  }

  public static func body(title: String, start: String, notes: String?, openTasks: [String]) -> String {
    let stichpunkte = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var lines = ["Hallo zusammen,", "", "danke für das Gespräch „\(title)“ am \(germanDate(start))."]
    if stichpunkte.isEmpty && openTasks.isEmpty {
      lines += ["", "Hier kommt noch eine kurze Zusammenfassung mit den nächsten Schritten."]
    } else {
      if !stichpunkte.isEmpty { lines += ["", stichpunkte] }
      if !openTasks.isEmpty { lines += ["", "Offene Punkte:"] + openTasks.map { "- \($0)" } }
    }
    lines += ["", "Viele Grüße"]
    return lines.joined(separator: "\n")
  }

  public static func draft(title: String, start: String, to: [String], notes: String?, openTasks: [String]) -> MailDraft {
    MailDraft(to: to, subject: subject(title: title, start: start),
              body: body(title: title, start: start, notes: notes, openTasks: openTasks))
  }
}
