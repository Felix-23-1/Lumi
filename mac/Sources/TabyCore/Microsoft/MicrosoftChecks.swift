// Prüfungen für Microsoft: Anmeldung per Gerätecode, Rechte je Funktion, Abbrechen, Erneuerung
// mit der Uhr (auch parallel und bei Abmeldung), Host-Liste und Größenlimit.
// HTTP läuft über CalendarStubURLProtocol (kein echtes Netz, kein echtes Konto).
// Der Schlüsselbund ist ein Speicher (InMemoryApiKeyStore); Wartezeiten vergehen auf der Prüfuhr.
import Foundation

/// Gestubbter Microsoft-Dienst: Antworten je Anfrage, mitgeschnittene Anfragen, Prüfuhr und Speicher.
final class MicrosoftHarness {
  struct Seen {
    let method: String
    let url: URL
    let body: String
    let headers: [String: String]
  }

  static let clientId = "11111111-2222-3333-4444-555555555555"

  let clock = ControllableClock("2026-10-20T09:00")
  let refresh = InMemoryApiKeyStore()
  var clientIdValue = MicrosoftHarness.clientId
  /// Laufzeit des Gerätecodes in Sekunden.
  var deviceExpiresIn = 900
  /// Abstand des Gerätecodes in Sekunden (vom Server).
  var deviceInterval = 5
  /// Rechte, die Microsoft in jeder Token-Antwort meldet.
  var grantedScope = MicrosoftChecks.fullScope
  /// Antworten des Token-Endpunkts der Reihe nach; leer = Standard (Erneuerung ok, Gerätecode wartet).
  var tokenReplies: [(Int, Any)] = []
  /// Graph-Antworten je „METHODE Pfad“, der Reihe nach; die letzte bleibt stehen.
  var graphReplies: [String: [(Int, Any)]] = [:]
  /// Wird bei jedem Warten aufgerufen (Anzahl bisher); Prüfungen können hier abbrechen oder neu anmelden.
  var onPause: ((Int) async -> Void)?
  /// Hält die nächste Erneuerungsantwort zurück, bis das Signal kommt.
  var renewGate: DispatchSemaphore?
  /// Wartezeiten, die die Anmeldung gewartet hat.
  private(set) var pauses: [TimeInterval] = []
  private(set) var seen: [Seen] = []
  private var renewals = 0
  private var devices = 0
  private var session: URLSession?

  func urlSession() -> URLSession {
    if let session { return session }
    let s = CalendarStubURLProtocol.session { [self] req, _ in self.reply(req) }
    session = s
    return s
  }

  lazy var auth: MicrosoftAuth = MicrosoftAuth(
    session: urlSession(), clock: clock, clientId: { [self] in self.clientIdValue }, refreshStore: refresh,
    pause: { [self] seconds in
      self.pauses.append(seconds)
      self.clock.advance(seconds: seconds)
      await self.onPause?(self.pauses.count)
    })

  func setGraph(_ key: String, _ replies: [(Int, Any)]) { graphReplies[key] = replies }

  /// Anfragen an Graph (ohne Token-Endpunkt), in der Reihenfolge der Ankunft.
  var graphSeen: [Seen] { seen.filter { !$0.url.path.hasSuffix("/token") && !$0.url.path.hasSuffix("/devicecode") } }

