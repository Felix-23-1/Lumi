// Datenschutz-Schranke (A3): entscheidet ohne Netz, ob Daten an ein Cloud-Modell
// dürfen. Wird vor jedem Modellaufruf und jedem Mod-Internetabruf gelesen.
import Foundation

public enum PrivacyGate {
  /// Fehlercode, wenn für ein Cloud-Modell noch keine Einwilligung vorliegt (es wird nichts gesendet).
  public static let consentCode = "CONSENT"

  /// Gespeicherte Einwilligung `cloudConsentAt`: "<ISO-Zeit>|<host>". Ein Wert ohne "|" stammt aus
  /// der Zeit vor der Host-Bindung und gilt für openrouter.ai.
  public static func consent(_ raw: String) -> (at: String, host: String)? {
    guard !raw.isEmpty else { return nil }
    guard let bar = raw.lastIndex(of: "|") else { return (raw, LlmConnection.defaultHost) }
    return (String(raw[..<bar]), String(raw[raw.index(after: bar)...]))
  }

  /// Wert für `cloudConsentAt` bei Einwilligung für den Endpunkt `baseUrl`.
  public static func consentValue(at: String, baseUrl: String) -> String {
    "\(at)|\(LlmConnection.host(of: baseUrl) ?? "")"
  }

  /// Cloud-Modell ohne Einwilligung für genau diesen Host (ein neuer Host fragt erneut).
  /// Im Nur-lokal-Modus ist die Frage gegenstandslos (dort gibt es ohnehin keinen Cloud-Client).
  public static func needsConsent(_ s: TabySettings, model: String) -> Bool {
    guard !s.localOnly else { return false }
    let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !m.isEmpty, m != TabySettings.appleIntelligenceModel, !LlmConnection.isLocalEndpoint(s.llmBaseUrl) else {
      return false
    }
    let given = consent(s.cloudConsentAt)
    return given == nil || given!.at.isEmpty || given!.host != (LlmConnection.host(of: s.llmBaseUrl) ?? "")
  }
}
