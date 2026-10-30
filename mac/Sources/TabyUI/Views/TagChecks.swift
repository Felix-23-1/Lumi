// Prüfungen der Kennzeichen: Sammeln und Zählen, Vereinigung mit Notiz-Kennzeichen, Gruppierung,
// Titel-Hashtags, Filter mit mehreren Kennzeichen; Snapshots der gefilterten und gruppierten Aufgaben
// sowie der Notizen mit Chips.
import SwiftUI
import TabyCore

enum TagChecks {
  private static let now = "2026-10-11T09:00"

  static func task(_ id: String, _ title: String, tags: [String] = [], due: String? = nil,
                   status: TaskStatus = .open) -> TabyTask {
    TabyTask(id: id, title: title, due: due, createdAt: "2026-10-01T08:00", status: status, tags: tags)
  }

  /// Aufgaben für das Ansicht-Menü: mit Ständen, damit Stand- und Kennzeichen-Filter zusammen zu sehen sind.
  static var viewSample: [TabyTask] {
    [
      task("s1", "Angebot prüfen", tags: ["arbeit", "kunde"], due: "2026-10-14", status: .inProgress),
      task("s2", "Steuerunterlagen", tags: ["privat"], due: "2026-10-12", status: .needsInfo),
      task("s3", "Bericht schreiben", tags: ["Arbeit"]),
      task("s4", "Einkauf"),
    ]
  }

  static func note(_ id: String, _ title: String, tags: [String] = [], taskId: String? = nil) -> Note {
    Note(id: id, title: title, content: "", createdAt: now, updatedAt: now, taskId: taskId, tags: tags)
  }

  static var sample: [TabyTask] {
    [
      task("s1", "Angebot prüfen", tags: ["arbeit", "kunde"], due: "2026-10-14"),
      task("s2", "Steuerunterlagen", tags: ["privat"], due: "2026-10-12"),
      task("s3", "Bericht schreiben", tags: ["Arbeit"]),
      task("s4", "Einkauf"),
    ]
  }

