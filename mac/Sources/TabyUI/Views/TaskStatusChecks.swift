// Prüfungen des Bearbeitungsstandes: Gruppierung nach Stand (Reihenfolge, erledigte, leer),
// Wert für den Kern, und Snapshots der gruppierten Liste und der Heute-Liste mit Chips.
import SwiftUI
import TabyCore

enum TaskStatusChecks {
  static func task(_ id: String, _ title: String, due: String? = nil, done: Bool = false,
                   status: TaskStatus = .open) -> TabyTask {
    TabyTask(id: id, title: title, due: due, done: done, createdAt: "2026-10-01T08:00", status: status)
  }

  static var sample: [TabyTask] {
    [
      task("s1", "Angebot prüfen", due: "2026-10-14", status: .inProgress),
      task("s2", "Rechnung Nr. 4711", due: "2026-10-12", status: .needsInfo),
      task("s3", "Steuerunterlagen", due: "2026-10-11", status: .open),
      task("s4", "Bericht schreiben", status: .inProgress),
      task("s5", "Einkauf", status: .open),
      task("s6", "Alt erledigt", done: true, status: .inProgress),
    ]
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Stand-Gruppen: In Bearbeitung, dann Info fehlt, dann Offen; erledigte fehlen") {
        let names = TaskStatusLogic.groups(sample).map(\.0)
        try expectEqual(names, [.inProgress, .needsInfo, .open])
        let ids = TaskStatusLogic.groups(sample).flatMap { $0.1.map(\.id) }
        try expect(!ids.contains("s6"), "erledigte Aufgabe darf nicht in einem Stand-Abschnitt stehen")
      },
      CheckCase("Stand-Gruppen: leere Stände entfallen, keine Aufgaben ergibt keine Abschnitte") {
        let only = [task("a", "Nur offen", status: .open)]
        try expectEqual(TaskStatusLogic.groups(only).map(\.0), [.open])
        try expectEqual(TaskStatusLogic.groups([]).isEmpty, true)
        try expectEqual(TaskStatusLogic.groups([task("d", "Erledigt", done: true, status: .needsInfo)]).isEmpty, true)
      },
      CheckCase("Stand-Gruppen: innerhalb eines Standes Fälligkeit aufsteigend, ohne Fälligkeit zuletzt, dann Titel") {
        let open = [
          task("z", "Zebra", status: .open),
          task("m", "Mitte", due: "2026-10-12", status: .open),
          task("f", "Früh", due: "2026-10-11T08:00", status: .open),
          task("l", "Apfel", status: .open),
          task("e", "Leer", due: "", status: .open),
          task("a", "Aaa", status: .open),
        ]
        let titles = TaskStatusLogic.groups(open).first?.1.map(\.title) ?? []
        try expectEqual(titles, ["Früh", "Mitte", "Aaa", "Apfel", "Leer", "Zebra"])
      },
      CheckCase("Stand-Wert für den Kern: offen ist leer, die anderen sind der rawValue") {
        try expectEqual(TaskStatusLogic.patchValue(.open), "")
        try expectEqual(TaskStatusLogic.patchValue(.inProgress), "inProgress")
        try expectEqual(TaskStatusLogic.patchValue(.needsInfo), "needsInfo")
      },
      CheckCase("Stand-Filter: ohne Auswahl alle, sonst nur die gewählten Stände (erledigte wie sie stehen)") {
        try expectEqual(TaskStatusLogic.filter(sample, statuses: []).count, 6)
        try expectEqual(TaskStatusLogic.filter(sample, statuses: [.inProgress]).map(\.id), ["s1", "s4", "s6"])
        try expectEqual(TaskStatusLogic.filter(sample, statuses: [.open, .needsInfo]).map(\.id), ["s2", "s3", "s5"])
      },
      CheckCase("Aktive Filter: Stände in Menüreihenfolge vor den Kennzeichen, Zähler zählt jeden einmal") {
        let active = TaskStatusLogic.activeFilters(statuses: [.needsInfo, .inProgress], tags: ["kunde", "arbeit"])
        try expectEqual(active, [.status(.inProgress), .status(.needsInfo), .tag("kunde"), .tag("arbeit")])
        try expectEqual(TaskStatusLogic.activeCount(statuses: [.needsInfo, .inProgress], tags: ["kunde", "arbeit"]), 4)
        try expectEqual(TaskStatusLogic.activeCount(statuses: [], tags: []), 0)
        try expectEqual(TaskStatusLogic.activeFilters(statuses: [.open], tags: []).map(\.title), ["Offen"])
      },
      CheckCase("Ansicht gemerkt: Werte lesen und schreiben, kaputte Einträge fallen auf den Standard zurück") {
        let broken = TaskViewPrefs.parse(grouping: "gibtsnicht", statuses: "{kaputt", tags: "nicht json")
        try expectEqual(broken, TaskViewPrefs())
        let ok = TaskViewPrefs.parse(grouping: "tag", statuses: "[\"inProgress\",\"open\"]", tags: "[\"kunde\"]")
        try expectEqual(ok.grouping, .tag)
        try expectEqual(ok.statuses, [.inProgress, .open])
        try expectEqual(ok.tags, ["kunde"])
        let suite = "taby-view-prefs-check"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        TaskViewPrefs(grouping: .none, statuses: [.needsInfo, .open], tags: ["Büro"]).store(defaults)
        try expectEqual(TaskViewPrefs.stored(defaults), TaskViewPrefs(grouping: .none, statuses: [.open, .needsInfo], tags: ["Büro"]))
      },
      CheckCase("Quelle: Notion ist, wer eine Quellen-Verknüpfung hat; ohne Auswahl alle") {
        let s = facetSample
        try expectEqual(TaskStatusLogic.filter(s, sources: [.notion], due: [], sourceLinks: facetLinks, now: facetNow).map(\.id),
                        ["f1", "f4"])
        try expectEqual(TaskStatusLogic.filter(s, sources: [.own], due: [], sourceLinks: facetLinks, now: facetNow).count, 7)
        try expectEqual(TaskStatusLogic.filter(s, sources: [], due: [], sourceLinks: facetLinks, now: facetNow).count, 9)
      },
      CheckCase("Fällig Überfällig: gestern, oder heute mit schon vergangener Uhrzeit; erledigte nie") {
        let ids = TaskStatusLogic.filter(facetSample, sources: [], due: [.overdue], sourceLinks: [:], now: facetNow).map(\.id)
        try expectEqual(ids, ["f1", "f3"], "f2 (nur Datum heute) und f8 (erledigt) fehlen")
        let early = task("x", "früh", due: "2026-10-28T08:00")
        try expect(!TaskStatusLogic.matches(early, due: [.overdue], now: "2026-10-28T07:00"), "Uhrzeit noch nicht vergangen")
        try expect(TaskStatusLogic.matches(early, due: [.today], now: "2026-10-28T07:00"), "heute bleibt heute")
      },
      CheckCase("Fällig Heute, Morgen, Diese Woche, Ohne Datum: Grenzen zum Jetzt-Zeitpunkt") {
        let s = facetSample
        func ids(_ due: Set<TaskDueChoice>) -> [String] {
          TaskStatusLogic.filter(s, sources: [], due: due, sourceLinks: [:], now: facetNow).map(\.id)
        }
        try expectEqual(ids([.today]), ["f2", "f3"])
        try expectEqual(ids([.tomorrow]), ["f4"])
        try expectEqual(ids([.week]), ["f2", "f3", "f4", "f5"], "Mo bis So; Montag nächster Woche fehlt")
        try expectEqual(ids([.none]), ["f7", "f9"], "fehlendes und leeres Datum")
      },
      CheckCase("Fällig: Auswahl innerhalb der Gruppe ist ODER, Quelle und Fällig zusammen UND") {
        let s = facetSample
        try expectEqual(TaskStatusLogic.filter(s, sources: [], due: [.tomorrow, .none], sourceLinks: [:], now: facetNow).map(\.id),
                        ["f4", "f7", "f9"])
        try expectEqual(TaskStatusLogic.filter(s, sources: [.notion], due: [.overdue], sourceLinks: facetLinks, now: facetNow)
                          .map(\.id), ["f1"])
      },
      CheckCase("Woche: Montag bis Sonntag, heute ist 0 Tage bis Sonntag") {
        try expectEqual(TaskStatusLogic.daysLeftInWeek("2026-10-26T09:00"), 6, "Montag")
        try expectEqual(TaskStatusLogic.daysLeftInWeek("2026-10-28"), 4, "Mittwoch")
        try expectEqual(TaskStatusLogic.daysLeftInWeek("2026-10-31"), 1, "Samstag")
        try expectEqual(TaskStatusLogic.daysLeftInWeek("2026-10-25T09:00"), 0, "Sonntag")
      },
      CheckCase("Aktive Filter mit Quelle und Fällig: feste Reihenfolge, Zähler zählt jeden einmal") {
        let active = TaskStatusLogic.activeFilters(statuses: [.open], tags: ["a"], sources: [.own], due: [.week, .overdue])
        try expectEqual(active, [.status(.open), .tag("a"), .source(.own), .due(.overdue), .due(.week)])
        try expectEqual(active.map(\.title), ["Offen", "#a", "Eigene", "Überfällig", "Diese Woche"])
        try expectEqual(TaskStatusLogic.activeCount(statuses: [.open], tags: ["a"], sources: [.own], due: [.week, .overdue]), 5)
        try expectEqual(TaskStatusLogic.activeCount(statuses: [], tags: [], sources: [], due: []), 0)
      },
      CheckCase("Ansicht gemerkt: Quelle und Fällig werden gelesen und geschrieben, kaputte Werte fallen auf leer") {
        let broken = TaskViewPrefs.parse(grouping: nil, statuses: nil, tags: nil, sources: "{x", due: "[\"gibtsnicht\"]")
        try expectEqual(broken.sources, [])
        try expectEqual(broken.due, [])
        let suite = "taby-view-prefs-facets-check"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        TaskViewPrefs(grouping: .none, statuses: [], tags: [], sources: [.own, .notion], due: [.none, .overdue]).store(defaults)
        let back = TaskViewPrefs.stored(defaults)
        try expectEqual(back.sources, [.notion, .own])
        try expectEqual(back.due, [.overdue, .none])
      },
    ]
  }

  /// Aufgaben für Quelle und Fälligkeit; „heute“ ist Mittwoch, 28.10.2026, 09:00.
  static var facetSample: [TabyTask] {
    [
      task("f1", "Ticket aus Notion", due: "2026-10-27"),
      task("f2", "Heute, nur Datum", due: "2026-10-28"),
      task("f3", "Heute, Uhrzeit vorbei", due: "2026-10-28T08:00"),
      task("f4", "Morgen aus Notion", due: "2026-10-29"),
      task("f5", "Freitag", due: "2026-10-30"),
      task("f6", "Montag nächste Woche", due: "2026-11-02"),
      task("f7", "Ohne Datum"),
      task("f8", "Erledigt, gestern fällig", due: "2026-10-27", done: true),
      task("f9", "Leeres Datum", due: ""),
    ]
  }

  static let facetLinks = ["f1": "src", "f4": "src"]
  static let facetNow = "2026-10-28T09:00"

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-tasks-facets-menu", size: CGSize(width: TabLayout.contentWidth, height: 820)) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = facetSample
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: facetSample, notionLinks: facetLinks, sourceFilter: [.notion],
                              dueFilter: [.overdue, .tomorrow], optionsOpen: true).tabyPage(), model, now: facetNow)
      },
      SnapshotSpec("view-tasks-status-grouped", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = sample
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: sample, groupedByStatus: true).tabyPage(), model)
      },
      SnapshotSpec("view-today-status-chips", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.overview.todayTasks = [
          task("t1", "Angebot prüfen", due: "2026-10-11", status: .inProgress),
          task("t2", "Rechnung Nr. 4711", due: "2026-10-11", status: .needsInfo),
          task("t3", "Steuerunterlagen", due: "2026-10-11"),
        ]
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .today, preview: fake.current), model)
      },
    ]
  }

  static let size = CGSize(width: TabLayout.contentWidth, height: 420)

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel, now: String = ViewChecks.now) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true))
  }
}
