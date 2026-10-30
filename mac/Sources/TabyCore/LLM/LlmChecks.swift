// Prüfungen für Sources/TabyCore/LLM (Agent B). Port von
// src/main/llm/http-client.test.ts und safe-storage.test.ts. HTTP wird an
// der Grenze per URLProtocol gestubbt (StubHTTP.swift), kein echtes Netz;
// der echte Schlüsselbund wird nie beschrieben.
import Foundation

enum LlmChecks {
  static let secret = "sk-top-secret-0123456789"

  static func client(_ s: StubServer, key: String? = "sk-test", model: String = "test-model") -> HttpLlmClient {
    HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: model, apiKey: key), session: s.session)
  }

  static let hi = [ChatMessage(role: .user, content: "hi")]

  static func llmError(_ body: () async throws -> Void) async throws -> LlmError {
    do {
      try await body()
    } catch let e as LlmError {
      return e
    } catch {
      throw fail("erwartet LlmError, war \(error)")
    }
    throw fail("sollte LlmError werfen")
  }

  static func errorCase(status: Int, body: String = #"{"error":{"message":"mock"}}"#, expected: LlmErrorCode)
    -> CheckCase
  {
    CheckCase("bildet HTTP \(status) auf \(expected.rawValue) ab") {
      let s = StubServer([.json(status: status, body: body)])
      let e = try await llmError { _ = try await client(s, key: secret).chat(messages: hi, tools: nil) }
      try expectEqual(e.code, expected)
      try expect(!e.message.contains(secret), "Key in Fehlermeldung")
      try expect(!e.message.isEmpty)
    }
  }

  static let suite = CheckSuite("LLM", [
    CheckCase("schickt model/messages an /chat/completions und liefert die assistant-Nachricht") {
      let s = StubServer([StubServer.text("Hallo!")])
      let m = try await client(s).chat(messages: [ChatMessage(role: .user, content: "Hi")], tools: nil)
      try expectEqual(m, ChatMessage(role: .assistant, content: "Hallo!"))
      let r = try expectNotNil(s.requests.first)
      try expectEqual(r.method, "POST")
      try expectEqual(r.url.path, "/api/v1/chat/completions")
      try expectEqual(r.body?["model"], "test-model")
      try expectEqual(r.body?["messages"], [["role": "user", "content": "Hi"]])
      try expect(r.body?["tools"] == nil, "ohne tools kein tools-Feld")
    },
    CheckCase("Basis-URL mit Schrägstrich am Ende") {
      let s = StubServer([StubServer.text("ok")])
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl + "//", model: "m"), session: s.session)
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(s.requests.first?.url.path, "/api/v1/chat/completions")
    },
    CheckCase("kodiert ToolDef als {type:function,function:{name,description,parameters}}") {
      let s = StubServer([StubServer.text("ok")])
      let schema: JSONValue = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]
      _ = try await client(s).chat(
        messages: hi, tools: [ToolDef(name: "add_task", description: "legt eine Aufgabe an", parameters: schema)])
      let tools = try expectNotNil(s.requests.first?.body?["tools"])
      try expectEqual(tools, [["type": "function",
                               "function": ["name": "add_task", "description": "legt eine Aufgabe an",
                                            "parameters": schema]]])
    },
    CheckCase("reicht Tool-Calls aus der Modellantwort unverändert durch") {
      let s = StubServer([StubServer.toolCall("add_task", #"{"title":"x"}"#)])
      let m = try await client(s).chat(messages: [ChatMessage(role: .user, content: "leg Aufgabe an")], tools: nil)
      try expectEqual(m.toolCalls, [ToolCall(id: "c1", name: "add_task", arguments: #"{"title":"x"}"#)])
      try expectEqual(m.content, nil)
    },
    CheckCase("Tool-Call-Rundreise: assistant tool_calls + tool-Antwort werden OpenAI-konform gesendet") {
      let s = StubServer([StubServer.text("ok")])
      let history = [
        ChatMessage(role: .user, content: "leg an"),
        ChatMessage(role: .assistant, content: nil,
                    toolCalls: [ToolCall(id: "c9", name: "add_task", arguments: #"{"title":"x"}"#)]),
        ChatMessage(role: .tool, content: #"{"ok":true}"#, name: "add_task", toolCallId: "c9"),
      ]
      _ = try await client(s).chat(messages: history, tools: nil)
      let msgs = try expectNotNil(s.requests.first?.body?["messages"]?.arrayValue)
      try expectEqual(msgs[1], ["role": "assistant", "content": nil,
                                "tool_calls": [["id": "c9", "type": "function",
                                                "function": ["name": "add_task", "arguments": #"{"title":"x"}"#]]]])
      try expectEqual(msgs[2], ["role": "tool", "content": #"{"ok":true}"#, "name": "add_task",
                                "tool_call_id": "c9"])
    },
    CheckCase("tolerant: tool_call ohne type und Argumente als Objekt") {
      let s = StubServer([StubServer.completion(
        #"{"role":"assistant","content":"","tool_calls":[{"id":"a","function":{"name":"f","arguments":{"x":1}}}]}"#)])
      let m = try await client(s).chat(messages: hi, tools: nil)
      try expectEqual(m.toolCalls, [ToolCall(id: "a", name: "f", arguments: #"{"x":1}"#)])
    },
    CheckCase("setzt Authorization-Header und die OpenRouter-Zusatzheader") {
      let s = StubServer([StubServer.text("ok")])
      _ = try await client(s, key: secret).chat(messages: hi, tools: nil)
      let r = try expectNotNil(s.requests.first)
      try expectEqual(r.header("Authorization"), "Bearer \(secret)")
      try expect(r.header("HTTP-Referer")?.isEmpty == false)
      try expect(r.header("X-Title")?.isEmpty == false)
      try expectEqual(r.header("Content-Type"), "application/json")
    },
    CheckCase("lässt den Authorization-Header weg, wenn kein Key gesetzt ist") {
      for key in [nil, ""] as [String?] {
        let s = StubServer([StubServer.text("ok")])
        _ = try await client(s, key: key).chat(messages: hi, tools: nil)
        try expect(s.requests.first?.header("Authorization") == nil)
      }
    },
    errorCase(status: 401, expected: .auth),
    errorCase(status: 403, expected: .auth),
    errorCase(status: 402, expected: .quota),
    errorCase(status: 429, expected: .rateLimit),
    errorCase(status: 404, body: #"{"error":{"message":"No endpoints found that support tool use."}}"#,
              expected: .noTools),
    errorCase(status: 404, body: #"{"error":{"message":"not found"}}"#, expected: .unknown),
    errorCase(status: 500, expected: .unknown),
    errorCase(status: 400, body: "Bearer \(secret)", expected: .unknown),
    CheckCase("unknown nennt den HTTP-Status") {
      let s = StubServer([.json(status: 503, body: "")])
      let e = try await llmError { _ = try await client(s).chat(messages: hi, tools: nil) }
      try expect(e.message.contains("503"), e.message)
    },
    CheckCase("bildet einen nicht erreichbaren Endpunkt auf network ab") {
      for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet, .timedOut, .cannotFindHost] {
        let s = StubServer([.transportError(code)])
        let e = try await llmError { _ = try await client(s, key: secret).chat(messages: hi, tools: nil) }
        try expectEqual(e.code, .network, "\(code)")
        try expect(!e.message.contains(secret))
      }
    },
    CheckCase("ungültige Basis-URL → network, ohne Anfrage") {
      for url in ["", "kein url", "ftp://x/y"] {
        let c = HttpLlmClient(config: LlmClientConfig(baseUrl: url, model: "m", apiKey: secret))
        let e = try await llmError { _ = try await c.chat(messages: hi, tools: nil) }
        try expectEqual(e.code, .network, url)
      }
    },
    CheckCase("bildet kaputtes JSON / falsche Form auf bad-response ab") {
      for body in ["{not valid json", #"{"choices":[]}"#, #"{"choices":[{"message":{"role":"user","content":"x"}}]}"#,
                   #"{"foo":1}"#, #"{"choices":[{"message":{"role":"assistant","tool_calls":[{"function":{}}]}}]}"#] {
        let s = StubServer([.json(status: 200, body: body)])
        let e = try await llmError { _ = try await client(s).chat(messages: hi, tools: nil) }
        try expectEqual(e.code, .badResponse, body)
      }
    },
    CheckCase("bereits abgebrochener Task → cancelled, ohne den Server zu erreichen") {
      let s = StubServer([StubServer.text("ok")])
      let c = client(s)
      let task = Task { () -> LlmError? in
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try await c.chat(messages: hi, tools: nil); return nil } catch let e as LlmError { return e }
      }
      let e = try await task.value
      try expectEqual(e?.code, .cancelled)
      try expectEqual(s.requests.count, 0)
    },
    CheckCase("Abbruch während laufender Anfrage → cancelled") {
      let s = StubServer([.hang])
      let c = client(s)
      let task = Task { () -> LlmError? in
        do { _ = try await c.chat(messages: hi, tools: nil); return nil } catch let e as LlmError { return e }
      }
      for _ in 0..<200 where s.requests.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
      try expectEqual(s.requests.count, 1)
      task.cancel()
      let e = try await task.value
      try expectEqual(e?.code, .cancelled)
    },
    CheckCase("Key taucht in keiner Fehlermeldung auf (alle Codes)") {
      let replies: [StubReply] = [
        .json(status: 401, body: secret), .json(status: 402, body: secret), .json(status: 404, body: "tool \(secret)"),
        .json(status: 429, body: secret), .json(status: 500, body: secret), .json(status: 200, body: secret),
        .transportError(.networkConnectionLost),
      ]
      for r in replies {
        let s = StubServer([r])
        let e = try await llmError { _ = try await client(s, key: secret).chat(messages: hi, tools: nil) }
        try expect(!e.message.contains(secret), "\(e.code)")
        try expect(!"\(e)".contains(secret), "\(e.code) description")
      }
    },
    // Modellliste
    CheckCase("listModels: GET /models → IDs, mit Key") {
      let s = StubServer([.json(status: 200, body: #"{"data":[{"id":"openai/gpt-4o"},{"id":"meta/llama"}]}"#)])
      let r = await LlmConnection.listModels(
        settings: TabySettings(llmBaseUrl: s.baseUrl), keyStore: InMemoryApiKeyStore(secret), session: s.session)
      try expectEqual(r, .ok(["openai/gpt-4o", "meta/llama"]))
      let req = try expectNotNil(s.requests.first)
      try expectEqual(req.method, "GET")
      try expectEqual(req.url.path, "/api/v1/models")
      try expectEqual(req.header("Authorization"), "Bearer \(secret)")
    },
    CheckCase("listModels: Fehler als ToolResult (deutsch, ohne Key)") {
      let empty = await LlmModels.list(baseUrl: " ", apiKey: nil)
      try expectEqual(empty.errorMessage, "Keine Endpunkt-URL angegeben.")
      let s = StubServer([.json(status: 500, body: secret)])
      let http = await LlmModels.list(baseUrl: s.baseUrl, apiKey: secret, session: s.session)
      try expect(http.errorMessage?.contains("500") == true)
      try expect(http.errorMessage?.contains(secret) == false)
      let n = StubServer([.transportError(.cannotConnectToHost)])
      let net = await LlmModels.list(baseUrl: n.baseUrl, apiKey: secret, session: n.session)
      if case .failure(let code, let msg) = net {
        try expectEqual(code, "NETWORK"); try expect(!msg.contains(secret))
      } else { throw fail("sollte fehlschlagen") }
    },
    // Verbindungstest und Client-Fabrik
    CheckCase("test: fehlende Angaben → deutsche Meldungen ohne Anfrage") {
      let store = InMemoryApiKeyStore()
      let noUrl = await LlmConnection.test(settings: TabySettings(llmBaseUrl: ""), keyStore: store)
      try expectEqual(noUrl.message, "Keine Endpunkt-URL angegeben.")
      let noModel = await LlmConnection.test(settings: TabySettings(llmModel: ""), keyStore: store)
      try expectEqual(noModel.message, "Kein Modell ausgewählt.")
      let noKey = await LlmConnection.test(settings: TabySettings(llmModel: "m"), keyStore: store)
      try expectEqual(noKey, LlmTestResult(ok: false, message: "Kein API-Schlüssel gesetzt."))
    },
    CheckCase("test: Erfolg und abgebildeter Fehler") {
      let ok = StubServer([StubServer.text("pong")])
      let r1 = await LlmConnection.test(settings: TabySettings(llmBaseUrl: ok.baseUrl, llmModel: "m"),
                                        keyStore: InMemoryApiKeyStore(secret), session: ok.session)
      try expectEqual(r1, LlmTestResult(ok: true, message: "Verbindung erfolgreich."))
      try expectEqual(ok.requests.first?.body?["messages"], [["role": "user", "content": "ping"]])
      let bad = StubServer([.json(status: 401, body: "")])
      let r2 = await LlmConnection.test(settings: TabySettings(llmBaseUrl: bad.baseUrl, llmModel: "m"),
                                        keyStore: InMemoryApiKeyStore(secret), session: bad.session)
      try expectEqual(r2, LlmTestResult(ok: false, message: LlmMessages.auth))
    },
    CheckCase("makeClient: lokaler Endpunkt braucht keinen Key, Remote schon") {
      let store = InMemoryApiKeyStore()
      try expect(LlmConnection.makeClient(settings: TabySettings(llmModel: "m"), keyStore: store) == nil)
      let local = LlmConnection.makeClient(
        settings: TabySettings(llmBaseUrl: "http://localhost:11434/v1", llmModel: "llama"), keyStore: store)
      try expectEqual(local?.config.apiKey, nil)
      try expect(LlmConnection.makeClient(settings: TabySettings(llmBaseUrl: "", llmModel: "m"),
                                          keyStore: InMemoryApiKeyStore("k")) == nil)
      try store.set("  k1  ")
      let remote = try expectNotNil(LlmConnection.makeClient(settings: TabySettings(llmModel: "m"), keyStore: store))
      try expectEqual(remote.config, LlmClientConfig(baseUrl: "https://openrouter.ai/api/v1", model: "m", apiKey: "k1"))
    },
    CheckCase("isLocalEndpoint") {
      for u in ["http://localhost:11434/v1", "http://127.0.0.1:1234", "localhost", "http://[::1]:8080/v1"] {
        try expect(LlmConnection.isLocalEndpoint(u), u)
      }
      for u in ["https://openrouter.ai/api/v1", "http://localhost.evil.com/v1", "http://127.0.0.10/v1",
                "http://localhost:1@evil.example", "http://localhost@evil.example/v1",
                "http://localhost.evil.example", "http://127.0.0.1.evil.example:11434", "http://[::1]@evil.example"] {
        try expect(!LlmConnection.isLocalEndpoint(u), u)
      }
    },
    CheckCase("Endpunkt-Host: Zugangsdaten und Teildomänen zählen nicht als lokal") {
      try expectEqual(LlmConnection.host(of: "https://OpenRouter.ai/api/v1"), "openrouter.ai")
      try expectEqual(LlmConnection.host(of: "http://localhost:11434/v1"), "localhost")
      try expectEqual(LlmConnection.host(of: "http://[::1]:8080/v1"), "::1")
      try expectEqual(LlmConnection.host(of: "http://localhost:1@evil.example"), nil)
      try expectEqual(LlmConnection.host(of: "ftp://localhost"), nil)
      try expect(LlmConnection.isLocalEndpoint("http://localhost:1234/v1"), "lokal")
    },
    CheckCase("Schlüssel je Host: fremder Host bekommt keinen fremden Schlüssel") {
      let other = InMemoryApiKeyStore()
      let settings = TabySettings(llmBaseUrl: "https://api.example.com/v1", llmModel: "m")
      try expect(LlmConnection.makeClient(settings: settings, keyStore: other) == nil, "ohne eigenen Schlüssel kein Client")
      let test = await LlmConnection.test(settings: settings, keyStore: other)
      try expectEqual(test.message, "Für diesen Anbieter einen eigenen Schlüssel eintragen.", "Hinweis")
      try other.set("sk-anbieter")
      let client = try expectNotNil(LlmConnection.makeClient(settings: settings, keyStore: other))
      try expectEqual(client.config.apiKey, "sk-anbieter", "eigener Schlüssel")
      try expectEqual(LlmConnection.keyAccount(host: "openrouter.ai"), "llm-api-key", "Altkonto bleibt")
      try expectEqual(LlmConnection.keyAccount(host: "api.example.com"), "llm-api-key@api.example.com", "Konto je Host")
    },
    CheckCase("Lokaler Endpunkt (Ollama, LM Studio) bekommt nie den Schlüssel, Remote schon") {
      let store = InMemoryApiKeyStore(secret)
      try expectEqual(LlmConnection.keyToSend(baseUrl: "http://localhost:11434/v1", keyStore: store), nil)
      try expectEqual(LlmConnection.keyToSend(baseUrl: "http://127.0.0.1:1234/v1", keyStore: store), nil)
      try expectEqual(LlmConnection.keyToSend(baseUrl: "https://openrouter.ai/api/v1", keyStore: store), secret)
    },
    CheckCase("Schlüssel nur über https oder an diesen Rechner: unsicherer Endpunkt ohne Anfrage abgelehnt") {
      for u in ["http://openrouter.ai/api/v1", "http://192.168.1.5:11434/v1", "http://localhost.evil.com/v1"] {
        let c = HttpLlmClient(config: LlmClientConfig(baseUrl: u, model: "m", apiKey: secret))
        let e = try await llmError { _ = try await c.chat(messages: hi, tools: nil) }
        try expectEqual(e.message, keyInsecureMessage, u)
        try expect(!e.message.contains(secret), u)
        let list = await LlmModels.list(baseUrl: u, apiKey: secret)
        try expectEqual(list.errorMessage, keyInsecureMessage, u)
      }
      for u in ["https://openrouter.ai/api/v1", "http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
        try expect(keyMayBeSent(to: URL(string: u)!), u)
      }
      try expect(!keyMayBeSent(to: URL(string: "http://openrouter.ai/api/v1")!))
    },
    // Key-Ablage (nur im Speicher; der echte Schlüsselbund wird nicht berührt)
    CheckCase("InMemoryApiKeyStore: set/get/hasKey/delete, leer = löschen") {
      let s = InMemoryApiKeyStore()
      try expect(!s.hasKey()); try expectEqual(try s.get(), nil)
      try s.set("abc"); try expect(s.hasKey()); try expectEqual(try s.get(), "abc")
      try s.set("  "); try expect(!s.hasKey())
      try s.set("x"); try s.delete(); try expectEqual(try s.get(), nil)
    },
    CheckCase("CachedApiKeyStore: liest den Wert nur einmal, set/delete erneuern, Ablehnung wird gemerkt") {
      final class Counting: ApiKeyStore {
        var value: String?; var gets = 0; var deny = false
        func get() throws -> String? { gets += 1; if deny { throw ApiKeyStoreError("nein", status: -128) }; return value }
        func set(_ key: String) throws { value = key.isEmpty ? nil : key }
        func delete() throws { value = nil }
        func hasKey() -> Bool { value != nil }
      }
      let inner = Counting()
      let c = CachedApiKeyStore(inner)
      try expectEqual(try c.get(), nil); try expectEqual(try c.get(), nil)
      try expectEqual(inner.gets, 2, "nicht vorhanden wird nicht gemerkt")
      inner.value = "k1"
      try expectEqual(try c.get(), "k1"); try expectEqual(try c.get(), "k1"); try expect(c.hasKey())
      try expectEqual(inner.gets, 3, "vorhandener Wert nur einmal gelesen")
      try c.set("k2"); try expectEqual(try c.get(), "k2"); try expectEqual(inner.gets, 3)
      try c.delete(); try expect(!c.hasKey()); try expectEqual(try c.get(), nil); try expectEqual(inner.gets, 4)
      inner.value = "k3"; inner.deny = true
      try expect((try? c.get()) == nil); try expectEqual(try c.get(), nil)
      try expectEqual(inner.gets, 5, "Ablehnung fragt nicht erneut")
      try c.set("k4"); try expectEqual(try c.get(), "k4")
      let make = CachedApiKeyStore.memoized { _ in Counting() }
      try expect(make("a") === make("a") && make("a") !== make("b"))
    },
    CheckCase("CachedApiKeyStore: hasKey wartet nicht hinter einem laufenden Schlüsselbund-Lesen") {
      final class Blocking: ApiKeyStore, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func get() throws -> String? { entered.signal(); release.wait(); return "k" }
        func set(_ key: String) throws {}
        func delete() throws {}
        func hasKey() -> Bool { true }
      }
      final class Box: @unchecked Sendable { var answer = false }
      let inner = Blocking()
      let c = CachedApiKeyStore(inner)
      DispatchQueue.global().async { _ = try? c.get() }
      inner.entered.wait()  // Lesen hängt jetzt im „Schlüsselbund“
      let done = DispatchSemaphore(value: 0)
      let box = Box()
      DispatchQueue.global().async { box.answer = c.hasKey(); done.signal() }
      let finished = done.wait(timeout: .now() + 2) == .success
      inner.release.signal()
      try expect(finished, "hasKey hat auf den laufenden Lesezugriff gewartet")
      try expect(box.answer, "hasKey liefert den Attribut-Befund")
    },
    CheckCase("KeychainApiKeyStore: im Prüfmodus nur Arbeitsspeicher, der echte Schlüsselbund bleibt unberührt") {
      try expect(KeychainApiKeyStore.memoryOnly, "TabyChecks setzt den Prüfmodus")
      let account = "pruefung-\(UUID().uuidString)"
      let k = KeychainApiKeyStore(account: account)
      try k.set("geheim")
      try expectEqual(try k.get(), "geheim")
      try expect(k.hasKey())
      // Direkt am System nachsehen (nur Attribute, ohne Wert, ohne Dialog): dort darf nichts stehen.
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: k.service, kSecAttrAccount as String: account,
                                  kSecReturnAttributes as String: true]
      try expectEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound, "nichts im echten Schlüsselbund")
      try k.delete()
      try expect(!k.hasKey())
    },
    CheckCase("KeychainApiKeyStore: Standard-Service/Account, Fehlertexte ohne Key") {
      let k = KeychainApiKeyStore()
      try expectEqual(k.service, "de.felix.taby")
      try expectEqual(k.account, "llm-api-key")
      let e = ApiKeyStoreError("Der API-Schlüssel konnte nicht gespeichert werden.", status: -1)
      try expect(!e.description.contains(secret))
    },
    // Verbrauch (usage) und Modell-Override
    CheckCase("sendet usage.include = true in jeder Chat-Anfrage") {
      let s = StubServer([StubServer.text("ok")])
      _ = try await client(s).chat(messages: hi, tools: nil)
      try expectEqual(s.requests.first?.body?["usage"]?["include"], JSONValue.bool(true))
    },
    CheckCase("onUsage erhält Tokens und Kosten einmal pro Antwort") {
      let s = StubServer([.json(status: 200, body: usageReply(cost: "0.00042"))])
      let box = UsageBox()
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: "cfg-model", apiKey: "k"),
                            session: s.session, onUsage: box.record)
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(box.values, [LlmUsage(model: "resp-model", promptTokens: 12, completionTokens: 3,
                                            costUsd: 0.00042)])
    },
    CheckCase("onUsage ohne cost → costUsd nil; ohne Antwort-model → konfiguriertes Modell") {
      let s = StubServer([.json(status: 200, body: usageReply(cost: nil, model: nil))])
      let box = UsageBox()
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: "cfg-model", apiKey: "k"),
                            session: s.session, onUsage: box.record)
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(box.values, [LlmUsage(model: "cfg-model", promptTokens: 12, completionTokens: 3,
                                            costUsd: nil)])
    },
    CheckCase("onUsage wird ohne usage-Objekt oder ohne Tokenzahlen nicht aufgerufen") {
      let s = StubServer([StubServer.text("ok"),
                          .json(status: 200, body: #"{"model":"m","choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1}}"#)])
      let box = UsageBox()
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: "m", apiKey: "k"),
                            session: s.session, onUsage: box.record)
      _ = try await c.chat(messages: hi, tools: nil)
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(box.values.count, 0)
    },
    CheckCase("onUsage wird bei Fehlerantworten nicht aufgerufen") {
      let s = StubServer([.json(status: 500, body: usageReply(cost: "0.1")),
                          .json(status: 200, body: "{not json")])
      let box = UsageBox()
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: "m", apiKey: "k"),
                            session: s.session, onUsage: box.record)
      _ = try await llmError { _ = try await c.chat(messages: hi, tools: nil) }
      _ = try await llmError { _ = try await c.chat(messages: hi, tools: nil) }
      try expectEqual(box.values.count, 0)
    },
    CheckCase("makeClient: Modell-Override wird gesendet und ersetzt die Prüfung auf leeres Modell") {
      let store = InMemoryApiKeyStore("k")
      let s = StubServer([StubServer.text("ok")])
      let base = TabySettings(llmBaseUrl: s.baseUrl, llmModel: "settings-model")
      let c = try expectNotNil(LlmConnection.makeClient(settings: base, keyStore: store, session: s.session,
                                                        model: "  override-model "))
      try expectEqual(c.config.model, "override-model")
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(s.requests.first?.body?["model"], "override-model")
      // Leerer Override → Einstellungsmodell
      let fallback = try expectNotNil(LlmConnection.makeClient(settings: base, keyStore: store, model: "  "))
      try expectEqual(fallback.config.model, "settings-model")
      // Kein Modell weder in Einstellungen noch im Override → nil
      let none = TabySettings(llmBaseUrl: "http://localhost:11434/v1", llmModel: "")
      try expect(LlmConnection.makeClient(settings: none, keyStore: store) == nil)
      try expect(LlmConnection.makeClient(settings: none, keyStore: store, model: " ") == nil)
      try expect(LlmConnection.makeClient(settings: none, keyStore: store, model: "x") != nil)
    },
    CheckCase("makeClient: onUsage wird an den Client durchgereicht") {
      let s = StubServer([.json(status: 200, body: usageReply(cost: "0.5"))])
      let box = UsageBox()
      let c = try expectNotNil(LlmConnection.makeClient(
        settings: TabySettings(llmBaseUrl: s.baseUrl, llmModel: "m"), keyStore: InMemoryApiKeyStore(secret),
        session: s.session, onUsage: box.record))
      _ = try await c.chat(messages: hi, tools: nil)
      try expectEqual(box.values.count, 1)
      try expectEqual(box.values.first?.costUsd, 0.5)
    },
    CheckCase("stream: Textstücke kommen einzeln an und die Antwort ist vollständig") {
      let s = StubServer([.json(status: 200, body: sse([
        #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Hal"}}]}"#,
        #"{"choices":[{"index":0,"delta":{"content":"lo!"}}]}"#,
        #"{"model":"m-x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"cost":0.01}}"#,
      ]))])
      let deltas = AgentLoopChecks.Box<[String]>([])
      let usage = UsageBox()
      let c = HttpLlmClient(config: LlmClientConfig(baseUrl: s.baseUrl, model: "test-model", apiKey: "sk-test"),
                            session: s.session, onUsage: usage.record)
      let m = try await c.chatStream(messages: hi, tools: nil, onDelta: { deltas.value.append($0) })
      try expectEqual(deltas.value, ["Hal", "lo!"])
      try expectEqual(m, ChatMessage(role: .assistant, content: "Hallo!"))
      let r = try expectNotNil(s.requests.first)
      try expectEqual(r.body?["stream"], .bool(true))
      try expectEqual(r.body?["stream_options"], .object(["include_usage": .bool(true)]))
      try expectEqual(usage.values.count, 1)
      try expectEqual(usage.values.first?.costUsd, 0.01)
      try expectEqual(usage.values.first?.model, "m-x")
    },
    CheckCase("stream: Werkzeugaufrufe werden über mehrere Stücke zusammengesetzt") {
      let s = StubServer([.json(status: 200, body: sse([
        #"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"add_task","arguments":""}}]}}]}"#,
        #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"title\":"}}]}}]}"#,
        #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Zahnarzt\"}"}}]}}]}"#,
        #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"list_tasks","arguments":"{}"}}]}}]}"#,
      ]))])
      let deltas = AgentLoopChecks.Box<[String]>([])
      let m = try await client(s).chatStream(messages: hi, tools: nil, onDelta: { deltas.value.append($0) })
      try expectEqual(deltas.value, [])
      try expectEqual(m.toolCalls, [
        ToolCall(id: "call_1", name: "add_task", arguments: #"{"title":"Zahnarzt"}"#),
        ToolCall(id: "call_2", name: "list_tasks", arguments: "{}"),
      ])
      try expect(m.content == nil, "Inhalt sollte fehlen")
    },
    CheckCase("stream: [DONE] beendet den Strom, danach kommt nichts mehr an") {
      let body = sse([#"{"choices":[{"index":0,"delta":{"content":"Ja"}}]}"#])
        + #"data: {"choices":[{"index":0,"delta":{"content":" NACH DONE"}}]}"# + "\n\n"
      let s = StubServer([.json(status: 200, body: body)])
      let deltas = AgentLoopChecks.Box<[String]>([])
      let m = try await client(s).chatStream(messages: hi, tools: nil, onDelta: { deltas.value.append($0) })
      try expectEqual(deltas.value, ["Ja"])
      try expectEqual(m.content, "Ja")
    },
    CheckCase("stream: Fehler mitten im Strom wird als LlmError gemeldet") {
      let body = #"data: {"choices":[{"index":0,"delta":{"content":"Ha"}}]}"# + "\n\n"
        + #"data: {"error":{"message":"Rate limited","code":429}}"# + "\n\n"
      let s = StubServer([.json(status: 200, body: body)])
      let e = try await llmError { _ = try await client(s).chatStream(messages: hi, tools: nil, onDelta: { _ in }) }
      try expectEqual(e.code, .rateLimit)
      try expect(!e.message.contains(secret), "Key in Fehlermeldung")
    },
    CheckCase("stream: HTTP-Fehler vor dem Strom wird wie bei chat abgebildet") {
      let s = StubServer([.json(status: 401, body: #"{"error":{"message":"mock"}}"#)])
      let e = try await llmError {
        _ = try await client(s, key: secret).chatStream(messages: hi, tools: nil, onDelta: { _ in })
      }
      try expectEqual(e.code, .auth)
      try expect(!e.message.contains(secret), "Key in Fehlermeldung")
    },
    CheckCase("stream: ganzes JSON ohne Strom wird trotzdem als Antwort gelesen") {
      let s = StubServer([StubServer.text("Hallo!")])
      let deltas = AgentLoopChecks.Box<[String]>([])
      let m = try await client(s).chatStream(messages: hi, tools: nil, onDelta: { deltas.value.append($0) })
      try expectEqual(m, ChatMessage(role: .assistant, content: "Hallo!"))
      try expectEqual(deltas.value, [])
    },
  ] + AppleToolChecks.cases + LlmProviderChecks.cases)

  /// SSE-Körper aus JSON-Stücken: je `data:`-Zeile, am Ende `[DONE]`.
  static func sse(_ events: [String]) -> String {
    events.map { "data: " + $0 + "\n\n" }.joined() + "data: [DONE]\n\n"
  }

  /// Antwort mit usage-Objekt (oben im JSON, wie OpenRouter).
  static func usageReply(cost: String?, model: String? = "resp-model") -> String {
    let modelPart = model.map { #""model":"\#($0)","# } ?? ""
    let costPart = cost.map { #","cost":\#($0)"# } ?? ""
    return #"{\#(modelPart)"choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}],"# +
      #""usage":{"prompt_tokens":12,"completion_tokens":3\#(costPart)}}"#
  }

  /// Sammelt onUsage-Aufrufe (Prüfungen laufen seriell, daher ohne Sperre).
  final class UsageBox: @unchecked Sendable {
    var values: [LlmUsage] = []
    func record(_ u: LlmUsage) { values.append(u) }
  }
}