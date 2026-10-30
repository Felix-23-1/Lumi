// Prüfungen Paket 12: Slack-Connector gegen ein gestubbtes HTTP (kein echtes Netz,
// kein echter Token). Eigenes URLProtocol, damit es mit anderen Stubs nicht kollidiert.
import Foundation

/// Gestubbtes HTTP nur für Slack-Prüfungen. Handler: Methode (letzter Pfadteil), Anfrage, Body → Antwort.
final class SlackStubURLProtocol: URLProtocol {
  struct Reply {
    var status = 200
    var body: [String: Any]
    var headers: [String: String] = [:]
  }
  typealias Handler = (String, URLRequest, Data?) -> Reply
  private static let lock = NSLock()
  private static var handler: Handler?

  static func session(_ handler: @escaping Handler) -> URLSession {
    lock.withLock { self.handler = handler }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [SlackStubURLProtocol.self]
    return URLSession(configuration: cfg)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var bodyData = request.httpBody
    if bodyData == nil, let stream = request.httpBodyStream {
      stream.open()
      var d = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        d.append(contentsOf: buf[0..<n])
      }
      stream.close()
      bodyData = d
    }
    let method = request.url?.lastPathComponent ?? ""
    let h = Self.lock.withLock { Self.handler }
    let reply = h?(method, request, bodyData) ?? Reply(status: 404, body: ["ok": false, "error": "unknown_method"])
    let data = (try? JSONSerialization.data(withJSONObject: reply.body)) ?? Data()
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Ein kleines Slack: zwei Unterhaltungen (Kanal, DM) und eine nicht beigetretene; zeichnet Aufrufe auf.
final class SlackFake: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var calls: [String] = []
  private(set) var authHeaders: [String] = []
  private(set) var lastRequest: URLRequest?
  private(set) var lastBody: Data?
  /// Antwort-Überschreibungen je Methode (z. B. Fehler).
  var overrides: [String: SlackStubURLProtocol.Reply] = [:]
  /// Verlauf je Kanal-ID, neueste zuerst (so liefert Slack ihn).
  var history: [String: [[String: Any]]] = SlackFake.defaultHistory

  static let defaultHistory: [String: [[String: Any]]] = [
    "C1": [
      ["type": "message", "user": "U2", "text": "Neu &amp; wichtig", "ts": "1700000300.000100"],
      ["type": "message", "user": "U1", "text": "Ich", "ts": "1700000200.000100"],
      ["type": "message", "user": "U2", "text": "Alt", "ts": "1700000100.000100"],
    ],
    "D1": [
      ["type": "message", "user": "U2", "text": "Hallo", "ts": "1700000400.000500"],
    ],
  ]

  func count(_ method: String) -> Int { lock.withLock { calls.filter { $0 == method }.count } }
  var callCount: Int { lock.withLock { calls.count } }

  func session() -> URLSession {
    SlackStubURLProtocol.session { [self] method, request, body in self.handle(method, request, body) }
  }

  private func handle(_ method: String, _ request: URLRequest, _ body: Data?) -> SlackStubURLProtocol.Reply {
    lock.withLock {
      calls.append(method)
      authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
      lastRequest = request
      lastBody = body
    }
    if let override = lock.withLock({ overrides[method] }) { return override }
    switch method {
    case "auth.test":
      return .init(body: ["ok": true, "url": "https://x.slack.com/", "team": "Subarachnoid Workspace",
                          "user": "grace", "team_id": "T1", "user_id": "U1"])
    case "users.conversations":
      // Zwei Seiten: Seite 1 mit Kanal, Seite 2 (cursor) mit DM und einer Nicht-Mitgliedschaft.
      let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "cursor" }?.value
      if cursor == nil {
        return .init(body: ["ok": true, "channels": [["id": "C1", "name": "allgemein", "is_channel": true, "is_member": true]],
                            "response_metadata": ["next_cursor": "seite2"]])
      }
      return .init(body: ["ok": true, "channels": [
        ["id": "D1", "is_im": true, "user": "U2"],
        ["id": "C2", "name": "archiv", "is_channel": true, "is_member": false],
      ], "response_metadata": ["next_cursor": ""]])
    case "conversations.history":
      let channel = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "channel" }?.value ?? ""
      return .init(body: ["ok": true, "messages": lock.withLock { history[channel] ?? [] }])
    case "users.info":
      return .init(body: ["ok": true, "user": ["id": "U2", "real_name": "Anna Beispiel",
                                               "profile": ["real_name": "Anna Beispiel"]]])
    case "chat.postMessage":
      return .init(body: ["ok": true, "ts": "1700000500.000100", "channel": "C1"])
    default:
      return .init(status: 404, body: ["ok": false, "error": "unknown_method"])
    }
  }
}

