// Snapshots der Microsoft-Karte auf der Seite „Verbindungen“: Anleitung offen, Gerätecode
// angezeigt und angemeldet (je in Notch-Breite).
import SwiftUI
import TabyCore

enum MicrosoftSnapshots {
  static let sampleCode = MicrosoftSignIn(userCode: "ABCD-1234", verificationUrl: "https://microsoft.com/devicelogin",
                                          expiresInSeconds: 900)

  @MainActor static var all: [SnapshotSpec] {
    [
      SnapshotSpec("view-settings-microsoft-help", size: CGSize(width: TabLayout.contentWidth, height: 720)) {
        var settings = TabySettings.defaults
        settings.microsoftClientId = ""
        return ViewSnapshots.wrapPicker(
          SettingsMicrosoftCard(form: .constant(settings), account: "", previewHelpOpen: true)
            .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top),
          AppModel(services: FakeServices()))
      },
      SnapshotSpec("view-settings-microsoft-code", size: CGSize(width: TabLayout.contentWidth, height: 560)) {
        var settings = TabySettings.defaults
        settings.microsoftClientId = "11111111-2222-3333-4444-555555555555"
        return ViewSnapshots.wrapPicker(
          SettingsMicrosoftCard(form: .constant(settings), account: "", previewPhase: .waiting(sampleCode))
            .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top),
          AppModel(services: FakeServices()))
      },
      SnapshotSpec("view-settings-microsoft-connected", size: CGSize(width: TabLayout.contentWidth, height: 260)) {
        var settings = TabySettings.defaults
        settings.microsoftClientId = "11111111-2222-3333-4444-555555555555"
        return ViewSnapshots.wrapPicker(
          SettingsMicrosoftCard(form: .constant(settings), account: "felix@beispiel.de")
            .padding(.horizontal, 16).frame(maxHeight: .infinity, alignment: .top),
          AppModel(services: FakeServices()))
      },
    ]
  }
}
