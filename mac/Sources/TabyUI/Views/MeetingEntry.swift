// Fester Einstieg in Meeting-Vorbereitung und Mitschrift auf „Heute“: der laufende oder
// nächste Termin mit Uhrzeit, dazu „Meeting mitschreiben“ für Gespräche ohne Termin.
// Die Karte aus dem Kalender-Takt (10 Minuten vorher) bleibt daneben bestehen.
import SwiftUI
import TabyCore

enum MeetingEntryLogic {
  /// Laufender oder nächster Termin mit Uhrzeit heute; `now` und `start` sind lokale ISO-Strings.
  static func target(events: [CalendarEvent], now: String) -> CalendarEvent? {
    events.filter { !$0.allDay && $0.start.count >= 16 && ($0.end ?? $0.start) >= now }
      .min { $0.start < $1.start }
  }

  static func brief(for e: CalendarEvent) -> MeetingBrief {
    MeetingBrief(id: MeetingCompanion.key(e), phase: .upcoming, title: e.title, start: e.start, end: e.end,
                 link: MeetingCompanion.extractLink(e.notes))
  }

  /// Gespräch ohne Termin; der Kern erkennt den Schlüssel am Präfix „adhoc|“.
  static func adhocBrief(now: String) -> MeetingBrief {
    let start = String(now.prefix(16))
    return MeetingBrief(id: "adhoc|\(start)", phase: .upcoming, title: "Gespräch \(start.suffix(5))", start: start)
  }
}

struct MeetingEntrySection: View {
  let events: [CalendarEvent]
  let now: String
  @EnvironmentObject private var model: AppModel
  @State private var open: MeetingBrief?
  @State private var listenFirst = false

  /// Ohne Termin und ohne offene Karte nur eine schmale Zeile – keine eigene Überschrift mit Karte.
  var body: some View {
    let target = MeetingEntryLogic.target(events: events, now: now)
    if open == nil && target == nil {
      Button {
        listenFirst = true
        open = MeetingEntryLogic.adhocBrief(now: now)
      } label: {
        Label("Meeting mitschreiben (Aufnahme als Text)", systemImage: "record.circle")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
          .padding(.horizontal, 4)
      }
      .buttonStyle(.plain)
      .help("Lokal, nur Text, nach Zustimmung aller")
    } else {
      card(target)
    }
  }

  private func card(_ target: CalendarEvent?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader(symbol: "person.2.wave.2", title: "Meeting").padding(.horizontal, 4)
      if let open {
        MeetingCardView(meeting: open, saved: nil, onSaved: { _ in }, onDone: { self.open = nil },
                        listenOpen: listenFirst)
          .id(open.id)
          .tabyCard(padding: 12)
      } else {
        HStack(spacing: 4) {
          if let e = target {
            Button {
              listenFirst = false
              open = MeetingEntryLogic.brief(for: e)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 1) {
                  Text(e.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                  Text("\(CalendarLogic.timeRange(e)) · vorbereiten")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          Button {
            listenFirst = true
            open = MeetingEntryLogic.adhocBrief(now: now)
          } label: { Image(systemName: "record.circle") }
            .buttonStyle(RoundIconButtonStyle(size: 28, tint: Theme.secondary))
            .help("Meeting mitschreiben (Aufnahme als Text, lokal, nach Zustimmung aller)")
            .accessibilityLabel("Meeting mitschreiben")
        }
        .tabyCard(padding: 10)
      }
    }
  }
}
