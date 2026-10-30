// Prüfungen und Snapshots für den Reiter „Musik“: Logik, Aktionen gegen
// FakeServices (Verbinden, Suchen, Abspielen, Playlists, Fehlerpfad) und die
// Ansicht in den Zuständen nicht verbunden, Treffer, Playlists, Web-Dienste und
// laufender Titel.
import Foundation
import SwiftUI
import TabyCore

enum MusicChecks {
  /// Dieselben Statuswerte wie FakeServices.musicStatus, für vorbelegte Snapshots.
  static func statuses(spotifyConnected: Bool, clientId: String = "") -> [MusicServiceStatus] {
    [
      MusicServiceStatus(service: .spotify, connected: spotifyConnected, canSearch: true, canListPlaylists: true,
                         canControl: true, clientId: clientId, note: "Suche und Wiedergabe brauchen Spotify Premium."),
      MusicServiceStatus(service: .appleMusic, connected: true, canSearch: false, canListPlaylists: true,
                         canControl: true, note: "Lokale Bibliothek der Musik-App."),
      MusicServiceStatus(service: .youtubeMusic, connected: true, canSearch: true, canListPlaylists: false,
                         canControl: false, note: "Nur Öffnen im Browser."),
      MusicServiceStatus(service: .amazonMusic, connected: true, canSearch: true, canListPlaylists: false,
                         canControl: false, note: "Nur Öffnen im Browser."),
    ]
  }

