// Prüfungen der Aufgaben-Kategorien: Filter, Ordner je Kategorie, Anlegen und Pflege, Plan-Gruppierung, Zähler,
// Notion-Zugänge (Kategorie je Zugang, Herkunft-Zeile) und die Snapshots dazu.
import Foundation
import SwiftUI
import TabyCore

enum TaskCategoryChecks {
  static let sport = TaskCategoryDef(id: "sport", name: "Sport", symbol: "figure.run")
  static let defs = TaskCategoryDef.builtIn + [sport]
  static let folders = [
    TaskFolder(id: "f-privat", name: "Reise", createdAt: "", categoryId: "privat"),
    TaskFolder(id: "f-sport", name: "Laufen", createdAt: "", categoryId: "sport"),
    TaskFolder(id: "f-alle", name: "Ideen", createdAt: "", categoryId: nil),
  ]

  /// Zwei Notion-Zugänge in Arbeit (Geschäftlich, Kunde Nord) und einer in Privat; Aufgaben aus Notion
  /// liegen unter „Privat“ nie, auch wenn ihre eigene Kategorie Privat ist.
  @MainActor static func notionFixture() -> FakeServices {
    let fake = FakeServices(sample: false)
    fake.current.settings.taskCategories = defs
    fake.current.settings.notionAccounts = [
      NotionAccount(id: "geschaeft", name: "Geschäftlich", categoryId: "arbeit"),
      NotionAccount(id: "kunde", name: "Kunde Nord", categoryId: "arbeit"),
      NotionAccount(id: "privat", name: "Privat", categoryId: "privat"),
    ]
    fake.current.notionSources = [
      NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "1a2b3c", accountId: "geschaeft"),
      NotionSource(id: "s2", name: "Weekly", category: .weekly, link: "4d5e6f", accountId: "kunde"),
    ]
    fake.current.notionSourceLinks = ["nt1": "s1", "nt2": "s1", "nt3": "s2"]
    fake.current.notionTaskCategories = ["nt1": "arbeit", "nt2": "arbeit", "nt3": "arbeit"]
    fake.current.tasks = [
      TabyTask(id: "nt1", title: "Angebot für Kunde X", due: "2026-10-14", createdAt: "2026-10-13T08:00"),
      TabyTask(id: "nt2", title: "Release-Ticket prüfen", createdAt: "2026-10-12T10:00", category: .privat),
      TabyTask(id: "nt3", title: "Weekly vorbereiten", createdAt: "2026-10-12T09:00"),
      TabyTask(id: "own1", title: "Bericht schreiben", due: "2026-10-15T09:00", createdAt: "2026-10-11T08:00",
               category: .arbeit),
      TabyTask(id: "own2", title: "Einkaufsliste", createdAt: "2026-10-11T18:00", category: .privat),
    ]
    return fake
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true)
      .frame(maxHeight: .infinity, alignment: .top))
  }

  /// Aufgabenliste mit den Festwerten der Fixture (Snapshots haben keinen geladenen `model.state`).
  @MainActor static func tasksView(_ fake: FakeServices, selected: String?) -> TasksView {
    TasksView(tasks: fake.current.tasks, notionLinks: fake.current.notionSourceLinks, categories: defs,
              selectedCategory: selected,
              notionOverride: NotionOverride(accounts: fake.current.settings.notionAccounts,
                                             sources: fake.current.notionSources,
                                             categories: fake.current.notionTaskCategories))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-tasks-notion-work", size: ViewSnapshots.size) {
        let fake = notionFixture()
        let model = AppModel(services: fake)
        return wrap(tasksView(fake, selected: "arbeit").tabyPage(), model)
      },
      SnapshotSpec("view-tasks-notion-privat", size: ViewSnapshots.size) {
        let fake = notionFixture()
        let model = AppModel(services: fake)
        return wrap(tasksView(fake, selected: "privat").tabyPage(), model)
      },
      SnapshotSpec("view-tasks-all-overview", size: CGSize(width: TabLayout.contentWidth, height: 1000)) {
        // Alle: eigene Aufgaben in Arbeit und Privat, eine Notion-Aufgabe eines Privat-Zugangs, eine ohne Kategorie.
        let fake = notionFixture()
        fake.current.settings.notionAccounts.append(NotionAccount(id: "zuhause", name: "Zuhause", categoryId: "privat"))
        fake.current.notionSources.append(NotionSource(id: "s3", name: "Haushalt", category: .todos, link: "7a8b9c",
                                                       accountId: "zuhause"))
        fake.current.notionSourceLinks["nt4"] = "s3"
        fake.current.notionTaskCategories["nt4"] = "privat"
        fake.current.tasks.append(TabyTask(id: "nt4", title: "Haushalt-Liste", createdAt: "2026-10-10T09:00"))
        fake.current.tasks.append(TabyTask(id: "own3", title: "Ohne Kategorie", createdAt: "2026-10-10T08:00"))
        let model = AppModel(services: fake)
        return wrap(tasksView(fake, selected: nil).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-category-menu", size: CGSize(width: TabLayout.contentWidth, height: 120)) {
        let fake = notionFixture()
        let model = AppModel(services: fake)
        let rows = VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 10) {
            TaskCategoryButton(current: defs[1], notionAccount: nil) { EmptyView() }
            Text("Eigene Aufgabe: Menü").font(.system(size: 13)).foregroundStyle(Theme.text)
          }
          HStack(spacing: 10) {
            TaskCategoryButton(current: defs[0], notionAccount: "Geschäftlich") { EmptyView() }
            Text("Notion-Aufgabe: nur Anzeige").font(.system(size: 13)).foregroundStyle(Theme.text)
          }
        }
        .padding(12)
        return wrap(rows, model)
      },
    ]
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Ordner aus Privat erscheinen nur unter Privat, bei Alle nur die ohne Kategorie") {
        try expectEqual(TaskCategoryLogic.folders(folders, in: "privat", defs: defs).map(\.id), ["f-privat"])
        try expectEqual(TaskCategoryLogic.folders(folders, in: "arbeit", defs: defs).map(\.id), [])
        try expectEqual(TaskCategoryLogic.folders(folders, in: nil, defs: defs).map(\.id), ["f-alle"])
      },
      CheckCase("Alle: Übersicht nach Kategorie, Ordner aus Kategorien erscheinen nicht, Alt-Ordner behalten ihren Abschnitt") {
        let t1 = TabyTask(id: "t1", title: "Flug", createdAt: "", folderId: "f-privat")
        let t2 = TabyTask(id: "t2", title: "Ohne", createdAt: "")
        let t3 = TabyTask(id: "t3", title: "Idee", createdAt: "", folderId: "f-alle")
        let names = TaskCategoryLogic.groups([t1, t2, t3], category: nil, folders: folders, defs: defs,
                                             notionCategories: [:]).map(\.name)
        try expectEqual(names, ["Privat", "Ideen", "Ohne Kategorie"])
        try expect(!names.contains("Reise") && !names.contains("Reise (Privat)"), "kategorisierter Ordner nicht in Alle")
      },
      CheckCase("Kategorien: Steuerzeichen im Namen und Symbol über 64 Zeichen werden mit Grund abgelehnt") {
        try expectEqual(TaskCategoryRules.problem(defs), nil, "gültige Liste")
        let control = [TaskCategoryDef(id: "x", name: "A\u{7}B", symbol: "tag.fill")]
        try expectEqual(TaskCategoryRules.problem(control), "Der Name enthält Steuerzeichen.")
        let long = [TaskCategoryDef(id: "x", name: "Ok", symbol: String(repeating: "s", count: 65))]
        try expectEqual(TaskCategoryRules.problem(long), "Das Symbol ist länger als 64 Zeichen.")
        try expect(TaskCategoryRules.sanitize(control) == nil, "ungültig bleibt ungültig")
      },
      CheckCase("Unbekannte Ordner-Kategorie zählt als keine") {
        let f = TaskFolder(id: "x", name: "Alt", createdAt: "", categoryId: "geloescht")
        try expectEqual(TaskCategoryLogic.folderCategory(f, defs: defs), nil)
        try expectEqual(TaskCategoryLogic.folders([f], in: nil, defs: defs).map(\.id), ["x"])
      },
      CheckCase("Eigene Kategorie gewinnt über den Ordner; ohne eigene zählt der Ordner") {
        let own = TabyTask(id: "a", title: "a", createdAt: "", category: .arbeit, folderId: "f-privat")
        try expectEqual(TaskCategoryLogic.effective(own, folders: folders, defs: defs, notionCategories: [:]), "arbeit")
        let inherited = TabyTask(id: "b", title: "b", createdAt: "", folderId: "f-privat")
        try expectEqual(TaskCategoryLogic.effective(inherited, folders: folders, defs: defs, notionCategories: [:]), "privat")
        let unknownOwn = TabyTask(id: "c", title: "c", createdAt: "", category: TaskCategory(rawValue: "weg"),
                                  folderId: "f-privat")
        try expectEqual(TaskCategoryLogic.effective(unknownOwn, folders: folders, defs: defs, notionCategories: [:]), "privat",
                        "unbekannte Kennung zählt als keine, dann der Ordner")
        let loose = TabyTask(id: "d", title: "d", createdAt: "", category: TaskCategory(rawValue: "weg"))
        try expectEqual(TaskCategoryLogic.effective(loose, folders: folders, defs: defs, notionCategories: [:]), nil)
        try expect(!TaskLogic.matches(own, category: "privat", folders: folders, defs: defs, notionCategories: [:]),
                   "eigene Arbeit ist nicht Privat")
        try expect(TaskLogic.matches(inherited, category: "privat", folders: folders, defs: defs, notionCategories: [:]))
      },
      CheckCase("Gruppen einer Kategorie: ihre Ordner, dann Ohne Ordner; fremde Ordner ausgeschlossen") {
        let t1 = TabyTask(id: "t1", title: "Flug", createdAt: "", folderId: "f-privat")
        let t2 = TabyTask(id: "t2", title: "Einkauf", createdAt: "", category: .privat)
        let t3 = TabyTask(id: "t3", title: "Lauf", createdAt: "", category: TaskCategory(rawValue: "sport"), folderId: "f-privat")
        let groups = TaskCategoryLogic.groups([t1, t2, t3], category: "privat", folders: folders, defs: defs,
                                              notionCategories: [:])
        try expectEqual(groups.map(\.name), ["Reise", "Ohne Ordner"])
        try expectEqual(groups[0].tasks.map(\.id), ["t1"])
        try expectEqual(groups[1].tasks.map(\.id), ["t2"], "t3 gehört zu Sport, auch wenn ihr Ordner Privat ist")
      },
      CheckCase("Neue Kategorie: Kennung normalisiert, Umlaute ausgeschrieben, Sonderzeichen entfernt") {
        try expectEqual(TaskCategoryLogic.id(from: "  Sport & Fitness "), "sport-fitness")
        try expectEqual(TaskCategoryLogic.id(from: "Über Ärger"), "ueber-aerger")
        try expectEqual(TaskCategoryLogic.id(from: "!!!"), "")
        var list = TaskCategoryDef.builtIn
        try expectEqual(TaskCategoryLogic.add(name: " Sport & Fitness ", symbol: "figure.run", to: &list), nil)
        try expectEqual(list.last?.id, "sport-fitness")
        try expectEqual(list.last?.name, "Sport & Fitness")
        try expectEqual(list.last?.symbol, "figure.run")
      },
      CheckCase("Neue Kategorie: Dubletten, Leerzeichen-Name, 13. Kategorie und Namenslänge werden abgelehnt") {
        var list = TaskCategoryDef.builtIn
        try expectEqual(TaskCategoryLogic.add(name: "Arbeit", symbol: "tag.fill", to: &list), "Die Kategorie Arbeit gibt es schon.")
        try expectEqual(TaskCategoryLogic.add(name: "   ", symbol: "tag.fill", to: &list), "Gib der Kategorie einen Namen.")
        try expectEqual(TaskCategoryLogic.add(name: "!!!", symbol: "tag.fill", to: &list),
                        "Der Name braucht mindestens einen Buchstaben oder eine Ziffer.")
        try expectEqual(TaskCategoryLogic.add(name: String(repeating: "x", count: 25), symbol: "tag.fill", to: &list),
                        "Der Name darf höchstens 24 Zeichen haben.")
        for i in 0..<10 { _ = TaskCategoryLogic.add(name: "Kat \(i)", symbol: "tag.fill", to: &list) }
        try expectEqual(list.count, 12)
        try expect(TaskCategoryLogic.add(name: "Dreizehn", symbol: "tag.fill", to: &list)?.hasPrefix("Höchstens 12") == true)
        try expectEqual(list.count, 12, "unverändert nach Ablehnung")
        try expectEqual(TaskCategoryRules.sanitize(list)?.count, 12, "passt zu den Regeln des Kerns")
      },
      CheckCase("Pflege: umbenennen behält die Kennung, eingebaute bleiben, eigene verschieben und löschen") {
        var list = defs
        try expectEqual(TaskCategoryLogic.rename("sport", to: "Training", in: &list), nil)
        try expectEqual(list.first { $0.id == "sport" }?.name, "Training")
        try expect(TaskCategoryLogic.delete("arbeit", in: &list) != nil, "eingebaute lassen sich nicht löschen")
        try expectEqual(list.count, 3)
        _ = TaskCategoryLogic.add(name: "Lesen", symbol: "book.fill", to: &list)
        TaskCategoryLogic.move("lesen", up: true, in: &list)
        try expectEqual(list.map(\.id), ["arbeit", "privat", "lesen", "sport"])
        TaskCategoryLogic.move("lesen", up: true, in: &list)
        try expectEqual(list.map(\.id), ["arbeit", "privat", "lesen", "sport"], "eingebaute bleiben vorn")
        try expectEqual(TaskCategoryLogic.delete("lesen", in: &list), nil)
        try expectEqual(list.map(\.id), ["arbeit", "privat", "sport"])
      },
      CheckCase("Plan-Auswahl gruppiert nach Kategorie in Einstellungsreihenfolge, dann Ordner") {
        let tasks = [
          TabyTask(id: "p1", title: "Flug", createdAt: "", folderId: "f-privat"),
          TabyTask(id: "p2", title: "Lauf", createdAt: "", category: TaskCategory(rawValue: "sport")),
          TabyTask(id: "p3", title: "Einkauf", createdAt: "", category: .privat),
          TabyTask(id: "p4", title: "Bericht", createdAt: "", category: .arbeit),
          TabyTask(id: "p5", title: "Idee", createdAt: ""),
        ]
        let out = PlanPickerLogic.sections(tasks, sourceLinks: [:], sources: [], taskGroups: [:],
                                           now: "2026-10-11T10:00", notionCategories: [:], categories: defs, folders: folders)
        try expectEqual(out.map(\.id), ["cat-arbeit", "cat-privat", "cat-sport", "none"])
        let privat = try expectNotNil(out.first { $0.id == "cat-privat" })
        try expectEqual(privat.groups.map(\.title), ["Reise", "Ohne Ordner"])
        try expectEqual(privat.count, 2)
        try expectEqual(out.first { $0.id == "none" }?.groups.first?.title, "")
      },
      CheckCase("Notion-Aufgabe: Kategorie kommt vom Zugang, auch wenn sie eigene Kategorie Privat trägt") {
        let n = TabyTask(id: "n", title: "Ticket", createdAt: "", category: .privat)
        let map = ["n": "arbeit"]
        try expectEqual(TaskCategoryLogic.effective(n, folders: folders, defs: defs, notionCategories: map), "arbeit")
        try expect(!TaskLogic.matches(n, category: "privat", folders: folders, defs: defs, notionCategories: map),
                   "Notion-Aufgabe eines Arbeits-Zugangs nie unter Privat")
        try expect(TaskLogic.matches(n, category: "arbeit", folders: folders, defs: defs, notionCategories: map))
        try expectEqual(TaskCategoryLogic.effective(n, folders: folders, defs: defs, notionCategories: [:]), "privat",
                        "ohne Zuordnung zählt die eigene Kategorie")
      },
      CheckCase("Notion-Aufgabe: Alle zeigt sie unter der Kategorie ihres Zugangs, nicht unter Privat") {
        let n = TabyTask(id: "n1", title: "Ticket", createdAt: "", category: .privat)
        let own = TabyTask(id: "o", title: "Einkauf", createdAt: "", category: .privat)
        let groups = TaskCategoryLogic.overview([n, own], folders: folders, defs: defs, notionCategories: ["n1": "arbeit"])
        try expectEqual(groups.map(\.name), ["Arbeit", "Privat"])
        try expectEqual(groups[0].tasks.map(\.id), ["n1"])
        try expectEqual(groups[1].tasks.map(\.id), ["o"])
      },
      CheckCase("Notion-Aufgabe mit unbekannter Zugangs-Kategorie zählt als Ohne Kategorie, auch im Plan") {
        let n = TabyTask(id: "n", title: "Ticket", createdAt: "", category: .privat)
        let map = ["n": "geloescht"]
        try expectEqual(TaskCategoryLogic.effective(n, folders: folders, defs: defs, notionCategories: map), nil)
        try expectEqual(TaskCategoryLogic.overview([n], folders: folders, defs: defs, notionCategories: map).map(\.name),
                        ["Ohne Kategorie"])
        let sources = [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "x", accountId: "acc")]
        let plan = PlanPickerLogic.sections([n], sourceLinks: ["n": "s1"], sources: sources, taskGroups: [:],
                                            now: "2026-10-11T10:00", notionCategories: map, categories: defs, folders: folders)
        try expectEqual(plan.map(\.title), ["Ohne Kategorie"])
        try expectEqual(plan.first?.groups.map(\.title), ["Notion · Tickets"])
      },
      CheckCase("Plan-Auswahl: Notion-Aufgabe steht unter der Kategorie ihres Zugangs, Quelle als Untertitel") {
        let n = TabyTask(id: "n", title: "Ticket", createdAt: "")
        let a = TabyTask(id: "a", title: "Bericht", createdAt: "", category: .arbeit)
        let sources = [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "x", accountId: "privat-acc")]
        let plan = PlanPickerLogic.sections([n, a], sourceLinks: ["n": "s1"], sources: sources, taskGroups: [:],
                                            now: "2026-10-11T10:00", notionCategories: ["n": "privat"],
                                            categories: defs, folders: folders)
        try expectEqual(plan.map(\.title), ["Arbeit", "Privat"])
        try expectEqual(plan[1].groups.map(\.title), ["Notion · Tickets"])
        try expectEqual(plan[1].count, 1)
        try expect(!plan.contains { $0.title == "Notion-Tickets" }, "kein globaler Notion-Block mehr")
      },
      CheckCase("Herkunft-Zeile: nur bei einer Kategorie mit Notion-Zugang, je Zugang ein Eintrag, unter Alle keine") {
        let accounts = [NotionAccount(id: "geschaeft", name: "Geschäftlich", categoryId: "arbeit"),
                        NotionAccount(id: "kunde", name: "Kunde", categoryId: "arbeit"),
                        NotionAccount(id: "leer", name: "Leer", categoryId: "arbeit"),
                        NotionAccount(id: "privat", name: "Privat", categoryId: "privat")]
        let sources = [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "a", accountId: "geschaeft"),
                       NotionSource(id: "s2", name: "Weekly", category: .weekly, link: "b", accountId: "kunde")]
        let tasks = [TabyTask(id: "t1", title: "Ticket", createdAt: "")]
        let links = ["t1": "s1"]
        let arbeit = TaskLogic.originAccounts(category: "arbeit", accounts: accounts, tasks: tasks,
                                              sourceLinks: links, sources: sources)
        try expectEqual(arbeit.map(\.id), ["geschaeft", "kunde"], "je Zugang mit Quellen ein Eintrag, der leere fehlt")
        try expectEqual(TaskLogic.originAccounts(category: "privat", accounts: accounts, tasks: tasks,
                                                 sourceLinks: links, sources: sources), [],
                        "Privat ohne Notion-Zugang: keine Zeile")
        try expectEqual(TaskLogic.originAccounts(category: nil, accounts: accounts, tasks: tasks,
                                                 sourceLinks: links, sources: sources), [], "Alle: keine Zeile")
        let gone = TaskLogic.originAccounts(category: "arbeit", accounts: accounts, tasks: [],
                                            sourceLinks: [:], sources: [])
        try expectEqual(gone, [], "ohne Quellen und Aufgaben keine Zeile")
      },
      CheckCase("Einordnen-Menü: Wahl setzt die Kennung, Keine Kategorie leert, die aktuelle tut nichts") {
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: "arbeit", current: nil, defs: defs), "arbeit")
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: "arbeit", current: "arbeit", defs: defs), nil)
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: nil, current: "privat", defs: defs), "")
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: nil, current: nil, defs: defs), nil)
      },
      CheckCase("Notion-Aufgabe ist im Menü nur Anzeige, eigene Aufgabe bleibt änderbar") {
        let map = ["n": "arbeit"]
        try expect(TaskCategoryLogic.isNotionTask("n", notionCategories: map))
        try expect(!TaskCategoryLogic.isNotionTask("o", notionCategories: map))
      },
      CheckCase("Einordnen aus dem Filter: Hinweis „In Arbeit verschoben“, bleibt sie im Filter oder bei Alle, kein Hinweis") {
        let t = TabyTask(id: "x", title: "Angebot", createdAt: "", category: .privat)
        try expect(TaskCategoryLogic.movesOut(t, to: "arbeit", filter: "privat", folders: folders, defs: defs,
                                              notionCategories: [:]))
        try expectEqual(TaskCategoryLogic.moveLabel("arbeit", defs: defs), "In Arbeit verschoben")
        try expectEqual(TaskCategoryLogic.moveLabel(nil, defs: defs), "Kategorie entfernt")
        try expect(!TaskCategoryLogic.movesOut(t, to: "arbeit", filter: nil, folders: folders, defs: defs, notionCategories: [:]),
                   "Alle hält sie")
        try expect(!TaskCategoryLogic.movesOut(t, to: "privat", filter: "privat", folders: folders, defs: defs,
                                               notionCategories: [:]), "bleibt im Filter")
        let inFolder = TabyTask(id: "y", title: "Reise", createdAt: "", folderId: "f-privat")
        try expect(!TaskCategoryLogic.movesOut(inFolder, to: nil, filter: "privat", folders: folders, defs: defs,
                                               notionCategories: [:]), "Ordner hält sie in Privat")
      },
      CheckCase("Kategorie mit Notion-Zugang lässt sich nicht löschen; ohne Zugang schon") {
        var list = defs
        let accounts = [NotionAccount(id: "kunde", name: "Kunde Nord", categoryId: "sport")]
        let refused = TaskCategoryLogic.delete("sport", in: &list, notionAccounts: accounts)
        try expectEqual(refused, "Notion-Zugang „Kunde Nord“ gehört zu dieser Kategorie – stelle ihn erst um.")
        try expect(list.contains { $0.id == "sport" }, "Kategorie bleibt")
        try expectEqual(TaskCategoryLogic.delete("sport", in: &list, notionAccounts: []), nil, "ohne Zugang löschbar")
        try expect(!list.contains { $0.id == "sport" }, "gelöscht")
      },
      CheckCase("Zugang mit fehlender Kategorie zählt als ohne Kategorie und wird in den Einstellungen gemeldet") {
        let accounts = [NotionAccount(id: "kunde", name: "Kunde Nord", categoryId: "sport")]
        try expectEqual(TaskCategoryLogic.accountsWithoutCategory(accounts, defs: TaskCategoryDef.builtIn).map(\.name),
                        ["Kunde Nord"], "Kategorie fehlt in der Liste")
        try expectEqual(TaskCategoryLogic.accountsWithoutCategory(accounts, defs: defs).count, 0, "Kategorie vorhanden")
        let t = TabyTask(id: "nt9", title: "Ticket", createdAt: "")
        try expectEqual(TaskCategoryLogic.effective(t, folders: [], defs: TaskCategoryDef.builtIn,
                                                    notionCategories: ["nt9": "sport"]), nil, "wirkt als ohne Kategorie")
      },
      CheckCase("Alle ohne Ordner: Arbeit, Privat (auch Notion-Privat-Zugang), Ohne Kategorie zuletzt") {
        let tasks = [
          TabyTask(id: "own1", title: "Bericht", createdAt: "", category: .arbeit),
          TabyTask(id: "own2", title: "Einkauf", createdAt: "", category: .privat),
          TabyTask(id: "nt4", title: "Haushalt-Liste", createdAt: ""),
          TabyTask(id: "own3", title: "Ohne", createdAt: ""),
        ]
        let groups = TaskCategoryLogic.overview(tasks, folders: [], defs: defs, notionCategories: ["nt4": "privat"])
        try expectEqual(groups.map(\.name), ["Arbeit", "Privat", "Ohne Kategorie"], "Reihenfolge")
        try expectEqual(groups.map { $0.tasks.count }, [1, 2, 1], "Zählung")
      },
      CheckCase("Zähler am Reiter: heute und alle offenen") {
        try expectEqual(TaskLogic.sidebarCount(todayOpen: 2, allOpen: 5), "heute 2 · 5 offen")
        try expectEqual(TaskLogic.sidebarCount(todayOpen: 0, allOpen: 0), "heute 0 · 0 offen")
      },
    ]
  }
}
