// Prüfungen und Snapshots der Updates-Seite (Anzeige-Logik, Hinweis am Zahnrad, Ansicht).
import SwiftUI
import TabyCore

enum UpdatesPageChecks {
  static let sample = AppUpdate(commit: "def5678", date: "2026-10-18T10:42", currentCommit: "abc1234",
                                build: 531, currentBuild: 527,
                                notes: "Neu: Obsidian-Verbindung, eigene Aufgaben-Kategorien.\nEinrichtung ohne Terminal.")

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Updates-Seite: Versionszeile, Titel mit Datum und Notizen auf Deutsch") {
        try expectEqual(UpdatesPageLogic.currentLine(build: 527), "Lumi Version 2.527")
        try expectEqual(UpdatesPageLogic.currentLine(build: 0), "Lumi Version 2.0")
        try expectEqual(UpdatesPageLogic.availableTitle(sample), "Update verfügbar – Version 2.531 (vom 18.10.)")
        try expectEqual(UpdatesPageLogic.shortDate("2026-10-18T10:42"), "18.10.")
        try expectEqual(UpdatesPageLogic.shortDate("18.10.2026"), "18.10.2026", "unbekanntes Format bleibt")
        try expectEqual(UpdatesPageLogic.notesText(sample.notes)?.hasPrefix("Neu: Obsidian"), true)
      },
      CheckCase("Updates-Seite: leere Notizen fehlen, leere Quelle zeigt die GitHub-Adresse") {
        try expectEqual(UpdatesPageLogic.notesText(nil), nil)
        try expectEqual(UpdatesPageLogic.notesText(" \n "), nil)
        try expectEqual(UpdatesPageLogic.effectiveSource("  "), AppUpdate.defaultSource)
        try expectEqual(UpdatesPageLogic.effectiveSource(" https://example.com/taby "), "https://example.com/taby")
      },
      CheckCase("Datenschutz-Banner: Apple, lokal und Anbieter werden aus den Einstellungen abgeleitet") {
        let apple = PrivacyRoute.line(llmModel: TabySettings.appleIntelligenceModel, llmBaseUrl: "https://openrouter.ai/api/v1")
        try expectEqual(apple.text, "Nur lokal (Apple Intelligence)")
        try expectEqual(apple.local, true)
        let local = PrivacyRoute.line(llmModel: "x", llmBaseUrl: "http://localhost:11434/v1")
        try expectEqual(local.local, true, "lokale Adresse bleibt am Mac")
        let cloud = PrivacyRoute.line(llmModel: "x", llmBaseUrl: "https://openrouter.ai/api/v1")
        try expectEqual(cloud.local, false)
        try expect(cloud.text.hasPrefix("Anfragen gehen an: "), cloud.text)
        try expectEqual(PrivacyRoute.line(llmModel: "x", llmBaseUrl: "").local, true, "ohne Adresse nichts erfunden")
      },
      CheckCase("Updates-Seite: Punkt am Zahnrad nur bei verfügbarem Update") {
        let fake = FakeServices(sample: false)
        try expectEqual(OpenBoardTabs.needsAttention(.settings, state: fake.current), false)
        fake.current.update = sample
        try expectEqual(OpenBoardTabs.needsAttention(.settings, state: fake.current), true)
        try expectEqual(OpenBoardTabs.needsAttention(.settings, state: nil), false)
      },
    ]
  }

  /// Die Seite mit festen Werten (ohne Modell). Breite: Notch oder Fenster.
  @MainActor static func panel(_ update: AppUpdate?, advanced: Bool, width: CGFloat) -> AnyView {
    AnyView(
      UpdatesPanel(currentBuild: 527, update: update,
                   source: .constant(advanced ? "https://example.com/taby" : ""), advancedOpen: advanced)
        .padding(Theme.pad)
        .frame(width: width, alignment: .topLeading)
        .environment(\.colorScheme, .dark))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-updates-current-notch", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        panel(nil, advanced: false, width: TabLayout.contentWidth)
      },
      SnapshotSpec("view-updates-available-notch", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        panel(sample, advanced: false, width: TabLayout.contentWidth)
      },
      SnapshotSpec("view-updates-advanced-notch", size: CGSize(width: TabLayout.contentWidth, height: 460)) {
        panel(sample, advanced: true, width: TabLayout.contentWidth)
      },
      SnapshotSpec("view-updates-available-window", size: CGSize(width: 760, height: 420)) {
        panel(sample, advanced: true, width: 760)
      },
    ]
  }
}
