// YouTube im Browser erkennen (nur auf ausdrücklichen Wunsch, Schalter im Musik-Reiter):
// Lumi liest dafür einmal pro Aufruf die Tab-Titel der laufenden Browser und behält nur den
// Titel eines YouTube-Tabs. Kein Takt, keine Speicherung, nichts außer dem einen Titel verlässt den Aufruf.
import AppKit
import Foundation

enum BrowserPlayer: CaseIterable {
  case safari, chrome, brave, edge

  var bundleId: String {
    switch self {
    case .safari: "com.apple.Safari"
    case .chrome: "com.google.Chrome"
    case .brave: "com.brave.Browser"
    case .edge: "com.microsoft.edgemac"
    }
  }
  var scriptName: String {
    switch self {
    case .safari: "Safari"
    case .chrome: "Google Chrome"
    case .brave: "Brave Browser"
    case .edge: "Microsoft Edge"
    }
  }

  /// Tab-Titel, einer je Zeile. Startet den Browser nie (die Laufprüfung steht im Skript).
  var titlesScript: String {
    let name = self == .safari ? "name" : "title"
    return """
    if application "\(scriptName)" is running then
      set lumiOut to ""
      tell application "\(scriptName)"
        repeat with w in windows
          repeat with t in tabs of w
            set lumiOut to lumiOut & (\(name) of t) & linefeed
          end repeat
        end repeat
      end tell
      return lumiOut
    end if
    return ""
    """
  }
}

enum BrowserMedia {
  static let defaultsKey = "lumi.music.detectBrowser"
  static let appName = "YouTube"

  /// Erster Titel eines YouTube-Tabs („Lied - YouTube“ bzw. „… - YouTube Music“); die Startseite („YouTube“) zählt nicht.
  static func parse(_ stdout: String) -> NowPlaying? {
    for raw in stdout.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      for suffix in [" - YouTube Music", " - YouTube"] where line.hasSuffix(suffix) {
        var title = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        // Chrome setzt bei Tabs mit Ton manchmal eine Zähl-Vorsilbe, z. B. „(3) “.
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"), title[title.index(after: title.startIndex)..<close].allSatisfy(\.isNumber) {
          title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { continue }
        return NowPlaying(title: String(title.prefix(120)), artist: "", app: appName, playing: true)
      }
    }
    return nil
  }
}

extension CoreServices {
  var browserDetectionOn: Bool { options.updateDefaults.bool(forKey: BrowserMedia.defaultsKey) }

  /// Liest die Tab-Titel laufender Browser (nur wenn eingeschaltet); schlägt ein Skript fehl, bleibt der Stand.
  func refreshBrowserMedia() async {
    guard browserDetectionOn else { media.byApp[BrowserMedia.appName] = nil; return }
    let bundles = options.mediaRunningBundles?()
      ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let run = mediaScriptRunner
    var found: NowPlaying?
    for b in BrowserPlayer.allCases where bundles.contains(b.bundleId) {
      let script = b.titlesScript
      guard let r = try? await Blocking.run({ try run(script) }), r.status == 0 else { continue }
      if let np = BrowserMedia.parse(r.stdout) { found = np; break }
    }
    if found?.title != media.byApp[BrowserMedia.appName]?.title { media.browserPaused = false }
    found?.playing = !media.browserPaused
    media.byApp[BrowserMedia.appName] = found
  }

  public func musicBrowserDetection() async -> Bool { browserDetectionOn }

  public func musicSetBrowserDetection(_ on: Bool) async {
    options.updateDefaults.set(on, forKey: BrowserMedia.defaultsKey)
    await refreshNowPlaying()
  }

  public func musicRefreshNowPlaying() async { await refreshNowPlaying() }
}
