// Gegliederte Anzeige einer Notiz-Gliederung in der Meeting-Karte: Abschnitte mit kleiner
// Überschrift (einklappbar), Unterabschnitte und Stichpunkte mit ruhigen Abständen.
import SwiftUI
import TabyCore

struct MeetingOutlineView: View {
  let sections: [MeetingOutline.Section]
  @State private var collapsed: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(sections) { section in
        VStack(alignment: .leading, spacing: 6) {
          if !section.heading.isEmpty {
            Button {
              if collapsed.contains(section.heading) { collapsed.remove(section.heading) } else { collapsed.insert(section.heading) }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: collapsed.contains(section.heading) ? "chevron.right" : "chevron.down")
                  .font(.system(size: 9, weight: .semibold))
                  .foregroundStyle(Theme.tertiary)
                  .frame(width: 10)
                Text(section.heading)
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          if !collapsed.contains(section.heading) {
            ForEach(Array(section.subs.enumerated()), id: \.offset) { _, sub in
              VStack(alignment: .leading, spacing: 4) {
                if !sub.heading.isEmpty && sub.heading != section.heading {
                  Text(sub.heading)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 2)
                }
                ForEach(Array(sub.items.enumerated()), id: \.offset) { _, item in
                  HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.tertiary)
                    Text(item)
                      .foregroundStyle(Theme.text)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  .font(.system(size: 12))
                }
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
