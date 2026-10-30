// Prüfungen Paket 12: iMessage-Connector gegen eine echte SQLite-Datei mit dem
// Schema-Ausschnitt aus chat.db. Kein echtes Messages-Konto, kein AppleScript.
import Foundation
import SQLite3

enum MessengerChecks {
  static let suite = CheckSuite("Messenger", SlackChecks.cases + AutoStatusChecks.cases + MicrosoftTeamsChecks.cases + [
    CheckCase("Antwort: Dienste ohne Threads senden bei replyTo ganz normal; Thread-Wurzel ist optional") {
      let c = HubFake()
      try await c.send(roomId: "C1", text: "Ok", replyTo: "$e1")
      try expectEqual(c.sent, ["Ok"])
      try expectEqual(MessengerMessage(id: "1", conversationId: "a|r", sender: "x", text: "t", at: "").threadRoot, nil)
    },
    CheckCase("Takt: 60 s bei Nutzung oder neuen Nachrichten, sonst 300 s") {
      let now = ControllableClock("2026-10-14T10:00").now()
      let ago = { (s: TimeInterval) in now.addingTimeInterval(-s) }
      func delay(_ use: Date?, _ msg: Date?) -> TimeInterval {
        MessengerPollPolicy.delay(base: 60, now: now, lastIslandUse: use, lastNewMessage: msg)
      }
      try expectEqual(delay(nil, nil), 300)
      try expectEqual(delay(ago(299), nil), 60)
      try expectEqual(delay(ago(301), nil), 300)
      try expectEqual(delay(nil, ago(60)), 60)
      try expectEqual(delay(nil, ago(301)), 300)
    },
    CheckCase("Takt: Fehler-Wartezeit verdoppelt sich je Konto, höchstens 5 Minuten") {
      try expectEqual(MessengerPollPolicy.backoff(base: 20, errorStreak: 1), 40)
      try expectEqual(MessengerPollPolicy.backoff(base: 20, errorStreak: 2), 80)
      try expectEqual(MessengerPollPolicy.backoff(base: 20, errorStreak: 4), 300, "höchstens 5 Minuten")
      try expectEqual(MessengerPollPolicy.backoff(base: 20, errorStreak: 9), 300)
    },
    CheckCase("Takt: ein fehlerhaftes Konto wartet, die anderen bleiben frei") {
      let now = ControllableClock("2026-10-14T10:00").now()
      var b = AccountBackoff()
      try expect(!b.isWaiting("slack", now: now), "ohne Fehler kein Warten")
      b.failed("slack", now: now, base: 20)
      try expect(b.isWaiting("slack", now: now.addingTimeInterval(39)), "nach 39 s noch Wartezeit")
      try expect(!b.isWaiting("slack", now: now.addingTimeInterval(40)), "nach 40 s wieder dran")
      try expect(!b.isWaiting("imessage", now: now), "anderes Konto unberührt")
      b.failed("slack", now: now, base: 20)
      try expectEqual(b.streaks["slack"], 2)
      try expect(b.isWaiting("slack", now: now.addingTimeInterval(79)))
      b.clear("slack")
      try expect(!b.isWaiting("slack", now: now), "nach Erfolg zurück im Takt")
      try expectEqual(b.streaks["slack"], nil)
    },
    CheckCase("Takt: der Hub nimmt Nutzung der Insel an und fällt danach zurück") {
      try await MainActor.run { try MessengerChecks.hubPollTakt() }
    },
    CheckCase("iMessage: Unterhaltungen mit Titel, letzter Nachricht und ungelesen") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let c = connector(path: path)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      let list = try await c.conversations()
      try expectEqual(list.map(\.title), ["+491701234567", "Familie"])
      try expectEqual(list[0].lastText, "Hallo")
      try expectEqual(list[0].lastAt, LocalTime.format(Date(timeIntervalSinceReferenceDate: 3_000_000)))
      try expectEqual(list[0].unread, 2, "m1 und m3 sind eingehend und ungelesen")
      try expectEqual(list[1].unread, 0)
      try expect(list[0].isDirect && !list[1].isDirect)
    },

    CheckCase("iMessage: Lese-Marker zählt nur neuere eingehende Nachrichten") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let markers = MarkerBox(values: ["acc|iMessage;-;+491701234567": 1])
      let c = connector(path: path, markers: markers.markers)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      let list = try await c.conversations()
      try expectEqual(list[0].unread, 1, "nur m3 liegt nach dem Marker")
    },

