// VERTRAG (nur Orchestrator ändert). Port von src/shared/llm.ts.
// OpenAI-kompatibles Chat-Format (/chat/completions mit tools).
import Foundation

public struct ToolCall: Codable, Equatable, Sendable {
  public struct Function: Codable, Equatable, Sendable {
    public var name: String
    /// JSON-Zeichenkette, wie vom Modell geliefert.
    public var arguments: String
    public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
  }

  public var id: String
  public var type: String = "function"
  public var function: Function

  public init(id: String, name: String, arguments: String) {
    self.id = id; self.function = Function(name: name, arguments: arguments)
  }
}

public enum ChatRole: String, Codable, Sendable {
  case system, user, assistant, tool
}

public struct ChatMessage: Codable, Equatable, Sendable {
  public var role: ChatRole
  public var content: String?
  /// Bei role .tool: Werkzeugname.
  public var name: String?
  /// Bei role .tool: Bezug zum Aufruf.
  public var toolCallId: String?
  /// Bei role .assistant: angeforderte Aufrufe.
  public var toolCalls: [ToolCall]?

  private enum CodingKeys: String, CodingKey {
    case role, content, name
    case toolCallId = "tool_call_id"
    case toolCalls = "tool_calls"
  }

  public init(role: ChatRole, content: String?, name: String? = nil, toolCallId: String? = nil,
              toolCalls: [ToolCall]? = nil) {
    self.role = role; self.content = content; self.name = name
    self.toolCallId = toolCallId; self.toolCalls = toolCalls
  }
}

public struct ToolDef: Equatable, Sendable {
  public var name: String
  public var description: String
  /// JSON-Schema der Argumente.
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name; self.description = description; self.parameters = parameters
  }
}

public enum LlmErrorCode: String, Codable, Sendable {
  case auth, quota
  case noTools = "no-tools"
  case rateLimit = "rate-limit"
  case network
  case badResponse = "bad-response"
  case cancelled
  case unknown
}

public struct LlmError: Error, Equatable {
  public var code: LlmErrorCode
  public var message: String

  public init(_ code: LlmErrorCode, _ message: String) {
    self.code = code; self.message = message
  }
}

/// Verbrauch einer Modell-Antwort (OpenRouter liefert `usage` inkl. `cost`).
public struct LlmUsage: Codable, Equatable, Sendable {
  public var model: String
  public var promptTokens: Int
  public var completionTokens: Int
  /// Kosten in US-Dollar, falls der Anbieter sie meldet.
  public var costUsd: Double?

  public init(model: String, promptTokens: Int, completionTokens: Int, costUsd: Double? = nil) {
    self.model = model; self.promptTokens = promptTokens
    self.completionTokens = completionTokens; self.costUsd = costUsd
  }
}

public protocol LlmClient: AnyObject {
  /// Wirft `LlmError`. Abbruch über Swift-Task-Cancellation (→ `.cancelled`).
  func chat(messages: [ChatMessage], tools: [ToolDef]?) async throws -> ChatMessage
  /// Wie `chat`, liefert Text aber schon unterwegs: `onDelta` bekommt jeweils das neue Stück.
  /// Werkzeugaufrufe kommen wie bei `chat` erst im Ergebnis. Standard: ruft `chat` ohne Teiltexte.
  func chatStream(messages: [ChatMessage], tools: [ToolDef]?,
                  onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatMessage
}

extension LlmClient {
  public func chatStream(messages: [ChatMessage], tools: [ToolDef]?,
                         onDelta: @escaping @Sendable (String) -> Void) async throws -> ChatMessage {
    try await chat(messages: messages, tools: tools)
  }
}

public struct LlmTestResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var message: String

  public init(ok: Bool, message: String) {
    self.ok = ok; self.message = message
  }
}
