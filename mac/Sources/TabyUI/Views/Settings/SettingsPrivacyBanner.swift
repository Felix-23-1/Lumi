// Statusbanner oben auf der Datenschutz-Seite: wohin Anfragen gerade gehen. Abgeleitet nur aus
// den Modell-Einstellungen (Apple Intelligence, lokale Adresse, Anbieter), nichts davon wird geraten.
import SwiftUI
import TabyCore

enum PrivacyRoute {
  /// Text und ob die Anfragen auf diesem Mac bleiben.
  static func line(llmModel: String, llmBaseUrl: String) -> (text: String, local: Bool) {
    if llmModel == TabySettings.appleIntelligenceModel { return ("Nur lokal (Apple Intelligence)", true) }
    if LlmConnection.isLocalEndpoint(llmBaseUrl) { return ("Nur lokal (auf diesem Mac)", true) }
    guard let name = LlmProviders.preset(forBaseUrl: llmBaseUrl)?.name ?? LlmConnection.host(of: llmBaseUrl) else {
      return ("Noch kein Anbieter eingerichtet", true)
    }
    return ("Anfragen gehen an: \(name)", false)
  }
}

extension SettingsView {
  /// Wird oben auf der Datenschutz-Seite gezeigt.
  var privacyRouteBanner: some View {
    let r = PrivacyRoute.line(llmModel: form.llmModel, llmBaseUrl: form.llmBaseUrl)
    return Banner(symbol: r.local ? "lock.fill" : "arrow.up.right", text: r.text, tint: r.local ? Theme.green : Theme.amber)
  }
}
