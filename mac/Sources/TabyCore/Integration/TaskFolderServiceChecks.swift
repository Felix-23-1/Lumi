// Prüfungen für Aufgaben-Ordner am Kern (CoreServices): Validierung, Meldungen,
// updateTask-Zuordnung und Zustand. Speicher im Arbeitsspeicher, Uhr steuerbar.
import Foundation

extension ToolResult {
  /// Fehlercode eines Fehlschlags (nil bei Erfolg).
  var errorCode: String? { if case .failure(let code, _) = self { return code }; return nil }
}

@MainActor
enum TaskFolderServiceChecks {
  static func rig() throws -> CoreServices {
    let opts = CoreServices.Options(databasePath: nil, socketPath: nil,
                                    clock: ControllableClock("2026-10-12T08:00"), keyStore: InMemoryApiKeyStore(),
                                    systemNotifier: SinkNotifier(), plannerInterval: nil)
    return try CoreServices(options: opts)
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Ordner-Kern: Name wird getrimmt, Zustand enthält den Ordner") {
        let svc = try rig()
        let r = await svc.addTaskFolder(name: "  Arbeit  ")
        try expectEqual(r.value?.name, "Arbeit", "getrimmter Name")
        let names = (await svc.state()).taskFolders.map(\.name)
        try expectEqual(names, ["Arbeit"], "AppState führt den Ordner")
      },
      CheckCase("Ordner-Kern: leerer oder zu langer Name wird abgewiesen") {
        let svc = try rig()
        let empty = await svc.addTaskFolder(name: "   ")
        try expectEqual(empty.errorMessage, "Ordnername fehlt oder ist zu lang.", "leer")
        let long = await svc.addTaskFolder(name: String(repeating: "x", count: 61))
        try expectEqual(long.errorMessage, "Ordnername fehlt oder ist zu lang.", "61 Zeichen")
        let max = await svc.addTaskFolder(name: String(repeating: "x", count: 60))
        try expect(max.isOk, "60 Zeichen sind erlaubt")
      },
      CheckCase("Ordner-Kern: doppelter Name (Groß/Klein egal) wird abgewiesen") {
        let svc = try rig()
        _ = await svc.addTaskFolder(name: "Arbeit")
        let dup = await svc.addTaskFolder(name: "arbeit")
        try expectEqual(dup.errorMessage, "Diesen Ordner gibt es schon.", "Dublette")
        let other = await svc.addTaskFolder(name: "Privat")
        let folder = other.value!
        let clash = await svc.renameTaskFolder(folder.id, name: "ARBEIT")
        try expectEqual(clash.errorMessage, "Diesen Ordner gibt es schon.", "Umbenennen auf vorhandenen Namen")
        let same = await svc.renameTaskFolder(folder.id, name: "privat")
        try expect(same.isOk, "Umbenennen nur in Schreibweise ist erlaubt")
      },
      CheckCase("Ordner-Kern: unbekannte Ordner-ID meldet Ordner nicht gefunden") {
        let svc = try rig()
        let r = await svc.renameTaskFolder("gibt-es-nicht", name: "Neu")
        try expectEqual(r.errorMessage, "Ordner nicht gefunden.", "umbenennen")
        let d = await svc.deleteTaskFolder("gibt-es-nicht")
        try expectEqual(d.errorMessage, "Ordner nicht gefunden.", "löschen")
        let task = await svc.addTask(title: "X", notes: nil, due: nil).value!
        let u = await svc.updateTask(task.id, TaskPatch(folderId: "gibt-es-nicht"))
        try expectEqual(u.errorMessage, "Ordner nicht gefunden.", "updateTask mit unbekannter ID")
      },
      CheckCase("Ordner-Kern: updateTask setzt, entfernt und Löschen behält die Aufgabe") {
        let svc = try rig()
        let folder = await svc.addTaskFolder(name: "Haus").value!
        let task = await svc.addTask(title: "Dach", notes: nil, due: nil).value!
        let set = await svc.updateTask(task.id, TaskPatch(folderId: folder.id))
        try expectEqual(set.value?.folderId, folder.id, "Ordner gesetzt")
        let deleted = await svc.deleteTaskFolder(folder.id)
        try expect(deleted.isOk, "Ordner gelöscht")
        let state = await svc.state()
        try expectEqual(state.taskFolders.count, 0, "Ordner aus dem Zustand entfernt")
        let kept = state.tasks.first { $0.id == task.id }
        try expectEqual(kept?.title, "Dach", "Aufgabe bleibt")
        try expectEqual(kept?.folderId, nil, "Aufgabe ohne Ordner")
        let again = await svc.updateTask(task.id, TaskPatch(folderId: folder.id))
        try expectEqual(again.errorMessage, "Ordner nicht gefunden.", "gelöschter Ordner ist nicht mehr zuweisbar")
        _ = await svc.addTaskFolder(name: "Auto")
        let auto = (await svc.state()).taskFolders.first!
        _ = await svc.updateTask(task.id, TaskPatch(folderId: auto.id))
        let cleared = await svc.updateTask(task.id, TaskPatch(folderId: ""))
        try expectEqual(cleared.value?.folderId, nil, "leer = aus dem Ordner nehmen")
      },
      CheckCase("Ordner-Kern: gleicher Name in zwei Kategorien ok, in einer Kategorie abgewiesen") {
        let svc = try rig()
        let inArbeit = await svc.addTaskFolder(name: "Plan", categoryId: "arbeit")
        let inPrivat = await svc.addTaskFolder(name: "Plan", categoryId: "privat")
        try expect(inArbeit.isOk && inPrivat.isOk, "Plan in Arbeit und in Privat")
        let dup = await svc.addTaskFolder(name: "PLAN", categoryId: "arbeit")
        try expectEqual(dup.errorCode, "DUPLICATE", "zweiter Plan in Arbeit abgewiesen")
      },
      CheckCase("Ordner-Kern: unbekannte Kategorie nennt die erlaubten Kennungen") {
        let svc = try rig()
        let r = await svc.addTaskFolder(name: "Training", categoryId: "sport")
        try expectEqual(r.errorMessage, "Kategorie \"sport\" gibt es nicht. Erlaubt: Arbeit (arbeit), Privat (privat) (oder \"\" für keine Kategorie).",
                        "Meldung mit Liste")
        let kept = await svc.addTaskFolder(name: "Training", categoryId: "")
        try expectEqual(kept.value?.categoryId, nil, "leer = keine Kategorie")
      },
      CheckCase("Ordner-Kern: Kategorie ändern, Namenskonflikt, Rückgängig") {
        let svc = try rig()
        _ = await svc.updateSettings(SettingsPatch(taskCategories: TaskCategoryDef.builtIn + [TaskCategoryDef(id: "sport", name: "Sport", symbol: "figure.run")]), apiKey: nil)
        let plan = await svc.addTaskFolder(name: "Plan").value!
        let moved = await svc.setTaskFolderCategory(plan.id, categoryId: "sport")
        try expectEqual(moved.value?.categoryId, "sport", "Kategorie gesetzt")
        let unknown = await svc.setTaskFolderCategory(plan.id, categoryId: "gibtsnicht")
        try expectEqual(unknown.errorCode, "VALIDATION", "unbekannte Kategorie abgewiesen")
        _ = await svc.addTaskFolder(name: "Plan", categoryId: "arbeit")
        let clash = await svc.setTaskFolderCategory(plan.id, categoryId: "arbeit")
        try expectEqual(clash.errorCode, "DUPLICATE", "Name in Arbeit schon belegt")
        let undone = await svc.undoLast()
        try expect(undone.isOk, "Rückgängig des Kategorie-Wechsels")
        let back = (await svc.state()).taskFolders.first { $0.id == plan.id }
        try expectEqual(back?.categoryId, nil, "vorherige Kategorie (keine) wiederhergestellt")
        let removed = await svc.setTaskFolderCategory(plan.id, categoryId: "")
        try expectEqual(removed.value?.categoryId, nil, "leer = keine Kategorie")
      },
    ]
  }
}
