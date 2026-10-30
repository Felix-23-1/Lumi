// Stand der Aufgabe in der Notizansicht: Chip mit Titel und Stand, Menü zum Ändern
// (Offen / In Bearbeitung / Info fehlt) und "Aufgabe erledigt".
import SwiftUI
import TabyCore

struct NoteTaskStatusBar: View {
  let task: TabyTask
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 6) {
      if task.done {
        Label("\(task.title) · Erledigt", systemImage: "checkmark.circle.fill")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Theme.green)
          .lineLimit(1)
      } else {
        Menu {
          ForEach(TaskStatus.allCases, id: \.self) { status in
            Button { setStatus(status) } label: {
              Label(status.title, systemImage: status == task.status ? "checkmark" : status.symbol)
            }
          }
        } label: {
          Label("\(task.title) · \(task.status.title)", systemImage: task.status.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.blue)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.blue.opacity(0.14)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Aufgabe: \(task.title), Stand \(task.status.title)")
        Spacer(minLength: 4)
        Button("Aufgabe erledigt") { complete() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Offen wird als leerer Wert gesetzt (Vertrag: "" = offen).
  private func setStatus(_ status: TaskStatus) {
    Task {
      _ = await model.services.updateTask(task.id, TaskPatch(status: status == .open ? "" : status.rawValue))
      await model.refresh()
    }
  }

  private func complete() {
    Task {
      _ = await model.services.completeTask(task.id)
      await model.refresh()
    }
  }
}
