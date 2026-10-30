// VERTRAG (nur Orchestrator ändert). Paket 12: Schnittstelle, die jeder Chat-Dienst
// erfüllt. CoreServices hält je Konto einen Connector, speichert Konten (ohne
// Geheimnis) in SQLite und das Geheimnis im Schlüsselbund; der Connector selbst
// speichert nichts dauerhaft außer seinem eigenen Sitzungsordner (falls nötig).
import Foundation

public protocol MessengerConnector: AnyObject, Sendable {
  var service: MessengerService { get }
  /// Erste Anmeldung. Liefert das Konto (ohne Geheimnis) und das zu speichernde
  /// Geheimnis (z. B. Zugriffstoken statt Passwort), das CoreServices in den
  /// Schlüsselbund legt.
  func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String)
  /// Sitzung nach App-Start mit dem gespeicherten Geheimnis wiederherstellen.
  func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount
  /// Verschlüsselung entsperren (nur Element/Matrix; andere: no-op).
  func unlock(recoveryKey: String) async throws
  /// Unterhaltungen des Kontos; `id` = "<accountId>|<raum-id>".
  func conversations() async throws -> [MessengerConversation]
  /// Letzte Nachrichten (älteste zuerst); `roomId` = Teil nach "|".
  func messages(roomId: String, limit: Int) async throws -> [MessengerMessage]
  func send(roomId: String, text: String) async throws
  /// Antwort auf eine Nachricht; Dienste ohne Threads senden normal.
  func send(roomId: String, text: String, replyTo: String?) async throws
  func markRead(roomId: String) async throws
  func logout() async
}

extension MessengerConnector {
  public func send(roomId: String, text: String, replyTo: String?) async throws {
    try await send(roomId: roomId, text: text)
  }
}
