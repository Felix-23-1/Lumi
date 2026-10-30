// Prüfungen der Datenschutz-Schranke (A3): Nur-lokal, Einwilligung für Cloud-Modelle
// und Internet für Mods. Die HTTP-Grenze ist per URLProtocol gestubbt; gezählt wird,
// ob überhaupt eine Anfrage ankam.
import Foundation

@MainActor
enum PrivacyChecks {
  static let consentAt = "2026-10-01T09:00"

  /// Einwilligung für den Host von `baseUrl` (so wie die App sie speichert).
  static func consent(for baseUrl: String) -> String { PrivacyGate.consentValue(at: consentAt, baseUrl: baseUrl) }

  /// Dienst mit gestubbter Sitzung, Cloud-Modell und Schlüssel; Einwilligung und Nur-lokal nach Wunsch.
  static func rig(_ stub: StubServer, localOnly: Bool, consent: String) async throws -> CoreServices {
    var opts = CoreServices.Options(databasePath: nil, socketPath: nil,
                                    clock: ControllableClock("2026-10-16T09:00"), keyStore: InMemoryApiKeyStore(),
                                    systemNotifier: SinkNotifier(), plannerInterval: nil)
    opts.session = stub.session
    opts.appleIntelligence = false  // Prüfung unabhängig davon, ob der Mac Apple Intelligence hat
    let svc = try CoreServices(options: opts)
    _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub.baseUrl, llmModel: "test/cloud-modell",
                                               localOnly: localOnly,
                                               cloudConsentAt: consent.isEmpty ? "" : PrivacyChecks.consent(for: stub.baseUrl)),
                                    apiKey: "sk-test-privat")
    return svc
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Datenschutz: Schranke nur mit Einwilligung für Cloud-Modelle") {
        var s = TabySettings(llmBaseUrl: "https://x.test/v1", llmModel: "m")
        try expect(PrivacyGate.needsConsent(s, model: "m"), "Cloud-Modell ohne Einwilligung")
        s.cloudConsentAt = PrivacyGate.consentValue(at: consentAt, baseUrl: "https://x.test/v1")
        try expect(!PrivacyGate.needsConsent(s, model: "m"), "mit Einwilligung für diesen Host frei")
        // Einwilligung gilt nur für den Host, dem sie erteilt wurde.
        s.llmBaseUrl = "https://other.test/v1"
        try expect(PrivacyGate.needsConsent(s, model: "m"), "anderer Host fragt erneut")
        s.llmBaseUrl = "https://x.test/v1"
        s.cloudConsentAt = consentAt  // alter Wert ohne Host gilt nur für openrouter.ai
        try expect(PrivacyGate.needsConsent(s, model: "m"), "alter Wert ohne Host zählt nicht für x.test")
        s.llmBaseUrl = "https://openrouter.ai/api/v1"
        try expect(!PrivacyGate.needsConsent(s, model: "m"), "alter Wert gilt für openrouter.ai")
        s.llmBaseUrl = "https://x.test/v1"
        s.cloudConsentAt = PrivacyGate.consentValue(at: consentAt, baseUrl: "https://x.test/v1")
        s.cloudConsentAt = ""
        try expect(!PrivacyGate.needsConsent(s, model: TabySettings.appleIntelligenceModel), "Apple braucht keine")
        try expect(!PrivacyGate.needsConsent(TabySettings(llmBaseUrl: "http://localhost:1234/v1", llmModel: "m"), model: "m"),
                   "lokaler Endpunkt braucht keine")
        s.localOnly = true
        try expect(!PrivacyGate.needsConsent(s, model: "m"), "Nur-lokal: Frage entfällt")
      },
      CheckCase("Schlüssel: Altschlüssel nur für openrouter.ai, neuer Host braucht eigenen") {
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil,
                                        clock: ControllableClock("2026-10-16T09:00"),
                                        keyStore: InMemoryApiKeyStore("sk-or-alt"),
                                        systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.llmHostKeyStore = { _ in InMemoryApiKeyStore() }
        let svc = try CoreServices(options: opts)
        try expect(svc.settings.hasApiKey, "Altschlüssel gehört zu openrouter.ai")
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: "https://api.example.com/v1"), apiKey: nil)
        try expect(!svc.settings.hasApiKey, "Altschlüssel geht nicht an api.example.com")
        _ = await svc.updateSettings(SettingsPatch(), apiKey: "sk-anbieter")
        try expect(svc.settings.hasApiKey, "eigener Schlüssel für den Host gespeichert")
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: "https://openrouter.ai/api/v1"), apiKey: nil)
        try expect(svc.settings.hasApiKey, "zurück zu openrouter.ai: Altschlüssel wieder da")
      },
      CheckCase("Schlüssel-Migration: Altschlüssel wandert an den eingestellten Host, nur einmal") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-16T09:00"))
        _ = try store.settings.update(SettingsPatch(llmBaseUrl: "https://api.example.com/v1"))
        let oldKey = InMemoryApiKeyStore("sk-alt")
        let host = InMemoryApiKeyStore()
        CoreServices.migrateLegacyLlmKey(store: store, keyStore: oldKey, hostKeyStore: { _ in host })
        try expectEqual(try host.get(), "sk-alt", "Altschlüssel am Host")
        try expectEqual(try oldKey.get(), nil, "nicht mehr unter openrouter.ai")
        try expect(!((try? store.db.query("SELECT key FROM app_settings WHERE key = 'llmKeyHostMigrated'")) ?? []).isEmpty,
                   "Markierung gesetzt")
        // Ein späterer Start (Markierung gesetzt) verschiebt nichts mehr.
        let newOld = InMemoryApiKeyStore("sk-neu")
        CoreServices.migrateLegacyLlmKey(store: store, keyStore: newOld, hostKeyStore: { _ in host })
        try expectEqual(try newOld.get(), "sk-neu", "einmalig: unberührt")
      },
      CheckCase("Datenschutz: ohne Einwilligung kommt CONSENT und nichts geht raus") {
        let stub = StubServer([StubServer.completion(#"{"role":"assistant","content":"Hallo"}"#)])
        let svc = try await rig(stub, localOnly: false, consent: "")
        do {
          _ = try await svc.chatSend("Was steht heute an?")
          throw fail("Ohne Einwilligung hätte der Chat nicht senden dürfen")
        } catch let e as LlmError {
          try expectEqual(e.message, PrivacyGate.consentCode, "Fehlercode CONSENT")
        }
        try expectEqual(stub.requests.count, 0, "kein Netzaufruf ohne Einwilligung")
        let saved = await svc.state().messages
        try expect(saved.isEmpty, "Nachricht nicht gespeichert, bevor eingewilligt wird")
        // Briefing ohne Einwilligung: kein Modell, kein Netz, nur der Text ohne Modell.
        await svc.answerDayStart(.yes)
        try expectEqual(stub.requests.count, 0, "Briefing sendet ohne Einwilligung nichts")
      },
      CheckCase("Datenschutz: mit Einwilligung antwortet das Modell") {
        let stub = StubServer([StubServer.completion(#"{"role":"assistant","content":"Hallo"}"#)])
        let svc = try await rig(stub, localOnly: false, consent: consentAt)
        let messages = try await svc.chatSend("Hallo")
        try expect(messages.contains { $0.content == "Hallo" }, "Antwort des Modells")
        try expectEqual(stub.requests.count, 1, "genau eine Anfrage nach Einwilligung")
      },
      CheckCase("Datenschutz: Nur-lokal ohne Apple Intelligence sendet nie und sagt es") {
        let stub = StubServer([StubServer.completion(#"{"role":"assistant","content":"Hallo"}"#)])
        let svc = try await rig(stub, localOnly: true, consent: consentAt)
        let messages = try await svc.chatSend("Hallo")
        let last = messages.last(where: { $0.role == .assistant })?.content ?? ""
        try expect(last.hasPrefix("Nur-lokal-Modus – kein Modell verfügbar"), "Hinweis im Chat")
        try expectEqual(stub.requests.count, 0, "Nur-lokal: keine Anfrage an die Cloud")
      },
      CheckCase("Datenschutz: Nur-lokal mit Cloud-Modell nimmt Apple Intelligence statt nichts") {
        let stub = StubServer([StubServer.completion(#"{"role":"assistant","content":"Hallo"}"#)])
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil,
                                        clock: ControllableClock("2026-10-16T09:00"), keyStore: InMemoryApiKeyStore(),
                                        systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.session = stub.session
        opts.appleIntelligence = true
        let svc = try CoreServices(options: opts)
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub.baseUrl, llmModel: "test/cloud-modell", localOnly: true),
                                     apiKey: "sk-test-privat")
        let client = await MainActor.run { svc.llmClient() }
        try expect(client is AppleIntelligenceClient, "Apple Intelligence statt Cloud")
        try expectEqual(stub.requests.count, 0, "nichts an die Cloud")
      },
      CheckCase("Datenschutz: Mod-Internet im Nur-lokal-Modus abgelehnt") {
        let stub = StubServer([StubServer.completion(#"{"role":"assistant","content":"x"}"#)])
        let code = #"async function run(){ return await taby.http.get("https://\#(stub.host)/wetter") }"#
        let manifest = ModManifest(id: "pruefung-netz", name: "Prüfung", description: "Prüfung", kind: .script,
                                   entry: "main.js", permissions: ["http:\(stub.host)"])
        do {
          _ = try await ScriptModRunner(host: PrivacyModHost(), session: stub.session, localOnly: true)
            .run(code: code, manifest: manifest, input: .null)
          throw fail("Nur-lokal hätte den Abruf nicht erlauben dürfen")
        } catch let e as ScriptModError {
          try expectEqual(e.errorDescription, "Nur-lokal-Modus: Internet für Mods ist aus.", "Meldung")
        }
        try expectEqual(stub.requests.count, 0, "Mod sendet im Nur-lokal-Modus nichts")
        // Gegenprobe: ohne Nur-lokal geht der freigegebene Abruf durch.
        _ = try await ScriptModRunner(host: PrivacyModHost(), session: stub.session)
          .run(code: code, manifest: manifest, input: .null)
        try expectEqual(stub.requests.count, 1, "freigegebener Abruf ohne Nur-lokal")
      },
    ]
  }
}

/// Mod-Host ohne Daten; die Prüfung braucht nur den HTTP-Pfad.
private final class PrivacyModHost: ModHostAPI, @unchecked Sendable {
  func listTasks() async throws -> [TabyTask] { [] }
  func addTask(title: String, due: String?) async throws -> TabyTask { throw ScriptBridgeError("nicht geprüft") }
  func completeTask(id: String) async throws {}
  func listNotes() async throws -> [Note] { [] }
  func addNote(title: String, content: String) async throws -> Note { throw ScriptBridgeError("nicht geprüft") }
  func listEvents(from: String, to: String) async throws -> [CalendarEvent] { [] }
  func notify(_ n: TabyNotification) {}
  func setIslandText(_ text: String, seconds: Double) {}
}