enum SlackChecks {
  /// Angemeldeter Connector mit fester Uhr (10:00) für die Prüfungen.
  private static func loggedIn(_ fake: SlackFake, markers: MessengerReadMarkers? = nil,
                               clock: Clock = ControllableClock("2026-10-14T10:00")) async throws -> SlackConnector {
    let c = SlackConnector(session: fake.session(), clock: clock, readMarkers: markers)
    _ = try await c.login(MessengerLogin(service: .slack, secret: "xoxp-test"), accountId: "acc")
    return c
  }

  /// Erwartet einen MessengerFailure und liefert seinen Text.
  private static func failure(_ body: () async throws -> Void) async throws -> String {
    do { try await body() } catch let e as MessengerFailure { return e.message }
    throw CheckFailure(message: "Fehler erwartet", location: "SlackChecks")
  }

  static let cases: [CheckCase] = [
    CheckCase("Slack: Anmeldung prüft den Token und nennt Benutzer und Workspace") {
      let fake = SlackFake()
      let c = SlackConnector(session: fake.session(), clock: ControllableClock("2026-10-14T10:00"))
      let (account, secret) = try await c.login(MessengerLogin(service: .slack, secret: " xoxp-test "), accountId: "acc")
      try expectEqual(account.user, "grace · Subarachnoid Workspace")
      try expectEqual(account.service, .slack)
      try expectEqual(secret, "xoxp-test")
      try expectEqual(fake.calls, ["auth.test"])
      try expectEqual(fake.authHeaders, ["Bearer xoxp-test"])
    },

    CheckCase("Slack: ungültiger Token gibt den deutschen Hinweis") {
      let fake = SlackFake()
      fake.overrides["auth.test"] = .init(body: ["ok": false, "error": "invalid_auth"])
      let c = SlackConnector(session: fake.session(), clock: ControllableClock("2026-10-14T10:00"))
      let text = try await failure { _ = try await c.login(MessengerLogin(service: .slack, secret: "xoxp-bad"), accountId: "acc") }
      try expectEqual(text, "Slack-Token ungültig oder widerrufen.")
      let empty = try await failure { _ = try await c.login(MessengerLogin(service: .slack, secret: "  "), accountId: "acc") }
      try expectEqual(empty, "Bitte den Slack-Token (xoxp-…) eingeben.")
      try expectEqual(fake.count("auth.test"), 1, "leerer Token braucht kein Netz")
    },

    CheckCase("Slack: Kanal mit #, DM mit echtem Namen, Nicht-Mitglied fehlt") {
      let c = try await loggedIn(SlackFake())
      let byId = Dictionary(uniqueKeysWithValues: try await c.conversations().map { ($0.id, $0) })
      try expectEqual(byId["acc|C1"]?.title, "#allgemein")
      try expectEqual(byId["acc|D1"]?.title, "Anna Beispiel")
      try expect(byId["acc|D1"]?.isDirect == true && byId["acc|C1"]?.isDirect == false)
      try expect(byId["acc|C2"] == nil, "nicht Mitglied")
      try expectEqual(byId["acc|C1"]?.lastText, "Neu & wichtig")
      try expectEqual(byId["acc|D1"]?.lastAt, LocalTime.format(Date(timeIntervalSince1970: 1_700_000_400)))
    },

    CheckCase("Slack: users.info wird je Person nur einmal geholt") {
      let fake = SlackFake()
      let c = try await loggedIn(fake)
      _ = try await c.conversations()
      _ = try await c.conversations()
      _ = try await c.messages(roomId: "C1", limit: 10)
      try expectEqual(fake.count("users.info"), 1, "Anna ist im Zwischenspeicher")
    },

    CheckCase("Slack: Nachrichten älteste zuerst, eigene markiert, Namen aufgelöst") {
      let c = try await loggedIn(SlackFake())
      let msgs = try await c.messages(roomId: "C1", limit: 10)
      try expectEqual(msgs.map(\.text), ["Alt", "Ich", "Neu & wichtig"])
      try expectEqual(msgs.map(\.sender), ["Anna Beispiel", "Ich", "Anna Beispiel"])
      try expectEqual(msgs.map(\.mine), [false, true, false])
      try expectEqual(msgs[0].conversationId, "acc|C1")
    },

    CheckCase("Slack: Senden schickt Kanal und Text als JSON per POST") {
      let fake = SlackFake()
      let c = try await loggedIn(fake)
      try await c.send(roomId: "C1", text: "Hallo Team")
      let body = try JSONSerialization.jsonObject(with: try expectNotNil(fake.lastBody)) as? [String: String]
      try expectEqual(body?["channel"], "C1")
      try expectEqual(body?["text"], "Hallo Team")
      try expectEqual(fake.lastRequest?.httpMethod, "POST")
      try expectEqual(fake.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
    },

    CheckCase("Slack: 429 pausiert den Takt mit Retry-After, ohne Absturz") {
      let fake = SlackFake()
      let clock = ControllableClock("2026-10-14T10:00")
      let c = try await loggedIn(fake, clock: clock)
      _ = try await c.conversations()
      fake.overrides["conversations.history"] = .init(status: 429, body: ["ok": false, "error": "ratelimited"],
                                                     headers: ["Retry-After": "30"])
      let during = try await c.conversations()
      try expectEqual(during.count, 2, "Zwischenspeicher bleibt sichtbar")
      let before = fake.callCount
      _ = try await c.conversations()
      try expectEqual(fake.callCount, before, "in der Pause keine Netzanfrage")
      let text = try await failure { _ = try await c.messages(roomId: "C1", limit: 5) }
      try expect(text.hasPrefix("Slack bremst gerade"), text)
      clock.advance(seconds: 31)
      fake.overrides["conversations.history"] = nil
      _ = try await c.conversations()
      try expect(fake.callCount > before, "nach der Pause wieder abfragen")
    },

    CheckCase("Slack: Ungelesen zählt Nachrichten anderer nach lokalem Marker") {
      let fake = SlackFake()
      let markers = MarkerBox(values: [:])
      let c = try await loggedIn(fake, markers: markers.markers)
      let first = try await c.conversations()
      try expectEqual(first.first { $0.id == "acc|C1" }?.unread, 0, "erster Blick zählt nichts")
      let fresh: [[String: Any]] = [["type": "message", "user": "U2", "text": "Neu", "ts": "1700000450.000100"]]
      fake.history["C1"] = fresh + SlackFake.defaultHistory["C1"]!
      let unread = try await c.conversations()
      try expectEqual(unread.first { $0.id == "acc|C1" }?.unread, 1)
      try await c.markRead(roomId: "C1")
      try expectEqual(markers.values["acc|C1"], 1_700_000_450_000_100)
      let read = try await c.conversations()
      try expectEqual(read.first { $0.id == "acc|C1" }?.unread, 0)
      let mine: [[String: Any]] = [["type": "message", "user": "U1", "text": "Mein", "ts": "1700000500.000100"]]
      fake.history["C1"] = mine + SlackFake.defaultHistory["C1"]!
      let own = try await c.conversations()
      try expectEqual(own.first { $0.id == "acc|C1" }?.unread, 0, "eigene Nachrichten zählen nicht")
    },

    CheckCase("Slack: vorgegebener Marker zählt nur neuere fremde Nachrichten") {
      let markers = MarkerBox(values: ["acc|C1": SlackConnector.micros("1700000150.000000") ?? 0])
      let c = try await loggedIn(SlackFake(), markers: markers.markers)
      let list = try await c.conversations()
      try expectEqual(list.first { $0.id == "acc|C1" }?.unread, 1, "nur die Nachricht um 300 zählt")
    },

    CheckCase("Slack: fehlende Berechtigung nennt den Scope") {
      let fake = SlackFake()
      let c = try await loggedIn(fake)
      fake.overrides["users.conversations"] = .init(body: ["ok": false, "error": "missing_scope", "needed": "im:history"])
      let text = try await failure { _ = try await c.conversations() }
      try expectEqual(text, "Dem Slack-Token fehlt die Berechtigung „im:history“.")
    },

    CheckCase("Slack: Unterhaltungen aus beiden Seiten, höchstens fünf Seiten") {
      let fake = SlackFake()
      let c = try await loggedIn(fake)
      let ids = try await c.conversations().map(\.id).sorted()
      try expectEqual(ids, ["acc|C1", "acc|D1"], "Seite 1 und Seite 2 erscheinen")
      try expectEqual(fake.count("users.conversations"), 2)
      // Endlose Seiten: nach roomPages Abrufen ist Schluss.
      let endless = SlackFake()
      endless.overrides["users.conversations"] = .init(body: ["ok": true, "channels": [
        ["id": "C1", "name": "allgemein", "is_channel": true, "is_member": true],
      ], "response_metadata": ["next_cursor": "immer"]])
      let capped = try await loggedIn(endless)
      _ = try await capped.conversations()
      try expectEqual(endless.count("users.conversations"), SlackConnector.roomPages, "Seitenzahl gedeckelt")
    },

    CheckCase("Slack: DM-Name wird nachgeholt, wenn users.info zuerst fehlschlug") {
      let fake = SlackFake()
      fake.overrides["users.info"] = .init(body: ["ok": false, "error": "user_not_found"])
      let c = try await loggedIn(fake)
      let first = try await c.conversations()
      try expectEqual(first.first { $0.id == "acc|D1" }?.title, "Direktnachricht")
      fake.overrides["users.info"] = nil
      let second = try await c.conversations()
      try expectEqual(second.first { $0.id == "acc|D1" }?.title, "Anna Beispiel")
    },

    CheckCase("Slack: Lesestand ist die neueste gesehene Nachricht (kein Rest-Zähler)") {
      let fake = SlackFake()
      let markers = MarkerBox(values: [:])
      let c = try await loggedIn(fake, markers: markers.markers)
      _ = try await c.conversations()  // erster Blick, Stand bis 1700000300
      let fresh: [[String: Any]] = [["type": "message", "user": "U2", "text": "Neu", "ts": "1700000450.000100"]]
      fake.history["C1"] = fresh + SlackFake.defaultHistory["C1"]!
      _ = try await c.messages(roomId: "C1", limit: 10)  // Nutzer sieht die neue Nachricht
      try await c.markRead(roomId: "C1")
      try expectEqual(markers.values["acc|C1"], 1_700_000_450_000_100, "markRead speichert den gesehenen Stand")
      let after = try await c.conversations()
      try expectEqual(after.first { $0.id == "acc|C1" }?.unread, 0)
    },

    CheckCase("Slack: Zeitstempel werden exakt in Mikrosekunden gelesen") {
      try expectEqual(SlackConnector.micros("1700000300.000100"), 1_700_000_300_000_100)
      try expectEqual(SlackConnector.micros("1700000300.5"), 1_700_000_300_500_000)
      try expectEqual(SlackConnector.slackFailure("invalid_auth", needed: nil).message, "Slack-Token ungültig oder widerrufen.")
    },
  ]
}
