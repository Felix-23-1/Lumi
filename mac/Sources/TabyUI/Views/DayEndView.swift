// Tagesabschluss am Abend: "Das ist heute noch offen" – einzeln auf morgen
// schieben oder abhaken, oder alles auf einmal verschieben. Die Hülle zeigt
// diese Ansicht, solange `model.state?.dayEndPrompt == true`.
import SwiftUI
import TabyCore

enum DayEndLogic {
  /// Offene Aufgaben für den Abschluss: überfällige zuerst, dann heutige (ohne Doppelte, ohne erledigte).
  static func openTasks(_ o: Overview) -> [TabyTask] {
    var seen = Set<String>()
    return (o.overdueTasks + o.todayTasks).filter { !$0.done && seen.insert($0.id).inserted }
  }
}

public struct DayEndView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var busy: Set<String> = []
  @State private var answering = false
  @State private var appeared = false

  /// Nur für Vorschaubilder: Überblick direkt vorgeben (sonst aus `model.state`).
  var preview: Overview?

  public init() {}
  init(preview: Overview?) { self.preview = preview }

  private var tasks: [TabyTask] { DayEndLogic.openTasks(preview ?? model.state?.overview ?? .empty) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "moon.stars.fill")
          .font(.system(size: 19))
          .foregroundStyle(MascotMoodColor.rest)
          .symbolEffect(.bounce, value: appeared)
          .frame(width: 38, height: 38)
          .background(Circle().fill(MascotMoodColor.rest.opacity(0.15)))
        VStack(alignment: .leading, spacing: 3) {
          Text(tasks.isEmpty ? "Feierabend! Alles erledigt." : "Feierabend! Das ist heute noch offen:")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
          Text(tasks.isEmpty ? "Stark – für heute bleibt nichts liegen."
               : "Schieb es auf morgen oder hak es ab.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        Spacer(minLength: 0)
      }
      if !tasks.isEmpty {
        CappedScroll(maxHeight: 170) {
          VStack(spacing: 4) {
            ForEach(tasks) { t in
              row(t).transition(Theme.rowTransition)
            }
          }
        }
      }
      HStack(spacing: 8) {
        Button("Heute nicht mehr fragen") { answer(.skip) }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer()
        if !tasks.isEmpty {
          Button {
            answer(.later)
          } label: {
            HStack(spacing: 4) { Text("Später"); Text("30 Min").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary))
          Button("Alles auf morgen") { answer(.moveAllToTomorrow) }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: [])
        } else {
          Button("Fertig") { answer(.done) }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: [])
        }
      }
      .disabled(answering)
    }
    .animation(Theme.spring, value: tasks.map(\.id))
    .tabyCard(tint: MascotMoodColor.rest, padding: 14)
    .tabyPage()
    .onAppear { appeared = true }
  }

  private func row(_ t: TabyTask) -> some View {
    HoverRow { _ in
      HStack(spacing: 8) {
        Text(t.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
        if let chip = TaskLogic.dueChip(t.due, now: NowResolver.now(nowEnv)) { DueChipView(info: chip) }
        Spacer(minLength: 4)
        Button("Morgen") { act(t.id) { _ = await model.services.moveTasksToTomorrow([t.id]) } }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button {
          act(t.id) {
            _ = await model.services.completeTask(t.id)
            model.react(.taskCompleted)
          }
        } label: { Image(systemName: "checkmark") }
          .buttonStyle(RoundIconButtonStyle(size: 24, tint: Theme.green))
          .help("Erledigt")
      }
      .disabled(busy.contains(t.id))
    }
  }

  private func act(_ id: String, _ work: @escaping () async -> Void) {
    busy.insert(id)
    Task {
      await work()
      await model.refresh()
      busy.remove(id)
    }
  }

  private func answer(_ a: DayEndAnswer) {
    answering = true
    Task {
      await model.services.answerDayEnd(a)
      if a == .moveAllToTomorrow { model.react(.celebrate) }
      await model.refresh()
      answering = false
    }
  }
}

/// Farbe des Abends (ruhiges Violett, wie die Stimmung "schläfrig").
enum MascotMoodColor {
  static let rest = Color(red: 0.65, green: 0.55, blue: 0.98)
}