  func reply(_ req: URLRequest) -> (Int, Data) {
    let body = CalendarStubURLProtocol.lastRawBody ?? Data()
    let url = req.url ?? URL(string: "https://invalid.local/")!
    seen.append(Seen(method: req.httpMethod ?? "GET", url: url, body: String(decoding: body, as: UTF8.self),
                     headers: req.allHTTPHeaderFields ?? [:]))
    let path = url.path
    let (status, json): (Int, Any)
    if path.hasSuffix("/devicecode") {
      devices += 1
      (status, json) = (200, ["device_code": "dev-\(devices)", "user_code": "ABCD-1234",
                              "verification_uri": "https://microsoft.com/devicelogin", "expires_in": deviceExpiresIn,
                              "interval": deviceInterval])
    } else if path.hasSuffix("/token") {
      let grant = MicrosoftChecks.fields(String(decoding: body, as: UTF8.self))["grant_type"] ?? ""
      if !tokenReplies.isEmpty {
        (status, json) = tokenReplies.removeFirst()
      } else if grant == "refresh_token" {
        if let gate = renewGate {
          renewGate = nil
          gate.wait()
        }
        renewals += 1
        (status, json) = (200, ["access_token": "at-\(renewals)", "expires_in": 3600, "refresh_token": "rt-\(renewals + 1)",
                                "scope": grantedScope])
      } else {
        (status, json) = (400, ["error": "authorization_pending"])
      }
    } else {
      let key = "\(req.httpMethod ?? "GET") \(path)"
      if var list = graphReplies[key], let first = list.first {
        if list.count > 1 { list.removeFirst(); graphReplies[key] = list }
        (status, json) = first
      } else {
        (status, json) = (404, ["error": ["code": "ItemNotFound"]])
      }
    }
    return (status, (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
  }

  /// Eine angemeldete Sitzung (Erneuerungs-Token im Speicher), ohne Gerätecode-Ablauf.
  func signedIn() throws {
    try refresh.set("rt-1")
  }
}

enum MicrosoftChecks {
  static let calendarScope = "offline_access User.Read Calendars.ReadWrite"
  static let fullScope = "offline_access User.Read Calendars.ReadWrite Chat.ReadWrite Presence.ReadWrite"

  /// Formularfelder (name=wert, Plus als Leerzeichen, Prozentkodierung aufgelöst).
  static func fields(_ body: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in body.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard let key = parts.first else { continue }
      let raw = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "+", with: " ")
      out[key] = raw.removingPercentEncoding ?? raw
    }
    return out
  }

  static func expectFailure(_ message: String, _ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch {
      let text = (error as? MicrosoftFailure)?.message ?? (error as? CalendarError).map { CalendarSupport.message(for: $0) }
        ?? "\(error)"
      try expectEqual(text, message)
      return
    }
    throw CheckFailure(message: "Es hätte scheitern müssen: \(message)", location: "MicrosoftChecks")
  }

  static let consent = "Deine IT muss Lumi einmal freigeben: Kalender, Chats und Status."

  static func pending() -> (Int, Any) { (400, ["error": "authorization_pending"]) }
  static func tokens(scope: String = fullScope) -> (Int, Any) {
    (200, ["access_token": "at-1", "expires_in": 3600, "refresh_token": "rt-1", "scope": scope])
  }

  /// Anmeldung bis zum Ende: Gerätecode, dann Bestätigung. Liefert das Konto.
  static func signIn(_ h: MicrosoftHarness, replies: [(Int, Any)], includeTeams: Bool = true) async throws -> String {
    h.tokenReplies = replies + [tokens(scope: h.grantedScope)]
    h.setGraph("GET /v1.0/me", [(200, ["id": "me-1", "mail": "felix@contoso.de"])])
    _ = try await h.auth.startSignIn(includeTeams: includeTeams)
    return try await h.auth.finishSignIn()
  }

