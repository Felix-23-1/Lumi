// Prüfungen für Apple Musik (Skripte per Attrappe, keine echte Musik-App) und die Web-Dienste
// (Adressen, Positivliste, Öffnen per Attrappe). Die Musik-App wird dabei nie berührt.
import Foundation

@MainActor
enum MusicLocalChecks {
  /// Sammelt die geöffneten Adressen (Attrappe für `open`).
  final class URLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
  }

  static func apple(installed: Bool = true, running: Bool = true,
                    answer: @escaping (String) -> ProcessOutput = { _ in ProcessOutput(status: 0) })
    -> (AppleMusicProvider, MediaAndBackupsChecks.ScriptStub) {
    let stub = MediaAndBackupsChecks.ScriptStub(answer)
    let provider = AppleMusicProvider(run: { stub.run($0) }, isInstalled: { installed }, isRunning: { running })
    return (provider, stub)
  }

  static func web(_ service: MusicService, log: URLLog) -> WebMusicProvider {
    WebMusicProvider(service: service, open: { log.add($0) })
  }

  static func code<T>(_ result: ToolResult<T>) -> String? {
    if case .failure(let code, _) = result { return code }
    return nil
  }

  static let attack = "x\" & do shell script \"rm -rf ~"

  static var cases: [CheckCase] {
    [
      CheckCase("YouTube: Suche öffnet www.youtube.com mit kodiertem Suchbegriff") {
        let url = try expectNotNil(WebMusicProvider.searchAddress(.youtube, "Müller & Co #1"))
        try expectEqual(url.absoluteString, "https://www.youtube.com/results?search_query=M%C3%BCller%20%26%20Co%20%231")
        try expect(WebMusicProvider.isAllowed(url), "Host erlaubt")
      },
      CheckCase("Apple Musik: Anführungszeichen mit Combining-Zeichen wird maskiert, Länge begrenzt") {
        let lit = AppleMusicProvider.literal("a\"\u{301}b")
        try expectEqual(lit, "\"a\\\"\u{301}b\"")
        try expect(AppleMusicProvider.literal(String(repeating: "x", count: 500)).count == 202, "auf 200 begrenzt")
      },
      CheckCase("Web-Musik: Benutzerinfo und fremder Port sind nicht erlaubt") {
        try expect(!WebMusicProvider.isAllowed(URL(string: "https://user:pw@music.youtube.com/")!), "userinfo")
        try expect(!WebMusicProvider.isAllowed(URL(string: "https://music.youtube.com:8443/x")!), "port")
        try expect(WebMusicProvider.isAllowed(URL(string: "https://music.youtube.com/search?q=a")!), "normal")
      },
      CheckCase("Apple Musik: Playlist-Ausgabe wird sauber gelesen") {
        let names = AppleMusicProvider.playlists("Hits\n\nRock\tJazz\n  \nHits\n")
        try expectEqual(names.map(\.id), ["Hits", "Rock", "Jazz"], "leere und doppelte Namen fallen weg")
        try expect(names.first?.kind == .playlist, "Art ist Playlist")
        let many = (1...150).map { "P\($0)" }.joined(separator: "\n")
        try expectEqual(AppleMusicProvider.playlists(many).count, 100, "höchstens 100")
      },

      CheckCase("Apple Musik: Titel-Ausgabe wird gelesen, fehlerhafte Zeilen fallen weg") {
        let out = "Lied eins\tKünstler A\tABCDEF0123456789\nkaputt\tnur zwei\n"
          + "Zweites\tB\tzz-nicht-hex\n\tKein Titel\t0123\nDrei\tKünstler C\tAAAAAAAAAAAAAAAA\n"
        let items = AppleMusicProvider.tracks(out)
        try expectEqual(items.map(\.id), ["ABCDEF0123456789", "AAAAAAAAAAAAAAAA"])
        try expectEqual(items.first?.title, "Lied eins")
        try expectEqual(items.first?.subtitle, "Künstler A")
        try expect(items.allSatisfy { $0.kind == .track && $0.service == .appleMusic })
        let twenty = (0..<20).map { String(format: "Titel %d\tA\t%016X", $0, $0 + 1) }.joined(separator: "\n")
        try expectEqual(AppleMusicProvider.tracks(twenty).count, 15, "höchstens 15")
      },

      CheckCase("Apple Musik: Anführungszeichen, Backslash und Zeilenumbrüche werden maskiert") {
        try expectEqual(AppleMusicProvider.literal("Rock \"Hits\""), "\"Rock \\\"Hits\\\"\"")
        try expectEqual(AppleMusicProvider.literal("a\\b"), "\"a\\\\b\"")
        try expectEqual(AppleMusicProvider.literal("zeile\neins\r\nzwei"), "\"zeile eins zwei\"")
        try expectEqual(AppleMusicProvider.literal(attack), "\"x\\\" & do shell script \\\"rm -rf ~\"")
      },

      CheckCase("Apple Musik: Schadtext bleibt beim Abspielen ein reiner Textwert") {
        let (p, stub) = apple()
        let r = await p.play(MusicItem(id: attack, service: .appleMusic, kind: .playlist, title: "x"))
        try expect(r.isOk, "Attrappe antwortet ok")
        let script = stub.scripts.first ?? ""
        try expectEqual(script, "tell application \"Music\" to play playlist " + AppleMusicProvider.literal(attack))
        try expect(!script.contains("script \"rm"), "kein unmaskiertes Anführungszeichen im Skript")
      },

      CheckCase("Apple Musik: Verweigerung (-1743) kommt als deutsche Meldung") {
        let (p, _) = apple(answer: { _ in ProcessOutput(status: 1, stderr: "execution error: Nicht erlaubt. (-1743)") })
        let r = await p.playlists()
        try expectEqual(code(r), "DENIED")
        try expectEqual(r.errorMessage, AppleMusicProvider.deniedText)
        try expect(r.errorMessage?.contains("Automation") == true, "Hinweis auf Automation")
      },

      CheckCase("Apple Musik: fehlende App wird gemeldet, ohne Skript") {
        let (p, stub) = apple(installed: false)
        let s = await p.status()
        try expect(!s.connected, "nicht verbunden")
        let c = await p.connect()
        try expectEqual(c.errorMessage, "Die Musik-App wurde nicht gefunden.")
        let found = await p.search("Hallo")
        try expectEqual(code(found), "NOT_INSTALLED")
        let lists = await p.playlists()
        try expectEqual(code(lists), "NOT_INSTALLED")
        try expectEqual(stub.scripts.count, 0, "kein Skript läuft")
      },

      CheckCase("Apple Musik: läuft die App nicht, wird sie für Suche nicht gestartet") {
        let (p, stub) = apple(running: false)
        let found = await p.search("Hallo")
        try expectEqual(code(found), "NOT_RUNNING")
        let lists = await p.playlists()
        try expectEqual(code(lists), "NOT_RUNNING")
        try expectEqual(stub.scripts.count, 0, "kein Skript läuft")
      },

      CheckCase("Apple Musik: Suche liest Titel und maskiert den Suchtext") {
        let (p, stub) = apple(answer: { _ in ProcessOutput(status: 0, stdout: "Lied\tA\tABCDEF0123456789\n") })
        let r = await p.search("Müller \"x\"")
        try expectEqual(r.value?.map(\.id), ["ABCDEF0123456789"])
        try expectEqual(r.value?.first?.title, "Lied")
        let script = stub.scripts.first ?? ""
        try expect(script.contains("search library playlist 1 for \"Müller \\\"x\\\"\""), "Suchtext maskiert")
        let empty = await p.search("   ")
        try expectEqual(code(empty), "EMPTY")
        try expectEqual(stub.scripts.count, 1, "leere Suche startet kein Skript")
      },

      CheckCase("Apple Musik: Titel wird über die persistente ID abgespielt, unsichere IDs nicht") {
        let (p, stub) = apple()
        let ok = await p.play(MusicItem(id: "ABCDEF0123456789", service: .appleMusic, kind: .track, title: "Lied"))
        try expect(ok.isOk, "gültige ID wird abgespielt")
        try expectEqual(stub.scripts.first ?? "",
                        "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"ABCDEF0123456789\")")
        let bad = await p.play(MusicItem(id: attack, service: .appleMusic, kind: .track, title: "x"))
        try expectEqual(code(bad), "BAD_INPUT")
        try expectEqual(stub.scripts.count, 1, "unsichere ID startet kein Skript")
      },

      CheckCase("Apple Musik: Status und Hinweis") {
        let (p, _) = apple()
        let s = await p.status()
        try expect(s.connected && s.canSearch && s.canListPlaylists && s.canControl, "Fähigkeiten")
        try expectEqual(s.note, "Sucht in deiner Bibliothek und spielt über die Musik-App (bei Apple angemeldet).")
        try expectEqual(s.service, .appleMusic)
        let c = await p.connect()
        try expect(c.isOk, "installiert: verbunden")
      },

      CheckCase("YouTube Music: Suche wird als kodierte Adresse geliefert") {
        let p = web(.youtubeMusic, log: URLLog())
        let r = await p.search("Müller & Söhne #1")
        try expectEqual(r.value?.count, 1)
        try expectEqual(r.value?.first?.id, "https://music.youtube.com/search?q=M%C3%BCller%20%26%20S%C3%B6hne%20%231")
        try expectEqual(r.value?.first?.title, "Im Browser suchen (YouTube Music): Müller & Söhne #1")
        try expect(r.value?.first?.kind == .playlist, "Art Playlist")
        let empty = await p.search(" ")
        try expectEqual(code(empty), "EMPTY")
      },

      CheckCase("Amazon Music: Suche wird kodiert (Plus, Leerzeichen)") {
        let p = web(.amazonMusic, log: URLLog())
        let r = await p.search("a+b c")
        try expectEqual(r.value?.first?.id, "https://music.amazon.de/search/a%2Bb%20c")
        try expectEqual(r.value?.first?.title, "Im Browser suchen (Amazon Music): a+b c")
      },

      CheckCase("Web-Musik: Status ohne Anmeldung und ohne Steuerung, keine Playlists") {
        let p = web(.amazonMusic, log: URLLog())
        let s = await p.status()
        try expect(s.connected && s.canSearch && !s.canListPlaylists && !s.canControl, "Fähigkeiten")
        try expectEqual(s.note, "Öffnet die Suche im Browser oder in der App.")
        let lists = await p.playlists()
        try expectEqual(lists.value?.count, 0)
      },

      CheckCase("Web-Musik: erlaubte https-Adressen werden genau so geöffnet") {
        let log = URLLog()
        let p = web(.youtubeMusic, log: log)
        let allowed = ["https://music.youtube.com/search?q=x", "https://www.youtube.com/watch?v=1",
                       "https://MUSIC.YOUTUBE.COM/", "https://music.amazon.co.uk/search/x"]
        for address in allowed {
          let r = await p.play(MusicItem(id: address, service: .youtubeMusic, kind: .playlist, title: "t"))
          try expect(r.isOk, "erlaubt: \(address)")
        }
        try expectEqual(log.all.map(\.absoluteString), ["https://music.youtube.com/search?q=x",
                                                         "https://www.youtube.com/watch?v=1",
                                                         "https://MUSIC.YOUTUBE.COM/",
                                                         "https://music.amazon.co.uk/search/x"])
      },

      CheckCase("Web-Musik: fremde Hosts, http und Tricks werden nicht geöffnet") {
        let log = URLLog()
        let p = web(.amazonMusic, log: log)
        let blocked = ["https://evil.com/?music.youtube.com", "http://music.youtube.com/search?q=x",
                       "https://music.youtube.com.evil.com/", "https://music.youtube.com@evil.com/",
                       "https://music.amazon.de.evil.net/", "file:///etc/hosts", "javascript:alert(1)", "kein Link"]
        for address in blocked {
          let r = await p.play(MusicItem(id: address, service: .amazonMusic, kind: .playlist, title: "t"))
          try expectEqual(code(r), "BLOCKED", address)
        }
        try expectEqual(log.all.count, 0, "nichts geöffnet")
      },
    ]
  }
}
