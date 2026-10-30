// VERTRAG (nur Orchestrator ändert): Musik-Reiter – Dienste, Treffer, Status.
// Spotify: Anmeldung (PKCE, eigene Client-ID), Suche, Playlists, Abspielen über die Web-API.
// Apple Musik: lokal über die Musik-App (AppleScript), Bibliothek und Playlists, keine Katalogsuche.
// YouTube Music und Amazon Music: keine offizielle Schnittstelle – Suche/Playlist wird nur geöffnet.
import Foundation

public enum MusicService: String, Codable, CaseIterable, Sendable {
  case spotify, appleMusic, youtube, youtubeMusic, amazonMusic

  public var title: String {
    switch self {
    case .spotify: "Spotify"
    case .appleMusic: "Apple Musik"
    case .youtube: "YouTube"
    case .youtubeMusic: "YouTube Music"
    case .amazonMusic: "Amazon Music"
    }
  }
}

public struct MusicItem: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case track, playlist, album }
  /// Eindeutig je Dienst: Spotify-URI, Playlist-Name (Apple Musik) oder Web-Adresse (YouTube/Amazon).
  public var id: String
  public var service: MusicService
  public var kind: Kind
  public var title: String
  public var subtitle: String
  /// Cover-Adresse (nur https), optional.
  public var imageURL: String?
  public init(id: String, service: MusicService, kind: Kind, title: String, subtitle: String = "", imageURL: String? = nil) {
    self.id = id; self.service = service; self.kind = kind; self.title = title; self.subtitle = subtitle
    self.imageURL = imageURL
  }
}

public struct MusicServiceStatus: Codable, Equatable, Identifiable, Sendable {
  public var service: MusicService
  public var id: String { service.rawValue }
  /// Angemeldet (Spotify) bzw. Programm vorhanden (Apple Musik); Web-Dienste: immer true.
  public var connected: Bool
  public var canSearch: Bool
  public var canListPlaylists: Bool
  /// Spielt direkt ab (true) oder öffnet nur Browser/App (false).
  public var canControl: Bool
  /// Eingetragene Client-ID (nur Spotify), sonst leer.
  public var clientId: String
  /// Kurzer Hinweis für die Oberfläche (z. B. „Premium nötig“, „nur Öffnen im Browser“).
  public var note: String
  public init(service: MusicService, connected: Bool, canSearch: Bool, canListPlaylists: Bool, canControl: Bool,
              clientId: String = "", note: String = "") {
    self.service = service; self.connected = connected; self.canSearch = canSearch
    self.canListPlaylists = canListPlaylists; self.canControl = canControl; self.clientId = clientId; self.note = note
  }
}
