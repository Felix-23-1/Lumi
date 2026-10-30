// Prüfungen für Paket 4: Tagesplan, Meeting-Begleiter, Wochenrückblick,
// Datei-Text und die Speicher-Repositories (im Speicher).
import Foundation

private func prStore(_ now: String = "2024-03-04T08:00") throws -> Store {
  try Store.inMemory(clock: ControllableClock(now))
}

private func prTask(_ id: String, _ title: String, due: String? = nil, done: Bool = false, doneAt: String? = nil,
                    notes: String? = nil, created: String = "2024-02-01T09:00") -> TabyTask {
  TabyTask(id: id, title: title, notes: notes, due: due, done: done, doneAt: doneAt, createdAt: created)
}

private func prEvent(_ id: String, _ start: String, _ end: String? = nil, allDay: Bool = false,
                     title: String = "Termin", notes: String? = nil) -> CalendarEvent {
  CalendarEvent(id: id, sourceId: "local", title: title, start: start, end: end, allDay: allDay, notes: notes)
}

private func prNote(_ id: String, _ title: String, _ content: String = "") -> Note {
  Note(id: id, title: title, content: content, createdAt: "2024-03-01T09:00", updatedAt: "2024-03-01T09:00")
}

/// Drei offene Aufgaben ohne Frist, 30 Minuten je Block, um 08:00 geplant:
/// t1 08:00–08:30, t2 08:35–09:05, t3 09:10–09:40.
private func prInitialPlan() -> DayPlan {
  AutoPlanner.plan(
    tasks: [prTask("t1", "Erster", created: "2024-02-01T09:00"), prTask("t2", "Zweiter", created: "2024-02-01T09:01"),
            prTask("t3", "Dritter", created: "2024-02-01T09:02")],
    events: [], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
}

/// Schreibt eine Datei in ein frisches Verzeichnis im Temp-Ordner.
private func prTempFile(_ name: String, _ data: Data) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-prod-\(UUID().uuidString)",
                                                                           isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent(name)
  try data.write(to: url)
  return url
}

public enum ProductivityChecks {
  @MainActor public static var suite: CheckSuite {
    CheckSuite("Productivity", autoPlannerChecks + replanChecks + meetingChecks + weeklyChecks + repositoryChecks
      + fileTextChecks + reasonChecks + whatNowChecks + workWeekChecks)
  }

  // MARK: Begründung je Block und „Was jetzt?“

