// Paket 12 im Integrator: Chat-Dienste ("Nachrichten"). Die Logik liegt im
// MessengerHub (Messenger/); hier nur die Verbindung zu CoreServices.
import Foundation

extension CoreServices {
  public func connectMessenger(_ login: MessengerLogin) async -> ToolResult<MessengerAccount> {
    await messenger.connect(login)
  }

  public func unlockMessenger(_ accountId: String, recoveryKey: String) async -> ToolResult<Empty> {
    await messenger.unlock(accountId, recoveryKey: recoveryKey)
  }

  public func disconnectMessenger(_ accountId: String) async {
    await messenger.disconnect(accountId)
  }

  public func messengerMessages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]> {
    await messenger.messages(conversationId, limit: limit)
  }

  public func sendMessengerMessage(_ conversationId: String, text: String, replyTo: String?) async -> ToolResult<Empty> {
    await messenger.send(conversationId, text: text, replyTo: replyTo)
  }

  public func markMessengerRead(_ conversationId: String) async {
    await messenger.markRead(conversationId)
  }
}
