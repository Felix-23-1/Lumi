// Tagesstart-Frage (BAUPLAN 9, Szenario B): Ja / Später / Heute nicht.
import SwiftUI
import TabyCore

public struct DayStartView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var answering = false
  @State private var appeared = false

  public init() {}

  public var body: some View {
    let o = model.state?.overview ?? .empty
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "sun.horizon.fill")
          .font(.system(size: 20))
          .foregroundStyle(Theme.amber)
          .symbolEffect(.bounce, value: appeared)
          .frame(width: 38, height: 38)
          .background(Circle().fill(Theme.amber.opacity(0.15)))
        VStack(alignment: .leading, spacing: 4) {
          Text("Guten Morgen! Soll ich dein Briefing für heute vorbereiten?")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
          Text(summary(o))
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Spacer()
        Button("Heute nicht") { answer(.skip) }
          .buttonStyle(PillButtonStyle(kind: .ghost))
          .keyboardShortcut(.escape, modifiers: [])
        Button {
          answer(.later)
        } label: {
          HStack(spacing: 4) { Text("Später"); Text("30 Min").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
        Button("Ja") { answer(.yes) }
          .buttonStyle(PillButtonStyle(kind: .primary))
          .keyboardShortcut(.return, modifiers: [])
      }
      .disabled(answering)
    }
    .tabyCard(tint: Theme.amber, padding: 14)
    .tabyPage()
    .onAppear { appeared = true }
  }

  private func summary(_ o: Overview) -> String {
    var parts: [String] = []
    if !o.eventsToday.isEmpty { parts.append(TodayLogic.count(o.eventsToday.count, "Termin", "Termine")) }
    let tasks = o.todayTasks.count + o.overdueTasks.count
    if tasks > 0 { parts.append(TodayLogic.count(tasks, "Aufgabe", "Aufgaben")) }
    if !o.missed.isEmpty { parts.append("\(o.missed.count) verpasst") }
    return parts.isEmpty ? "Heute ist noch nichts eingetragen." : "Heute: " + parts.joined(separator: " · ")
  }

  private func answer(_ a: DayStartAnswer) {
    answering = true
    Task {
      await model.services.answerDayStart(a)
      await model.refresh()
      if a == .yes { model.react(.celebrate) }
      answering = false
    }
  }
}
