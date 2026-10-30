// Verdrahtung Einstellungen + Schlüsselbund → LlmClient, Modellliste und
// „Verbindung testen“ (Port von getLlmClient in src/main/appContext.ts und
// den Handlern models:list / llm:test in src/main/ipc/index.ts).
import Foundation

public enum LlmConnection {
  /// Anbieter des bisherigen (einzigen) Schlüssels; sein Eintrag bleibt unter dem alten Konto.
  public static let defaultHost = "openrouter.ai"

  /// Host einer Endpunkt-URL in Kleinbuchstaben, ohne Port und Pfad. nil bei ungültiger URL
  /// oder wenn Zugangsdaten (`user@`) im Spiel sind (Tricks wie `localhost:1@evil.example`).
  public static func host(of baseUrl: String) -> String? {
    let t = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !t.contains("@") else { return nil }
    let full = t.contains("://") ? t : "https://" + t
    guard let parts = URLComponents(string: full), let scheme = parts.scheme?.lowercased(),
          scheme == "http" || scheme == "https", parts.user == nil, parts.password == nil,
          let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
    return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  }

  /// Konto im Schlüsselbund je Anbieter-Host (openrouter.ai: das bisherige Konto).
  public static func keyAccount(host: String) -> String {
    host == defaultHost ? KeychainApiKeyStore.defaultAccount : KeychainApiKeyStore.defaultAccount + "@" + host
  }

  /// true für Endpunkte auf diesem Rechner (z. B. Ollama, LM Studio): dort
  /// ist kein API-Key nötig.
  public static func isLocalEndpoint(_ baseUrl: String) -> Bool {
    guard let host = host(of: baseUrl) else { return false }
    return ["localhost", "127.0.0.1", "::1"].contains(host)
  }

  /// Schlüssel für eine Anfrage an `baseUrl`. `keyStore` ist der Speicher des Endpunkt-Hosts
  /// (siehe CoreServices.llmKeyStore). Lokale Endpunkte bekommen nie den Schlüssel.
  static func keyToSend(baseUrl: String, keyStore: ApiKeyStore) -> String? {
    guard !isLocalEndpoint(baseUrl), let k = try? keyStore.get(), !k.isEmpty else { return nil }
    return k
  }

  /// Client aus den Einstellungen; nil, wenn Endpunkt oder Modell fehlen
  /// oder ein Remote-Endpunkt ohne Key konfiguriert ist. Ein nicht leeres
  /// `model` ersetzt `settings.llmModel`; `onUsage` erhält den Verbrauch.
  public static func makeClient(settings: TabySettings, keyStore: ApiKeyStore,
                                session: URLSession = .shared,
                                model: String? = nil,
                                onUsage: ((LlmUsage) -> Void)? = nil) -> HttpLlmClient? {
    let baseUrl = settings.llmBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let override = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effectiveModel = override.isEmpty
      ? settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines) : override
    guard !baseUrl.isEmpty, !effectiveModel.isEmpty else { return nil }
    let key = keyToSend(baseUrl: baseUrl, keyStore: keyStore)
    if key == nil && !isLocalEndpoint(baseUrl) { return nil }
    return HttpLlmClient(config: LlmClientConfig(baseUrl: baseUrl, model: effectiveModel, apiKey: key),
                         session: session, onUsage: onUsage)
  }

  /// Modell-IDs von `{baseUrl}/models` (Key wird mitgeschickt, falls vorhanden).
  public static func listModels(settings: TabySettings, keyStore: ApiKeyStore,
                                session: URLSession = .shared) async -> ToolResult<[String]> {
    await LlmModels.list(baseUrl: settings.llmBaseUrl,
                         apiKey: keyToSend(baseUrl: settings.llmBaseUrl, keyStore: keyStore), session: session)
  }

  /// „Verbindung testen“: minimale Anfrage ohne Werkzeuge.
  public static func test(settings: TabySettings, keyStore: ApiKeyStore,
                          session: URLSession = .shared) async -> LlmTestResult {
    if settings.llmBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return LlmTestResult(ok: false, message: "Keine Endpunkt-URL angegeben.")
    }
    if settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return LlmTestResult(ok: false, message: "Kein Modell ausgewählt.")
    }
    guard let client = makeClient(settings: settings, keyStore: keyStore, session: session) else {
      if !isLocalEndpoint(settings.llmBaseUrl), (host(of: settings.llmBaseUrl) ?? "") != defaultHost {
        return LlmTestResult(ok: false, message: "Für diesen Anbieter einen eigenen Schlüssel eintragen.")
      }
      return LlmTestResult(ok: false, message: "Kein API-Schlüssel gesetzt.")
    }
    return await test(client: client)
  }

  /// Test gegen einen beliebigen Client (auch für Fakes).
  public static func test(client: LlmClient) async -> LlmTestResult {
    do {
      _ = try await client.chat(messages: [ChatMessage(role: .user, content: "ping")], tools: nil)
      return LlmTestResult(ok: true, message: "Verbindung erfolgreich.")
    } catch let e as LlmError {
      return LlmTestResult(ok: false, message: e.message)
    } catch {
      return LlmTestResult(ok: false, message: "Verbindung fehlgeschlagen.")
    }
  }
}
