// Paket 12: Slack über eine eigene Slack-App des Nutzers (User OAuth Token "xoxp-…").
// Kein App-Verzeichnis, kein OAuth-Server. Lesen: users.conversations/history, Namen:
// users.info; Senden: chat.postMessage. Lese-Marker lokal (conversations.mark bräuchte
// Schreib-Berechtigungen, die die Anleitung nicht vorsieht). Der Token bleibt im
// Schlüsselbund; er steht nur im Authorization-Header, nie in Fehlertexten oder Logs.
import Foundation

/// 429 von Slack: `Retry-After` in Sekunden. Nur intern; öffentliche Aufrufe machen daraus einen Fehlertext.
struct SlackRateLimited: Error { let retryAfter: TimeInterval }

public actor SlackConnector: MessengerConnector, StatusSetting {
  public let service: MessengerService = .slack

  static let apiBase = "https://slack.com/api/"
  /// Unterhaltungen im Zustand (die jüngsten nach Aktivität).
  static let roomLimit = 30
  /// Verlauf-Abrufe je Takt (höchstens 5); die am längsten nicht geholten Räume kommen dran (reihum).
  static let pollPerCycle = 5
  /// Nachrichten je Verlaufsabruf: reicht für Zähler und letzte Nachricht.
  static let historyWindow = 20
  /// Seiten von users.conversations je Takt (je 200 Unterhaltungen); mehr wird nicht geholt.
  /// shortcut: mehr als 1000 Unterhaltungen werden abgeschnitten, Upgrade auf Abruf nach Bedarf.
  static let roomPages = 5
  /// Titel einer DM, deren Name (users.info) noch nicht da ist; wird bei jedem Takt erneut versucht.
  static let directPlaceholder = "Direktnachricht"

  /// Eine Unterhaltung mit dem zuletzt gesehenen Stand (Zwischenspeicher zwischen den Takten).
  private struct Room {
    let id: String
    let isDirect: Bool
    var title: String
    var lastText: String?
    /// Slack-Zeitstempel der neuesten Nachricht ("1700000000.000100").
    var lastTs: String?
    var unread = 0
    /// Takt-Nummer des letzten Verlaufsabrufs (0 = noch nie).
    var fetchTick = 0
  }

  private let session: URLSession
  private let clock: Clock
  private let readMarkers: MessengerReadMarkers
  private var accountId = ""
  private var token = ""
  private var ownUserId = ""
  private var rooms: [String: Room] = [:]
  private var userNames: [String: String] = [:]
  private var tick = 0
  /// Nach 429: bis dahin keine Netzanfragen aus dem Takt.
  private var pausedUntil: Date?

  public init(session: URLSession = .shared, clock: Clock = SystemClock(), readMarkers: MessengerReadMarkers? = nil) {
    self.session = session
    self.clock = clock
    self.readMarkers = readMarkers ?? Self.memoryMarkers()
  }

  // MARK: - Anmeldung

  public func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
    let clean = login.secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw MessengerFailure(message: "Bitte den Slack-Token (xoxp-…) eingeben.") }
    self.accountId = accountId
    token = clean
    let who: (user: String, team: String)
    do { who = try await unlimited { try await self.authTest() } } catch { token = ""; throw error }
    return (MessengerAccount(id: accountId, service: .slack, user: "\(who.user) · \(who.team)"), clean)
  }

  public func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount {
    guard !secret.isEmpty else { throw MessengerFailure(message: "Slack-Token ungültig oder widerrufen.") }
    accountId = account.id
    token = secret
    _ = try await unlimited { try await self.authTest() }
    return account
  }

  /// Slack braucht keinen Schlüssel zum Entsperren.
  public func unlock(recoveryKey: String) async throws {}

  public func logout() async {
    token = ""
    ownUserId = ""
    accountId = ""
    rooms = [:]
    userNames = [:]
    pausedUntil = nil
  }

  // MARK: - Lesen

  public func conversations() async throws -> [MessengerConversation] {
    try requireToken()
    if let until = pausedUntil, clock.now() < until { return output() }
    pausedUntil = nil
    do {
      try await refreshRoomList()
      let batch = tracked().sorted { $0.fetchTick < $1.fetchTick }.prefix(Self.pollPerCycle).map(\.id)
      for id in batch where rooms[id] != nil {
        try await refreshRoom(id)
      }
    } catch let limited as SlackRateLimited {
      pausedUntil = clock.now().addingTimeInterval(limited.retryAfter)
    }
    return output()
  }

  public func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] {
    try requireToken()
    return try await unlimited {
      let json = try await self.call("conversations.history", ["channel": roomId, "limit": "\(max(1, min(limit, 100)))"])
      let raw = (json["messages"] as? [[String: Any]]) ?? []
      // Neueste Nachricht in den Zwischenspeicher, damit markRead den gesehenen Stand speichert.
      if let top = raw.first, let ts = top["ts"] as? String, self.rooms[roomId] != nil {
        self.rooms[roomId]?.lastTs = ts
        self.rooms[roomId]?.lastText = Self.messageText(top)
      }
      var out: [MessengerMessage] = []
      for m in raw.reversed() {  // Slack liefert neueste zuerst; Anzeige älteste zuerst
        guard let ts = m["ts"] as? String else { continue }
        let user = m["user"] as? String
        let mine = user != nil && user == self.ownUserId
        let sender = mine ? "Ich" : try await self.senderName(m)
        out.append(MessengerMessage(id: ts, conversationId: "\(self.accountId)|\(roomId)", sender: sender,
                                    text: Self.messageText(m), at: Self.localDate(ts), mine: mine))
      }
      return out
    }
  }

  public func send(roomId: String, text: String) async throws {
    try requireToken()
    _ = try await unlimited {
      try await self.call("chat.postMessage", ["channel": roomId, "text": text], asJSON: true)
    }
  }

  /// Lesestand lokal: alles bis zur neuesten bekannten Nachricht gilt als gelesen.
  public func markRead(roomId: String) async throws {
    guard let room = rooms[roomId], let ts = room.lastTs, let micros = Self.micros(ts) else { return }
    readMarkers.set("\(accountId)|\(roomId)", micros)
    rooms[roomId]?.unread = 0
  }

  // MARK: - Unterhaltungen laden

  /// Mitgliedschaften aus users.conversations (seitenweise); neue DMs bekommen ihren Namen über users.info.
  private func refreshRoomList() async throws {
    var seen = Set<String>()
    var cursor = ""
    for _ in 0..<Self.roomPages {
      var params = ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200"]
      if !cursor.isEmpty { params["cursor"] = cursor }
      let json = try await call("users.conversations", params)
      for ch in (json["channels"] as? [[String: Any]]) ?? [] {
        guard let id = ch["id"] as? String else { continue }
        let isDirect = ch["is_im"] as? Bool == true
        guard isDirect || ch["is_member"] as? Bool == true else { continue }
        seen.insert(id)
        if let known = rooms[id] {
          // Name war beim ersten Mal nicht abrufbar: erneut versuchen.
          if isDirect, known.title == Self.directPlaceholder, let user = ch["user"] as? String {
            let name = try await userName(user)
            rooms[id]?.title = name
          }
          continue
        }
        var title = Self.channelTitle(ch)
        if isDirect, let user = ch["user"] as? String { title = try await userName(user) }
        rooms[id] = Room(id: id, isDirect: isDirect, title: title)
      }
      cursor = ((json["response_metadata"] as? [String: Any])?["next_cursor"] as? String) ?? ""
      if cursor.isEmpty { break }
    }
    rooms = rooms.filter { seen.contains($0.key) }
  }

  /// Verlauf der Unterhaltung: neue Nachrichten anderer zählen gegen den lokalen Marker.
  private func refreshRoom(_ id: String) async throws {
    tick += 1
    let json = try await call("conversations.history", ["channel": id, "limit": "\(Self.historyWindow)"])
    let raw = (json["messages"] as? [[String: Any]]) ?? []
    let newest = raw.compactMap { m -> (ts: String, micros: Int, text: String)? in
      guard let ts = m["ts"] as? String, let micros = Self.micros(ts) else { return nil }
      return (ts, micros, Self.messageText(m))
    }.max { $0.micros < $1.micros }
    let key = "\(accountId)|\(id)"
    var unread = 0
    if let marker = readMarkers.get(key) {
      unread = raw.filter { m in
        guard let ts = m["ts"] as? String, let micros = Self.micros(ts) else { return false }
        return micros > marker && (m["user"] as? String) != ownUserId
      }.count
    } else if let newest {
      readMarkers.set(key, newest.micros)  // erster Blick: alles Bisherige gilt als gelesen
    }
    guard var room = rooms[id] else { return }
    room.fetchTick = tick
    room.unread = unread
    if let newest {
      room.lastTs = newest.ts
      room.lastText = newest.text
    }
    rooms[id] = room
  }

  /// Die jüngsten Unterhaltungen; noch nie abgefragte zuerst, damit sie einen Stand bekommen.
  private func tracked() -> [Room] {
    Array(rooms.values.sorted { a, b in
      switch (a.lastTs, b.lastTs) {
      case (nil, nil): return a.id < b.id
      case (nil, _): return true
      case (_, nil): return false
      case let (x?, y?): return x > y
      }
    }.prefix(Self.roomLimit))
  }

  private func output() -> [MessengerConversation] {
    tracked().map { r in
      MessengerConversation(id: "\(accountId)|\(r.id)", accountId: accountId, title: r.title, unread: r.unread,
                            lastText: r.lastText, lastAt: r.lastTs.map(Self.localDate), isDirect: r.isDirect)
    }
  }

  // MARK: - Namen

  private func senderName(_ m: [String: Any]) async throws -> String {
    if let user = m["user"] as? String { return try await userName(user) }
    return (m["username"] as? String) ?? "Bot"
  }

  /// users.info mit Zwischenspeicher. Fehler (z. B. unbekannter Nutzer) ergeben "Direktnachricht",
  /// ohne es zu speichern; Rate-Limit reicht der Aufrufer weiter.
  private func userName(_ id: String) async throws -> String {
    if let known = userNames[id] { return known }
    do {
      let json = try await call("users.info", ["user": id])
      let user = json["user"] as? [String: Any]
      let profile = user?["profile"] as? [String: Any]
      let name = Self.nonEmpty(profile?["real_name"] as? String) ?? Self.nonEmpty(user?["real_name"] as? String)
        ?? Self.nonEmpty(user?["name"] as? String) ?? Self.directPlaceholder
      userNames[id] = name
      return name
    } catch let limited as SlackRateLimited {
      throw limited
    } catch {
      return Self.directPlaceholder
    }
  }

  // MARK: - HTTP

  private func authTest() async throws -> (user: String, team: String) {
    let json = try await call("auth.test", [:])
    ownUserId = (json["user_id"] as? String) ?? ""
    return ((json["user"] as? String) ?? "Slack", (json["team"] as? String) ?? "Workspace")
  }

  /// Ein Aufruf der Web-API. 429 wirft `SlackRateLimited`; andere Fehler sind `MessengerFailure`.
  private func call(_ method: String, _ params: [String: String], asJSON: Bool = false) async throws -> [String: Any] {
    var request: URLRequest
    if asJSON {
      request = URLRequest(url: URL(string: Self.apiBase + method)!)
      request.httpMethod = "POST"
      request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: params)
    } else {
      var parts = URLComponents(string: Self.apiBase + method)!
      parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
      request = URLRequest(url: parts.url!)
    }
    let json = try await send(request)
    if json["ok"] as? Bool == true { return json }
    throw Self.slackFailure(json["error"] as? String ?? "unbekannt", needed: json["needed"] as? String)
  }

  /// Eine HTTP-Anfrage mit Token. 429 wirft `SlackRateLimited`; unlesbare Antworten `MessengerFailure`.
  /// Den Ok-Status prüft der Aufrufer.
  private func send(_ request: URLRequest) async throws -> [String: Any] {
    var request = request
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    let data: Data, response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw MessengerFailure(message: "Slack ist gerade nicht erreichbar.")
    }
    if let http = response as? HTTPURLResponse, http.statusCode == 429 {
      let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
      throw SlackRateLimited(retryAfter: wait)
    }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw MessengerFailure(message: "Slack hat eine unlesbare Antwort geschickt.")
    }
    return json
  }

  /// Öffentliche Aufrufe: Rate-Limit wird zu einem verständlichen Fehler.
  private func unlimited<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let limited as SlackRateLimited {
      throw MessengerFailure(message: "Slack bremst gerade. Bitte in \(Int(limited.retryAfter.rounded(.up))) Sekunden erneut versuchen.")
    }
  }

  private func requireToken() throws {
    guard !token.isEmpty else { throw MessengerFailure(message: "Slack ist nicht angemeldet.") }
  }

  // MARK: - Status (Paket „Status automatisch“)

  /// Eigener Status (users.profile.get, Scope users.profile:read).
  public func readStatus() async throws -> (text: String, emoji: String) {
    let json = try await unlimited { try await self.statusCall("users.profile.get", body: nil, scope: "users.profile:read") }
    let profile = json["profile"] as? [String: Any]
    return ((profile?["status_text"] as? String) ?? "", (profile?["status_emoji"] as? String) ?? "")
  }

  /// Status setzen oder mit leerem Text löschen (users.profile.set, Scope users.profile:write).
  public func writeStatus(text: String, emoji: String, until: Date?) async throws {
    let profile: [String: Any] = ["status_text": text, "status_emoji": emoji,
                                  "status_expiration": until.map { Int($0.timeIntervalSince1970) } ?? 0]
    _ = try await unlimited { try await self.statusCall("users.profile.set", body: ["profile": profile], scope: "users.profile:write") }
  }

  /// Statusaufruf: fehlendes Recht wird als deutscher Hinweis mit dem Scope-Namen gemeldet.
  private func statusCall(_ method: String, body: [String: Any]?, scope: String) async throws -> [String: Any] {
    try requireToken()
    var request = URLRequest(url: URL(string: Self.apiBase + method)!)
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let json = try await send(request)
    if json["ok"] as? Bool == true { return json }
    if json["error"] as? String == "missing_scope" {
      throw MessengerFailure(message: "Slack-App braucht das Recht \(scope)")
    }
    throw Self.slackFailure(json["error"] as? String ?? "unbekannt", needed: json["needed"] as? String)
  }

  // MARK: - Hilfen

  static func slackFailure(_ code: String, needed: String?) -> MessengerFailure {
    switch code {
    case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive":
      return MessengerFailure(message: "Slack-Token ungültig oder widerrufen.")
    case "missing_scope":
      if let needed, !needed.isEmpty {
        return MessengerFailure(message: "Dem Slack-Token fehlt die Berechtigung „\(needed)“.")
      }
      return MessengerFailure(message: "Dem Slack-Token fehlt eine Berechtigung (siehe Anleitung).")
    case "not_in_channel":
      return MessengerFailure(message: "Lumi ist in dieser Unterhaltung nicht Mitglied.")
    case "channel_not_found":
      return MessengerFailure(message: "Unterhaltung nicht gefunden.")
    case "rate_limited", "ratelimited":
      return MessengerFailure(message: "Slack bremst gerade. Bitte gleich erneut versuchen.")
    default:
      return MessengerFailure(message: "Slack meldet einen Fehler (\(code)).")
    }
  }

  static func channelTitle(_ ch: [String: Any]) -> String {
    let name = (ch["name"] as? String) ?? ""
    if ch["is_mpim"] as? Bool == true {
      // Gruppen-DM heißt z. B. "mpdm-anna--bob-1".
      let trimmed = name.replacingOccurrences(of: "mpdm-", with: "").replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
      return trimmed.components(separatedBy: "--").joined(separator: ", ")
    }
    return "#\(name)"
  }

  /// Text; Slack-Escapes zurück, leer → "(Anhang)".
  static func messageText(_ m: [String: Any]) -> String {
    let clean = ((m["text"] as? String) ?? "")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? "(Anhang)" : clean
  }

  /// Slack-Zeitstempel "Sekunden.Mikro" → Mikrosekunden als Ganzzahl (exakt, ohne Gleitkomma).
  static func micros(_ ts: String) -> Int? {
    let parts = ts.split(separator: ".", maxSplits: 1)
    guard let sec = parts.first.flatMap({ Int($0) }) else { return nil }
    let frac = parts.count > 1 ? String(parts[1].prefix(6)).padding(toLength: 6, withPad: "0", startingAt: 0) : "000000"
    guard let f = Int(frac) else { return nil }
    return sec * 1_000_000 + f
  }

  static func localDate(_ ts: String) -> String {
    LocalTime.format(Date(timeIntervalSince1970: Double(ts.split(separator: ".").first ?? "0") ?? 0))
  }

  static func nonEmpty(_ s: String?) -> String? {
    let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty ?? true) ? nil : t
  }

  /// Ohne Schlüsselbund-Marker (nur Prüfungen): Marker im Speicher.
  static func memoryMarkers() -> MessengerReadMarkers {
    final class Box: @unchecked Sendable {
      var values: [String: Int] = [:]
      let lock = NSLock()
    }
    let box = Box()
    return MessengerReadMarkers(
      get: { key in box.lock.lock(); defer { box.lock.unlock() }; return box.values[key] },
      set: { key, value in box.lock.lock(); defer { box.lock.unlock() }; box.values[key] = value })
  }
}
