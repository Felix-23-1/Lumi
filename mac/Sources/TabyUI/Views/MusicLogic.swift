// Logik des Musik-Reiters ohne Oberfläche: Texte, Knopf-Wahl, Standarddienst,
// Cover-Adressen und Grenzen. Aktionen gehen über `ViewActions` (unten), damit
// MusicChecks sie gegen FakeServices prüfen kann.
import Foundation
import TabyCore

enum MusicLogic {
  static let redirectURI = "http://127.0.0.1:8898/callback"
  static let playlistLimit = 50
  static let defaultsKey = "taby.music.service"
  static let setupSteps = [
    "developer.spotify.com/dashboard öffnen und eine App anlegen.",
    "In den Einstellungen der App die Redirect-URI oben eintragen.",
    "Die Client-ID der App hier eintragen und „Verbinden“ drücken.",
  ]

  static let spotifyDashboardURL = URL(string: "https://developer.spotify.com/dashboard")!

  /// Web-Dienste ohne Anmeldung: der Browser öffnet sie, Lumi steuert sie nicht.
  static func isWebService(_ service: MusicService) -> Bool {
    [MusicService.youtube, .youtubeMusic, .amazonMusic].contains(service)
  }

  static func statusBadge(_ s: MusicServiceStatus) -> String {
    if isWebService(s.service) { return "Öffnet im Browser" }
    return s.connected ? "Verbunden" : "Nicht verbunden"
  }

  /// Spotify-Client-IDs haben 32 Buchstaben oder Ziffern; sonst ein Hinweis, nil wenn passend oder leer.
  static func clientIdHint(_ id: String) -> String? {
    let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    let ok = clean.count == 32 && clean.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    return ok ? nil : "Die Client-ID hat 32 Zeichen, nur Buchstaben und Ziffern. Bitte prüfen."
  }

  static func redirectLine() -> String {
    "Redirect-URI zum Eintragen in deiner Spotify-App: \(redirectURI)"
  }

  /// Erster verbundener Dienst in der Reihenfolge der Auswahl, sonst Spotify.
  static func defaultService(_ statuses: [MusicServiceStatus]) -> MusicService {
    MusicService.allCases.first { s in statuses.contains { $0.service == s && $0.connected } } ?? .spotify
  }

  /// Gemerkte Auswahl des Nutzers (UserDefaults), nil wenn noch nie gewählt.
  static func storedService(_ defaults: UserDefaults = .standard) -> MusicService? {
    defaults.string(forKey: defaultsKey).flatMap(MusicService.init(rawValue:))
  }

  static func remember(_ service: MusicService, _ defaults: UserDefaults = .standard) {
    defaults.set(service.rawValue, forKey: defaultsKey)
  }

  static func kindTitle(_ kind: MusicItem.Kind) -> String {
    switch kind {
    case .track: "Titel"
    case .playlist: "Playlist"
    case .album: "Album"
    }
  }

  static func kindSymbol(_ kind: MusicItem.Kind) -> String {
    switch kind {
    case .track: "music.note"
    case .playlist: "music.note.list"
    case .album: "square.stack"
    }
  }

  /// Untertitel einer Zeile: Interpret/Beschreibung und Art, ohne leere Teile.
  static func rowSubtitle(_ item: MusicItem) -> String {
    [item.subtitle, kindTitle(item.kind)].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// Dienste ohne Wiedergabe in der App öffnen nur den Browser oder das Programm.
  static func actionTitle(canControl: Bool) -> String { canControl ? "Abspielen" : "Öffnen" }

  static func canConnect(clientId: String) -> Bool {
    !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Cover nur über https; alles andere zeigt das Platzhalter-Symbol.
  static func coverURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  static func limited(_ items: [MusicItem]) -> [MusicItem] { Array(items.prefix(playlistLimit)) }

  static func searchProblem(_ query: String) -> String? {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bitte einen Suchbegriff eingeben." : nil
  }

  static func emptyText(_ query: String) -> String {
    "Keine Treffer für „\(query.trimmingCharacters(in: .whitespacesAndNewlines))“."
  }
}

/// Optischer Effekt hinter der Now-Playing-Karte. Reine Optik, keine Audioanalyse.
enum MusicEffect: String, CaseIterable {
  case off, bars, waves, glow

  var title: String {
    switch self {
    case .off: "Aus"
    case .bars: "Balken"
    case .waves: "Wellen"
    case .glow: "Glühen"
    }
  }

  /// Unbekannte oder fehlende Werte ergeben „Aus“.
  static func parse(_ raw: String?) -> MusicEffect { raw.flatMap(MusicEffect.init(rawValue:)) ?? .off }
}

/// Zustand des Liedtext-Panels.
enum LyricsState: Equatable {
  case idle, loading
  case text([String])
  case empty
  case failed(String)
}

/// Einstellungen der Musikseite (UserDefaults) und die Berechnung des Effekts. Zeit ist immer ein Parameter.
extension MusicLogic {
  static let lyricsKey = "music.lyrics"
  static let effectKey = "music.effect"
  static let lyricsNotice = "Interpret und Titel werden an lrclib.net gesendet."

  static func lyricsEnabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: lyricsKey) }
  static func storedEffect(_ d: UserDefaults = .standard) -> MusicEffect { .parse(d.string(forKey: effectKey)) }