    CheckCase("iMessage: offene Verbindung sieht neue Nachrichten bei jedem Takt") {
      let path = try makeChatDb()
      defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
      let c = connector(path: path)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      let first = try await c.conversations().first
      try expectEqual(first?.unread, 2)
      var writer: OpaquePointer?
      guard sqlite3_open(path, &writer) == SQLITE_OK, let w = writer else { throw fail("Schreiber") }
      defer { sqlite3_close(w) }
      try expectEqual(sqlite3_exec(w, """
        INSERT INTO message VALUES (6, 'm6', 'Noch eine', NULL, 4000000000000000, 0, 0, 1);
        INSERT INTO chat_message_join VALUES (1, 6);
        """, nil, nil, nil), SQLITE_OK)
      let second = try await c.conversations().first
      try expectEqual(second?.unread, 3, "zweiter Takt liest die Änderung")
    },
    CheckCase("iMessage: Nachrichten älteste zuerst, eigene markiert, Text aus attributedBody") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let c = connector(path: path)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      let msgs = try await c.messages(roomId: "iMessage;-;+491701234567", limit: 10)
      try expectEqual(msgs.map(\.text), ["Hallo von Anna", "Hi zurück", "Hallo"])
      try expectEqual(msgs.map(\.sender), ["+491701234567", "Ich", "+491701234567"])
      try expectEqual(msgs.map(\.mine), [false, true, false])
      try expectEqual(msgs[0].conversationId, "acc|iMessage;-;+491701234567")
      let last = try await c.messages(roomId: "iMessage;-;+491701234567", limit: 1)
      try expectEqual(last.map(\.text), ["Hallo"], "Limit nimmt die neuesten")
    },

    CheckCase("iMessage: Lesen markiert den Stand bis zur neuesten ROWID") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let markers = MarkerBox(values: [:])
      let c = connector(path: path, markers: markers.markers)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      try await c.markRead(roomId: "iMessage;-;+491701234567")
      try expectEqual(markers.values["acc|iMessage;-;+491701234567"], 3)
    },

    CheckCase("iMessage: fehlende Leserechte geben den Freigabe-Hinweis, fehlende Datei den echten Fehler") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
      do {
        _ = try await connector(path: path).login(MessengerLogin(service: .imessage), accountId: "acc")
        throw fail("Anmeldung ohne Leserecht sollte scheitern")
      } catch let e as MessengerFailure {
        try expect(e.message.contains("Festplattenvollzugriff"), e.message)
      }
      do {
        _ = try await connector(path: "/nicht/vorhanden/chat.db").login(MessengerLogin(service: .imessage), accountId: "acc")
        throw fail("Anmeldung ohne Datenbank sollte scheitern")
      } catch let e as MessengerFailure {
        try expect(!e.message.contains("Festplattenvollzugriff") && e.message.contains("nicht gelesen"), e.message)
      }
    },

    CheckCase("iMessage: WAL-Datenbank – neue Nachrichten eines offenen Schreibers sind sichtbar") {
      let path = try makeChatDb()
      defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
      var writer: OpaquePointer?
      guard sqlite3_open(path, &writer) == SQLITE_OK, let w = writer else { throw fail("Schreiber") }
      defer { sqlite3_close(w) }
      try expectEqual(sqlite3_exec(w, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK)
      let c = connector(path: path)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      try expectEqual(sqlite3_exec(w, """
        INSERT INTO message VALUES (5, 'm5', 'Ganz neu', NULL, 4000000000000000, 0, 0, 1);
        INSERT INTO chat_message_join VALUES (1, 5);
        """, nil, nil, nil), SQLITE_OK)
      try expect(FileManager.default.fileExists(atPath: path + "-wal"))
      let list = try await c.conversations()
      try expectEqual(list.first?.lastText, "Ganz neu", "Lesen muss die WAL-Datei einbeziehen")
      try expectEqual(list.first?.unread, 3)
    },

    CheckCase("iMessage: attributedBody – kaputte Daten stürzen nie ab, Länge 0x81 wird gelesen") {
      try expectEqual(IMessageConnector.messageText(nil, Data([0x00, 0x01])), "(Anhang)")
      let marker = Array("NSString".utf8)
      for blob: [UInt8] in [marker, marker + [0x01, 0x2B], marker + [0x2B, 0x81, 0x05], marker + [0x2B, 0x82, 0xFF, 0xFF, 0xFF, 0x7F, 0x41],
                            marker + [0x2B, 0x05, 0x41], marker + [0x2B, 0x90, 0x41], marker + [0x2B, 0x02, 0xFF, 0xFE]] {
        try expectEqual(IMessageConnector.messageText(nil, Data(blob)), "(Anhang)", "\(blob)")
      }
      let long = String(repeating: "ä", count: 100)  // 200 Bytes → 0x81 + UInt16
      let archived = NSArchiver.archivedData(withRootObject: NSAttributedString(string: long))
      try expectEqual(IMessageConnector.messageText(nil, archived), long)
      try expectEqual(IMessageConnector.typedStreamText(Data(marker + [0x01, 0x2B, 0x81, 0x02, 0x00, 0x48, 0x69])), "Hi")
    },

    CheckCase("iMessage: Datum in Nanosekunden und (alt) Sekunden seit 2001") {
      try expectEqual(IMessageConnector.localDate(3_000_000_000_000_000),
                      LocalTime.format(Date(timeIntervalSinceReferenceDate: 3_000_000)))
      try expectEqual(IMessageConnector.localDate(700_000_000), LocalTime.format(Date(timeIntervalSinceReferenceDate: 700_000_000)))
    },

    CheckCase("iMessage: AppleScript-Literal entschärft Zeilenumbrüche und Chat-Kennung") {
      let script = IMessageConnector.sendScript(text: "a\nb\" & do shell script \"x", chatGuid: "g\"\\")
      try expectEqual(script, #"tell application "Messages" to send "a\nb\" & do shell script \"x" to chat id "g\"\\""#)
    },

    CheckCase("iMessage: Senden baut das AppleScript mit escapten Zeichen") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let recorder = ScriptRecorder(status: 0)
      let c = connector(path: path, run: recorder.run)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      try await c.send(roomId: "iMessage;-;+49", text: #"Er sagt "Hi" \ ok"#)
      try expectEqual(recorder.scripts, [#"tell application "Messages" to send "Er sagt \"Hi\" \\ ok" to chat id "iMessage;-;+49""#])
    },

    CheckCase("iMessage: Senden ohne Automation-Freigabe gibt den deutschen Hinweis") {
      let path = try makeChatDb()
      defer { try? FileManager.default.removeItem(atPath: path) }
      let recorder = ScriptRecorder(status: 1, stderr: "execution error: Not authorized to send Apple events (-1743)")
      let c = connector(path: path, run: recorder.run)
      _ = try await c.login(MessengerLogin(service: .imessage), accountId: "acc")
      do {
        try await c.send(roomId: "iMessage;-;+49", text: "x")
        throw fail("Senden ohne Freigabe sollte scheitern")
      } catch let e as MessengerFailure {
        try expect(e.message.contains("Automation"), e.message)
      }
    },

    // Matrix-SDK-Brücke: nur prüfbar, wenn Vendor/MatrixSDK gebaut ist.
    CheckCase("Matrix SDK: Bibliothek gelinkt und FFI-Aufruf liefert eine Git-SHA") {
      #if TABY_MATRIX
      try expect(MatrixAvailability.isAvailable, "Matrix SDK ist gebaut, aber nicht verfügbar")
      #else
      try expect(!MatrixAvailability.isAvailable, "ohne Vendor darf nichts verfügbar sein")
      #endif
    },

    CheckCase("Matrix: Geheimnis wird als JSON ohne Passwort gespeichert und kommt unverändert zurück") {
      let secret = MatrixSecret(accessToken: "tok-1", refreshToken: nil, userId: "@felix:matrix.org",
                                deviceId: "DEV1", homeserverUrl: "https://matrix.org", oauthData: nil,
                                passphrase: "pp-abc")
      let json = try secret.json()
      try expect(json.contains("tok-1") && json.contains("pp-abc"), "Sitzung und Passphrase gehören ins Geheimnis")
      try expect(!json.lowercased().contains("passwort"), "kein Passwortfeld im Geheimnis")
      try expectEqual(try MatrixSecret.parse(json), secret)
      try await expectThrows("kaputtes JSON muss als Fehler kommen") { _ = try MatrixSecret.parse("{nicht json") }
    },

    CheckCase("Matrix: Speicher-Passphrase ist 64 Hex-Zeichen und jedes Mal neu") {
      let a = MatrixSecret.newPassphrase(), b = MatrixSecret.newPassphrase()
      try expectEqual(a.count, 64)
      try expect(a.allSatisfy { $0.isHexDigit } && a != b, "zufällig und hex")
    },

    CheckCase("Matrix: Server-Adresse normalisieren (Leerraum und / am Ende weg)") {
      try expectEqual(MatrixLoginInput.homeserver("  https://matrix.firma.de/ "), "https://matrix.firma.de")
      try expectEqual(MatrixLoginInput.homeserver("matrix.org"), "matrix.org")
      try expectEqual(MatrixLoginInput.homeserver("   "), "")
    },

    CheckCase("Matrix: vollständige Kennung @name:server erkennen") {
      try expect(MatrixLoginInput.isUserId("@felix:matrix.org"))
      try expect(!MatrixLoginInput.isUserId("felix"), "Kurzname ist keine Kennung")
      try expect(!MatrixLoginInput.isUserId("@felix"), "ohne Server")
      try expect(!MatrixLoginInput.isUserId("@:matrix.org"), "ohne Name")
      try expect(!MatrixLoginInput.isUserId("@a b:matrix.org"), "Leerzeichen")
      try expectEqual(MatrixLoginInput.user("  felix \n"), "felix")
    },

    CheckCase("Matrix: Sicherheitsschlüssel ohne Leerzeichen; Anmelden erst mit allen Feldern") {
      try expectEqual(MatrixLoginInput.recoveryKey("EsTc 1234 abcd\n5678"), "EsTc1234abcd5678")
      try expect(MatrixLoginInput.canSubmit(server: "matrix.org", user: "felix", password: "x"))
      try expect(!MatrixLoginInput.canSubmit(server: " ", user: "felix", password: "x"), "Server fehlt")
      try expect(!MatrixLoginInput.canSubmit(server: "matrix.org", user: "", password: "x"), "Benutzer fehlt")
      try expect(!MatrixLoginInput.canSubmit(server: "matrix.org", user: "felix", password: ""), "Passwort fehlt")
    },

    CheckCase("Matrix: Status – gesperrt nur, wenn der Schlüssel fehlt") {
      try expectEqual(MatrixStatusMap.status(keyMissing: false), .connected)
      try expectEqual(MatrixStatusMap.status(keyMissing: true), .locked)
      try expectEqual(MatrixStatusMap.wrongKeyText, "Sicherheitsschlüssel passt nicht.")
    },

    CheckCase("Matrix: Speicherort je Konto unter de.felix.taby/Matrix") {
      try expectEqual(MatrixStorage.root(accountId: "acc-1", base: "/x/Matrix"), "/x/Matrix/acc-1")
      try expect(MatrixStorage.base.hasSuffix("de.felix.taby/Matrix"))
    },
  ] + hubCases)

  /// Connector mit injizierter Datenbank, Markern (Standard: keine) und Skript-Start (Standard: keiner).
  static func connector(path: String, markers: MessengerReadMarkers? = nil,
                        run: (@Sendable (String) throws -> ProcessOutput)? = nil) -> IMessageConnector
  {
    IMessageConnector(chatDbPath: path,
                      readMarkers: markers ?? MessengerReadMarkers(get: { _ in nil }, set: { _, _ in }),
                      runScript: run ?? { _ in ProcessOutput(status: 0) })
  }

  /// Legt eine Datei mit dem Schema-Ausschnitt von chat.db und drei Chats/Nachrichten an.
  static func makeChatDb() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("taby-chat-\(UUID().uuidString).db").path
    let archived = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Hallo"))
    let hex = archived.map { String(format: "%02X", $0) }.joined()
    try execRaw(path, """
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, date INTEGER,
        is_from_me INTEGER, is_read INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      INSERT INTO handle VALUES (1, '+491701234567'), (2, 'anna@example.com');
      INSERT INTO chat VALUES (1, 'iMessage;-;+491701234567', '+491701234567', ''),
        (2, 'iMessage;+;chat123', 'chat123', 'Familie');
      INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
      INSERT INTO message VALUES
        (1, 'm1', 'Hallo von Anna', NULL, 1000000000000000, 0, 0, 1),
        (2, 'm2', 'Hi zurück', NULL, 2000000000000000, 1, 1, 0),
        (3, 'm3', NULL, X'\(hex)', 3000000000000000, 0, 0, 1),
        (4, 'm4', 'Gruß in die Runde', NULL, 2500000000000000, 0, 1, 2);
      INSERT INTO chat_message_join VALUES (1, 1), (1, 2), (1, 3), (2, 4);
      """)
    return path
  }

  static func execRaw(_ path: String, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else { throw fail("Testdatenbank nicht anlegbar") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw fail("Testdaten nicht schreibbar") }
  }
}

