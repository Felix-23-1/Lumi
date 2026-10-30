// Paket 12 gegen den echten Kern: iMessage verbinden/trennen, Routing, Hinweise
// bei neuen Nachrichten, Wiederherstellen nach Neustart. Chat-Datenbank und
// Lumi-Speicher sind Temp-Dateien; AppleScript läuft als Attrappe.
import Foundation

enum PackageTwelveChecks {
  final class EventLog {
    var events: [AppEvent] = []
    var flashes: [TabyNotification] {
      events.compactMap { if case .flash(let n) = $0 { return n }; return nil }
    }
  }

  @MainActor static func rig(chatDb: String, storePath: String? = nil, runner: ScriptRecorder? = nil) throws
    -> (CoreServices, EventLog)
  {
    var opts = CoreServices.Options(
      databasePath: storePath, socketPath: nil, clock: ControllableClock("2026-10-14T09:00"),
      keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), session: .shared, plannerInterval: nil,
      calendarSecrets: { _ in InMemoryApiKeyStore() }, notionOAuthClientSecrets: { InMemoryApiKeyStore() })
    opts.microsoftRefreshStore = InMemoryApiKeyStore()
    opts.messengerChatDbPath = chatDb
    opts.messengerScriptRunner = runner?.run
    opts.messengerPollInterval = nil
    let svc = try CoreServices(options: opts)
    let log = EventLog()
    svc.subscribe { log.events.append($0) }
    return (svc, log)
  }

  static func tempPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("taby-\(name)-\(UUID().uuidString).sqlite").path
  }

  static let chat1 = "iMessage;-;+491701234567"

  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration Paket 12", [
      CheckCase("Chat: iMessage verbinden speichert Konto und schaltet Nachrichten ein") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let (svc, log) = try rig(chatDb: chatDb)
        let r = await svc.connectMessenger(MessengerLogin(service: .imessage))
        let account = try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen")
        let state = await svc.state()
        try expectEqual(state.messengerAccounts.map(\.id), [account.id])
        try expect(state.settings.messengerEnabled, "Nachrichten-Reiter muss an sein")
        try expectEqual(state.messengerConversations.count, 2)
        try expect(log.events.contains(.stateChanged))
        let again = await svc.connectMessenger(MessengerLogin(service: .imessage))
        try expect(!again.isOk, "zweites iMessage-Konto wird abgewiesen")
      },

      CheckCase("Chat: Trennen entfernt Konto und schaltet den Reiter aus") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let (svc, _) = try rig(chatDb: chatDb)
        let connected = await svc.connectMessenger(MessengerLogin(service: .imessage))
        let account = try expectNotNil(connected.value)
        await svc.disconnectMessenger(account.id)
        let state = await svc.state()
        try expect(state.messengerAccounts.isEmpty && state.messengerConversations.isEmpty)
        try expect(!state.settings.messengerEnabled, "ohne Konto kein Reiter")
      },

      CheckCase("Chat: Nicht unterstützte Dienste melden 'noch nicht verfügbar'") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let (svc, _) = try rig(chatDb: chatDb)
        let r = await svc.connectMessenger(MessengerLogin(service: .teams))
        try expectEqual(r.errorMessage, "Erst bei Microsoft anmelden: Verbindungen → Microsoft.")
      },

      CheckCase("Chat: Nachrichten lesen, senden und Lesestand über das Konto-Präfix") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let runner = ScriptRecorder(status: 0)
        let (svc, _) = try rig(chatDb: chatDb, runner: runner)
        let connected = await svc.connectMessenger(MessengerLogin(service: .imessage))
        let convId = "\(try expectNotNil(connected.value).id)|\(chat1)"
        let listed = await svc.messengerMessages(convId, limit: 10)
        try expectEqual(try expectNotNil(listed.value).count, 3)
        let unknown = await svc.messengerMessages("fremd|\(chat1)", limit: 10)
        try expect(!unknown.isOk, "unbekanntes Konto")
        let sent = await svc.sendMessengerMessage(convId, text: "Ok")
        try expect(sent.isOk, sent.errorMessage ?? "")
        try expect(runner.scripts.last?.contains("to chat id \"\(chat1)\"") == true, "Senden geht an den Chat")
        let empty = await svc.sendMessengerMessage(convId, text: "  ")
        try expect(!empty.isOk, "leere Nachricht wird abgewiesen")
        await svc.markMessengerRead(convId)
        let state = await svc.state()
        let unread = state.messengerConversations.first { $0.id == convId }?.unread
        try expectEqual(unread, 0, "nach Lesen keine ungelesenen mehr")
      },

      CheckCase("Chat: Takt meldet genau eine neue eingehende Nachricht, eigene nicht") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let (svc, log) = try rig(chatDb: chatDb)
        _ = await svc.connectMessenger(MessengerLogin(service: .imessage))
        try expect(log.flashes.isEmpty, "bestehende Nachrichten melden nichts")

        try MessengerChecks.execRaw(chatDb, """
          INSERT INTO message VALUES (5, 'm5', 'Neu da', NULL, 4000000000000000, 0, 0, 1);
          INSERT INTO chat_message_join VALUES (1, 5);
          """)
        await svc.messenger.poll()
        try expectEqual(log.flashes, [TabyNotification(title: "+491701234567", body: "Neu da")])
        await svc.messenger.poll()
        try expectEqual(log.flashes.count, 1, "kein doppelter Hinweis")

        try MessengerChecks.execRaw(chatDb, """
          INSERT INTO message VALUES (6, 'm6', 'Eigene', NULL, 5000000000000000, 1, 1, 0);
          INSERT INTO chat_message_join VALUES (1, 6);
          """)
        await svc.messenger.poll()
        try expectEqual(log.flashes.count, 1, "eigene Nachrichten melden nichts")
      },

      CheckCase("Chat: gleichzeitige Abfragen überlappen nicht (ein Hinweis je Nachricht)") {
        let chatDb = try MessengerChecks.makeChatDb()
        defer { try? FileManager.default.removeItem(atPath: chatDb) }
        let (svc, log) = try rig(chatDb: chatDb)
        _ = await svc.connectMessenger(MessengerLogin(service: .imessage))
        try MessengerChecks.execRaw(chatDb, """
          INSERT INTO message VALUES (5, 'm5', 'Neu da', NULL, 4000000000000000, 0, 0, 1);
          INSERT INTO chat_message_join VALUES (1, 5);
          """)
        async let a: Void = svc.messenger.poll()
        async let b: Void = svc.messenger.poll()
        async let c: Void = svc.messenger.poll()
        _ = await (a, b, c)
        try expectEqual(log.flashes.count, 1)
      },

      CheckCase("Chat: Konto überlebt einen Neustart") {
        let chatDb = try MessengerChecks.makeChatDb()
        let store = tempPath("store")
        defer {
          try? FileManager.default.removeItem(atPath: chatDb)
          try? FileManager.default.removeItem(atPath: store)
        }
        let (first, _) = try rig(chatDb: chatDb, storePath: store)
        let connected = await first.connectMessenger(MessengerLogin(service: .imessage))
        _ = try expectNotNil(connected.value)
        first.shutdown()

        let (second, _) = try rig(chatDb: chatDb, storePath: store)
        await second.messenger.restoreAll()
        await second.messenger.poll()
        let state = await second.state()
        try expectEqual(state.messengerAccounts.count, 1)
        try expect(state.messengerAccounts.first?.status == .connected, "Wiederherstellung ohne Fehler")
        try expectEqual(state.messengerConversations.count, 2)
        second.shutdown()
      },

      CheckCase("Chat: Element gesperrt → nach Entsperren und im Takt verbunden") {
        let (svc, log) = try rig(chatDb: tempPath("chat"))
        let fake = LockedConnector()
        svc.messenger.connectorFactory = { _ in fake }
        let r = await svc.connectMessenger(MessengerLogin(service: .matrix, server: "m.org", user: "@a:m.org", secret: "pw"))
        let account = try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen")
        var status = await svc.state().messengerAccounts.first?.status
        try expectEqual(status, .locked)
        log.events.removeAll()
        _ = await svc.unlockMessenger(account.id, recoveryKey: "key")
        status = await svc.state().messengerAccounts.first?.status
        try expectEqual(status, .connected, "Entsperren bleibt sichtbar")
        try expect(log.events.contains(.stateChanged))
        fake.reported = .locked
        await svc.messenger.poll()
        status = await svc.state().messengerAccounts.first?.status
        try expectEqual(status, .locked, "Takt übernimmt späteren Stand")
      },

      CheckCase("Element: Sicherheitsschlüssel mit „MAC check“ erklärt die Sicherung statt nur „passt nicht“") {
        let text = MatrixStatusMap.keyMismatchText(detail: "The MAC check for the secret storage key failed")
        try expect(text.contains("gehört nicht zur aktuellen Sicherung"), "Hinweis auf die Sicherung")
        try expect(text.hasSuffix("(The MAC check for the secret storage key failed)"), "SDK-Detail in Klammern")
        try expectEqual(MatrixStatusMap.keyMismatchText(detail: "Invalid key"), "Sicherheitsschlüssel passt nicht. (Invalid key)")
      },

      CheckCase("Element: SAS-Emojis kommen auf Deutsch, Unbekanntes bleibt") {
        try expectEqual(MatrixVerificationText.emoji(symbol: "🐶", name: "Dog"), MessengerEmoji(symbol: "🐶", name: "Hund"))
        try expectEqual(MatrixVerificationText.emoji(symbol: "🎁", name: "Gift").name, "Geschenk")
        try expectEqual(MatrixVerificationText.emoji(symbol: "?", name: "Unknown Thing").name, "Unknown Thing")
        try expectEqual(MatrixVerificationText.emoji(symbol: "📌", name: "Pin").name, "Stecknadel")
        try expectEqual(MatrixVerificationText.emoji(symbol: "👍", name: "Thumbs Up").name, "Daumen hoch")
      },

      CheckCase("Element: Bestätigung mit Emojis → Zustimmung → verbunden") {
        let (svc, _) = try rig(chatDb: tempPath("chat"))
        let fake = VerifyingConnector()
        svc.messenger.connectorFactory = { _ in fake }
        let r = await svc.connectMessenger(MessengerLogin(service: .matrix, server: "m.org", user: "@a:m.org", secret: "pw"))
        let account = try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen")
        let started = await svc.startMessengerVerification(account.id)
        try expect(started.isOk, started.errorMessage ?? "Start fehlgeschlagen")
        var v = await svc.state().messengerVerification
        try expectEqual(v?.phase, .showEmojis)
        try expectEqual(v?.emojis.count, 2)
        _ = await svc.answerMessengerVerification(account.id, matches: true)
        v = await svc.state().messengerVerification
        try expectEqual(v?.phase, .done)
        let accounts = await svc.state().messengerAccounts
        try expectEqual(accounts.first?.status, .connected)
      },

      CheckCase("Element: Emojis stimmen nicht → abgebrochen, Konto bleibt gesperrt") {
        let (svc, _) = try rig(chatDb: tempPath("chat"))
        let fake = VerifyingConnector()
        svc.messenger.connectorFactory = { _ in fake }
        let r = await svc.connectMessenger(MessengerLogin(service: .matrix, server: "m.org", user: "@a:m.org", secret: "pw"))
        let account = try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen")
        _ = await svc.startMessengerVerification(account.id)
        _ = await svc.answerMessengerVerification(account.id, matches: false)
        let state = await svc.state()
        try expectEqual(state.messengerVerification?.phase, .cancelled)
        try expectEqual(state.messengerAccounts.first?.status, .locked)
      },

      CheckCase("Element: Abbrechen räumt die Bestätigung; ohne Element-Konto → Fehler") {
        let (svc, _) = try rig(chatDb: tempPath("chat"))
        let fake = VerifyingConnector()
        svc.messenger.connectorFactory = { _ in fake }
        let r = await svc.connectMessenger(MessengerLogin(service: .matrix, server: "m.org", user: "@a:m.org", secret: "pw"))
        let account = try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen")
        _ = await svc.startMessengerVerification(account.id)
        await svc.cancelMessengerVerification(account.id)
        let afterCancel = await svc.state().messengerVerification
        try expectEqual(afterCancel, nil)
        let unknown = await svc.startMessengerVerification("gibt-es-nicht")
        try expect(!unknown.isOk, "Konto ohne Bestätigung meldet Fehler")
      },
    ])
  }

  /// Element-Bestätigung: meldet Emojis sofort; „Stimmt überein“ schaltet das Konto frei.
  final class VerifyingConnector: MessengerConnector, MessengerVerifying, MessengerStatusReporting, @unchecked Sendable {
    let service: MessengerService = .matrix
    private var accountId = ""
    private var status: MessengerStatus = .locked
    private var report: (@Sendable (MessengerVerification) -> Void)?
    func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
      self.accountId = accountId
      return (MessengerAccount(id: accountId, service: .matrix, user: login.user, status: .locked), "")
    }
    func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount { account }
    func unlock(recoveryKey: String) async throws {}
    func conversations() async throws -> [MessengerConversation] { [] }
    func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] { [] }
    func send(roomId: String, text: String) async throws {}
    func markRead(roomId: String) async throws {}
    func logout() async {}
    func currentStatus() async -> MessengerStatus? { status }
    func startVerification(report: @escaping @Sendable (MessengerVerification) -> Void) async throws {
      self.report = report
      report(MessengerVerification(accountId: accountId, phase: .showEmojis, emojis: [
        MessengerEmoji(symbol: "🐶", name: "Hund"), MessengerEmoji(symbol: "🎁", name: "Geschenk"),
      ]))
    }
    func answerVerification(matches: Bool) async throws {
      if matches {
        status = .connected
      } else {
        report?(MessengerVerification(accountId: accountId, phase: .cancelled, message: "abgelehnt"))
      }
    }
    func cancelVerification() async {}
  }

  /// Element-Attrappe: meldet sich gesperrt an; `reported` ist der Stand für den Takt.
  final class LockedConnector: MessengerConnector, MessengerStatusReporting, @unchecked Sendable {
    let service: MessengerService = .matrix
    var reported: MessengerStatus?
    func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
      (MessengerAccount(id: accountId, service: .matrix, user: login.user, status: .locked), "")
    }
    func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount { account }
    func unlock(recoveryKey: String) async throws {}
    func conversations() async throws -> [MessengerConversation] { [] }
    func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] { [] }
    func send(roomId: String, text: String) async throws {}
    func markRead(roomId: String) async throws {}
    func logout() async {}
    func currentStatus() async -> MessengerStatus? { reported }
  }
}
