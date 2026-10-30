// Prüfungen für Sources/TabyCore/Reminders (Apple-Erinnerungen-Abgleich).
import Foundation

enum RemindersChecks {
  static let suite = CheckSuite("Reminders", [
    // MARK: Schutz gegen Massenlöschung

    CheckCase("Massenlöschung: leere Apple-Liste bei Verknüpfungen löscht nichts") {
      let (engine, backend, taskSide) = remindersFixture()
      taskSide.linkList = [rlink("T1", "R1", "Milch", due: "2026-10-12"), rlink("T2", "R2", "Brief", done: true)]
      backend.items = []
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report.deletedTask, 0)
      try expectEqual(report.errors, [ReminderSyncEngine.pausedMessage])
      try expectEqual(taskSide.store.count, 2, "Aufgaben bleiben erhalten")
      try expectEqual(taskSide.linkList.count, 2, "Verknüpfungen bleiben erhalten")
    },
    CheckCase("Massenlöschung: 1 fehlende von 10 wird gelöscht") {
      let backend = FakeRemindersBackend()
      let taskSide = FakeTaskSide()
      for i in 1...10 {
        backend.seed(ExternalReminder(id: "R\(i)", title: "E\(i)"))
        taskSide.store.append(rtask("T\(i)", "E\(i)"))
        taskSide.linkList.append(rlink("T\(i)", "R\(i)", "E\(i)"))
      }
      backend.items.removeAll { $0.id == "R3" }
      let report = try await ReminderSyncEngine(backend: backend, taskSide: taskSide).sync(listId: nil, now: rnow)
      try expectEqual(report.deletedTask, 0, "Aufgabe wird nie gelöscht")
      try expectEqual(report.removedFromApple, ["T3"], "Aufgabe bleibt offen, Verknüpfung bleibt")
      try expectEqual(report.errors, [])
      try expectEqual(taskSide.store.count, 10)
      try expectEqual(taskSide.linkList.count, 10, "Verknüpfung bleibt, damit nichts neu angelegt wird")
    },
    CheckCase("Abgleich: Apple gewinnt bei Konflikt und meldet die überschriebene Lumi-Änderung") {
      let backend = FakeRemindersBackend()
      let taskSide = FakeTaskSide()
      backend.seed(ExternalReminder(id: "R1", title: "Apple-Wert"))
      taskSide.store.append(rtask("T1", "Lumi-Wert"))
      taskSide.linkList.append(rlink("T1", "R1", "E1"))
      let report = try await ReminderSyncEngine(backend: backend, taskSide: taskSide).sync(listId: nil, now: rnow)
      try expectEqual(report.overwrittenLumiEdits, ["T1"])
      try expectEqual(taskSide.store.first?.title, "Apple-Wert", "Apple gewinnt")
    },
    CheckCase("Export: Aufgaben aus Notion gehen nie nach Apple") {
      let tasks = [rtask("N1", "Notion-Ticket"), rtask("T1", "Lokal")]
      let actions = ReminderSyncPlanner.plan(tasks: tasks, external: [], links: [], excludedTaskIds: ["N1"])
      try expectEqual(actions, [.createExternal(taskId: "T1")])
    },
    CheckCase("Massenlöschung: 5 in Apple fehlende Erinnerungen löschen keine Aufgabe und pausieren nicht") {
      let backend = FakeRemindersBackend()
      let taskSide = FakeTaskSide()
      for i in 1...10 {
        backend.seed(ExternalReminder(id: "R\(i)", title: "E\(i)"))
        taskSide.store.append(rtask("T\(i)", "E\(i)"))
        taskSide.linkList.append(rlink("T\(i)", "R\(i)", "E\(i)"))
      }
      backend.items.removeAll { ["R1", "R2", "R3", "R4", "R5"].contains($0.id) }
      let report = try await ReminderSyncEngine(backend: backend, taskSide: taskSide).sync(listId: nil, now: rnow)
      try expectEqual(report.deletedTask, 0)
      try expectEqual(report.errors, [], "kein Pausieren: deleteTask zählt nicht")
      try expectEqual(report.removedFromApple.count, 5, "Aufgaben bleiben offen")
      try expectEqual(taskSide.store.count, 10)
      try expectEqual(taskSide.linkList.count, 10)
    },
    CheckCase("Massenlöschung: 5 Aufgaben in Lumi fehlen → keine Erinnerung wird gelöscht") {
      let backend = FakeRemindersBackend()
      let taskSide = FakeTaskSide()
      for i in 1...10 {
        backend.seed(ExternalReminder(id: "R\(i)", title: "E\(i)"))
        taskSide.linkList.append(rlink("T\(i)", "R\(i)", "E\(i)"))
        if i > 5 { taskSide.store.append(rtask("T\(i)", "E\(i)")) }
      }
      let report = try await ReminderSyncEngine(backend: backend, taskSide: taskSide).sync(listId: nil, now: rnow)
      try expectEqual(report.deletedExternal, 0)
      try expectEqual(report.errors, [ReminderSyncEngine.pausedMessage])
      try expectEqual(backend.items.count, 10, "Erinnerungen bleiben erhalten")
    },
    CheckCase("Massenlöschung: eine ganze Liste mit Verknüpfungen verschwindet → pausiert") {
      let backend = FakeRemindersBackend()
      let taskSide = FakeTaskSide()
      for i in 1...8 {
        let list = i <= 6 ? "L1" : "L2"
        backend.seed(ExternalReminder(id: "R\(i)", title: "E\(i)"), list: list)
        taskSide.store.append(rtask("T\(i)", "E\(i)"))
        var link = rlink("T\(i)", "R\(i)", "E\(i)")
        link.listId = list
        taskSide.linkList.append(link)
      }
      backend.items.removeAll { $0.id == "R7" || $0.id == "R8" }
      let report = try await ReminderSyncEngine(backend: backend, taskSide: taskSide).sync(listId: nil, now: rnow)
      try expectEqual(report.errors, [ReminderSyncEngine.pausedMessage])
      try expectEqual(taskSide.store.count, 8, "Aufgaben bleiben erhalten")
      try expectEqual(taskSide.linkList.count, 8, "Verknüpfungen bleiben erhalten")
    },
    CheckCase("Listen-Prüfung: Verknüpfungen ohne Listenangabe zählen nicht") {
      let links = [rlink("T1", "R1", "A"), rlink("T2", "R2", "B")]
      try expect(!ReminderSyncPlanner.isListVanished(links: links, externalIds: []), "ohne Liste darf nichts pausieren")
      var l1 = rlink("T1", "R1", "A"); l1.listId = "L1"
      var l2 = rlink("T2", "R2", "B"); l2.listId = "L1"
      try expect(ReminderSyncPlanner.isListVanished(links: [l1, l2], externalIds: ["R3"]), "ganze Liste weg")
      try expect(!ReminderSyncPlanner.isListVanished(links: [l1, l2], externalIds: ["R1", "R3"]), "eine Erinnerung noch da")
      var l3 = rlink("T3", "R3", "C"); l3.listId = "L2"
      try expect(!ReminderSyncPlanner.isListVanished(links: [l3], externalIds: []), "Liste mit nur einer Erinnerung zählt nicht")
    },
    CheckCase("Engine: Verknüpfung speichert die Liste und trägt sie bei älteren Ständen nach") {
      let (engine, _, taskSide) = remindersFixture()
      taskSide.linkList = [rlink("T1", "R1", "Milch", due: "2026-10-12")]
      _ = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(taskSide.linkList.first(where: { $0.externalId == "R1" })?.listId, "L1")
    },

    // MARK: Planer

    CheckCase("Planer: offene Aufgabe ohne Verknüpfung wird exportiert") {
      let plan = ReminderSyncPlanner.plan(tasks: [rtask("T1", "Milch")], external: [], links: [])
      try expectEqual(plan, [.createExternal(taskId: "T1")])
    },
    CheckCase("Planer: erledigte Aufgabe wird nicht exportiert") {
      let plan = ReminderSyncPlanner.plan(tasks: [rtask("T1", "Milch", done: true)], external: [], links: [])
      try expectEqual(plan, [])
    },
    CheckCase("Planer: offene Erinnerung ohne Verknüpfung wird Aufgabe") {
      let plan = ReminderSyncPlanner.plan(tasks: [], external: [rext("R1", "Steuer")], links: [])
      try expectEqual(plan, [.createTask(externalId: "R1")])
    },
    CheckCase("Planer: erledigte Erinnerung ohne Verknüpfung wird nicht übernommen") {
      let plan = ReminderSyncPlanner.plan(tasks: [], external: [rext("R1", "Alt", done: true)], links: [])
      try expectEqual(plan, [])
    },
    CheckCase("Planer: unverändertes Paar ergibt nichts") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch", due: "2026-10-12")],
        external: [rext("R1", "Milch", due: "2026-10-12")],
        links: [rlink("T1", "R1", "Milch", due: "2026-10-12")])
      try expectEqual(plan, [])
    },
    CheckCase("Planer: nur Lumi geändert → pushToExternal") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch neu")],
        external: [rext("R1", "Milch")],
        links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.pushToExternal(taskId: "T1")])
    },
    CheckCase("Planer: nur Apple geändert (Fälligkeit) → pullToTask") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch")],
        external: [rext("R1", "Milch", due: "2026-10-20T09:00")],
        links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.pullToTask(externalId: "R1")])
    },
    CheckCase("Planer: beide geändert → Apple gewinnt (pullToTask)") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Lumi-Titel")],
        external: [rext("R1", "Apple-Titel")],
        links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.pullToTask(externalId: "R1")])
    },
    CheckCase("Planer: in Lumi erledigt → pushToExternal") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch", done: true)],
        external: [rext("R1", "Milch")],
        links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.pushToExternal(taskId: "T1")])
    },
    CheckCase("Planer: in Apple erledigt → pullToTask (keine erneute Erstellung)") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch")],
        external: [rext("R1", "Milch", done: true)],
        links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.pullToTask(externalId: "R1")])
    },
    CheckCase("Planer: Erinnerung in Apple gelöscht → Aufgabe wird gelöscht") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch")], external: [], links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.deleteTask(taskId: "T1")])
    },
    CheckCase("Planer: Erinnerung gelöscht, Aufgabe schon erledigt → nur unlink") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [rtask("T1", "Milch", done: true)], external: [], links: [rlink("T1", "R1", "Milch", done: true)])
      try expectEqual(plan, [.unlink(taskId: "T1")])
    },
    CheckCase("Planer: Aufgabe in Lumi gelöscht → Erinnerung wird gelöscht") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [], external: [rext("R1", "Milch")], links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.deleteExternal(externalId: "R1")])
    },
    CheckCase("Planer: Aufgabe gelöscht, Erinnerung schon erledigt → nur unlink") {
      let plan = ReminderSyncPlanner.plan(
        tasks: [], external: [rext("R1", "Milch", done: true)], links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.unlink(taskId: "T1")])
    },
    CheckCase("Planer: Aufgabe und Erinnerung beide weg → nur unlink") {
      let plan = ReminderSyncPlanner.plan(tasks: [], external: [], links: [rlink("T1", "R1", "Milch")])
      try expectEqual(plan, [.unlink(taskId: "T1")])
    },

    CheckCase("Planer: Importliste übernimmt nur unverknüpfte Erinnerungen dieser Liste") {
      var inList = rext("R1", "Steuer")
      inList.listId = "L2"
      var other = rext("R2", "Alt")
      other.listId = "L1"
      let plan = ReminderSyncPlanner.plan(tasks: [], external: [inList, other], links: [], importListId: "L2")
      try expectEqual(plan, [.createTask(externalId: "R1")])
    },
    CheckCase("Planer: ohne Importliste werden alle unverknüpften Erinnerungen übernommen") {
      var a = rext("R1", "Steuer")
      a.listId = "L2"
      let b = rext("R2", "Alt")
      let plan = ReminderSyncPlanner.plan(tasks: [], external: [a, b], links: [])
      try expectEqual(plan, [.createTask(externalId: "R1"), .createTask(externalId: "R2")])
    },

    // MARK: Abbildung der Fälligkeit (EventKit-Helfer, ohne Freigabe prüfbar)

    CheckCase("EventKit-Abbildung: Datum ohne Uhrzeit") {
      let dc = try expectNotNil(EventKitRemindersBackend.dueComponents(from: "2026-10-11"))
      try expectEqual(dc.year, 2026)
      try expectEqual(dc.month, 10)
      try expectEqual(dc.day, 11)
      try expectEqual(dc.hour, nil, "nur Datum, keine Uhrzeit")
    },
    CheckCase("EventKit-Abbildung: Datum mit Uhrzeit") {
      let dc = try expectNotNil(EventKitRemindersBackend.dueComponents(from: "2026-10-11T09:30"))
      try expectEqual(dc.hour, 9)
      try expectEqual(dc.minute, 30)
    },
    CheckCase("EventKit-Abbildung: Hin- und Rückweg ergibt dieselbe Zeichenkette") {
      for s in ["2026-10-11", "2026-01-05T00:00", "2026-12-31T23:59"] {
        let back = EventKitRemindersBackend.dueString(from: EventKitRemindersBackend.dueComponents(from: s))
        try expectEqual(back, s)
      }
    },
    CheckCase("EventKit-Abbildung: fehlende oder ungültige Fälligkeit") {
      try expectEqual(EventKitRemindersBackend.dueComponents(from: nil) == nil, true)
      try expectEqual(EventKitRemindersBackend.dueComponents(from: "kaputt") == nil, true)
      try expectEqual(EventKitRemindersBackend.dueComponents(from: "2026-13-01") == nil, true)
      try expectEqual(EventKitRemindersBackend.dueString(from: nil), nil)
    },
    CheckCase("EventKit-Abbildung: Zugriffsstatus") {
      try expectEqual(EventKitRemindersBackend.isGranted(.fullAccess), true)
      try expectEqual(EventKitRemindersBackend.isGranted(.denied), false)
      try expectEqual(EventKitRemindersBackend.isGranted(.notDetermined), false)
    },

    // MARK: Engine mit Attrappen

    CheckCase("Engine: erster Abgleich legt in beide Richtungen an und verknüpft") {
      let (engine, backend, taskSide) = remindersFixture()
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(createdExternal: 1, createdTask: 1, errors: []))
      try expectEqual(backend.items.count, 3, "Steuer, Alt (erledigt) und neue Erinnerung für Milch")
      try expectEqual(taskSide.store.count, 3, "Milch, Brief (erledigt) und neue Aufgabe für Steuer")
      try expectEqual(taskSide.linkList.count, 2)
      try expect(taskSide.store.contains { $0.title == "Steuer" && !$0.done }, "Steuer fehlt als Aufgabe")
      try expect(!taskSide.store.contains { $0.title == "Alt" }, "erledigte Erinnerung darf nicht übernommen werden")
      try expect(!backend.items.contains { $0.title == "Brief" }, "erledigte Aufgabe darf nicht exportiert werden")
    },
    CheckCase("Engine: zweiter Abgleich ohne Änderungen ist ein No-op") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let items = backend.items
      let tasks = taskSide.store
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(), "zweiter Lauf soll nichts tun")
      try expect(backend.items == items, "Apple-Seite darf sich nicht ändern")
      try expect(taskSide.store == tasks, "Aufgaben dürfen sich nicht ändern")
    },
    CheckCase("Engine: Änderung in Apple wird in Lumi übernommen") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let i = try expectNotNil(backend.items.firstIndex { $0.title == "Steuer" })
      backend.items[i].title = "Steuererklärung"
      backend.items[i].due = "2026-10-20T09:00"
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pulled: 1))
      let task = try expectNotNil(taskSide.store.first { $0.title == "Steuererklärung" })
      try expectEqual(task.due, "2026-10-20T09:00")
    },
    CheckCase("Engine: Änderung in Lumi wird nach Apple übertragen") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let t = try expectNotNil(taskSide.store.first { $0.title == "Milch" })
      try taskSide.updateTask(id: t.id, title: "Milch und Brot", notes: nil, due: "2026-10-14")
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pushed: 1))
      let r = try expectNotNil(backend.items.first { $0.title == "Milch und Brot" })
      try expectEqual(r.due, "2026-10-14")
    },
    CheckCase("Engine: Erledigt-Status läuft in beide Richtungen") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let t = try expectNotNil(taskSide.store.first { $0.title == "Milch" })
      try taskSide.setDone(id: t.id, done: true)
      var report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pushed: 1))
      try expectEqual(backend.items.first { $0.title == "Milch" }?.done, true, "in Apple erledigt")

      let i = try expectNotNil(backend.items.firstIndex { $0.title == "Steuer" })
      backend.items[i].done = true
      report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pulled: 1))
      try expectEqual(taskSide.store.first { $0.title == "Steuer" }?.done, true, "in Lumi erledigt")
    },
    CheckCase("Engine: Fehler einer Aktion wird gesammelt, der Rest läuft weiter") {
      let (engine, backend, taskSide) = remindersFixture()
      backend.failCreateTitle = "Scheitert"
      _ = try taskSide.addTask(title: "Scheitert", notes: nil, due: nil)
      _ = try taskSide.addTask(title: "Gut", notes: nil, due: nil)
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report.errors.count, 1)
      try expect(report.errors.first?.contains("Scheitert") == true, "Fehlertext nennt die Aufgabe")
      try expectEqual(report.createdExternal, 2, "Milch und Gut werden trotzdem angelegt")
      try expect(backend.items.contains { $0.title == "Gut" }, "Gut fehlt in Apple")
    },
    CheckCase("Engine: Listenwahl ruft immer alle Listen ab, filtert nur den Import und legt dort an") {
      let (engine, backend, taskSide) = remindersFixture()
      backend.seed(ExternalReminder(id: "R3", title: "Einkauf"), list: "L2")
      let report = try await engine.sync(listId: "L2", now: rnow)
      try expectEqual(backend.lastListIds, nil, "Abruf immer über alle Listen")
      try expectEqual(report, SyncReport(createdExternal: 1, createdTask: 1, errors: []))
      try expect(taskSide.store.contains { $0.title == "Einkauf" }, "unverknüpfte Erinnerung aus L2 wird Aufgabe")
      try expect(!taskSide.store.contains { $0.title == "Steuer" }, "Steuer aus L1 wird bei Listenwahl L2 nicht importiert")
      let milch = try expectNotNil(backend.items.first { $0.title == "Milch" })
      try expectEqual(backend.listOf[milch.id], "L2", "neue Erinnerung liegt in der gewählten Liste")
      let later = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(later, SyncReport(createdTask: 1), "ohne Listenwahl wird Steuer nachgeholt")
    },
    CheckCase("Engine: Listenwechsel löscht und verwaist nichts") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let report = try await engine.sync(listId: "L2", now: rnow)
      try expectEqual(report, SyncReport(), "Listenwechsel: keine Aktion")
      try expectEqual(taskSide.store.count, 3, "alle Aufgaben bleiben")
      try expectEqual(taskSide.linkList.count, 2, "alle Verknüpfungen bleiben")
      try expectEqual(backend.items.count, 3, "keine Erinnerung wird gelöscht")
      let again = try await engine.sync(listId: "L2", now: rnow)
      try expectEqual(again, SyncReport(), "wiederholter Lauf bleibt ein No-op")
    },
    CheckCase("Engine: ohne Zugriff wird geworfen") {
      let (engine, backend, _) = remindersFixture()
      backend.granted = false
      var thrown: RemindersError?
      do {
        _ = try await engine.sync(listId: nil, now: rnow)
      } catch let e as RemindersError {
        thrown = e
      }
      try expectEqual(thrown, .accessDenied)
      try expectEqual(
        RemindersError.accessDenied.errorDescription,
        "Kein Zugriff auf Erinnerungen. Bitte in den Systemeinstellungen freigeben.")
    },
    CheckCase("Engine: in Apple gelöschte Erinnerung löscht die Aufgabe, ohne Wiederauferstehung") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      backend.items.removeAll { $0.title == "Steuer" }
      let report = try await engine.sync(listId: nil, now: rnow)
      let steuerId = try expectNotNil(taskSide.store.first { $0.title == "Steuer" }?.id)
      var expected = SyncReport()
      expected.removedFromApple = [steuerId]
      try expectEqual(report, expected)
      try expect(taskSide.store.contains { $0.title == "Steuer" }, "Aufgabe Steuer bleibt in Lumi")
      let again = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(again.createdExternal, 0, "zweiter Lauf: nichts nach Apple schreiben")
      try expectEqual(again.deletedTask, 0)
      try expectEqual(backend.items.contains { $0.title == "Steuer" }, false, "Erinnerung kehrt nicht zurück")
    },
    CheckCase("Engine: in Lumi gelöschte Aufgabe löscht die Erinnerung, ohne Wiederauferstehung") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let t = try expectNotNil(taskSide.store.first { $0.title == "Milch" })
      try taskSide.deleteTask(id: t.id)
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(deletedExternal: 1))
      try expect(!backend.items.contains { $0.title == "Milch" }, "Erinnerung Milch muss gelöscht sein")
      try expectEqual(taskSide.linkList.count, 1, "nur Steuer bleibt verknüpft")
      let again = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(again, SyncReport(), "zweiter Lauf: keine neue Erinnerung für Milch")
      try expect(!backend.items.contains { $0.title == "Milch" }, "Milch darf nicht zurückkommen")
    },
    CheckCase("Engine: Erinnerung gelöscht, Aufgabe schon erledigt → nur Verknüpfung lösen") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let t = try expectNotNil(taskSide.store.first { $0.title == "Milch" })
      try taskSide.setDone(id: t.id, done: true)
      backend.items.removeAll { $0.title == "Milch" }
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(unlinked: 1))
      try expect(taskSide.store.contains { $0.id == t.id && $0.done }, "erledigte Aufgabe bleibt bestehen")
    },
    CheckCase("Engine: Aufgabe gelöscht, Erinnerung schon erledigt → nur Verknüpfung lösen") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try await engine.sync(listId: nil, now: rnow)
      let i = try expectNotNil(backend.items.firstIndex { $0.title == "Milch" })
      backend.items[i].done = true
      let t = try expectNotNil(taskSide.store.first { $0.title == "Milch" })
      try taskSide.deleteTask(id: t.id)
      let report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(unlinked: 1))
      try expect(backend.items.contains { $0.title == "Milch" }, "erledigte Erinnerung bleibt bestehen")
    },
    CheckCase("Engine: Notizen werden nur beim Anlegen kopiert, nie beim Push oder Pull überschrieben") {
      let (engine, backend, taskSide) = remindersFixture()
      _ = try taskSide.addTask(title: "Einkauf", notes: "Zwei Liter Milch", due: nil)
      _ = try await engine.sync(listId: nil, now: rnow)
      let created = try expectNotNil(backend.items.first { $0.title == "Einkauf" })
      try expectEqual(created.notes, "Zwei Liter Milch", "beim Anlegen kopiert")

      // Apple ändert Titel und Notiz: Pull übernimmt den Titel, die Lumi-Notiz bleibt.
      let i = try expectNotNil(backend.items.firstIndex { $0.title == "Einkauf" })
      backend.items[i].title = "Einkauf neu"
      backend.items[i].notes = "Apple-Notiz"
      var report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pulled: 1))
      let pulled = try expectNotNil(taskSide.store.first { $0.title == "Einkauf neu" })
      try expectEqual(pulled.notes, "Zwei Liter Milch", "Pull darf die Lumi-Notiz nicht überschreiben")

      // Lumi ändert Titel und Notiz: Push übernimmt den Titel, die Apple-Notiz bleibt.
      try taskSide.updateTask(id: pulled.id, title: "Einkauf neu!", notes: "Lumi-Notiz", due: nil)
      report = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(report, SyncReport(pushed: 1))
      let pushed = try expectNotNil(backend.items.first { $0.title == "Einkauf neu!" })
      try expectEqual(pushed.notes, "Apple-Notiz", "Push darf die Apple-Notiz nicht überschreiben")
      let last = try await engine.sync(listId: nil, now: rnow)
      try expectEqual(last, SyncReport(), "danach ein No-op")
    },
    CheckCase("EventKit: Freigabeprüfung stürzt ohne App-Bundle nicht ab") {
      // Ohne Info.plist-Begründung darf nie der Systemdialog kommen; das Ergebnis hängt
      // vom Zustand des Systems ab, deshalb wird nur auf „kein Absturz“ geprüft.
      _ = await EventKitRemindersBackend().requestAccess()
    },
  ])
}

