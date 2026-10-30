// Prüfungen für Musik (Skriptlauf per Attrappe, keine echte App) und Sicherungen
// (Temp-Ordner, echte SQLite-Dateien). Uhr steuerbar.
import Foundation

@MainActor
enum MediaAndBackupsChecks {
  /// Zeichnet die Skripte auf und antwortet über `answer`.
  final class ScriptStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let answer: (String) -> ProcessOutput

    init(_ answer: @escaping (String) -> ProcessOutput) { self.answer = answer }

    var scripts: [String] {
      lock.lock(); defer { lock.unlock() }
      return recorded
    }

    func run(_ script: String) -> ProcessOutput {
      lock.lock(); recorded.append(script); lock.unlock()
      return answer(script)
    }
  }

  static func tempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "taby-media-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/Backups", withIntermediateDirectories: true)
    return dir
  }

  /// Dienst mit Datei-Datenbank im Temp-Ordner; Musik-Skripte gehen an `stub`.
  static func rig(dir: String, bundles: Set<String> = [],
                  answer: @escaping (String) -> ProcessOutput = { _ in ProcessOutput(status: 0) })
    throws -> (CoreServices, ScriptStub) {
    let stub = ScriptStub(answer)
    var opts = CoreServices.Options(databasePath: dir + "/taby.sqlite", socketPath: nil,
                                    clock: ControllableClock("2026-10-15T08:30"), keyStore: InMemoryApiKeyStore(),
                                    systemNotifier: SinkNotifier(), plannerInterval: nil)
    opts.mediaScriptRunner = { script in stub.run(script) }
    opts.mediaRunningBundles = { bundles }
    return (try CoreServices(options: opts), stub)
  }

  /// Eine vollständige, migrierte Sicherung mit einer Marker-Zeile.
  static func makeBackup(_ dir: String, _ name: String, marker: String) throws {
    let db = try Database.open(path: dir + "/Backups/" + name, clock: ControllableClock("2026-10-14T09:00"))
    try db.execute("CREATE TABLE IF NOT EXISTS marker(v TEXT); DELETE FROM marker; INSERT INTO marker VALUES('\(marker)');")
  }

  static func markers(_ path: String) throws -> [String] {
    let db = try Database.open(path: path, clock: ControllableClock("2026-10-15T09:00"))
    return try db.query("SELECT v FROM marker").map { $0.text("v") }
  }


  static var cases: [CheckCase] {
    [
      CheckCase("Musik: Schnappschuss liest Titel, Interpret, Zustand; Stopp und Lücken fallen weg") {
        let out = "Musik\tSong\tAnna\tplaying\nSpotify\tB\tC\tpaused\nMusik\tX\tY\tstopped\nSpotify\t\tZ\tplaying\nMusik\tOhne\tTab\n"
        try expectEqual(MediaParser.tracks(out), [NowPlaying(title: "Song", artist: "Anna", app: "Musik", playing: true),
                                                  NowPlaying(title: "B", artist: "C", app: "Spotify", playing: false)])
        try expect(MediaParser.tracks("").isEmpty, "leere Ausgabe")
        try expect(MediaParser.tracks("Lied\tAnna\tplaying").isEmpty, "falsches Format")
        try expectEqual(MediaParser.tracks("Musik\tÄrger ♪ 日本\tÉmile\tplaying").first?.title, "Ärger ♪ 日本", "Unicode")
      },
      CheckCase("Benachrichtigung: Music und Spotify werden gelesen, Stopp und Lücken fallen weg") {
        let music: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Anna", "Album": "A", "Total Time": 200000]
        try expectEqual(NowPlayingParser.parse(name: "com.apple.Music.playerInfo", userInfo: music),
                        NowPlaying(title: "Song", artist: "Anna", app: "Musik", playing: true))
        let old: [AnyHashable: Any] = ["Player State": "Paused", "Name": "Alt"]
        try expectEqual(NowPlayingParser.parse(name: "com.apple.iTunes.playerInfo", userInfo: old),
                        NowPlaying(title: "Alt", artist: "", app: "Musik", playing: false))
        let spot: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Lied", "Artist": "Bob", "Duration": 180000]
        try expectEqual(NowPlayingParser.parse(name: "com.spotify.client.PlaybackStateChanged", userInfo: spot),
                        NowPlaying(title: "Lied", artist: "Bob", app: "Spotify", playing: true))
        try expect(NowPlayingParser.parse(name: "com.apple.Music.playerInfo", userInfo: ["Player State": "Stopped", "Name": "Song"]) == nil, "gestoppt")
        try expect(NowPlayingParser.parse(name: "com.apple.Music.playerInfo", userInfo: ["Player State": "Playing"]) == nil, "ohne Titel")
        try expect(NowPlayingParser.parse(name: "com.apple.Music.playerInfo", userInfo: nil) == nil, "ohne Daten")
        try expect(NowPlayingParser.parse(name: "com.example.other", userInfo: music) == nil, "fremde Mitteilung")
        let uni: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Über alles 🎵", "Artist": "Müller"]
        try expectEqual(NowPlayingParser.parse(name: "com.spotify.client.PlaybackStateChanged", userInfo: uni)?.title, "Über alles 🎵")
      },
      CheckCase("Musik: läuft keine App, wird kein Skript gestartet") {
        let (svc, stub) = try rig(dir: try tempDir())
        await svc.refreshNowPlaying()
        let state = await svc.state()
        try expect(state.nowPlaying == nil, "keine Anzeige")
        try expectEqual(stub.scripts.count, 0, "kein Skript")
        let r = await svc.mediaControl(.playPause)
        try expectEqual(r.errorMessage, "Weder Musik noch Spotify läuft.")
        try expectEqual(stub.scripts.count, 0, "auch die Steuerung startet nichts")
      },
      CheckCase("Musik: läuft keine steuerbare App, gehen die Befehle an die Mediatasten des Systems") {
        let dir = try tempDir()
        let sent = LockedBox<[MediaCommand]>([])
        let stub = ScriptStub { _ in ProcessOutput(status: 0) }
        var opts = CoreServices.Options(databasePath: dir + "/taby.sqlite", socketPath: nil,
                                        clock: ControllableClock("2026-10-15T08:30"), keyStore: InMemoryApiKeyStore(),
                                        systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.mediaScriptRunner = { script in stub.run(script) }
        opts.mediaRunningBundles = { [] }
        opts.mediaKeySender = { c in sent.value.append(c); return true }
        let svc = try CoreServices(options: opts)
        let r = await svc.mediaControl(.next)
        try expect(r.isOk, r.errorMessage ?? "")
        try expectEqual(sent.value, [.next])
        try expectEqual(stub.scripts.count, 0, "kein Skript")
        opts.mediaKeySender = { _ in false }
        let denied = try CoreServices(options: opts)
        let d = await denied.mediaControl(.playPause)
        try expect(d.errorMessage?.contains("Bedienungshilfen") == true, d.errorMessage ?? "ok?")
      },
      CheckCase("YouTube im Browser: Titel nur bei eingeschaltetem Schalter, Befehle gehen an die Mediatasten") {
        let dir = try tempDir()
        let suite = "lumi.test.\(UUID().uuidString)"
        let defaults = try expectNotNil(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sent = LockedBox<[MediaCommand]>([])
        let stub = ScriptStub { script in
          script.contains("Google Chrome") ? ProcessOutput(status: 0, stdout: "Posteingang\n(2) Mein Lied - YouTube\nYouTube\n")
            : ProcessOutput(status: 0)
        }
        var opts = CoreServices.Options(databasePath: dir + "/taby.sqlite", socketPath: nil,
                                        clock: ControllableClock("2026-10-15T08:30"), keyStore: InMemoryApiKeyStore(),
                                        systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.mediaScriptRunner = { script in stub.run(script) }
        opts.mediaRunningBundles = { ["com.google.Chrome", "com.spotify.client"] }
        opts.mediaKeySender = { c in sent.value.append(c); return true }
        opts.updateDefaults = defaults
        let svc = try CoreServices(options: opts)
        await svc.musicRefreshNowPlaying()
        let off = await svc.state().nowPlaying
        try expect(off == nil, "aus: kein Browser-Titel")
        try expect(!stub.scripts.contains { $0.contains("Google Chrome") }, "aus: Browser nie gefragt")
        await svc.musicSetBrowserDetection(true)
        let onState = await svc.state().nowPlaying
        let on = try expectNotNil(onState)
        try expectEqual(on.title, "Mein Lied")
        try expectEqual(on.app, "YouTube")
        _ = await svc.mediaControl(.playPause)
        try expectEqual(sent.value, [.playPause])
        let paused = await svc.state().nowPlaying
        try expectEqual(paused?.playing, false, "nach Pause zeigt der Player Pause")
        _ = await svc.mediaControl(.playPause)
        let resumed = await svc.state().nowPlaying
        try expectEqual(resumed?.playing, true, "nach erneutem Druck wieder Spiel")
        sent.value = [.playPause]
        await svc.musicSetBrowserDetection(false)
        let gone = await svc.state().nowPlaying
        try expect(gone == nil, "wieder aus: Titel weg")
      },
      CheckCase("YouTube im Browser: Startseite und fremde Tabs zählen nicht, Präfix „(3)“ fällt weg") {
        try expect(BrowserMedia.parse("YouTube\nNachrichten - Spiegel\n") == nil, "keine Treffer")
        try expectEqual(BrowserMedia.parse("(3) Lied A - YouTube Music\n")?.title, "Lied A")
        try expectEqual(BrowserMedia.parse("Zwei Titel - YouTube\nAnderer - YouTube\n")?.title, "Zwei Titel")
        try expect(BrowserMedia.parse(" - YouTube\n") == nil, "leerer Titel")
      },
      CheckCase("Musik: Ereignis nur bei geändertem Wert") {
        let (svc, _) = try rig(dir: try tempDir())
        var events = 0
        svc.subscribe { if case .stateChanged = $0 { events += 1 } }
        let song: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Anna"]
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: song)
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: song)
        try expectEqual(events, 1, "gleiches Lied zweimal: ein Ereignis")
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: ["Player State": "Paused", "Name": "Song", "Artist": "Anna"])
        try expectEqual(events, 2, "Pause ist eine Änderung")
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: ["Player State": "Stopped"])
        try expectEqual(events, 3, "Stopp ist eine Änderung")
        try expect(svc.media.nowPlaying == nil, "Stopp räumt die Anzeige")
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: ["Player State": "Stopped"])
        try expectEqual(events, 3, "nochmal Stopp: keine Änderung")
      },
      CheckCase("Musik: beendet sich die App, verschwindet ihr Lied") {
        let (svc, _) = try rig(dir: try tempDir())
        let song: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Anna"]
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: song)
        svc.handleMediaNotification(name: "com.spotify.client.PlaybackStateChanged",
                                    userInfo: ["Player State": "Paused", "Name": "Lied", "Artist": "Bob"])
        try expectEqual(svc.media.nowPlaying?.app, "Musik", "spielend vor pausiert")
        svc.handleMediaAppTerminated(bundleId: "com.apple.Music")
        try expectEqual(svc.media.nowPlaying?.app, "Spotify", "Spotify bleibt übrig")
        svc.handleMediaAppTerminated(bundleId: "com.spotify.client")
        try expect(svc.media.nowPlaying == nil, "beide beendet: nichts mehr")
        svc.handleMediaNotification(name: "com.apple.Music.playerInfo", userInfo: song)
        svc.handleMediaAppTerminated(bundleId: "com.example.other")
        try expectEqual(svc.media.nowPlaying?.title, "Song", "fremdes Programm ändert nichts")
      },
      CheckCase("Musik: Beobachtung wird einmal angemeldet, ohne osascript-Aufruf") {
        let (svc, stub) = try rig(dir: try tempDir())
        svc.installMediaObservers()
        let first = svc.media.observer
        svc.installMediaObservers()
        try expect(first != nil && first === svc.media.observer, "einmal angemeldet")
        try expectEqual(stub.scripts.count, 0, "Anmelden startet kein Skript")
      },
      CheckCase("Musik: Start ruft osascript höchstens einmal, ohne offene App gar nicht") {
        let answer: (String) -> ProcessOutput = { s in
          s.contains("lumiOut") ? ProcessOutput(status: 0, stdout: "Spotify\tA\tB\tpaused\nMusik\tC\tD\tplaying") : ProcessOutput(status: 0)
        }
        let (svc, stub) = try rig(dir: try tempDir(), bundles: ["com.spotify.client", "com.apple.Music"], answer: answer)
        await svc.refreshNowPlaying()
        try expectEqual(stub.scripts.count, 1, "beide offen: ein einziger Aufruf")
        let title = await svc.state().nowPlaying?.title
        try expectEqual(title, "C", "spielend gewinnt gegen pausiert")
        let (idle, idleStub) = try rig(dir: try tempDir(), answer: answer)
        await idle.refreshNowPlaying()
        try expectEqual(idleStub.scripts.count, 0, "keine App offen: kein Aufruf")
      },
      CheckCase("Musik: Spotify vor Musik, spielend vor pausiert") {
        let (svc, _) = try rig(dir: try tempDir(), bundles: ["com.spotify.client", "com.apple.Music"],
                               answer: { _ in ProcessOutput(status: 0, stdout: "Spotify\tA\tB\tpaused\nMusik\tC\tD\tplaying") })
        await svc.refreshNowPlaying()
        let title = await svc.state().nowPlaying?.title
        try expectEqual(title, "C", "spielend gewinnt gegen pausiert")
        let (svc2, _) = try rig(dir: try tempDir(), bundles: ["com.spotify.client", "com.apple.Music"],
                                answer: { _ in ProcessOutput(status: 0, stdout: "Spotify\tA\tB\tplaying\nMusik\tC\tD\tplaying") })
        await svc2.refreshNowPlaying()
        let now = await svc2.state().nowPlaying
        try expectEqual(now?.title, "A", "beide spielen: Spotify zuerst")
        try expectEqual(now?.app, "Spotify")
      },
      CheckCase("Musik: Steuerbefehle gehen an die gezeigte App") {
        let answer: (String) -> ProcessOutput = { s in
          if s.contains("return \"ok\"") { return ProcessOutput(status: 0, stdout: "ok") }
          return ProcessOutput(status: 0, stdout: "Musik\tC\tD\tplaying")
        }
        let (svc, stub) = try rig(dir: try tempDir(), bundles: ["com.apple.Music"], answer: answer)
        await svc.refreshNowPlaying()
        let r1 = await svc.mediaControl(.next)
        try expect(r1.isOk, "weiter")
        try expect(stub.scripts.contains { $0.contains("tell application \"Music\" to next track") }, "weiter gesendet")
        let r2 = await svc.mediaControl(.playPause)
        try expect(r2.isOk, "play/pause")
        try expect(stub.scripts.contains { $0.contains("tell application \"Music\" to playpause") }, "play/pause gesendet")
        let r3 = await svc.mediaControl(.previous)
        try expect(r3.isOk, "zurück")
        try expect(stub.scripts.contains { $0.contains("tell application \"Music\" to previous track") }, "zurück gesendet")
      },
      CheckCase("Musik: App beendet sich vor dem Befehl – nichts wird gestartet") {
        // Das Skript meldet "gone": die App lief beim Senden nicht mehr.
        let answer: (String) -> ProcessOutput = { s in
          if s.contains("return \"ok\"") { return ProcessOutput(status: 0, stdout: "gone") }
          return ProcessOutput(status: 0, stdout: "Musik\tC\tD\tplaying")
        }
        let (svc, stub) = try rig(dir: try tempDir(), bundles: ["com.apple.Music"], answer: answer)
        await svc.refreshNowPlaying()
        let r = await svc.mediaControl(.playPause)
        try expectEqual(r.errorMessage, "Weder Musik noch Spotify läuft.")
        try expect(stub.scripts.contains { $0.contains("if application \"Music\" is running then") }, "Laufprüfung im Skript")
      },
      CheckCase("Musik: fehlende Automation meldet den deutschen Hinweis") {
        let answer: (String) -> ProcessOutput = { s in
          s.contains("return \"ok\"")
            ? ProcessOutput(status: 1, stderr: "execution error: Not authorized to send Apple events to Music. (-1743)")
            : ProcessOutput(status: 0, stdout: "Musik\tC\tD\tplaying")
        }
        let (svc, _) = try rig(dir: try tempDir(), bundles: ["com.apple.Music"], answer: answer)
        await svc.refreshNowPlaying()
        let r = await svc.mediaControl(.playPause)
        try expectEqual(r.errorMessage, "Lumi darf Musik/Spotify nicht steuern – Systemeinstellungen → Datenschutz → Automation.")
      },
      CheckCase("Sicherung: Liste neueste zuerst, defekte und fremde Dateien ausgelassen") {
        let dir = try tempDir()
        let b = dir + "/Backups/"
        try "xxx".write(toFile: b + "taby-2026-10-14-0900.sqlite", atomically: true, encoding: .utf8)
        try "yyyy".write(toFile: b + "taby-2026-10-15-0830.sqlite", atomically: true, encoding: .utf8)
        try "zz".write(toFile: b + "taby-broken-2026-10-15-0700.sqlite", atomically: true, encoding: .utf8)
        try "zz".write(toFile: b + "notes.txt", atomically: true, encoding: .utf8)
        let (svc, _) = try rig(dir: dir)
        let list = await svc.listBackups()
        try expectEqual(list.map(\.name), ["taby-2026-10-15-0830.sqlite", "taby-2026-10-14-0900.sqlite"])
        try expectEqual(list.first?.createdAt, "2026-10-15T08:30")
        try expectEqual(list.map(\.sizeBytes), [4, 3])
      },
      CheckCase("Sicherung: ungültige Namen werden abgelehnt") {
        let dir = try tempDir()
        let (svc, _) = try rig(dir: dir)
        for bad in ["../taby-2026-10-14-0900.sqlite", "taby-broken-2026-10-14-0900.sqlite",
                    "taby-2026-10-14-0900.sqlite.bak", "taby-2026-10-14-09x0.sqlite", "/etc/passwd"] {
          let r = await svc.restoreBackup(bad)
          try expectEqual(r.errorMessage, "Ungültiger Sicherungsname.", bad)
        }
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "kein Plan geschrieben")
      },
      CheckCase("Sicherung: beschädigte Datei wird nicht eingespielt") {
        let dir = try tempDir()
        try "keine Datenbank".write(toFile: dir + "/Backups/taby-2026-10-14-0900.sqlite", atomically: true, encoding: .utf8)
        let (svc, _) = try rig(dir: dir)
        let r = await svc.restoreBackup("taby-2026-10-14-0900.sqlite")
        try expectEqual(r.errorMessage?.hasPrefix("Sicherung ist beschädigt"), true)
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "kein Plan bei defekter Datei")
      },
      CheckCase("Umzug: Export auf Mac A, Import auf Mac B bringt die Notiz mit; Müll wird abgelehnt") {
        let a = try tempDir(), b = try tempDir(), out = try tempDir() + "/Stick"
        let (svcA, _) = try rig(dir: a)
        _ = await svcA.addNote(title: "Umzug", content: "bleibt erhalten")
        let exported = await svcA.exportBackup(to: out)
        guard let file = exported.value else { throw CheckFailure(message: "Export: \(exported.errorMessage ?? "?")", location: "") }
        try expect(FileManager.default.fileExists(atPath: file), "Exportdatei liegt im Zielordner")
        try expect(BackupNames.isValid((file as NSString).lastPathComponent), "Name passt zum Sicherungsmuster")
        let (svcB, _) = try rig(dir: b)
        let imported = await svcB.importBackup(from: file)
        guard let name = imported.value else { throw CheckFailure(message: "Import: \(imported.errorMessage ?? "?")", location: "") }
        let listed = await svcB.listBackups().map(\.name)
        try expect(listed.contains(name), "Import erscheint in der Liste")
        let titles = try Database.open(path: b + "/Backups/" + name, clock: ControllableClock("2026-10-15T09:00"))
          .query("SELECT title FROM notes").map { $0.text("title") }
        try expect(titles.contains("Umzug"), "Notiz steckt in der importierten Datei")
        let junk = out + "/müll.sqlite"
        try "kein sqlite".write(toFile: junk, atomically: true, encoding: .utf8)
        let bad = await svcB.importBackup(from: junk)
        try expect(!bad.isOk, "defekte Datei abgelehnt")
        let missing = await svcB.importBackup(from: out + "/fehlt.sqlite")
        try expect(!missing.isOk, "fehlende Datei abgelehnt")
      },
      CheckCase("Sicherung: gleicher Minutenstempel wird nicht überschrieben") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-15-0830.sqlite", marker: "vorlage")
        let (svc, _) = try rig(dir: dir)
        let r = await svc.restoreBackup("taby-2026-10-15-0830.sqlite")
        try expect(r.isOk, "Wiederherstellung trotz gleicher Minute angenommen")
        try expectEqual(try markers(dir + "/Backups/taby-2026-10-15-0830.sqlite"), ["vorlage"], "Vorlage unverändert")
        try expect(FileManager.default.fileExists(atPath: dir + "/Backups/taby-2026-10-15-0830-2.sqlite"), "Vorher-Sicherung mit -2")
      },
      CheckCase("Sicherung: zweite Datei in derselben Minute bekommt -2, dann -3") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-15-0830.sqlite", marker: "erste")
        let (svc, _) = try rig(dir: dir)
        let clock = ControllableClock("2026-10-15T08:30")
        let p2 = try DatabaseBackup.create(svc.store.db, clock: clock)
        let p3 = try DatabaseBackup.create(svc.store.db, clock: clock)
        try expect(p2.hasSuffix("/taby-2026-10-15-0830-2.sqlite"), "zweite: \(p2)")
        try expect(p3.hasSuffix("/taby-2026-10-15-0830-3.sqlite"), "dritte: \(p3)")
        try expectEqual(try markers(dir + "/Backups/taby-2026-10-15-0830.sqlite"), ["erste"], "erste Datei unverändert")
        let list = await svc.listBackups().map(\.name)
        try expectEqual(list, ["taby-2026-10-15-0830-3.sqlite", "taby-2026-10-15-0830-2.sqlite", "taby-2026-10-15-0830.sqlite"], "neueste zuerst")
        try expect(BackupNames.isValid("taby-2026-10-15-0830-2.sqlite"), "Zusatz gültig")
        for bad in ["taby-2026-10-15-0830-.sqlite", "taby-2026-10-15-0830-2/../x.sqlite", "taby-2026-10-15-0830-2x.sqlite"] {
          try expect(!BackupNames.isValid(bad), "abgelehnt: \(bad)")
        }
      },
      CheckCase("Wiederherstellungsplan: älter als 24 Stunden wird verworfen") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-14-0900.sqlite", marker: "backup")
        let db = try Database.open(path: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        try db.execute("CREATE TABLE IF NOT EXISTS marker(v TEXT); DELETE FROM marker; INSERT INTO marker VALUES('live');")
        // Plan von vorgestern, Start heute: nicht anwenden, Datei wegräumen.
        try RestorePlan.write(backup: "taby-2026-10-14-0900.sqlite", dbPath: dir + "/taby.sqlite",
                              clock: ControllableClock("2026-10-13T08:00"))
        RestorePlan.applyIfPending(dbPath: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        try expectEqual(try markers(dir + "/taby.sqlite"), ["live"], "alter Plan: Datenbank bleibt")
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "Plan entfernt")
        // Frischer Plan (vor 2 Stunden) wird angewendet.
        try RestorePlan.write(backup: "taby-2026-10-14-0900.sqlite", dbPath: dir + "/taby.sqlite",
                              clock: ControllableClock("2026-10-15T06:30"))
        RestorePlan.applyIfPending(dbPath: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        try expectEqual(try markers(dir + "/taby.sqlite"), ["backup"], "frischer Plan: Sicherung ist die Datenbank")
      },
      CheckCase("Sicherung: Wiederherstellung greift beim nächsten Öffnen") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-14-0900.sqlite", marker: "backup")
        let (svc, _) = try rig(dir: dir)
        try svc.store.db.execute("CREATE TABLE IF NOT EXISTS marker(v TEXT); DELETE FROM marker; INSERT INTO marker VALUES('live');")
        let r = await svc.restoreBackup("taby-2026-10-14-0900.sqlite")
        try expect(r.isOk, "Wiederherstellung angenommen")
        try expect(FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "Plan geschrieben")
        try expect(FileManager.default.fileExists(atPath: dir + "/Backups/taby-2026-10-15-0830.sqlite"), "aktuelle Datenbank vorher gesichert")
        // Nächster Start: Datei wird vor dem Öffnen ersetzt.
        try expectEqual(try markers(dir + "/taby.sqlite"), ["backup"], "Sicherung ist jetzt die Datenbank")
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "Plan entfernt")
        try expect(FileManager.default.fileExists(atPath: dir + "/taby.sqlite.before-restore"), "alte Datei bleibt 7 Tage")
        try expectEqual(try markers(dir + "/Backups/taby-2026-10-15-0830.sqlite"), ["live"], "Vorher-Sicherung hat den alten Stand")
      },
      CheckCase("Sicherung: Vorlage mit neuerem Schema wird abgelehnt, kein Plan") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-14-0900.sqlite", marker: "backup")
        let bak = try Database.open(path: dir + "/Backups/taby-2026-10-14-0900.sqlite",
                                    clock: ControllableClock("2026-10-14T09:00"))
        try bak.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", [.of(999), .text("2026-10-14T09:00")])
        let (svc, _) = try rig(dir: dir)
        let r = await svc.restoreBackup("taby-2026-10-14-0900.sqlite")
        try expect(!r.isOk, "abgelehnt")
        try expect(r.errorMessage?.contains("neueren Lumi-Version") == true, "klare Meldung")
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "kein Plan geschrieben")
      },
      CheckCase("Sicherung: .before-restore bleibt 7 Tage, danach wird es beim Start entfernt") {
        let dir = try tempDir()
        let db = dir + "/taby.sqlite"
        try Data("alt".utf8).write(to: URL(fileURLWithPath: db + ".before-restore"))
        let old = LocalTime.parse("2026-10-07T08:30") ?? Date()  // 8 Tage vor dem Prüfzeitpunkt
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: db + ".before-restore")
        RestorePlan.purgeOldCopies(dbPath: db, clock: ControllableClock("2026-10-12T08:30"))
        try expect(FileManager.default.fileExists(atPath: db + ".before-restore"), "nach 5 Tagen noch da")
        RestorePlan.purgeOldCopies(dbPath: db, clock: ControllableClock("2026-10-15T08:30"))
        try expect(!FileManager.default.fileExists(atPath: db + ".before-restore"), "nach 8 Tagen weg")
      },
      CheckCase("Sicherung: fehlende Vorlage lässt die Datenbank unverändert") {
        let dir = try tempDir()
        try makeBackup(dir, "taby-2026-10-14-0900.sqlite", marker: "backup")
        let db = try Database.open(path: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        try db.execute("CREATE TABLE IF NOT EXISTS marker(v TEXT); DELETE FROM marker; INSERT INTO marker VALUES('live');")
        try RestorePlan.write(backup: "taby-2026-10-13-0900.sqlite", dbPath: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        RestorePlan.applyIfPending(dbPath: dir + "/taby.sqlite", clock: ControllableClock("2026-10-15T08:30"))
        try expectEqual(try markers(dir + "/taby.sqlite"), ["live"], "Datenbank bleibt")
        try expect(!FileManager.default.fileExists(atPath: dir + "/restore-plan.json"), "Plan trotzdem entfernt")
      },
    ]
  }
}
