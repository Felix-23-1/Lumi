// Prüfungen für Aufgaben-Ordner im Speicher und im Werkzeugbereich: Migration,
// Repository (Name, Eindeutigkeit, Löschen) und update_task/add_task/list_tasks mit `folder`.
import Foundation

private func folderCtx() throws -> ToolContext {
  ToolContext(store: try Store.inMemory(clock: ControllableClock("2024-03-04T08:00")), mode: .standard)
}

private func folderRun(_ name: String, _ args: JSONValue, _ ctx: ToolContext) async -> JSONValue {
  await ToolRegistry.execute(name: name, args: args, ctx: ctx)
}

extension StoreChecks {
  static let taskFolderChecks: [CheckCase] = [
    CheckCase("Ordner-Migration: bestehende Aufgaben bleiben, Spalte und Tabelle kommen dazu") {
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      let task = try store.tasks.add(title: "Alt")
      // Schema auf den Stand vor Migration 21 zurückbauen, dann neu migrieren.
      try store.db.execute("""
        DROP TABLE task_folders;
        ALTER TABLE tasks DROP COLUMN folder_id;
        DELETE FROM schema_migrations WHERE version IN (21, 30);
        """)
      try Migrations.migrate(store.db, clock: clock)
      try expect(try store.db.appliedMigrations().contains(21), "Migration 21 nicht eingetragen")
      try expect(try store.db.appliedMigrations().contains(30), "Migration 30 nicht eingetragen")
      let kept = try store.tasks.get(task.id)
      try expectEqual(kept?.title, "Alt", "bestehende Aufgabe fehlt nach Migration")
      try expectEqual(kept?.folderId, nil, "folderId muss für alte Aufgaben nil sein")
      try expectEqual(try store.taskFolders.list(), [], "neue Ordner-Tabelle muss leer starten")
    },
    CheckCase("Ordner-Migration 30: bestehende Ordner bleiben ohne Kategorie") {
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      let folder = try store.taskFolders.add(name: "Alt")
      try store.db.execute("""
        DROP INDEX task_folders_category_name;
        ALTER TABLE task_folders DROP COLUMN category_id;
        CREATE UNIQUE INDEX task_folders_name_nocase ON task_folders (name COLLATE NOCASE);
        DELETE FROM schema_migrations WHERE version = 30;
        """)
      try Migrations.migrate(store.db, clock: clock)
      let kept = try store.taskFolders.get(folder.id)
      try expectEqual(kept?.name, "Alt", "Ordner bleibt erhalten")
      try expectEqual(kept?.categoryId, nil, "bestehender Ordner hat keine Kategorie")
      _ = try store.taskFolders.add(name: "Alt", categoryId: "sport")
      try expectEqual(try store.taskFolders.list().count, 2, "gleicher Name in anderer Kategorie")
    },
    CheckCase("Ordner-Repository: gleicher Name in zwei Kategorien ok, in einer Kategorie abgewiesen") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.taskFolders.add(name: "Plan", categoryId: "arbeit")
      _ = try store.taskFolders.add(name: "Plan", categoryId: "privat")
      _ = try store.taskFolders.add(name: "Plan")
      try expectEqual(try store.taskFolders.list().count, 3, "drei Ordner mit gleichem Namen in verschiedenen Kategorien")
      var threw = false
      do { _ = try store.taskFolders.add(name: "PLAN", categoryId: "arbeit") } catch { threw = true }
      try expect(threw, "gleicher Name (andere Schreibweise) in derselben Kategorie muss scheitern")
      try expectEqual(try store.taskFolders.find(name: "plan", categoryId: "privat")?.categoryId, "privat",
                      "Suche liefert den Ordner der Kategorie")
    },
    CheckCase("Ordner-Repository: Kategorie setzen und entfernen") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let folder = try store.taskFolders.add(name: "Training", categoryId: "sport")
      try expectEqual(try store.taskFolders.setCategory(folder.id, categoryId: "privat")?.categoryId, "privat",
                      "Kategorie gesetzt")
      try expectEqual(try store.taskFolders.setCategory(folder.id, categoryId: nil)?.categoryId, nil,
                      "Kategorie entfernt")
      try expectEqual(try store.taskFolders.setCategory("gibt-es-nicht", categoryId: "privat")?.id, nil,
                      "unbekannter Ordner")
    },
    CheckCase("Ordner-Repository: anlegen, sortiert listen, umbenennen") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.taskFolders.add(name: "bravo")
      _ = try store.taskFolders.add(name: "Alpha")
      try expectEqual(try store.taskFolders.list().map(\.name), ["Alpha", "bravo"], "Sortierung Groß/Klein egal")
      let alpha = try store.taskFolders.find(name: "ALPHA", categoryId: nil)
      try expectNotNil(alpha, "Suche ohne Groß/Klein")
      let renamed = try store.taskFolders.rename(alpha!.id, name: "Anker")
      try expectEqual(renamed?.name, "Anker", "umbenannt")
      try expectEqual(try store.taskFolders.find(name: "alpha", categoryId: nil), nil, "alter Name ist weg")
    },
    CheckCase("Ordner-Repository: Namen sind eindeutig ohne Groß/Klein") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.taskFolders.add(name: "Arbeit")
      var threw = false
      do { _ = try store.taskFolders.add(name: "ARBEIT") } catch { threw = true }
      try expect(threw, "zweiter Ordner mit gleichem Namen (andere Schreibweise) muss scheitern")
    },
    CheckCase("Ordner-Repository: Löschen behält Aufgaben ohne Ordner") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let folder = try store.taskFolders.add(name: "Projekt")
      let task = try store.tasks.add(title: "Angebot", folderId: folder.id)
      try expectEqual(try store.tasks.get(task.id)?.folderId, folder.id, "Aufgabe liegt im Ordner")
      try expect(try store.taskFolders.delete(folder.id), "Löschen meldet Erfolg")
      try expectEqual(try store.taskFolders.get(folder.id), nil, "Ordner weg")
      let after = try store.tasks.get(task.id)
      try expectEqual(after?.title, "Angebot", "Aufgabe bleibt")
      try expectEqual(after?.folderId, nil, "Aufgabe ist ohne Ordner")
    },
    CheckCase("Werkzeug: add_task mit folder, list_tasks zeigt den Ordnernamen") {
      let ctx = try folderCtx()
      _ = try ctx.store.taskFolders.add(name: "Steuer")
      let added = await folderRun("add_task", ["title": "Belege sortieren", "folder": "steuer"], ctx)
      try expectEqual(added["ok"]?.boolValue, true, "add_task mit Ordnernamen (Groß/Klein egal)")
      let listed = await folderRun("list_tasks", [:], ctx)
      let first = listed["tasks"]?.arrayValue?.first
      try expectEqual(first?["folder"]?.stringValue, "Steuer", "list_tasks nennt den Ordner")
      try expectEqual(first?["folderId"], nil, "interne Ordner-ID wird nicht ausgegeben")
    },
    CheckCase("Werkzeug: update_task setzt und entfernt den Ordner über den Namen") {
      let ctx = try folderCtx()
      _ = try ctx.store.taskFolders.add(name: "Haus")
      let task = try ctx.store.tasks.add(title: "Dach")
      let set = await folderRun("update_task", ["id": .string(task.id), "folder": "HAUS"], ctx)
      try expectEqual(set["ok"]?.boolValue, true, "update_task setzt Ordner")
      try expect(try ctx.store.tasks.get(task.id)?.folderId != nil, "Ordner-ID gespeichert")
      let cleared = await folderRun("update_task", ["id": .string(task.id), "folder": ""], ctx)
      try expectEqual(cleared["ok"]?.boolValue, true, "update_task mit leerem Ordner")
      try expectEqual(try ctx.store.tasks.get(task.id)?.folderId, nil, "leer = aus dem Ordner nehmen")
    },
    CheckCase("Werkzeug: unbekannter Ordnername nennt die vorhandenen Ordner") {
      let ctx = try folderCtx()
      _ = try ctx.store.taskFolders.add(name: "Alpha")
      _ = try ctx.store.taskFolders.add(name: "Beta")
      let task = try ctx.store.tasks.add(title: "X")
      let r = await folderRun("update_task", ["id": .string(task.id), "folder": "Gamma"], ctx)
      try expectEqual(r["ok"]?.boolValue, false, "unbekannter Ordner scheitert")
      let msg = r["error"]?.stringValue ?? ""
      try expect(msg.contains("Alpha") && msg.contains("Beta"), "Fehler nennt vorhandene Ordner: \(msg)")
      try expectEqual(try ctx.store.tasks.get(task.id)?.folderId, nil, "Aufgabe unverändert")
    },
    CheckCase("Werkzeug: es gibt kein Werkzeug zum Löschen von Ordnern") {
      let names = ToolRegistry.definitions.map(\.name)
      try expect(!names.contains { $0.contains("folder") && $0.contains("delete") }, "kein Lösch-Werkzeug für Ordner")
    },
  ]
}
