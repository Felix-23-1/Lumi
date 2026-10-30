// Einordnung von Mails ohne Modell: Absender- und Betreff-Regeln.
import Foundation

/// Zerlegt „Name <adresse>“ in Name und Adresse.
public enum MailAddress {
  public static func parse(_ raw: String) -> (name: String, address: String) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close else {
      return ("", s)
    }
    let address = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    var name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
    if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
      name = String(name.dropFirst().dropLast())
    }
    return (name.trimmingCharacters(in: .whitespaces), address)
  }
}

public enum MailTriage {
  static let newsletterLocalParts = ["noreply", "no-reply", "newsletter", "news", "marketing", "mailer", "notifications", "updates"]
  static let importantWords = ["rechnung", "frist", "fällig", "dringend", "wichtig", "mahnung", "termin", "einladung", "vertrag", "kündigung"]

  /// Newsletter, Werbung, automatische Benachrichtigungen.
  static func isNewsletter(_ m: MailMessage) -> Bool {
    let address = m.senderAddress.lowercased()
    let local = address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
    if local == "info" || newsletterLocalParts.contains(where: { local.contains($0) }) { return true }
    let subject = m.subject.lowercased()
    if subject.contains("newsletter") || subject.contains("% ") || subject.contains("rabatt")
      || subject.contains("angebot") || subject.contains("unsubscribe") {
      return true
    }
    let words = Set(subject.split { !$0.isLetter }.map(String.init))
    return words.contains("sale") || words.contains("deal")
  }

  /// Wichtig: markiert, Frist-/Rechnungs-Wörter, Antworten, Absender mit Vor- und Nachname.
  static func isImportant(_ m: MailMessage) -> Bool {
    if m.flagged { return true }
    let subject = m.subject.lowercased().trimmingCharacters(in: .whitespaces)
    if subject.hasPrefix("re:") || subject.hasPrefix("aw:") { return true }
    if importantWords.contains(where: { subject.contains($0) }) { return true }
    return m.senderName.trimmingCharacters(in: .whitespaces).contains(" ")
  }

  public static func categorize(_ m: MailMessage) -> MailCategory {
    if isNewsletter(m) { return .newsletter }
    if isImportant(m) { return .important }
    return .normal
  }

  /// Überblick: ordnet ein, zählt ungelesene, neueste zuerst, höchstens 40 Mails.
  public static func overview(_ messages: [MailMessage], now: String) -> MailOverview {
    let sorted = messages.sorted { $0.date > $1.date }.prefix(40).map { m -> MailMessage in
      var copy = m
      copy.category = categorize(m)
      return copy
    }
    return MailOverview(messages: Array(sorted), unread: sorted.filter { !$0.read }.count, fetchedAt: now)
  }

  /// Ein Satz fürs Briefing, nur mit Anzahl und Absendernamen (nie Betreff oder Inhalt).
  /// nil, wenn nichts ungelesen ist.
  public static func briefingLine(_ o: MailOverview) -> String? {
    guard o.unread > 0 else { return nil }
    let count = o.unread == 1 ? "1 neue Mail" : "\(o.unread) neue Mails"
    var names: [String] = []
    for m in o.messages where !m.read && m.category == .important {
      let name = m.senderName.trimmingCharacters(in: .whitespaces)
      if !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    guard !names.isEmpty else { return count }
    return "\(count), wichtig: " + names.prefix(3).joined(separator: ", ")
  }
}
