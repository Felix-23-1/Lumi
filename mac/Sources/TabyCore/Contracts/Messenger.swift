// VERTRAG (nur Orchestrator ändert). Paket 12: Chat-Dienste ("Nachrichten").
// Mehrere Chats (iMessage, Slack, Teams, später Element/Matrix) in einem Reiter. Zugangsdaten nur im Schlüsselbund, nie in
// SQLite, Logs oder `AppState`.
import Foundation

public enum MessengerService: String, Codable, CaseIterable, Sendable {
  case matrix, slack, teams, imessage

  public var title: String {
    switch self {
    case .matrix: "Element / Matrix"
    case .slack: "Slack"
    case .teams: "Microsoft Teams"
    case .imessage: "iMessage / SMS"
    }
  }

  /// SF-Symbol für Verbindungen und Unterhaltungen.
  public var symbol: String {
    switch self {
    case .matrix: "lock.shield"
    case .slack: "number"
    case .teams: "person.3"
    case .imessage: "message"
    }
  }

  /// Der Nutzer trägt die Server-Adresse selbst ein (selbst gehostete Dienste).
  public var needsServer: Bool { self == .matrix }
}

public enum MessengerStatus: Codable, Equatable, Sendable {
  case connected
  /// Angemeldet, aber verschlüsselte Chats noch gesperrt (Sicherheitsschlüssel fehlt).
  case locked
  case error(String)
}

/// Ein verbundenes Chat-Konto (ohne Geheimnisse).
public struct MessengerAccount: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var service: MessengerService
  /// Server-Adresse (leer bei Diensten ohne eigenen Server).
  public var server: String
  /// Anzeigename bzw. Benutzer-ID.
  public var user: String
  public var status: MessengerStatus
  public init(id: String, service: MessengerService, server: String = "", user: String, status: MessengerStatus = .connected) {
    self.id = id; self.service = service; self.server = server; self.user = user; self.status = status
  }
}

/// Eine Unterhaltung (Raum, Kanal, Direktnachricht) eines Kontos.
public struct MessengerConversation: Codable, Equatable, Identifiable, Sendable {
  /// Eindeutig über alle Konten: "<accountId>|<raum-id>".
  public var id: String
  public var accountId: String
  public var title: String
  public var unread: Int
  public var lastText: String?
  /// Lokale zonenlose Zeit der letzten Nachricht.
  public var lastAt: String?
  public var isDirect: Bool
  public init(id: String, accountId: String, title: String, unread: Int = 0, lastText: String? = nil,
              lastAt: String? = nil, isDirect: Bool = false) {
    self.id = id; self.accountId = accountId; self.title = title; self.unread = unread
    self.lastText = lastText; self.lastAt = lastAt; self.isDirect = isDirect
  }
}

public struct MessengerMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var conversationId: String
  public var sender: String
  public var text: String
  /// Lokale zonenlose Zeit.
  public var at: String
  public var mine: Bool
  /// Wurzel des Threads, wenn die Nachricht in einem Thread steht (Element); sonst nil.
  public var threadRoot: String?
  public init(id: String, conversationId: String, sender: String, text: String, at: String, mine: Bool = false,
              threadRoot: String? = nil) {
    self.id = id; self.conversationId = conversationId; self.sender = sender; self.text = text; self.at = at; self.mine = mine
    self.threadRoot = threadRoot
  }
}

/// Anmeldedaten für `connectMessenger` – `secret` (Passwort/Token) geht direkt in den
/// Schlüsselbund und wird nirgends gespeichert oder geloggt.
public struct MessengerLogin: Sendable {
  public var service: MessengerService
  public var server: String
  public var user: String
  public var secret: String
  public init(service: MessengerService, server: String = "", user: String = "", secret: String = "") {
    self.service = service; self.server = server; self.user = user; self.secret = secret
  }
}

/// Paket 12: Bestätigung von Lumi durch ein anderes eigenes Gerät (Element: Emoji-Vergleich),
/// statt den Sicherheitsschlüssel einzugeben.
public struct MessengerVerification: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    /// Anfrage gesendet, das andere Gerät muss sie annehmen.
    case waitingForOther
    /// Emojis anzeigen: Nutzer vergleicht mit dem anderen Gerät.
    case showEmojis
    /// Bestätigt, Lumi wartet auf den Abschluss.
    case confirming
    case done
    case cancelled
    case failed
  }
  public var accountId: String
  public var phase: Phase
  public var emojis: [MessengerEmoji]
  /// Hinweis/Fehlertext (deutsch), optional.
  public var message: String?
  public init(accountId: String, phase: Phase, emojis: [MessengerEmoji] = [], message: String? = nil) {
    self.accountId = accountId; self.phase = phase; self.emojis = emojis; self.message = message
  }
}

public struct MessengerEmoji: Codable, Equatable, Sendable {
  public var symbol: String
  public var name: String
  public init(symbol: String, name: String) { self.symbol = symbol; self.name = name }
}
