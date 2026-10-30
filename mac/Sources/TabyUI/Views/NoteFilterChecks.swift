// Prüfungen für Notizen nach Kategorie (Arbeit/Privat), das Kennzeichen-Setzen und die Aufgaben-Auswahl
// zum Zuordnen (Suche, Filter, erledigte, Sortierung), dazu die Snapshots der Filterleiste und der Auswahl.
import AppKit
import Foundation
import SwiftUI
import TabyCore

enum NoteFilterChecks {
  private static let now = "2026-10-11T09:00"

  private static func tasks() -> [TabyTask] {
    [
      TabyTask(id: "a", title: "Steuer abgeben", due: "2026-10-20", createdAt: now, category: .arbeit, tags: ["Haus"]),
      TabyTask(id: "b", title: "Einkauf", createdAt: now),
      TabyTask(id: "c", title: "Alt", due: "2026-10-01", done: true, createdAt: now, category: .arbeit),
      TabyTask(id: "d", title: "Reise buchen", due: "2026-10-10", createdAt: now, category: .privat),
    ]
  }

  private static func note(_ id: String, tags: [String] = [], taskId: String? = nil) -> Note {
    Note(id: id, title: id, content: "", createdAt: now, updatedAt: now, taskId: taskId, tags: tags)
  }

  @MainActor private static func fixture() -> FakeServices {
    let fake = FakeServices(sample: false)
    fake.current.tasks = tasks()
    fake.current.notes = [
      note("Arbeitsnotiz", taskId: "a"),
      note("Einkaufsliste", tags: ["Privat"]),
      note("Ohne Kategorie", tags: ["Projekt"]),
    ]
    return fake
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Kategorie: Aufgabe gewinnt über Kennzeichen; ohne Aufgabe zählt das Kennzeichen") {
        let ts = tasks()
        try expectEqual(NoteCategoryLogic.category(of: note("n", tags: ["Privat"], taskId: "a"), tasks: ts), "arbeit",
                        "Aufgabe Arbeit schlägt Kennzeichen Privat")
        try expectEqual(NoteCategoryLogic.category(of: note("n", tags: ["Privat"], taskId: "missing"), tasks: ts), "privat",
                        "unbekannte Aufgabe: Kennzeichen gilt")
        try expectEqual(NoteCategoryLogic.category(of: note("n", tags: ["ARBEIT"]), tasks: ts), "arbeit",
                        "Groß/Klein egal")
        try expectEqual(NoteCategoryLogic.category(of: note("n", tags: ["Projekt"]), tasks: ts), nil)
        try expectEqual(NoteCategoryLogic.category(of: note("n", taskId: "b"), tasks: ts), nil,
                        "Aufgabe ohne Kategorie ist keine Kategorie")
      },
      CheckCase("Kategorie-Filter: Alle lässt alles durch, sonst nur die Kategorie") {
        let ts = tasks()
        let privat = note("n", tags: ["privat"])
        try expect(NoteCategoryLogic.matches(privat, filter: nil, tasks: ts), "Alle")
        try expect(NoteCategoryLogic.matches(privat, filter: "privat", tasks: ts), "Privat passt")
        try expect(!NoteCategoryLogic.matches(privat, filter: "arbeit", tasks: ts), "Arbeit passt nicht")
      },
      CheckCase("Als Arbeit/Privat kennzeichnen: setzt, entfernt und hält beide Kennzeichen getrennt") {
        try expectEqual(NoteCategoryLogic.setMark(["Privat", "x"], category: "arbeit", on: true), ["x", "Arbeit"],
                        "Arbeit ersetzt Privat")
        try expectEqual(NoteCategoryLogic.setMark(["ARBEIT", "x"], category: "arbeit", on: false), ["x"],
                        "entfernt unabhängig von Groß/Klein")
        try expectEqual(NoteCategoryLogic.setMark(["Arbeit"], category: "arbeit", on: true), ["Arbeit"],
                        "kein Doppelter")
        try expectEqual(NoteCategoryLogic.setMark(["x"], category: "privat", on: true), ["x", "Privat"])
      },
      CheckCase("Aufgaben-Auswahl: offene zuerst, nach Fälligkeit, ohne Fälligkeit zuletzt; erledigte nur mit Schalter") {
        let ts = tasks()
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "", category: nil, showDone: false, keep: nil).map(\.id),
                        ["d", "a", "b"])
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "", category: nil, showDone: true, keep: nil).map(\.id),
                        ["d", "a", "b", "c"], "erledigte hinten")
      },
      CheckCase("Aufgaben-Auswahl: Suche über Titel und Kennzeichen, Kategorie, aktuelle Zuordnung bleibt sichtbar") {
        let ts = tasks()
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "haus", category: nil, showDone: false, keep: nil).map(\.id),
                        ["a"], "Kennzeichen-Suche ohne Groß/Klein")
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "#STEUER", category: nil, showDone: false, keep: nil).map(\.id),
                        ["a"], "führendes # zählt nicht")
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "", category: "arbeit", showDone: false, keep: nil).map(\.id),
                        ["a"])
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "", category: "arbeit", showDone: false, keep: "b").map(\.id),
                        ["a", "b"], "aktuelle Zuordnung bleibt, auch wenn sie nicht passt")
        try expectEqual(NoteTaskPickLogic.rows(ts, query: "zzz", category: nil, showDone: true, keep: nil).map(\.id), [])
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-notes-category-filter", size: ViewSnapshots.size) {
        let fake = fixture()
        let model = AppModel(services: fake)
        return AnyView(NotesView(notes: fake.current.notes, tasks: fake.current.tasks)
          .environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true)
          .frame(maxHeight: .infinity, alignment: .top))
      },
      SnapshotSpec("view-notes-task-picker", size: ViewSnapshots.size) {
        AnyView(NoteTaskPicker(tasks: tasks(), current: "a", onPick: { _ in })
          .tabyNow(now).environment(\.tabySnapshot, true)
          .frame(maxHeight: .infinity, alignment: .top))
      },
    ]
  }
}
