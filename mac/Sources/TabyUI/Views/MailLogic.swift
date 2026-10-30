// Reine Logik des Mail-Reiters (ohne Ansicht, ohne Kern): Filter, Zeitangaben,
// Vorschau-Kürzung und die Zeile in der Insel. Prüfungen in MailChecks.swift.
import Foundation
import TabyCore

/// Filter der Posteingangsliste.
enum MailFilter: String, CaseIterable, Identifiable {
  case important, all, newsletter

  var id: String { rawValue }

  var title: String {
    switch self {
    case .important: "Wichtig"
    case .all: "Alle"
    case .newsletter: "Newsletter"
    }
  }
}

enum MailLogic {
  /// Wie viele Zeichen einer Mail im Aufklappen gezeigt werden.
  static let previewLimit = 600
  static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
  static let privacyText = "Lumi liest Betreff und Absender aus Apple Mail. Inhalte bleiben auf deinem Mac, "
    + "solange „Nur lokal“ an ist. Senden, Archivieren und Löschen nur nach deinem Klick."

  /// Neueste zuerst; bei gleichem Zeitpunkt bleibt die Reihenfolge der Liste.
  static func sorted(_ messages: [MailMessage]) -> [MailMessage] {
    messages.enumerated()
      .sorted { a, b in
        if a.element.date != b.element.date { return a.element.date > b.element.date }
        return a.offset < b.offset
      }
      .map(\.element)
  }

  static func filter(_ messages: [MailMessage], _ filter: MailFilter) -> [MailMessage] {
    let base = sorted(messages)
    switch filter {
    case .all: return base
    case .important: return base.filter { $0.category == .important }
    case .newsletter: return base.filter { $0.category == .newsletter }
    }
  }

  static func importantUnread(_ messages: [MailMessage]) -> Int {
    messages.filter { $0.category == .important && !$0.read }.count
  }

  static func unreadCount(_ messages: [MailMessage]) -> Int {
    messages.filter { !$0.read }.count
  }

  /// „Wichtig“, wenn es ungelesene wichtige Mails gibt, sonst „Alle“.
  static func defaultFilter(_ messages: [MailMessage]) -> MailFilter {
    importantUnread(messages) > 0 ? .important : .all
  }

  /// Anzeigename: Name, sonst Adresse.
  static func senderLabel(_ m: MailMessage) -> String {
    m.senderName.trimmingCharacters(in: .whitespaces).isEmpty ? m.senderAddress : m.senderName
  }

  /// "08:41" am selben Tag, "gestern", Wochentag (Fr) innerhalb einer Woche, sonst "10.10.".
  /// Beide Angaben sind lokale ISO-Zeiten ("YYYY-MM-DDTHH:mm").
  static func relativeTime(_ date: String, now: String) -> String {
    guard let day = dayNumber(date), let today = dayNumber(now) else { return date }
    let diff = today - day
    if diff <= 0 { return timePart(date) }
    if diff == 1 { return "gestern" }
    if diff < 7 { return weekdayShort(day) }
    let parts = datePart(date).split(separator: "-")
    guard parts.count == 3 else { return date }
    return "\(parts[2]).\(parts[1])."
  }

  /// Kürzt den Text auf `limit` Zeichen; mit „…“, wenn gekürzt wurde.
  static func previewText(_ body: String, limit: Int = previewLimit) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  /// Zeile in der Insel: "3 ungelesen · 1 wichtig", sonst Hinweis auf Aus/Fehler.
  static func islandLines(_ overview: MailOverview?) -> [String] {
    guard let m = overview else { return ["Aus"] }
    if m.error != nil { return [m.accessDenied ? "Freigabe fehlt" : "Nicht erreichbar"] }
    guard m.unread > 0 else { return ["Alles gelesen"] }
    var line = "\(m.unread) ungelesen"
    let important = importantUnread(m.messages)
    if important > 0 { line += " · \(important) wichtig" }
    return [line]
  }

  // MARK: Datum (ohne Foundation-Formatierer, damit es in Prüfungen fest ist)

  private static func datePart(_ iso: String) -> String {
    String(iso.split(separator: "T").first ?? "")
  }

  private static func timePart(_ iso: String) -> String {
    guard let t = iso.split(separator: "T").dropFirst().first else { return "" }
    return String(t.prefix(5))
  }

  /// Julianische Tageszahl aus "YYYY-MM-DD"; nil bei unbekanntem Format.
  static func dayNumber(_ iso: String) -> Int? {
    let parts = datePart(iso).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    let (y, m, d) = (parts[0], parts[1], parts[2])
    let a = (14 - m) / 12
    let yy = y + 4800 - a
    let mm = m + 12 * a - 3
    return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
  }

  private static func weekdayShort(_ day: Int) -> String {
    // Tageszahl 0 ist ein Montag; (day + 1) % 7 ergibt 0 für Sonntag.
    let names = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
    return names[(day + 1) % 7]
  }
}
