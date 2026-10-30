// Seite „Musik“: Spotify verbinden, Dienste, YouTube im Browser, Liedtext, Effekt und Wunsch-Dienst.
// Aktionen liegen in ViewActions (MusicLogic), die Musikseite zeigt nur noch Abspielen und Suche.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  var musicSection: some View { MusicSettingsView() }
}

struct MusicSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(MusicLogic.lyricsKey) private var lyricsOn = false
  @AppStorage(MusicLogic.effectKey) private var effectRaw = MusicEffect.off.rawValue
  @State private var statuses: [MusicServiceStatus]
  @State private var browserOn = false
  @State private var preferred: MusicService?
  @State private var clientIdDraft: String
  @State private var connecting = false
  @State private var error: String?
  @State private var note: String?

  init(preview: MusicPreview = MusicPreview()) {
    _statuses = State(initialValue: preview.statuses ?? [])
    _preferred = State(initialValue: preview.selected ?? MusicLogic.storedService())
    _clientIdDraft = State(initialValue: preview.clientId)
    _error = State(initialValue: preview.error)
    _note = State(initialValue: preview.note)
  }

  private var spotify: MusicServiceStatus? { statuses.first { $0.service == .spotify } }
  private var effect: MusicEffect { .parse(effectRaw) }
  private var wished: MusicService { preferred ?? MusicLogic.defaultService(statuses) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if let note { Banner(symbol: "checkmark.circle.fill", text: note, tint: Theme.green) }
      if let spotify { spotifyCard(spotify) }
      othersCard
      displayCard
    }
    .task {
      browserOn = await model.services.musicBrowserDetection()
      await refresh()
    }
  }

  // MARK: Spotify

  @ViewBuilder
  private func spotifyCard(_ s: MusicServiceStatus) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionHeader(symbol: "link", title: "Spotify")
        Spacer(minLength: 4)
        Chip(text: MusicLogic.statusBadge(s), tint: s.connected ? Theme.green : Theme.amber)
      }
      if s.connected {
        HStack(spacing: 8) {
          Text("Suche, Playlists und Wiedergabe sind freigeschaltet.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          Spacer(minLength: 4)
          Button("Trennen") { disconnect(s.service) }
            .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
        }
      } else {
        connectForm(s)
      }
      if !s.note.isEmpty { Text(s.note).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
    }
    .tabyCard()
  }

  private func connectForm(_ s: MusicServiceStatus) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      InputCapsule(placeholder: "Client-ID", text: $clientIdDraft, mono: true) {
        Button("Speichern") { saveClientId(s.service) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      .onSubmit { saveClientId(s.service) }
      HStack(spacing: 8) {
        Text("Dashboard öffnen, dort die App anlegen und die Client-ID kopieren.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("Dashboard öffnen") { NSWorkspace.shared.open(MusicLogic.spotifyDashboardURL) }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(MusicLogic.redirectLine())
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("Kopieren") { copyRedirect() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(MusicLogic.setupSteps.enumerated()), id: \.offset) { i, step in
          Text("\(i + 1). \(step)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
      HStack(spacing: 8) {
        if connecting {
          Text("Warte auf Spotify im Browser …").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        Spacer(minLength: 4)
        Button("Verbinden") { connect(s.service) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(connecting || !MusicLogic.canConnect(clientId: s.clientId))
      }
      if let hint = MusicLogic.clientIdHint(s.clientId), error != nil {
        Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Weitere Dienste

  private var othersCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "music.note.list", title: "Weitere Dienste")
      ForEach(statuses.filter { $0.service != .spotify }, id: \.service) { s in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(s.service.title).font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            Chip(text: MusicLogic.statusBadge(s), tint: s.connected ? Theme.green : Theme.amber)
          }
          if !s.note.isEmpty { Text(s.note).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
      }
    }
    .tabyCard()
  }

  // MARK: Anzeige

  private var displayCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(symbol: "slider.horizontal.3", title: "Anzeige")
      VStack(alignment: .leading, spacing: 4) {
        PillToggle(title: "YouTube im Browser anzeigen", isOn: Binding(
          get: { browserOn },
          set: { on in
            browserOn = on
            Task { await model.services.musicSetBrowserDetection(on); await model.refresh() }
          }))
        Text("Lumi liest dafür die Tab-Titel von Safari, Chrome, Brave oder Edge und zeigt nur den YouTube-Titel. macOS fragt einmal je Browser nach der Automation-Freigabe.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        PillToggle(title: "Liedtext anzeigen", isOn: $lyricsOn)
        Text(MusicLogic.lyricsNotice)
          .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Effekt").font(.system(size: 13)).foregroundStyle(Theme.text)
        WrapLayout(spacing: 4) {
          ForEach(MusicEffect.allCases, id: \.self) { e in
            ChoiceChip(text: e.title, selected: e == effect) { effectRaw = e.rawValue }
              .accessibilityAddTraits(e == effect ? .isSelected : [])
          }
        }
        Text("Optik, keine echte Audioanalyse. Läuft nur, solange etwas spielt.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Wunsch-Dienst").font(.system(size: 13)).foregroundStyle(Theme.text)
        WrapLayout(spacing: 4) {
          ForEach(MusicService.allCases, id: \.self) { s in
            ChoiceChip(text: s.title, selected: s == wished) {
              preferred = s
              MusicLogic.remember(s)
            }
            .accessibilityAddTraits(s == wished ? .isSelected : [])
          }
        }
        Text("Diesen Dienst zeigt die Musikseite beim Öffnen.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
    }
    .tabyCard()
  }

  // MARK: Aktionen

  private func saveClientId(_ service: MusicService) {
    Task {
      error = await ViewActions.musicSaveClientId(model, service, clientIdDraft)
      if error == nil {
        note = "Client-ID gespeichert."
        await refresh()
      }
    }
  }

  private func copyRedirect() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(MusicLogic.redirectURI, forType: .string)
    note = "Redirect-URI kopiert."
  }

  private func connect(_ service: MusicService) {
    Task {
      connecting = true
      error = nil
      let failure = await ViewActions.musicConnect(model, service)
      connecting = false
      error = failure
      if failure == nil { note = "Mit \(service.title) verbunden." }
      await refresh()
    }
  }

  private func disconnect(_ service: MusicService) {
    Task {
      await ViewActions.musicDisconnect(model, service)
      note = "Von \(service.title) getrennt."
      await refresh()
    }
  }

  private func refresh() async {
    statuses = await model.services.musicStatus()
    if clientIdDraft.isEmpty, let id = spotify?.clientId, !id.isEmpty { clientIdDraft = id }
  }
}
