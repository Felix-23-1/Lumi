// VERTRAG (nur Orchestrator ändert): ein Musikdienst hinter dem Musik-Reiter.
// Jede Implementierung liegt in einer eigenen Datei in Music/; `CoreServices+Music.swift`
// verteilt die Dienst-Aufrufe (`musicSearch` usw.) an den passenden Anbieter.
import Foundation

protocol MusicProvider: AnyObject, Sendable {
  var service: MusicService { get }
  func status() async -> MusicServiceStatus
  /// Anmelden bzw. prüfen, ob das Programm da ist.
  func connect() async -> ToolResult<Empty>
  func disconnect() async
  func search(_ query: String) async -> ToolResult<[MusicItem]>
  func playlists() async -> ToolResult<[MusicItem]>
  func play(_ item: MusicItem) async -> ToolResult<Empty>
  /// Nur Spotify: eigene Client-ID speichern.
  func setClientId(_ clientId: String) async
}

extension MusicProvider {
  func setClientId(_ clientId: String) async {}
  func disconnect() async {}
}
