// Apples Sprachmodell auf dem Mac (Apple Intelligence, FoundationModels) als
// `LlmClient`: kostenlos, ohne Internet, Daten verlassen den Mac nicht.
// Genutzt für Briefing und geplante Aufträge (Einstellung briefingModel =
// TabySettings.appleIntelligenceModel) und als lokales Chat-Modell.
// Werkzeuge: das Modell wählt per Schema einen Aufruf (AppleToolCalling); ausgeführt
// wird er weiter im AgentLoop, nie hier.
import Foundation
import FoundationModels

public final class AppleIntelligenceClient: LlmClient {
  /// Sitzung und Verlauf; bleibt zwischen den chat()-Aufrufen eines Zuges erhalten.
  private let box = ConversationBox()

  public init() {}

  /// true, wenn Apple Intelligence eingeschaltet ist und Deutsch kann (nur ab macOS 26).
  public static var isAvailable: Bool {
    guard #available(macOS 26, *) else { return false }
    return Modern.isAvailable
  }

  public func chat(messages: [ChatMessage], tools: [ToolDef]?) async throws -> ChatMessage {
    guard Self.isAvailable else {
      throw LlmError(.unknown, "Apple Intelligence ist auf diesem Mac nicht verfügbar oder ausgeschaltet.")
    }
    guard #available(macOS 26, *) else {
      throw LlmError(.unknown, "Apple Intelligence braucht macOS 26.")
    }
    do {
      do {
        return try await Modern.reply(messages: messages, tools: tools ?? [], box: box)
      } catch where Modern.isContextOverflow(error) {
        // Zweiter Versuch: nur Grundwerkzeuge und die letzten Nachrichten.
        let core = (tools ?? []).filter { ToolRegistry.handlers[$0.name] != nil }
        return try await Modern.reply(messages: Self.lastTurn(messages), tools: core, box: box)
      }
    } catch is CancellationError {
      throw LlmError(.cancelled, "Abgebrochen.")
    } catch where Modern.isContextOverflow(error) {
      throw LlmError(.unknown, "Apple Intelligence: Die Anfrage ist zu lang für das Modell auf dem Mac. Leere den Verlauf oder frag kürzer.")
    } catch {
      throw LlmError(.unknown, "Apple Intelligence konnte nicht antworten.")
    }
  }

  /// Systemtext ohne den Überblick: der passt nicht ins Kontextfenster (4096 Tokens),
  /// das Modell holt ihn bei Bedarf über get_overview.
  static func slimSystem(_ text: String) -> String {
    guard let r = text.range(of: SystemPrompt.overviewHeading) else { return text }
    return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Systemnachrichten und die letzten drei übrigen (Frage, evtl. Werkzeugaufruf und Ergebnis).
  static func lastTurn(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { $0.role == .system } + messages.filter { $0.role != .system }.suffix(3)
  }

  /// Verlauf als Text. Nach einem Neuaufbau der Sitzung (oder beim ersten Aufruf)
  /// zählt nur der letzte Teil, damit das kleine Kontextfenster reicht.
  static func prompt(from messages: [ChatMessage]) -> String {
    let rest = messages.filter { $0.role != .system }
    if rest.count == 1, rest[0].role == .user { return rest[0].content ?? "" }
    return rest.suffix(8).compactMap(AppleToolCalling.line(for:)).joined(separator: "\n")
  }
}

/// Hält die Sitzung über die Aufrufe eines Zuges (Klasse, damit `chat` nicht mutiert).
/// Der Wert ist ein `Conversation` (nur ab macOS 26), daher als AnyObject.
private final class ConversationBox {
  var value: AnyObject?
}

/// Alles, was FoundationModels direkt anfasst – nur ab macOS 26 (das
/// Framework ist schwach gelinkt, Package.swift).
@available(macOS 26, *)
private enum Modern {
  /// Die Sitzung entsteht erst beim ersten Aufruf und wird wiederverwendet, solange
  /// der bisherige Verlauf der Anfrage vorn anliegt und nicht zu lang wird.
  final class Conversation {
    var session: LanguageModelSession?
    var instructions = ""
    var sent: [ChatMessage] = []
  }

