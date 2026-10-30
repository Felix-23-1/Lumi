// Liedtexte über den freien Dienst lrclib.net (kein Schlüssel, GET /api/get, Feld `plainLyrics`).
// Datenschutz: Interpret und Titel gehen an lrclib.net. Der Aufrufer (UI) holt Texte nur, wenn der Nutzer
// das ausdrücklich eingeschaltet hat. Antworten werden nie geloggt, nur Ereignisse.
// Zwischenspeicher nur im Arbeitsspeicher (50 Eingaben, Treffer und „nicht gefunden“). Keine Zeit nötig.
// shortcut: Zwischenspeicher ohne Ablauf, FIFO statt LRU, Upgrade bei Bedarf.
import Foundation

public final class LyricsProvider: @unchecked Sendable {
  public static let shared = LyricsProvider()

  static let endpoint = URL(string: "https://lrclib.net/api/get")!
  static let userAgent = "Lumi (macOS)"
  static let maxField = 200
  static let maxText = 20000
  static let cacheLimit = 50
  static let notFoundMessage = "Kein Liedtext gefunden."
  static let instrumentalMessage = "Instrumental."
  static let networkMessage = "Liedtext-Dienst nicht erreichbar."

  static let liveSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 8
    cfg.timeoutIntervalForResource = 8
    return URLSession(configuration: cfg)
  }()

  private let session: URLSession
  private let lock = NSLock()
  private var cache: [String: ToolResult<String>] = [:]
  private var order: [String] = []

  init(session: URLSession = LyricsProvider.liveSession) {
    self.session = session
  }

  public func lyrics(artist: String, title: String) async -> ToolResult<String> {
    let a = Self.tidy(artist), t = Self.tidy(title)
    guard !a.isEmpty, !t.isEmpty else {
      return .failure(code: "VALIDATION", error: "Interpret und Titel angeben.")
    }
    let key = "\(a)|\(t)"
    if let hit = lock.withLock({ cache[key] }) { return hit }

    var result = await fetch(artist: a, title: t)
    // Zweiter Versuch nur mit gesäubertem Interpreten/Titel, nur nach „nicht gefunden“.
    let ca = Self.stripFeat(a), ct = Self.stripSuffix(t)
    if case .failure(_, let message) = result, message == Self.notFoundMessage,
       !ca.isEmpty, !ct.isEmpty, (ca, ct) != (a, t) {
      result = await fetch(artist: ca, title: ct)
    }

    if case .failure(let code, _) = result, code == "NETWORK" || code == "PARSE" {
      return result
    }
    store(key, result)
    return result
  }

  // MARK: - Abruf

  private func fetch(artist: String, title: String) async -> ToolResult<String> {
    guard var comps = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else {
      return .failure(code: "NETWORK", error: Self.networkMessage)
    }
    comps.queryItems = [URLQueryItem(name: "artist_name", value: artist),
                        URLQueryItem(name: "track_name", value: title)]
    guard let url = comps.url else { return .failure(code: "NETWORK", error: Self.networkMessage) }
    var request = URLRequest(url: url)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      TabyLog.info(.core, "Liedtext: Dienst nicht erreichbar")
      return .failure(code: "NETWORK", error: Self.networkMessage)
    }
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200: break
    case 404:
      TabyLog.info(.core, "Liedtext: nicht gefunden")
      return .failure(code: "NOT_FOUND", error: Self.notFoundMessage)
    default:
      TabyLog.info(.core, "Liedtext: Dienst antwortet mit Fehler")
      return .failure(code: "NETWORK", error: Self.networkMessage)
    }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      TabyLog.info(.core, "Liedtext: Antwort unlesbar")
      return .failure(code: "PARSE", error: "Liedtext-Antwort unlesbar.")
    }
    if (json["instrumental"] as? Bool) == true {
      return .failure(code: "NOT_FOUND", error: Self.instrumentalMessage)
    }
    let text = ((json["plainLyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .failure(code: "NOT_FOUND", error: Self.notFoundMessage) }
    TabyLog.info(.core, "Liedtext: Treffer")
    return .ok(String(text.prefix(Self.maxText)))
  }

  private func store(_ key: String, _ result: ToolResult<String>) {
    lock.withLock {
      if cache[key] == nil { order.append(key) }
      cache[key] = result
      while order.count > Self.cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
    }
  }

  // MARK: - Säubern

  /// Leerraum zusammenziehen und auf `maxField` Zeichen begrenzen.
  static func tidy(_ text: String) -> String {
    String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(maxField))
  }

  /// Entfernt „feat. …“, „ft. …“ und „featuring …“ beim Interpreten.
  static func stripFeat(_ artist: String) -> String {
    tidy(artist.replacingOccurrences(of: #"\s*[\(\[]?\s*\b(feat|ft|featuring)\b\.?.*$"#,
                                     with: "", options: [.regularExpression, .caseInsensitive]))
  }

  /// Entfernt Klammer-Zusätze am Titelende („(Remastered 2011)“, „[Live]“) und „- Live“ / „- Remastered …“.
  static func stripSuffix(_ title: String) -> String {
    var s = tidy(title)
    while true {
      let next = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
      if next == s { break }
      s = next
    }
    s = s.replacingOccurrences(
      of: #"\s+[-–]\s+.*\b(live|remaster\w*|mono|stereo|demo|version|edit|mix)\b.*$"#,
      with: "", options: [.regularExpression, .caseInsensitive])
    return tidy(s)
  }
}
