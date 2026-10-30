// Snapshots der Netzlaufwerk-Karte: verbundene und fehlerhafte Freigabe auf der Seite
// „Verbindungen“, das Formular „+ Netzlaufwerk“ und ein Formular mit ungültiger Adresse.
import SwiftUI
import TabyCore

enum ShareSnapshots {
  static let sampleShares = [
    NetworkShare(id: "nas", name: "Dokumente", url: "smb://nas.local/Dokumente", user: "felix",
                 autoMount: true, searchFolders: ["Unterlagen"]),
    NetworkShare(id: "fotos", name: "Fotos", url: "smb://192.168.1.20/Fotos", user: "gast"),
  ]

  static let sampleStates: [String: ShareState] = [
    "nas": ShareState(mounted: true, mountPath: "/Volumes/Dokumente"),
    "fotos": ShareState(mounted: false, error: "Anmeldung abgelehnt – Benutzer oder Passwort prüfen."),
  ]

  @MainActor static var all: [SnapshotSpec] {
    [
      SnapshotSpec("view-settings-page-connect-shares", size: CGSize(width: TabLayout.contentWidth, height: 1500)) {
        let fake = FakeServices()
        fake.current.settings.networkShares = sampleShares
        fake.current.shareStates = sampleStates
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs,
                                page: .connections, privacyState: s)
        view.pageHeight = 1480
        return ViewSnapshots.wrapPicker(view.tabyPage().frame(maxHeight: .infinity, alignment: .top), model)
      },
      SnapshotSpec("view-share-card-form", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let form = ShareForm(name: "Archiv", address: "smb://nas.local/Archiv", user: "felix",
                             autoMount: true, folders: ["Unterlagen", "Rechnungen 2026"])
        return AnyView(ShareCard(shares: sampleShares, states: sampleStates, previewForm: form)
          .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top)
          .environment(\.tabySnapshot, true))
      },
      SnapshotSpec("view-share-card-form-error", size: CGSize(width: TabLayout.contentWidth, height: 520)) {
        let form = ShareForm(name: "Büro", address: "http://nas.local/Büro", user: "")
        return AnyView(ShareCard(shares: [], states: [:], previewForm: form)
          .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top)
          .environment(\.tabySnapshot, true))
      },
    ]
  }
}
