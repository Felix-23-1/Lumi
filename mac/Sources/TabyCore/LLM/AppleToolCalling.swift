// Werkzeugaufrufe für Apple Intelligence. Ohne FoundationModels-Typen (damit
// die Prüfungen überall laufen); die Framework-Abbildung steht in
// AppleToolSchema (macOS 26).
//
// Warum Guided Generation statt Framework-Werkzeugen: FoundationModels führt
// ein Werkzeug selbst aus und setzt die Antwort danach fort. Taby muss aber
// bestätigen lassen und selbst ausführen. Deshalb liefert das Modell per
// Schema entweder {"tool": Name, "arguments": {...}} oder {"reply": Text}.
import Foundation

enum AppleToolCalling {
  /// Ein Argumentfeld, vereinfacht auf das, was Apple abbilden kann.
  struct Field: Equatable {
    enum Kind: Equatable { case string, number, integer, boolean, stringArray }
    var name: String
    var description: String?
    var kind: Kind
    var required: Bool
  }

  /// Felder aus dem JSON-Schema der Argumente. Objekte, verschachtelte Listen
  /// und sonstiges werden als Text (JSON-Zeichenkette) angeboten.
  static func fields(from schema: JSONValue) -> [Field] {
    guard let root = schema.objectValue, let props = root["properties"]?.objectValue else { return [] }
    let required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    return props.keys.sorted().map { name in
      let spec = props[name]?.objectValue ?? [:]
      var description = spec["description"]?.stringValue
      var kind = Field.Kind.string
      switch spec["type"]?.stringValue {
      case "number": kind = .number
      case "integer": kind = .integer
      case "boolean": kind = .boolean
      case "array":
        if spec["items"]?.objectValue?["type"]?.stringValue == "string" { kind = .stringArray }
      default: break
      }
      if let options = spec["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
        description = [description, "Erlaubt: " + options.joined(separator: ", ")].compactMap { $0 }.joined(separator: " ")
      }
      return Field(name: name, description: description, kind: kind, required: required.contains(name))
    }
  }

  /// Vereinigung über alle Werkzeuge: je Name ein Feld; Pflicht nur, wenn jedes
  /// Werkzeug, das es nennt, es verlangt und alle Werkzeuge es nennen.
  static func merged(_ lists: [[Field]]) -> [Field] {
    var result: [String: Field] = [:]
    var count: [String: Int] = [:]
    for list in lists {
      for f in list {
        count[f.name, default: 0] += 1
        if var old = result[f.name] {
          old.required = old.required && f.required
          result[f.name] = old
        } else {
          result[f.name] = f
        }
      }
    }
    return result.values.sorted { $0.name < $1.name }.map { f in
      var f = f
      f.required = f.required && count[f.name] == lists.count
      return f
    }
  }

  /// Systemtext mit Werkzeugliste. Ohne Werkzeuge bleibt der Text unverändert.
  static func instructions(base: String, tools: [ToolDef]) -> String {
    guard !tools.isEmpty else { return base }
    let list = tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    let guide = "Werkzeuge (nur nutzen, wenn der Nutzer etwas tun will oder Daten braucht):\n" + list
      + "\nAntworte mit \"tool\" und \"arguments\" für einen Aufruf, sonst mit \"reply\"."
    return base.isEmpty ? guide : base + "\n\n" + guide
  }

  /// Wandelt die geführte Antwort in eine Assistenten-Nachricht. Unbekannte
  /// Werkzeuge und Felder werden verworfen; ohne gültige Antwort gibt es Text.
  static func message(fromGuided json: String, tools: [ToolDef]) -> ChatMessage {
    guard let root = JSONValue.parse(json)?.objectValue else {
      return ChatMessage(role: .assistant, content: json)
    }
    if let name = root["tool"]?.stringValue, let def = tools.first(where: { $0.name == name }) {
      let allowed = Set(fields(from: def.parameters).map(\.name))
      var args: [String: JSONValue] = [:]
      for (key, value) in root["arguments"]?.objectValue ?? [:] where allowed.contains(key) && value != .null {
        args[key] = value
      }
      return ChatMessage(role: .assistant, content: nil, toolCalls: [
        ToolCall(id: "apple-" + UUID().uuidString, name: name, arguments: JSONValue.object(args).jsonString()),
      ])
    }
    return ChatMessage(role: .assistant, content: root["reply"]?.stringValue ?? "")
  }

  /// Eine Zeile je Nachricht für den Modell-Prompt (Systemnachrichten fehlen hier).
  static func line(for m: ChatMessage) -> String? {
    switch m.role {
    case .system: return nil
    case .user: return "Nutzer: " + (m.content ?? "")
    case .assistant:
      if let calls = m.toolCalls, !calls.isEmpty {
        return calls.map { "Assistent ruft \($0.function.name) mit \($0.function.arguments) auf" }.joined(separator: "\n")
      }
      return "Assistent: " + (m.content ?? "")
    case .tool: return "Ergebnis von \(m.name ?? "Werkzeug"): " + (m.content ?? "")
    }
  }
}
