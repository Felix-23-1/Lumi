// Seite „Netzwerk“ (erweitert): Netzwerk-Werkzeuge und Wächter.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Netzwerk (Paket 6)

  var networkSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "network", title: "Netzwerk")
      PillToggle(title: "Netzwerk-Werkzeuge einschalten", isOn: $form.networkToolsEnabled)
      Text("Der Reiter erscheint erst danach. Nichts läuft im Hintergrund, solange es aus ist.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      PillToggle(title: "Wächter: neue Geräte und Internet-Ausfälle melden", isOn: $form.networkWatch)
        .disabled(!form.networkToolsEnabled)
        .opacity(form.networkToolsEnabled ? 1 : 0.4)
      VStack(alignment: .leading, spacing: 4) {
        Text("Ins Internet geht nur auf Knopfdruck:")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
        Text("• Speedtest → Apple (networkQuality)\n• Öffentliche IP → ipify.org\n• DNS-Abfrage → dein DNS-Server")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Ping, Portprüfung und Geräte bleiben in deinem Netz. Gerätedaten bleiben lokal auf dem Mac.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .tabyCard()
  }

}
