// Prüfungen und Snapshot für Notizen in Aufgaben: Hilfslogik (TaskNotesLogic), Zuordnung
// über die Aktion (gegen FakeServices) und der aufgeklappte Aufgaben-Bereich mit Notizen.
import Foundation
import SwiftUI
import TabyCore

enum TaskNotesChecks {
  private static let now = "2026-10-11T09:00"

  @MainActor private static func fixture() -> FakeServices {
    let fake = FakeServices(sample: false)
    fake.current.tasks = [
      TabyTask(id: "n1", title: "Steuererklärung abgeben", notes: "Belege aus dem Ordner Steuer, Frist 31.07.",
               due: "2026-10-14", createdAt: "2026-10-01T08:00"),
      TabyTask(id: "n2", title: "Zahnarzt anrufen", due: "2026-10-15T09:00", createdAt: "2026-10-11T08:00"),
      TabyTask(id: "n3", title: "Alte Aufgabe", done: true, doneAt: "2026-10-05T10:00", createdAt: "2026-10-01T08:00"),
    ]
    fake.current.notes = [
      Note(id: "m1", title: "Belege", content: "Kontoauszüge Q2\nRechnung Handwerker\n☐ Quittung Fahrrad",
           createdAt: "2026-10-10T08:00", updatedAt: "2026-10-10T08:00", taskId: "n1"),
      Note(id: "m2", title: "Fristen", content: "Ende Juli", createdAt: "2026-10-09T08:00",
           updatedAt: "2026-10-09T08:00", taskId: "n1"),
      Note(id: "m3", title: "Zahnarzt Termin", content: "", createdAt: "2026-10-08T08:00",
           updatedAt: "2026-10-08T08:00"),
    ]
    return fake
  }

  private static func tasks() -> [TabyTask] {
    [
      TabyTask(id: "n1", title: "Steuererklärung abgeben", due: "2026-10-14", createdAt: "2026-10-01T08:00"),
      TabyTask(id: "n2", title: "Zahnarzt anrufen", createdAt: "2026-10-11T08:00"),
      TabyTask(id: "n3", title: "Alte Aufgabe", done: true, doneAt: "2026-10-05T10:00", createdAt: "2026-10-01T08:00"),
    ]
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Aufgabe: Notizen nach Aufgaben-ID filtern, Reihenfolge bleibt") {
        let notes = fixture().current.notes
        try expectEqual(TaskNotesLogic.notes(of: "n1", in: notes).map(\.id), ["m1", "m2"])
        try expectEqual(TaskNotesLogic.notes(of: "n2", in: notes).map(\.id), [])
        try expectEqual(TaskNotesLogic.notes(of: "gibt-es-nicht", in: notes).map(\.id), [])
      },
      CheckCase("Aufgabe: Titel der zugeordneten Aufgabe; ohne Zuordnung oder fehlende Aufgabe nil") {
        let all = tasks()
        try expectEqual(TaskNotesLogic.taskTitle(for: fixture().current.notes[0], in: all), "Steuererklärung abgeben")
        try expectEqual(TaskNotesLogic.taskTitle(for: fixture().current.notes[2], in: all), nil)
        let orphan = Note(id: "o", title: "x", content: "", createdAt: now, updatedAt: now, taskId: "weg")
        try expectEqual(TaskNotesLogic.taskTitle(for: orphan, in: all), nil)
      },
      CheckCase("Aufgabe: Zuordnen-Menü bietet nur offene Aufgaben") {
        try expectEqual(TaskNotesLogic.assignable(tasks()).map(\.id), ["n1", "n2"])
      },
      CheckCase("Aufgabe: Vorschau zeigt höchstens zwei Zeilen, Checkboxen als ☐/☑") {
        let text = "Erste\n\nZweite\nDritte"
        try expectEqual(TaskNotesLogic.preview(text), "Erste\nZweite")
        try expectEqual(TaskNotesLogic.preview("- [ ] Milch\n- [x] Brot", lines: 5), "☐ Milch\n☑ Brot")
      },
      CheckCase("Aufgabe: Notiz ohne Titel bekommt Platzhalter") {
        let n = Note(id: "p", title: "  ", content: "", createdAt: now, updatedAt: now)
        try expectEqual(TaskNotesLogic.displayTitle(n), "Ohne Titel")
      },
      CheckCase("Aktion setNoteTask: Zuordnen und Lösen über die Dienste") {
        let fake = fixture()
        let model = AppModel(services: fake)
        _ = await ViewActions.setNoteTask(model, id: "m3", taskId: "n2")
        try expectEqual(fake.current.notes.first { $0.id == "m3" }?.taskId, "n2")
        _ = await ViewActions.setNoteTask(model, id: "m3", taskId: "")
        try expectEqual(fake.current.notes.first { $0.id == "m3" }?.taskId, nil)
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-tasks-expanded-notes", size: ViewSnapshots.size) {
        let fake = fixture()
        let model = AppModel(services: fake)
        return AnyView(TasksView(tasks: fake.current.tasks, notes: fake.current.notes, expandedId: "n1")
          .environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true)
          .frame(maxHeight: .infinity, alignment: .top))
      },
    ]
  }
}
