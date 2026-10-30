// Welche Apple-/iCloud-Kalender Lumi liest. Nichts gewählt = alle; sonst nur die gewählten.
import SwiftUI
import TabyCore

enum AppleCalendarChoice {
  /// Neue Kennungen nach dem Umschalten von `id`. Sind danach alle gewählt, heißt das „alle“ (leer).
  static func toggled(_ id: String, current: [String], all: [String]) -> [String] {
    var set = current.isEmpty ? Set(all) : Set(current)
    if set.contains(id) { set.remove(id) } else { set.insert(id) }
    return set.count == all.count ? [] : all.filter(set.contains)
  }
}

struct AppleCalendarPicker: View {
  let source: CalendarSourceConfig
  let onChange: ([String: JSONValue]) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var calendars: [AppleCalendarInfo] = []

  private var chosen: [String] { source.config["calendarIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(chosen.isEmpty ? "Kalender: alle werden gelesen. Tippe auf einen, um nur bestimmte zu nehmen."
                          : "Kalender: nur die markierten werden gelesen.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      WrapLayout(spacing: 4) {
        ForEach(calendars) { c in
          ChoiceChip(text: c.account.isEmpty ? c.title : "\(c.title) · \(c.account)",
                     selected: chosen.isEmpty || chosen.contains(c.id)) { toggle(c) }
        }
      }
    }
    .padding(.leading, 32)
    .task { calendars = await model.services.appleCalendars() }
  }

  private func toggle(_ c: AppleCalendarInfo) {
    let ids = AppleCalendarChoice.toggled(c.id, current: chosen, all: calendars.map(\.id))
    var config = source.config
    config["calendarIds"] = ids.isEmpty ? nil : .array(ids.map { .string($0) })
    onChange(config)
  }
}
