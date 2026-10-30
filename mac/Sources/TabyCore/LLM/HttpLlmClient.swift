// LlmClient gegen ein OpenAI-kompatibles `/chat/completions` (BAUPLAN.md
// Abschnitt 8). Port von src/main/llm/http-client.ts. Fehler werden auf
// LlmErrorCode abgebildet (deutsche Texte, nie den API-Key enthaltend).
import Foundation

public struct LlmClientConfig: Equatable, Sendable {
  public var baseUrl: String
  public var model: String
  /// Leer/nil erlaubt, wenn baseUrl auf localhost/127.0.0.1 zeigt.
  public var apiKey: String?

  public init(baseUrl: String, model: String, apiKey: String? = nil) {
    self.baseUrl = baseUrl; self.model = model; self.apiKey = apiKey
  }
}

/// Feste deutsche Fehlermeldungen. Keine davon enthält Nutzer- oder
/// Schlüsseldaten.
enum LlmMessages {
  static let auth = "Der API-Schlüssel ist ungültig oder fehlt. Bitte in den Einstellungen prüfen."
  static let quota = "Kontingent oder Guthaben ist aufgebraucht."
  static let noTools = "Dieses Modell unterstützt keine Werkzeuge, bitte anderes wählen."
  static let rateLimit = "Zu viele Anfragen in kurzer Zeit. Bitte kurz warten."
  static let network = "Keine Verbindung zum Modell möglich. Netzwerk oder Endpunkt prüfen."
  static let badResponse = "Unerwartete Antwort vom Modell."
  static let cancelled = "Anfrage abgebrochen."
  static let invalidUrl = "Ungültige Endpunkt-URL. Bitte in den Einstellungen prüfen."
  static func unknown(status: Int) -> String { "Unbekannter Fehler beim Aufruf des Modells (HTTP \(status))." }
}

/// Bildet einen HTTP-Fehlerstatus auf `LlmError` ab (wie TS `mapHttpError`).
func mapHttpError(status: Int, body: String) -> LlmError {
  switch status {
  case 401, 403: return LlmError(.auth, LlmMessages.auth)
  case 402: return LlmError(.quota, LlmMessages.quota)
  case 404 where body.lowercased().contains("tool"): return LlmError(.noTools, LlmMessages.noTools)
  case 429: return LlmError(.rateLimit, LlmMessages.rateLimit)
  default: return LlmError(.unknown, LlmMessages.unknown(status: status))
  }
}

/// Bildet einen Transportfehler (URLSession) auf `LlmError` ab. Die
/// Originalmeldung wird bewusst verworfen (könnte URL/Header enthalten).
func mapTransportError(_ error: Error) -> LlmError {
  if let e = error as? LlmError { return e }
  if error is CancellationError { return LlmError(.cancelled, LlmMessages.cancelled) }
  if let u = error as? URLError, u.code == .cancelled { return LlmError(.cancelled, LlmMessages.cancelled) }
  return LlmError(.network, LlmMessages.network)
}

/// `{baseUrl}/{path}` mit bereinigten Schrägstrichen; nil bei ungültiger URL.
func endpointURL(baseUrl: String, path: String) -> URL? {
  var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") { base.removeLast() }
  guard !base.isEmpty, let url = URL(string: "\(base)/\(path)"), let scheme = url.scheme?.lowercased(),
    scheme == "http" || scheme == "https", url.host != nil
  else { return nil }
  return url
}

/// Der API-Schlüssel darf nur über https oder an diesen Rechner (http://localhost,
/// 127.0.0.1, [::1] – lokale Modelle) gehen. Sonst bleibt er zu Hause.
func keyMayBeSent(to url: URL) -> Bool {
  let scheme = url.scheme?.lowercased() ?? ""
  if scheme == "https" { return true }
  guard scheme == "http", let host = url.host?.lowercased() else { return false }
  return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
}

/// Meldung, wenn ein Schlüssel an einen unsicheren Endpunkt gesendet werden soll.
let keyInsecureMessage = "Der Schlüssel wird nur über https gesendet."

/// OpenAI-kompatibler HTTP-Client. Abbruch über Swift-Task-Cancellation.
public final class HttpLlmClient: LlmClient, @unchecked Sendable {
  public let config: LlmClientConfig
  private let session: URLSession
  /// Zeitlimit pro Modell-Anfrage in Sekunden.
  public var timeout: TimeInterval = 120
  /// Wird nach jeder erfolgreichen Antwort aufgerufen, die ein `usage`-Objekt
  /// mit `prompt_tokens` und `completion_tokens` enthält. Nie bei Fehlern.
  public var onUsage: ((LlmUsage) -> Void)?

