// Prüfungen der „Erklär mir das“-Karte: Zustandslogik, Weiterfragen-Text und Snapshots
// in den drei Phasen (lädt, Antwort, Fehler). Der Kern hat eigene Prüfungen (ExplainTextChecks).
import SwiftUI
import TabyCore

enum ExplainChecks {
  static let original = "Die Gewährleistung gilt zwei Jahre ab Übergabe der Ware."
  static let answer = "Gewährleistung heißt: Der Verkäufer haftet zwei Jahre dafür, dass die Ware bei Übergabe in Ordnung ist. Zeigt sich ein Mangel, kannst du Nachbesserung oder Ersatz verlangen. Beispiel: Ein Laptop geht nach einem Jahr kaputt, obwohl er schon beim Kauf einen Fehler hatte – dann muss der Verkäufer reparieren."

  static let draft = "Hallo, vielen Dank für Ihre Nachricht. Die Gewährleistung läuft zwei Jahre ab Übergabe; bei einem Mangel können Sie Nachbesserung oder Ersatz verlangen.\n\nFreundliche Grüße"

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Erklär-Karte: Weiterfragen beginnt mit dem markierten Text") {
        let prompt = ExplainCardState.chatPrompt(for: "Hallo")
        try expect(prompt.contains("„Hallo“"), prompt)
      },
      CheckCase("Erklär-Karte: Einrichten-Knopf nur bei fehlendem KI-Zugang") {
        let noModel = ExplainCardState(original: "a", phase: .failure("Erklären braucht ein Modell. Richte einen Zugang in den Einstellungen ein."))
        try expect(noModel.needsAISetup, "fehlender Zugang")
        try expect(!ExplainCardState(original: "a", phase: .failure("Die Erklärung ist gerade nicht möglich.")).needsAISetup, "anderer Fehler")
        try expect(!ExplainCardState(original: "a", phase: .answer("x")).needsAISetup, "Antwort")
      },
      CheckCase("Erklär-Karte: Gleichheit nach Inhalt und Phase") {
        try expect(ExplainCardState(original: "a") == ExplainCardState(original: "a"), "gleicher Stand")
        try expect(ExplainCardState(original: "a", phase: .answer("x")) != ExplainCardState(original: "a"),
                   "Antwort ist ein anderer Stand als Ladezustand")
      },
      CheckCase("Erklär-Schalter: ohne gespeicherte Wahl wird vorgelesen") {
        if UserDefaults.standard.object(forKey: ExplainSettings.speakKey) == nil {
          try expect(ExplainSettings.speak, "Standard ist an")
        }
      },
      CheckCase("Entwurf: Grußformel-Schlüssel und Standard leer") {
        try expect(DraftSettings.signatureKey == "taby.draft.signature", DraftSettings.signatureKey)
        if UserDefaults.standard.object(forKey: DraftSettings.signatureKey) == nil {
          try expect(DraftSettings.signature.isEmpty, "Standard ist leer")
        }
      },
      CheckCase("Entwurf: mailto-Link kodiert den Text und sendet nichts") {
        let body = "Hallo & Gruß + 2 = 3\nDank"
        let s = ExplainCardState.mailtoURL(for: body)?.absoluteString ?? ""
        try expect(s.hasPrefix("mailto:?body="), s)
        let encoded = String(s.dropFirst("mailto:?body=".count))
        try expect(!encoded.contains("&") && !encoded.contains("+") && !encoded.contains("\n"), encoded)
        try expect(encoded.removingPercentEncoding == body, "Rückübersetzung weicht ab")
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-explain-answer", size: CGSize(width: TabLayout.contentWidth, height: 190)) {
        wrap(ExplainCard(state: ExplainCardState(original: original, phase: .answer(answer)),
                         onAskInChat: {}, onDone: {}), AppModel(services: FakeServices(sample: false)))
      },
      SnapshotSpec("view-explain-draft", size: CGSize(width: TabLayout.contentWidth, height: 200)) {
        wrap(ExplainCard(state: ExplainCardState(original: original, phase: .answer(answer)),
                         onAskInChat: {}, onDone: {}, initialDraft: draft), AppModel(services: FakeServices(sample: false)))
      },
      SnapshotSpec("view-explain-loading",size: CGSize(width: TabLayout.contentWidth, height: 90)) {
        wrap(ExplainCard(state: ExplainCardState(original: original),
                         onAskInChat: {}, onDone: {}), AppModel(services: FakeServices(sample: false)))
      },
      SnapshotSpec("view-explain-failure", size: CGSize(width: TabLayout.contentWidth, height: 120)) {
        wrap(ExplainCard(state: ExplainCardState(original: original,
                                                 phase: .failure("Erklären braucht ein Modell. Richte einen Zugang in den Einstellungen ein.")),
                         onAskInChat: {}, onDone: {}), AppModel(services: FakeServices(sample: false)))
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }
}
