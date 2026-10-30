// Microsoft-Anmeldung per Gerätecode (OAuth 2.0 Device Code, Mandant „common“).
// Das langlebige Erneuerungs-Token liegt nur im Schlüsselbund (Konto „microsoft-refresh“).
// Das kurzlebige Zugriffs-Token bleibt im Speicher und wird 60 s vor Ablauf erneuert.
// Die gewährten Rechte (Scopes) stehen nur im Speicher; sie kommen aus jeder Token-Antwort.
// Die Client-ID ist öffentlich, kommt aber vom Nutzer aus den Einstellungen (nie im Code).
// Zeit nur über die injizierte Uhr; Warten über `pause`, damit Prüfungen nicht schlafen.
import Foundation

public final class MicrosoftAuth: @unchecked Sendable {
  /// Kalender braucht nur diese Rechte; Teams-Chats und Status kommen dazu, wenn der Nutzer sie wählt.
  public static let calendarScope = "offline_access User.Read Calendars.ReadWrite"
  public static let teamsScope = "Chat.ReadWrite Presence.ReadWrite"
  static let chatScope = "Chat.ReadWrite"
  static let presenceScope = "Presence.ReadWrite"
  static let tokenRenewLead: TimeInterval = 60
  static let deviceCodeURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode")!
  static let tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
  static let notSignedInText = "Nicht bei Microsoft angemeldet. Bitte unter Verbindungen → Microsoft anmelden."
  static let teamsNotReleasedText = "Teams ist nicht freigegeben – melde dich unter Verbindungen → Microsoft mit „Teams-Chats und Status“ an."
  static let cancelledText = "Anmeldung abgebrochen."

  private struct Access {
    let token: String
    let expiresAt: Date
  }

  private struct Pending {
    let deviceCode: String
    let interval: TimeInterval
    let expiresAt: Date
  }

  private let session: URLSession
  private let clock: Clock
  private let clientIdSource: () -> String
  private let refreshStore: ApiKeyStore
  private let pause: (TimeInterval) async -> Void
  private let lock = NSLock()
  private var access: Access?
  private var pending: Pending?
  /// Gewährte Rechte aus der letzten Token-Antwort (nur im Speicher).
  private var granted: Set<String> = []
  /// Eine laufende Erneuerung; parallele Aufrufe warten auf dieselbe.
  private var renewal: Task<String, Error>?
  /// Zählt die Abmeldungen: eine Erneuerung aus einer früheren Sitzung darf nichts mehr speichern.
  private var generation = 0

  /// `clientId` liest die Client-ID aus den Einstellungen. `refreshStore` ist der Schlüsselbund (Prüfungen: Speicher).
  public init(session: URLSession = .shared, clock: Clock = SystemClock(), clientId: @escaping () -> String,
              refreshStore: ApiKeyStore = KeychainApiKeyStore(account: "microsoft-refresh"),
              pause: @escaping (TimeInterval) async -> Void = MicrosoftAuth.sleep) {
    self.session = session
    self.clock = clock
    self.clientIdSource = clientId
    self.refreshStore = refreshStore
    self.pause = pause
  }

