// Datenschutz: Protokoll der Werkzeug-Ausführungen (die letzten 200, neueste zuerst) und
// CSV-Export auf den Schreibtisch. Zeigt nur Werkzeug, Kurzbeschreibung und Kennzeichen, nie Inhalte.
import AppKit
import Foundation
import SwiftUI
import TabyCore

enum AuditLogic {
  /// „2026-10-16T13:16“ → „16.10. 13:16“.
  static func time(_ iso: String) -> String {
    let p = LocalTime.datePart(iso).split(separator: "-")
    guard p.count == 3 else { return iso }
    let clock = iso.split(separator: "T").last.map { String($0.prefix(5)) } ?? ""
    return "\(p[2]).\(p[1]). \(clock)"
  }
}

struct AuditCard: View {
  /// Zahlen wie in den Chat-Einstellungen; `0` gibt es hier nicht (Protokoll immer begrenzt).
  static let retentionChoices = [(1, "1 Tag"), (7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "365 Tage")]

  let services: TabyServices
  @Binding var retentionDays: Int
  @State private var collapsed = true
  @State private var entries: [AuditEntry] = []
  @State private var message: String?
  @State private var confirmingClear = false

  var body: some View {
    CollapsibleSection(symbol: "list.bullet.rectangle", title: "Protokoll", count: nil, collapsed: $collapsed) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Was Lumi ausgeführt hat: Werkzeug und Kurzbeschreibung, nie Texte oder Inhalte. Neueste zuerst.")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Löschen nach").font(.system(size: 13)).foregroundStyle(Theme.text)
          HStack(spacing: 4) {
            ForEach(Self.retentionChoices, id: \.0) { days, label in
              ChoiceChip(text: label, selected: retentionDays == days) { retentionDays = days }
            }
            Spacer(minLength: 0)
          }
          Text("Ältere Einträge löscht Lumi automatisch, einmal am Tag.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        HStack(spacing: 8) {
          Button("Exportieren") { export() }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(entries.isEmpty)
          Button("Jetzt löschen") { confirmingClear = true }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(entries.isEmpty)
        }
        if entries.isEmpty {
          Text("Noch keine Einträge.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } else {
          ForEach(entries) { entry in row(entry) }
        }
        if let message {
          Text(message).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
    }
    .tabyCard()
    .task { await reload() }
    .confirmationDialog("Gesamtes Protokoll löschen? Das lässt sich nicht rückgängig machen.",
                        isPresented: $confirmingClear, titleVisibility: .visible) {
      Button("Protokoll löschen", role: .destructive) { clear() }
      Button("Abbrechen", role: .cancel) {}
    }
  }

  private func row(_ e: AuditEntry) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(e.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        Spacer(minLength: 4)
        Text(AuditLogic.time(e.at)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
      }
      Text([e.actor, e.tool, e.confirmed ? "bestätigt" : nil, e.ok ? nil : "fehlgeschlagen"]
        .compactMap { $0 }.joined(separator: " · "))
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  private func reload() async {
    entries = await services.listAudit(limit: 200)
  }

  private func clear() {
    Task {
      let r = await services.clearAudit()
      message = r.isOk ? "Protokoll gelöscht." : (r.errorMessage ?? "Löschen hat nicht geklappt.")
      await reload()
    }
  }

  private func export() {
    Task {
      guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
        message = "Schreibtisch nicht gefunden."
        return
      }
      let all = await services.listAudit(limit: AuditRepository.maxRows)
      do {
        let url = try AuditExport.write(all, to: desktop)
        message = "\(all.count) Einträge nach \(url.lastPathComponent) auf dem Schreibtisch exportiert."
      } catch {
        message = "Export fehlgeschlagen: \(error.localizedDescription)"
      }
    }
  }
}
