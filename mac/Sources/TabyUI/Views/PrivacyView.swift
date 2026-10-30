// Einstellungen „Datenschutz“ (A3): Tabelle „Welche Daten gehen wohin“, Schalter
// „Nur lokal“ und der Stand der Einwilligung für Cloud-Modelle.
import Foundation
import SwiftUI
import TabyCore

/// Eine Zeile der Tabelle: wer, wohin (Host), welche Daten.
struct PrivacyFlow: Equatable, Identifiable {
  let feature: String
  let destination: String
  let data: String
  var id: String { feature + "|" + destination }
}

enum PrivacyLogic {
  /// Nur der Host, ohne Schema und Pfad (z. B. „openrouter.ai“).
  static func host(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "" }
    let full = t.contains("://") ? t : "https://" + t
    return URL(string: full)?.host ?? t
  }

  /// Die Zeilen aus dem Zustand; nur Dienste, die eingerichtet oder installiert sind.
  static func flows(_ state: AppState) -> [PrivacyFlow] {
    let s = state.settings
    let apple = TabySettings.appleIntelligenceModel
    var out: [PrivacyFlow] = []
    let chatTarget = s.llmModel == apple ? "Apple Intelligence (auf deinem Mac)"
      : LlmConnection.isLocalEndpoint(s.llmBaseUrl) ? "\(host(s.llmBaseUrl)) (dein Mac)"
      : host(s.llmBaseUrl).isEmpty ? "Kein Anbieter eingetragen" : host(s.llmBaseUrl)
    out.append(PrivacyFlow(feature: "Chat & Briefing", destination: chatTarget,
                           data: "Chattexte, Aufgaben, Termine"))
    out.append(PrivacyFlow(feature: "Diktat", destination: "Apple (Spracherkennung)",
                           data: "Deine Sprache; Audio kann an Apple gehen"))
    if state.notionTasksConnected || state.calendarSources.contains(where: { $0.kind == .notion }) {
      out.append(PrivacyFlow(feature: "Notion", destination: "api.notion.com",
                             data: "Aufgaben und Termine aus deinen Notion-Datenbanken"))
    }
    if state.messengerAccounts.contains(where: { $0.service == .slack }) {
      out.append(PrivacyFlow(feature: "Slack", destination: "slack.com",
                             data: "Nachrichten aus deinen Slack-Gesprächen"))
    }
    for account in state.messengerAccounts where account.service == .matrix {
      out.append(PrivacyFlow(feature: "Element", destination: host(account.server),
                             data: "Nachrichten aus deinen Matrix-Gesprächen"))
    }
    if state.mods.contains(where: { $0.manifest.permissions.contains("http:open-meteo.com") }) {
      out.append(PrivacyFlow(feature: "Wetter-Mod", destination: "open-meteo.com",
                             data: "Wohnort-Stadt für die Wetterabfrage"))
    }
    let update = s.updateSource.trimmingCharacters(in: .whitespacesAndNewlines)
    out.append(PrivacyFlow(feature: "Updates", destination: host(update.isEmpty ? AppUpdate.defaultSource : update),
                           data: "Nur die Abfrage nach neuen Versionen"))
    return out
  }

  /// Cloud-Modell: nicht Apple und kein Endpunkt auf diesem Mac.
  static func isCloud(_ s: TabySettings) -> Bool {
    s.llmModel != TabySettings.appleIntelligenceModel && !LlmConnection.isLocalEndpoint(s.llmBaseUrl)
  }

  /// „2026-10-01T09:00“ → „01.10.2026“.
  static func germanDate(_ iso: String) -> String {
    let p = LocalTime.datePart(iso).split(separator: "-")
    guard p.count == 3 else { return iso }
    return "\(p[2]).\(p[1]).\(p[0])"
  }
}

/// Der Abschnitt „Datenschutz“ in den Einstellungen; ändert die Werte im Formular (Autosave).
struct PrivacyCard: View {
  @Binding var form: TabySettings
  let state: AppState
  let onRevoke: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "tablecells", title: "Welche Daten gehen wohin")
        ForEach(PrivacyLogic.flows(state)) { flow in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(flow.feature).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
              Spacer(minLength: 8)
              Text(flow.destination).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.middle)
            }
            Text(flow.data).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 2)
        }
      }
      .tabyCard()

      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "lock.shield", title: "Nur lokal")
        PillToggle(title: "Nur lokal nutzen", isOn: $form.localOnly)
        Text("Lumi schickt dann keine Daten an Cloud-Modelle und ruft keine Internetseiten für Mods auf. "
          + "Die MCP-Brücke (Schnittstelle für andere KI-Programme) ist dann aus: Claude und andere Programme können keine Lumi-Daten lesen. "
          + "Ohne Apple Intelligence kann Lumi dann keine Antworten formulieren.")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .tabyCard()

      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "checkmark.seal", title: "Einwilligung")
        consentStatus
      }
      .tabyCard()
    }
  }

  @ViewBuilder private var consentStatus: some View {
    let host = PrivacyLogic.host(form.llmBaseUrl)
    if !PrivacyLogic.isCloud(form) {
      Text("Für dein Modell ist keine Einwilligung nötig.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
    } else if PrivacyGate.consent(form.cloudConsentAt).map({ $0.host == LlmConnection.host(of: form.llmBaseUrl) }) != true {
      Text("Noch keine Einwilligung. Lumi sendet nichts an \(host), bis du im Chat zustimmst.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      Text("Du hast am \(PrivacyLogic.germanDate(PrivacyGate.consent(form.cloudConsentAt)?.at ?? "")) zugestimmt, dass Lumi Chat-Nachrichten an \(host) schickt.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Einwilligung zurückziehen") {
        form.cloudConsentAt = ""
        onRevoke()
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
  }
}
