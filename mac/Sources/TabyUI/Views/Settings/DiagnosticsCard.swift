// Einstellungen → Allgemein → Diagnose: Zip mit Protokoll, Version, Einstellungen ohne Geheimnisse
// und Datenbank-Statistik. Der Export läuft nur auf Knopfdruck.
import AppKit
import SwiftUI
import TabyCore

struct DiagnosticsCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var exporting = false
  @State private var path: String?
  @State private var message: (ok: Bool, text: String)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "stethoscope", title: "Diagnose", count: nil)
      Text("Protokoll, Version und Einstellungen ohne Geheimnisse – nie Schlüssel oder Nachrichtentexte.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      HStack(spacing: 8) {
        Button("Diagnose exportieren") { export() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(exporting)
        if let path {
          Button("Im Finder zeigen") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
      }
      if let path {
        Text(path)
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .lineLimit(2).textSelection(.enabled)
      }
      if let message {
        Banner(symbol: message.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", text: message.text,
               tint: message.ok ? Theme.green : Theme.red)
      }
    }
    .tabyCard()
  }

  private func export() {
    exporting = true
    message = nil
    Task {
      let result = await model.services.exportDiagnostics(to: nil)
      exporting = false
      if let exported = result.value {
        path = exported
        message = (true, "Diagnose gespeichert.")
      } else {
        message = (false, result.errorMessage ?? "Diagnose konnte nicht erstellt werden.")
      }
    }
  }
}