  /// Wartet im Echtbetrieb (Prüfungen setzen eine eigene Wartefunktion).
  public static func sleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  /// Form einer Anwendungs-ID: 36 Zeichen, Hex-Ziffern in Gruppen 8-4-4-4-12.
  public static func isClientId(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespaces)
    return s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                   options: .regularExpression) != nil
  }

  /// Graph-Adresse (v1.0) mit bereits kodierten Pfad-Segmenten.
  public static func graphURL(_ path: String, query: [URLQueryItem] = []) -> URL {
    var parts = URLComponents(string: "https://graph.microsoft.com/v1.0/" + path)!
    if !query.isEmpty { parts.queryItems = query }
    return parts.url!
  }

  /// Ein Pfad-Segment (Termin- oder Chat-Kennung) sicher kodiert.
  public static func segment(_ raw: String) -> String {
    raw.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/+="))) ?? raw
  }

  /// Rechte aus dem Feld `scope` der Antwort („https://graph.microsoft.com/Chat.ReadWrite“ zählt als „Chat.ReadWrite“).
  static func grantedNames(_ scope: String) -> Set<String> {
    Set(scope.split(separator: " ").map { String($0.split(separator: "/").last ?? "") })
  }

  func clientId() throws -> String {
    let raw = clientIdSource().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      throw MicrosoftFailure(message: "Trag zuerst die Client-ID ein – Anleitung unter Verbindungen → Microsoft.")
    }
    guard Self.isClientId(raw) else {
      throw MicrosoftFailure(message: "Die Client-ID sieht nicht richtig aus (36 Zeichen mit Bindestrichen). Prüfe sie unter Verbindungen → Microsoft.")
    }
    return raw
  }

  // MARK: - Anmelden

  /// Fordert einen Gerätecode an. Der Nutzer öffnet `verificationUrl` und gibt `userCode` ein.
  /// `includeTeams` fügt Teams-Chats und Status hinzu; ohne sie bekommt Lumi nur den Kalender.
  public func startSignIn(includeTeams: Bool) async throws -> MicrosoftSignIn {
    let cid = try clientId()
    let scope = includeTeams ? "\(Self.calendarScope) \(Self.teamsScope)" : Self.calendarScope
    let (data, http) = try await MicrosoftHTTP.send(session, MicrosoftHTTP.form(Self.deviceCodeURL,
                                                                             [("client_id", cid), ("scope", scope)]))
    let json = MicrosoftHTTP.json(data)
    guard http.statusCode == 200 else { throw MicrosoftHTTP.oauthFailure(json) }
    guard let deviceCode = json?["device_code"] as? String, let userCode = json?["user_code"] as? String,
          let uri = json?["verification_uri"] as? String else {
      throw MicrosoftFailure(message: "Microsoft hat keinen Anmeldecode geschickt.")
    }
    let expires = json?["expires_in"] as? Int ?? 900
    // Ein Abstand unter 1 s wäre ein Dauerfeuer; dann gilt der Standard von 5 s.
    let rawInterval = json?["interval"] as? Int ?? 5
    let interval = TimeInterval(rawInterval < 1 ? 5 : rawInterval)
    lock.withLock {
      pending = Pending(deviceCode: deviceCode, interval: interval,
                        expiresAt: clock.now().addingTimeInterval(TimeInterval(expires)))
    }
    return MicrosoftSignIn(userCode: userCode, verificationUrl: uri, expiresInSeconds: expires)
  }

  /// Wartet, bis der Nutzer den Code bestätigt hat, und gibt das Konto zurück (Mail-Adresse).
  /// Endet vorher, wenn die Anmeldung abgebrochen wird oder eine neuere beginnt.
  public func finishSignIn() async throws -> String {
    guard let first = lock.withLock({ pending }) else {
      throw MicrosoftFailure(message: "Es läuft keine Anmeldung. Bitte zuerst „Anmelden“ drücken.")
    }
    let cid = try clientId()
    let gen = lock.withLock { generation }
    var interval = first.interval
    while clock.now() < first.expiresAt {
      await pause(interval)
      // Nur der Lauf mit dem aktuellen Gerätecode darf weiter abfragen.
      guard lock.withLock({ pending?.deviceCode == first.deviceCode }) else {
        throw MicrosoftFailure(message: Self.cancelledText)
      }
      let (data, http) = try await MicrosoftHTTP.send(session, MicrosoftHTTP.form(Self.tokenURL, [
        ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"), ("client_id", cid), ("device_code", first.deviceCode),
      ]))
      let json = MicrosoftHTTP.json(data)
      if http.statusCode == 200, let token = json?["access_token"] as? String {
        try store(json, token: token, generation: gen)
        lock.withLock { if pending?.deviceCode == first.deviceCode { pending = nil } }
        // Die Tokens stehen schon im Schlüsselbund: fehlt nur die Adresse, ist die Anmeldung trotzdem gelungen.
        do {
          return try await accountMail()
        } catch {
          TabyLog.error(.calendar, "Microsoft: Konto-Adresse nicht gelesen (\((error as? MicrosoftFailure)?.message ?? "Fehler"))")
          return "Microsoft-Konto"
        }
      }
      switch (json?["error"] as? String) ?? "" {
      case "authorization_pending":
        continue
      case "slow_down":
        interval += 5
      case "expired_token":
        lock.withLock { if pending?.deviceCode == first.deviceCode { pending = nil } }
        throw MicrosoftFailure(message: "Der Anmeldecode ist abgelaufen. Bitte neu anmelden.")
      case "access_denied":
        lock.withLock { if pending?.deviceCode == first.deviceCode { pending = nil } }
        throw MicrosoftFailure(message: "Die Anmeldung wurde abgebrochen.")
      default:
        lock.withLock { if pending?.deviceCode == first.deviceCode { pending = nil } }
        throw MicrosoftHTTP.oauthFailure(json)
      }
    }
    lock.withLock { if pending?.deviceCode == first.deviceCode { pending = nil } }
    throw MicrosoftFailure(message: "Der Anmeldecode ist abgelaufen. Bitte neu anmelden.")
  }

  /// Laufende Anmeldung abbrechen (Nutzer hat „Abbrechen“ gedrückt). Die Abfragen enden beim nächsten Takt.
  public func cancelSignIn() {
    lock.withLock { pending = nil }
  }

  // MARK: - Konto und Sitzung

  public func isSignedIn() -> Bool {
    refreshStore.hasKey()
  }

  /// Vergisst die Anmeldung: Schlüsselbund, Zugriffs-Token, Rechte; eine laufende Erneuerung wird verworfen.
  public func signOut() throws {
    lock.withLock {
      generation += 1
      access = nil
      pending = nil
      granted = []
      renewal?.cancel()
      renewal = nil
    }
    do {
      try refreshStore.delete()
    } catch {
      throw MicrosoftFailure(message: "Das Microsoft-Passwort konnte nicht aus dem Schlüsselbund gelöscht werden.")
    }
  }

  /// Gültiges Zugriffs-Token; erneuert es 60 s vor Ablauf. Gleichzeitige Aufrufe teilen sich eine Erneuerung.
  public func accessToken() async throws -> String {
    if let a = lock.withLock({ access }), clock.now() < a.expiresAt.addingTimeInterval(-Self.tokenRenewLead) {
      return a.token
    }
    let task = lock.withLock { () -> Task<String, Error> in
      if let running = renewal { return running }
      let gen = generation
      let started = Task { try await self.renew(generation: gen) }
      renewal = started
      return started
    }
    do {
      return try await task.value
    } catch is CancellationError {
      throw MicrosoftFailure(message: Self.notSignedInText)
    }
  }

  /// Prüft, ob Microsoft das Recht gewährt hat (z. B. `Chat.ReadWrite`); holt dafür ein Token.
  func requireScope(_ name: String) async throws {
    _ = try await accessToken()
    guard lock.withLock({ granted.contains(name) }) else {
      throw MicrosoftFailure(message: Self.teamsNotReleasedText)
    }
  }

  /// Graph-Aufruf mit Token. Nur an erlaubte Adressen, sonst Fehler (vor dem Senden).
  public func graph(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) async throws
    -> (Data, HTTPURLResponse)
  {
    let token = try await accessToken()
    var req = URLRequest(url: try MicrosoftHTTP.checkedURL(url))
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let body {
      req.httpBody = body
      if headers["Content-Type"] == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    }
    let (data, http) = try await MicrosoftHTTP.send(session, req)
    guard (200..<300).contains(http.statusCode) else { throw MicrosoftHTTP.graphFailure(http.statusCode) }
    return (data, http)
  }

  // MARK: - Intern

  /// Erneuert mit dem Erneuerungs-Token. Kein `scope` in der Anfrage: es bleibt bei den gewährten Rechten.
  private func renew(generation gen: Int) async throws -> String {
    defer { lock.withLock { if generation == gen { renewal = nil } } }
    let cid = try clientId()
    guard let refresh = try storedRefresh(), !refresh.isEmpty else {
      throw MicrosoftFailure(message: Self.notSignedInText)
    }
    let (data, http) = try await MicrosoftHTTP.send(session, MicrosoftHTTP.form(Self.tokenURL, [
      ("grant_type", "refresh_token"), ("client_id", cid), ("refresh_token", refresh),
    ]))
    let json = MicrosoftHTTP.json(data)
    guard http.statusCode == 200, let token = json?["access_token"] as? String else {
      if (json?["error"] as? String) == "invalid_grant" {
        throw MicrosoftFailure(message: "Die Microsoft-Anmeldung ist abgelaufen. Bitte unter Verbindungen → Microsoft neu anmelden.")
      }
      throw MicrosoftHTTP.oauthFailure(json)
    }
    try store(json, token: token, generation: gen)
    return token
  }

  /// Zugriffs-Token und Rechte merken; ein neues Erneuerungs-Token (Rotation) geht sofort in den Schlüsselbund.
  /// Gehört die Antwort zu einer früheren Sitzung (Abmeldung dazwischen), wird nichts geschrieben.
  private func store(_ json: [String: Any]?, token: String, generation gen: Int) throws {
    let expires = TimeInterval(json?["expires_in"] as? Int ?? 3600)
    let refresh = json?["refresh_token"] as? String
    try lock.withLock {
      guard generation == gen else { throw MicrosoftFailure(message: Self.notSignedInText) }
      access = Access(token: token, expiresAt: clock.now().addingTimeInterval(expires))
      if let scope = json?["scope"] as? String { granted = Self.grantedNames(scope) }
      if let refresh, !refresh.isEmpty {
        do {
          try refreshStore.set(refresh)
        } catch {
          throw MicrosoftFailure(message: "Die Anmeldung konnte nicht im Schlüsselbund gespeichert werden.")
        }
      }
    }
  }

  private func storedRefresh() throws -> String? {
    do {
      return try refreshStore.get()
    } catch {
      throw MicrosoftFailure(message: "Das Microsoft-Passwort konnte nicht aus dem Schlüsselbund gelesen werden.")
    }
  }

  /// Mail-Adresse des Kontos (Fallback: Anmeldename).
  private func accountMail() async throws -> String {
    let (data, _) = try await graph("GET", Self.graphURL("me", query: [URLQueryItem(name: "$select", value: "mail,userPrincipalName")]))
    let json = MicrosoftHTTP.json(data)
    let mail = (json?["mail"] as? String) ?? ""
    if !mail.isEmpty { return mail }
    return (json?["userPrincipalName"] as? String) ?? "Microsoft-Konto"
  }
}