// MARK: Hilfsfunktionen für Prüfungen

private let rnow = "2026-10-11T08:00"

private func rtask(_ id: String, _ title: String, due: String? = nil, done: Bool = false) -> TabyTask {
  TabyTask(id: id, title: title, due: due, done: done, createdAt: "2026-10-01T09:00")
}

private func rext(_ id: String, _ title: String, due: String? = nil, done: Bool = false) -> ExternalReminder {
  ExternalReminder(id: id, title: title, due: due, done: done)
}

/// Verknüpfung mit Snapshot = Ausgangszustand (Standard: unverändert).
private func rlink(_ taskId: String, _ extId: String, _ title: String, due: String? = nil,
                   done: Bool = false) -> ReminderLink {
  ReminderLink(taskId: taskId, externalId: extId, snapTitle: title, snapDue: due, snapDone: done, syncedAt: rnow)
}

/// Attrappe der Apple-Seite: Listen-Zuordnung, Fehler-Schalter, Abrufprotokoll.
private final class FakeRemindersBackend: RemindersBackend {
  var granted = true
  var items: [ExternalReminder] = []
  var listOf: [String: String] = [:]
  var failCreateTitle: String?
  var lastListIds: [String]?
  private var nextId = 100

  func requestAccess() async -> Bool { granted }

