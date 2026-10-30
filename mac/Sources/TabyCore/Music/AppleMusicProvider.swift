// Apple Musik über die Musik-App (AppleScript): Playlists und Bibliothek durchsuchen, abspielen.
// Die App wird nie von selbst gestartet – nur beim ausdrücklichen Abspielen. Skripte laufen über
// die injizierte Skriptausführung (wie bei MediaPlayer), damit die Prüfungen ohne echte App gehen.
import AppKit
import Foundation

final class AppleMusicProvider: MusicProvider {
  static let bundleId = "com.apple.Music"
  static let notInstalledText = "Die Musik-App wurde nicht gefunden."
  static let notRunningText = "Die Musik-App läuft nicht. Öffne sie, dann klappt die Suche."
  static let deniedText = "Taby darf die Musik-App nicht steuern – Systemeinstellungen → Datenschutz → Automation."
  static let scriptFailedText = "Die Musik-App konnte den Befehl nicht ausführen."

  let service = MusicService.appleMusic
  private let run: @Sendable (String) throws -> ProcessOutput
  private let isInstalled: @Sendable () -> Bool
  private let isRunning: @Sendable () -> Bool

  init(run: @escaping @Sendable (String) throws -> ProcessOutput = IMessageConnector.osascript,
       isInstalled: @escaping @Sendable () -> Bool = {
         NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppleMusicProvider.bundleId) != nil
       },
       isRunning: @escaping @Sendable () -> Bool = {
         NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AppleMusicProvider.bundleId }
       }) {
    self.run = run; self.isInstalled = isInstalled; self.isRunning = isRunning
  }

  func status() async -> MusicServiceStatus {
    MusicServiceStatus(service: service, connected: isInstalled(), canSearch: true, canListPlaylists: true,
                       canControl: true,
                       note: "Sucht in deiner Bibliothek und spielt über die Musik-App (bei Apple angemeldet).")
  }

  func connect() async -> ToolResult<Empty> {
    isInstalled() ? .ok(Empty()) : .failure(code: "NOT_INSTALLED", error: Self.notInstalledText)
  }

  func search(_ query: String) async -> ToolResult<[MusicItem]> {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return .failure(code: "EMPTY", error: "Bitte einen Suchbegriff eingeben.") }
    if let failure = checkReady() { return failure }
    return await execute(Self.searchScript(q)) { Self.tracks($0) }
  }

  func playlists() async -> ToolResult<[MusicItem]> {
    if let failure = checkReady() { return failure }
    return await execute(Self.playlistsScript) { Self.playlists($0) }
  }

  func play(_ item: MusicItem) async -> ToolResult<Empty> {
    guard isInstalled() else { return .failure(code: "NOT_INSTALLED", error: Self.notInstalledText) }
    let script: String
    switch item.kind {
    case .playlist:
      guard !item.id.isEmpty else { return .failure(code: "BAD_INPUT", error: "Diese Playlist lässt sich nicht abspielen.") }
      script = Self.playPlaylistScript(item.id)
    case .track:
      guard Self.isPersistentId(item.id) else {
        return .failure(code: "BAD_INPUT", error: "Dieser Titel lässt sich nicht abspielen.")
      }
      script = Self.playTrackScript(item.id)
    case .album:
      return .failure(code: "UNSUPPORTED", error: "Alben gibt es in Apple Musik hier nicht.")
    }
    return await execute(script) { _ in Empty() }
  }

  /// Gemeinsame Vorprüfung: Programm vorhanden und läuft. Ohne Lauf kein Skript (und kein Start).
  private func checkReady() -> ToolResult<[MusicItem]>? {
    guard isInstalled() else { return .failure(code: "NOT_INSTALLED", error: Self.notInstalledText) }
    guard isRunning() else { return .failure(code: "NOT_RUNNING", error: Self.notRunningText) }
    return nil
  }

  /// Führt ein Skript abseits des Hauptthreads aus und übersetzt Fehler in Meldungen.
  private func execute<T>(_ script: String, _ parse: (String) -> T) async -> ToolResult<T> {
    let run = self.run
    do {
      let r = try await Blocking.run { try run(script) }
      if !r.timedOut && r.status == 0 { return .ok(parse(r.stdout)) }
      if MediaParser.isDenied(r.stderr) { return .failure(code: "DENIED", error: Self.deniedText) }
      return .failure(code: "SCRIPT", error: Self.scriptFailedText)
    } catch {
      return .failure(code: "SCRIPT", error: Self.scriptFailedText)
    }
  }

  // MARK: Skripte und Auswertung (rein, prüfbar)

  static let playlistsScript = """
  tell application "Music"
    set out to ""
    repeat with n in (name of every user playlist)
      set out to out & n & linefeed
    end repeat
    return out
  end tell
  """

  static func searchScript(_ query: String) -> String {
    """
    tell application "Music"
      set out to ""
      set found to (search library playlist 1 for \(literal(query)) only songs)
      if found is missing value then return out
      set n to 0
      repeat with t in found
        set n to n + 1
        if n > 15 then exit repeat
        set out to out & (name of t) & tab & (artist of t) & tab & (persistent ID of t) & linefeed
      end repeat
      return out
    end tell
    """
  }

  static func playPlaylistScript(_ name: String) -> String {
    "tell application \"Music\" to play playlist \(literal(name))"
  }

  static func playTrackScript(_ id: String) -> String {
    "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \(literal(id)))"
  }

  /// AppleScript-Textliteral: Anführungszeichen und Backslash maskiert, Steuer- und Zeilenumbrüche werden Leerzeichen.
  static func literal(_ text: String) -> String {
    var out = "\""
    // Pro Unicode-Skalar, nicht pro Zeichen: ein „"“ mit Combining-Zeichen darf nicht ungemaskiert durch.
    for u in String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)).unicodeScalars {
      if u == "\"" {
        out += "\\\""
      } else if u == "\\" {
        out += "\\\\"
      } else if u.value < 32 || CharacterSet.newlines.contains(u) {
        if !out.hasSuffix(" ") { out += " " }
      } else {
        out.unicodeScalars.append(u)
      }
    }
    return out + "\""
  }

  /// Persistente Titel-IDs sind 16 Hex-Zeichen; alles andere wird nicht ins Skript gegeben.
  static func isPersistentId(_ id: String) -> Bool {
    (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && $0.isHexDigit }
  }

  /// Zeilen "Name<TAB>Künstler<TAB>ID" (Künstler-Teil optional); höchstens 15 Titel.
  static func tracks(_ stdout: String) -> [MusicItem] {
    var out: [MusicItem] = []
    for line in stdout.components(separatedBy: .newlines) {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }
      let id = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
      let artist = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
      let title = parts[0..<(parts.count - 2)].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
      guard !title.isEmpty, isPersistentId(id) else { continue }
      out.append(MusicItem(id: id, service: .appleMusic, kind: .track, title: title, subtitle: artist))
      if out.count == 15 { break }
    }
    return out
  }

  /// Ein Name je Zeile (oder Tab-getrennt); leer und doppelt fällt weg, höchstens 100.
  static func playlists(_ stdout: String) -> [MusicItem] {
    var seen = Set<String>()
    var out: [MusicItem] = []
    for part in stdout.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))) {
      let name = part.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, seen.insert(name).inserted else { continue }
      out.append(MusicItem(id: name, service: .appleMusic, kind: .playlist, title: name, subtitle: "Playlist"))
      if out.count == 100 { break }
    }
    return out
  }
}
