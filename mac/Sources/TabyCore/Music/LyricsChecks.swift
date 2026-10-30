// Prüfungen für den Liedtext-Dienst (lrclib.net). HTTP wird über ein eigenes URLProtocol gestubbt,
// kein echtes Netz. Der echte Aufruf von lrclib.net ist nicht geprüft.
import Foundation

/// Gestubbtes HTTP für Liedtexte: Antwort je Anfrage, mitgeschnittene Anfragen.
final class LyricsStubURLProtocol: URLProtocol {
  enum Reply {
    case http(Int, Data)
    case fail
  }

  struct Recorded {
    let url: URL?
    let userAgent: String?
  }

  typealias Handler = (URLRequest) -> Reply
  private static let lock = NSLock()
  private static var handler: Handler?
  private static var recorded: [Recorded] = []

  static func session(_ handler: @escaping Handler) -> URLSession {
    lock.withLock {
      self.handler = handler
      recorded = []
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [LyricsStubURLProtocol.self]
    return URLSession(configuration: cfg)
  }

  static var requests: [Recorded] { lock.withLock { recorded } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let req = request
    let reply: Reply = Self.lock.withLock {
      Self.recorded.append(Recorded(url: req.url, userAgent: req.value(forHTTPHeaderField: "User-Agent")))
      return Self.handler?(req) ?? .fail
    }
    switch reply {
    case .http(let code, let data):
      let url = req.url ?? URL(string: "https://lrclib.net")!
      let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .fail:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
  }

  override func stopLoading() {}
}

enum LyricsChecks {
  /// Zählt Aufrufe in Handlern, ohne dass der Handler ein `var` capturen muss (Swift 6 Sendable).
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
  }

  static func ok(_ text: String = "Zeile eins\nZeile zwei") -> LyricsStubURLProtocol.Reply {
    .http(200, body(["plainLyrics": text, "instrumental": false]))
  }

  static func body(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  static func query(_ url: URL?, _ name: String) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == name }?.value
  }

  static func failure(_ r: ToolResult<String>) -> (code: String, error: String)? {
    if case .failure(let code, let error) = r { return (code, error) }
    return nil
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Liedtext: Treffer liefert den Text, mit Interpret, Titel und User-Agent") {
        let session = LyricsStubURLProtocol.session { _ in ok() }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        try expectEqual(r.value, "Zeile eins\nZeile zwei")
        let sent = LyricsStubURLProtocol.requests
        try expectEqual(sent.count, 1, "ein Treffer braucht genau eine Anfrage")
        try expectEqual(sent.first?.url?.host, "lrclib.net")
        try expectEqual(sent.first?.url?.path, "/api/get")
        try expectEqual(query(sent.first?.url, "artist_name"), "Ab")
        try expectEqual(query(sent.first?.url, "track_name"), "Cd")
        try expectEqual(sent.first?.userAgent, "Lumi (macOS)")
      },

      CheckCase("Liedtext: 404 ist „nicht gefunden“ ohne zweiten Versuch") {
        let session = LyricsStubURLProtocol.session { _ in .http(404, Data()) }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        let f = failure(r)
        try expectEqual(f?.code, "NOT_FOUND")
        try expectEqual(f?.error, "Kein Liedtext gefunden.")
        try expectEqual(LyricsStubURLProtocol.requests.count, 1, "ohne Zusatz keine zweite Anfrage")
      },

      CheckCase("Liedtext: Netzfehler ist NETWORK mit Dienst-Hinweis") {
        let session = LyricsStubURLProtocol.session { _ in .fail }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        try expectEqual(failure(r)?.code, "NETWORK")
        try expectEqual(failure(r)?.error, "Liedtext-Dienst nicht erreichbar.")
      },

      CheckCase("Liedtext: Serverfehler 500 ist NETWORK") {
        let session = LyricsStubURLProtocol.session { _ in .http(500, Data()) }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        try expectEqual(failure(r)?.code, "NETWORK")
      },

      CheckCase("Liedtext: unlesbare Antwort ist PARSE") {
        let session = LyricsStubURLProtocol.session { _ in .http(200, Data("kein json".utf8)) }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        try expectEqual(failure(r)?.code, "PARSE")
      },

      CheckCase("Liedtext: Instrumentalstück liefert Hinweis „Instrumental.“, ohne zweiten Versuch") {
        let session = LyricsStubURLProtocol.session { _ in
          .http(200, body(["instrumental": true, "plainLyrics": NSNull()]))
        }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Song (Remastered 2011)")
        try expectEqual(failure(r)?.code, "NOT_FOUND")
        try expectEqual(failure(r)?.error, "Instrumental.")
        try expectEqual(LyricsStubURLProtocol.requests.count, 1)
      },

      CheckCase("Liedtext: Titel ohne Zusatz im zweiten Versuch") {
        let session = LyricsStubURLProtocol.session { req in
          query(req.url, "track_name")?.contains("(") == true ? .http(404, Data()) : ok()
        }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Song (Remastered 2011)")
        try expectEqual(r.value, "Zeile eins\nZeile zwei")
        let sent = LyricsStubURLProtocol.requests
        try expectEqual(sent.count, 2)
        try expectEqual(query(sent.last?.url, "track_name"), "Song")
      },