  /// Dieselben Treffer und Playlists wie FakeServices (Spotify).
  static let spotifyHits = [
    MusicItem(id: "spotify:track:1", service: .spotify, kind: .track, title: "Nachtfahrt", subtitle: "Lumen Trio"),
    MusicItem(id: "spotify:track:2", service: .spotify, kind: .track, title: "Sommerregen", subtitle: "Mira Vale"),
    MusicItem(id: "spotify:album:1", service: .spotify, kind: .album, title: "Leise Stadt", subtitle: "Mira Vale"),
    MusicItem(id: "spotify:playlist:1", service: .spotify, kind: .playlist, title: "Fokus Mix", subtitle: "Taby"),
  ]
  static let spotifyPlaylists = ["Morgenmusik", "Konzentration", "Sonntag"].map {
    MusicItem(id: "spotify:playlist:\($0)", service: .spotify, kind: .playlist, title: $0, subtitle: "Spotify")
  }
  static let webHit = MusicItem(id: "https://music.youtube.com/search?q=Nachtfahrt", service: .youtubeMusic,
                                kind: .track, title: "Suche: Nachtfahrt", subtitle: "YouTube Music")

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Musik: Zeilen-Untertitel aus Interpret und Art, ohne leere Teile") {
        let track = MusicItem(id: "1", service: .spotify, kind: .track, title: "A", subtitle: "B")
        try expectEqual(MusicLogic.rowSubtitle(track), "B · Titel")
        let bare = MusicItem(id: "2", service: .youtubeMusic, kind: .playlist, title: "C")
        try expectEqual(MusicLogic.rowSubtitle(bare), "Playlist")
        try expectEqual(MusicLogic.kindSymbol(.album), "square.stack")
      },
      CheckCase("Musik: Web-Dienste zeigen „Öffnet im Browser“, Client-ID-Hinweis nur bei Fehlformat") {
        let web = MusicServiceStatus(service: .youtube, connected: true, canSearch: true, canListPlaylists: false,
                                     canControl: false)
        try expectEqual(MusicLogic.statusBadge(web), "Öffnet im Browser")
        let spotify = MusicServiceStatus(service: .spotify, connected: false, canSearch: false, canListPlaylists: false,
                                         canControl: false)
        try expectEqual(MusicLogic.statusBadge(spotify), "Nicht verbunden")
        try expect(MusicLogic.clientIdHint("") == nil, "leer ohne Hinweis")
        try expect(MusicLogic.clientIdHint("0123456789abcdef0123456789abcdef") == nil, "32 Zeichen passen")
        try expect(MusicLogic.clientIdHint("kurz") != nil, "zu kurz braucht Hinweis")
        try expect(MusicLogic.clientIdHint("0123456789abcdef0123456789abcde-") != nil, "Sonderzeichen braucht Hinweis")
      },
      CheckCase("Musik: Knopftext Abspielen bei steuerbaren Diensten, sonst Öffnen") {
        try expectEqual(MusicLogic.actionTitle(canControl: true), "Abspielen")
        try expectEqual(MusicLogic.actionTitle(canControl: false), "Öffnen")
      },
      CheckCase("Musik: Standarddienst ist der erste verbundene, sonst Spotify") {
        try expectEqual(MusicLogic.defaultService(statuses(spotifyConnected: true)), .spotify)
        try expectEqual(MusicLogic.defaultService(statuses(spotifyConnected: false)), .appleMusic)
        try expectEqual(MusicLogic.defaultService([]), .spotify)
      },
      CheckCase("Musik: gemerkte Auswahl bleibt erhalten, ohne Eintrag keine Auswahl") {
        let suite = UserDefaults(suiteName: "taby.checks.music")!
        suite.removePersistentDomain(forName: "taby.checks.music")
        try expect(MusicLogic.storedService(suite) == nil, "Ohne Eintrag keine Auswahl")
        MusicLogic.remember(.amazonMusic, suite)
        try expectEqual(MusicLogic.storedService(suite), .amazonMusic)
        suite.removePersistentDomain(forName: "taby.checks.music")
      },
      CheckCase("Musik: Cover nur über https, Client-ID nur mit Inhalt, Suche braucht einen Begriff") {
        try expect(MusicLogic.coverURL("https://i.example.org/c.jpg") != nil, "https erlaubt")
        try expect(MusicLogic.coverURL("http://i.example.org/c.jpg") == nil, "http abgelehnt")
        try expect(MusicLogic.coverURL("file:///etc/x.png") == nil, "Datei abgelehnt")
        try expect(MusicLogic.coverURL(nil) == nil, "Ohne Adresse kein Cover")
        try expect(!MusicLogic.canConnect(clientId: "   "), "Leere Client-ID")
        try expect(MusicLogic.canConnect(clientId: " abc "), "Client-ID mit Inhalt")
        try expect(MusicLogic.searchProblem("  ") != nil, "Leerer Begriff")
        try expect(MusicLogic.searchProblem("Lumen") == nil, "Begriff gültig")
        try expectEqual(MusicLogic.emptyText(" Lumen "), "Keine Treffer für „Lumen“.")
      },
      CheckCase("Musik: höchstens 50 Playlists, Redirect-URI und drei Anleitungsschritte wie vorgegeben") {
        let many = (1...60).map { MusicItem(id: "p\($0)", service: .spotify, kind: .playlist, title: "P\($0)") }
        try expectEqual(MusicLogic.limited(many).count, 50)
        try expectEqual(MusicLogic.redirectLine(),
                        "Redirect-URI zum Eintragen in deiner Spotify-App: http://127.0.0.1:8898/callback")
        try expectEqual(MusicLogic.setupSteps.count, 3)
      },
      CheckCase("Musik: Effekt-Wahl aus Text, unbekannt oder leer ist Aus; Standard Liedtext aus") {
        try expectEqual(MusicEffect.parse("bars"), .bars)
        try expectEqual(MusicEffect.parse("glow"), .glow)
        try expectEqual(MusicEffect.parse("quatsch"), .off)
        try expectEqual(MusicEffect.parse(nil), .off)
        let suite = UserDefaults(suiteName: "taby.checks.music.prefs")!
        suite.removePersistentDomain(forName: "taby.checks.music.prefs")
        try expect(!MusicLogic.lyricsEnabled(suite), "Liedtext standardmäßig aus")
        try expectEqual(MusicLogic.storedEffect(suite), .off)
        suite.set(true, forKey: MusicLogic.lyricsKey)
        suite.set("waves", forKey: MusicLogic.effectKey)
        try expect(MusicLogic.lyricsEnabled(suite), "Liedtext an")
        try expectEqual(MusicLogic.storedEffect(suite), .waves)
        suite.removePersistentDomain(forName: "taby.checks.music.prefs")
      },
      CheckCase("Musik: Effekt-Berechnung ist rein, begrenzt und bewegt sich; Farbton stabil") {
        let a = MusicLogic.barHeights(count: 20, t: 3.2)
        try expectEqual(a, MusicLogic.barHeights(count: 20, t: 3.2), "gleiche Zeit, gleiche Höhen")
        try expect(a != MusicLogic.barHeights(count: 20, t: 3.9), "Höhen ändern sich mit der Zeit")
        for t in stride(from: 0.0, to: 30, by: 0.37) {
          try expect(MusicLogic.barHeights(count: 16, t: t).allSatisfy { $0 >= 0.12 && $0 <= 1 }, "Höhe im Bereich")
          let g = MusicLogic.glowPulse(t: t)
          try expect(g >= 0.55 - 1e-9 && g <= 1 + 1e-9, "Glühen im Bereich")
          for line in 0..<3 { try expect(abs(MusicLogic.waveOffset(line: line, x: 0.5, t: t)) <= 1, "Welle im Bereich") }
        }
        try expectEqual(MusicLogic.hue("Nachtfahrt"), MusicLogic.hue("Nachtfahrt"))
        try expect(MusicLogic.hue("Nachtfahrt") != MusicLogic.hue("Sommerregen"), "andere Titel, anderer Ton")
        try expect(MusicLogic.hue("x") >= 0 && MusicLogic.hue("x") < 1, "Ton im Bereich")
        try expect(MusicLogic.animates(playing: true, reduceMotion: false), "läuft bei Wiedergabe")
        try expect(!MusicLogic.animates(playing: false, reduceMotion: false), "steht bei Pause")
        try expect(!MusicLogic.animates(playing: true, reduceMotion: true), "steht bei weniger Bewegung")
      },
      CheckCase("Musik: Liedtext-Zustand aus Ergebnis, Knopf nur mit Schalter und Titel") {
        try expectEqual(MusicLogic.lyricsState(.ok("Eins\r\n\nZwei")), .text(["Eins", "", "Zwei"]))
        try expectEqual(MusicLogic.lyricsState(.ok("  \n ")), .empty)
        try expectEqual(MusicLogic.lyricsState(.failure(code: "NOT_FOUND", error: "x")), .empty)
        try expectEqual(MusicLogic.lyricsState(.failure(code: "NET", error: "Offline")), .failed("Offline"))
        try expectEqual(MusicLogic.lyricsMessage(.empty), "Kein Liedtext gefunden.")
        try expect(MusicLogic.lyricsMessage(.text(["a"])) == nil, "Text braucht keine Meldung")
        let np = NowPlaying(title: "Nachtfahrt", artist: "Lumen Trio", app: "Spotify", playing: true)
        try expect(MusicLogic.showsLyricsButton(enabled: true, np: np), "Knopf bei Schalter und Titel")
        try expect(!MusicLogic.showsLyricsButton(enabled: false, np: np), "Schalter aus, kein Knopf")
        try expect(!MusicLogic.showsLyricsButton(enabled: true, np: nil), "Nichts läuft, kein Knopf")
        try expect(MusicLogic.trackKey(np) != MusicLogic.trackKey(NowPlaying(title: "B", artist: "Lumen Trio", app: "Spotify", playing: true)), "Schlüssel je Titel")
      },
      CheckCase("Musik: Liedtext kommt über den Dienst (Fake liefert Beispieltext)") {
        let fake = FakeServices(sample: false)
        let r = await fake.lyrics(artist: "Lumen Trio", title: "Nachtfahrt")
        guard case .text(let lines) = MusicLogic.lyricsState(r) else { try expect(false, "Text erwartet"); return }
        try expect(lines.count >= 5, "Mehrere Zeilen")
      },
      CheckCase("Einstellungen: Seite Musik ist Grundseite unter Lumi, direkt nach Verbindungen") {
        let basic = SettingsPage.visibleSections(advanced: false).flatMap(\.pages)
        try expect(basic.contains(.music), "Musik in der Seitenleiste")
        try expect(!SettingsPage.music.isAdvanced, "Musik ist nicht erweitert")
        try expectEqual(SettingsPage.music.title, "Musik")
        let i = basic.firstIndex(of: .connections)!
        try expectEqual(basic[i + 1], .music)
      },
      CheckCase("Musik verbinden: ohne Client-ID meldet der Fehlerpfad den Grund, danach klappt es") {
        let fake = FakeServices(sample: false)
        fake.musicSpotifyConnected = false
        let model = AppModel(services: fake, preloaded: fake.current)
        let early = await ViewActions.musicConnect(model, .spotify)
        try expectEqual(early, "Client-ID fehlt.")
        let blank = await ViewActions.musicSaveClientId(model, .spotify, "   ")
        try expect(blank != nil, "Leere Client-ID wird abgewiesen")
        let saved = await ViewActions.musicSaveClientId(model, .spotify, " abc123 ")
        try expect(saved == nil, "Client-ID wird gespeichert")
        try expectEqual(fake.musicClientId, "abc123")
        let connected = await ViewActions.musicConnect(model, .spotify)
        try expect(connected == nil, "Verbinden gelingt")
        let after = await model.services.musicStatus()
        try expect(after.first { $0.service == .spotify }?.connected == true, "Spotify danach verbunden")
        try expectEqual(fake.musicCallCount["connect"], 2)
        try expectEqual(fake.musicCallCount["setClientId"], 1, "Nur die gültige Eingabe wird gesendet")
      },
      CheckCase("Musik verbinden: Fehler aus dem Dienst erscheint als Meldung") {
        let fake = FakeServices(sample: false)
        fake.musicSpotifyConnected = false
        fake.musicConnectError = "Anmeldung abgebrochen."
        let model = AppModel(services: fake, preloaded: fake.current)
        _ = await ViewActions.musicSaveClientId(model, .spotify, "abc")
        let failure = await ViewActions.musicConnect(model, .spotify)
        try expectEqual(failure, "Anmeldung abgebrochen.")
        await ViewActions.musicDisconnect(model, .spotify)
        try expectEqual(fake.musicCallCount["disconnect"], 1)
      },
      CheckCase("Musik suchen: Treffer aus Spotify, leere Suche meldet einen Fehler ohne Aufruf") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let before = fake.musicCallCount["search"] ?? 0
        let empty = await ViewActions.musicSearch(model, .spotify, query: "  ")
        try expect(empty.error != nil, "Leere Suche abgewiesen")
        try expectEqual(fake.musicCallCount["search"] ?? 0, before)
        let hit = await ViewActions.musicSearch(model, .spotify, query: "Nachtfahrt")
        try expect(hit.error == nil, "Suche gelingt: \(hit.error ?? "")")
        try expectEqual(hit.items.count, 4)
        try expect(hit.items.allSatisfy { $0.service == .spotify }, "Nur Spotify-Treffer")
        fake.musicSpotifyConnected = false
        let off = await ViewActions.musicSearch(model, .spotify, query: "Nachtfahrt")
        try expect(off.error != nil && off.items.isEmpty, "Ohne Anmeldung kein Treffer, sondern Fehler")
        let apple = await ViewActions.musicSearch(model, .appleMusic, query: "x")
        try expect(apple.error != nil, "Apple Musik: keine Katalogsuche")
      },
      CheckCase("Musik abspielen: Spotify spielt ab, Web-Dienst öffnet, ohne Anmeldung kommt ein Fehler") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let hits = await ViewActions.musicSearch(model, .spotify, query: "Nachtfahrt")
        try expect(!hits.items.isEmpty, "Treffer vorhanden")
        let first = await ViewActions.musicPlay(model, hits.items[0])
        try expect(first == nil, "Abspielen gelingt")
        try expectEqual(fake.musicLastPlayed?.id, hits.items[0].id)
        let web = await ViewActions.musicSearch(model, .youtubeMusic, query: "Nachtfahrt")
        try expect(!web.items.isEmpty, "Web-Treffer vorhanden")
        let opened = await ViewActions.musicPlay(model, web.items[0])
        try expect(opened == nil, "Öffnen gelingt")
        try expectEqual(fake.musicCallCount["play"], 2)
        fake.musicSpotifyConnected = false
        let denied = await ViewActions.musicPlay(model, hits.items[0])
        try expect(denied != nil, "Ohne Anmeldung kein Abspielen")
      },
      CheckCase("Playlists: Spotify und Apple Musik liefern Listen, Web-Dienste keine, Abmeldung meldet Fehler") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let sp = await ViewActions.musicPlaylists(model, .spotify)
        try expectEqual(sp.items.count, 3)
        let apple = await ViewActions.musicPlaylists(model, .appleMusic)
        try expectEqual(apple.items.count, 3)
        let web = await ViewActions.musicPlaylists(model, .youtubeMusic)
        try expectEqual(web.items.count, 0)
        fake.musicSpotifyConnected = false
        let denied = await ViewActions.musicPlaylists(model, .spotify)
        try expect(denied.error != nil && denied.items.isEmpty, "Ohne Anmeldung keine Playlists")
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-music-connect", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: false)
        fake.musicSpotifyConnected = false
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: false), selected: .spotify)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-results", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify,
                                   query: "Nachtfahrt", results: spotifyHits, playlistsOpen: false)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-playlists", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify,
                                   playlists: spotifyPlaylists, playlistsOpen: true)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-web", size: CGSize(width: TabLayout.contentWidth, height: 240)) {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .youtubeMusic,
                                   query: "Nachtfahrt", results: [webHit], playlistsOpen: false)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-effect-lyrics", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let fake = FakeServices(sample: false)
        fake.current.nowPlaying = NowPlaying(title: "Nachtfahrt", artist: "Lumen Trio", app: "Spotify", playing: true)
        let model = AppModel(services: fake, preloaded: fake.current)
        let lines = ["Erste Zeile des Beispieltextes", "Zweite Zeile des Beispieltextes", "", "Refrain, Zeile eins", "Refrain, Zeile zwei"]
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify,
                                   effect: .bars, lyrics: true, lyricsState: .text(lines))
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-effect-glow", size: CGSize(width: TabLayout.contentWidth, height: 260)) {
        let fake = FakeServices(sample: false)
        fake.current.nowPlaying = NowPlaying(title: "Nachtfahrt", artist: "Lumen Trio", app: "Spotify", playing: true)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify,
                                   effect: .glow, lyrics: true)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-effect-waves", size: CGSize(width: TabLayout.contentWidth, height: 260)) {
        let fake = FakeServices(sample: false)
        fake.current.nowPlaying = NowPlaying(title: "Nachtfahrt", artist: "Lumen Trio", app: "Spotify", playing: true)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify, effect: .waves)
        return wrap(MusicView(preview: preview), model)
      },
      SnapshotSpec("view-music-settings-connect", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let fake = FakeServices(sample: false)
        fake.musicSpotifyConnected = false
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: false, clientId: "0123456789abcdef0123456789abcdef"),
                                   selected: .spotify, clientId: "0123456789abcdef0123456789abcdef")
        return wrap(MusicSettingsView(preview: preview).padding(.horizontal, 16)
          .frame(maxHeight: .infinity, alignment: .top), model)
      },
      SnapshotSpec("view-music-settings-connected", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .appleMusic)
        return wrap(MusicSettingsView(preview: preview).padding(.horizontal, 16)
          .frame(maxHeight: .infinity, alignment: .top), model)
      },
      SnapshotSpec("view-music-nowplaying", size: CGSize(width: TabLayout.contentWidth, height: 200)) {
        let fake = FakeServices(sample: false)
        fake.current.nowPlaying = NowPlaying(title: "Nachtfahrt", artist: "Lumen Trio", app: "Spotify", playing: true)
        let model = AppModel(services: fake, preloaded: fake.current)
        let preview = MusicPreview(statuses: statuses(spotifyConnected: true), selected: .spotify,
                                   playlistsOpen: false)
        return wrap(MusicView(preview: preview), model)
      },
    ]
  }
}
