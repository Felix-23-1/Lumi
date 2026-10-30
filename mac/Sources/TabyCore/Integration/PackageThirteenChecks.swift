// Prüfungen für Paket 13: gewählte Aufgaben mit festen Uhrzeiten (AutoPlanner.planChosen),
// Umplanen und Umsortieren ohne Verschieben festgesetzter Blöcke, und planTasks gegen den
// echten Kern (Speicher, steuerbare Uhr). Ohne Modell.
import Foundation

private func pwTask(_ id: String, _ title: String, done: Bool = false) -> TabyTask {
  TabyTask(id: id, title: title, notes: nil, due: nil, done: done, doneAt: nil, createdAt: "2024-02-01T09:00")
}

private func pwEvent(_ id: String, _ start: String, _ end: String) -> CalendarEvent {
  CalendarEvent(id: id, sourceId: "local", title: "Termin", start: start, end: end)
}

enum PackageThirteenChecks {
  @MainActor static var suite: CheckSuite {
    CheckSuite("Paket 13 Gewählte Aufgaben", pureChecks + [integrationCheck])
  }

  static let pureChecks: [CheckCase] = [
    CheckCase("Festgesetzt: 10:30 für 60 Minuten bleibt genau dort") {
      let plan = AutoPlanner.planChosen(items: [PlanItem(taskId: "a", start: "10:30", minutes: 60)],
                                        tasks: [pwTask("a", "A")], events: [], now: "2024-03-04T08:00",
                                        bufferMinutes: 0)
      try expectEqual(plan.blocks.count, 1)
      try expectEqual(plan.blocks[0].start, "2024-03-04T10:30")
      try expectEqual(plan.blocks[0].end, "2024-03-04T11:30")
      try expect(plan.blocks[0].isPinned, "Block ist nicht festgesetzt")
      try expectEqual(plan.unplanned, [])
    },
    CheckCase("Festgesetzt überlappt einen Termin, bleibt trotzdem stehen") {
      let plan = AutoPlanner.planChosen(items: [PlanItem(taskId: "a", start: "11:30", minutes: 60)],
                                        tasks: [pwTask("a", "A")],
                                        events: [pwEvent("m", "2024-03-04T11:00", "2024-03-04T12:00")],
                                        now: "2024-03-04T08:00", bufferMinutes: 0)
      try expectEqual(plan.blocks.first?.start, "2024-03-04T11:30")
    },
    CheckCase("Automatisch: packt um Termin und festgesetzten Block herum, in gegebener Reihenfolge") {
      let items = [PlanItem(taskId: "p", start: "10:30", minutes: 60), PlanItem(taskId: "a", minutes: 120),
                   PlanItem(taskId: "c", minutes: 120)]
      let tasks = [pwTask("p", "P"), pwTask("a", "A"), pwTask("c", "C")]
      let plan = AutoPlanner.planChosen(items: items, tasks: tasks,
                                        events: [pwEvent("m", "2024-03-04T11:00", "2024-03-04T12:00")],
                                        now: "2024-03-04T08:00", bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["a", "p", "c"])
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T10:30", "2024-03-04T12:00"])
      try expect(plan.blocks[0].pinned != true, "automatischer Block ist festgesetzt")
      try expectEqual(plan.unplanned, [])
    },
    CheckCase("Ungültige Uhrzeit wird wie automatisch behandelt") {
      let items = [PlanItem(taskId: "a", start: "25:00", minutes: 30), PlanItem(taskId: "b", start: "9am", minutes: 30),
                   PlanItem(taskId: "c", start: "8:00", minutes: 30)]
      let tasks = [pwTask("a", "A"), pwTask("b", "B"), pwTask("c", "C")]
      let plan = AutoPlanner.planChosen(items: items, tasks: tasks, events: [], now: "2024-03-04T08:00",
                                        bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["a", "b", "c"])
      try expectEqual(plan.blocks.first?.start, "2024-03-04T08:00")
      try expect(plan.blocks.allSatisfy { $0.pinned != true }, "ungültige Uhrzeit wurde festgesetzt")
    },
    CheckCase("Erledigte, unbekannte und doppelte Aufgaben werden ignoriert") {
      let items = [PlanItem(taskId: "done", minutes: 30), PlanItem(taskId: "ghost", minutes: 30),
                   PlanItem(taskId: "b", minutes: 30), PlanItem(taskId: "b", start: "10:00", minutes: 30)]
      let tasks = [pwTask("done", "Fertig", done: true), pwTask("b", "B")]
      let plan = AutoPlanner.planChosen(items: items, tasks: tasks, events: [], now: "2024-03-04T08:00",
                                        bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["b"])
      try expectEqual(plan.blocks.first?.pinned, nil)
      try expectEqual(plan.unplanned, [])
    },
    CheckCase("Zu viel für den Tag: Rest landet in unplanned") {
      let items = [PlanItem(taskId: "a", minutes: 60), PlanItem(taskId: "b", minutes: 60)]
      let plan = AutoPlanner.planChosen(items: items, tasks: [pwTask("a", "A"), pwTask("b", "B")], events: [],
                                        now: "2024-03-04T08:00", dayEnd: "09:00", bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.taskId), ["a"])
      try expectEqual(plan.unplanned, ["b"])
    },
    CheckCase("Dauer wird auf 5 bis 480 Minuten begrenzt") {
      let plan = AutoPlanner.planChosen(items: [PlanItem(taskId: "a", start: "08:00", minutes: 1000),
                                                PlanItem(taskId: "b", start: "18:00", minutes: 0)],
                                        tasks: [pwTask("a", "A"), pwTask("b", "B")], events: [],
                                        now: "2024-03-04T08:00", bufferMinutes: 0)
      try expectEqual(AutoPlanner.toMinutes(plan.blocks[0].end)! - AutoPlanner.toMinutes(plan.blocks[0].start)!, 480)
      try expectEqual(AutoPlanner.toMinutes(plan.blocks[1].end)! - AutoPlanner.toMinutes(plan.blocks[1].start)!, 5)
    },
    CheckCase("Umplanen nach neuem Termin: festgesetzter Block bleibt, nur der automatische wandert") {
      let tasks = [pwTask("a", "A"), pwTask("b", "B"), pwTask("p", "P")]
      let items = [PlanItem(taskId: "a", minutes: 30), PlanItem(taskId: "b", minutes: 30),
                   PlanItem(taskId: "p", start: "10:30", minutes: 60)]
      let plan = AutoPlanner.planChosen(items: items, tasks: tasks, events: [], now: "2024-03-04T08:00",
                                        bufferMinutes: 0)
      try expectEqual(plan.blocks.map(\.start), ["2024-03-04T08:00", "2024-03-04T08:35", "2024-03-04T10:30"])
      let pinnedBefore = plan.blocks.first { $0.isPinned }
      // Neuer Termin 08:40–08:50 kollidiert mit b (08:35), a hat schon begonnen.
      let result = AutoPlanner.replan(plan, tasks: tasks, events: [pwEvent("anruf", "2024-03-04T08:40",
                                                                            "2024-03-04T08:50")],
                                      now: "2024-03-04T08:10", dayEnd: "20:00", blockMinutes: 30, bufferMinutes: 0)
      try expectEqual(result.plan.blocks.first { $0.isPinned }, pinnedBefore)
      try expectEqual(result.moved.map(\.taskId), ["b"])
      try expectEqual(result.plan.blocks.first { $0.taskId == "b" }?.start, "2024-03-04T08:50")
    },
    CheckCase("Umplanen: festgesetzter Block bleibt bei offener Aufgabe, fällt bei erledigter oder gelöschter weg") {
      let pinned = PlannedBlock(id: "p@x", taskId: "p", title: "P", start: "2024-03-04T10:30",
                                end: "2024-03-04T11:30", pinned: true, reason: AutoPlanner.userPinReason)
      let old = DayPlan(date: "2024-03-04", blocks: [pinned])
      func run(_ tasks: [TabyTask]) -> [PlannedBlock] {
        AutoPlanner.replan(old, tasks: tasks, events: [], now: "2024-03-04T12:00", dayEnd: "20:00",
                           blockMinutes: 30, bufferMinutes: 0).plan.blocks
      }
      try expectEqual(run([pwTask("p", "P"), pwTask("b", "B")]), [pinned])
      try expectEqual(run([pwTask("p", "P", done: true), pwTask("b", "B")]), [])
      try expectEqual(run([pwTask("b", "B")]), [])
    },
    CheckCase("Automatisch planen: festgesetzter Block bleibt, Rest wird drumherum gepackt") {
      let pinned = PlannedBlock(id: "p@x", taskId: "p", title: "P", start: "2024-03-04T08:00",
                                end: "2024-03-04T09:00", pinned: true, reason: AutoPlanner.userPinReason)
      let gone = PlannedBlock(id: "g@x", taskId: "g", title: "G", start: "2024-03-04T12:00",
                              end: "2024-03-04T13:00", pinned: true)
      let plan = AutoPlanner.plan(tasks: [pwTask("p", "P"), pwTask("a", "A")], events: [],
                                  now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0,
                                  pinned: [pinned, gone])
      try expectEqual(plan.blocks.map(\.taskId), ["p", "a"])
      try expectEqual(plan.blocks[0], pinned)
      try expectEqual(plan.blocks[1].start, "2024-03-04T09:00")
    },
    CheckCase("Umsortieren: ✕ auf einem festgesetzten Block nimmt ihn heraus") {
      let pinned = PlannedBlock(id: "p@x", taskId: "p", title: "P", start: "2024-03-04T10:30",
                                end: "2024-03-04T11:30", pinned: true)
      let result = AutoPlanner.reorder(["a"], tasks: [pwTask("a", "A"), pwTask("p", "P")], events: [],
                                       now: "2024-03-04T08:00", blockMinutes: 30, bufferMinutes: 0, pinned: [pinned])
      try expectEqual(result.blocks.map(\.taskId), ["a"])
    },
    CheckCase("Festgesetzt 23:30 für 60 Minuten endet um 23:59 desselben Tages") {
      let plan = AutoPlanner.planChosen(items: [PlanItem(taskId: "a", start: "23:30", minutes: 60)],
                                        tasks: [pwTask("a", "A")], events: [], now: "2024-03-31T08:00",
                                        bufferMinutes: 0)
      try expectEqual(plan.blocks.first?.end, "2024-03-31T23:59")
    },
    CheckCase("Umsortieren: festgesetzter Block bleibt, nur der Rest wird in der neuen Reihenfolge gepackt") {
      let tasks = [pwTask("a", "A"), pwTask("b", "B"), pwTask("p", "P")]
      let items = [PlanItem(taskId: "a", minutes: 30), PlanItem(taskId: "p", start: "10:30", minutes: 60)]
      let plan = AutoPlanner.planChosen(items: items, tasks: tasks, events: [], now: "2024-03-04T08:00",
                                        bufferMinutes: 0)
      let pinnedBefore = plan.blocks.filter(\.isPinned)
      let result = AutoPlanner.reorder(["b", "p", "a"], tasks: tasks, events: [], now: "2024-03-04T08:00",
                                       blockMinutes: 30, bufferMinutes: 0, pinned: pinnedBefore)
      try expectEqual(result.blocks.first { $0.isPinned }, pinnedBefore.first)
      try expectEqual(result.blocks.first { $0.taskId == "b" }?.start, "2024-03-04T08:00")
      try expectEqual(result.blocks.first { $0.taskId == "a" }?.start, "2024-03-04T08:35")
      try expectEqual(result.blocks.count, 3)
    },
  ]

  @MainActor static var integrationCheck: CheckCase {
    CheckCase("Integration: planTasks speichert festgesetzte und automatische Blöcke, leere Liste löscht") {
    let rig = try IntegrationRig()  // Montag 08:00 (2026-10-12)
    let svc = rig.svc
    _ = await svc.addTask(title: "Alpha", notes: nil, due: nil)
    _ = await svc.addTask(title: "Beta", notes: nil, due: nil)
    let tasks = await svc.state().tasks
    let alpha = tasks.first { $0.title == "Alpha" }?.id ?? ""
    let beta = tasks.first { $0.title == "Beta" }?.id ?? ""
    guard case .ok(let planned) = await svc.planTasks([PlanItem(taskId: alpha, start: "10:30", minutes: 60),
                                                       PlanItem(taskId: beta, minutes: 30)]) else {
      throw CheckFailure(message: "planTasks fehlgeschlagen", location: "")
    }
    try expectEqual(planned.blocks.first { $0.taskId == alpha }?.start, "2026-10-12T10:30")
    try expectEqual(planned.blocks.first { $0.taskId == beta }?.start, "2026-10-12T08:00")
    let state = await svc.state()
    try expectEqual(state.plan?.blocks.first { $0.taskId == alpha }?.isPinned, true)
    try expectEqual(state.plan?.blocks.map(\.taskId).sorted(), [alpha, beta].sorted())

    // „Neu planen“ (planDay) lässt die festgesetzte Zeit stehen.
    guard case .ok(let again) = await svc.planDay() else {
      throw CheckFailure(message: "planDay fehlgeschlagen", location: "")
    }
    let kept = again.blocks.first { $0.taskId == alpha }
    try expectEqual(kept?.start, "2026-10-12T10:30")
    try expectEqual(kept?.isPinned, true)
    try expectEqual(again.blocks.filter { $0.taskId == alpha }.count, 1)

    guard case .ok(let cleared) = await svc.planTasks([]) else {
      throw CheckFailure(message: "planTasks([]) fehlgeschlagen", location: "")
    }
    try expectEqual(cleared.blocks, [])
    let after = await svc.state()
    try expectEqual(after.plan, nil)
    }
  }
}
