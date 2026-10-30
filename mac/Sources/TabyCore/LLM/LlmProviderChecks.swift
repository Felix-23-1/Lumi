// Prüfungen für die Anbieter-Voreinstellungen: feste URLs, Zuordnung URL → Anbieter,
// Schlüssel je Host über den Kern (Speicher je Host, kein Netz).
import Foundation

enum LlmProviderChecks {
  static let cases: [CheckCase] = [
    CheckCase("Anbieter-Voreinstellungen: feste URLs und Vorschlags-Modelle") {
      let table: [(LlmProvider, String, String)] = [
        (LlmProviders.openRouter, "https://openrouter.ai/api/v1", "openai/gpt-4o-mini"),
        (LlmProviders.openAI, "https://api.openai.com/v1", "gpt-4o-mini"),
        (LlmProviders.anthropic, "https://api.anthropic.com/v1", "claude-sonnet-5-5"),
        (LlmProviders.gemini, "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.0-flash"),
        (LlmProviders.mistral, "https://api.mistral.ai/v1", "mistral-small-latest"),
        (LlmProviders.groq, "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
        (LlmProviders.deepSeek, "https://api.deepseek.com/v1", "deepseek-chat"),
      ]
      try expectEqual(LlmProviders.all.count, table.count)
      for (p, url, model) in table {
        try expectEqual(p.baseUrl, url, p.name)
        try expectEqual(p.defaultModel, model, p.name)
        try expect(p.keyUrl.hasPrefix("https://"), "Schlüssel-Link per https: \(p.name)")
      }
    },
    CheckCase("Voreinstellung zu URL: Host-Vergleich, lokal und fremde Hosts sind keine Voreinstellung") {
      for p in LlmProviders.all { try expectEqual(LlmProviders.preset(forBaseUrl: p.baseUrl), p, p.name) }
      try expectEqual(LlmProviders.preset(forBaseUrl: "https://api.groq.com/openai/v1/")?.name, "Groq")
      try expectEqual(LlmProviders.preset(forBaseUrl: "https://API.OpenAI.com/v1")?.name, "OpenAI")
      try expectEqual(LlmProviders.preset(forBaseUrl: "http://localhost:11434/v1"), nil, "lokal")
      try expectEqual(LlmProviders.preset(forBaseUrl: "https://example.com/v1"), nil, "eigener Anbieter")
      try expectEqual(LlmProviders.preset(forBaseUrl: "https://openrouter.ai.example.com/v1"), nil, "Präfix-Trick")
      try expectEqual(LlmProviders.preset(forBaseUrl: "https://api.openai.com@evil.example/v1"), nil, "Zugangsdaten-Trick")
    },
    CheckCase("Voreinstellung setzt URL und Modell, Briefing-Modell folgt dem Chat") {
      var s = TabySettings.defaults
      s.llmBaseUrl = "https://openrouter.ai/api/v1"
      s.llmModel = "openai/gpt-4o"
      s.briefingModel = "openai/gpt-4o-mini"
      LlmProviders.apply(LlmProviders.mistral, to: &s)
      try expectEqual(s.llmBaseUrl, "https://api.mistral.ai/v1")
      try expectEqual(s.llmModel, "mistral-small-latest")
      try expectEqual(s.briefingModel, "", "altes Briefing-Modell eines anderen Anbieters fliegt raus")
    },
    CheckCase("Schlüsselkonto je Anbieter-Host: OpenRouter bleibt beim alten Konto, sonst eigenes Konto") {
      var accounts = Set<String>()
      for p in LlmProviders.all {
        let account = LlmConnection.keyAccount(host: p.host)
        try expect(accounts.insert(account).inserted, "Konto eindeutig: \(p.name)")
        if p.host != LlmConnection.defaultHost {
          try expectEqual(account, "llm-api-key@\(p.host)", p.name)
        }
      }
      try expectEqual(LlmConnection.keyAccount(host: LlmProviders.openRouter.host), "llm-api-key")
    },
    CheckCase("Ohne eigenen Schlüssel geht kein Verbindungstest los und kein Schlüssel wandert zu einem anderen Host") {
      var s = TabySettings.defaults
      LlmProviders.apply(LlmProviders.openAI, to: &s)
      let empty = InMemoryApiKeyStore()
      let r = await LlmConnection.test(settings: s, keyStore: empty)
      try expect(!r.ok)
      try expectEqual(r.message, "Für diesen Anbieter einen eigenen Schlüssel eintragen.")
      // Stub: Ein Schlüssel für OpenAI liegt im Speicher von OpenAI. Groq bekommt nur seinen eigenen Speicher.
      let openAIStore = InMemoryApiKeyStore()
      try openAIStore.set("sk-test-openai")
      LlmProviders.apply(LlmProviders.groq, to: &s)
      try expect(LlmConnection.makeClient(settings: s, keyStore: InMemoryApiKeyStore()) == nil,
                 "Groq ohne eigenen Schlüssel: kein Client, also kein Aufruf")
      try expectEqual(LlmConnection.keyToSend(baseUrl: LlmProviders.openAI.baseUrl, keyStore: openAIStore),
                      "sk-test-openai")
    },
    CheckCase("Kern: Schlüssel gehört zum Host, der Status „gesetzt“ folgt dem Endpunkt") {
      try await LlmProviderChecks.perHostKeysOnCore()
    },
  ]

  /// Kern mit Schlüsselspeicher je Host: Anbieterwechsel zeigt nur dort „gesetzt“, wo der Schlüssel liegt.
  @MainActor static func perHostKeysOnCore() async throws {
    let clock = ControllableClock("2026-10-16T09:00")
    let svc = try CoreServices(options: .init(
      databasePath: nil, socketPath: nil, clock: clock, keyStore: InMemoryApiKeyStore(),
      systemNotifier: SinkNotifier(), plannerInterval: nil,
      llmHostKeyStore: { _ in InMemoryApiKeyStore() }))
    var toOpenAI = SettingsPatch()
    toOpenAI.llmBaseUrl = LlmProviders.openAI.baseUrl
    _ = await svc.updateSettings(toOpenAI, apiKey: "sk-test-openai")
    try expectEqual(svc.settings.hasApiKey, true, "OpenAI: Schlüssel gesetzt")
    var toGroq = SettingsPatch()
    toGroq.llmBaseUrl = LlmProviders.groq.baseUrl
    _ = await svc.updateSettings(toGroq, apiKey: nil)
    try expectEqual(svc.settings.hasApiKey, false, "Groq: kein Schlüssel, OpenAIs Schlüssel bleibt draußen")
    var toRouter = SettingsPatch()
    toRouter.llmBaseUrl = LlmProviders.openRouter.baseUrl
    _ = await svc.updateSettings(toRouter, apiKey: nil)
    try expectEqual(svc.settings.hasApiKey, false, "OpenRouter: eigener Speicher, leer")
    _ = await svc.updateSettings(toOpenAI, apiKey: nil)
    try expectEqual(svc.settings.hasApiKey, true, "zurück zu OpenAI: Schlüssel wieder gesetzt")
  }
}
