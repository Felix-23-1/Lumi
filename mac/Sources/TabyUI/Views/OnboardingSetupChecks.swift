// Prüfungen der Einrichtung: Modell-Auswahl als Einstellungs-Patch, Fortsetzen nach dem
// Neustart, „So geht’s“-Kacheln und die Links zu den Systemeinstellungen.
import Foundation
import TabyCore

enum OnboardingSetupChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Einrichtung Modell: Apple setzt Chat- und Briefing-Modell auf Apple Intelligence") {
        let p = OnboardingModelPatch.patch(choice: .apple, provider: LlmProviders.openAI, model: "egal")
        try expectEqual(p.llmModel, TabySettings.appleIntelligenceModel)
        try expectEqual(p.briefingModel, TabySettings.appleIntelligenceModel)
        try expect(p.llmBaseUrl == nil, "Apple ändert den Endpunkt nicht")
      },
      CheckCase("Einrichtung Modell: Cloud mit leerem Modell nimmt den Vorschlag des Anbieters") {
        let p = OnboardingModelPatch.patch(choice: .cloud, provider: LlmProviders.anthropic, model: "   ")
        try expectEqual(p.llmBaseUrl, LlmProviders.anthropic.baseUrl)
        try expectEqual(p.llmModel, LlmProviders.anthropic.defaultModel)
      },
      CheckCase("Einrichtung Modell: Cloud behält ein eigenes Modell") {
        let p = OnboardingModelPatch.patch(choice: .cloud, provider: LlmProviders.groq, model: " meins/modell ")
        try expectEqual(p.llmModel, "meins/modell")
        try expectEqual(p.llmBaseUrl, LlmProviders.groq.baseUrl)
      },
      CheckCase("Einrichtung Modell: Ohne KI ändert nichts") {
        let p = OnboardingModelPatch.patch(choice: .none, provider: LlmProviders.openRouter, model: "x")
        try expect(p.llmModel == nil && p.llmBaseUrl == nil && p.briefingModel == nil, "leerer Patch")
      },
      CheckCase("Einrichtung: Schritt wird gemerkt und nach dem Neustart wieder gelesen") {
        let defaults = try expectNotNil(UserDefaults(suiteName: "taby-check-\(UUID().uuidString)"), "Suite")
        try expect(OnboardingResume.savedStep(in: defaults) == nil, "zuerst nichts gespeichert")
        OnboardingResume.save(.model, in: defaults)
        try expectEqual(OnboardingResume.savedStep(in: defaults), .model)
        OnboardingResume.clear(in: defaults)
        try expect(OnboardingResume.savedStep(in: defaults) == nil, "nach dem Abschluss leer")
      },
      CheckCase("Einrichtung aus der Menüleiste: Signieren merkt die Freigaben, Abschluss räumt auf") {
        let defaults = try expectNotNil(UserDefaults(suiteName: "taby-check-\(UUID().uuidString)"), "Suite")
        try expect(!OnboardingResume.isSigningReturn(in: defaults), "zuerst nicht")
        OnboardingResume.markSigningReturn(in: defaults)
        try expectEqual(OnboardingResume.savedStep(in: defaults), .calendar, "Freigaben-Schritt")
        try expect(OnboardingResume.isSigningReturn(in: defaults), "Hinweis aktiv")
        OnboardingResume.clear(in: defaults)
        try expect(!OnboardingResume.isSigningReturn(in: defaults), "Hinweis nach dem Abschluss weg")
      },
      CheckCase("Einrichtung: Überspringen nur bei fehlgeschlagener Signatur, Fehlertext nennt die Menüleiste") {
        try expect(!SetupState.idle.isFailed && !SetupState.running.isFailed, "ohne Fehler")
        try expect(SetupState.failed("x").isFailed, "mit Fehler")
      },
      CheckCase("So geht’s: sechs Kacheln mit Titel und Text") {
        try expectEqual(HowToContent.tiles.count, 6)
        try expectEqual(HowToContent.tiles.first?.title, "Vorschau")
        try expect(HowToContent.tiles.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty }, "Text je Kachel")
      },
      CheckCase("Freigaben: Systemeinstellungen-Links für jede Freigabe") {
        for kind in PermissionKind.allCases {
          try expect(kind.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:"), "\(kind)")
        }
        try expect(PermissionKind.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"), "Bedienungshilfen")
        try expect(PermissionKind.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"), "Mikrofon")
      },
    ]
  }
}
