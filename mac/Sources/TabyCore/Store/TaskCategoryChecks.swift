// Prüfungen für Aufgaben-Kategorien: Einstellungen (Speichern, Laden, Regeln) und
// Werkzeuge (add_task, update_task, list_tasks mit `category`). Speicher im Arbeitsspeicher.
import Foundation

private func categoryStore() throws -> Store {
  try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
}

private func def(_ id: String, _ name: String) -> TaskCategoryDef {
  TaskCategoryDef(id: id, name: name, symbol: "tag.fill")
}

extension StoreChecks {
  static let taskCategoryChecks: [CheckCase] = [
    CheckCase("Kategorien: Speichern und Laden über die Einstellungen") {
      let store = try categoryStore()
      let saved = try store.settings.update(SettingsPatch(taskCategories: [
        def("arbeit", "Arbeit"), def("privat", "Privat"), def("sport", "Sport"),
      ]))
      try expectEqual(saved.taskCategories.map(\.id), ["arbeit", "privat", "sport"], "Rückgabe des Updates")
      let loaded = try store.settings.get()
      try expectEqual(loaded.taskCategories, saved.taskCategories, "Neu geladen wie gespeichert")
      try expectEqual(loaded.taskCategories.last?.name, "Sport", "eigener Name bleibt erhalten")
    },
    CheckCase("Kategorien: eingebaute Arbeit und Privat bleiben vorn, auch wenn die Liste sie weglässt") {
      let store = try categoryStore()
      let saved = try store.settings.update(SettingsPatch(taskCategories: [def("sport", "Sport"), def("privat", "Privat")]))
      try expectEqual(saved.taskCategories.map(\.id), ["arbeit", "privat", "sport"], "arbeit ergänzt, vorn")
    },
    CheckCase("Kategorien: ungültige Kennung, Name oder Anzahl wird abgewiesen, der bisherige Wert bleibt") {
      let store = try categoryStore()
      let before = try store.settings.get().taskCategories
      let bad: [[TaskCategoryDef]] = [
        [def("Sport", "Sport")],                       // Großbuchstaben
        [def("sport wow", "Sport")],                   // Leerzeichen
        [def("", "Sport")],                            // leere Kennung
        [def("sport", "")],                            // leerer Name
        [def("sport", String(repeating: "x", count: 25))], // Name zu lang
        [def("sport", "Sport"), def("sport", "Doppelt")],  // doppelte Kennung
        (0..<12).map { def("k\($0)", "K\($0)") },         // 12 eigene + 2 eingebaute = 14 > 12
      ]
      for list in bad {
        let after = try store.settings.update(SettingsPatch(taskCategories: list)).taskCategories
        try expectEqual(after, before, "abgewiesen: \(list.map(\.id))")
      }
      let limit = try store.settings.update(SettingsPatch(taskCategories: (0..<10).map { def("k\($0)", "K\($0)") }))
      try expectEqual(limit.taskCategories.count, 12, "10 eigene + 2 eingebaute sind genau 12 erlaubt")
    },
    CheckCase("Kategorien: ungültig gespeicherte Liste fällt auf die eingebauten zurück") {
      let store = try categoryStore()
      try store.db.run("INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text("taskCategories"), .text(#"[{"id":"NOPE!","name":"x","symbol":"a"}]"#)])
      try expectEqual(try store.settings.get().taskCategories, TaskCategoryDef.builtIn, "Standard bei kaputter Liste")
    },
    CheckCase("Kategorien: Kennung und Anzeige im Überblick (summary)") {
      try expectEqual(TaskCategoryRules.summary(TaskCategoryDef.builtIn + [def("sport", "Sport")]),
                      "Arbeit (arbeit), Privat (privat), Sport (sport)", "Zeile für Systemprompt")
      try expectEqual(TaskCategoryRules.normalize("  Sport "), "sport", "Kennung normalisiert")
      try expectEqual(TaskCategoryRules.normalize("  "), nil, "leer = keine Kategorie")
    },
    CheckCase("Werkzeug: add_task lehnt unbekannte Kategorie mit der Liste ab") {
      let store = try categoryStore()
      let ctx = ToolContext(store: store, mode: .standard)
      let r = await ToolRegistry.execute(name: "add_task", args: ["title": "Lauf", "category": "sport"], ctx: ctx)
      try expectEqual(r["ok"]?.boolValue, false, "unbekannte Kategorie abgewiesen")
      try expectEqual(r["error"]?.stringValue, TaskCategoryRules.unknownMessage("sport", in: TaskCategoryDef.builtIn),
                      "Meldung nennt die erlaubten Kategorien")
      try expectEqual(try store.tasks.list().count, 0, "keine Aufgabe angelegt")
    },
    CheckCase("Werkzeug: add_task und update_task mit bekannter Kategorie, leer = keine") {
      let store = try categoryStore()
      _ = try store.settings.update(SettingsPatch(taskCategories: TaskCategoryDef.builtIn + [def("sport", "Sport")]))
      let ctx = ToolContext(store: store, mode: .standard)
      let added = await ToolRegistry.execute(name: "add_task", args: ["title": "Lauf", "category": "SPORT"], ctx: ctx)
      try expectEqual(added["ok"]?.boolValue, true, "bekannte Kategorie (Groß/Klein egal)")
      let id = added["task"]?["id"]?.stringValue ?? ""
      try expectEqual(try store.tasks.get(id)?.category, TaskCategory(rawValue: "sport"), "Kategorie gespeichert")
      let cleared = await ToolRegistry.execute(name: "update_task", args: ["id": .string(id), "category": ""], ctx: ctx)
      try expectEqual(cleared["ok"]?.boolValue, true, "leer = keine Kategorie")
      try expectEqual(try store.tasks.get(id)?.category, nil, "Kategorie entfernt")
      let bad = await ToolRegistry.execute(name: "update_task", args: ["id": .string(id), "category": "nope"], ctx: ctx)
      try expectEqual(bad["ok"]?.boolValue, false, "unbekannte Kategorie bei update_task abgewiesen")
      try expect((bad["error"]?.stringValue ?? "").contains("Arbeit (arbeit), Privat (privat)"), "Meldung nennt die Liste")
    },
    CheckCase("Werkzeug: list_tasks filtert nach Kategorie") {
      let store = try categoryStore()
      _ = try store.settings.update(SettingsPatch(taskCategories: TaskCategoryDef.builtIn + [def("sport", "Sport")]))
      _ = try store.tasks.add(title: "Büro", category: TaskCategory(rawValue: "arbeit"))
      _ = try store.tasks.add(title: "Lauf", category: TaskCategory(rawValue: "sport"))
      let ctx = ToolContext(store: store, mode: .standard)
      let only = await ToolRegistry.execute(name: "list_tasks", args: ["category": "sport"], ctx: ctx)
      let titles = (only["tasks"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
      try expectEqual(titles, ["Lauf"], "nur Sport")
      let unknown = await ToolRegistry.execute(name: "list_tasks", args: ["category": "gibtsnicht"], ctx: ctx)
      try expectEqual(unknown["ok"]?.boolValue, false, "unbekannter Filter wird abgewiesen")
    },
    CheckCase("Werkzeug: gleicher Ordnername in zwei Kategorien, die Kategorie der Aufgabe entscheidet") {
      let store = try categoryStore()
      _ = try store.taskFolders.add(name: "Plan", categoryId: "arbeit")
      let privat = try store.taskFolders.add(name: "Plan", categoryId: "privat")
      let ctx = ToolContext(store: store, mode: .standard)
      let added = await ToolRegistry.execute(name: "add_task",
                                             args: ["title": "Urlaub buchen", "category": "privat", "folder": "plan"], ctx: ctx)
      try expectEqual(added["ok"]?.boolValue, true, "Ordner aus der Kategorie der Aufgabe")
      let id = added["task"]?["id"]?.stringValue ?? ""
      try expectEqual(try store.tasks.get(id)?.folderId, privat.id, "Ordner der Kategorie privat")
      let ambiguous = await ToolRegistry.execute(name: "add_task", args: ["title": "Ohne Kategorie", "folder": "Plan"], ctx: ctx)
      try expectEqual(ambiguous["ok"]?.boolValue, false, "ohne Kategorie ist der Name mehrdeutig")
    },
    CheckCase("Werkzeug: get_overview nennt die Kategorien in einer Zeile") {
      let ctx = ToolContext(store: try categoryStore(), mode: .standard)
      let r = await ToolRegistry.execute(name: "get_overview", args: [:], ctx: ctx)
      try expectEqual(r["kategorien"]?.stringValue, "Arbeit (arbeit), Privat (privat)", "Kategorien-Zeile")
    },
  ]
}
