import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  var settings: TabySettings {
    var s = (try? store.settings.get()) ?? .defaults
    s.hasApiKey = llmKeyStore(for: s.llmBaseUrl).hasKey()
    return s
  }

  /// Schlüssel-Speicher für den Endpunkt `baseUrl`: openrouter.ai nutzt den bisherigen Eintrag,
  /// jeder andere Host seinen eigenen (Key geht nie an einen anderen Host).
  func llmKeyStore(for baseUrl: String) -> ApiKeyStore {
    let host = LlmConnection.host(of: baseUrl) ?? ""
    if host == LlmConnection.defaultHost { return keyStore }
    return options.llmHostKeyStore(host)
  }

  /// Verbrauch je Antwort speichern (Rückruf kommt von der Netzwerk-Queue;
  /// das Repository ist threadsicher).
  private var recordUsage: (LlmUsage) -> Void {
    { [store] u in _ = try? store.usage.record(u) }
  }

  func usageSummary() -> UsageSummary {
    let s = settings
    return (try? store.usage.summary(dailyLimit: s.dailyCostLimitUsd, monthlyLimit: s.monthlyCostLimitUsd))
      ?? UsageSummary()
  }

  /// Über dem Kostenlimit wird das Modell nicht mehr gerufen.
  var limitReached: Bool { usageSummary().limitReached }

  static let limitMessage =
    "Kostenlimit erreicht – das Modell pausiert. Du kannst das Limit in den Einstellungen unter „Verbrauch“ anheben."

  /// Starkes Modell (Chat, Schnellerfassung).
  func llmClient() -> LlmClient? {
    // Apple Intelligence läuft lokal; ein Cloud-Client mit diesem Modellnamen würde Dateiinhalte senden.
    if settings.llmModel == TabySettings.appleIntelligenceModel {
      return appleIntelligenceAvailable ? AppleIntelligenceClient() : nil
    }
    // Nur lokal: eigener Rechner (Ollama/LM Studio) oder Apple Intelligence statt Cloud – nie nichts,
    // wenn eins davon geht (vorher blieb der Chat stumm, sobald noch ein Cloud-Modell eingestellt war).
    if settings.localOnly { return localOnlyClient(model: nil) }
    if PrivacyGate.needsConsent(settings, model: settings.llmModel) { return nil }
    return LlmConnection.makeClient(settings: settings, keyStore: llmKeyStore(for: settings.llmBaseUrl),
                                    session: options.session, onUsage: recordUsage)
  }

  /// Im Nur-lokal-Modus: lokaler Endpunkt, sonst Apple Intelligence, sonst nil.
  private func localOnlyClient(model: String?) -> LlmClient? {
    if LlmConnection.isLocalEndpoint(settings.llmBaseUrl) {
      return LlmConnection.makeClient(settings: settings, keyStore: llmKeyStore(for: settings.llmBaseUrl),
                                      session: options.session, model: model, onUsage: recordUsage)
    }
    return appleIntelligenceAvailable ? AppleIntelligenceClient() : nil
  }

  /// Günstiges Modell für Briefing und geplante Aufträge (Einstellung
  /// `briefingModel`, leer = gleiches Modell wie im Chat).
  func cheapLlmClient() -> LlmClient? {
    let s = settings
    let model = s.briefingModel.isEmpty ? s.llmModel : s.briefingModel
    if model == TabySettings.appleIntelligenceModel {
      return appleIntelligenceAvailable ? AppleIntelligenceClient() : nil
    }
    if s.localOnly { return localOnlyClient(model: s.briefingModel.isEmpty ? nil : s.briefingModel) }
    if PrivacyGate.needsConsent(s, model: model) { return nil }
    return LlmConnection.makeClient(settings: s, keyStore: llmKeyStore(for: s.llmBaseUrl), session: options.session,
                                    model: s.briefingModel.isEmpty ? nil : s.briefingModel, onUsage: recordUsage)
  }
}