  /// Der Effekt läuft nur bei Wiedergabe und ohne „Bewegung reduzieren“.
  static func animates(playing: Bool, reduceMotion: Bool) -> Bool { playing && !reduceMotion }

  /// Je Titel einmal laden: Schlüssel aus Interpret und Titel, nil wenn nichts läuft.
  static func trackKey(_ np: NowPlaying?) -> String? {
    guard let np, !np.title.isEmpty else { return nil }
    return "\(np.artist)\u{1F}\(np.title)"
  }

  /// Liedtext-Knopf nur bei eingeschaltetem Schalter und laufendem Titel.
  static func showsLyricsButton(enabled: Bool, np: NowPlaying?) -> Bool { enabled && trackKey(np) != nil }

  static func lyricsState(_ r: ToolResult<String>) -> LyricsState {
    if case .failure(let code, let message) = r { return code == "NOT_FOUND" ? .empty : .failed(message) }
    let lines = (r.value ?? "").replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    return trimmed.allSatisfy(\.isEmpty) ? .empty : .text(trimmed)
  }

  static func lyricsMessage(_ s: LyricsState) -> String? {
    switch s {
    case .loading: "Lade Liedtext …"
    case .empty: "Kein Liedtext gefunden."
    case .failed(let e): "Liedtext konnte nicht geladen werden: \(e)"
    case .idle, .text: nil
    }
  }

  /// Stabiler Farbton 0...1 aus dem Titel (nicht `hashValue`, das sich je Start ändert).
  static func hue(_ title: String) -> Double {
    var h: UInt32 = 2_166_136_261
    for b in title.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return Double(h % 360) / 360
  }

  /// Höhen 0.12...1 für `count` Balken zur Zeit `t` (Sekunden): überlagerte Sinuskurven mit eigener Phase je Balken.
  static func barHeights(count: Int, t: Double) -> [Double] {
    (0..<max(0, count)).map { i in
      let x = Double(i)
      let v = 0.5 * sin(t * 2.1 + x * 0.9) + 0.3 * sin(t * 3.3 + x * 1.7 + 1) + 0.2 * sin(t * 5.1 + x * 0.4)
      return 0.12 + 0.88 * (v + 1) / 2
    }
  }

  /// Auslenkung -1...1 der Welle `line` an der Stelle `x` (0...1) zur Zeit `t`.
  static func waveOffset(line: Int, x: Double, t: Double) -> Double {
    let l = Double(line)
    return (0.6 * sin(x * (5 + l * 1.5) + t * (1.4 + l * 0.5) + l) + 0.4 * sin(x * 11 - t * (2.2 - l * 0.3))) * 0.9
  }

  /// Helligkeit 0.55...1 des Glühens.
  static func glowPulse(t: Double) -> Double { 0.775 + 0.225 * sin(t * 1.6) * (0.7 + 0.3 * sin(t * 0.55)) }
}

extension ViewActions {
  /// Fehlermeldung oder nil. Speichert die bereinigte Client-ID.
  static func musicSaveClientId(_ model: AppModel, _ service: MusicService, _ id: String) async -> String? {
    let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard MusicLogic.canConnect(clientId: clean) else { return "Client-ID fehlt." }
    await model.services.musicSetClientId(service, clean)
    return nil
  }

  /// Fehlermeldung oder nil; bei Erfolg ist der Dienst angemeldet.
  static func musicConnect(_ model: AppModel, _ service: MusicService) async -> String? {
    await model.services.musicConnect(service).errorMessage
  }

  static func musicDisconnect(_ model: AppModel, _ service: MusicService) async {
    await model.services.musicDisconnect(service)
  }

  /// Treffer und Fehlermeldung; höchstens eines davon ist gesetzt.
  static func musicSearch(_ model: AppModel, _ service: MusicService,
                          query: String) async -> (items: [MusicItem], error: String?) {
    if let problem = MusicLogic.searchProblem(query) { return ([], problem) }
    let r = await model.services.musicSearch(service, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    if let e = r.errorMessage { return ([], e) }
    return (r.value ?? [], nil)
  }

  static func musicPlaylists(_ model: AppModel, _ service: MusicService) async -> (items: [MusicItem], error: String?) {
    let r = await model.services.musicPlaylists(service)
    if let e = r.errorMessage { return ([], e) }
    return (r.value ?? [], nil)
  }

  /// Spielt ab, oder öffnet bei Web-Diensten den Browser. Fehlermeldung oder nil.
  static func musicPlay(_ model: AppModel, _ item: MusicItem) async -> String? {
    await model.services.musicPlay(item).errorMessage
  }
}
