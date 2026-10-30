// Aufgaben-Details: Notiztext der Aufgabe (speichert beim Verlassen des Feldes),
// verknüpfte Notizen (aufklappbar) und "+ Notiz". Dazu der Chip "Aufgabe" an Notizen.
import SwiftUI
import TabyCore

/// Kleiner Chip mit dem Titel der zugeordneten Aufgabe.
struct NoteTaskChip: View {
  let title: String

  var body: some View {
    Label(title, systemImage: "checkmark.circle")
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(Theme.blue)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(Theme.blue.opacity(0.14)))
      .accessibilityLabel("Aufgabe: \(title)")
  }
}

/// Aufgeklappter Bereich unter einer Aufgabenzeile.
struct TaskNotesDetail: View {
  let task: TabyTask
  let notes: [Note]
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot
  @State private var draft: String
  @State private var openNote: String?
  @FocusState private var focused: Bool

  init(task: TabyTask, notes: [Note], openNote: String? = nil) {
    self.task = task
    self.notes = notes
    _draft = State(initialValue: task.notes ?? "")
    _openNote = State(initialValue: openNote)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text("Notiz zur Aufgabe…").foregroundStyle(Theme.tertiary).padding(.leading, 5).padding(.top, 1)
            .allowsHitTesting(false)
        }
        if snapshot {
          Text(draft).foregroundStyle(Theme.text).padding(.leading, 5).padding(.top, 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
          TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .foregroundStyle(Theme.text)
            .frame(minHeight: 56)
        }
      }
      .font(.system(size: 13))
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.capsule))
      .onChange(of: focused) { _, isFocused in if !isFocused { saveDraft() } }
      .onChange(of: task.notes) { _, n in if !focused { draft = n ?? "" } }

      HStack {
        Text("Notizen")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.secondary)
        Spacer()
        Button(action: addNote) { Label("Notiz", systemImage: "plus") }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          .help("Neue Notiz zu dieser Aufgabe")
      }
      ForEach(notes) { note in
        LinkedNoteRow(note: note, open: openNote == note.id) {
          withAnimation(Theme.spring) { openNote = openNote == note.id ? nil : note.id }
        }
      }
    }
    .padding(.leading, 26)
    .padding(.bottom, 2)
  }

  /// Speichert den Notiztext, wenn er sich geändert hat (Feld verlassen).
  private func saveDraft() {
    guard draft != (task.notes ?? "") else { return }
    let text = draft
    Task {
      _ = await model.services.updateTask(task.id, TaskPatch(notes: text))
      await model.refresh()
    }
  }

  /// Legt eine Notiz an, die dieser Aufgabe zugeordnet ist.
  private func addNote() {
    Task {
      if case .ok(let note) = await model.services.addNote(title: task.title, content: "") {
        _ = await model.services.updateNote(note.id, NotePatch(taskId: task.id))
      }
      await model.refresh()
    }
  }
}

/// Verknüpfte Notiz in der Aufgabe: Titel und erste Zeilen, antippen klappt den Inhalt auf.
private struct LinkedNoteRow: View {
  let note: Note
  let open: Bool
  let onTap: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(TaskNotesLogic.displayTitle(note))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
      if !note.content.isEmpty {
        Text(TaskNotesLogic.preview(note.content, lines: open ? Int.max : 2))
          .font(.system(size: 11))
          .foregroundStyle(Theme.secondary)
          .lineLimit(open ? nil : 2)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
  }
}
