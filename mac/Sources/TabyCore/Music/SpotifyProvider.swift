// Spotify als Musikdienst: Suche, Playlists und Abspielen über die Web-API.
// Anmeldung (PKCE, Loopback) in SpotifyAuth.swift. Das Erneuerungs-Token liegt nur im Schlüsselbund
// (Konto „spotify-refresh“), das Zugriffs-Token nur im Speicher mit Ablaufzeit.
// Die Client-ID ist öffentlich und kommt vom Nutzer (UserDefaults „lumi.spotify.clientId“).
// Zeit nur über die injizierte Uhr. Fehlertexte enthalten nie Token, Codes oder Antworttexte.
// shortcut: parallele Aufrufe können je ein eigenes Zugriffs-Token erneuern, Upgrade bei Bedarf.
import AppKit
import Foundation

final class SpotifyProvider: MusicProvider, @unchecked Sendable {
  static let redirectURI = "http://127.0.0.1:8898/callback"
  static let scopes = "user-read-playback-state user-modify-playback-state playlist-read-private playlist-read-collaborative"
  static let clientIdKey = "lumi.spotify.clientId"
  static let refreshAccount = "spotify-refresh"
  static let maxBody = 2 * 1024 * 1024
  /// Zugriffs-Token wird so viele Sekunden vor Ablauf erneuert.
  static let renewLead: TimeInterval = 60
  static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
  static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
  static let apiBase = "https://api.spotify.com/v1/"

  static let noClientIdNote = "Client-ID aus deiner Spotify-Entwickler-App eintragen"
  static let premiumNote = "Zum Abspielen ist Spotify Premium nötig"
  static let reloginMessage = "Bitte neu anmelden."
  static let notConnected = SpotifyFailure("not_connected", "Nicht bei Spotify angemeldet. Bitte unter Verbindungen → Spotify anmelden.")