  /// Wartet (auf der Prüfuhr-unabhängigen Echtzeit), bis `condition` gilt.
  static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CheckFailure(message: "Die Bedingung trat nicht ein", location: "MicrosoftChecks")
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Microsoft: ohne Client-ID kommt der Hinweis auf die Anleitung") {
        let h = MicrosoftHarness()
        h.clientIdValue = ""
        try await expectFailure("Trag zuerst die Client-ID ein – Anleitung unter Verbindungen → Microsoft.") {
          _ = try await h.auth.startSignIn(includeTeams: true)
        }
        try expect(h.seen.isEmpty, "ohne Client-ID wird nichts gesendet")
      },

      CheckCase("Microsoft: Client-ID muss die Form einer App-ID haben") {
        try expect(MicrosoftAuth.isClientId(MicrosoftHarness.clientId))
        try expect(!MicrosoftAuth.isClientId("abc"), "zu kurz")
        try expect(!MicrosoftAuth.isClientId("0f3c9a2e7b1d4c559e1a2d6f8b7c4a10"), "ohne Bindestriche")
        let h = MicrosoftHarness()
        h.clientIdValue = "abc"
        try await expectFailure("Die Client-ID sieht nicht richtig aus (36 Zeichen mit Bindestrichen). Prüfe sie unter Verbindungen → Microsoft.") {
          _ = try await h.auth.startSignIn(includeTeams: true)
        }
        try expect(h.seen.isEmpty)
      },

      CheckCase("Rechte: Kalender fordert nur Kalender an, mit Teams kommen Chat und Presence dazu") {
        let calendar = MicrosoftHarness()
        _ = try await calendar.auth.startSignIn(includeTeams: false)
        let calReq = try expectNotNil(calendar.seen.first)
        try expectEqual(MicrosoftChecks.fields(calReq.body)["scope"], calendarScope)
        try expectEqual(MicrosoftChecks.fields(calReq.body)["client_id"], MicrosoftHarness.clientId)
        let teams = MicrosoftHarness()
        let sign = try await teams.auth.startSignIn(includeTeams: true)
        try expectEqual(sign.userCode, "ABCD-1234")
        try expectEqual(sign.verificationUrl, "https://microsoft.com/devicelogin")
        try expectEqual(sign.expiresInSeconds, 900)
        let req = try expectNotNil(teams.seen.first)
        try expectEqual(req.url.host, "login.microsoftonline.com")
        try expectEqual(req.url.path, "/common/oauth2/v2.0/devicecode")
        try expectEqual(MicrosoftChecks.fields(req.body)["scope"], fullScope)
      },

      CheckCase("Rechte: ohne Teams-Freigabe kommt der Hinweis mit dem Weg zur Anmeldung") {
        let h = MicrosoftHarness()
        h.grantedScope = calendarScope
        _ = try await signIn(h, replies: [pending()], includeTeams: false)
        try await expectFailure("Teams ist nicht freigegeben – melde dich unter Verbindungen → Microsoft mit „Teams-Chats und Status“ an.") {
          try await h.auth.requireScope(MicrosoftAuth.chatScope)
        }
        try await expectFailure("Teams ist nicht freigegeben – melde dich unter Verbindungen → Microsoft mit „Teams-Chats und Status“ an.") {
          try await h.auth.requireScope(MicrosoftAuth.presenceScope)
        }
        let full = MicrosoftHarness()
        _ = try await signIn(full, replies: [pending()])
        try await full.auth.requireScope(MicrosoftAuth.chatScope)
        try await full.auth.requireScope(MicrosoftAuth.presenceScope)
      },

      CheckCase("Gerätecode: Anfrage mit Client-ID und allen Bereichen, Code wird angezeigt") {
        let h = MicrosoftHarness()
        let sign = try await h.auth.startSignIn(includeTeams: true)
        try expectEqual(sign.userCode, "ABCD-1234")
        try expectEqual(sign.verificationUrl, "https://microsoft.com/devicelogin")
        try expectEqual(sign.expiresInSeconds, 900)
        let req = try expectNotNil(h.seen.first)
        try expectEqual(req.url.host, "login.microsoftonline.com")
        try expectEqual(req.url.path, "/common/oauth2/v2.0/devicecode")
        let f = MicrosoftChecks.fields(req.body)
        try expectEqual(f["client_id"], MicrosoftHarness.clientId)
        try expectEqual(f["scope"], "offline_access User.Read Calendars.ReadWrite Chat.ReadWrite Presence.ReadWrite")
      },

      CheckCase("Anmeldung: wartet auf die Bestätigung und legt das Erneuerungs-Token in den Schlüsselbund") {
        let h = MicrosoftHarness()
        let mail = try await signIn(h, replies: [pending(), pending()])
        try expectEqual(mail, "felix@contoso.de")
        try expectEqual(h.pauses, [5, 5, 5], "drei Abfragen im Abstand des Gerätecodes")
        try expectEqual(try h.refresh.get(), "rt-1", "Erneuerungs-Token im Schlüsselbund")
        let polls = h.seen.filter { $0.url.path.hasSuffix("/token") }
        try expectEqual(polls.count, 3)
        try expect(polls.allSatisfy { MicrosoftChecks.fields($0.body)["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" })
        try expect(polls.allSatisfy { MicrosoftChecks.fields($0.body)["device_code"] == "dev-1" })
      },

      CheckCase("Anmeldung: slow_down verlängert den Abstand zwischen den Abfragen") {
        let h = MicrosoftHarness()
        _ = try await signIn(h, replies: [(400, ["error": "slow_down"]), pending()])
        try expectEqual(h.pauses, [5, 10, 10], "nach slow_down fünf Sekunden mehr")
      },

      CheckCase("Anmeldung: ein Abstand unter einer Sekunde gilt als fünf Sekunden") {
        let h = MicrosoftHarness()
        h.deviceInterval = 0
        _ = try await signIn(h, replies: [pending()])
        try expectEqual(h.pauses, [5, 5], "kein Dauerfeuer bei interval 0")
      },

      CheckCase("Anmeldung: abgelaufener Code und abgebrochene Anmeldung sind auf Deutsch") {
        let expired = MicrosoftHarness()
        try await expectFailure("Der Anmeldecode ist abgelaufen. Bitte neu anmelden.") {
          _ = try await signIn(expired, replies: [(400, ["error": "expired_token"])])
        }
        let denied = MicrosoftHarness()
        try await expectFailure("Die Anmeldung wurde abgebrochen.") {
          _ = try await signIn(denied, replies: [(400, ["error": "access_denied"])])
        }
        try expect(try denied.refresh.get() == nil, "nach Abbruch kein Token")
      },

      CheckCase("Abbrechen: die Abfragen enden mit eigenem Hinweis, nichts wird gespeichert") {
        let h = MicrosoftHarness()
        h.tokenReplies = [pending(), pending(), tokens()]
        h.onPause = { n in if n == 2 { h.auth.cancelSignIn() } }
        _ = try await h.auth.startSignIn(includeTeams: true)
        try await expectFailure(MicrosoftAuth.cancelledText) { _ = try await h.auth.finishSignIn() }
        try expectEqual(h.pauses.count, 2, "nach dem Abbruch keine weitere Wartezeit")
        try expectEqual(h.seen.filter { $0.url.path.hasSuffix("/token") }.count, 1, "nur die eine Abfrage vor dem Abbruch")
        try expect(try h.refresh.get() == nil, "kein Token nach Abbruch")
        try expect(!h.auth.isSignedIn())
      },

      CheckCase("Abbrechen: eine neuere Anmeldung beendet die ältere Abfrage") {
        let h = MicrosoftHarness()
        h.tokenReplies = [pending(), tokens()]
        h.onPause = { n in
          if n == 1 { _ = try? await h.auth.startSignIn(includeTeams: true) }
        }
        _ = try await h.auth.startSignIn(includeTeams: true)  // dev-1
        try await expectFailure(MicrosoftAuth.cancelledText) { _ = try await h.auth.finishSignIn() }
        try expect(!h.seen.contains { $0.url.path.hasSuffix("/token") && MicrosoftChecks.fields($0.body)["device_code"] == "dev-1" },
                   "der alte Gerätecode wird nicht mehr abgefragt")
        try expect(try h.refresh.get() == nil)
      },

      CheckCase("Anmeldung: AADSTS65001 nennt die fehlende Freigabe durch die IT") {
        let h = MicrosoftHarness()
        try await expectFailure(consent) {
          _ = try await signIn(h, replies: [(400, ["error": "invalid_grant",
                                                    "error_description": "AADSTS65001: The user or administrator has not consented to use the application."])])
        }
      },

      CheckCase("Anmeldung: fehlt die Mail-Adresse nach dem Speichern, bleibt sie erfolgreich („Microsoft-Konto“)") {
        let h = MicrosoftHarness()
        h.tokenReplies = [tokens()]
        h.setGraph("GET /v1.0/me", [(500, ["error": ["code": "ServiceNotAvailable"]])])
        _ = try await h.auth.startSignIn(includeTeams: true)
        let mail = try await h.auth.finishSignIn()
        try expectEqual(mail, "Microsoft-Konto")
        try expectEqual(try h.refresh.get(), "rt-1", "die Tokens sind trotzdem gespeichert")
      },

      CheckCase("Anmeldung: nach expires_in des Gerätecodes ist Schluss (Prüfuhr)") {
        let h = MicrosoftHarness()
        // Gerätecode mit 60 s Laufzeit und 5 s Abstand, der Nutzer bestätigt nie: zwölf Abfragen, dann Ablauf.
        h.deviceExpiresIn = 60
        _ = try await h.auth.startSignIn(includeTeams: true)
        try await expectFailure("Der Anmeldecode ist abgelaufen. Bitte neu anmelden.") {
          _ = try await h.auth.finishSignIn()
        }
        try expectEqual(h.pauses.count, 12, "60 s / 5 s")
      },

      CheckCase("Erneuerung: das Zugriffs-Token wird 60 s vor Ablauf mit dem Erneuerungs-Token erneuert") {
        let h = MicrosoftHarness()
        _ = try await signIn(h, replies: [pending()])
        let finished = h.clock.now()
        let before = h.seen.count
        // Erstes Token gilt 3600 s: bis 60 s vorher kein neuer Aufruf.
        h.clock.advance(seconds: 3_539)
        let cached = try await h.auth.accessToken()
        try expectEqual(cached, "at-1")
        try expectEqual(h.seen.count, before, "noch gültig, kein Aufruf")
        h.clock.advance(seconds: 1)  // genau 60 s vor Ablauf
        let renewed = try await h.auth.accessToken()
        try expectEqual(renewed, "at-1", "die Erneuerung liefert das nächste Token (Prüfung unten)")
        let refreshCall = try expectNotNil(h.seen.last { MicrosoftChecks.fields($0.body)["grant_type"] == "refresh_token" })
        try expectEqual(MicrosoftChecks.fields(refreshCall.body)["refresh_token"], "rt-1")
        try expect(MicrosoftChecks.fields(refreshCall.body)["scope"] == nil, "die Erneuerung fordert keine Rechte nach")
        try expectEqual(try h.refresh.get(), "rt-2", "gedrehtes Erneuerungs-Token ist im Schlüsselbund")
        try expect(h.clock.now() > finished, "die Prüfuhr ist vorgerückt")
      },

      CheckCase("Erneuerung: parallele Aufrufe teilen sich eine Anfrage") {
        let h = MicrosoftHarness()
        try h.signedIn()
        let gate = DispatchSemaphore(value: 0)
        h.renewGate = gate
        let first = Task { try await h.auth.accessToken() }
        try await waitUntil { h.seen.contains { MicrosoftChecks.fields($0.body)["grant_type"] == "refresh_token" } }
        let second = Task { try await h.auth.accessToken() }
        gate.signal()
        let a = try await first.value
        let b = try await second.value
        try expectEqual(a, "at-1")
        try expectEqual(b, "at-1")
        let refreshes = h.seen.filter { MicrosoftChecks.fields($0.body)["grant_type"] == "refresh_token" }
        try expectEqual(refreshes.count, 1, "eine Erneuerung, kein zweiter Aufruf")
      },

      CheckCase("Erneuerung: Abmelden während der Anfrage schreibt das Token nicht zurück") {
        let h = MicrosoftHarness()
        try h.signedIn()
        let gate = DispatchSemaphore(value: 0)
        h.renewGate = gate
        let running = Task { try await h.auth.accessToken() }
        try await waitUntil { h.seen.contains { MicrosoftChecks.fields($0.body)["grant_type"] == "refresh_token" } }
        try h.auth.signOut()
        gate.signal()
        do {
          _ = try await running.value
          throw CheckFailure(message: "nach Abmelden darf keine Erneuerung gelingen", location: "MicrosoftChecks")
        } catch let f as MicrosoftFailure {
          try expectEqual(f.message, MicrosoftAuth.notSignedInText)
        }
        try expect(try h.refresh.get() == nil, "das gedrehte Token landet nicht im Schlüsselbund")
        try expect(!h.auth.isSignedIn())
      },

      CheckCase("Erneuerung ohne Anmeldung: klare Meldung, kein Netz") {
        let h = MicrosoftHarness()
        try await expectFailure("Nicht bei Microsoft angemeldet. Bitte unter Verbindungen → Microsoft anmelden.") {
          _ = try await h.auth.accessToken()
        }
        try expect(h.seen.isEmpty)
      },

      CheckCase("Abmelden: Schlüsselbund leer, danach kein Zugriff mehr") {
        let h = MicrosoftHarness()
        _ = try await signIn(h, replies: [pending()])
        try expect(h.auth.isSignedIn())
        try h.auth.signOut()
        try expect(!h.auth.isSignedIn())
        try expect(try h.refresh.get() == nil, "Erneuerungs-Token gelöscht")
        try await expectFailure("Nicht bei Microsoft angemeldet. Bitte unter Verbindungen → Microsoft anmelden.") {
          _ = try await h.auth.accessToken()
        }
      },

      CheckCase("Host-Liste: nur login.microsoftonline.com und graph.microsoft.com, nur HTTPS") {
        try expect(MicrosoftHTTP.allowed(URL(string: "https://graph.microsoft.com/v1.0/me")))
        try expect(MicrosoftHTTP.allowed(URL(string: "https://login.microsoftonline.com/common")))
        try expect(!MicrosoftHTTP.allowed(URL(string: "https://evil.example/x")), "fremder Host")
        try expect(!MicrosoftHTTP.allowed(URL(string: "http://graph.microsoft.com/v1.0/me")), "kein HTTPS")
        try expect(!MicrosoftHTTP.allowed(URL(string: "https://graph.microsoft.com.evil.example/")), "Domain-Trick")
        let h = MicrosoftHarness()
        try h.signedIn()
        do {
          _ = try await h.auth.graph("GET", URL(string: "https://evil.example/steal")!)
          throw CheckFailure(message: "fremder Host wurde aufgerufen", location: "MicrosoftChecks")
        } catch let f as MicrosoftFailure {
          try expect(f.message.hasPrefix("Microsoft: Die Adresse wird nicht erlaubt"), f.message)
        }
        try expect(!h.seen.contains { $0.url.host == "evil.example" }, "nie eine Anfrage an den fremden Host")
      },

      CheckCase("Größe: eine Antwort über 5 MB wird abgewiesen") {
        let h = MicrosoftHarness()
        try h.signedIn()
        h.setGraph("GET /v1.0/me", [(200, ["id": String(repeating: "x", count: 5_100_000)])])
        try await expectFailure("Microsoft hat eine zu große Antwort geschickt (mehr als 5 MB). Abgebrochen.") {
          _ = try await h.auth.graph("GET", MicrosoftAuth.graphURL("me"))
        }
      },

      CheckCase("Fehlertext 403: die IT-Freigabe wird genannt") {
        let h = MicrosoftHarness()
        try h.signedIn()
        h.setGraph("GET /v1.0/me", [(403, ["error": ["code": "Forbidden"]])])
        do {
          _ = try await h.auth.graph("GET", MicrosoftAuth.graphURL("me"))
          throw CheckFailure(message: "403 muss scheitern", location: "MicrosoftChecks")
        } catch let f as MicrosoftFailure {
          try expectEqual(f.message, "Microsoft verweigert den Zugriff (403). \(consent)")
        }
      },
    ]
  }
}