/// Lese-Marker im Speicher (Schlüssel = Unterhaltungs-Kennung).
final class MarkerBox: @unchecked Sendable {
  var values: [String: Int]
  init(values: [String: Int]) { self.values = values }
  var markers: MessengerReadMarkers {
    MessengerReadMarkers(get: { [self] in self.values[$0] }, set: { [self] in self.values[$0] = $1 })
  }
}

/// Connector für Hub-Prüfungen: zählt Abfragen und Lesen; Bestätigung meldet sofort die Emojis.
final class HubFake: MessengerConnector, MessengerVerifying, MessengerStatusReporting, @unchecked Sendable {
  let service: MessengerService = .slack
  private(set) var pollCount = 0
  private(set) var markedRead: [String] = []
  private(set) var sent: [String] = []
  /// Läuft beim Antworten auf den Emoji-Vergleich (z. B. um währenddessen abzubrechen).
  var onAnswer: (() async -> Void)?
  private var accountId = ""

  func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
    self.accountId = accountId
    return (MessengerAccount(id: accountId, service: .slack, user: "grace"), "xoxp-test")
  }
  func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount { account }
  func unlock(recoveryKey: String) async throws {}
  func conversations() async throws -> [MessengerConversation] {
    pollCount += 1
    return [MessengerConversation(id: "\(accountId)|C1", accountId: accountId, title: "#allgemein", unread: 1)]
  }
  func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] { [] }
  func send(roomId: String, text: String) async throws { sent.append(text) }
  func markRead(roomId: String) async throws { markedRead.append(roomId) }
  func logout() async {}
  func currentStatus() async -> MessengerStatus? { .connected }
  func startVerification(report: @escaping @Sendable (MessengerVerification) -> Void) async throws {
    report(MessengerVerification(accountId: accountId, phase: .showEmojis))
  }
  func answerVerification(matches: Bool) async throws { await onAnswer?() }
  func cancelVerification() async {}
}

