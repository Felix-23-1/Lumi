// Prüfungen des Notion-Bereichs der Aufgabenansicht: Zuklappen (gemerkt, alle auf/zu, Filter klappt auf),
// Suche im Titel, Quellenauswahl, und die Snapshots dazu.
import Foundation
import SwiftUI
import TabyCore

enum NotionSectionChecks {
  static let ticket = "s1|Notion · Tickets"

  static func task(_ id: String, _ title: String) -> TabyTask {
    TabyTask(id: id, title: title, createdAt: "2026-10-12T08:00")
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Notion-Zuklappen: gemerkter Zustand überlebt Neustart, kaputte Werte fallen auf nichts zugeklappt") {
        let suite = try expectNotNil(UserDefaults(suiteName: "taby-check-notion-\(UUID().uuidString)"), "Suite")
        try expectEqual(NotionSectionLogic.stored(suite), [], "ohne Eintrag nichts zugeklappt")
        NotionSectionLogic.store(["s1|Notion · Tickets", "s2|KW 42"], suite)
        try expectEqual(NotionSectionLogic.stored(suite), ["s1|Notion · Tickets", "s2|KW 42"], "Zustand bleibt erhalten")
        suite.set("kein json", forKey: NotionSectionLogic.collapsedKey)
        try expectEqual(NotionSectionLogic.stored(suite), [], "kaputter Wert = nichts zugeklappt")
        try expectEqual(NotionSectionLogic.parse(nil), [], "fehlender Wert ist sicher")
      },
      CheckCase("Notion-Zuklappen: alle zu, dann alle auf (nur die sichtbaren Abschnitte)") {
        let ids = ["a|X", "b|Y"]
        let all = NotionSectionLogic.toggledAll(ids, collapsed: [])
        try expectEqual(all, Set(ids), "Alle zuklappen klappt alle sichtbaren zu")
        try expect(NotionSectionLogic.allFolded(ids, collapsed: all), "danach sind alle zu")
        try expectEqual(NotionSectionLogic.toggledAll(ids, collapsed: all), [], "wenn alle zu: alle auf")
        try expectEqual(NotionSectionLogic.toggledAll(ids, collapsed: ["a|X", "fremd|Z"]), ["a|X", "b|Y", "fremd|Z"],
                        "gemerkte Abschnitte außerhalb der Liste bleiben unberührt")
        try expectEqual(NotionSectionLogic.toggledAll([], collapsed: ["x"]), ["x"], "ohne Abschnitte ändert sich nichts")
        try expect(!NotionSectionLogic.allFolded([], collapsed: []), "ohne Abschnitte gilt nicht als zugeklappt")
      },
      CheckCase("Notion-Zuklappen: aktiver Filter klappt auf, Zustand bleibt gemerkt") {
        try expect(NotionSectionLogic.isFolded("a", collapsed: ["a"], filterActive: false), "zugeklappt ohne Filter")
        try expect(!NotionSectionLogic.isFolded("a", collapsed: ["a"], filterActive: true),
                   "mit aktivem Filter nichts verstecken")
        try expect(!NotionSectionLogic.isFolded("b", collapsed: ["a"], filterActive: false), "nicht gemerkt = offen")
        try expect(!NotionSectionLogic.filterActive(search: "   ", sourceIds: []), "Leerzeichen ist keine Suche")
        try expect(NotionSectionLogic.filterActive(search: "", sourceIds: ["s1"]), "Quellenauswahl zählt als Filter")
      },
      CheckCase("Notion-Suche: Titel ohne Groß/Klein und Akzente, leer findet alles") {
        let angebot = task("a", "Angebot für Kunde X")
        let uebergabe = task("u", "Übergabe Protokoll")
        try expect(NotionSectionLogic.matches(angebot, search: "  ANGEBOT "), "Groß/Klein und Leerzeichen egal")
        try expect(NotionSectionLogic.matches(uebergabe, search: "ubergabe"), "ohne Umlautpunkt findet Ü")
        try expect(!NotionSectionLogic.matches(angebot, search: "rechnung"), "fremder Begriff findet nichts")
        try expect(NotionSectionLogic.matches(angebot, search: ""), "leere Suche findet alles")
      },
      CheckCase("Notion-Filter: Quelle und Suche wirken zusammen; leere Quellenauswahl heißt alle") {
        let tasks = [task("n1", "Ticket Alpha"), task("n2", "Ticket Beta"), task("n3", "Weekly Alpha")]
        let links = ["n1": "s1", "n2": "s2", "n3": "s2"]
        try expectEqual(NotionSectionLogic.filter(tasks, search: "", sourceIds: [], sourceLinks: links).map(\.id),
                        ["n1", "n2", "n3"], "ohne Auswahl alle")
        try expectEqual(NotionSectionLogic.filter(tasks, search: "", sourceIds: ["s2"], sourceLinks: links).map(\.id),
                        ["n2", "n3"], "nur Quelle s2")
        try expectEqual(NotionSectionLogic.filter(tasks, search: "alpha", sourceIds: ["s2"], sourceLinks: links).map(\.id),
                        ["n3"], "Quelle und Suche zusammen")
        try expectEqual(NotionSectionLogic.filter(tasks, search: "zzz", sourceIds: [], sourceLinks: links).map(\.id),
                        [], "kein Treffer")
      },
      CheckCase("Notion-Abschnitte: Kennung trennt gleichnamige Wochen verschiedener Quellen") {
        let a = NotionSectionLogic.sectionId(title: "Notion · KW 42", sourceId: "w1")
        let b = NotionSectionLogic.sectionId(title: "Notion · KW 42", sourceId: "w2")
        try expect(a != b, "gleiche Woche, andere Quelle = anderer Abschnitt")
        try expectEqual(a, NotionSectionLogic.sectionId(title: "Notion · KW 42", sourceId: "w1"), "Kennung ist stabil")
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    let size = ViewSnapshots.size
    return [
      SnapshotSpec("view-tasks-notion-folded", size: size) {
        // Abschnitt „Tickets“ zugeklappt: nur Kopf mit Anzahl, Weekly-Abschnitt offen.
        let fake = TaskCategoryChecks.notionFixture()
        let model = AppModel(services: fake)
        return wrap(view(fake, origin: .account("geschaeft"), collapsed: [ticket]).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-notion-search-empty", size: size) {
        // Suche ohne Treffer: „Nichts gefunden“ mit „Filter zurücksetzen“.
        let fake = TaskCategoryChecks.notionFixture()
        let model = AppModel(services: fake)
        return wrap(view(fake, origin: .account("geschaeft"), search: "zzzz").tabyPage(), model)
      },
      SnapshotSpec("view-tasks-notion-sources", size: size) {
        // Zugang mit zwei Quellen: Quellen-Auswahl mit „Alle“, gewählt ist nur „Tickets“.
        let fake = TaskCategoryChecks.notionFixture()
        fake.current.notionSources.append(NotionSource(id: "s4", name: "Projekte", category: .todos, link: "9z8y7x",
                                                       accountId: "geschaeft"))
        let model = AppModel(services: fake)
        return wrap(view(fake, origin: .account("geschaeft"), sourceIds: ["s1"]).tabyPage(), model)
      },
    ]
  }

  @MainActor private static func view(_ fake: FakeServices, origin: TaskOrigin, search: String = "",
                                      sourceIds: [String] = [], collapsed: [String]? = nil) -> TasksView {
    TasksView(tasks: fake.current.tasks, notionLinks: fake.current.notionSourceLinks,
              categories: TaskCategoryChecks.defs, selectedCategory: "arbeit",
              notionOverride: NotionOverride(accounts: fake.current.settings.notionAccounts,
                                             sources: fake.current.notionSources,
                                             categories: fake.current.notionTaskCategories),
              selectedOrigin: origin, notionSearch: search, notionSourceIds: sourceIds,
              notionCollapsedIds: collapsed ?? [])
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true)
      .frame(maxHeight: .infinity, alignment: .top))
  }
}