  static let reasonChecks: [CheckCase] = [
    CheckCase("Begründung: feste Uhrzeit (Fälligkeit), vom Nutzer festgelegt, Lücke vor Termin, bis Feierabend") {
      let due = AutoPlanner.plan(tasks: [prTask("a", "A", due: "2024-03-04T09:15")], events: [],
                                 now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(due.blocks.first?.reason, "Feste Uhrzeit 09:15")
      let chosen = AutoPlanner.planChosen(items: [PlanItem(taskId: "a", start: "10:00", minutes: 30)],
                                          tasks: [prTask("a", "A")], events: [], now: "2024-03-04T08:00",
                                          bufferMinutes: 0)
      try expectEqual(chosen.blocks.first?.reason, "Von dir festgelegt")
      let before = AutoPlanner.plan(tasks: [prTask("a", "A")],
                                    events: [prEvent("m", "2024-03-04T09:00", "2024-03-04T10:00", title: "Standup")],
                                    now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(before.blocks.first?.reason, "Freie Lücke vor „Standup“")
      let end = AutoPlanner.plan(tasks: [prTask("a", "A")], events: [], now: "2024-03-04T08:00",
                                 blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(end.blocks.first?.reason, "Freie Lücke bis Feierabend")
    },
    CheckCase("Begründung: nach der Mittagspause aus dem Gedächtnis") {
      let lunch = CalendarEvent(id: "break#12:00", sourceId: "memory", title: "Mittagspause",
                                start: "2024-03-04T12:00", end: "2024-03-04T13:00")
      let plan = AutoPlanner.plan(tasks: [prTask("a", "A")], events: [lunch], now: "2024-03-04T12:00",
                                  blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.first?.start, "2024-03-04T13:00")
      try expectEqual(plan.blocks.first?.reason, "Nach der Mittagspause")
    },
    CheckCase("Begründung: verschoben wegen des Termins, der den Block verdrängt") {
      let plan = AutoPlanner.plan(tasks: [prTask("a", "A")], events: [], now: "2024-03-04T07:30",
                                  blockMinutes: 30, bufferMinutes: 0)
      let result = AutoPlanner.replan(plan, tasks: [prTask("a", "A")],
                                      events: [prEvent("m", "2024-03-04T08:10", "2024-03-04T08:40")],
                                      now: "2024-03-04T07:30", dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(result.plan.blocks.first?.start, "2024-03-04T08:40")
      try expectEqual(result.plan.blocks.first?.reason, "Verschoben wegen „Termin“")
      try expectEqual(result.moved.count, 1)
    },
  ]

  @MainActor static let whatNowChecks: [CheckCase] = [
    CheckCase("Was jetzt: überfällig zuerst (älteste Fälligkeit), mit Wochentag") {
      let tasks = [prTask("neu", "Neu", due: "2024-03-02"), prTask("alt", "Alt", due: "2024-02-28")]
      let pick = WhatNowLogic.pick(tasks: tasks, now: "2024-03-04T08:00", priority: [], defaultMinutes: 30)
      try expectEqual(pick?.task.id, "alt")
      try expectEqual(pick?.reason, "Überfällig seit Mi")
    },
    CheckCase("Was jetzt: fest terminiert in 30 Minuten geht vor der Priorität") {
      let tasks = [prTask("p", "Priorität"), prTask("f", "Termin", due: "2024-03-04T15:00")]
      let soon = WhatNowLogic.pick(tasks: tasks, now: "2024-03-04T14:45", priority: ["p"], defaultMinutes: 30)
      try expectEqual(soon?.task.id, "f")
      try expectEqual(soon?.reason, "Termin um 15:00")
      let later = WhatNowLogic.pick(tasks: tasks, now: "2024-03-04T14:00", priority: ["p"], defaultMinutes: 30)
      try expectEqual(later?.task.id, "p")
      try expectEqual(later?.reason, "Priorisiert")
    },
    CheckCase("Was jetzt: heute fällig vor kurz, kurz zuletzt, erledigte fallen weg") {
      let tasks = [prTask("kurz", "Kurz (15 min)"), prTask("lang", "Lang (2h)"),
                   prTask("heute", "Heute", due: "2024-03-04"), prTask("alt", "Alt", done: true)]
      let due = WhatNowLogic.pick(tasks: tasks, now: "2024-03-04T08:00", priority: [], defaultMinutes: 30)
      try expectEqual(due?.task.id, "heute")
      try expectEqual(due?.reason, "Heute fällig")
      let short = WhatNowLogic.pick(tasks: [tasks[0], tasks[1]], now: "2024-03-04T08:00", priority: [],
                                    defaultMinutes: 30)
      try expectEqual(short?.task.id, "kurz")
      try expectEqual(short?.reason, "Kurz erledigt")
      try expectEqual(WhatNowLogic.pick(tasks: [tasks[3]], now: "2024-03-04T08:00", priority: [],
                                        defaultMinutes: 30) == nil, true)
    },
    CheckCase("Was jetzt: startet den Fokus, läuft schon einer, bleibt es bei der Meldung") {
      let rig = try IntegrationRig()
      _ = await rig.svc.addTask(title: "Alpha", notes: nil, due: nil)
      guard case .ok(let pick) = await rig.svc.whatNow() else {
        throw CheckFailure(message: "whatNow fehlgeschlagen", location: "")
      }
      try expectEqual(pick.reason, "Kurz erledigt")
      let focus = await rig.svc.state().focus
      try expectEqual(focus?.title, "Alpha")
      guard case .failure(_, let error) = await rig.svc.whatNow() else {
        throw CheckFailure(message: "zweiter Aufruf hätte scheitern müssen", location: "")
      }
      try expectEqual(error, "Fokus läuft schon.")
    },
  ]

  // MARK: Automatisch einplanen

  static let autoPlannerChecks: [CheckCase] = [
    CheckCase("Dauer aus dem Titel: Minuten, Stunden, Komma, Wortform, Grenzen") {
      try expectEqual(AutoPlanner.estimateMinutes("Bericht (45 min)", default: 30), 45)
      try expectEqual(AutoPlanner.estimateMinutes("Review45min", default: 30), 45)
      try expectEqual(AutoPlanner.estimateMinutes("Ticket 99999999999999999999999 h", default: 30), 240, "kein Überlauf")
      try expectEqual(AutoPlanner.estimateMinutes("Vorbereitung 1h", default: 30), 60)
      try expectEqual(AutoPlanner.estimateMinutes("Workshop 1,5 h", default: 30), 90)
      try expectEqual(AutoPlanner.estimateMinutes("Lesen 90 Minuten", default: 30), 90)
      try expectEqual(AutoPlanner.estimateMinutes("Mix 1h 30min", default: 30), 90)
      try expectEqual(AutoPlanner.estimateMinutes("Ohne Angabe", default: 30), 30)
      try expectEqual(AutoPlanner.estimateMinutes("Großprojekt 9h", default: 30), 240)
      try expectEqual(AutoPlanner.estimateMinutes("Kurz 1 min", default: 30), 5)
    },
    CheckCase("Plan: überfällig vor heute fällig vor ohne Frist; Frist über 3 Tage fehlt") {
      let tasks = [
        prTask("a", "A", due: "2024-03-04", created: "2024-02-10T09:00"),
        prTask("b", "B", due: "2024-03-01", created: "2024-02-01T09:00"),
        prTask("c", "C", created: "2024-01-01T09:00"),
        prTask("d", "D", due: "2024-03-20", created: "2024-01-01T09:00"),
      ]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 30,
                                  bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["b", "a", "c"])
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T08:35", "2024-03-04T09:10"])
      try expectEqual(plan.unplanned, [])
      try expectEqual(plan.date, "2024-03-04")
    },
    CheckCase("Plan: priorisierte Aufgaben zuerst, in gemerkter Reihenfolge, Rest wie gehabt dahinter") {
      let tasks = [
        prTask("a", "A", due: "2024-03-04", created: "2024-02-10T09:00"),
        prTask("b", "B", due: "2024-03-01", created: "2024-02-01T09:00"),
        prTask("c", "C", created: "2024-01-01T09:00"),
      ]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 30,
                                  bufferMinutes: 0, priority: ["c", "a"])
      try expectEqual(plan.blocks.map(\.taskId), ["c", "a", "b"])
    },
    CheckCase("Plan: Prioritäts-IDs ohne passende offene Aufgabe werden ignoriert") {
      let tasks = [prTask("a", "A", created: "2024-02-01T09:00"), prTask("b", "B", done: true, created: "2024-02-01T09:00")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 30,
                                  bufferMinutes: 0, priority: ["weg", "b", "a"])
      try expectEqual(plan.blocks.map(\.taskId), ["a"])
    },
    CheckCase("reorder: packt in genau der gegebenen Reihenfolge, lässt Erledigtes/Unbekanntes weg") {
      let tasks = [prTask("a", "A", created: "2024-02-01T09:00"), prTask("b", "B", created: "2024-02-01T09:01"),
                   prTask("c", "C", done: true, created: "2024-02-01T09:02")]
      let plan = AutoPlanner.reorder(["b", "weg", "c", "a"], tasks: tasks, events: [], now: "2024-03-04T08:00",
                                     blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["b", "a"])
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T08:35"])
    },
    CheckCase("reorder: was nicht mehr passt, landet in unplanned, nicht wiederholt") {
      let tasks = (1...4).map { prTask("t\($0)", "T\($0)", created: "2024-02-01T09:0\($0)") }
      let plan = AutoPlanner.reorder(tasks.map(\.id).reversed(), tasks: tasks, events: [
        prEvent("full", "2024-03-04T08:30", "2024-03-04T23:00"),
      ], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["t4"])
      try expectEqual(plan.unplanned, ["t3", "t2", "t1"])
    },
    CheckCase("reorder: eine zu lange Aufgabe vorn blockiert die passende dahinter nicht") {
      let tasks = [prTask("long", "Lang (90 min)", created: "2024-02-01T09:00"),
                   prTask("short", "Kurz (30 min)", created: "2024-02-01T09:01")]
      let plan = AutoPlanner.reorder(["long", "short"], tasks: tasks, events: [
        prEvent("full", "2024-03-04T09:00", "2024-03-04T23:00"),
      ], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["short"])
      try expectEqual(plan.unplanned, ["long"])
    },
    CheckCase("Plan: Blöcke überschneiden keine Termine, halten den Puffer und 5 Minuten Abstand") {
      let events = [prEvent("m", "2024-03-04T10:00", "2024-03-04T11:00", title: "Meeting")]
      let tasks = [prTask("a", "A", created: "2024-02-01T09:00"), prTask("b", "B", created: "2024-02-01T09:01"),
                   prTask("c", "C", created: "2024-02-01T09:02")]
      let plan = AutoPlanner.plan(tasks: tasks, events: events, now: "2024-03-04T08:00", blockMinutes: 60,
                                  bufferMinutes: 10)
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T11:10", "2024-03-04T12:15"])
      // Puffer: vor dem Termin (ab 09:50) und danach (bis 11:10) bleibt frei.
      for block in plan.blocks {
        try expect(block.end <= "2024-03-04T09:50" || block.start >= "2024-03-04T11:10",
                   "Block \(block.start)–\(block.end) verletzt den Puffer")
      }
      for (earlier, later) in zip(plan.blocks, plan.blocks.dropFirst()) {
        try expect(later.start >= earlier.end, "Blöcke überschneiden sich")
        let gap = AutoPlanner.toMinutes(later.start)! - AutoPlanner.toMinutes(earlier.end)!
        try expect(gap >= 5, "weniger als 5 Minuten Abstand: \(gap)")
      }
    },
    CheckCase("Plan: nichts vor 'jetzt', auf 5 Minuten aufgerundet") {
      let plan = AutoPlanner.plan(tasks: [prTask("x", "X")], events: [], now: "2024-03-04T10:02",
                                  blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.first?.start, "2024-03-04T10:05")
    },
    CheckCase("Plan: voller Tag legt übrige Aufgaben in unplanned") {
      let tasks = [prTask("a", "A", created: "2024-02-01T09:00"), prTask("b", "B", created: "2024-02-01T09:01")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", dayEnd: "09:00",
                                  blockMinutes: 60, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["a"])
      try expectEqual(plan.unplanned, ["b"])
    },
    CheckCase("Plan: höchstens 12 Blöcke, Rest in unplanned") {
      let tasks = (0..<14).map { i in
        prTask("t\(i)", "Aufgabe \(i) (5 min)", created: "2024-02-01T09:\(String(format: "%02d", i))")
      }
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 60,
                                  bufferMinutes: 0)
      try expectEqual(plan.blocks.count, 12)
      try expectEqual(plan.unplanned.count, 2)
    },
    CheckCase("Plan: erledigte Aufgaben werden nicht eingeplant") {
      let plan = AutoPlanner.plan(tasks: [prTask("d", "Fertig", done: true, doneAt: "2024-03-03T10:00")],
                                  events: [], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks, [])
      try expectEqual(plan.unplanned, [])
    },
  ]

  // MARK: Arbeitszeiten

  static let workWeekChecks: [CheckCase] = [
    CheckCase("Arbeitszeit: Freitag endet 13:00, Samstag (frei) nimmt das alte Fenster bis 20:00") {
      var s = TabySettings.defaults
      s.workHours[4] = "08:00-13:00"
      let friday = AutoPlanner.window(s, date: "2024-03-08")
      try expectEqual(friday.start, "08:00")
      try expectEqual(friday.end, "13:00")
      try expectEqual(AutoPlanner.window(s, date: "2024-03-09").end, "20:00")
      let tasks = [prTask("a", "A (2 h)"), prTask("b", "B (2 h)"), prTask("c", "C (45 min)"), prTask("d", "D (1 h)")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-08T08:00", dayStart: friday.start,
                                  dayEnd: friday.end, blockMinutes: 30, bufferMinutes: 0)
      try expect(plan.blocks.allSatisfy { $0.end <= "2024-03-08T13:00" }, "\(plan.blocks)")
      try expectEqual(plan.blocks.map(\.taskId), ["a", "b", "c"])
      try expectEqual(plan.unplanned, ["d"])
    },
    CheckCase("Arbeitszeit: freier Tag wird trotzdem geplant (08:00 bis Feierabend)") {
      var s = TabySettings.defaults
      s.workHours[5] = ""
      let saturday = AutoPlanner.window(s, date: "2024-03-09")
      let plan = AutoPlanner.plan(tasks: [prTask("a", "A")], events: [], now: "2024-03-09T08:00",
                                  dayStart: saturday.start, dayEnd: saturday.end, blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.first?.start, "2024-03-09T08:00")
    },
  ]

  // MARK: Umplanen

  static let replanChecks: [CheckCase] = [
    CheckCase("Replan: erledigte und gelöschte Aufgaben fallen weg, der Rest bleibt") {
      let plan = prInitialPlan()
      let withDone = [prTask("t1", "Erster"), prTask("t2", "Zweiter", done: true, doneAt: "2024-03-04T08:10"),
                      prTask("t3", "Dritter")]
      let kept = AutoPlanner.replan(plan, tasks: withDone, events: [], now: "2024-03-04T08:20", dayEnd: "20:00",
                                    blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(kept.moved, [])
      try expectEqual(kept.plan.blocks.map(\.taskId), ["t1", "t3"])
      try expectEqual(kept.plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T09:10"])

      let deleted = AutoPlanner.replan(plan, tasks: [prTask("t1", "Erster")], events: [], now: "2024-03-04T08:20",
                                       dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(deleted.plan.blocks.map(\.taskId), ["t1"])
    },
    CheckCase("Replan: kollidierender Block wird verschoben, begonnene Blöcke bleiben") {
      let tasks = [prTask("t1", "Erster"), prTask("t2", "Zweiter"), prTask("t3", "Dritter")]
      let events = [prEvent("e", "2024-03-04T08:30", "2024-03-04T09:00", title: "Anruf")]
      let result = AutoPlanner.replan(prInitialPlan(), tasks: tasks, events: events, now: "2024-03-04T08:20",
                                      dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      // t1 hat schon begonnen und bleibt; t2 (08:35) kollidiert mit dem Anruf.
      try expectEqual(result.plan.blocks.first { $0.taskId == "t1" }?.start, "2024-03-04T08:00")
      try expectEqual(result.moved.map(\.taskId), ["t2", "t3"])
      try expectEqual(result.plan.blocks.first { $0.taskId == "t2" }?.start, "2024-03-04T09:00")
      try expectEqual(result.plan.blocks.first { $0.taskId == "t3" }?.start, "2024-03-04T09:35")
    },
    CheckCase("Replan: Plan eines anderen Tages wird für heute neu verteilt") {
      let old = DayPlan(date: "2024-03-03", blocks: [
        PlannedBlock(id: "t1@2024-03-03T08:00", taskId: "t1", title: "Erster", start: "2024-03-03T08:00",
                     end: "2024-03-03T08:30"),
      ])
      let result = AutoPlanner.replan(old, tasks: [prTask("t1", "Erster")], events: [], now: "2024-03-04T08:00",
                                      dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(result.plan.date, "2024-03-04")
      try expectEqual(result.plan.blocks.first?.start, "2024-03-04T08:00")
      try expectEqual(result.moved.count, 1)
    },
    CheckCase("Feste Uhrzeit heute: Fälligkeit 08:30 und 09:15 bleiben, Rest in die freie Lücke davor") {
      let tasks = [prTask("f1", "Erste", due: "2024-03-04T08:30"), prTask("f2", "Zweite", due: "2024-03-04T09:15"),
                   prTask("c", "Frei", created: "2024-02-01T09:00")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.first { $0.taskId == "f1" }?.start, "2024-03-04T08:30")
      try expectEqual(plan.blocks.first { $0.taskId == "f1" }?.end, "2024-03-04T09:00")
      try expectEqual(plan.blocks.first { $0.taskId == "f2" }?.start, "2024-03-04T09:15")
      try expectEqual(plan.blocks.first { $0.taskId == "f2" }?.end, "2024-03-04T09:45")
      try expect(plan.blocks.filter { $0.taskId != "c" }.allSatisfy(\.isPinned))
      try expectEqual(plan.blocks.first { $0.taskId == "c" }?.start, "2024-03-04T08:00")
      try expectEqual(plan.blocks.count, 3)
      try expectEqual(plan.unplanned, [])
    },
    CheckCase("Zwei feste Aufgaben überlappen: beide bleiben auf ihrer Zeit, im Bereich wird nichts gepackt") {
      let tasks = [prTask("o1", "Erste", due: "2024-03-04T10:00"), prTask("o2", "Zweite", due: "2024-03-04T10:15"),
                   prTask("c", "Frei", created: "2024-02-01T09:00")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.filter(\.isPinned).map(\.start), ["2024-03-04T10:00", "2024-03-04T10:15"])
      try expectEqual(plan.blocks.first { $0.taskId == "c" }?.start, "2024-03-04T08:00")
      try expectEqual(plan.blocks.count, 3)
    },
    CheckCase("Fälligkeit mit Uhrzeit schon vorbei: wird ab jetzt wie eine normale Aufgabe gepackt") {
      let tasks = [prTask("p", "Vergangen", due: "2024-03-04T09:00")]
      let plan = AutoPlanner.plan(tasks: tasks, events: [], now: "2024-03-04T10:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T10:00"])
      try expect(plan.blocks.first?.isPinned != true)
    },
    CheckCase("Mittagspause als Termin bleibt frei, auch für eine Aufgabe ohne Uhrzeit") {
      let lunch = [prEvent("lunch", "2024-03-04T12:00", "2024-03-04T13:00")]
      let plan = AutoPlanner.plan(tasks: [prTask("l", "Lang (60 min)")], events: lunch, now: "2024-03-04T11:30",
                                  blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T13:00"])
    },
    CheckCase("planTasks: gewählte Uhrzeit geht vor der Fälligkeit, ohne Uhrzeit gilt die Fälligkeit heute") {
      let tasks = [prTask("x", "X", due: "2024-03-04T09:15"), prTask("y", "Y", due: "2024-03-04T09:15")]
      let plan = AutoPlanner.planChosen(items: [PlanItem(taskId: "x", start: "10:00", minutes: 30),
                                                PlanItem(taskId: "y", minutes: 30)],
                                        tasks: tasks, events: [], now: "2024-03-04T08:00", bufferMinutes: 0)
      try expectEqual(plan.blocks.first { $0.taskId == "x" }?.start, "2024-03-04T10:00")
      try expectEqual(plan.blocks.first { $0.taskId == "y" }?.start, "2024-03-04T09:15")
    },
    CheckCase("Umplanen: Aufgabe mit neuer Uhrzeit heute steht fest und erscheint nur einmal") {
      let tasks = [prTask("t1", "Erster"), prTask("t2", "Zweiter", due: "2024-03-04T09:30"), prTask("t3", "Dritter")]
      let result = AutoPlanner.replan(prInitialPlan(), tasks: tasks, events: [], now: "2024-03-04T08:20",
                                      dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      let t2 = result.plan.blocks.filter { $0.taskId == "t2" }
      try expectEqual(t2.map(\.start), ["2024-03-04T09:30"])
      try expect(t2.first?.isPinned == true)
      try expectEqual(result.plan.blocks.count, 3)
    },
  ]

  // MARK: Meeting-Begleiter

  static let meetingChecks: [CheckCase] = [
    CheckCase("Links: Zoom, Meet, Teams und Webex vor anderen, Satzzeichen fallen weg") {
      try expectEqual(MeetingCompanion.extractLink("Agenda https://example.com/a. Einwahl: https://us02web.zoom.us/j/123456789)"),
                      "https://us02web.zoom.us/j/123456789")
      try expectEqual(MeetingCompanion.extractLink("Raum https://intern.example/x, meet: https://meet.google.com/abc-defg-hij."),
                      "https://meet.google.com/abc-defg-hij")
      try expectEqual(MeetingCompanion.extractLink("<https://teams.microsoft.com/l/meetup-join/abc>"),
                      "https://teams.microsoft.com/l/meetup-join/abc")
      try expectEqual(MeetingCompanion.extractLink("https://webex.com/meet/kunde."), "https://webex.com/meet/kunde")
    },
    CheckCase("Links: Fallback auf den ersten https-Link, sonst nil") {
      try expectEqual(MeetingCompanion.extractLink("Siehe http://alt.example und https://wiki.example/seite"),
                      "https://wiki.example/seite")
      try expectEqual(MeetingCompanion.extractLink(nil), nil)
      try expectEqual(MeetingCompanion.extractLink("kein Link hier"), nil)
    },
    CheckCase("Vorbereitung: Termin in (jetzt, +Vorlauf], ganztägige und bearbeitete ausgeschlossen") {
      let e1 = prEvent("e1", "2024-03-04T10:00", "2024-03-04T10:30", title: "Kunde")
      let events = [e1, prEvent("e2", "2024-03-04", allDay: true, title: "Feiertag"),
                    prEvent("e3", "2024-03-04T12:00")]
      try expectEqual(MeetingCompanion.key(e1), "local|e1|2024-03-04T10:00")
      let found = MeetingCompanion.upcoming(events: events, now: "2024-03-04T09:50", leadMinutes: 15, handled: [])
      try expectEqual(found?.id, "e1")
      try expectEqual(MeetingCompanion.upcoming(events: events, now: "2024-03-04T09:30", leadMinutes: 15, handled: []),
                      nil)
      try expectEqual(MeetingCompanion.upcoming(events: events, now: "2024-03-04T09:50", leadMinutes: 15,
                                                handled: [MeetingCompanion.key(e1) + "#upcoming"]), nil)
    },
    CheckCase("Nachbereitung: Ende vor höchstens 30 Minuten, mindestens 15 Minuten Dauer") {
      let events = [prEvent("e1", "2024-03-04T09:00", "2024-03-04T10:00", title: "Kunde"),
                    prEvent("e2", "2024-03-04T10:00", "2024-03-04T10:10", title: "Kurz")]
      try expectEqual(MeetingCompanion.ended(events: events, now: "2024-03-04T10:10", handled: [])?.id, "e1")
      try expectEqual(MeetingCompanion.ended(events: events, now: "2024-03-04T10:45", handled: []), nil)
      try expectEqual(MeetingCompanion.ended(events: events, now: "2024-03-04T10:10",
                                             handled: [MeetingCompanion.key(events[0]) + "#ended"]), nil)
    },
    CheckCase("Verwandte Notizen und Aufgaben über Schlüsselwörter, Karte mit Link") {
      let event = prEvent("m", "2024-03-04T10:00", "2024-03-04T11:00", title: "Projekt Phoenix Kickoff mit Team",
                          notes: "Einwahl: https://zoom.us/j/1)")
      let notes = [prNote("n1", "Phoenix Briefing"), prNote("n2", "Einkauf", "Milch"),
                   prNote("n3", "Kickoff-Notizen"), prNote("n4", "Team Liste"), prNote("n5", "Projekt Plan")]
      let tasks = [prTask("t1", "Phoenix Angebot"), prTask("t2", "Phoenix erledigt", done: true),
                   prTask("t3", "Rechnung", notes: "Team fragen"), prTask("t4", "Einkaufen")]
      let related = MeetingCompanion.related(event: event, notes: notes, tasks: tasks)
      try expectEqual(related.notes.map(\.id), ["n1", "n3", "n4"])
      try expectEqual(related.tasks.map(\.id), ["t1", "t3"])

      let brief = MeetingCompanion.brief(event: event, phase: .upcoming, notes: notes, tasks: tasks)
      try expectEqual(brief.link, "https://zoom.us/j/1")
      try expectEqual(brief.phase, .upcoming)
      try expectEqual(brief.id, "local|m|2024-03-04T10:00")
    },
    CheckCase("Stichpunkte aus Notizen werden zu Aufgaben") {
      let text = "Protokoll\n- Angebot schicken\n* Termin buchen\n• Rechnung prüfen\n[ ] Liste\n- [ ] Mail\n"
        + "TODO: Abstimmen\ntodo:  \nnormaler Satz\n-"
      try expectEqual(MeetingCompanion.tasksFromNotes(text),
                      ["Angebot schicken", "Termin buchen", "Rechnung prüfen", "Liste", "Mail", "Abstimmen"])
    },
  ]

  // MARK: Wochenrückblick

  static let weeklyChecks: [CheckCase] = [
    CheckCase("Montag der Woche: Sonntag gehört zur Vorwoche") {
      try expectEqual(WeeklyReviewBuilder.monday(of: "2024-03-04"), "2024-03-04")
      try expectEqual(WeeklyReviewBuilder.monday(of: "2024-03-06"), "2024-03-04")
      try expectEqual(WeeklyReviewBuilder.monday(of: "2024-03-10"), "2024-03-04")
      try expectEqual(WeeklyReviewBuilder.monday(of: "2024-03-11"), "2024-03-11")
      try expectEqual(WeeklyReviewBuilder.monday(of: "2023-12-31"), "2023-12-25")
    },
    CheckCase("isDue: Wochentag und Uhrzeit") {
      try expect(WeeklyReviewBuilder.isDue(now: "2024-03-10T18:00", day: 7, time: "18:00"))
      try expect(WeeklyReviewBuilder.isDue(now: "2024-03-10T18:30", day: 7, time: "18:00"))
      try expect(!WeeklyReviewBuilder.isDue(now: "2024-03-10T17:59", day: 7, time: "18:00"))
      try expect(!WeeklyReviewBuilder.isDue(now: "2024-03-10T18:30", day: 6, time: "18:00"))
      try expect(!WeeklyReviewBuilder.isDue(now: "2024-03-10", day: 7, time: "18:00"))
    },
    CheckCase("Wochenrückblick: erledigt, Habits und Fokus nur innerhalb der Woche") {
      let habit = Habit(id: "h", name: "Sport", createdAt: "2024-01-01", streak: 2)
      let tasks = [prTask("t1", "A", done: true, doneAt: "2024-03-05T10:00"),
                   prTask("t2", "Alt", done: true, doneAt: "2024-02-28T10:00"),
                   prTask("t3", "C", done: true, doneAt: "2024-03-07T11:00"), prTask("t4", "Offen")]
      let review = WeeklyReviewBuilder.build(
        weekStart: "2024-03-04", today: "2024-03-08", focusMinutes: 75, tasks: tasks,
        habitChecks: [(habit: habit, dates: ["2024-03-04", "2024-03-05", "2024-02-28", "2024-03-09", "2024-03-05"])],
        eventCount: 5, goals: [WeeklyGoal(id: "g", week: "2024-03-04", text: "Ziel")])
      try expectEqual(review.tasksDone, 2)
      try expectEqual(review.doneTitles, ["C", "A"])
      try expectEqual(review.habits, [HabitWeek(name: "Sport", days: 2, streak: 2)])
      try expectEqual(review.focusMinutes, 75)
      try expectEqual(review.events, 5)
      try expectEqual(review.goals.count, 1)
      try expectEqual(review.weekStart, "2024-03-04")
    },
  ]

  // MARK: Repositories

  static let repositoryChecks: [CheckCase] = [
    CheckCase("Tagesplan: speichern, lesen, ersetzen, löschen") {
      let store = try prStore()
      let repo = store.dayPlans
      try expectEqual(try repo.get("2024-03-04"), nil)
      let plan = DayPlan(date: "2024-03-04", blocks: [
        PlannedBlock(id: "a@2024-03-04T08:00", taskId: "a", title: "A", start: "2024-03-04T08:00",
                     end: "2024-03-04T08:30"),
      ], unplanned: ["b"])
      try repo.save(plan)
      try expectEqual(try repo.get("2024-03-04"), plan)
      var changed = plan
      changed.unplanned = []
      try repo.save(changed)
      try expectEqual(try repo.get("2024-03-04"), changed)
      try repo.delete("2024-03-04")
      try expectEqual(try repo.get("2024-03-04"), nil)
    },
    CheckCase("Wochenziele: trimmen, leere auslassen, höchstens drei, erledigt setzen") {
      let store = try prStore()
      let repo = store.weeklyGoals
      let goals = try repo.replace(week: "2024-03-04", texts: ["  Sport  ", "", "Buch lesen", "Dritter", "Vierter"],
                                   now: "2024-03-03T18:00")
      try expectEqual(goals.map(\.text), ["Sport", "Buch lesen", "Dritter"])
      let done = try repo.setDone(goals[1].id, true)
      try expectEqual(done?.done, true)
      try expectEqual(try repo.list(week: "2024-03-04").map(\.done), [false, true, false])
      try expectEqual(try repo.list(week: "2024-03-11"), [])
      try expectEqual(try repo.setDone("gibt-es-nicht", true), nil)
      try expectEqual(try repo.replace(week: "2024-03-04", texts: ["Neu"], now: "2024-03-03T18:00").map(\.text),
                      ["Neu"])
    },
    CheckCase("Wochen-Stand: setzen, schlummern, zurücksetzen") {
      let store = try prStore()
      let repo = store.weeklyReview
      try expectEqual(try repo.get("2024-03-04"), nil)
      try repo.set("2024-03-04", state: .snoozed, snoozeUntil: "2024-03-10T18:30")
      let snoozed = try expectNotNil(try repo.get("2024-03-04"))
      try expectEqual(snoozed.state, .snoozed)
      try expectEqual(snoozed.snoozeUntil, "2024-03-10T18:30")
      try expectEqual(snoozed.date, "2024-03-04")
      try repo.set("2024-03-04", state: .done, snoozeUntil: nil)
      let done = try expectNotNil(try repo.get("2024-03-04"))
      try expectEqual(done.state, .done)
      try expectEqual(done.snoozeUntil, nil)
    },
    CheckCase("Auswertung: Fokus-Minuten und Habit-Haken im Zeitraum, Migration 8 angewendet") {
      let store = try prStore()
      try expect(try store.db.appliedMigrations().contains(8), "Migration 8 fehlt")
      let sessions: [(id: String, phase: String, started: String, minutes: Int, completed: Int)] = [
        ("f1", "work", "2024-03-04T09:00:00", 25, 1),
        ("f2", "work", "2024-03-05T09:00:00", 25, 0),
        ("f3", "rest", "2024-03-05T09:30:00", 5, 1),
        ("f4", "work", "2024-03-11T09:00:00", 25, 1),
        ("f5", "work", "2024-03-10T20:00:00", 50, 1),
      ]
      for s in sessions {
        try store.db.run(
          "INSERT INTO focus_sessions (id, task_id, title, phase, started_at, ends_at, minutes, finished_at, completed) "
            + "VALUES (?, NULL, 'Fokus', ?, ?, ?, ?, NULL, ?)",
          [.text(s.id), .text(s.phase), .text(s.started), .text(s.started), .of(s.minutes), .of(s.completed)])
      }
      try expectEqual(try store.weeklyStats.focusMinutes(from: "2024-03-04", to: "2024-03-10"), 75)

      let habit = try store.habits.add(name: "Sport")
      for date in ["2024-03-02", "2024-03-04", "2024-03-10", "2024-03-11"] {
        _ = try store.habits.check(habit.id, date: date)
      }
      try expectEqual(try store.weeklyStats.habitCheckDates(habitId: habit.id, from: "2024-03-04", to: "2024-03-10"),
                      ["2024-03-04", "2024-03-10"])
    },
  ]

  // MARK: Datei-Text

  static let fileTextChecks: [CheckCase] = [
    CheckCase("Datei-Text: Klartext wird gelesen und getrimmt") {
      let url = try prTempFile("notiz.txt", Data("Hallo Welt\nZeile zwei\n".utf8))
      try expectEqual(try FileTextExtractor.extract(url), "Hallo Welt\nZeile zwei")
    },
    CheckCase("Datei-Text: RTF wird als Text gelesen") {
      let url = try prTempFile("brief.rtf", Data("{\\rtf1\\ansi Hallo RTF}".utf8))
      let text = try FileTextExtractor.extract(url)
      try expect(text.contains("Hallo RTF"), "RTF-Text fehlt: \(text)")
    },
    CheckCase("Datei-Text: leere Datei wirft empty") {
      let url = try prTempFile("leer.txt", Data())
      do {
        _ = try FileTextExtractor.extract(url)
        throw fail("leere Datei sollte werfen")
      } catch let error as FileTextError {
        try expectEqual(error, .empty)
      }
    },
    CheckCase("Datei-Text: Binärdatei wirft unsupported, maxChars kürzt") {
      let binary = try prTempFile("daten.bin", Data([0x00, 0x01, 0x02, 0x41]))
      do {
        _ = try FileTextExtractor.extract(binary)
        throw fail("Binärdatei sollte werfen")
      } catch let error as FileTextError {
        try expectEqual(error, .unsupported)
      }
      let long = try prTempFile("lang.txt", Data(String(repeating: "a", count: 100).utf8))
      try expectEqual(try FileTextExtractor.extract(long, maxChars: 10).count, 10)
    },
    CheckCase("Datei-Text: Dateien über 20 MB werden nicht gelesen") {
      let big = try prTempFile("gross.txt", Data(count: FileTextExtractor.maxBytes + 1))
      do {
        _ = try FileTextExtractor.extract(big)
        throw fail("große Datei sollte werfen")
      } catch let error as FileTextError {
        try expectEqual(error, .tooLarge)
      }
    },
    CheckCase("Datei-Text: HTML außerhalb des Hauptthreads ohne Tags und Skripte") {
      let html = "<html><head><style>p{color:red}</style></head><body><script>var x=1;</script><p>Hallo &amp; Welt</p></body></html>"
      let url = try prTempFile("seite.html", Data(html.utf8))
      let text = try await Task.detached { try FileTextExtractor.extract(url) }.value
      try expectEqual(text, "Hallo & Welt")
    },
  ]
}
