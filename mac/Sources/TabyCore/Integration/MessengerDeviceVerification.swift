// Paket 12: Bestätigung von Lumi durch ein anderes eigenes Gerät (Element: Emoji-Vergleich).
// Die Logik liegt im MessengerHub (Messenger/); hier nur die Verbindung zu CoreServices.
import Foundation

extension CoreServices {
  public func startMessengerVerification(_ accountId: String) async -> ToolResult<Empty> {
    await messenger.startVerification(accountId)
  }
  public func answerMessengerVerification(_ accountId: String, matches: Bool) async -> ToolResult<Empty> {
    await messenger.answerVerification(accountId, matches: matches)
  }
  public func cancelMessengerVerification(_ accountId: String) async {
    await messenger.cancelVerification(accountId)
  }
}
