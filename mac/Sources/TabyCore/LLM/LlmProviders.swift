// Anbieter-Voreinstellungen für die Modell-Einstellungen. Alle sprechen das OpenAI-Format
// (`/chat/completions`, Bearer-Schlüssel). Der Schlüssel geht nur an den Host des Anbieters
// (siehe LlmConnection.keyAccount).
import Foundation

public struct LlmProvider: Equatable, Sendable {
  public let name: String
  public let baseUrl: String
  /// Vorschlag für die Modell-Kennung; im Feld frei änderbar.
  public let defaultModel: String
  /// Seite, auf der man den Schlüssel anlegt.
  public let keyUrl: String

  public var host: String { LlmConnection.host(of: baseUrl) ?? "" }
}

public enum LlmProviders {
  public static let openRouter = LlmProvider(
    name: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1",
    defaultModel: "openai/gpt-4o-mini", keyUrl: "https://openrouter.ai/keys")
  public static let openAI = LlmProvider(
    name: "OpenAI", baseUrl: "https://api.openai.com/v1",
    defaultModel: "gpt-4o-mini", keyUrl: "https://platform.openai.com/api-keys")
  /// Anthropic über den OpenAI-kompatiblen Endpunkt (Bearer statt x-api-key).
  public static let anthropic = LlmProvider(
    name: "Anthropic", baseUrl: "https://api.anthropic.com/v1",
    defaultModel: "claude-sonnet-5-5", keyUrl: "https://console.anthropic.com/settings/keys")
  public static let gemini = LlmProvider(
    name: "Google Gemini", baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
    defaultModel: "gemini-2.0-flash", keyUrl: "https://aistudio.google.com/app/apikey")
  public static let mistral = LlmProvider(
    name: "Mistral", baseUrl: "https://api.mistral.ai/v1",
    defaultModel: "mistral-small-latest", keyUrl: "https://console.mistral.ai/api-keys")
  public static let groq = LlmProvider(
    name: "Groq", baseUrl: "https://api.groq.com/openai/v1",
    defaultModel: "llama-3.3-70b-versatile", keyUrl: "https://console.groq.com/keys")
  public static let deepSeek = LlmProvider(
    name: "DeepSeek", baseUrl: "https://api.deepseek.com/v1",
    defaultModel: "deepseek-chat", keyUrl: "https://platform.deepseek.com/api_keys")

  /// Alle Cloud-Voreinstellungen in der Reihenfolge der Auswahl.
  public static let all: [LlmProvider] = [openRouter, openAI, anthropic, gemini, mistral, groq, deepSeek]

  /// Voreinstellung zu einer Endpunkt-URL (Vergleich über den Host). nil für lokale Server und eigene Anbieter.
  public static func preset(forBaseUrl baseUrl: String) -> LlmProvider? {
    guard let host = LlmConnection.host(of: baseUrl) else { return nil }
    return all.first { $0.host == host }
  }

  /// Setzt Endpunkt und Vorschlags-Modell. Das Briefing-Modell wird geleert, damit es dem
  /// Chat-Modell des neuen Anbieters folgt (ein altes Modell eines anderen Anbieters wäre falsch).
  public static func apply(_ p: LlmProvider, to s: inout TabySettings) {
    s.llmBaseUrl = p.baseUrl
    s.llmModel = p.defaultModel
    s.briefingModel = ""
  }
}
