// Prüfungen für die Zuordnung Notiz → Aufgabe: Migration behält Notizen, Verknüpfen
// und Lösen, Löschen der Aufgabe lässt Notizen stehen, Werkzeuge add_note/update_note/
// list_notes und CoreServices.updateNote (Fehlertext bei unbekannter Aufgabe).
import Foundation

private func noteTaskCtx(_ now: String = "2024-03-04T08:00") throws -> (ToolContext, Store) {
  let store = try Store.inMemory(clock: ControllableClock(now))
  return (ToolContext(store: store, mode: .standard), store)
}

extension StoreChecks {
  static let noteTaskChecks: [CheckCase] = [
    CheckCase("Migration 23: bestehende Notizen bleiben beim Nachziehen der Spalte erhalten") {
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      let note = try store.notes.add(title: "Einkauf", content: "Milch")
      try store.db.execute("DROP INDEX notes_task_id; ALTER TABLE notes DROP COLUMN task_id;")
      try store.db.run("DELETE FROM schema_migrations WHERE version = 23")
      try Migrations.migrate(store.db, clock: clock)
      let kept = try expectNotNil(try store.notes.get(note.id))
      try expectEqual(kept.title, "Einkauf")
      try expectEqual(kept.content, "Milch")
      try expectEqual(kept.taskId, nil)
    },
    CheckCase("Notiz verknüpfen und lösen per NotePatch (\"\" = lösen)") {
      let (_, store) = try noteTaskCtx()
      let task = try store.tasks.add(title: "Steuer machen")
      let note = try store.notes.add(title: "Belege", content: "Quittungen")
      _ = try store.notes.update(note.id, NotePatch(taskId: task.id))
      try expectEqual(try store.notes.get(note.id)?.taskId, task.id)
      try expectEqual(try store.notes.list(taskId: task.id).map(\.id), [note.id])
      _ = try store.notes.update(note.id, NotePatch(title: "Belege 2024"))
      try expectEqual(try store.notes.get(note.id)?.taskId, task.id, "nil im Patch lässt die Zuordnung")
      _ = try store.notes.update(note.id, NotePatch(taskId: ""))
      try expectEqual(try store.notes.get(note.id)?.taskId, nil)
    },
    CheckCase("Aufgabe löschen: Notizen bleiben, nur die Zuordnung wird gelöst") {
      let (_, store) = try noteTaskCtx()
      let task = try store.tasks.add(title: "Umzug")
      let note = try store.notes.add(title: "Kisten", content: "Küche", taskId: task.id)
      _ = try store.tasks.delete(task.id)
      let kept = try expectNotNil(try store.notes.get(note.id))
      try expectEqual(kept.content, "Küche")
      try expectEqual(kept.taskId, nil)
    },
    CheckCase("Werkzeug add_note: Aufgabe per Titel zuordnen, unbekannte Aufgabe scheitert") {
      let (ctx, store) = try noteTaskCtx()
      let task = try store.tasks.add(title: "Geschenk kaufen")
      _ = await ToolRegistry.execute(name: "add_note", args: .object([
        "title": .string("Ideen"), "content": .string("Buch"), "task": .string("Geschenk kaufen"),
      ]), ctx: ctx)
      try expectEqual(try store.notes.list().first?.taskId, task.id)
      let bad = await ToolRegistry.execute(name: "add_note", args: .object([
        "title": .string("X"), "content": .string("Y"), "task": .string("gibt-es-nicht"),
      ]), ctx: ctx)
      guard case .object(let o) = bad, o["ok"] == .bool(false) else {
        throw CheckFailure(message: "unbekannte Aufgabe muss scheitern", location: "add_note")
      }
      try expectEqual(try store.notes.list().count, 1, "fehlgeschlagen = keine Notiz")
    },
    CheckCase("Werkzeug update_note: task setzen und mit \"\" lösen; list_notes zeigt den Aufgabentitel") {
      let (ctx, store) = try noteTaskCtx()
      let task = try store.tasks.add(title: "Arzt anrufen")
      let note = try store.notes.add(title: "Termin", content: "Di")
      _ = await ToolRegistry.execute(name: "update_note", args: .object(["id": .string(note.id), "task": .string(task.id)]), ctx: ctx)
      try expectEqual(try store.notes.get(note.id)?.taskId, task.id)
      guard case .object(let listed) = await ToolRegistry.execute(name: "list_notes", args: .object([:]), ctx: ctx),
            case .array(let notes)? = listed["notes"], case .object(let first)? = notes.first else {
        throw CheckFailure(message: "list_notes ohne Notizen", location: "list_notes")
      }
      try expectEqual(first["task_title"], .string("Arzt anrufen"))
      _ = await ToolRegistry.execute(name: "update_note", args: .object(["id": .string(note.id), "task": .string("")]), ctx: ctx)
      try expectEqual(try store.notes.get(note.id)?.taskId, nil)
    },
    CheckCase("CoreServices.updateNote: unbekannte Aufgabe meldet \"Aufgabe nicht gefunden.\"") { @MainActor in
      let r = try IntegrationRig()
      guard case .ok(let note) = await r.svc.addNote(title: "A", content: "B"),
            case .ok(let task) = await r.svc.addTask(title: "Aufgabe X", notes: nil, due: nil) else {
        throw CheckFailure(message: "Notiz oder Aufgabe nicht angelegt", location: "CoreServices")
      }
      guard case .failure(_, let msg) = await r.svc.updateNote(note.id, NotePatch(taskId: "gibt-es-nicht")) else {
        throw CheckFailure(message: "unbekannte Aufgabe muss scheitern", location: "updateNote")
      }
      try expectEqual(msg, "Aufgabe nicht gefunden.")
      guard case .ok(let linked) = await r.svc.updateNote(note.id, NotePatch(taskId: task.id)) else {
        throw CheckFailure(message: "Verknüpfen scheitert", location: "updateNote")
      }
      try expectEqual(linked.taskId, task.id)
      guard case .ok(let unlinked) = await r.svc.updateNote(note.id, NotePatch(taskId: "")) else {
        throw CheckFailure(message: "Lösen scheitert", location: "updateNote")
      }
      try expectEqual(unlinked.taskId, nil)
    },
  ]
}