  /// Mehr Nachrichten als das (kleine) Kontextfenster verträgt: neu aufbauen.
  static let maxSent = 12

  static func isContextOverflow(_ error: Error) -> Bool {
    if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
    return false
  }

  static var isAvailable: Bool {
    let m = SystemLanguageModel.default
    guard case .available = m.availability else { return false }
    return m.supportsLocale(Locale(identifier: "de_DE"))
  }

  static func reply(messages: [ChatMessage], tools: [ToolDef], box: ConversationBox) async throws -> ChatMessage {
    let base = AppleIntelligenceClient.slimSystem(
      messages.filter { $0.role == .system }.compactMap(\.content).joined(separator: "\n\n"))
    let instructions = AppleToolCalling.instructions(base: base, tools: tools)
    let conv = (box.value as? Conversation) ?? Conversation()
    box.value = conv

    let fresh = conv.session == nil || conv.instructions != instructions
      || conv.sent.count > maxSent || !messages.starts(with: conv.sent)
    let prompt: String
    if fresh {
      conv.session = LanguageModelSession(instructions: instructions.isEmpty ? nil : instructions)
      conv.instructions = instructions
      conv.sent = []
      prompt = AppleIntelligenceClient.prompt(from: messages)
    } else {
      prompt = messages.dropFirst(conv.sent.count).compactMap(AppleToolCalling.line(for:)).joined(separator: "\n")
    }
    guard let session = conv.session else { throw LlmError(.unknown, "Keine Sitzung.") }

    do {
      let result: ChatMessage
      if tools.isEmpty {
        result = ChatMessage(role: .assistant, content: try await session.respond(to: prompt).content)
      } else {
        let schema = try AppleToolSchema.schema(for: tools)
        let json = try await session.respond(to: prompt, schema: schema).content.jsonString
        result = AppleToolCalling.message(fromGuided: json, tools: tools)
      }
      conv.sent = messages + [result]
      return result
    } catch {
      // Die Sitzung hat den Versuch evtl. schon aufgenommen: beim nächsten Mal neu aufbauen.
      conv.session = nil
      throw error
    }
  }
}

/// Abbildung der Werkzeugargumente auf FoundationModels (dynamisches Schema).
@available(macOS 26, *)
enum AppleToolSchema {
  /// Objekt { tool: Name, reply: Text, arguments: Vereinigung aller Felder }.
  static func schema(for tools: [ToolDef]) throws -> GenerationSchema {
    let merged = AppleToolCalling.merged(tools.map { AppleToolCalling.fields(from: $0.parameters) })
    var props = [
      DynamicGenerationSchema.Property(
        name: "tool", description: "Name des Werkzeugs, das aufgerufen werden soll",
        schema: DynamicGenerationSchema(name: "ToolName", description: nil, anyOf: tools.map(\.name)),
        isOptional: true),
      DynamicGenerationSchema.Property(
        name: "reply", description: "Antwort an den Nutzer, wenn kein Werkzeug nötig ist",
        schema: DynamicGenerationSchema(type: String.self), isOptional: true),
    ]
    if !merged.isEmpty {
      let args = DynamicGenerationSchema(name: "Arguments", description: nil, properties: merged.map(property))
      props.append(DynamicGenerationSchema.Property(
        name: "arguments", description: "Argumente des Werkzeugs", schema: args, isOptional: true))
    }
    return try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", description: nil, properties: props),
                                dependencies: [])
  }

  static func property(_ f: AppleToolCalling.Field) -> DynamicGenerationSchema.Property {
    let schema: DynamicGenerationSchema
    switch f.kind {
    case .string: schema = DynamicGenerationSchema(type: String.self)
    case .number: schema = DynamicGenerationSchema(type: Double.self)
    case .integer: schema = DynamicGenerationSchema(type: Int.self)
    case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
    case .stringArray: schema = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
    }
    return DynamicGenerationSchema.Property(name: f.name, description: f.description, schema: schema,
                                            isOptional: !f.required)
  }
}
