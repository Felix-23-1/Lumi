// Apple Mail: Schnittstelle zur Mail-App (Paket 5). Die Implementierung mit
// JXA steht in AppleMailBackend.swift, Test-Ersatz in FakeMailBackend.swift.
import Foundation

/// Zugriff auf Apple Mail. Alle Aufrufe sind asynchron und laufen nicht auf dem Hauptthread.
public protocol MailBackend: AnyObject, Sendable {
  /// Posteingang der letzten `days` Tage, neueste zuerst, höchstens `limit` Mails.
  /// Die Kategorie ist hier noch `.normal`; die Einordnung macht `MailTriage`.
  func inbox(days: Int, limit: Int) async throws -> [MailMessage]
  /// Nur-Text-Inhalt einer Mail (wird höchstens auf 20 000 Zeichen gekürzt).
  func body(id: String) async throws -> String
  func setRead(id: String, _ read: Bool) async throws
  /// Öffnet eine Antwort auf diese Mail als sichtbaren Entwurf in Apple Mail. Sendet nie.
  func openReplyDraft(id: String) async throws
  func setFlagged(id: String, _ flagged: Bool) async throws
  /// Verschiebt die Mail in den Archiv-Ordner des Kontos.
  func archive(id: String) async throws
  /// Verschiebt die Mail in den Papierkorb (kein endgültiges Löschen).
  func trash(id: String) async throws
  /// Öffnet einen neuen Entwurf sichtbar in Apple Mail. Sendet nie (auch nicht bei leerem Empfänger).
  func openNewDraft(_ draft: MailDraft) async throws
  /// Antwort (mit `replyToId`, im Thread) oder neue Mail.
  func send(_ draft: MailDraft) async throws
}

/// Fehler von Apple Mail mit deutschen Meldungen für die Oberfläche.
public enum MailError: Error, LocalizedError, Equatable {
  /// Die Automations-Freigabe für Mail fehlt (osascript -1743).
  case accessDenied
  /// Apple Mail hat kein Konto.
  case notConfigured
  case notFound
  /// Sonstiger Fehler; der Text ist bereits lesbar.
  case scriptFailed(String)
  case timeout

  public var errorDescription: String? {
    switch self {
    case .accessDenied:
      return "Lumi darf Apple Mail nicht steuern. Systemeinstellungen → Datenschutz & Sicherheit → Automation → Lumi → Mail."
    case .notConfigured:
      return "In Apple Mail ist kein Konto eingerichtet."
    case .notFound:
      return "Mail nicht gefunden."
    case .scriptFailed(let message):
      return message.isEmpty ? "Apple Mail konnte die Aktion nicht ausführen." : message
    case .timeout:
      return "Apple Mail hat zu lange gebraucht und wurde abgebrochen."
    }
  }
}
