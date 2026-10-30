// Prüfungen für den Spotify-Anbieter. Netz, Browser und Schlüsselbund sind gestubbt:
// Anfragen gehen an einen Handler, der Browser liefert eine feste Antwort, Tokens liegen im Speicher.
import Foundation

enum SpotifyChecks {
  static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  static let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  /// Zählt Aufrufe über Grenzen hinweg (Sendefunktion läuft nebenläufig).
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
  }

  /// Einfacher, nebenläufig sicherer Wert (für Antworten, die ein Test zwischendurch ändert).
  final class Cell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
      get { lock.withLock { v } }
      set { lock.withLock { v = newValue } }
    }
  }

  /// Gestubbte Umgebung: Anfragen, Antworten, geöffnete Adressen, Speicher und Uhr.
  final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    private var opened: [URL] = []
    /// Zustand, den der Browser zurückmeldet; nil = der Zustand aus der geöffneten Adresse.
    private var callbackState: String?
    let refresh = InMemoryApiKeyStore()
    let clock = ControllableClock("2026-10-20T10:00")
    let defaults: UserDefaults
    private let suite: String

    init() {
      suite = "spotify-checks-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suite)!
      defaults.set("client-123", forKey: SpotifyProvider.clientIdKey)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    var sent: [URLRequest] { lock.withLock { requests } }
    var openedURLs: [URL] { lock.withLock { opened } }

    func setHandler(_ h: @escaping (URLRequest) -> (Int, Data)) { lock.withLock { handler = h } }
    func setCallbackState(_ s: String) { lock.withLock { callbackState = s } }

    func respond(_ req: URLRequest) -> (Data, Int) {
      let h = lock.withLock { () -> (URLRequest) -> (Int, Data) in requests.append(req); return handler }
      let (status, data) = h(req)
      return (data, status)
    }

    func provider() -> SpotifyProvider {
      SpotifyProvider(
        defaults: defaults, refreshStore: refresh, clock: clock,
        send: { [self] req in self.respond(req) },
        openURL: { [self] url in self.lock.withLock { self.opened.append(url) } },
        receive: { [self] onReady in
          onReady()
          let fromURL = SpotifyChecks.query(self.openedURLs.last ?? URL(string: "https://x.invalid")!)["state"] ?? ""
          let state = self.lock.withLock { self.callbackState } ?? fromURL
          return SpotifyCallback(code: "CODE-1", state: state)
        })
    }
  }

  static func json(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
  }

  static func query(_ url: URL) -> [String: String] {
    var d: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { d[item.name] = item.value }
    return d
  }

  static func form(_ req: URLRequest) -> [String: String] {
    var d: [String: String] = [:]
    for pair in String(decoding: req.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 { d[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
    }
    return d
  }

  static func jsonBody(_ req: URLRequest) -> [String: Any]? {
    guard let b = req.httpBody else { return nil }
    return (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
  }

  static func isToken(_ req: URLRequest) -> Bool { req.url?.host == "accounts.spotify.com" }
  static func isGrant(_ req: URLRequest, _ grant: String) -> Bool { isToken(req) && form(req)["grant_type"] == grant }

  /// Standardantwort des Token-Endpunkts: Anmeldung liefert AT-1/RT-1, Erneuerung AT-2/RT-2.
  static func tokenAnswer(_ req: URLRequest) -> (Int, Data) {
    if isGrant(req, "refresh_token") {
      return (200, json(["access_token": "AT-2", "expires_in": 3600, "refresh_token": "RT-2", "token_type": "Bearer"]))
    }
    return (200, json(["access_token": "AT-1", "expires_in": 3600, "refresh_token": "RT-1", "token_type": "Bearer"]))
  }

  /// Gestubbt: Token-Endpunkt antwortet, sonst `api` (Pfad → Antwort).
  static func route(_ api: @escaping (URLRequest) -> (Int, Data)) -> (URLRequest) -> (Int, Data) {
    { req in isToken(req) ? tokenAnswer(req) : api(req) }
  }

  /// Verbindet die Umgebung (Anmeldung mit Standardantwort) und liefert den Anbieter.
  static func connected(_ h: Harness, api: @escaping (URLRequest) -> (Int, Data) = { _ in (500, Data()) }) async throws -> SpotifyProvider {
    h.setHandler(route(api))
    let p = h.provider()
    let r = await p.connect()
    try expect(r.isOk, "Anmeldung im Test muss gelingen: \(r.errorMessage ?? "")")
    h.setHandler(route(api))
    return p
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Spotify: PKCE-Challenge stimmt mit dem RFC-7636-Testvektor überein") {
        try expectEqual(SpotifyPKCE.challenge(for: rfcVerifier), rfcChallenge)
        let v = SpotifyPKCE.randomToken(bytes: 64)
        try expectEqual(v.count, 86, "64 Zufallsbytes ergeben 86 Zeichen base64url")
        try expect(!v.contains("=") && !v.contains("+") && !v.contains("/"), "base64url ohne Auffüllung")
        try expectEqual(SpotifyPKCE.encode("a b&c=d+e/ü"), "a%20b%26c%3Dd%2Be%2F%C3%BC")
      },

      CheckCase("Spotify: ohne Client-ID wird nichts gesendet und nichts geöffnet") {
        let h = Harness(); defer { h.cleanup() }
        h.defaults.removeObject(forKey: SpotifyProvider.clientIdKey)
        let r = await h.provider().connect()
        try expectEqual(r.errorMessage, SpotifyProvider.noClientIdNote)
        try expect(h.sent.isEmpty && h.openedURLs.isEmpty, "keine Anfrage, kein Browser")
      },

      CheckCase("Spotify: Anmeldung öffnet nur accounts.spotify.com mit PKCE und speichert nur das Erneuerungs-Token") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h)
        h.setHandler(SpotifyChecks.route { _ in (500, Data()) })
        let open = try expectNotNil(h.openedURLs.first)
        try expectEqual(open.host, "accounts.spotify.com")
        try expectEqual(open.path, "/authorize")
        let q = SpotifyChecks.query(open)
        try expectEqual(q["redirect_uri"], SpotifyProvider.redirectURI)
        try expectEqual(q["code_challenge_method"], "S256")
        try expectEqual(q["scope"], SpotifyProvider.scopes)
        try expectEqual(q["client_id"], "client-123")
        let exchange = try expectNotNil(h.sent.first(where: { SpotifyChecks.isGrant($0, "authorization_code") }))
        let body = SpotifyChecks.form(exchange)
        try expectEqual(body["code"], "CODE-1")
        try expect(body["client_secret"] == nil, "kein Client-Secret")
        let verifier = try expectNotNil(body["code_verifier"])
        try expectEqual(SpotifyPKCE.challenge(for: verifier), q["code_challenge"], "Challenge passt zum Verifier")
        try expectEqual(try h.refresh.get(), "RT-1")
        let st = await p.status()
        try expect(st.connected && st.canSearch && st.canListPlaylists && st.canControl)
        try expectEqual(st.note, SpotifyProvider.premiumNote)
      },

      CheckCase("Spotify: falscher Zustand wird abgelehnt, kein Token-Tausch, nichts gespeichert") {
        let h = Harness(); defer { h.cleanup() }
        h.setHandler(SpotifyChecks.route { _ in (500, Data()) })
        h.setCallbackState("falsch")
        let r = await h.provider().connect()
        try expect(!r.isOk, "falscher state muss scheitern")
        try expect(!h.sent.contains { SpotifyChecks.isToken($0) }, "kein Tausch bei falschem state")
        try expect(!h.refresh.hasKey(), "nichts gespeichert")
      },

      CheckCase("Spotify: Zugriffs-Token wird vor Ablauf erneuert, das gedrehte Erneuerungs-Token gespeichert") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h) { req in
          req.url?.path == "/v1/me/playlists" ? (200, SpotifyChecks.json(["items": []])) : (500, Data())
        }
        _ = await p.playlists()
        try expectEqual(h.sent.filter { SpotifyChecks.isGrant($0, "refresh_token") }.count, 0, "frisches Token: keine Erneuerung")
        h.clock.advance(seconds: 3600 - 30)
        let r = await p.playlists()
        try expect(r.isOk, r.errorMessage ?? "")
        try expectEqual(h.sent.filter { SpotifyChecks.isGrant($0, "refresh_token") }.count, 1, "kurz vor Ablauf: eine Erneuerung")
        let last = try expectNotNil(h.sent.last)
        try expectEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer AT-2")
        try expectEqual(try h.refresh.get(), "RT-2")
      },

      CheckCase("Spotify: Suche bildet Titel und Playlists ab, Cover nur über https") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h) { req in
          guard req.url?.path == "/v1/search" else { return (500, Data()) }
          return (200, SpotifyChecks.json([
            "tracks": ["items": [
              ["uri": "spotify:track:AAA", "name": "Lied A", "artists": [["name": "Artist 1"], ["name": "Artist 2"]],
               "album": ["images": [["url": "https://i.scdn.co/a.jpg"]]]],
              ["uri": "spotify:track:BBB", "name": "Lied B", "artists": [["name": "X"]],
               "album": ["images": [["url": "http://insecure.example/b.jpg"]]]],
              ["uri": "spotify:track:CCC", "name": "Lied C", "artists": []],
              NSNull(),
            ]],
            "playlists": ["items": [
              ["uri": "spotify:playlist:PPP", "name": "Liste", "owner": ["display_name": "Anna"],
               "images": [["url": "https://i.scdn.co/p.jpg"]]],
              NSNull(),
            ]],
          ]))
        }
        let r = await p.search("Hallo Welt & A+B")
        let items = try expectNotNil(r.value, r.errorMessage ?? "")
        try expectEqual(items.map(\.title), ["Lied A", "Lied B", "Lied C", "Liste"], "null-Einträge fallen weg")
        try expectEqual(items[0].id, "spotify:track:AAA")
        try expectEqual(items[0].kind, .track)
        try expectEqual(items[0].subtitle, "Artist 1, Artist 2")
        try expectEqual(items[0].imageURL, "https://i.scdn.co/a.jpg")
        try expectEqual(items[1].imageURL, nil, "http-Cover wird verworfen")
        try expectEqual(items[2].imageURL, nil, "fehlendes Album-Cover")
        try expectEqual(items[3].kind, .playlist)
        try expectEqual(items[3].subtitle, "Anna")
        try expectEqual(items[3].imageURL, "https://i.scdn.co/p.jpg")
        let call = try expectNotNil(h.sent.last(where: { $0.url?.path == "/v1/search" }))
        let absolute = try expectNotNil(call.url?.absoluteString)
        try expect(absolute.contains("q=Hallo%20Welt%20%26%20A%2BB"), "Anfrage gründlich kodiert: \(absolute)")
        try expect(absolute.contains("type=track,playlist&limit=10"), absolute)
      },

      CheckCase("Spotify: leere Suche ergibt eine leere Liste ohne Netz") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h)
        let before = h.sent.count
        let r = await p.search("   ")
        try expectEqual(r.value?.count, 0)
        try expectEqual(h.sent.count, before, "keine Anfrage bei leerer Suche")
      },

      CheckCase("Spotify: Suche ohne Anmeldung meldet Anmeldung statt Netz") {
        let h = Harness(); defer { h.cleanup() }
        let r = await h.provider().search("Queen")
        try expectEqual(r.errorMessage, "Nicht bei Spotify angemeldet. Bitte unter Verbindungen → Spotify anmelden.")
        try expect(h.sent.isEmpty, "ohne Anmeldung wird gar nichts gesendet")
      },

      CheckCase("Spotify: Playlists kommen aus /me/playlists mit Besitzer und Cover") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h) { req in
          guard req.url?.path == "/v1/me/playlists" else { return (500, Data()) }
          return (200, SpotifyChecks.json(["items": [
            ["uri": "spotify:playlist:P1", "name": "Mix", "owner": ["display_name": "Me"], "images": []],
            NSNull(),
          ]]))
        }
        let r = await p.playlists()
        let items = try expectNotNil(r.value, r.errorMessage ?? "")
        try expectEqual(items.count, 1)
        try expectEqual(items[0].id, "spotify:playlist:P1")
        try expectEqual(items[0].subtitle, "Me")
        try expectEqual(items[0].imageURL, nil)
        try expectEqual(h.sent.last?.url?.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=50")
      },

      CheckCase("Spotify: Titel wird als uris, Playlist und Album als context_uri abgespielt") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h) { req in
          req.url?.path == "/v1/me/player/play" ? (204, Data()) : (500, Data())
        }
        let track = await p.play(MusicItem(id: "spotify:track:T1", service: .spotify, kind: .track, title: "T"))
        try expect(track.isOk, track.errorMessage ?? "")
        let t = try expectNotNil(h.sent.last)
        try expectEqual(t.httpMethod, "PUT")
        try expectEqual(t.url?.absoluteString, "https://api.spotify.com/v1/me/player/play")
        try expectEqual(SpotifyChecks.jsonBody(t)?["uris"] as? [String], ["spotify:track:T1"])
        let list = await p.play(MusicItem(id: "spotify:playlist:P1", service: .spotify, kind: .playlist, title: "P"))
        try expect(list.isOk, list.errorMessage ?? "")
        try expectEqual(SpotifyChecks.jsonBody(try expectNotNil(h.sent.last))?["context_uri"] as? String, "spotify:playlist:P1")
        let album = await p.play(MusicItem(id: "spotify:album:L1", service: .spotify, kind: .album, title: "L"))
        try expect(album.isOk, album.errorMessage ?? "")
        try expectEqual(SpotifyChecks.jsonBody(try expectNotNil(h.sent.last))?["context_uri"] as? String, "spotify:album:L1")
      },

      CheckCase("Spotify: Fehler beim Abspielen werden auf Deutsch abgebildet") {
        let h = Harness(); defer { h.cleanup() }
        let status = Cell(404)
        let p = try await SpotifyChecks.connected(h) { req in
          req.url?.path == "/v1/me/player/play" ? (status.value, Data()) : (500, Data())
        }
        let cases: [(Int, String)] = [
          (404, "Öffne Spotify auf diesem Mac und starte dort einmal einen Titel."),
          (403, "Dafür ist Spotify Premium nötig."),
          (429, "Spotify bremst gerade, versuch es gleich noch einmal."),
          (500, "Spotify konnte die Anfrage nicht ausführen (Status 500)."),
        ]
        for (code, text) in cases {
          status.value = code
          let r = await p.play(MusicItem(id: "spotify:track:T1", service: .spotify, kind: .track, title: "T"))
          try expectEqual(r.errorMessage, text, "Status \(code)")
        }
      },

      CheckCase("Spotify: 401 beim Abspielen erneuert das Token einmal und wiederholt") {
        let h = Harness(); defer { h.cleanup() }
        let calls = Counter()
        let p = try await SpotifyChecks.connected(h) { req in
          guard req.url?.path == "/v1/me/player/play" else { return (500, Data()) }
          return calls.next() == 1 ? (401, Data()) : (204, Data())
        }
        let r = await p.play(MusicItem(id: "spotify:track:T1", service: .spotify, kind: .track, title: "T"))
        try expect(r.isOk, r.errorMessage ?? "")
        try expectEqual(h.sent.filter { SpotifyChecks.isGrant($0, "refresh_token") }.count, 1)
        try expectEqual(h.sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer AT-2")
      },

      CheckCase("Spotify: bleibt 401 nach Erneuerung, heißt es „Bitte neu anmelden.“") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h) { req in
          req.url?.path == "/v1/me/player/play" ? (401, Data()) : (500, Data())
        }
        let r = await p.play(MusicItem(id: "spotify:track:T1", service: .spotify, kind: .track, title: "T"))
        try expectEqual(r.errorMessage, "Bitte neu anmelden.")
      },

      CheckCase("Spotify: ungültige Adressen werden beim Abspielen abgelehnt, ohne Anfrage") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h)
        let before = h.sent.count
        for bad in ["spotify:user:x", "spotify:track:a b", "https://evil.example/x", "spotify:track:", "spotify:track:a:b"] {
          let r = await p.play(MusicItem(id: bad, service: .spotify, kind: .track, title: "x"))
          try expectEqual(r.errorMessage, "Dieser Eintrag kann nicht abgespielt werden.", bad)
        }
        try expectEqual(h.sent.count, before, "keine Anfrage für ungültige Adressen")
      },

      CheckCase("Spotify: abgelaufene Anmeldung meldet „Bitte neu anmelden.“ ohne Token-Text") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h)
        h.setHandler { req in
          SpotifyChecks.isGrant(req, "refresh_token") ? (400, Data("{\"error\":\"invalid_grant\"}".utf8)) : (500, Data())
        }
        h.clock.advance(seconds: 3600)
        let r = await p.playlists()
        try expectEqual(r.errorMessage, "Bitte neu anmelden.")
        let msg = r.errorMessage ?? ""
        try expect(!msg.contains("RT-1") && !msg.contains("AT-1"), "keine Tokens in der Meldung")
      },

      CheckCase("Spotify: Trennen löscht das Erneuerungs-Token und verwirft das Zugriffs-Token") {
        let h = Harness(); defer { h.cleanup() }
        let p = try await SpotifyChecks.connected(h)
        try expect(h.refresh.hasKey())
        await p.disconnect()
        try expect(!h.refresh.hasKey(), "Erneuerungs-Token gelöscht")
        let st = await p.status()
        try expect(!st.connected && !st.canControl, "nach Trennen nicht verbunden")
        let r = await p.playlists()
        try expectEqual(r.errorMessage, "Nicht bei Spotify angemeldet. Bitte unter Verbindungen → Spotify anmelden.")
      },

      CheckCase("Spotify: Status ohne Client-ID nennt den Einrichtungshinweis, Client-ID wird getrimmt gespeichert") {
        let h = Harness(); defer { h.cleanup() }
        h.defaults.removeObject(forKey: SpotifyProvider.clientIdKey)
        let p = h.provider()
        let st = await p.status()
        try expectEqual(st.note, SpotifyProvider.noClientIdNote)
        try expect(!st.connected && st.clientId.isEmpty)
        await p.setClientId("  abc-123  ")
        try expectEqual(h.defaults.string(forKey: SpotifyProvider.clientIdKey), "abc-123")
        let st2 = await p.status()
        try expectEqual(st2.clientId, "abc-123")
      },

      CheckCase("Spotify: Loopback nimmt nur GET /callback an und liest code und state") {
        let t = try expectNotNil(SpotifyLoopback.requestTarget(Data("GET /callback?code=c1&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)))
        try expectEqual(t.0, "/callback")
        try expectEqual(t.1.first { $0.name == "code" }?.value, "c1")
        try expectEqual(t.1.first { $0.name == "state" }?.value, "s1")
        try expect(SpotifyLoopback.requestTarget(Data("POST /callback HTTP/1.1\r\n\r\n".utf8)) == nil, "nur GET")
        try expect(SpotifyLoopback.requestTarget(nil) == nil, "ohne Daten nichts")
      },
    ]
  }
}
