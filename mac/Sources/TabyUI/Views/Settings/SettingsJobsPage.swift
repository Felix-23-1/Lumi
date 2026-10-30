// Seite „Aufträge“ (erweitert): geplante Aufträge stoppen oder entfernen. Ohne Rückgängig, daher mit Bestätigung.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  var jobsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader(symbol: "clock.arrow.circlepath", title: "Aufträge", count: jobs.count)
      if jobs.isEmpty {
        Text("Keine. Im Chat z. B.: „Erinnere mich jeden Montag um 8 an den Wochenplan.“")
          .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
      }
      ForEach(jobs) { j in
        HoverRow { hover in
          HStack(spacing: 8) {
            StatusDot(color: j.enabled ? Theme.green : Theme.tertiary, size: 6)
            VStack(alignment: .leading, spacing: 1) {
              Text(j.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
              Text(SettingsLogic.ruleText(j.rule) + (j.mode == .readOnly ? " · nur lesen" : ""))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button(j.enabled ? "Stoppen" : "Entfernen") { pendingJob = j }
              .buttonStyle(PillButtonStyle(kind: hover ? .danger : .ghost, compact: true))
          }
        }
        .transition(Theme.rowTransition)
      }
    }
    .tabyCard()
  }

  /// Nach Bestätigung: Auftrag stoppen oder entfernen.
  func cancelJob(_ job: Job) {
    Task {
      let r = await model.services.cancelJob(job.id)
      model.react(.itemDeleted)
      await done(r.errorMessage, success: job.enabled ? "Auftrag gestoppt" : "Auftrag entfernt")
    }
  }
}