extension MessengerChecks {
  @MainActor static func hubPollTakt() throws {
    let clock = ControllableClock("2026-10-14T10:00")
    let store = try Store.inMemory(clock: clock)
    let hub = MessengerHub(store: store, secrets: { _ in InMemoryApiKeyStore() }, chatDbPath: "/nicht/vorhanden",
                           runScript: { _ in ProcessOutput(status: 0) }, clock: clock)
    try expectEqual(hub.pollDelay(base: 60), 300, "ohne Nutzung")
    hub.noteIslandUse()
    try expectEqual(hub.pollDelay(base: 60), 60, "gerade benutzt")
    clock.advance(seconds: 301)
    try expectEqual(hub.pollDelay(base: 60), 300, "nach 5 Minuten wieder langsam")
  }

  @MainActor static func hubRig(_ fake: HubFake) throws -> MessengerHub {
    let store = try Store.inMemory(clock: ControllableClock("2026-10-14T10:00"))
    let hub = MessengerHub(store: store, secrets: { _ in InMemoryApiKeyStore() }, chatDbPath: "/nicht/vorhanden",
                           runScript: { _ in ProcessOutput(status: 0) })
    hub.connectorFactory = { _ in fake }
    return hub
  }

  @MainActor static func connectedHub(_ fake: HubFake) async throws -> (MessengerHub, MessengerAccount) {
    let hub = try hubRig(fake)
    let r = await hub.connect(MessengerLogin(service: .slack, secret: "xoxp-test"))
    return (hub, try expectNotNil(r.value, r.errorMessage ?? "Anmeldung fehlgeschlagen"))
  }

