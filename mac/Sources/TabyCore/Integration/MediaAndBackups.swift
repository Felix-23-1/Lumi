// Runde 3: Musik (Apple Music, Spotify per AppleScript) und Datenbank-Sicherungen
// (auflisten, zum nächsten Start wiederherstellen). Skripte laufen über die injizierte
// Skriptausführung; Musik-Apps werden nur gefragt, wenn sie schon laufen (nie gestartet).
import AppKit
import Foundation
import SQLite3

/// Ein Musikprogramm, das Lumi anzeigen und steuern kann.
enum MediaPlayer: CaseIterable {
  case spotify, music

  var bundleId: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
  /// Name in der Oberfläche (NowPlaying.app).
  var appName: String { self == .spotify ? "Spotify" : "Musik" }
  /// Name für AppleScript.
  var scriptName: String { self == .spotify ? "Spotify" : "Music" }

  static let deniedText =
    "Lumi darf Musik/Spotify nicht steuern – Systemeinstellungen → Datenschutz → Automation."

  /// Ein einziges Skript für alle laufenden Programme (ein osascript-Aufruf).
  /// Je Zeile "Musik|Spotify<TAB>Titel<TAB>Interpret<TAB>Zustand"; startet keine App.
  static func snapshotScript(_ players: [MediaPlayer]) -> String {
    var lines = ["set lumiOut to \"\""]
    for p in players {
      lines.append("""
      if application "\(p.scriptName)" is running then
        tell application "\(p.scriptName)"
          if player state is not stopped then set lumiOut to lumiOut & "\(p.appName)" & tab & (name of current track) & tab & (artist of current track) & tab & (player state as text) & linefeed
        end tell
      end if
      """)
    }
    lines.append("return lumiOut")
    return lines.joined(separator: "\n")
  }

  func controlScript(_ command: MediaCommand) -> String {
    let verb: String
    switch command {
    case .playPause: verb = "playpause"
    case .next: verb = "next track"
    case .previous: verb = "previous track"
    }
    // Nur senden, wenn die App im selben Skript noch läuft – `tell` würde sie sonst starten.
    return """
    if application "\(scriptName)" is running then
      tell application "\(scriptName)" to \(verb)
      return "ok"
    end if
    return "gone"
    """
  }
}

enum MediaParser {
  /// Zeilen aus `MediaPlayer.snapshotScript`; angehaltene oder unlesbare Zeilen fallen weg.
  static func tracks(_ stdout: String) -> [NowPlaying] {
    stdout.split(whereSeparator: \.isNewline).compactMap { line -> NowPlaying? in
      let parts = line.components(separatedBy: "\t")
      guard parts.count == 4, ["Musik", "Spotify"].contains(parts[0]),
            !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      let state = parts[3].trimmingCharacters(in: .whitespaces).lowercased()
      guard state == "playing" || state == "paused" else { return nil }
      return NowPlaying(title: parts[1], artist: parts[2], app: parts[0], playing: state == "playing")
    }
  }

  static func isDenied(_ stderr: String) -> Bool {
    stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("Not authorized")
  }
}

/// Benachrichtigungen der Musik-Apps (ereignisgesteuert, kein Abfrage-Takt).
/// Die Payload-Schlüssel sind die der Apps selbst: "Player State", "Name", "Artist".
enum NowPlayingParser {
  /// Anzeigename ("Musik"/"Spotify") zu einem Benachrichtigungsnamen; nil für andere Mitteilungen.
  static func app(forNotification name: String) -> String? {
    switch name {
    case "com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo": return "Musik"
    case "com.spotify.client.PlaybackStateChanged": return "Spotify"
    default: return nil
    }
  }

  /// nil bei "Stopped", fehlendem Titel oder unbekanntem Zustand (das entfernt das Programm aus der Anzeige).
  static func parse(name: String, userInfo: [AnyHashable: Any]?) -> NowPlaying? {
    guard let app = app(forNotification: name), let info = userInfo,
          let state = (info["Player State"] as? String)?.lowercased(),
          state == "playing" || state == "paused",
          let title = info["Name"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let artist = info["Artist"] as? String ?? ""
    return NowPlaying(title: title, artist: artist, app: app, playing: state == "playing")
  }
}

/// Empfängt die Benachrichtigungen und leitet sie an den Dienst weiter (auf dem Hauptthread).
@MainActor
final class MediaObserver: NSObject {
  weak var owner: CoreServices?