  /// `session` ist injizierbar, damit Prüfungen HTTP per URLProtocol stubben.
  public init(config: LlmClientConfig, session: URLSession = .shared,
              onUsage: ((LlmUsage) -> Void)? = nil) {
    self.config = config; self.session = session; self.onUsage = onUsage
  }

  public func chat(messages: [ChatMessage], tools: [ToolDef]?) async throws -> ChatMessage {
    if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }
    let request = try makeRequest(messages: messages, tools: tools, stream: false)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw mapTransportError(error)
    }
    if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }

    guard let http = response as? HTTPURLResponse else {
      throw LlmError(.badResponse, LlmMessages.badResponse)
    }
    let text = String(decoding: data, as: UTF8.self)
    guard (200..<300).contains(http.statusCode) else {
      throw mapHttpError(status: http.statusCode, body: text)
    }
    guard let json = JSONValue.parse(text) else {
      throw LlmError(.badResponse, LlmMessages.badResponse)
    }
    let message = try Self.normalizeMessage(json["choices"]?.arrayValue?.first?["message"])
    if let usage = Self.usage(from: json, configuredModel: config.model) {
      onUsage?(usage)
    }
    return message
  }

  /// Wie `chat`, aber mit `stream: true`: Textstücke gehen sofort an `onDelta`,
  /// die Antwort (inkl. Werkzeugaufrufe) kommt am Ende als ChatMessage.
  public func chatStream(messages: [ChatMessage], tools: [ToolDef]?,
                         onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatMessage {
    if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }
    let request = try makeRequest(messages: messages, tools: tools, stream: true)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      throw mapTransportError(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw LlmError(.badResponse, LlmMessages.badResponse)
    }
    guard (200..<300).contains(http.statusCode) else {
      // Fehlertext klein halten: nur der Anfang des Körpers zählt für die Zuordnung.
      var text = ""
      do {
        for try await line in bytes.lines {
          text += line + "\n"
          if text.count > 4000 { break }
        }
      } catch {}
      throw mapHttpError(status: http.statusCode, body: text)
    }

    var acc = ChatStreamAccumulator(configuredModel: config.model)
    do {
      for try await line in bytes.lines {
        if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }
        if let delta = try acc.feed(line) { onDelta(delta) }
        if acc.done { break }
      }
    } catch {
      throw mapTransportError(error)
    }
    if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }
    let message = try acc.message()
    if let usage = acc.usage { onUsage?(usage) }
    return message
  }

  /// Anfrage mit Kopf- und Körperdaten; für `chat` und `chatStream` gleich.
  private func makeRequest(messages: [ChatMessage], tools: [ToolDef]?, stream: Bool) throws -> URLRequest {
    guard let url = endpointURL(baseUrl: config.baseUrl, path: "chat/completions") else {
      throw LlmError(.network, LlmMessages.invalidUrl)
    }
    if let key = config.apiKey, !key.isEmpty, !keyMayBeSent(to: url) {
      throw LlmError(.unknown, keyInsecureMessage)
    }

    var body: [String: JSONValue] = [
      "model": .string(config.model),
      "messages": .array(messages.map(Self.encodeMessage)),
      // OpenRouter liefert dann `usage.cost`; andere Server ignorieren das Feld.
      "usage": .object(["include": .bool(true)]),
    ]
    if let tools { body["tools"] = .array(tools.map(Self.encodeTool)) }
    if stream {
      body["stream"] = .bool(true)
      // Verbrauch kommt im letzten Stück, auch beim Streamen.
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Zusatz-Header für OpenRouter; andere Endpunkte ignorieren sie.
    request.setValue("https://taby.app", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("Lumi", forHTTPHeaderField: "X-Title")
    // Kein Key nötig bei lokalem Endpunkt (z. B. Ollama). Fehlt er bei einem
    // Remote-Endpunkt, antwortet der Server mit 401/403 → .auth.
    if let key = config.apiKey, !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = Data(JSONValue.object(body).jsonString().utf8)
    return request
  }

  // MARK: Verbrauch

  /// Liest `usage` aus einer erfolgreichen Antwort. nil, wenn Tokenzahlen fehlen.
  /// `model` der Antwort hat Vorrang, sonst das konfigurierte Modell.
  static func usage(from json: JSONValue, configuredModel: String) -> LlmUsage? {
    guard let usage = json["usage"],
      let prompt = intValue(usage["prompt_tokens"]),
      let completion = intValue(usage["completion_tokens"])
    else { return nil }
    let responseModel = json["model"]?.stringValue ?? ""
    return LlmUsage(
      model: responseModel.isEmpty ? configuredModel : responseModel,
      promptTokens: prompt, completionTokens: completion,
      costUsd: usage["cost"]?.numberValue)
  }

  /// Ganzzahl aus einer JSON-Zahl; nil bei fehlendem Wert oder Bruchteil.
  static func intValue(_ v: JSONValue?) -> Int? {
    guard let n = v?.numberValue, n.isFinite, n.rounded() == n, abs(n) < 1e15 else { return nil }
    return Int(n)
  }

  // MARK: Kodierung

  static func encodeTool(_ t: ToolDef) -> JSONValue {
    [
      "type": "function",
      "function": [
        "name": .string(t.name),
        "description": .string(t.description),
        "parameters": t.parameters,
      ],
    ]
  }

  static func encodeMessage(_ m: ChatMessage) -> JSONValue {
    var o: [String: JSONValue] = [
      "role": .string(m.role.rawValue),
      // content immer mitsenden (null bei reinen Tool-Calls), wie TS.
      "content": m.content.map(JSONValue.string) ?? .null,
    ]
    if let name = m.name { o["name"] = .string(name) }
    if let id = m.toolCallId { o["tool_call_id"] = .string(id) }
    if let calls = m.toolCalls, !calls.isEmpty {
      o["tool_calls"] = .array(calls.map { c in
        [
          "id": .string(c.id),
          "type": .string(c.type),
          "function": ["name": .string(c.function.name), "arguments": .string(c.function.arguments)],
        ]
      })
    }
    return .object(o)
  }

  /// Wie TS `normalizeMessage`: nur role "assistant", content String oder nil,
  /// tool_calls tolerant (fehlendes `type`, Argumente als Objekt).
  static func normalizeMessage(_ raw: JSONValue?) throws -> ChatMessage {
    guard let raw, raw.objectValue != nil, raw["role"]?.stringValue == "assistant" else {
      throw LlmError(.badResponse, LlmMessages.badResponse)
    }
    var calls: [ToolCall]?
    if let arr = raw["tool_calls"]?.arrayValue {
      calls = try arr.map { c in
        guard let id = c["id"]?.stringValue, let fn = c["function"], let name = fn["name"]?.stringValue else {
          throw LlmError(.badResponse, LlmMessages.badResponse)
        }
        let args: String
        switch fn["arguments"] {
        case .string(let s)?: args = s
        case nil, .null?: args = "{}"
        case let other?: args = other.jsonString()
        }
        var call = ToolCall(id: id, name: name, arguments: args)
        if let type = c["type"]?.stringValue { call.type = type }
        return call
      }
      if calls?.isEmpty == true { calls = nil }
    }
    return ChatMessage(role: .assistant, content: raw["content"]?.stringValue, toolCalls: calls)
  }

  // MARK: Modellliste

  /// `GET {baseUrl}/models` → IDs. Fehler als ToolResult (deutsch, ohne Key).
  public func listModels() async -> ToolResult<[String]> {
    await LlmModels.list(baseUrl: config.baseUrl, apiKey: config.apiKey, session: session)
  }
}

public enum LlmModels {
  /// `GET {baseUrl}/models` (OpenAI-Format `{data:[{id}]}`) → Modell-IDs.
  public static func list(baseUrl: String, apiKey: String?, session: URLSession = .shared) async
    -> ToolResult<[String]>
  {
    if baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .failure(code: "NO_BASE_URL", error: "Keine Endpunkt-URL angegeben.")
    }
    guard let url = endpointURL(baseUrl: baseUrl, path: "models") else {
      return .failure(code: "INVALID_URL", error: LlmMessages.invalidUrl)
    }
    if let apiKey, !apiKey.isEmpty, !keyMayBeSent(to: url) {
      return .failure(code: "KEY_INSECURE", error: keyInsecureMessage)
    }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("https://taby.app", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("Lumi", forHTTPHeaderField: "X-Title")
    if let key = apiKey, !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .failure(code: "BAD_RESPONSE", error: "Unerwartete Antwort beim Laden der Modellliste.")
      }
      guard (200..<300).contains(http.statusCode) else {
        return .failure(
          code: "HTTP_ERROR", error: "Modellliste konnte nicht geladen werden (HTTP \(http.statusCode)).")
      }
      guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
        return .failure(code: "BAD_RESPONSE", error: "Unerwartete Antwort beim Laden der Modellliste.")
      }
      let ids = (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
      return .ok(ids)
    } catch {
      let mapped = mapTransportError(error)
      if mapped.code == .cancelled { return .failure(code: "CANCELLED", error: LlmMessages.cancelled) }
      return .failure(code: "NETWORK", error: "Keine Verbindung zum Endpunkt möglich. Netzwerk oder URL prüfen.")
    }
  }
}
