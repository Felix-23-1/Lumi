// Bestätigungskarten: das Modell möchte etwas löschen oder einen Auftrag
// stoppen – erst der Klick auf "Löschen" führt es aus (Schutz gegen
// Prompt-Injection über Kalender-/Notiz-Inhalte).
import SwiftUI
import TabyCore

struct ConfirmationCards: View {
  let pending: [PendingConfirmation]
  @EnvironmentObject private var model: AppModel
  @State private var busy: Set<String> = []
  @State private var expanded: Set<String> = []
  @Environment(\.tabySnapshot) private var snapshot
  var showAllDetail = false

  var body: some View {
    VStack(spacing: 8) {
      ForEach(pending) { p in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
            Text(Self.title(p)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
          }
          Text(p.summary).font(.system(size: 13)).foregroundStyle(Theme.secondary)
          if let detail = p.detail, !detail.isEmpty {
            Button {
              if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) }
            } label: {
              Label(expanded.contains(p.id) ? "Ausblenden" : "Alles anzeigen",
                    systemImage: expanded.contains(p.id) ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            if showAllDetail || expanded.contains(p.id) {
              Text(Self.plainLine(p))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
              detailText(detail)
              .padding(8)
              .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.capsule))
              Text("Geheimnisse sind nur in der Anzeige verborgen; ausgeführt wird der Originaltext.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
          }
          HStack(spacing: 8) {
            Spacer()
            Button("Ablehnen") { resolve(p, confirm: false) }
              .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            Button(Self.confirmLabel(p)) { resolve(p, confirm: true) }
              .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          }
          .disabled(busy.contains(p.id))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.amber.opacity(0.35), lineWidth: 1))
        .transition(Theme.rowTransition)
      }
    }
    .animation(Theme.spring, value: pending)
  }

  /// Vollständiger Text, monospaced und scrollbar (im Snapshot ohne ScrollView, die dort nicht gezeichnet wird).
  @ViewBuilder private func detailText(_ detail: String) -> some View {
    let text = Text(detail)
      .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .textSelection(.enabled)
    if snapshot {
      text.frame(height: 160, alignment: .top).clipped()
    } else {
      ScrollView(.vertical) { text }.frame(height: 160)
    }
  }

  /// Wortlaut je Werkzeug: nichts wird ohne Name als „löschen“ angezeigt, unbekannte Werkzeuge bleiben neutral.
  static func title(_ p: PendingConfirmation) -> String {
    switch ConfirmationKind(tool: p.tool) {
    case .delete: "\(ConfirmationKind.noun(p.tool) ?? "Eintrag") löschen?"
    case .create: "\(ConfirmationKind.noun(p.tool) ?? "Eintrag") anlegen?"
    case .send: "\(ConfirmationKind.noun(p.tool) ?? "Nachricht") senden?"
    case .stop: "Auftrag stoppen?"
    case .mod: "Lumi möchte einen Mod ausführen"
    case .other: "Lumi möchte eine Aktion ausführen"
    }
  }

  static func confirmLabel(_ p: PendingConfirmation) -> String {
    switch ConfirmationKind(tool: p.tool) {
    case .delete: "Löschen"
    case .create: "Anlegen"
    case .send: "Senden"
    case .stop: "Stoppen"
    case .mod, .other: "Ausführen"
    }
  }

  /// Klartext-Zeile über dem rohen JSON: Werkzeugname lesbar, dazu bis zu drei einfache Felder.
  static func plainLine(_ p: PendingConfirmation) -> String {
    var name = p.tool.hasPrefix("mcp_") ? String(p.tool.dropFirst(4)) : p.tool
    name = name.replacingOccurrences(of: "_", with: " ")
    let fields = keyFields(p.detail)
    return fields.isEmpty ? "Werkzeug: \(name)" : "Werkzeug: \(name) – \(fields.joined(separator: ", "))"
  }

  /// Einfache Felder (Text oder Zahl) aus den Argumenten, wichtige Namen zuerst.
  static func keyFields(_ detail: String?) -> [String] {
    guard let detail, let data = detail.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let args = (json["arguments"] as? [String: Any]) ?? json
    let preferred = ["title", "name", "summary", "content", "text", "due", "date", "start", "end"]
    let keys = args.keys.filter { key in
      key != "tool" && (args[key] is String || args[key] is NSNumber)
    }.sorted { a, b in
      let ia = preferred.firstIndex(of: a) ?? Int.max
      let ib = preferred.firstIndex(of: b) ?? Int.max
      return ia == ib ? a < b : ia < ib
    }
    return keys.prefix(3).map { key in "\(key): \(String(String(describing: args[key] ?? "").prefix(60)))" }
  }

  private func resolve(_ p: PendingConfirmation, confirm: Bool) {
    busy.insert(p.id)
    Task {
      if confirm {
        let r = await model.services.confirmAction(p.id)
        if r.isOk { model.react(.itemDeleted) } else { model.react(.failed(r.errorMessage ?? "")) }
      } else {
        await model.services.rejectAction(p.id)
      }
      await model.refresh()
      busy.remove(p.id)
    }
  }
}

/// Art einer Bestätigung, aus den Wortteilen des Werkzeugnamens abgeleitet (reine Logik).
enum ConfirmationKind: Equatable {
  case delete, create, send, stop, mod, other

  init(tool: String) {
    let parts = Self.parts(tool)
    if tool.hasPrefix("mod_") { self = .mod }
    else if parts.contains(where: { ["cancel", "stop", "stoppen", "abbrechen"].contains($0) }) { self = .stop }
    else if parts.contains(where: { ["send", "senden"].contains($0) }) { self = .send }
    else if parts.contains(where: { ["delete", "remove", "löschen", "loeschen", "entfernen"].contains($0) }) { self = .delete }
    else if parts.contains(where: { ["create", "add", "anlegen", "insert"].contains($0) }) { self = .create }
    else { self = .other }
  }

  /// Deutscher Gegenstand aus dem Werkzeugnamen, z. B. „delete_task“ → „Aufgabe“.
  static func noun(_ tool: String) -> String? {
    let nouns = ["task": "Aufgabe", "note": "Notiz", "event": "Termin", "habit": "Gewohnheit",
                 "message": "Nachricht", "page": "Seite", "mail": "E-Mail", "draft": "Entwurf", "job": "Auftrag"]
    return parts(tool).lazy.compactMap { nouns[$0] }.first
  }

  private static func parts(_ tool: String) -> [String] {
    tool.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
  }
}