  init(owner: CoreServices) {
    self.owner = owner
    super.init()
  }

  @objc func playerChanged(_ note: Notification) {
    owner?.handleMediaNotification(name: note.name.rawValue, userInfo: note.userInfo)
  }

  @objc func appTerminated(_ note: Notification) {
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    owner?.handleMediaAppTerminated(bundleId: app?.bundleIdentifier)
  }
}

/// Laufender Zustand der Musikanzeige (nur im Speicher).
@MainActor
final class MediaState {
  var nowPlaying: NowPlaying?
  /// Letzter bekannter Stand je Programm (Schlüssel: Anzeigename). Nur laufende Programme mit Wiedergabe.
  var byApp: [String: NowPlaying] = [:]
  /// Browser-YouTube: Lumi sieht Pause/Spiel nicht, merkt sich daher den eigenen Pause-Befehl.
  var browserPaused = false
  var observer: MediaObserver?
}

/// Dateinamen der Sicherungen: taby-JJJJ-MM-TT-HHMM.sqlite (siehe DatabaseBackup.stamp).
enum BackupNames {
  /// Optional "-N" (N ≥ 2) für zweite Sicherungen in derselben Minute (siehe DatabaseBackup.freeName).
  static let pattern = #"^taby-\d{4}-\d{2}-\d{2}-\d{4}(-\d+)?\.sqlite$"#

  static func isValid(_ name: String) -> Bool {
    name.range(of: pattern, options: .regularExpression) != nil
  }

  /// "taby-2026-10-15-0830-2.sqlite" → (stamp: "2026-10-15-0830", n: 2); ohne Zusatz n = 1.
  static func key(_ name: String) -> (stamp: String, n: Int) {
    let parts = name.dropFirst(5).dropLast(7).split(separator: "-", omittingEmptySubsequences: false)
    if parts.count == 5 { return (parts[0...3].joined(separator: "-"), Int(parts[4]) ?? 1) }
    return (String(name.dropFirst(5).dropLast(7)), 1)
  }

  /// Zeitliche Reihenfolge (älter zuerst); "-2" gehört nach dem Stamm ohne Zusatz.
  static func isOlder(_ a: String, _ b: String) -> Bool {
    let x = key(a), y = key(b)
    return x.stamp == y.stamp ? x.n < y.n : x.stamp < y.stamp
  }

  /// "taby-2026-10-15-0830.sqlite" → "2026-10-15T08:30"
  static func createdAt(_ name: String) -> String {
    let parts = key(name).stamp.split(separator: "-")
    guard parts.count == 4 else { return "" }
    let time = parts[3]
    return "\(parts[0])-\(parts[1])-\(parts[2])T\(time.prefix(2)):\(time.suffix(2))"
  }
}

/// Prüft eine Sicherung schreibgeschützt mit `PRAGMA quick_check`.
enum BackupCheck {
  /// nil, wenn genau "ok" herauskommt, sonst eine kurze Beschreibung.
  static func integrityProblem(path: String) -> String? {
    var h: OpaquePointer?
    guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      if let h { sqlite3_close_v2(h) }
      return "nicht lesbar"
    }
    defer { sqlite3_close_v2(h) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(h, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
      return errorText(h)
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [String] = []
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_ROW {
        rows.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
      } else if rc == SQLITE_DONE {
        break
      } else {
        return errorText(h)
      }
    }
    if rows == ["ok"] { return nil }
    let text = rows.prefix(3).joined(separator: "; ")
    return text.isEmpty ? "unbekannt" : text
  }

