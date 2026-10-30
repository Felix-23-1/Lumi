// Agent-Schleife (BAUPLAN.md Abschnitt 8), Port von src/main/agent/
// agent-loop.ts: bis zu 8 Schritte, Systemprompt pro Modell-Anfrage neu
// gebaut, Verlauf auf die letzten 40 Nachrichten begrenzt. Werkzeugfehler
// (unbekannt, abgelehnte Argumente, Ausnahme) brechen die Schleife nicht ab,
// sondern gehen als ToolResult-JSON zurück ans Modell. Abbruch über
// Swift-Task-Cancellation (→ LlmError .cancelled).
import Foundation

/// Führt ein Werkzeug aus. `argumentsJson` ist die rohe Argument-Zeichenkette
/// des Modells; Rückgabe ist das ToolResult als JSON-String
/// (`{"ok":true,...}` bzw. `{"ok":false,"code":...,"error":...}`).
public typealias AgentToolExecutor = (_ name: String, _ argumentsJson: String) async throws -> String

public struct AgentDeps {
  public var llm: LlmClient
  public var tools: [ToolDef]
  public var executeTool: AgentToolExecutor
  public var personality: Personality
  public var customInstructions: String
  public var getOverview: () async -> Overview
  public var clock: Clock
  public var maxSteps: Int
  /// Called for every new message (user, assistant, tool) in order, as soon as it exists –
  /// also when the loop later throws. Lets the caller persist partial progress.
  public var onMessage: ((ChatMessage) -> Void)?
  /// Gemerkte Fakten für den Systemprompt; wird pro Schritt abgefragt.
  public var getMemories: () async -> [Memory]
  /// Arbeitszeiten für den Systemprompt (nil = nicht genannt).
  public var workSettings: TabySettings?

  public init(llm: LlmClient, tools: [ToolDef], executeTool: @escaping AgentToolExecutor,
              personality: Personality, customInstructions: String,
              getOverview: @escaping () async -> Overview = { .empty }, clock: Clock,
              maxSteps: Int = AgentLoop.maxSteps,
              onMessage: ((ChatMessage) -> Void)? = nil,
              getMemories: @escaping () async -> [Memory] = { [] }, workSettings: TabySettings? = nil) {
    self.workSettings = workSettings
    self.llm = llm; self.tools = tools; self.executeTool = executeTool
    self.personality = personality; self.customInstructions = customInstructions
    self.getOverview = getOverview; self.clock = clock; self.maxSteps = maxSteps
    self.onMessage = onMessage; self.getMemories = getMemories
  }
}

public enum AgentLoop {
  public static let maxSteps = 8
  public static let historyLimit = 40

  /// Letzte `limit` Nachrichten; schneidet weiter ab, solange die älteste
  /// verbleibende eine verwaiste Tool-Antwort wäre.
  public static func trimHistory(_ messages: [ChatMessage], limit: Int) -> [ChatMessage] {
    var start = max(0, messages.count - limit)
    while start < messages.count && messages[start].role == .tool { start += 1 }
    return Array(messages[start...])
  }

  static func failureJSON(code: String, error: String) -> String {
    JSONValue.object(["ok": .bool(false), "code": .string(code), "error": .string(error)]).jsonString()
  }

  static func runTool(_ deps: AgentDeps, known: Set<String>, call: ToolCall) async -> String {
    guard known.contains(call.function.name) else {
      return failureJSON(code: "UNKNOWN_TOOL", error: "Unbekanntes Werkzeug: \(call.function.name)")
    }
    do {
      return try await deps.executeTool(call.function.name, call.function.arguments)
    } catch is CancellationError {
      return failureJSON(code: "CANCELLED", error: "Werkzeug-Ausführung abgebrochen.")
    } catch {
      let msg = (error as? LocalizedError)?.errorDescription ?? "Werkzeug-Ausführung fehlgeschlagen."
      return failureJSON(code: "TOOL_ERROR", error: msg)
    }
  }

  private static func checkCancelled() throws {
    if Task.isCancelled { throw LlmError(.cancelled, LlmMessages.cancelled) }
  }

  /// Führt einen Nutzer-Turn aus. `history` ist der bisherige Verlauf ohne
  /// Systemprompt. Gibt die neu entstandenen Nachrichten zurück (User-
  /// Eingabe, Assistant- und Tool-Antworten). Wirft `LlmError` des Clients
  /// unverändert weiter, bei Abbruch `.cancelled`.
  /// Mit `onPartial` läuft jede Modell-Anfrage als Strom: `onPartial` bekommt den
  /// gesamten bisherigen Text dieses Modellschritts (gebündelt). Werkzeuge bleiben gleich.
  public static func run(_ deps: AgentDeps, history: [ChatMessage], userText: String,
                         onPartial: (@Sendable (String) -> Void)? = nil) async throws -> [ChatMessage]
  {
    let known = Set(deps.tools.map(\.name))
    let userMessage = ChatMessage(role: .user, content: userText)
    var conversation = history + [userMessage]
    var newMessages: [ChatMessage] = []
    func record(_ message: ChatMessage) {
      newMessages.append(message)
      deps.onMessage?(message)
    }
    record(userMessage)

    for _ in 0..<max(0, deps.maxSteps) {
      try checkCancelled()
      let overview = await deps.getOverview()
      let memories = await deps.getMemories()
      let system = ChatMessage(
        role: .system,
        content: SystemPrompt.build(
          clock: deps.clock, personality: deps.personality,
          customInstructions: deps.customInstructions, overview: overview, memories: memories,
          settings: deps.workSettings))

      let request = [system] + trimHistory(conversation, limit: historyLimit)
      let message: ChatMessage
      do {
        if let onPartial {
          let throttle = PartialThrottle(emit: onPartial)
          defer { throttle.finish() }
          message = try await deps.llm.chatStream(messages: request, tools: deps.tools,
                                                  onDelta: { throttle.append($0) })
        } else {
          message = try await deps.llm.chat(messages: request, tools: deps.tools)
        }
      } catch {
        throw mapTransportError(error)
      }
      conversation.append(message)
      record(message)

      let calls = message.toolCalls ?? []
      if calls.isEmpty { break }

      for call in calls {
        try checkCancelled()
        let result = await runTool(deps, known: known, call: call)
        // Jedes Werkzeugergebnis ist Material, nie Anweisung: zentral verpacken, außer es ist schon verpackt.
        let packed = ForeignContent.isWrapped(result) ? result : ForeignContent.wrap(result)
        let toolMessage = ChatMessage(role: .tool, content: packed, name: call.function.name, toolCallId: call.id)
        conversation.append(toolMessage)
        record(toolMessage)
      }
    }
    return newMessages
  }
}