      CheckCase("Liedtext: Interpret mit feat. im zweiten Versuch ohne Zusatz") {
        let session = LyricsStubURLProtocol.session { req in
          query(req.url, "artist_name")?.contains("feat") == true ? .http(404, Data()) : ok()
        }
        let r = await LyricsProvider(session: session).lyrics(artist: "Artist feat. Other", title: "Song")
        try expectEqual(r.value, "Zeile eins\nZeile zwei")
        let sent = LyricsStubURLProtocol.requests
        try expectEqual(sent.count, 2)
        try expectEqual(query(sent.last?.url, "artist_name"), "Artist")
      },

      CheckCase("Liedtext: Titelsäuberung entfernt Klammern und „- Live“ am Ende") {
        try expectEqual(LyricsProvider.stripSuffix("Song (Remastered 2011)"), "Song")
        try expectEqual(LyricsProvider.stripSuffix("Song [Live]"), "Song")
        try expectEqual(LyricsProvider.stripSuffix("Song - Live"), "Song")
        try expectEqual(LyricsProvider.stripSuffix("Song - Remastered 2011"), "Song")
        try expectEqual(LyricsProvider.stripSuffix("Song (Live) (Remastered 2011)"), "Song")
        try expectEqual(LyricsProvider.stripSuffix("Rock - Hardcore"), "Rock - Hardcore")
      },

      CheckCase("Liedtext: feat.-Säuberung und Leerraum") {
        try expectEqual(LyricsProvider.stripFeat("Artist (feat. Other)"), "Artist")
        try expectEqual(LyricsProvider.stripFeat("Artist ft. Other"), "Artist")
        try expectEqual(LyricsProvider.stripFeat("Daft Punk"), "Daft Punk")
        try expectEqual(LyricsProvider.tidy("  Ab   Cd  "), "Ab Cd")
      },

      CheckCase("Liedtext: leere Eingabe ist VALIDATION ohne Anfrage") {
        let session = LyricsStubURLProtocol.session { _ in ok() }
        let p = LyricsProvider(session: session)
        let blankArtist = await p.lyrics(artist: "  ", title: "Song")
        let blankTitle = await p.lyrics(artist: "Ab", title: " ")
        try expectEqual(failure(blankArtist)?.code, "VALIDATION")
        try expectEqual(failure(blankTitle)?.code, "VALIDATION")
        try expectEqual(LyricsStubURLProtocol.requests.count, 0, "leere Eingabe fragt nichts ab")
      },

      CheckCase("Liedtext: zweiter Aufruf kommt aus dem Zwischenspeicher") {
        let session = LyricsStubURLProtocol.session { _ in ok() }
        let p = LyricsProvider(session: session)
        let first = await p.lyrics(artist: "Ab", title: "Cd")
        let second = await p.lyrics(artist: "Ab", title: "Cd")
        try expectEqual(first.value, second.value)
        try expectEqual(LyricsStubURLProtocol.requests.count, 1, "kein zweiter Abruf")
      },

      CheckCase("Liedtext: „nicht gefunden“ wird ebenfalls gemerkt") {
        let session = LyricsStubURLProtocol.session { _ in .http(404, Data()) }
        let p = LyricsProvider(session: session)
        _ = await p.lyrics(artist: "Ab", title: "Cd")
        let again = await p.lyrics(artist: "Ab", title: "Cd")
        try expectEqual(failure(again)?.code, "NOT_FOUND")
        try expectEqual(LyricsStubURLProtocol.requests.count, 1)
      },

      CheckCase("Liedtext: Netzfehler wird nicht gemerkt") {
        let counter = Counter()
        let session = LyricsStubURLProtocol.session { _ in counter.next() == 1 ? .fail : ok() }
        let p = LyricsProvider(session: session)
        let first = await p.lyrics(artist: "Ab", title: "Cd")
        let second = await p.lyrics(artist: "Ab", title: "Cd")
        try expectEqual(failure(first)?.code, "NETWORK")
        try expectEqual(second.value, "Zeile eins\nZeile zwei")
        try expectEqual(LyricsStubURLProtocol.requests.count, 2)
      },

      CheckCase("Liedtext: Zwischenspeicher hält höchstens 50 Eingaben") {
        let session = LyricsStubURLProtocol.session { _ in ok() }
        let p = LyricsProvider(session: session)
        for i in 0..<51 { _ = await p.lyrics(artist: "Ab", title: "Titel \(i)") }
        try expectEqual(LyricsStubURLProtocol.requests.count, 51)
        _ = await p.lyrics(artist: "Ab", title: "Titel 50")
        try expectEqual(LyricsStubURLProtocol.requests.count, 51, "jüngster Eintrag bleibt im Speicher")
        _ = await p.lyrics(artist: "Ab", title: "Titel 0")
        try expectEqual(LyricsStubURLProtocol.requests.count, 52, "ältester Eintrag ist herausgefallen")
      },

      CheckCase("Liedtext: Text wird auf 20000 Zeichen gekürzt") {
        let long = String(repeating: "a", count: 25000)
        let session = LyricsStubURLProtocol.session { _ in ok(long) }
        let r = await LyricsProvider(session: session).lyrics(artist: "Ab", title: "Cd")
        try expectEqual(r.value?.count, 20000)
      },
    ]
  }
}