  /// Höchste angewendete Migrationsversion der Sicherung, nur lesend geöffnet (keine Migration darauf).
  /// nil, wenn die Datei nicht lesbar ist; 0, wenn sie noch keine Migrationstabelle hat.
  static func schemaVersion(path: String) -> Int? {
    var h: OpaquePointer?
    guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      if let h { sqlite3_close_v2(h) }
      return nil
    }
    defer { sqlite3_close_v2(h) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(h, "SELECT MAX(version) FROM schema_migrations", -1, &stmt, nil) == SQLITE_OK else {
      return 0  // keine Tabelle: ältere, leere Datei
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(stmt, 0))
  }

  private static func errorText(_ h: OpaquePointer?) -> String {
    sqlite3_errmsg(h).map { String(cString: $0) } ?? "Prüfung fehlgeschlagen"
  }
}

/// Wiederherstellung: Plan-Datei neben der Datenbank, angewendet beim nächsten Öffnen.
public enum RestorePlan {
  /// Gültig 24 Stunden ab `at` (lokaler ISO-Zeitpunkt aus der Uhr).
  struct Plan: Codable { var backup: String; var at: String }
  static let maxAge: TimeInterval = 24 * 3600  // Sekunden

  static func planPath(dbPath: String) -> String {
    ((dbPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("restore-plan.json")
  }

  static func write(backup: String, dbPath: String, clock: Clock) throws {
    let data = try JSONEncoder().encode(Plan(backup: backup, at: LocalTime.format(clock.now())))
    try data.write(to: URL(fileURLWithPath: planPath(dbPath: dbPath)), options: .atomic)
  }

  /// Vor dem Öffnen der Datenbank aufrufen (nicht für ":memory:"). Ersetzt die Datei durch die Sicherung.
  /// Scheitert ein Schritt, bleibt die alte Datei erhalten (Zurückrollen). Der Plan wird immer entfernt.
  static func applyIfPending(dbPath: String, clock: Clock) {
    let fm = FileManager.default
    purgeOldCopies(dbPath: dbPath, clock: clock)
    let plan = planPath(dbPath: dbPath)
    guard let data = fm.contents(atPath: plan) else { return }
    defer { try? fm.removeItem(atPath: plan) }
    guard let p = try? JSONDecoder().decode(Plan.self, from: data), BackupNames.isValid(p.backup) else {
      DatabaseBackup.log("Wiederherstellungsplan ungültig, verworfen")
      return
    }
    // Ein alter Plan (oder ein Plan aus der Zukunft) wird nicht mehr angewendet.
    guard let at = LocalTime.parse(p.at), abs(clock.now().timeIntervalSince(at)) <= RestorePlan.maxAge else {
      DatabaseBackup.log("Wiederherstellungsplan älter als 24 Stunden, verworfen")
      return
    }
    let backup = (DatabaseBackup.directory(for: dbPath) as NSString).appendingPathComponent(p.backup)
    guard fm.fileExists(atPath: backup) else {
      DatabaseBackup.log("Sicherung fehlt")
      return
    }
    let tmp = dbPath + ".restoring"
    let aside = dbPath + ".before-restore"
    try? fm.removeItem(atPath: tmp)
    do {
      try fm.copyItem(atPath: backup, toPath: tmp)
    } catch {
      try? fm.removeItem(atPath: tmp)
      DatabaseBackup.log("Wiederherstellung abgebrochen (Kopie, \(TabyLog.code(error)))")
      return
    }
    // Alte Datei samt WAL/SHM beiseite legen (bleibt zum Zurückrollen, bis alles geklappt hat).
    let suffixes = ["", "-wal", "-shm"]
    do {
      for s in suffixes where fm.fileExists(atPath: dbPath + s) {
        try? fm.removeItem(atPath: aside + s)
        try fm.moveItem(atPath: dbPath + s, toPath: aside + s)
      }
    } catch {
      for s in suffixes where fm.fileExists(atPath: aside + s) {
        try? fm.moveItem(atPath: aside + s, toPath: dbPath + s)
      }
      try? fm.removeItem(atPath: tmp)
      DatabaseBackup.log("Wiederherstellung abgebrochen (Platz machen, \(TabyLog.code(error)))")
      return
    }
    do {
      try fm.moveItem(atPath: tmp, toPath: dbPath)
    } catch {
      for s in suffixes where fm.fileExists(atPath: aside + s) {
        try? fm.moveItem(atPath: aside + s, toPath: dbPath + s)
      }
      try? fm.removeItem(atPath: tmp)
      DatabaseBackup.log("Wiederherstellung zurückgerollt (\(TabyLog.code(error)))")
      return
    }
    // Die alte Datei bleibt 7 Tage als `.before-restore` zum Zurückholen (siehe purgeOldCopies).
    let sidecar = DatabaseBackup.notionSidecar(forBackup: backup)
    if fm.fileExists(atPath: sidecar) {
      let state = ((dbPath as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent(DatabaseBackup.notionStateName)
      try? fm.removeItem(atPath: state)
      try? fm.copyItem(atPath: sidecar, toPath: state)
    }
    DatabaseBackup.log("Sicherung wiederhergestellt")
  }

  /// `.before-restore`-Kopien älter als 7 Tage entfernen (Zeitpunkt aus der Uhr, Änderungsdatum der Datei).
  static func purgeOldCopies(dbPath: String, clock: Clock) {
    let fm = FileManager.default
    for s in ["", "-wal", "-shm"] {
      let path = dbPath + ".before-restore" + s
      guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
      if clock.now().timeIntervalSince(date) > keepBeforeRestoreDays { try? fm.removeItem(atPath: path) }
    }
  }

  static let keepBeforeRestoreDays: TimeInterval = 7 * 24 * 3600

  /// Startet Lumi nach dem Beenden neu: ein kleines Skript wartet auf diesen Prozess und öffnet die App.
  /// Nur für eine gebündelte App (.app); sonst passiert nichts.
  /// Wird erst unmittelbar vor dem Beenden aufgerufen (Oberfläche), damit der Helfer nicht hängen bleibt.
  public static func relaunchAfterQuit(appPath: String) throws {
    guard appPath.hasSuffix(".app") else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"", "sh",
                   String(ProcessInfo.processInfo.processIdentifier), appPath]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
  }
}

extension CoreServices {
  var mediaScriptRunner: @Sendable (String) throws -> ProcessOutput {
    options.mediaScriptRunner ?? IMessageConnector.osascript
  }

  /// Laufende Musikprogramme (Spotify vor Musik). Startet nie eine App.
  func runningMediaPlayers() -> [MediaPlayer] {
    let bundles = options.mediaRunningBundles?()
      ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    return MediaPlayer.allCases.filter { bundles.contains($0.bundleId) }
  }

  /// Liest den Stand per osascript – höchstens ein Aufruf. Nur beim Start und nach einem Steuerbefehl.
  /// Schlägt das Skript fehl, bleibt der bisherige Stand.
  func refreshNowPlaying() async {
    let players = runningMediaPlayers()
    if players.isEmpty {
      media.byApp = [:]
    } else {
      let run = mediaScriptRunner
      let script = MediaPlayer.snapshotScript(players)
      guard let r = try? await Blocking.run({ try run(script) }), r.status == 0 else { return }
      media.byApp = Dictionary(MediaParser.tracks(r.stdout).map { ($0.app, $0) }, uniquingKeysWith: { a, _ in a })
    }
    await refreshBrowserMedia()
    publishNowPlaying()
  }

  /// Spielend vor pausiert, Spotify vor Musik; veröffentlicht nur, wenn sich der Wert ändert.
  func publishNowPlaying() {
    let ordered = MediaPlayer.allCases.compactMap { media.byApp[$0.appName] } + [media.byApp[BrowserMedia.appName]].compactMap { $0 }
    let found = ordered.first(where: \.playing) ?? ordered.first
    guard found != media.nowPlaying else { return }
    media.nowPlaying = found
    emit(.stateChanged)
  }

  /// Beobachtet die Musik-Apps (keine Abfrage, kein Takt). Einmal je Lauf.
  func installMediaObservers() {
    guard media.observer == nil else { return }
    let observer = MediaObserver(owner: self)
    media.observer = observer
    let dnc = DistributedNotificationCenter.default()
    for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
      dnc.addObserver(observer, selector: #selector(MediaObserver.playerChanged(_:)),
                      name: NSNotification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      observer, selector: #selector(MediaObserver.appTerminated(_:)),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil)
  }

  func stopMediaObservers() {
    guard let observer = media.observer else { return }
    DistributedNotificationCenter.default().removeObserver(observer)
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    media.observer = nil
  }

  /// Start: Beobachtung einrichten und einmal lesen, was schon läuft (nur wenn eine App offen ist).
  func startMediaLoop() {
    guard options.plannerInterval != nil else { return }  // Prüfungen laufen ohne Takt
    installMediaObservers()
    Task { @MainActor [weak self] in await self?.refreshNowPlaying() }
  }

  /// Eine Mitteilung einer Musik-App: Stand dieses Programms ersetzen (oder entfernen bei Stopp).
  func handleMediaNotification(name: String, userInfo: [AnyHashable: Any]?) {
    guard let app = NowPlayingParser.app(forNotification: name) else { return }
    media.byApp[app] = NowPlayingParser.parse(name: name, userInfo: userInfo)
    publishNowPlaying()
  }

  /// Beendet sich Musik oder Spotify, verschwindet das Lied.
  func handleMediaAppTerminated(bundleId: String?) {
    guard let player = MediaPlayer.allCases.first(where: { $0.bundleId == bundleId }) else { return }
    media.byApp[player.appName] = nil
    publishNowPlaying()
  }

  public func mediaControl(_ command: MediaCommand) async -> ToolResult<Empty> {
    let running = runningMediaPlayers()
    // Das gerade gezeigte Programm, sonst das erste laufende; YouTube im Browser geht nur über die Mediatasten.
    let browserShown = media.nowPlaying?.app == BrowserMedia.appName
    guard !browserShown, let player = running.first(where: { $0.appName == media.nowPlaying?.app }) ?? running.first else {
      // Kein Programm, das Lumi per Skript steuert (z. B. YouTube im Browser): Mediatasten des Systems.
      guard let sendKey = options.mediaKeySender else {
        return .failure(code: "NOT_RUNNING", error: "Weder Musik noch Spotify läuft.")
      }
      guard sendKey(command) else {
        return .failure(code: "DENIED", error: "Dafür braucht Lumi die Bedienungshilfen-Freigabe (Systemeinstellungen → Datenschutz).")
      }
      if browserShown, var np = media.byApp[BrowserMedia.appName] {
        media.browserPaused = command == .playPause ? !media.browserPaused : false
        np.playing = !media.browserPaused
        media.byApp[BrowserMedia.appName] = np
        publishNowPlaying()
      }
      return .ok(Empty())
    }
    let script = player.controlScript(command)
    let run = mediaScriptRunner
    do {
      let r = try await Blocking.run { try run(script) }
      if r.status != 0 {
        if MediaParser.isDenied(r.stderr) { return .failure(code: "DENIED", error: MediaPlayer.deniedText) }
        return .failure(code: "SCRIPT", error: "\(player.appName) konnte den Befehl nicht ausführen.")
      }
      // Die App hat sich inzwischen beendet: nichts gesendet, nichts gestartet.
      guard r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
        return .failure(code: "NOT_RUNNING", error: "Weder Musik noch Spotify läuft.")
      }
    } catch {
      return .failure(code: "SCRIPT", error: "\(player.appName) konnte den Befehl nicht ausführen.")
    }
    await refreshNowPlaying()
    return .ok(Empty())
  }

  /// Sicherungsordner; nil bei flüchtiger Datenbank.
  func backupDirectory() -> String? {
    store.db.path == ":memory:" ? nil : DatabaseBackup.directory(for: store.db.path)
  }

  public func listBackups() async -> [BackupInfo] {
    guard let dir = backupDirectory() else { return [] }
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter(BackupNames.isValid).sorted { BackupNames.isOlder($1, $0) }
    return names.map { name in
      let path = (dir as NSString).appendingPathComponent(name)
      let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
      return BackupInfo(name: name, createdAt: BackupNames.createdAt(name), sizeBytes: size)
    }
  }

  public func restoreBackup(_ name: String) async -> ToolResult<Empty> {
    guard BackupNames.isValid(name), let dir = backupDirectory() else {
      return .failure(code: "VALIDATION", error: "Ungültiger Sicherungsname.")
    }
    let path = (dir as NSString).appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: path) else {
      return .failure(code: "NOT_FOUND", error: "Sicherung nicht gefunden.")
    }
    if let problem = BackupCheck.integrityProblem(path: path) {
      return .failure(code: "BROKEN", error: "Sicherung ist beschädigt (\(problem)). Wiederherstellung abgebrochen.")
    }
    // Eine Sicherung aus einer neueren Version würde die Datei in ein Schema zwingen, das diese App nicht kennt.
    let known = Migrations.all.map(\.version).max() ?? 0
    guard let found = BackupCheck.schemaVersion(path: path) else {
      return .failure(code: "BROKEN", error: "Sicherung ist nicht lesbar. Wiederherstellung abgebrochen.")
    }
    if found > known {
      return .failure(code: "NEWER_SCHEMA",
                      error: "Diese Sicherung stammt aus einer neueren Lumi-Version (Schema \(found), diese Version kennt bis \(known)). Bitte Lumi aktualisieren, dann erneut versuchen.")
    }
    // Die Sicherung der aktuellen Datenbank bekommt einen freien Namen; die Vorlage wird nie überschrieben.
    do {
      try DatabaseBackup.create(store.db, clock: clock)
    } catch {
      return .failure(code: "BACKUP", error: "Die aktuelle Datenbank konnte nicht gesichert werden.")
    }
    do {
      try RestorePlan.write(backup: name, dbPath: store.db.path, clock: clock)
    } catch {
      return .failure(code: "PLAN", error: "Der Wiederherstellungsplan konnte nicht geschrieben werden.")
    }
    return .ok(Empty())
  }

  public func exportBackup(to folder: String) async -> ToolResult<String> {
    guard backupDirectory() != nil else { return .failure(code: "UNSUPPORTED", error: "Ohne dauerhafte Datenbank gibt es nichts zu exportieren.") }
    let fm = FileManager.default
    do {
      let source = try DatabaseBackup.create(store.db, clock: clock)
      try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
      let name = (source as NSString).lastPathComponent
      let target = (folder as NSString).appendingPathComponent(DatabaseBackup.freeName(in: folder, base: (name as NSString).deletingPathExtension))
      try fm.copyItem(atPath: source, toPath: target)
      let sidecar = DatabaseBackup.notionSidecar(forBackup: source)
      if fm.fileExists(atPath: sidecar) { try? fm.copyItem(atPath: sidecar, toPath: DatabaseBackup.notionSidecar(forBackup: target)) }
      return .ok(target)
    } catch {
      return .failure(code: "EXPORT", error: "Der Export hat nicht geklappt. Ist der Ordner beschreibbar?")
    }
  }

  public func importBackup(from path: String) async -> ToolResult<String> {
    guard let dir = backupDirectory() else { return .failure(code: "UNSUPPORTED", error: "Ohne dauerhafte Datenbank kann nichts importiert werden.") }
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return .failure(code: "NOT_FOUND", error: "Die Datei wurde nicht gefunden.") }
    if let problem = BackupCheck.integrityProblem(path: path) {
      return .failure(code: "BROKEN", error: "Die Datei ist keine gültige Lumi-Sicherung (\(problem)).")
    }
    guard BackupCheck.schemaVersion(path: path) != nil else {
      return .failure(code: "BROKEN", error: "Die Datei ist keine gültige Lumi-Sicherung.")
    }
    do {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let name = DatabaseBackup.freeName(in: dir, base: "taby-\(DatabaseBackup.stamp(clock))")
      let target = (dir as NSString).appendingPathComponent(name)
      try fm.copyItem(atPath: path, toPath: target)
      let sidecar = DatabaseBackup.notionSidecar(forBackup: path)
      if fm.fileExists(atPath: sidecar) { try? fm.copyItem(atPath: sidecar, toPath: DatabaseBackup.notionSidecar(forBackup: target)) }
      return .ok(name)
    } catch {
      return .failure(code: "IMPORT", error: "Die Datei konnte nicht übernommen werden.")
    }
  }
}