  @MainActor static func waitForEmojis(_ hub: MessengerHub) async throws {
    for _ in 0..<200 where hub.verification?.phase != .showEmojis {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    try expectEqual(hub.verification?.phase, .showEmojis, "Emojis kommen vom Gerät")
  }

  static let hubCases: [CheckCase] = [
    CheckCase("Hub: Lesen setzt den Zähler lokal auf 0, ohne neuen Takt") { @MainActor in
      let fake = HubFake()
      let (hub, account) = try await connectedHub(fake)
      let convId = "\(account.id)|C1"
      try expectEqual(hub.conversationList().first { $0.id == convId }?.unread, 1)
      let polls = fake.pollCount
      await hub.markRead(convId)
      try expectEqual(hub.conversationList().first { $0.id == convId }?.unread, 0)
      try expectEqual(fake.pollCount, polls, "Lesen löst keinen Takt aus")
      try expectEqual(fake.markedRead, ["C1"])
    },

    CheckCase("Hub: Abbruch während der Bestätigung wird nicht überschrieben") { @MainActor in
      let fake = HubFake()
      let (hub, account) = try await connectedHub(fake)
      _ = await hub.startVerification(account.id)
      try await waitForEmojis(hub)
      fake.onAnswer = { await hub.cancelVerification(account.id) }
      _ = await hub.answerVerification(account.id, matches: true)
      try expect(hub.verification == nil, "nach Abbruch kommt kein Erfolg mehr zurück")
    },

    CheckCase("Hub: fertige Bestätigung ist nach dem nächsten Takt weg") { @MainActor in
      let fake = HubFake()
      let (hub, account) = try await connectedHub(fake)
      _ = await hub.startVerification(account.id)
      try await waitForEmojis(hub)
      _ = await hub.answerVerification(account.id, matches: true)
      try expectEqual(hub.verification?.phase, .done)
      await hub.poll()
      try expect(hub.verification == nil, "der Takt räumt die erledigte Bestätigung auf")
    },
  ]
}

/// Zeichnet die Skripte auf statt osascript zu starten.
final class ScriptRecorder: @unchecked Sendable {
  private(set) var scripts: [String] = []
  let status: Int32
  let stderr: String
  init(status: Int32, stderr: String = "") { self.status = status; self.stderr = stderr }
  var run: @Sendable (String) throws -> ProcessOutput {
    { [self] script in
      self.scripts.append(script)
      return ProcessOutput(status: self.status, stderr: self.stderr)
    }
  }
}
