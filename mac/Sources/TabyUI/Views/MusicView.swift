// Reiter "Musik": ruhige Ansicht mit laufendem Titel, Suche und Playlists. Verbinden und Einrichten
// liegt in den Einstellungen (Seite „Musik“). Aufrufe gehen über `model.services` (Aktionen in ViewActions, Logik in MusicLogic).
import AppKit
import SwiftUI
import TabyCore

/// Vorbelegung für Snapshots und Prüfungen (ohne Kern).
struct MusicPreview {
  var statuses: [MusicServiceStatus]?
  var selected: MusicService?
  var query = ""
  var results: [MusicItem]?
  var searchError: String?
  var playlists: [MusicItem]?
  var playlistsOpen = false
  var error: String?
  var note: String?
  var clientId = ""
  var effect: MusicEffect?
  var lyrics: Bool?
  var lyricsState: LyricsState?
}

struct MusicView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(MusicLogic.lyricsKey) private var lyricsStored = false
  @AppStorage(MusicLogic.effectKey) private var effectStored = MusicEffect.off.rawValue
  @State private var statuses: [MusicServiceStatus]
  /// nil = noch nie gewählt, dann gilt der Standarddienst.
  @State private var selected: MusicService?
  @State private var query: String
  @State private var results: [MusicItem]?
  @State private var searchError: String?
  @State private var searching = false
  @State private var playlists: [MusicItem]?
  @State private var playlistsOpen: Bool
  @State private var error: String?
  @State private var note: String?
  @State private var lyricsOpen: Bool
  @State private var lyricsState: LyricsState
  /// Titel, zu dem `lyricsState` gehört: je Titel wird nur einmal geladen.
  @State private var lyricsLoadedKey: String?
  private let effectOverride: MusicEffect?
  private let lyricsOverride: Bool?

  /// Höhe des scrollbaren Bereichs unter Karte, Suche und Dienst-Auswahl.
  static let scrollHeight: CGFloat = 200

  init(preview: MusicPreview = MusicPreview()) {
    _statuses = State(initialValue: preview.statuses ?? [])
    _selected = State(initialValue: preview.selected ?? MusicLogic.storedService())
    _query = State(initialValue: preview.query)
    _results = State(initialValue: preview.results)
    _searchError = State(initialValue: preview.searchError)
    _playlists = State(initialValue: preview.playlists)
    _playlistsOpen = State(initialValue: preview.playlistsOpen)
    _error = State(initialValue: preview.error)
    _note = State(initialValue: preview.note)
    _lyricsOpen = State(initialValue: preview.lyricsState != nil)
    _lyricsState = State(initialValue: preview.lyricsState ?? .idle)
    effectOverride = preview.effect
    lyricsOverride = preview.lyrics
  }

  private var active: MusicService { selected ?? MusicLogic.defaultService(statuses) }
  private var status: MusicServiceStatus? { statuses.first { $0.service == active } }
  private var effect: MusicEffect { effectOverride ?? .parse(effectStored) }
  private var lyricsOn: Bool { lyricsOverride ?? lyricsStored }

  var body: some View {
    let np = model.state?.nowPlaying
    let key = MusicLogic.trackKey(np)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 8) {
        PageHeader(title: "Musik")
        Spacer(minLength: 0)
        Button { SettingsEntry.show(.music) } label: {
          Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .help("Musik-Einstellungen")
        .accessibilityLabel("Musik-Einstellungen")
      }
      nowPlayingCard(np)
      if lyricsOn && lyricsOpen && key != nil { MusicLyricsView(state: lyricsState) }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if let note { Banner(symbol: "checkmark.circle.fill", text: note, tint: Theme.green) }
      serviceChips
      if let status {
        if status.connected {
          if status.canSearch { searchSection(status) }
          CappedScroll(maxHeight: Self.scrollHeight) {
            VStack(alignment: .leading, spacing: 10) {
              resultList(status)
              if status.canListPlaylists { playlistSection(status) }
            }
          }
        } else {
          notConnectedRow(status)
        }
      }
    }
    .task { await model.services.musicRefreshNowPlaying() }
    .task(id: active) { await refresh() }
    .task(id: "\(key ?? "")|\(lyricsOn)|\(lyricsOpen)") { await loadLyrics(np, key) }
    .onChange(of: active) { _, _ in
      results = nil
      searchError = nil
    }
  }

  // MARK: Karte

  /// Immer sichtbar: ohne erkanntes Lied steuern die Knöpfe, was im System gerade abspielt (z. B. YouTube im Browser).
  private func nowPlayingCard(_ np: NowPlaying?) -> some View {
    VStack(spacing: 10) {
      VStack(spacing: 10) {
        VStack(spacing: 2) {
          Text(np?.title ?? "Nichts läuft")
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(np == nil ? Theme.secondary : Theme.text).lineLimit(1)
          Text(np.map { $0.artist.isEmpty ? $0.app : $0.artist } ?? "Starte Musik in Spotify oder Apple Musik.")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        HStack(spacing: 14) {
          mediaButton("backward.fill", "Zurück", .previous)
          mediaButton(np?.playing == true ? "pause.fill" : "play.fill", np?.playing == true ? "Pause" : "Abspielen/Pause", .playPause, size: 34)
          mediaButton("forward.fill", "Weiter", .next)
        }
        if effect != .off {
          MusicEffectView(effect: effect, playing: np?.playing == true, title: np?.title ?? "")
            .frame(height: 36)
        }
        if MusicLogic.showsLyricsButton(enabled: lyricsOn, np: np) {
          Button(lyricsOpen ? "Liedtext ausblenden" : "Liedtext") {
            withAnimation(Theme.snappy) { lyricsOpen.toggle() }
          }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      }
      .frame(maxWidth: .infinity)
    }
    .tabyCard(padding: 12)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func mediaButton(_ symbol: String, _ label: String, _ command: MediaCommand, size: CGFloat = 26) -> some View {
    Button {
      Task {
        let r = await model.services.mediaControl(command)
        error = r.errorMessage
        await model.refresh()
      }
    } label: { Image(systemName: symbol).font(.system(size: size > 30 ? 13 : 10)) }
      .buttonStyle(RoundIconButtonStyle(size: size))
      .help(label)
      .accessibilityLabel(label)
  }

  private var serviceChips: some View {
    WrapLayout(spacing: 4) {
      ForEach(MusicService.allCases, id: \.self) { s in
        Button { choose(s) } label: {
          Text(s.title).font(.system(size: 11, weight: s == active ? .semibold : .medium))
            .foregroundStyle(s == active ? Color.black : Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(s == active ? Color.white.opacity(0.92) : Theme.capsule))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(s == active ? .isSelected : [])
      }
    }
  }

  private func choose(_ s: MusicService) {
    selected = s
    MusicLogic.remember(s)
    error = nil
    note = nil
  }

  /// Eine ruhige Zeile statt Einrichtungsschritten: verbunden wird in den Einstellungen.
  private func notConnectedRow(_ s: MusicServiceStatus) -> some View {
    HStack(spacing: 8) {
      Text("\(s.service.title) ist nicht verbunden")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      Spacer(minLength: 4)
      Button("In den Einstellungen verbinden") { SettingsEntry.show(.music) }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(Capsule().fill(Theme.capsule))
  }

  // MARK: Liedtext

  /// Lädt beim Aufklappen, je Titel einmal. Ausgeschaltet oder zugeklappt passiert nichts.
  private func loadLyrics(_ np: NowPlaying?, _ key: String?) async {
    guard lyricsOn, lyricsOpen, let np, let key else { return }
    if lyricsLoadedKey == key, lyricsState != .idle { return }
    lyricsLoadedKey = key
    lyricsState = .loading
    let r = await model.services.lyrics(artist: np.artist, title: np.title)
    guard !Task.isCancelled else { lyricsLoadedKey = nil; lyricsState = .idle; return }
    lyricsState = MusicLogic.lyricsState(r)
  }

  /// Lädt Dienststatus und, wenn angemeldet, die Playlists des aktiven Dienstes.
  private func refresh() async {
    statuses = await model.services.musicStatus()
    guard let s = status else { return }
    guard s.connected && s.canListPlaylists else {
      playlists = nil
      return
    }
    let r = await ViewActions.musicPlaylists(model, s.service)
    playlists = MusicLogic.limited(r.items)
    if let e = r.error { error = e }
  }

  // MARK: Suche

  private func searchSection(_ s: MusicServiceStatus) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      InputCapsule(placeholder: "Song, Album oder Playlist suchen", text: $query) {
        Button("Suchen") { search(s.service) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      .onSubmit { search(s.service) }
      if searching { Text("Suche läuft …").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
    }
  }

  @ViewBuilder
  private func resultList(_ s: MusicServiceStatus) -> some View {
    if let searchError {
      Banner(symbol: "exclamationmark.circle.fill", text: searchError, tint: Theme.red)
    } else if let results {
      if results.isEmpty {
        Banner(symbol: "magnifyingglass", text: MusicLogic.emptyText(query), tint: Theme.blue)
      } else {
        ForEach(results) { itemRow($0, canControl: s.canControl) }
      }
    }
  }

  private func search(_ service: MusicService) {
    Task {
      searching = true
      let r = await ViewActions.musicSearch(model, service, query: query)
      searching = false
      searchError = r.error
      results = r.error == nil ? r.items : nil
    }
  }

  // MARK: Zeilen

  private func itemRow(_ item: MusicItem, canControl: Bool) -> some View {
    HStack(spacing: 10) {
      cover(item)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        Text(MusicLogic.rowSubtitle(item))
          .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
      }
      Spacer(minLength: 6)
      Button(MusicLogic.actionTitle(canControl: canControl)) { play(item, canControl: canControl) }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
  }

  @ViewBuilder
  private func cover(_ item: MusicItem) -> some View {
    Group {
      if let url = MusicLogic.coverURL(item.imageURL) {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          coverPlaceholder(item.kind)
        }
      } else {
        coverPlaceholder(item.kind)
      }
    }
    .frame(width: 36, height: 36)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func coverPlaceholder(_ kind: MusicItem.Kind) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.capsule)
      Image(systemName: MusicLogic.kindSymbol(kind)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
    }
  }

  private func play(_ item: MusicItem, canControl: Bool) {
    Task {
      error = await ViewActions.musicPlay(model, item)
      if error == nil && !canControl { note = "Im Browser geöffnet." }
    }
  }

  // MARK: Playlists

  private func playlistSection(_ s: MusicServiceStatus) -> some View {
    CollapsibleSection(symbol: "music.note.list", title: "Deine Playlists",
                       count: playlists.map { $0.count }, collapsed: Binding(
                         get: { !playlistsOpen }, set: { playlistsOpen = !$0 })) {
      VStack(alignment: .leading, spacing: 8) {
        if let playlists {
          if playlists.isEmpty {
            Banner(symbol: "music.note.list", text: "Keine Playlists gefunden.", tint: Theme.blue)
          } else {
            ForEach(playlists) { itemRow($0, canControl: s.canControl) }
          }
        } else {
          Text("Lade Playlists …").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
    }
  }
}