  func lists() async throws -> [ReminderListInfo] {
    [ReminderListInfo(id: "L1", title: "Erinnerungen"), ReminderListInfo(id: "L2", title: "Einkauf")]
  }

  func fetchAll(listIds: [String]?) async throws -> [ExternalReminder] {
    lastListIds = listIds
    let all = items.map { r -> ExternalReminder in
      var copy = r
      copy.listId = listOf[r.id]
      return copy
    }
    guard let ids = listIds else { return all }
    return all.filter { ids.contains($0.listId ?? "") }
  }

  func create(_ r: ExternalReminder, listId: String?) async throws -> String {
    if r.title == failCreateTitle { throw RemindersError.listUnavailable }
    let id = "R\(nextId)"
    nextId += 1
    items.append(ExternalReminder(id: id, title: r.title, notes: r.notes, due: r.due, done: r.done))
    listOf[id] = listId ?? "L1"
    return id
  }

  func update(_ r: ExternalReminder) async throws {
    guard let i = items.firstIndex(where: { $0.id == r.id }) else { throw RemindersError.notFound }
    items[i] = r
  }

  func delete(id: String) async throws {
    items.removeAll { $0.id == id }
    listOf[id] = nil
  }

  func seed(_ r: ExternalReminder, list: String = "L1") {
    items.append(r)
    listOf[r.id] = list
  }
}

