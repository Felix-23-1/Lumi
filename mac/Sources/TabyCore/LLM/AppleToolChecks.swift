// Prüfungen für Werkzeuge bei Apple Intelligence (AppleToolCalling und die
// Schema-Abbildung). Ohne echtes Modell: die geführte Antwort wird als Text
// vorgegeben. Echtes Modell prüft nur ein Mac mit Apple Intelligence (HANDTEST).
import Foundation

enum AppleToolChecks {
  static func schema(_ text: String) throws -> JSONValue {
    try expectNotNil(JSONValue.parse(text))
  }

  static let createTask = ToolDef(
    name: "create_task", description: "Legt eine Aufgabe an.",
    parameters: try! schema(#"""
    {"type":"object","properties":{
      "title":{"type":"string","description":"Titel"},
      "minutes":{"type":"integer"},
      "weight":{"type":"number"},
      "urgent":{"type":"boolean"},
      "tags":{"type":"array","items":{"type":"string"}},
      "priority":{"type":"string","enum":["low","high"]},
      "meta":{"type":"object"}},
     "required":["title","minutes"]}
    """#))

  static let listTasks = ToolDef(
    name: "list_tasks", description: "Zeigt offene Aufgaben.",
    parameters: try! schema(#"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#))

  static let cases: [CheckCase] = [
    CheckCase("Apple: Systemtext ohne Überblick (Kontextfenster 4096)") {
      let full = SystemPrompt.build(clock: ControllableClock("2026-10-16T09:00"), personality: .locker,
                                    customInstructions: "", overview: Overview())
      let slim = AppleIntelligenceClient.slimSystem(full)
      try expect(full.contains(SystemPrompt.overviewHeading), "voll hat Überblick")
      try expect(!slim.contains(SystemPrompt.overviewHeading) && slim.contains("Heutiges Datum"), "schlank ohne Überblick")
      let msgs = [ChatMessage(role: .system, content: "s")] + (0..<6).map { ChatMessage(role: .user, content: "\($0)") }
      let last = AppleIntelligenceClient.lastTurn(msgs)
      try expectEqual(last.map { $0.content ?? "" }, ["s", "3", "4", "5"])
    },
    CheckCase("JSON-Schema wird zu Feldern mit Typ und Pflicht") {
      let fields = AppleToolCalling.fields(from: createTask.parameters)
      try expectEqual(fields.map(\.name), ["meta", "minutes", "priority", "tags", "title", "urgent", "weight"])
      let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
      try expectEqual(byName["title"]?.kind, .string)
      try expectEqual(byName["title"]?.required, true)
      try expectEqual(byName["minutes"]?.kind, .integer)
      try expectEqual(byName["minutes"]?.required, true)
      try expectEqual(byName["weight"]?.kind, .number)
      try expectEqual(byName["urgent"]?.kind, .boolean)
      try expectEqual(byName["tags"]?.kind, .stringArray)
      try expectEqual(byName["meta"]?.kind, .string, "Objekt fällt auf Text zurück")
      try expectEqual(byName["priority"]?.description, "Erlaubt: low, high")
      try expectEqual(byName["urgent"]?.required, false)
      try expectEqual(AppleToolCalling.fields(from: .string("kaputt")), [])
    },
    CheckCase("Vereinigung: Pflicht nur, wenn alle Werkzeuge das Feld verlangen") {
      let merged = AppleToolCalling.merged([
        AppleToolCalling.fields(from: createTask.parameters),
        AppleToolCalling.fields(from: listTasks.parameters),
      ])
      let byName = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0) })
      try expectEqual(byName["title"]?.required, true)
      try expectEqual(byName["minutes"]?.required, false, "nur create_task verlangt es")
      try expectEqual(merged.count, 7)
    },
    CheckCase("geführte Antwort mit Werkzeug wird zu toolCalls, unbekannte Felder fliegen raus") {
      let json = #"{"tool":"create_task","arguments":{"title":"Milch","minutes":5,"bogus":1,"urgent":null}}"#
      let m = AppleToolCalling.message(fromGuided: json, tools: [createTask, listTasks])
      try expectEqual(m.role, .assistant)
      try expectEqual(m.content, nil)
      let call = try expectNotNil(m.toolCalls?.first)
      try expectEqual(m.toolCalls?.count, 1)
      try expectEqual(call.function.name, "create_task")
      try expectEqual(JSONValue.parse(call.function.arguments), .object(["title": "Milch", "minutes": 5]))
    },
    CheckCase("geführte Antwort mit reply wird zu Text") {
      let m = AppleToolCalling.message(fromGuided: #"{"reply":"Hallo!"}"#, tools: [createTask])
      try expectEqual(m, ChatMessage(role: .assistant, content: "Hallo!"))
    },
    CheckCase("unbekanntes Werkzeug und kaputtes JSON geben Text, kein Absturz") {
      let unknown = AppleToolCalling.message(fromGuided: #"{"tool":"gibtsnicht","reply":"ok"}"#, tools: [createTask])
      try expectEqual(unknown, ChatMessage(role: .assistant, content: "ok"))
      let broken = AppleToolCalling.message(fromGuided: "kein json", tools: [createTask])
      try expectEqual(broken, ChatMessage(role: .assistant, content: "kein json"))
    },
    CheckCase("Systemtext nennt Werkzeuge nur, wenn welche da sind") {
      try expectEqual(AppleToolCalling.instructions(base: "Basis", tools: []), "Basis")
      let text = AppleToolCalling.instructions(base: "", tools: [createTask])
      try expect(text.contains("- create_task: Legt eine Aufgabe an."), "Werkzeug fehlt im Systemtext")
    },
    CheckCase("Verlauf mit Werkzeugergebnis erscheint im Prompt") {
      let call = ToolCall(id: "1", name: "create_task", arguments: #"{"title":"Milch"}"#)
      let prompt = AppleIntelligenceClient.prompt(from: [
        ChatMessage(role: .system, content: "sys"),
        ChatMessage(role: .user, content: "Milch kaufen"),
        ChatMessage(role: .assistant, content: nil, toolCalls: [call]),
        ChatMessage(role: .tool, content: "angelegt", name: "create_task", toolCallId: "1"),
      ])
      try expect(prompt.contains(#"Assistent ruft create_task mit {"title":"Milch"} auf"#), "Aufruf fehlt")
      try expect(prompt.hasSuffix("Ergebnis von create_task: angelegt"), "Ergebnis fehlt")
      try expect(!prompt.contains("sys"), "Systemtext gehört nicht in den Prompt")
    },
    CheckCase("ohne Apple Intelligence: Fehler statt Absturz") {
      guard !AppleIntelligenceClient.isAvailable else { return }
      do {
        _ = try await AppleIntelligenceClient().chat(messages: [ChatMessage(role: .user, content: "hi")],
                                                     tools: [createTask])
        throw fail("sollte ohne Verfügbarkeit werfen")
      } catch let e as LlmError {
        try expectEqual(e.code, .unknown)
      }
    },
    CheckCase("Framework-Schema lässt sich aus den Werkzeugen bauen") {
      guard #available(macOS 26, *) else { return }
      let schema = try AppleToolSchema.schema(for: [createTask, listTasks])
      let text = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
      for word in ["create_task", "list_tasks", "minutes", "priority", "reply", "integer", "boolean", "array"] {
        try expect(text.contains(word), "\(word) fehlt im Schema")
      }
    },
  ]
}
