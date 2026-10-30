// Liedtext-Aufruf der Dienste: reicht an LyricsProvider (lrclib.net) weiter.
// Der Aufrufer holt Texte nur nach ausdrücklichem Einschalten durch den Nutzer.
import Foundation

extension CoreServices {
  public func lyrics(artist: String, title: String) async -> ToolResult<String> {
    await LyricsProvider.shared.lyrics(artist: artist, title: title)
  }
}
