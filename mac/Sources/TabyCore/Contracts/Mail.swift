// VERTRAG (nur Orchestrator ändert). Paket 5: Mail über die Apple-Mail-App
// und Meldungen aus Claude Code.
//
// Sicherheitsregeln (docs/decisions/0007-mail.md):
// - Zugriff nur über Apple Mail (AppleScript), kein eigenes Passwort.
// - Mail-Inhalte werden nicht in Tabys Datenbank kopiert; nur die Liste
//   (Absender, Betreff, Datum) liegt im Speicher, solange Lumi läuft.
// - `mailLocalOnly`: Mail-Inhalte gehen nur an Apple Intelligence auf dem Mac,
//   nie an ein Cloud-Modell; die Mail-Werkzeuge stehen dem Cloud-Modell dann
//   nicht zur Verfügung.
// - Senden, Löschen, Verschieben durch das Modell nur nach Bestätigung;
//   Text aus Mails ist Material, nie Anweisung. Keine Links/Anhänge öffnen.
import Foundation

/// Grobe Einordnung im Code (Absender/Betreff-Regeln, kein Modell).
public enum MailCategory: String, Codable, Sendable, CaseIterable {
  /// Von echten Personen, markiert, oder mit Frist-/Rechnungs-Wörtern.
  case important
  case normal
  /// Newsletter, Werbung, automatische Benachrichtigungen.
  case newsletter
}

public struct MailMessage: Codable, Equatable, Identifiable, Sendable {
  /// Stabile Kennung: Message-ID-Header von Apple Mail.
  public var id: String
  /// Name, falls bekannt, sonst Adresse.
  public var senderName: String
  public var senderAddress: String
  public var subject: String
  /// Empfangen, lokal "YYYY-MM-DDTHH:mm".
  public var date: String
  public var read: Bool
  public var flagged: Bool
  public var account: String
  public var mailbox: String
  public var category: MailCategory
  public init(id: String, senderName: String, senderAddress: String, subject: String, date: String,
              read: Bool = false, flagged: Bool = false, account: String = "", mailbox: String = "INBOX",
              category: MailCategory = .normal) {
    self.id = id; self.senderName = senderName; self.senderAddress = senderAddress; self.subject = subject
    self.date = date; self.read = read; self.flagged = flagged; self.account = account; self.mailbox = mailbox
    self.category = category
  }
}

/// Posteingang-Überblick (nur Kopfzeilen, kein Inhalt).
public struct MailOverview: Codable, Equatable, Sendable {
  /// Neueste zuerst, höchstens 40 der letzten 7 Tage.
  public var messages: [MailMessage]
  public var unread: Int
  /// Zeitpunkt des Abrufs, lokal.
  public var fetchedAt: String?
  /// Deutsche Fehlermeldung (Mail nicht eingerichtet, keine Freigabe, …).
  public var error: String?
  /// true, wenn die Automations-Freigabe für Mail fehlt (Knopf „Systemeinstellungen öffnen“).
  public var accessDenied: Bool
  public init(messages: [MailMessage] = [], unread: Int = 0, fetchedAt: String? = nil, error: String? = nil,
              accessDenied: Bool = false) {
    self.messages = messages; self.unread = unread; self.fetchedAt = fetchedAt; self.error = error
    self.accessDenied = accessDenied
  }
}

/// Mail zum Senden (neu oder Antwort). Wird dem Nutzer immer erst gezeigt.
public struct MailDraft: Codable, Equatable, Sendable {
  /// Antwort auf diese Mail (nil = neue Mail).
  public var replyToId: String?
  public var to: [String]
  public var subject: String
  public var body: String
  public init(replyToId: String? = nil, to: [String], subject: String, body: String) {
    self.replyToId = replyToId; self.to = to; self.subject = subject; self.body = body
  }
}

/// Meldung aus Claude Code (Hooks `Notification` und `Stop`).
public struct ClaudeNotice: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// Claude wartet auf deine Eingabe oder Freigabe.
    case needsInput
    /// Claude ist mit der Aufgabe fertig.
    case finished
  }
  public var kind: Kind
  /// Text von Claude Code (bei needsInput), sonst leer.
  public var message: String
  /// Projektordner (letzter Teil von cwd), z. B. "Lumi".
  public var project: String
  public init(kind: Kind, message: String = "", project: String = "") {
    self.kind = kind; self.message = message; self.project = project
  }
}
