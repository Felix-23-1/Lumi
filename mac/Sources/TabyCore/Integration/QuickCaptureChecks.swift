// Prüfungen der Schnellerfassung: ohne Modell, bei Modellfehler, Erfolgspfad
// und sauberer Chatverlauf. Modell-HTTP per StubServer, Speicher im Arbeitsspeicher.
import Foundation

enum QuickCaptureChecks {
  static let thought = "Milch kaufen\nIm Laden um die Ecke"

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Schnellerfassung ohne Modell speichert Aufgabe mit Titel und Notiz") {
        let (svc, _, _) = try modRig(modelReplies: nil)
        let out = try await svc.quickCapture(thought)
        try expectEqual(out.last?.content, "Als Aufgabe gespeichert (ohne Modell).")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Milch kaufen"])
        try expectEqual(st.tasks.first?.notes, "Im Laden um die Ecke")
        try expect(st.messages.isEmpty, "ohne Modell kein Verlauf")
      },

      CheckCase("Schnellerfassung: Titel höchstens 120 Zeichen, Rest in die Notiz") {
        let (svc, _, _) = try modRig(modelReplies: nil)
        _ = try await svc.quickCapture(String(repeating: "a", count: 150))
        let st = await svc.state()
        let t = try expectNotNil(st.tasks.first, "Aufgabe fehlt")
        try expectEqual(t.title.count, 120)
        try expectEqual(t.notes?.count, 30)
      },

      CheckCase("Schnellerfassung: Netzfehler speichert trotzdem als Aufgabe") {
        let (svc, _, stub) = try modRig(modelReplies: [.transportError(.notConnectedToInternet)])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        let out = try await svc.quickCapture(thought)
        try expectEqual(out.last?.content, "Als Aufgabe gespeichert (ohne Modell).")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Milch kaufen"])
      },

      CheckCase("Schnellerfassung: Modellfehler (HTTP 500) speichert trotzdem als Aufgabe") {
        let (svc, _, stub) = try modRig(modelReplies: [.json(status: 500, body: #"{"error":{"message":"mock"}}"#)])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        let out = try await svc.quickCapture(thought)
        try expectEqual(out.last?.content, "Als Aufgabe gespeichert (ohne Modell).")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Milch kaufen"])
      },

      CheckCase("Schnellerfassung: Modell nur mit Text geantwortet, Gedanke wird trotzdem Aufgabe") {
        let (svc, _, stub) = try modRig(modelReplies: [StubServer.text("Angelegt: Milch.")])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        let out = try await svc.quickCapture(thought)
        try expectEqual(out.last?.content, "Das Modell hat nichts angelegt, deshalb als Aufgabe gespeichert.")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Milch kaufen"])
      },

      CheckCase("Schnellerfassung: Modell legt an, dann Fehler, kein Duplikat") {
        let args = #"{"title":"Milch kaufen","notes":"Im Laden um die Ecke"}"#
        let (svc, _, stub) = try modRig(modelReplies: [StubServer.toolCall("add_task", args),
                                                       .json(status: 500, body: #"{"error":{"message":"mock"}}"#)])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        let out = try await svc.quickCapture(thought)
        try expectEqual(out.last?.content, "Gespeichert.")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Milch kaufen"])
      },

      CheckCase("Schnellerfassung mit Modell: Erfolg wie bisher, Anweisung nicht im Verlauf") {
        let (svc, _, stub) = try modRig(modelReplies: [StubServer.text("Angelegt: Milch.")])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        _ = try await svc.quickCapture(thought)
        let st = await svc.state()
        try expect(st.tasks.map(\.title) == ["Milch kaufen"], "Text ohne Anlage wird als Aufgabe gesichert")
        let texts = st.messages.compactMap(\.content)
        try expect(texts.contains(thought), "Originaltext fehlt im Verlauf")
        try expect(!texts.contains { $0.contains("Schnellerfassung") }, "Anweisung darf nicht im Verlauf stehen")
      },
    ]
  }
}
