// Geburtstag heute im Heute-Tab: anrufen, FaceTime oder die Nachricht vorbereiten.
// Die Links baut der Kern (ContactSearch.link); Anrufe und FaceTime öffnet das System.
import AppKit
import SwiftUI
import TabyCore

struct BirthdayRow: View {
  let card: ContactCard

  var body: some View {
    HStack(spacing: 8) {
      Text("🎂 Heute: \(card.name)")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let phone = card.phones.first {
        if let tel = ContactSearch.link(scheme: "tel", phone: phone) {
          Button("Anrufen") { NSWorkspace.shared.open(tel) }
        }
        if let facetime = ContactSearch.link(scheme: "facetime", phone: phone) {
          Button("FaceTime") { NSWorkspace.shared.open(facetime) }
        }
      }
      // Die Nachricht schreibst du selbst: der Name liegt danach in der Zwischenablage.
      Button("Nachricht") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.name, forType: .string)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .tabyCard(tint: Theme.amber)
  }
}