/// Attrappe der Lumi-Seite.
private final class FakeTaskSide: TaskSide {
  var store: [TabyTask] = []
  var linkList: [ReminderLink] = []
  private var nextId = 1

  func tasks() throws -> [TabyTask] { store }

  func addTask(title: String, notes: String?, due: String?) throws -> TabyTask {
    let t = TabyTask(id: "N\(nextId)", title: title, notes: notes, due: due, createdAt: rnow)
    nextId += 1
    store.append(t)
    return t
  }

  func updateTask(id: String, title: String, notes: String?, due: String?) throws {
    guard let i = store.firstIndex(where: { $0.id == id }) else { throw RemindersError.notFound }
    store[i].title = title
    store[i].notes = notes
    store[i].due = due
  }

  func setDone(id: String, done: Bool) throws {
    guard let i = store.firstIndex(where: { $0.id == id }) else { throw RemindersError.notFound }
    store[i].done = done
    store[i].doneAt = done ? rnow : nil
  }

  func deleteTask(id: String) throws {
    store.removeAll { $0.id == id }
  }

  func links() throws -> [ReminderLink] { linkList }

  func saveLink(_ l: ReminderLink) throws {
    if let i = linkList.firstIndex(where: { $0.taskId == l.taskId }) {
      linkList[i] = l
    } else {
      linkList.append(l)
    }
  }

  func deleteLink(taskId: String) throws {
    linkList.removeAll { $0.taskId == taskId }
  }
}

/// Ausgangslage: Aufgaben „Milch“ (offen) und „Brief“ (erledigt);
/// Erinnerungen „Steuer“ (offen, L1), „Alt“ (erledigt, L1).
private func remindersFixture() -> (ReminderSyncEngine, FakeRemindersBackend, FakeTaskSide) {
  let backend = FakeRemindersBackend()
  backend.seed(ExternalReminder(id: "R1", title: "Steuer", due: "2026-10-13T09:00"))
  backend.seed(ExternalReminder(id: "R2", title: "Alt", done: true))
  let taskSide = FakeTaskSide()
  taskSide.store = [
    rtask("T1", "Milch", due: "2026-10-12"),
    rtask("T2", "Brief", done: true),
  ]
  return (ReminderSyncEngine(backend: backend, taskSide: taskSide), backend, taskSide)
}
