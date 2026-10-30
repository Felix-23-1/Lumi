// Prüfungen und Vorschauen der Datenschutz-Ansichten (Tabelle, Einwilligung, Nur-lokal-Hinweis).
import Foundation
import SwiftUI
import TabyCore

@MainActor
enum PrivacyViewChecks {
  static var cases: [CheckCase] {
    [
      CheckCase("Datenschutz: Host ohne Schema und Pfad") {
        try expectEqual(PrivacyLogic.host("https://openrouter.ai/api/v1"), "openrouter.ai")
        try expectEqual(PrivacyLogic.host("http://localhost:1234/v1"), "localhost")
        try expectEqual(PrivacyLogic.host("  "), "")
      },
      CheckCase("Datenschutz: Datum deutsch") {
        try expectEqual(PrivacyLogic.germanDate("2026-10-01T09:00"), "01.10.2026")
      },
      CheckCase("Datenschutz: Tabelle nennt nur eingerichtete Dienste") {
        var s = TabySettings.defaults
        s.llmBaseUrl = "https://openrouter.ai/api/v1"
        s.llmModel = "anbieter/modell"
        var st = AppState(settings: s)
        var features = PrivacyLogic.flows(st).map(\.feature)
        try expectEqual(features, ["Chat & Briefing", "Diktat", "Updates"], "Standard ohne Verbindungen")
        try expectEqual(PrivacyLogic.flows(st).first?.destination, "openrouter.ai")
        st.notionTasksConnected = true
        st.messengerAccounts = [MessengerAccount(id: "m1", service: .matrix, server: "https://matrix.example.org", user: "@a:example.org"),
                                MessengerAccount(id: "s1", service: .slack, user: "Team")]
        st.mods = [ModInfo(manifest: ModManifest(id: "wetter", name: "Wetter", description: "Wetter", kind: .script,
                                                 entry: "main.js", permissions: ["http:open-meteo.com"]))]
        features = PrivacyLogic.flows(st).map(\.feature)
        try expectEqual(features, ["Chat & Briefing", "Diktat", "Notion", "Slack", "Element", "Wetter-Mod", "Updates"],
                        "mit Verbindungen und Wetter-Mod")
        try expectEqual(PrivacyLogic.flows(st).first { $0.feature == "Element" }?.destination, "matrix.example.org")
      },
      CheckCase("Datenschutz: Apple Intelligence als Ziel ohne Host") {
        var s = TabySettings.defaults
        s.llmModel = TabySettings.appleIntelligenceModel
        let chat = PrivacyLogic.flows(AppState(settings: s)).first
        try expectEqual(chat?.destination, "Apple Intelligence (auf deinem Mac)")
        try expect(!PrivacyLogic.isCloud(s), "Apple ist kein Cloud-Modell")
      },
    ]
  }

  /// Vorschauen: Datenschutz-Seite (eigenes Fenster), Einwilligungskarte und Nur-lokal-Hinweis im Chat.
  @MainActor static var snapshots: [SnapshotSpec] {
    func fixture(localOnly: Bool = false, consent: String = "") -> AppState {
      var s = TabySettings.defaults
      s.llmBaseUrl = "https://openrouter.ai/api/v1"
      s.llmModel = "anbieter/modell"
      s.hasApiKey = true
      s.localOnly = localOnly
      s.cloudConsentAt = consent
      var st = AppState(settings: s)
      st.notionTasksConnected = true
      st.messengerAccounts = [MessengerAccount(id: "s1", service: .slack, user: "Team")]
      st.mods = [ModInfo(manifest: ModManifest(id: "wetter", name: "Wetter", description: "Wetter", kind: .script,
                                               entry: "main.js", permissions: ["http:open-meteo.com"]))]
      return st
    }
    return [
      SnapshotSpec("view-privacy-page", size: CGSize(width: 760, height: 640)) {
        let st = fixture(consent: "2026-10-01T09:00")
        let model = AppModel(services: FakeServices())
        return AnyView(SettingsView(settings: st.settings, sources: [], jobs: [], page: .privacy, layout: .window,
                                    privacyState: st)
          .environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
      },
      SnapshotSpec("view-privacy-consent-card", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        let st = fixture()
        let model = AppModel(services: FakeServices())
        return AnyView(ChatView(state: st, controller: ChatController(consentRetry: "Was steht heute an?"))
          .tabyPage()
          .environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
      },
      SnapshotSpec("view-privacy-localonly-chat", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        let st = fixture(localOnly: true)
        let model = AppModel(services: FakeServices())
        return AnyView(ChatView(state: st).tabyPage()
          .environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
      },
      SnapshotSpec("view-chat-dropped-file", size: CGSize(width: TabLayout.contentWidth, height: 340)) {
        let fake = FakeServices(sample: true)
        let model = AppModel(services: fake)
        model.droppedFiles = ["/Users/test/Angebot.pdf"]
        return AnyView(ChatView(state: fake.current).tabyPage()
          .environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
      },
    ]
  }
}