  /// Sendet eine Anfrage; liefert Antwortkörper und HTTP-Status.
  typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)
  /// Startet den Listener, ruft `onReady` (Browser öffnen) und liefert die Antwort des Browsers.
  typealias Receive = @Sendable (@escaping @Sendable () -> Void) async throws -> SpotifyCallback

  let service: MusicService = .spotify
  private let defaults: UserDefaults
  private let refreshStore: ApiKeyStore
  private let clock: Clock
  private let send: Send
  private let openURL: @Sendable (URL) -> Void
  private let receive: Receive
  private let lock = NSLock()
  private var access: (token: String, expiresAt: Date)?

  init(defaults: UserDefaults = .standard,
       refreshStore: ApiKeyStore = KeychainApiKeyStore(account: SpotifyProvider.refreshAccount),
       clock: Clock = SystemClock(),
       send: @escaping Send = SpotifyProvider.liveSend,
       openURL: @escaping @Sendable (URL) -> Void = SpotifyProvider.liveOpen,
       receive: @escaping Receive = { try await SpotifyLoopback.receive(onReady: $0) }) {
    self.defaults = defaults
    self.refreshStore = refreshStore
    self.clock = clock
    self.send = send
    self.openURL = openURL
    self.receive = receive
  }

  static let liveSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 15
    cfg.timeoutIntervalForResource = 30
    return URLSession(configuration: cfg)
  }()

  static let liveSend: Send = { request in
    let (bytes, response) = try await liveSession.bytes(for: request)
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > maxBody { throw SpotifyFailure("network", "Die Antwort von Spotify ist zu groß.") }
    }
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  static let liveOpen: @Sendable (URL) -> Void = { url in
    Task { @MainActor in NSWorkspace.shared.open(url) }
  }

  // MARK: - Status und Konto

  var clientId: String {
    (defaults.string(forKey: Self.clientIdKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func setClientId(_ clientId: String) async {
    defaults.set(clientId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIdKey)
  }

  func status() async -> MusicServiceStatus {
    let cid = clientId
    let connected = refreshStore.hasKey()
    return MusicServiceStatus(service: .spotify, connected: connected, canSearch: connected,
                              canListPlaylists: connected, canControl: connected, clientId: cid,
                              note: cid.isEmpty ? Self.noClientIdNote : Self.premiumNote)
  }

  func connect() async -> ToolResult<Empty> {
    let cid = clientId
    guard !cid.isEmpty else { return .failure(code: "no_client_id", error: Self.noClientIdNote) }
    let verifier = SpotifyPKCE.randomToken(bytes: 64)
    let state = SpotifyPKCE.randomToken(bytes: 16)
    var comps = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
    comps?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: cid),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "scope", value: Self.scopes),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: SpotifyPKCE.challenge(for: verifier)),
      URLQueryItem(name: "state", value: state),
    ]
    // Nur diese eine Adresse darf im Browser geöffnet werden.
    guard let url = comps?.url, url.host == "accounts.spotify.com", url.path == "/authorize" else {
      return .failure(code: "failed", error: "Die Anmeldung bei Spotify ist nicht möglich.")
    }
    return await perform {
      let callback = try await self.receive { self.openURL(url) }
      guard callback.state == state else {
        throw SpotifyFailure("state", "Die Anmeldung stimmt nicht überein. Bitte noch einmal versuchen.")
      }
      let (data, status) = try await self.send(Self.tokenRequest([
        ("grant_type", "authorization_code"), ("code", callback.code), ("redirect_uri", Self.redirectURI),
        ("client_id", cid), ("code_verifier", verifier),
      ]))
      guard status == 200, let json = Self.json(data), let refresh = json["refresh_token"] as? String else {
        throw SpotifyFailure("failed", "Die Anmeldung bei Spotify ist fehlgeschlagen.")
      }
      try self.refreshStore.set(refresh)
      _ = self.remember(json, now: self.clock.now())
      return Empty()
    }
  }

  func disconnect() async {
    try? refreshStore.delete()
    lock.withLock { access = nil }
  }

  // MARK: - Suche, Playlists, Abspielen

  func search(_ query: String) async -> ToolResult<[MusicItem]> {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return .ok([]) }
    return await perform {
      let (data, status) = try await self.call("GET", Self.apiURL("search?q=\(SpotifyPKCE.encode(q))&type=track,playlist&limit=10"))
      guard status == 200 else { throw Self.failure(status) }
      return Self.searchItems(Self.json(data) ?? [:])
    }
  }

  func playlists() async -> ToolResult<[MusicItem]> {
    await perform {
      let (data, status) = try await self.call("GET", Self.apiURL("me/playlists?limit=50"))
      guard status == 200 else { throw Self.failure(status) }
      let items = (Self.json(data)?["items"] as? [Any]) ?? []
      return items.compactMap { Self.playlistItem($0) }
    }
  }

  func play(_ item: MusicItem) async -> ToolResult<Empty> {
    guard Self.validURI(item.id) else { return .failure(code: "invalid_uri", error: "Dieser Eintrag kann nicht abgespielt werden.") }
    let kind = item.id.split(separator: ":")[1]
    let body: [String: Any] = kind == "track" ? ["uris": [item.id]] : ["context_uri": item.id]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
      return .failure(code: "invalid_uri", error: "Dieser Eintrag kann nicht abgespielt werden.")
    }
    return await perform {
      let (_, status) = try await self.call("PUT", Self.apiURL("me/player/play"), body: data)
      guard (200...299).contains(status) else { throw Self.failure(status, play: true) }
      return Empty()
    }
  }

  // MARK: - Tokens

  /// Liefert ein gültiges Zugriffs-Token; erneuert es mit dem Erneuerungs-Token, wenn es abgelaufen ist.
  private func accessToken() async throws -> String {
    let now = clock.now()
    if let a = lock.withLock({ access }), a.expiresAt.timeIntervalSince(now) > Self.renewLead {
      return a.token
    }
    guard let refresh = try? refreshStore.get() else { throw Self.notConnected }
    let (data, status) = try await send(Self.tokenRequest([
      ("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientId),
    ]))
    guard status == 200, let json = Self.json(data), json["access_token"] is String else {
      if status == 400 || status == 401 { throw SpotifyFailure("auth", Self.reloginMessage) }
      throw SpotifyFailure("network", "Spotify ist gerade nicht erreichbar.")
    }
    if let rotated = json["refresh_token"] as? String { try refreshStore.set(rotated) }
    return remember(json, now: now)
  }

  /// Speichert das Zugriffs-Token im Speicher und gibt es zurück.
  private func remember(_ json: [String: Any], now: Date) -> String {
    let token = (json["access_token"] as? String) ?? ""
    let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    lock.withLock { access = (token, now.addingTimeInterval(seconds)) }
    return token
  }

  /// Anfrage an die Web-API; bei 401 wird das Token einmal erneuert und die Anfrage wiederholt.
  private func call(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Data, Int) {
    let first = try await accessToken()
    var (data, status) = try await send(Self.request(method, url, token: first, body: body))
    if status == 401 {
      lock.withLock { access = nil }
      let renewed = try await accessToken()
      (data, status) = try await send(Self.request(method, url, token: renewed, body: body))
      if status == 401 { throw SpotifyFailure("auth", Self.reloginMessage) }
    }
    return (data, status)
  }

  /// Führt Arbeit aus und bildet Fehler auf ein ToolResult ab (ohne Token oder Antworttext).
  private func perform<T>(_ work: () async throws -> T) async -> ToolResult<T> {
    do {
      return .ok(try await work())
    } catch let e as SpotifyFailure {
      return .failure(code: e.code, error: e.message)
    } catch {
      return .failure(code: "network", error: "Spotify ist gerade nicht erreichbar.")
    }
  }

  // MARK: - Hilfen (statisch, für Prüfungen)

  static func failure(_ status: Int, play: Bool = false) -> SpotifyFailure {
    switch status {
    case 401: return SpotifyFailure("auth", reloginMessage)
    case 429: return SpotifyFailure("rate", "Spotify bremst gerade, versuch es gleich noch einmal.")
    case 403 where play: return SpotifyFailure("premium", "Dafür ist Spotify Premium nötig.")
    case 404 where play: return SpotifyFailure("no_device", "Öffne Spotify auf diesem Mac und starte dort einmal einen Titel.")
    case 403: return SpotifyFailure("forbidden", "Spotify verweigert den Zugriff (403).")
    default: return SpotifyFailure("failed", "Spotify konnte die Anfrage nicht ausführen (Status \(status)).")
    }
  }

  /// Nur Titel, Playlists und Alben; Form „spotify:track:ID“ mit alphanumerischer Kennung.
  static func validURI(_ uri: String) -> Bool {
    let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "spotify", ["track", "playlist", "album"].contains(String(parts[1])),
          !parts[2].isEmpty else { return false }
    return parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  static func apiURL(_ path: String) -> URL {
    URL(string: apiBase + path)!
  }

  static func request(_ method: String, _ url: URL, token: String, body: Data? = nil) -> URLRequest {
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      r.httpBody = body
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return r
  }

  static func tokenRequest(_ pairs: [(String, String)]) -> URLRequest {
    var r = URLRequest(url: tokenURL)
    r.httpMethod = "POST"
    r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    r.httpBody = SpotifyPKCE.formBody(pairs)
    return r
  }

  static func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// Erstes Cover mit https; alles andere wird verworfen.
  static func cover(_ images: Any?) -> String? {
    ((images as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }.first { $0.hasPrefix("https://") }
  }

  static func trackItem(_ raw: Any?) -> MusicItem? {
    guard let t = raw as? [String: Any], let uri = t["uri"] as? String, let name = t["name"] as? String else { return nil }
    let artists = ((t["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    let album = t["album"] as? [String: Any]
    return MusicItem(id: uri, service: .spotify, kind: .track, title: name,
                     subtitle: artists.joined(separator: ", "), imageURL: cover(album?["images"]))
  }

  static func playlistItem(_ raw: Any?) -> MusicItem? {
    guard let p = raw as? [String: Any], let uri = p["uri"] as? String, let name = p["name"] as? String else { return nil }
    let owner = (p["owner"] as? [String: Any])?["display_name"] as? String ?? ""
    return MusicItem(id: uri, service: .spotify, kind: .playlist, title: name, subtitle: owner, imageURL: cover(p["images"]))
  }

  /// Titel zuerst, dann Playlists. Fehlende oder leere Einträge (Spotify liefert manchmal null) fallen weg.
  static func searchItems(_ json: [String: Any]) -> [MusicItem] {
    let tracks = ((json["tracks"] as? [String: Any])?["items"] as? [Any]) ?? []
    let lists = ((json["playlists"] as? [String: Any])?["items"] as? [Any]) ?? []
    return tracks.compactMap { trackItem($0) } + lists.compactMap { playlistItem($0) }
  }
}
