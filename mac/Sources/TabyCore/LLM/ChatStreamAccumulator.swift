// Setzt einen OpenAI-kompatiblen SSE-Strom (`data:`-Zeilen, `[DONE]`) zur
// Antwort zusammen. Reine Logik ohne Netz, damit sie ohne HTTP prüfbar ist.
import Foundation

struct ChatStreamAccumulator {
  private struct PartialCall {
    var id = ""
    var name = ""
    var arguments = ""
  }

  let configuredModel: String
  /// Gesetzt, sobald `data: [DONE]` kam.
  private(set) var done = false
  /// Verbrauch aus dem letzten Stück (nur mit `stream_options.include_usage`).
  private(set) var usage: LlmUsage?

  private var text = ""
  private var calls: [Int: PartialCall] = [:]
  private var sawData = false
  /// Nicht-SSE-Zeilen: falls der Server trotz `stream` ein normales JSON schickt.
  private var rawLines: [String] = []

  init(configuredModel: String) { self.configuredModel = configuredModel }

  /// Verarbeitet eine Zeile. Liefert den neuen Textteil, wenn dieser Stück Text enthält.
  mutating func feed(_ line: String) throws -> String? {
    guard line.hasPrefix("data:") else {
      if !line.isEmpty { rawLines.append(line) }
      return nil
    }
    sawData = true
    let payload = line.dropFirst(5).drop(while: { $0 == " " })
    if payload == "[DONE]" {
      done = true
      return nil
    }
    guard let json = JSONValue.parse(String(payload)) else {
      throw LlmError(.badResponse, LlmMessages.badResponse)
    }
    if let err = json["error"] { throw Self.streamError(err) }
    if let u = HttpLlmClient.usage(from: json, configuredModel: configuredModel) { usage = u }
    guard let delta = json["choices"]?.arrayValue?.first?["delta"] else { return nil }

    var piece: String?
    if let c = delta["content"]?.stringValue, !c.isEmpty {
      text += c
      piece = c
    }
    for item in delta["tool_calls"]?.arrayValue ?? [] {
      let index = HttpLlmClient.intValue(item["index"]) ?? 0
      var call = calls[index] ?? PartialCall()
      if let id = item["id"]?.stringValue, !id.isEmpty { call.id = id }
      // Der Name kommt meist einmal; spätere Wiederholungen hängen nichts an.
      if let name = item["function"]?["name"]?.stringValue, !name.isEmpty, call.name.isEmpty {
        call.name = name
      }
      if let args = item["function"]?["arguments"]?.stringValue { call.arguments += args }
      calls[index] = call
    }
    return piece
  }

  /// Fertige Antwort. Wirft `.badResponse`, wenn nichts Brauchbares kam.
  func message() throws -> ChatMessage {
    if !sawData {
      // Kein Strom: ganze Antwort als JSON (wie `chat`) auswerten.
      guard let json = JSONValue.parse(rawLines.joined(separator: "\n")) else {
        throw LlmError(.badResponse, LlmMessages.badResponse)
      }
      return try HttpLlmClient.normalizeMessage(json["choices"]?.arrayValue?.first?["message"])
    }
    var result: [ToolCall] = []
    for (_, call) in calls.sorted(by: { $0.key < $1.key }) {
      guard !call.id.isEmpty, !call.name.isEmpty else {
        throw LlmError(.badResponse, LlmMessages.badResponse)
      }
      result.append(ToolCall(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments))
    }
    return ChatMessage(role: .assistant, content: text.isEmpty ? nil : text,
                       toolCalls: result.isEmpty ? nil : result)
  }

  /// Fehler mitten im Strom (`{"error":{...}}`) auf LlmError abbilden.
  static func streamError(_ err: JSONValue) -> LlmError {
    let code = HttpLlmClient.intValue(err["code"]) ?? 0
    if code == 0 { return LlmError(.badResponse, LlmMessages.badResponse) }
    return mapHttpError(status: code, body: err.jsonString())
  }
}
