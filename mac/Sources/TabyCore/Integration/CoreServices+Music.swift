// Musik-Reiter: verteilt die Dienst-Aufrufe an die Anbieter in Music/.
import Foundation

extension CoreServices {
  private var musicProviders: [MusicService: MusicProvider] {
    if let r = musicRegistry { return r }
    let run = mediaScriptRunner
    let list: [MusicProvider] = [
      SpotifyProvider(),
      AppleMusicProvider(run: run),
      WebMusicProvider(service: .youtube),
      WebMusicProvider(service: .youtubeMusic),
      WebMusicProvider(service: .amazonMusic),
    ]
    let r = Dictionary(uniqueKeysWithValues: list.map { ($0.service, $0) })
    musicRegistry = r
    return r
  }

  public func musicStatus() async -> [MusicServiceStatus] {
    var out: [MusicServiceStatus] = []
    for s in MusicService.allCases { if let p = musicProviders[s] { out.append(await p.status()) } }
    return out
  }

  public func musicSetClientId(_ service: MusicService, _ clientId: String) async {
    await musicProviders[service]?.setClientId(clientId.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public func musicConnect(_ service: MusicService) async -> ToolResult<Empty> {
    guard let p = musicProviders[service] else { return .failure(code: "UNSUPPORTED", error: "Dienst unbekannt.") }
    return await p.connect()
  }

  public func musicDisconnect(_ service: MusicService) async { await musicProviders[service]?.disconnect() }

  public func musicSearch(_ service: MusicService, query: String) async -> ToolResult<[MusicItem]> {
    guard let p = musicProviders[service] else { return .failure(code: "UNSUPPORTED", error: "Dienst unbekannt.") }
    return await p.search(query)
  }

  public func musicPlaylists(_ service: MusicService) async -> ToolResult<[MusicItem]> {
    guard let p = musicProviders[service] else { return .failure(code: "UNSUPPORTED", error: "Dienst unbekannt.") }
    return await p.playlists()
  }

  public func musicPlay(_ item: MusicItem) async -> ToolResult<Empty> {
    guard let p = musicProviders[item.service] else { return .failure(code: "UNSUPPORTED", error: "Dienst unbekannt.") }
    return await p.play(item)
  }
}
