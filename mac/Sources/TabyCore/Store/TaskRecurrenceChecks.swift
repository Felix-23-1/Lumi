// Prüfungen für wiederholte Aufgaben: Fälligkeitsrechnung (Monatsende, Wochenende,
// Nachholen vergangener Fälligkeiten), Repository (Erledigen legt die nächste an)
// und die Werkzeuge add_task/update_task mit `recurrence`.
import Foundation

private func recCtx(_ now: String = "2024-03-04T08:00") throws -> (ToolContext, Store) {
  let store = try Store.inMemory(clock: ControllableClock(now))
  return (ToolContext(store: store, mode: .standard), store)
}

extension StoreChecks {
  static let recurrenceChecks: [CheckCase] = [
    CheckCase("Wiederholung täglich: nächster Tag, Uhrzeit bleibt") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-04T15:30", .daily, today: "2024-03-04"),
                      "2024-03-05T15:30")
    },
    CheckCase("Wiederholung ohne Fälligkeit: Basis ist heute") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: nil, .daily, today: "2024-03-04"), "2024-03-05")
    },
    CheckCase("Wiederholung wöchentlich: +7 Tage") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-04", .weekly, today: "2024-03-04"), "2024-03-11")
    },
    CheckCase("Wiederholung werktags: Freitag springt auf Montag") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-08", .weekdays, today: "2024-03-08"), "2024-03-11")
    },
    CheckCase("Wiederholung werktags: Samstag springt auf Montag") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-09", .weekdays, today: "2024-03-09"), "2024-03-11")
    },
    CheckCase("Wiederholung werktags: Donnerstag geht auf Freitag") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-07", .weekdays, today: "2024-03-07"), "2024-03-08")
    },
    CheckCase("Wiederholung monatlich: gleicher Tag im Folgemonat") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-15", .monthly, today: "2024-03-15"), "2024-04-15")
    },
    CheckCase("Wiederholung monatlich: Jahreswechsel") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-12-15", .monthly, today: "2024-12-15"), "2025-01-15")
    },
    CheckCase("Wiederholung monatlich: 31. wird im Februar auf 29. (Schaltjahr) gekürzt") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-01-31", .monthly, today: "2024-01-31"), "2024-02-29")
    },
    CheckCase("Wiederholung monatlich: 31. wird im Februar auf 28. gekürzt") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2023-01-31", .monthly, today: "2023-01-31"), "2023-02-28")
    },
    CheckCase("Wiederholung monatlich: 31. März geht auf 30. April") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-03-31", .monthly, today: "2024-03-31"), "2024-04-30")
    },
    CheckCase("Wiederholung: vergangene Fälligkeit wird bis heute nachgeholt (täglich landet auf heute)") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-02-01", .daily, today: "2024-03-04"), "2024-03-04")
    },
    CheckCase("Wiederholung wöchentlich: genau heute fällig bleibt heute") {
      // 2024-01-01 + 9 Wochen = 2024-03-04
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-01-01", .weekly, today: "2024-03-04"), "2024-03-04")
    },
    CheckCase("Wiederholung werktags: vergangene Fälligkeit rollt bis heute vor") {
      try expectEqual(TaskRecurrenceMath.nextDue(old: "2024-01-05", .weekdays, today: "2024-03-04"), "2024-03-04")
    },
    CheckCase("Erledigen: wiederholte Aufgabe legt die nächste mit gleichen Feldern an") {
      let (_, store) = try recCtx()
      let folder = try store.taskFolders.add(name: "Haus")
      let first = try store.tasks.add(title: "Müll", notes: "gelbe Tonne", due: "2024-03-04T18:00",
                                      folderId: folder.id, category: .privat, recurrence: .weekly)
      _ = try store.tasks.complete(first.id)
      let all = try store.tasks.list()
      try expectEqual(all.count, 2, "eine neue Aufgabe muss entstehen")
      let next = try expectNotNil(all.first { $0.id != first.id })
      try expectEqual(next.title, "Müll")
      try expectEqual(next.notes, "gelbe Tonne")
      try expectEqual(next.folderId, folder.id)
      try expectEqual(next.category, .privat)
      try expectEqual(next.recurrence, .weekly)
      try expectEqual(next.due, "2024-03-11T18:00")
      try expect(!next.done, "die nächste ist offen")
    },
    CheckCase("Erledigen: zweimal erledigt legt nur eine nächste Aufgabe an") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Post", due: "2024-03-04", recurrence: .daily)
      _ = try store.tasks.complete(task.id)
      _ = try store.tasks.complete(task.id)
      try expectEqual(try store.tasks.list().count, 2, "keine doppelte Folgeaufgabe")
    },
    CheckCase("Erledigen: ohne Wiederholung entsteht keine neue Aufgabe") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Einmal", due: "2024-03-04")
      _ = try store.tasks.complete(task.id)
      try expectEqual(try store.tasks.list().count, 1, "keine Folgeaufgabe ohne Wiederholung")
    },
    CheckCase("Rückgängig: bearbeitete oder kommentierte Folgeaufgabe bleibt stehen") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Post", due: "2024-03-04", recurrence: .daily)
      _ = try store.tasks.complete(task.id)
      let next = try expectNotNil(try store.tasks.list().first(where: { $0.id != task.id }))
      _ = try store.tasks.update(next.id, title: "Post neu")
      _ = try store.tasks.reopen(task.id)
      try expectEqual(try store.tasks.list().count, 2, "umbenannte Folgeaufgabe bleibt")
      let trash = try store.tasks.add(title: "Müll", due: "2024-03-04", recurrence: .daily)
      _ = try store.tasks.complete(trash.id)
      let moved = try expectNotNil(try store.tasks.list().first(where: { $0.title == "Müll" && $0.id != trash.id }))
      _ = try store.tasks.update(moved.id, due: .set("2024-03-20"))
      _ = try store.tasks.reopen(trash.id)
      try expectEqual(try store.tasks.list().filter { $0.title == "Müll" }.count, 2, "verschobene Folgeaufgabe bleibt")
      let noted = try store.tasks.add(title: "Pflanzen", due: "2024-03-04", recurrence: .weekly)
      _ = try store.tasks.complete(noted.id)
      let withNote = try expectNotNil(try store.tasks.list().first(where: { $0.title == "Pflanzen" && $0.id != noted.id }))
      _ = try store.notes.add(title: "Notiz", content: "Gießen", taskId: withNote.id)
      _ = try store.tasks.reopen(noted.id)
      try expectEqual(try store.tasks.list().filter { $0.title == "Pflanzen" }.count, 2, "Folgeaufgabe mit Notiz bleibt")
    },
    CheckCase("Erledigen: wieder öffnen und erneut erledigen legt keine zweite Folgeaufgabe an") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Post", due: "2024-03-04", recurrence: .daily)
      _ = try store.tasks.complete(task.id)
      _ = try store.tasks.reopen(task.id)
      try expectEqual(try store.tasks.list().count, 1, "offene Folgeaufgabe beim Wieder-Öffnen entfernt")
      _ = try store.tasks.complete(task.id)
      try expectEqual(try store.tasks.list().count, 2, "genau eine Folgeaufgabe")
      _ = try store.tasks.complete(task.id)
      try expectEqual(try store.tasks.list().count, 2, "doppeltes Erledigen legt nichts dazu")
    },
    CheckCase("Erledigen: erledigte Folgeaufgabe bleibt beim Wieder-Öffnen, keine neue daneben") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Müll", due: "2024-03-04", recurrence: .daily)
      _ = try store.tasks.complete(task.id)
      let next = try expectNotNil(try store.tasks.list().first(where: { $0.id != task.id }))
      _ = try store.tasks.complete(next.id)  // legt die übernächste an
      try expectEqual(try store.tasks.list().count, 3, "drei Aufgaben nach zwei Erledigungen")
      _ = try store.tasks.reopen(task.id)
      _ = try store.tasks.complete(task.id)
      try expectEqual(try store.tasks.list().count, 3, "keine zweite Folgeaufgabe")
    },
    CheckCase("Patch: recurrence setzen und mit \"\" wieder entfernen") {
      let (_, store) = try recCtx()
      let task = try store.tasks.add(title: "Sport")
      let set = try expectNotNil(try store.tasks.update(task.id, TaskPatch(recurrence: "monthly")))
      try expectEqual(set.recurrence, .monthly)
      let cleared = try expectNotNil(try store.tasks.update(task.id, TaskPatch(recurrence: "")))
      try expectEqual(cleared.recurrence, nil)
      let untouched = try expectNotNil(try store.tasks.update(task.id, TaskPatch(title: "Sport 2")))
      try expectEqual(untouched.recurrence, nil, "nil im Patch lässt die Wiederholung unverändert")
    },
    CheckCase("Werkzeug add_task: \"täglich\" und \"werktags\" werden gespeichert") {
      let (ctx, store) = try recCtx()
      _ = await ToolRegistry.execute(name: "add_task", args: .object(["title": .string("A"), "recurrence": .string("täglich")]), ctx: ctx)
      _ = await ToolRegistry.execute(name: "add_task", args: .object(["title": .string("B"), "recurrence": .string("werktags")]), ctx: ctx)
      let all = try store.tasks.list()
      try expectEqual(all.first { $0.title == "A" }?.recurrence, .daily)
      try expectEqual(all.first { $0.title == "B" }?.recurrence, .weekdays)
    },
    CheckCase("Werkzeug update_task: Wiederholung setzen, \"\" entfernt, ungültig wird abgelehnt") {
      let (ctx, store) = try recCtx()
      let task = try store.tasks.add(title: "Rechnung")
      _ = await ToolRegistry.execute(name: "update_task", args: .object(["id": .string(task.id), "recurrence": .string("monatlich")]), ctx: ctx)
      try expectEqual(try store.tasks.get(task.id)?.recurrence, .monthly)
      let bad = await ToolRegistry.execute(name: "update_task", args: .object(["id": .string(task.id), "recurrence": .string("jährlich")]), ctx: ctx)
      guard case .object(let o) = bad, o["ok"] == .bool(false) else { throw CheckFailure(message: "ungültige Wiederholung muss scheitern", location: "recurrence") }
      try expectEqual(try store.tasks.get(task.id)?.recurrence, .monthly, "ungültiger Wert ändert nichts")
      _ = await ToolRegistry.execute(name: "update_task", args: .object(["id": .string(task.id), "recurrence": .string("")]), ctx: ctx)
      try expectEqual(try store.tasks.get(task.id)?.recurrence, nil)
    },
    CheckCase("Dauer: add_task/update_task speichern Minuten, 0/null/ungültig/Patch 0 räumen oder lehnen ab") {
      let (ctx, store) = try recCtx()
      _ = await ToolRegistry.execute(name: "add_task", args: .object(["title": .string("Plan"), "minutes": .number(45)]), ctx: ctx)
      let task = try expectNotNil(try store.tasks.list().first)
      try expectEqual(task.minutes, 45)
      let bad = await ToolRegistry.execute(name: "update_task", args: .object(["id": .string(task.id), "minutes": .number(0)]), ctx: ctx)
      guard case .object(let o) = bad, o["ok"] == .bool(false) else { throw CheckFailure(message: "0 Minuten muss scheitern", location: "minutes") }
      try expectEqual(try store.tasks.get(task.id)?.minutes, 45, "ungültig ändert nichts")
      let kept = try expectNotNil(try store.tasks.update(task.id, TaskPatch(title: "Plan 2")))
      try expectEqual(kept.minutes, 45, "nil im Patch lässt die Dauer")
      let cleared = try expectNotNil(try store.tasks.update(task.id, TaskPatch(minutes: 0)))
      try expectEqual(cleared.minutes, nil, "Patch 0 entfernt die Dauer")
      let set = try expectNotNil(try store.tasks.update(task.id, TaskPatch(minutes: 90)))
      try expectEqual(set.minutes, 90)
    },
    CheckCase("Kennzeichen: bereinigt (#, Leerraum, Duplikate), an Aufgaben und Notizen gespeichert, Patch ersetzt, [] leert") {
      let (ctx, store) = try recCtx()
      try expectEqual(TagRules.normalize(["#Kunde X", "kunde-x", " ", "a,b", "##Angebot"]), ["Kunde-X", "ab", "Angebot"])
      let task = try store.tasks.add(title: "Plan", tags: ["#Kunde X"])
      try expectEqual(try store.tasks.get(task.id)?.tags, ["Kunde-X"])
      let note = try store.notes.add(title: "Idee", content: "x", tags: ["angebot"], meetingKey: "cal|1|2026-10-12T10:00")
      try expectEqual(try store.notes.get(note.id)?.tags, ["angebot"])
      try expectEqual(try store.notes.get(meetingKey: "cal|1|2026-10-12T10:00")?.id, note.id)
      _ = try store.tasks.update(task.id, TaskPatch(tags: ["neu", "Neu", "zwei"]))
      try expectEqual(try store.tasks.get(task.id)?.tags, ["neu", "zwei"], "Duplikate ohne Groß/Klein entfernt")
      _ = try store.tasks.update(task.id, TaskPatch(title: "Plan 2"))
      try expectEqual(try store.tasks.get(task.id)?.tags, ["neu", "zwei"], "nil lässt die Kennzeichen")
      _ = await ToolRegistry.execute(name: "update_task", args: .object(["id": .string(task.id), "tags": .array([])]), ctx: ctx)
      try expectEqual(try store.tasks.get(task.id)?.tags, [], "[] leert")
      _ = await ToolRegistry.execute(name: "add_note", args: .object(["title": .string("N"), "content": .string("c"),
                                                                       "tags": .array([.string("x")])]), ctx: ctx)
      try expectEqual(try store.notes.list().first { $0.title == "N" }?.tags, ["x"])
      let bad = await ToolRegistry.execute(name: "add_note", args: .object(["title": .string("M"), "content": .string("c"),
                                                                             "tags": .string("x")]), ctx: ctx)
      guard case .object(let o) = bad, o["ok"] == .bool(false) else { throw CheckFailure(message: "tags als Text muss scheitern", location: "tags") }
    },
  ]
}
