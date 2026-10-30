// YouTube, YouTube Music und Amazon Music: keine Anmeldung, keine Steuerung. Die Suche wird nur als
// Adresse angeboten und im Browser oder in der App geöffnet – und nur für feste https-Hosts.
import AppKit
import Foundation

final class WebMusicProvider: MusicProvider {
  /// Feste Positivliste: nur diese https-Hosts öffnet Taby.
  static let allowedHosts: Set<String> = [
    "music.youtube.com", "www.youtube.com", "youtube.com",
    "music.amazon.de", "music.amazon.com", "music.amazon.co.uk",
  ]
  /// Nur ASCII-Zeichen bleiben unverändert; Umlaute, Leerzeichen, & und # werden kodiert.
  static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  let service: MusicService
  private let opener: @Sendable (URL) -> Void

  init(service: MusicService, open: @escaping @Sendable (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }) {
    self.service = service
    self.opener = open
  }

  func status() async -> MusicServiceStatus {
    MusicServiceStatus(service: service, connected: true, canSearch: true, canListPlaylists: false,
                       canControl: false, note: "Öffnet die Suche im Browser oder in der App.")
  }

  func connect() async -> ToolResult<Empty> { .ok(Empty()) }

  func search(_ query: String) async -> ToolResult<[MusicItem]> {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return .failure(code: "EMPTY", error: "Bitte einen Suchbegriff eingeben.") }
    guard let address = Self.searchAddress(service, q) else {
      return .failure(code: "UNSUPPORTED", error: "Dieser Dienst ist hier nicht verfügbar.")
    }
    return .ok([MusicItem(id: address.absoluteString, service: service, kind: .playlist,
                          title: "Im Browser suchen (\(service.title)): \(q)")])
  }

  func playlists() async -> ToolResult<[MusicItem]> { .ok([]) }

  func play(_ item: MusicItem) async -> ToolResult<Empty> {
    guard let url = URL(string: item.id), Self.isAllowed(url) else {
      return .failure(code: "BLOCKED", error: "Diese Adresse öffnet Taby nicht.")
    }
    opener(url)
    return .ok(Empty())
  }

  /// Suchadresse des Dienstes; nil für Dienste ohne Web-Suche.
  static func searchAddress(_ service: MusicService, _ query: String) -> URL? {
    guard let q = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
    switch service {
    case .youtube: return URL(string: "https://www.youtube.com/results?search_query=\(q)")
    case .youtubeMusic: return URL(string: "https://music.youtube.com/search?q=\(q)")
    case .amazonMusic: return URL(string: "https://music.amazon.de/search/\(q)")
    case .spotify, .appleMusic: return nil
    }
  }

  /// Nur https und ein Host aus der Positivliste (Groß-/Kleinschreibung egal).
  static func isAllowed(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
    return allowedHosts.contains(host) && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
  }
}
