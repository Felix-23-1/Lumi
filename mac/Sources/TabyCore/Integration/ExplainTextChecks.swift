// Prüfungen von „Erklär mir das“ gegen den echten Kern. Modell-HTTP ist die Grenze (StubServer),
// der Sprecher ein Sammler (SinkSpeaker).
import Foundation

enum ExplainTextChecks {
  @MainActor static func rig(_ replies: [StubReply]) throws -> (CoreServices, SinkSpeaker, StubServer) {
    let speaker = SinkSpeaker()
    let stub = StubServer(replies)
    var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                    keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
                                    session: stub.session, plannerInterval: nil)
    opts.speaker = speaker
    opts.appleIntelligence = false
    return (try CoreServices(options: opts), speaker, stub)
  }

  @MainActor static func configured(_ replies: [StubReply]) async throws -> (CoreServices, SinkSpeaker, StubServer) {
    let (svc, speaker, stub) = try rig(replies)
    _ = await svc.updateSettings(
      SettingsPatch(llmBaseUrl: stub.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub.baseUrl)),
      apiKey: "sk-integration-test")
    return (svc, speaker, stub)
  }

  /// Erwarteter Nachrichtenverlauf im Anfrage-Körper: Systemprompt, dann der markierte Text.
  static func messages(system: String, user: String) -> JSONValue {
    .array([.object(["role": .string("system"), "content": .string(system)]),
            .object(["role": .string("user"), "content": .string(user)])])
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Erklären: leerer Text ist ein deutscher Fehler, es wird kein Modell gerufen") {
        let (svc, _, stub) = try await configured([StubServer.text("nie")])
        let r = await svc.explainText("   \n ", speak: false)
        try expect(!r.isOk, "leer muss scheitern")
        try expect(r.errorMessage?.contains("markiert") == true, r.errorMessage ?? "")
        try expect(stub.requests.isEmpty, "kein Aufruf des Modells")
      },
      CheckCase("Erklären ohne Modell: freundlicher Fehler, kein Raten") {
        let (svc, speaker, _) = try rig([])
        let r = await svc.explainText("Gewährleistung", speak: true)
        try expect(!r.isOk, "ohne Modell muss scheitern")
        try expect(r.errorMessage?.isEmpty == false, "Fehlertext fehlt")
        try expect(speaker.spoken.isEmpty, "nichts sprechen")
      },
      CheckCase("Erklären: Antwort kommt zurück, Modell bekommt Systemprompt und Text, aber keine Werkzeuge") {
        let (svc, speaker, stub) = try await configured([StubServer.text("  Das heißt: Frist.  ")])
        let r = await svc.explainText("Gewährleistung", speak: false)
        try expectEqual(r.value, "Das heißt: Frist.")
        let body = try expectNotNil(stub.requests.first?.body)
        try expect(body["tools"] == nil, "das Modell darf keine Werkzeuge bekommen")
        try expectEqual(body["messages"], ExplainTextChecks.messages(system: CoreServices.explainPrompt, user: "Gewährleistung"))
        try expect(speaker.spoken.isEmpty, "speak=false spricht nicht")
      },
      CheckCase("Erklären: Text wird vor dem Modell auf 4000 Zeichen gekürzt") {
        let (svc, _, stub) = try await configured([StubServer.text("ok")])
        _ = await svc.explainText(String(repeating: "a", count: 5000), speak: false)
        let messages = try expectNotNil(stub.requests.first?.body?["messages"])
        try expectEqual(messages, ExplainTextChecks.messages(system: CoreServices.explainPrompt,
                                                user: String(repeating: "a", count: CoreServices.explainMaxChars)))
      },
      CheckCase("Erklären mit speak: Sprecher bekommt die Antwort genau einmal") {
        let (svc, speaker, stub) = try await configured([StubServer.text("Kurz erklärt.")])
        let r = await svc.explainText("Gewährleistung", speak: true)
        try expect(r.value == "Kurz erklärt.", r.errorMessage ?? "ohne Fehlertext")
        try expectEqual(speaker.spoken, ["Kurz erklärt."])
        try expectEqual(stub.requests.count, 1, "genau ein Modellaufruf")
      },
      CheckCase("Erklären: Modellfehler wird zur deutschen Meldung, nichts wird gesprochen") {
        let (svc, speaker, stub) = try await configured([.json(status: 500, body: "{}")])
        let r = await svc.explainText("Gewährleistung", speak: true)
        try expect(!r.isOk, "Fehler muss ankommen")
        try expect(r.errorMessage?.isEmpty == false, "Fehlertext fehlt")
        try expect(speaker.spoken.isEmpty, "bei Fehler nichts sprechen")
        try expect(stub.requests.count == 1, "der Stub-Server muss bis zum Ende leben")
      },
    ]
  }
}
