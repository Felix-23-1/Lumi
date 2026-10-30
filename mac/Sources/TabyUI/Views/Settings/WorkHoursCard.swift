// Arbeitszeiten je Wochentag (Mo…So). Gespeichert wird nur Gültiges; ein freier Tag ist "".
import SwiftUI
import TabyCore

struct WorkHoursCard: View {
  @Binding var hours: [String]
  private static let names = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "clock", title: "Arbeitszeiten")
      Text("Lumi plant Aufgaben nur in deiner Arbeitszeit und fragt das Briefing nur an Arbeitstagen.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(0..<7, id: \.self) { i in
        WorkDayRow(name: Self.names[i], hours: $hours[i])
      }
    }
    .tabyCard()
  }
}

private struct WorkDayRow: View {
  let name: String
  @Binding var hours: String
  @State private var working: Bool
  @State private var start: String
  @State private var end: String
  @State private var invalid = false
  @Environment(\.tabySnapshot) private var snapshot

  init(name: String, hours: Binding<String>) {
    self.name = name
    _hours = hours
    let parsed = WorkWeek.parse(hours.wrappedValue)
    _working = State(initialValue: parsed != nil)
    _start = State(initialValue: parsed?.start ?? "08:00")
    _end = State(initialValue: parsed?.end ?? "17:00")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(name)
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
          .frame(width: 26, alignment: .leading)
        Button { setWorking(!working) } label: {
          HStack(spacing: 6) {
            ZStack(alignment: working ? .trailing : .leading) {
              Capsule().fill(working ? Theme.green : Theme.capsuleHover).frame(width: 28, height: 16)
              Circle().fill(.white).frame(width: 12, height: 12).padding(2)
            }
            Text("arbeite ich").font(.system(size: 12)).foregroundStyle(Theme.text)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.snappy, value: working)
        if working {
          timeField($start)
          Text("–").foregroundStyle(Theme.tertiary)
          timeField($end)
        }
        Spacer(minLength: 0)
      }
      if invalid {
        Text("Bitte Uhrzeiten als HH:mm angeben, das Ende nach dem Beginn.")
          .font(.system(size: 11)).foregroundStyle(Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func timeField(_ text: Binding<String>) -> some View {
    ZStack {
      if snapshot {
        Text(text.wrappedValue)
      } else {
        TextField("HH:mm", text: text)
          .textFieldStyle(.plain)
          .onSubmit {
            if let s = SettingsLogic.normalizeTime(start) { start = s }
            if let e = SettingsLogic.normalizeTime(end) { end = e }
          }
      }
    }
    .font(.system(size: 13, design: .monospaced))
    .multilineTextAlignment(.center)
    .frame(width: 58)
    .padding(.vertical, 5)
    .background(Capsule().fill(Theme.capsule))
    .onChange(of: text.wrappedValue) { _, _ in validate() }
  }

  private func setWorking(_ on: Bool) {
    working = on
    if on {
      validate()
    } else {
      invalid = false
      hours = ""
    }
  }

  /// Speichert nur, wenn beide Zeiten gültig sind und das Ende nach dem Beginn liegt.
  private func validate() {
    guard working else { return }
    if let s = SettingsLogic.normalizeTime(start), let e = SettingsLogic.normalizeTime(end),
       let parsed = WorkWeek.parse("\(s)-\(e)") {
      invalid = false
      hours = "\(parsed.start)-\(parsed.end)"
    } else {
      invalid = true
    }
  }
}