  static var sampleNotes: [Note] {
    [
      note("n1", "Ideen Kunde", tags: ["Ideen"], taskId: "s1"),
      note("n2", "Belege", tags: ["privat", "steuer"]),
      note("n3", "Besprechung", tags: ["arbeit"]),
    ]
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Kennzeichen sammeln: Groß/Klein zählt zusammen, je Gegenstand einmal, häufigste zuerst") {
        let tasks = [
          task("a", "A", tags: ["arbeit", "privat"]),
          task("b", "B", tags: ["Arbeit", "arbeit"]),
        ]
        let notes = [note("n", "N", tags: ["arbeit", "ideen"])]
        let counted = TagLogic.allTags(tasks: tasks, notes: notes).map { "\($0.name):\($0.count)" }
        try expectEqual(counted, ["arbeit:3", "ideen:1", "privat:1"])
      },
      CheckCase("Kennzeichen sammeln: ohne Aufgaben und Notizen keine Liste") {
        try expectEqual(TagLogic.allTags(tasks: [], notes: []).isEmpty, true)
      },
      CheckCase("Vereinigung: eigene zuerst, dann die verknüpfter Notizen ohne Doppelte; freie Notiz zählt nicht") {
        let t = task("t", "Angebot", tags: ["privat"])
        let notes = [
          note("n1", "Verknüpft", tags: ["arbeit", "Privat"], taskId: "t"),
          note("n2", "Frei", tags: ["x"]),
        ]
        try expectEqual(TagLogic.taskTags(t, notes: notes), ["privat", "arbeit"])
        try expectEqual(TagLogic.ownAndInherited(t, notes: notes).inherited, ["arbeit"])
      },
      CheckCase("Gruppierung: Aufgabe steht unter jedem ihrer Kennzeichen, ohne Kennzeichen zuletzt") {
        let tasks = [
          task("a", "A", tags: ["arbeit"]),
          task("b", "B", tags: ["arbeit", "privat"]),
          task("c", "C"),
        ]
        let groups = TagLogic.groups(tasks, notes: [])
        try expectEqual(groups.map { $0.name }, ["#arbeit", "#privat", "Ohne Kennzeichen"])
        try expectEqual(groups[0].tasks.map(\.id), ["a", "b"])
        try expectEqual(groups[1].tasks.map(\.id), ["b"])
        try expectEqual(groups[2].tasks.map(\.id), ["c"])
      },
      CheckCase("Gruppierung: geerbte Kennzeichen zählen, Aufgabe ohne eigene Kennzeichen ist nicht „ohne“") {
        let tasks = [task("a", "A")]
        let groups = TagLogic.groups(tasks, notes: [note("n", "N", tags: ["ideen"], taskId: "a")])
        try expectEqual(groups.map { $0.name }, ["#ideen"])
      },
      CheckCase("Titel-Hashtags: #wort wird Kennzeichen und fällt aus dem Titel, Umlaute gelten") {
        let r = TagLogic.extractHashtags(from: "Angebot #Büro prüfen")
        try expectEqual(r.title, "Angebot prüfen")
        try expectEqual(r.tags, ["Büro"])
        let g = TagLogic.extractHashtags(from: "Büro #Größe")
        try expectEqual(g.title, "Büro")
        try expectEqual(g.tags, ["Größe"])
      },
      CheckCase("Titel-Hashtags: #a#b ergibt zwei Kennzeichen, C# und #- bleiben Text") {
        let r = TagLogic.extractHashtags(from: "Lesen #a#b Ende")
        try expectEqual(r.tags, ["a", "b"])
        try expectEqual(r.title, "Lesen Ende")
        try expectEqual(TagLogic.extractHashtags(from: "C#-Kurs").title, "C#-Kurs")
        try expectEqual(TagLogic.extractHashtags(from: "C#-Kurs").tags.isEmpty, true)
        try expectEqual(TagLogic.extractHashtags(from: "Nur #- Text").tags.isEmpty, true)
      },
      CheckCase("Titel-Hashtags: nur „#“ bleibt; wäre der Titel leer, bleibt alles wie eingegeben") {
        let only = TagLogic.extractHashtags(from: "#")
        try expectEqual(only.title, "#")
        try expectEqual(only.tags.isEmpty, true)
        let empty = TagLogic.extractHashtags(from: "#arbeit")
        try expectEqual(empty.title, "#arbeit")
        try expectEqual(empty.tags.isEmpty, true)
      },
      CheckCase("Filter: mehrere Kennzeichen wirken zusammen (alle müssen passen), ohne Auswahl alles") {
        let tasks = sample
        try expectEqual(TagLogic.filter(tasks, selected: [], notes: sampleNotes).count, 4)
        try expectEqual(TagLogic.filter(tasks, selected: ["arbeit"], notes: sampleNotes).map(\.id), ["s1", "s3"])
        try expectEqual(TagLogic.filter(tasks, selected: ["ARBEIT", "kunde"], notes: []).map(\.id), ["s1"])
        try expectEqual(TagLogic.filter(tasks, selected: ["arbeit", "privat"], notes: []).isEmpty, true)
      },
      CheckCase("Filter: geerbtes Kennzeichen aus einer verknüpften Notiz findet die Aufgabe") {
        let hit = TagLogic.filter(sample, selected: ["ideen"], notes: sampleNotes).map(\.id)
        try expectEqual(hit, ["s1"])
      },
      CheckCase("Ansicht-Menü: Zähler je Kennzeichen über Aufgaben und Notizen, je Gegenstand einmal") {
        let counted = TagLogic.allTags(tasks: sample, notes: sampleNotes).map { "\($0.name):\($0.count)" }
        try expectEqual(counted.first, "arbeit:3")
        try expectEqual(counted.contains("privat:2"), true)
      },
      CheckCase("Kennzeichen wählen und entfernen: Groß/Klein egal, andere bleiben") {
        try expectEqual(TagLogic.contains(["arbeit", "kunde"], name: "ARBEIT"), true)
        try expectEqual(TagLogic.contains(["arbeit"], name: "kunde"), false)
        try expectEqual(TagLogic.removing("Arbeit", from: ["arbeit", "kunde"]), ["kunde"])
        try expectEqual(TagLogic.removing("nichtda", from: ["arbeit"]), ["arbeit"])
      },
      CheckCase("Ansicht-Filter kombiniert: Stand und Kennzeichen zusammen, beide müssen passen") {
        let byTag = TagLogic.filter(viewSample, selected: ["arbeit"], notes: [])
        try expectEqual(TaskStatusLogic.filter(byTag, statuses: [.inProgress]).map(\.id), ["s1"])
        try expectEqual(TaskStatusLogic.filter(byTag, statuses: [.needsInfo]).isEmpty, true)
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-tasks-tags-grouped", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = sample
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: sample, notes: sampleNotes, expandedId: "s1", groupedByTag: true).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-tags-filtered", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = sample
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: sample, notes: sampleNotes, groupedByTag: true, selectedTags: ["arbeit"]).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-list", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = viewSample
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: viewSample, notes: sampleNotes).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-list-filtered", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = viewSample
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: viewSample, notes: sampleNotes, selectedTags: ["arbeit"],
                              statusFilter: [.inProgress]).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-menu-open", size: CGSize(width: TabLayout.contentWidth, height: 640)) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = viewSample
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: viewSample, notes: sampleNotes, selectedTags: ["arbeit"],
                              statusFilter: [.inProgress], optionsOpen: true).tabyPage(), model)
      },
      SnapshotSpec("view-notes-tags", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.notes = sampleNotes
        let model = AppModel(services: fake)
        return wrap(NotesView(notes: sampleNotes, expanded: "n2", tasks: sample).tabyPage(), model)
      },
    ]
  }

  static let size = CGSize(width: TabLayout.contentWidth, height: 420)

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true))
  }
}
