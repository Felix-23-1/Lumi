// Prüfungen für Sources/TabyCore/Planner (Agent C). Port der TS-Tests aus
// src/main/planner/*.test.ts plus Szenarien B–E auf Logik-Ebene.
import Foundation

private func at(_ iso: String) -> Date {
  guard let d = LocalTime.parse(iso) else { preconditionFailure("ungültige Zeit \(iso)") }
  return d
}

private func comp(_ c: Calendar.Component, _ d: Date?) -> Int? {
  d.map { LocalTime.calendar.component(c, from: $0) }
}

private func task(_ id: String, _ title: String, due: String?, done: Bool = false) -> TabyTask {
  TabyTask(id: id, title: title, due: due, done: done, createdAt: "2026-01-01T00:00")
}

private func event(_ id: String, _ title: String, start: String, allDay: Bool = false) -> CalendarEvent {
  CalendarEvent(id: id, sourceId: "local", title: title, start: start, allDay: allDay)
}

private final class Box<T> {
  var value: T
  init(_ v: T) { value = v }
}

private final class FakeLlm: LlmClient {
  let reply: () throws -> ChatMessage
  init(_ reply: @escaping () throws -> ChatMessage) { self.reply = reply }
  func chat(messages: [ChatMessage], tools: [ToolDef]?) async throws -> ChatMessage { try reply() }
}

private struct ProgrammingError: Error {}

private struct Harness {
  let clock: ControllableClock
  let planner: Planner
  let notifier: SinkNotifier
  let reminders: InMemoryPlannerReminderStore
  let jobRuns: InMemoryPlannerJobRunStore
  let runnerCalls: Box<[Job]>
  let taskCalls: Box<Int>
  let savedStates: Box<[DailyState]>
}

private func makeHarness(
  _ clock: ControllableClock, tasks: [TabyTask] = [], events: [CalendarEvent] = [], jobs: [Job] = [],
  leadMinutes: Box<Int> = Box(10), dailyState: DailyState? = nil,
  runner: ((Job) async throws -> JobRunResult)? = nil
) -> Harness {
  let notifier = SinkNotifier()
  let reminders = InMemoryPlannerReminderStore()
  let jobRuns = InMemoryPlannerJobRunStore()
  let runnerCalls = Box<[Job]>([])
  let taskCalls = Box(0)
  let saved = Box<[DailyState]>([])
  let planner = Planner(
    clock: clock, notifier: notifier, reminders: reminders, jobRuns: jobRuns,
    tasksSource: { taskCalls.value += 1; return tasks },
    eventsSource: { from, to in
      PlannerEventRead(events: events.filter { LocalTime.datePart($0.start) >= from && LocalTime.datePart($0.start) <= to })
    },
    jobsSource: { jobs },
    jobRunner: { job in
      runnerCalls.value.append(job)
      if let runner { return try await runner(job) }
      return JobRunResult(ok: true, output: "erledigt: \(job.name)")
    },
    eventLeadMinutes: { leadMinutes.value },
    dailyState: dailyState,
    onDailyStateChange: { saved.value.append($0) },
    // Die Zustandstests laufen an festen Daten (auch Samstag): jeder Tag ist Arbeitstag.
    workSettings: { var s = TabySettings.defaults; s.workHours = Array(repeating: "08:00-17:00", count: 7); return s }
  )
  return Harness(clock: clock, planner: planner, notifier: notifier, reminders: reminders, jobRuns: jobRuns,
                 runnerCalls: runnerCalls, taskCalls: taskCalls, savedStates: saved)
}

private func dailyJob(_ time: String, createdAt: String) -> Job {
  Job(id: "j1", name: "Tagesreport", prompt: "x", rule: .daily(time: time), mode: .readOnly, createdAt: createdAt)
}

enum PlannerChecks {
  static let suite = CheckSuite("Planner", reminderSync + dayStart + dayEnd + dayEndPlanner + workdayStart + jobSchedule + briefing + planner + retirement + notifiers + BreakMemoryChecks.pure + GermanDateParserChecks.cases + EventDetectorChecks.cases + reflowChecks)

  /// Planer mit Tagesabschluss-Einstellungen; liefert die gespeicherten Zustände mit.
  private struct DayEndHarness {
    let clock: ControllableClock
    let planner: Planner
    let tasks: Box<[TabyTask]>
    let saved: Box<[DayEndRecord]>
    let time: Box<String>
  }

  private static func dayEndHarness(
    _ clock: ControllableClock, tasks: [TabyTask], record: DayEndRecord? = nil, time: String = "20:00"
  ) -> DayEndHarness {
    let taskBox = Box(tasks)
    let saved = Box<[DayEndRecord]>([])
    let timeBox = Box(time)
    let planner = Planner(
      clock: clock, notifier: SinkNotifier(), reminders: InMemoryPlannerReminderStore(),
      jobRuns: InMemoryPlannerJobRunStore(),
      tasksSource: { taskBox.value },
      eventsSource: { _, _ in PlannerEventRead(events: []) },
      jobsSource: { [] },
      jobRunner: { _ in JobRunResult(ok: true) },
      dayEnd: record,
      dayEndSettings: { (true, timeBox.value) },
      onDayEndChange: { saved.value.append($0) }
    )
    return DayEndHarness(clock: clock, planner: planner, tasks: taskBox, saved: saved, time: timeBox)
  }

  /// Tagesstart fragt nur an Arbeitstagen: Mo–Fr 08:00–17:00 (Standard), Sa/So frei.
  private static func workdayPlanner(_ clock: ControllableClock) -> Planner {
    Planner(
      clock: clock, notifier: SinkNotifier(), reminders: InMemoryPlannerReminderStore(),
      jobRuns: InMemoryPlannerJobRunStore(),
      tasksSource: { [] },
      eventsSource: { _, _ in PlannerEventRead(events: []) },
      jobsSource: { [] },
      jobRunner: { _ in JobRunResult(ok: true) },
      workSettings: { .defaults }
    )
  }

  static let workdayStart: [CheckCase] = [
    CheckCase("Tagesstart: am freien Samstag nicht fragen, Zustand bleibt none") {
      let p = workdayPlanner(ControllableClock("2026-03-14T09:00"))
      let r = await p.onAppStart()
      try expect(!r.showQuestion)
      try expectEqual(r.state.state, DayStartState.none)
    },
    CheckCase("Tagesstart: am Arbeitstag wie bisher fragen") {
      let p = workdayPlanner(ControllableClock("2026-03-10T09:00"))
      let r = await p.onAppStart()
      try expect(r.showQuestion)
      try expectEqual(r.state.state, DayStartState.asked)
    },
  ]

  static let dayEndPlanner: [CheckCase] = [
    CheckCase("Planer Tagesabschluss: vor 20:00 nicht, ab 20:00 einmal") {
      let h = dayEndHarness(ControllableClock("2026-03-10T19:30"), tasks: [task("t1", "Bericht", due: "2026-03-10")])
      let early = await h.planner.tick()
      try expect(!early.showDayEnd)
      h.clock.set(at("2026-03-10T20:00"))
      let first = await h.planner.tick()
      try expect(first.showDayEnd, "ab 20:00 mit offener Aufgabe zeigen")
      try expect(first.changed, "showDayEnd zählt als Änderung")
      let second = await h.planner.tick()
      try expect(!second.showDayEnd, "nicht doppelt zeigen")
      let record = await h.planner.dayEndRecord
      try expectEqual(record, DayEndRecord(date: "2026-03-10", state: .asked))
    },
    CheckCase("Planer Tagesabschluss: überfällige offene Aufgabe zählt, erledigte nicht") {
      let h = dayEndHarness(ControllableClock("2026-03-10T21:00"), tasks: [
        task("t1", "erledigt", due: "2026-03-10", done: true),
        task("t2", "ohne Datum", due: nil),
        task("t3", "künftig", due: "2026-03-11"),
      ])
      let r = await h.planner.tick()
      try expect(!r.showDayEnd, "keine offene Aufgabe bis heute")
      let record = await h.planner.dayEndRecord
      try expectEqual(record, DayEndRecord(date: "2026-03-10", state: .done))
    },
    CheckCase("Planer Tagesabschluss: Später → nach 30 min wieder zeigen") {
      let h = dayEndHarness(ControllableClock("2026-03-10T20:00"), tasks: [task("t1", "X", due: "2026-03-09")])
      let shown = await h.planner.tick()
      try expect(shown.showDayEnd)
      let later = await h.planner.answerDayEnd(.later)
      try expectEqual(later, DayEndRecord(date: "2026-03-10", state: .snoozed, snoozeUntil: "2026-03-10T20:30"))
      h.clock.advance(seconds: 29 * 60)
      let beforeEnd = await h.planner.tick()
      try expect(!beforeEnd.showDayEnd, "vor Ablauf nicht")
      h.clock.advance(seconds: 60)
      let afterEnd = await h.planner.tick()
      try expect(afterEnd.showDayEnd, "nach 30 min wieder")
    },
    CheckCase("Planer Tagesabschluss: Antwort wird über den Callback gespeichert") {
      let h = dayEndHarness(ControllableClock("2026-03-10T20:05"), tasks: [task("t1", "X", due: "2026-03-10")])
      _ = await h.planner.tick()
      let r = await h.planner.answerDayEnd(.skip)
      try expectEqual(r, DayEndRecord(date: "2026-03-10", state: .skipped))
      try expectEqual(h.saved.value, [DayEndRecord(date: "2026-03-10", state: .asked),
                                      DayEndRecord(date: "2026-03-10", state: .skipped)])
      h.clock.advance(seconds: 3600)
      let later = await h.planner.tick()
      try expect(!later.showDayEnd, "übersprungen heute nie wieder")
    },
    CheckCase("Planer Tagesabschluss: App-Start zeigt unbeantwortete Frage erneut") {
      let h = dayEndHarness(ControllableClock("2026-03-10T20:10"), tasks: [task("t1", "X", due: "2026-03-10")],
                            record: DayEndRecord(date: "2026-03-10", state: .asked))
      let show = await h.planner.dayEndOnAppStart()
      try expect(show, "asked → beim Start erneut")
      let record = await h.planner.dayEndRecord
      try expectEqual(record, DayEndRecord(date: "2026-03-10", state: .asked))
    },
    CheckCase("Planer Tagesabschluss: gespeicherter Zustand eines alten Tages wird ignoriert") {
      let h = dayEndHarness(ControllableClock("2026-03-10T20:10"), tasks: [],
                            record: DayEndRecord(date: "2026-03-09", state: .done))
      let record = await h.planner.dayEndRecord
      try expectEqual(record, DayEndRecord(date: "2026-03-10", state: .none))
      let show = await h.planner.dayEndOnAppStart()
      try expect(!show, "ohne offene Aufgaben nichts zeigen")
    },
    CheckCase("Planer Tagesabschluss: deaktiviert → nie") {
      let clock = ControllableClock("2026-03-10T21:00")
      let planner = Planner(
        clock: clock, notifier: SinkNotifier(), reminders: InMemoryPlannerReminderStore(),
        jobRuns: InMemoryPlannerJobRunStore(),
        tasksSource: { [task("t1", "X", due: "2026-03-10")] },
        eventsSource: { _, _ in PlannerEventRead(events: []) }, jobsSource: { [] },
        jobRunner: { _ in JobRunResult(ok: true) },
        dayEndSettings: { (false, "20:00") }
      )
      let tick = await planner.tick()
      try expect(!tick.showDayEnd)
      let show = await planner.dayEndOnAppStart()
      try expect(!show)
    },
  ]

  // MARK: Tagesabschluss (DayEndMachine)

  static let dayEnd: [CheckCase] = {
    let d = "2026-03-10"
    let time = "20:00"
    func evalEnd(_ r: DayEndRecord?, _ now: String, open: Bool = true, trigger: DayStartTrigger = .tick,
                 enabled: Bool = true) -> (record: DayEndRecord, showQuestion: Bool) {
      DayEndMachine.evaluate(r, now: at(now), time: time, enabled: enabled, trigger: trigger, hasOpenTasks: open)
    }
    return [
      CheckCase("Tagesabschluss: vor der Uhrzeit nie zeigen") {
        let r = evalEnd(nil, "\(d)T19:59")
        try expect(!r.showQuestion)
        try expectEqual(r.record, DayEndRecord(date: d, state: .none))
      },
      CheckCase("Tagesabschluss: ab der Uhrzeit mit offenen Aufgaben → zeigen, asked") {
        let r = evalEnd(nil, "\(d)T20:00")
        try expect(r.showQuestion)
        try expectEqual(r.record, DayEndRecord(date: d, state: .asked))
      },
      CheckCase("Tagesabschluss: ab der Uhrzeit ohne offene Aufgaben → done, still") {
        let r = evalEnd(nil, "\(d)T21:00", open: false)
        try expect(!r.showQuestion)
        try expectEqual(r.record, DayEndRecord(date: d, state: .done))
      },
      CheckCase("Tagesabschluss: asked + Tick → nicht erneut") {
        let s = DayEndRecord(date: d, state: .asked)
        let r = evalEnd(s, "\(d)T20:05")
        try expect(!r.showQuestion)
        try expectEqual(r.record, s)
      },
      CheckCase("Tagesabschluss: asked + Neustart → erneut, bleibt asked") {
        let r = evalEnd(DayEndRecord(date: d, state: .asked), "\(d)T21:00", trigger: .restart)
        try expect(r.showQuestion)
        try expectEqual(r.record, DayEndRecord(date: d, state: .asked))
      },
      CheckCase("Tagesabschluss: snoozed vor Ablauf → nichts") {
        let s = DayEndRecord(date: d, state: .snoozed, snoozeUntil: "\(d)T20:30")
        let r = evalEnd(s, "\(d)T20:29")
        try expect(!r.showQuestion)
        try expectEqual(r.record, s)
      },
      CheckCase("Tagesabschluss: snoozed bei Ablauf → erneut zeigen") {
        let s = DayEndRecord(date: d, state: .snoozed, snoozeUntil: "\(d)T20:30")
        let r = evalEnd(s, "\(d)T20:30")
        try expect(r.showQuestion)
        try expectEqual(r.record, DayEndRecord(date: d, state: .asked))
      },
      CheckCase("Tagesabschluss: done/skipped nie wieder am selben Tag") {
        for st in [DayStartState.done, .skipped] {
          let s = DayEndRecord(date: d, state: st)
          let r = evalEnd(s, "\(d)T23:00", trigger: .restart)
          try expect(!r.showQuestion, "\(st) darf nicht erneut zeigen")
          try expectEqual(r.record, s)
        }
      },
      CheckCase("Tagesabschluss: neuer Tag setzt auf none zurück") {
        let r = evalEnd(DayEndRecord(date: "2026-03-09", state: .skipped), "\(d)T19:00")
        try expectEqual(r.record, DayEndRecord(date: d, state: .none))
        try expect(!r.showQuestion)
      },
      CheckCase("Tagesabschluss: deaktiviert → nie zeigen") {
        let r = evalEnd(nil, "\(d)T22:00", enabled: false)
        try expect(!r.showQuestion)
        try expect(!DayEndMachine.needsOpenTasks(nil, now: at("\(d)T22:00"), time: time, enabled: false))
      },
      CheckCase("Tagesabschluss: needsOpenTasks nur ab Uhrzeit bei none") {
        try expect(!DayEndMachine.needsOpenTasks(nil, now: at("\(d)T19:00"), time: time, enabled: true))
        try expect(DayEndMachine.needsOpenTasks(nil, now: at("\(d)T20:00"), time: time, enabled: true))
        try expect(!DayEndMachine.needsOpenTasks(DayEndRecord(date: d, state: .asked),
                                                 now: at("\(d)T21:00"), time: time, enabled: true))
      },
      CheckCase("Tagesabschluss: Antworten (später = genau 30 min)") {
        let now = at("\(d)T20:10")
        try expectEqual(DayEndMachine.answer(.later, record: nil, now: now),
                        DayEndRecord(date: d, state: .snoozed, snoozeUntil: "\(d)T20:40"))
        try expectEqual(DayEndMachine.answer(.moveAllToTomorrow, record: nil, now: now),
                        DayEndRecord(date: d, state: .done))
        try expectEqual(DayEndMachine.answer(.done, record: nil, now: now), DayEndRecord(date: d, state: .done))
        try expectEqual(DayEndMachine.answer(.skip, record: nil, now: now), DayEndRecord(date: d, state: .skipped))
      },
    ]
  }()

  // MARK: reminder-sync.test.ts

  static let reminderSync: [CheckCase] = [
    CheckCase("taskReminders: nur offene Aufgaben mit Uhrzeit") {
      let r = ReminderSync.taskReminders([
        task("t1", "mit Zeit", due: "2026-01-10T09:00"),
        task("t2", "nur Datum", due: "2026-01-10"),
        task("t3", "ohne", due: nil),
        task("t4", "erledigt", due: "2026-01-10T09:00", done: true),
      ])
      try expectEqual(r, [WantedReminder(source: .task, sourceRef: "t1", dueAt: "2026-01-10T09:00")])
    },
    CheckCase("eventReminders: N Minuten vorher, ganztägig ausgenommen") {
      let events = [event("e1", "Meeting", start: "2026-01-10T10:00"),
                    event("e2", "Geburtstag", start: "2026-01-10", allDay: true)]
      try expectEqual(ReminderSync.eventReminders(events, leadMinutes: 10),
                      [WantedReminder(source: .event, sourceRef: "e1", dueAt: "2026-01-10T09:50")])
      try expectEqual(ReminderSync.eventReminders(events, leadMinutes: 0), [])
    },
    CheckCase("sync: legt einmal an, lässt Ausgelöstes bei gleichem Termin in Ruhe") {
      let repo = InMemoryPlannerReminderStore()
      let wanted = [WantedReminder(source: .task, sourceRef: "t1", dueAt: "2026-01-10T09:00")]
      try ReminderSync.sync(wanted, into: repo)
      let created = try expectNotNil(try repo.listAll().first)
      try repo.markFired(created.id, firedAt: "2026-01-10T09:00")
      try ReminderSync.sync(wanted, into: repo)
      try expectEqual(try repo.listAll().count, 1)
      try expectEqual(try repo.listAll().first?.firedAt, "2026-01-10T09:00")
    },
    CheckCase("retireStale: fehlt ein Termin bei nicht erreichbarer Quelle, bleibt seine Erinnerung offen") {
      let repo = InMemoryPlannerReminderStore()
      try ReminderSync.sync([WantedReminder(source: .event, sourceRef: "e1", dueAt: "2026-01-10T09:50"),
                             WantedReminder(source: .task, sourceRef: "t1", dueAt: "2026-01-10T09:00")], into: repo)
      // Keine Termine mehr gewünscht (Quelle nicht erreichbar), die Aufgabe ist erledigt.
      try ReminderSync.retireStale([], eventsFrom: "2026-01-10", eventsTo: "2026-01-11", eventLeadMinutes: 10,
                                   acknowledgedAt: "2026-01-10T09:55", eventSourcesReachable: false, in: repo)
      let open = try repo.listAll().filter { $0.acknowledgedAt == nil }.map(\.id)
      try expectEqual(open, ["event:e1"], "Termin bleibt, Aufgabe wird zurückgezogen")
      // Quelle wieder erreichbar und Termin weg: jetzt gilt er als bestätigt.
      try ReminderSync.retireStale([], eventsFrom: "2026-01-10", eventsTo: "2026-01-11", eventLeadMinutes: 10,
                                   acknowledgedAt: "2026-01-10T09:56", in: repo)
      try expectEqual(try repo.listAll().filter { $0.acknowledgedAt == nil }.count, 0)
    },
    CheckCase("sync: geänderte Fälligkeit setzt firedAt zurück") {
      let repo = InMemoryPlannerReminderStore()
      try ReminderSync.sync([WantedReminder(source: .task, sourceRef: "t1", dueAt: "2026-01-10T09:00")], into: repo)
      try repo.markFired("task:t1", firedAt: "2026-01-10T09:00")
      try ReminderSync.sync([WantedReminder(source: .task, sourceRef: "t1", dueAt: "2026-01-10T15:00")], into: repo)
      let after = try expectNotNil(try repo.listAll().first)
      try expectEqual(after.dueAt, "2026-01-10T15:00")
      try expect(after.firedAt == nil, "firedAt sollte nil sein")
    },
    CheckCase("partitionDue: fällig vs. verpasst nach Kulanz, ignoriert ausgelöst/bestätigt") {
      let rs = [
        Reminder(id: "r1", source: .task, sourceRef: "t1", dueAt: "2026-01-10T09:59:30"),
        Reminder(id: "r2", source: .task, sourceRef: "t2", dueAt: "2026-01-10T08:00"),
        Reminder(id: "r3", source: .task, sourceRef: "t3", dueAt: "2026-01-10T11:00"),
        Reminder(id: "r4", source: .task, sourceRef: "t4", dueAt: "2026-01-10T07:00", firedAt: "2026-01-10T07:00"),
        Reminder(id: "r5", source: .task, sourceRef: "t5", dueAt: "2026-01-10T07:00",
                 acknowledgedAt: "2026-01-10T09:00"),
      ]
      let p = ReminderSync.partitionDue(rs, now: at("2026-01-10T10:00"), grace: 60)
      try expectEqual(p.due.map(\.id), ["r1"])
      try expectEqual(p.missed.map(\.id), ["r2"])
    },
  ]

  // MARK: daily-state.test.ts (Szenario B)

  static let dayStart: [CheckCase] = {
    let d1 = "2026-03-10", d2 = "2026-03-11"
    return [
      CheckCase("Tagesstart: none → asked, Frage zeigen") {
        let r = DayStartMachine.evaluate(DailyState(date: d1, state: .none), now: at("\(d1)T09:00"))
        try expect(r.showQuestion)
        try expectEqual(r.state, DailyState(date: d1, state: .asked))
      },
      CheckCase("Tagesstart: asked + Tick → nicht erneut") {
        let s = DailyState(date: d1, state: .asked)
        let r = DayStartMachine.evaluate(s, now: at("\(d1)T09:05"), trigger: .tick)
        try expect(!r.showQuestion)
        try expectEqual(r.state, s)
      },
      CheckCase("Tagesstart: asked + Neustart → erneut, bleibt asked") {
        let r = DayStartMachine.evaluate(DailyState(date: d1, state: .asked), now: at("\(d1)T10:00"), trigger: .restart)
        try expect(r.showQuestion)
        try expectEqual(r.state, DailyState(date: d1, state: .asked))
      },
      CheckCase("Tagesstart: snoozed vor Ablauf → nichts") {
        let s = DailyState(date: d1, state: .snoozed, snoozeUntil: "\(d1)T09:30")
        let r = DayStartMachine.evaluate(s, now: at("\(d1)T09:10"))
        try expect(!r.showQuestion)
        try expectEqual(r.state, s)
      },
      CheckCase("Tagesstart: snoozed nach Ablauf → erneut, asked") {
        let s = DailyState(date: d1, state: .snoozed, snoozeUntil: "\(d1)T09:30")
        let r = DayStartMachine.evaluate(s, now: at("\(d1)T09:30"))
        try expect(r.showQuestion)
        try expectEqual(r.state, DailyState(date: d1, state: .asked))
      },
      CheckCase("Tagesstart: done/skipped → heute nie wieder") {
        for st in [DayStartState.done, .skipped] {
          let s = DailyState(date: d1, state: st)
          try expect(!DayStartMachine.evaluate(s, now: at("\(d1)T20:00"), trigger: .tick).showQuestion)
          try expect(!DayStartMachine.evaluate(s, now: at("\(d1)T20:00"), trigger: .restart).showQuestion)
        }
      },
      CheckCase("Tagesstart: neuer Tag setzt zurück und fragt") {
        let r = DayStartMachine.evaluate(DailyState(date: d1, state: .done), now: at("\(d2)T08:00"))
        try expect(r.showQuestion)
        try expectEqual(r.state, DailyState(date: d2, state: .asked))
      },
      CheckCase("Tagesstart: höchstens einmal pro Tag (asked → Ja → done)") {
        var s = DayStartMachine.evaluate(DailyState(date: d1, state: .none), now: at("\(d1)T09:00")).state
        s = DayStartMachine.answer(.yes, state: s, now: at("\(d1)T09:01"))
        try expectEqual(s.state, .done)
        try expect(!DayStartMachine.evaluate(s, now: at("\(d1)T15:00")).showQuestion)
      },
      CheckCase("Tagesstart-Antworten: Ja/Später (+30 min)/Heute nicht") {
        let s = DailyState(date: d1, state: .asked)
        try expectEqual(DayStartMachine.answer(.yes, state: s, now: at("\(d1)T09:01")).state, .done)
        let later = DayStartMachine.answer(.later, state: s, now: at("\(d1)T09:00"))
        try expectEqual(later.state, .snoozed)
        try expectEqual(later.snoozeUntil, "\(d1)T09:30")
        try expectEqual(DayStartMachine.answer(.skip, state: s, now: at("\(d1)T09:01")).state, .skipped)
      },
    ]
  }()

  // MARK: job-schedule.test.ts

  static let jobSchedule: [CheckCase] = [
    CheckCase("nextDue daily: heute später") {
      let n = JobSchedule.nextDue(.daily(time: "09:00"), now: at("2026-01-10T08:00"))
      try expectEqual(n, at("2026-01-10T09:00"))
    },
    CheckCase("nextDue daily: morgen nach Ablauf (Mitternacht)") {
      let n = JobSchedule.nextDue(.daily(time: "09:00"), now: at("2026-01-10T23:30"))
      try expectEqual(comp(.day, n), 11); try expectEqual(comp(.hour, n), 9)
    },
    CheckCase("nextDue daily: genau zur Zeit ist nicht 'nächste'") {
      try expectEqual(comp(.day, JobSchedule.nextDue(.daily(time: "09:00"), now: at("2026-01-10T09:00"))), 11)
    },
    CheckCase("nextDue daily: Sommerzeit-Umstellung behält Wanduhrzeit") {
      let n = JobSchedule.nextDue(.daily(time: "09:00"), now: at("2026-03-28T10:00"))
      try expectEqual(comp(.day, n), 29); try expectEqual(comp(.hour, n), 9); try expectEqual(comp(.minute, n), 0)
    },
    CheckCase("nextDue weekly: nächster passender Wochentag") {
      let n = JobSchedule.nextDue(.weekly(days: [1, 4], time: "08:00"), now: at("2026-01-10T12:00"))
      try expectEqual(comp(.weekday, n), 2)  // Montag
      try expectEqual(comp(.day, n), 12)
    },
    CheckCase("nextDue weekly: gleicher Tag später zählt") {
      let n = JobSchedule.nextDue(.weekly(days: [1], time: "18:00"), now: at("2026-01-12T08:00"))
      try expectEqual(comp(.day, n), 12); try expectEqual(comp(.hour, n), 18)
    },
    CheckCase("weekly: Sonntag als 0 (Vertrag) und 7 (ISO) gleichwertig") {
      // 2026-01-11 ist ein Sonntag.
      for days in [[0], [7]] {
        try expectEqual(JobSchedule.nextDue(.weekly(days: days, time: "10:00"), now: at("2026-01-10T12:00")),
                        at("2026-01-11T10:00"))
      }
    },
    CheckCase("nextDue once: Zukunft, sonst nil") {
      try expectEqual(JobSchedule.nextDue(.once(at: "2026-05-01T10:00"), now: at("2026-04-01T00:00")),
                      at("2026-05-01T10:00"))
      try expect(JobSchedule.nextDue(.once(at: "2026-01-01T10:00"), now: at("2026-04-01T00:00")) == nil)
    },
    CheckCase("lastDue daily: heute früher") {
      let l = JobSchedule.lastDue(.daily(time: "09:00"), now: at("2026-01-10T10:00"))
      try expectEqual(comp(.day, l), 10); try expectEqual(comp(.hour, l), 9)
    },
    CheckCase("lastDue daily: gestern vor der Uhrzeit (Mitternacht)") {
      let l = JobSchedule.lastDue(.daily(time: "09:00"), now: at("2026-01-10T02:00"))
      try expectEqual(comp(.day, l), 9); try expectEqual(comp(.hour, l), 9)
    },
    CheckCase("lastDue daily: Winterzeit-Umstellung") {
      let l = JobSchedule.lastDue(.daily(time: "09:00"), now: at("2026-10-26T10:00"))
      try expectEqual(comp(.day, l), 26); try expectEqual(comp(.hour, l), 9)
    },
    CheckCase("lastDue weekly: letzter passender Wochentag") {
      let l = JobSchedule.lastDue(.weekly(days: [1, 4], time: "08:00"), now: at("2026-01-10T12:00"))
      try expectEqual(comp(.weekday, l), 5)  // Donnerstag
      try expectEqual(comp(.day, l), 8)
    },
    CheckCase("lastDue once: fällig, sonst nil") {
      try expectEqual(JobSchedule.lastDue(.once(at: "2026-01-01T10:00"), now: at("2026-04-01T00:00")),
                      at("2026-01-01T10:00"))
      try expect(JobSchedule.lastDue(.once(at: "2026-05-01T10:00"), now: at("2026-04-01T00:00")) == nil)
    },
  ]

  // MARK: briefing.test.ts

  static let briefing: [CheckCase] = [
    CheckCase("Briefing: nutzt das Modell, wenn es antwortet") {
      let llm = FakeLlm { ChatMessage(role: .assistant, content: "Hallo vom Modell.") }
      let b = try await BriefingBuilder.build(.empty, llm: llm)
      try expect(b.generatedByModel)
      try expectEqual(b.text, "Hallo vom Modell.")
    },
    CheckCase("Briefing: wiederholtes Muster („Stichpunkte: … Briefing: …“) wird entfernt") {
      let llm = FakeLlm { ChatMessage(role: .assistant,
                                      content: "Stichpunkte: Aufgaben heute: X\n\nBriefing: Heute steht X an.") }
      let b = try await BriefingBuilder.build(.empty, llm: llm)
      try expectEqual(b.text, "Heute steht X an.")
      try expectEqual(BriefingBuilder.cleanReply("Stichpunkte: a\nNur Text."), "Nur Text.")
    },
    CheckCase("Briefing: Fallback ohne Modell und ohne Netz (deutsch, regelbasiert)") {
      let o = Overview(overdueTasks: [task("t1", "Rechnung zahlen", due: nil)],
                       eventsToday: [event("e1", "Zahnarzt", start: "2026-01-10T09:00")],
                       missed: [ReminderWithTitle(reminder: Reminder(id: "r", source: .task, sourceRef: "t",
                                                                     dueAt: "2026-01-10T07:00"), title: "X")])
      let b = try await BriefingBuilder.build(o, llm: nil)
      try expect(!b.generatedByModel)
      try expect(b.text.contains("Zahnarzt"), b.text)
      try expect(b.text.contains("Rechnung zahlen"), b.text)
      try expect(b.text.contains("Verpasst: 1"), b.text)
      try expect(b.text.contains("Termine heute"), b.text)
    },
    CheckCase("Briefing: Fallback bei jedem LlmError-Code") {
      for code in [LlmErrorCode.auth, .quota, .noTools, .rateLimit, .network, .badResponse, .cancelled, .unknown] {
        let llm = FakeLlm { throw LlmError(code, "boom \(code.rawValue)") }
        let b = try await BriefingBuilder.build(Overview(todayTasks: [task("t", "X", due: nil)]), llm: llm)
        try expect(!b.generatedByModel, code.rawValue)
        try expect(b.text.contains("X"))
      }
    },
    CheckCase("Briefing: Stichpunkte fürs Modell ohne IDs, Leeres und Quittiertes") {
      // Der Fall vom 13.10.2026: Geburtstag, quittierte Erinnerung ohne Titel, ein Habit.
      let o = Overview(
        habitsToday: [Habit(id: "h1", name: "Pausen machen beim Arbeiten", createdAt: "2026-10-01T08:00", streak: 1)],
        eventsToday: [event("e1", "Katrin Geburtstag", start: "2026-10-13", allDay: true)],
        remindersToday: [ReminderWithTitle(reminder: Reminder(id: "r1", source: .task, sourceRef: "c3106291-aaaa",
                                                              dueAt: "2026-10-13T09:00", firedAt: "2026-10-13T00:17",
                                                              acknowledgedAt: "2026-10-13T00:17"), title: "")])
      try expectEqual(BriefingBuilder.facts(o),
                      "Ganztägig heute: Katrin Geburtstag\nOffene Habits: Pausen machen beim Arbeiten")
      let busy = Overview(overdueTasks: [task("t1", "Steuer", due: "2026-10-10")],
                          todayTasks: [task("t2", "Einkaufen", due: "2026-10-13")],
                          eventsToday: [event("e2", "Standup", start: "2026-10-13T09:30")],
                          remindersToday: [ReminderWithTitle(reminder: Reminder(id: "r2", source: .task, sourceRef: "t2",
                                                                                dueAt: "2026-10-13T11:00"), title: "Einkaufen")])
      let text = BriefingBuilder.facts(busy)
      try expectEqual(text, "Überfällig: Steuer (fällig 10.10.)\nTermine heute: 09:30 Standup\nAufgaben heute: Einkaufen")
      try expect(!text.contains("t1") && !text.contains("e2"), "keine IDs")
      try expectEqual(BriefingBuilder.facts(.empty), "Heute steht nichts an.")
    },
    CheckCase("Briefing: eigene Vorgabe ersetzt die eingebaute, leer = eingebaute") {
      try expectEqual(BriefingBuilder.prompt(custom: "  \n"), BriefingBuilder.defaultPrompt)
      try expectEqual(BriefingBuilder.prompt(custom: "Sag es wie ein Pirat."), "Sag es wie ein Pirat.")
      try expect(BriefingBuilder.defaultPrompt.contains("Muster") && BriefingBuilder.defaultPrompt.contains("keine Emojis"))
    },
    CheckCase("Briefing: Fallback bei leerer Modellantwort") {
      let b = try await BriefingBuilder.build(.empty, llm: FakeLlm { ChatMessage(role: .assistant, content: nil) })
      try expect(!b.generatedByModel)
    },
    CheckCase("Briefing: Fallback-Text nie leer") {
      let b = try await BriefingBuilder.build(.empty, formulate: nil)
      try expect(!b.text.isEmpty)
      try expectEqual(b.text, "Heute keine Termine.")
    },
    CheckCase("Briefing: verschluckt keinen Programmierfehler") {
      try await expectThrows {
        _ = try await BriefingBuilder.build(.empty, llm: FakeLlm { throw ProgrammingError() })
      }
    },
  ]

  // MARK: planner.test.ts + Szenarien C, D, E, B

  static let planner: [CheckCase] = [
    CheckCase("Ansage-Text: Termin nennt Uhrzeit und Vorlauf, Aufgabe bleibt schlicht") {
      let task = Reminder(id: "x", source: .task, sourceRef: "t", dueAt: "2026-01-10T09:00")
      try expectEqual(ReminderText.notification(for: task, title: "Zahnarzt anrufen", eventStart: nil,
                                                now: at("2026-01-10T09:00")),
                      TabyNotification(title: "Erinnerung", body: "Zahnarzt anrufen", taskId: "t"))
      let ev = Reminder(id: "y", source: .event, sourceRef: "e", dueAt: "2026-01-10T09:50")
      try expectEqual(ReminderText.notification(for: ev, title: "Zahnarzt", eventStart: "2026-01-10T10:00",
                                                now: at("2026-01-10T09:50")),
                      TabyNotification(title: "Termin bald", body: "Zahnarzt um 10:00 – in 10 Minuten"))
      let now = ReminderText.notification(for: ev, title: "Standup", eventStart: "2026-01-10T10:00",
                                          now: at("2026-01-10T10:00"))
      try expect(now.body.contains("jetzt"), now.body)
    },
    CheckCase("Snooze: „In 10 Min“ setzt die Fälligkeit 10 Minuten später, lokal ohne Zone") {
      try expectEqual(ReminderText.snoozeDue(now: at("2026-01-10T09:55")), "2026-01-10T10:05")
      try expectEqual(ReminderText.snoozeDue(now: at("2026-01-10T23:55")), "2026-01-11T00:05")
    },
    CheckCase("C: Aufgaben-Erinnerung genau einmal, nie doppelt") {
      let h = makeHarness(ControllableClock("2026-01-10T08:59"),
                          tasks: [task("t1", "Zahnarzt anrufen", due: "2026-01-10T09:00")])
      await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      h.clock.set(at("2026-01-10T09:00"))
      let r = await h.planner.tick()
      try expectEqual(h.notifier.sent, [TabyNotification(title: "Erinnerung", body: "Zahnarzt anrufen", taskId: "t1")])
      try expectEqual(r.fired.map(\.id), ["task:t1"])
      for _ in 0..<5 {
        h.clock.advance(seconds: 30)
        await h.planner.tick()
      }
      try expectEqual(h.notifier.sent.count, 1)
      try expectEqual(try h.reminders.listAll().first?.firedAt, "2026-01-10T09:00")
    },
    CheckCase("C: Termin-Erinnerung mit Vorlauf aus den Einstellungen") {
      let lead = Box(15)
      let h = makeHarness(ControllableClock("2026-01-10T09:00"),
                          events: [event("e1", "Meeting", start: "2026-01-10T10:00")], leadMinutes: lead)
      await h.planner.tick()
      try expectEqual(try h.reminders.listAll().first?.dueAt, "2026-01-10T09:45")
      h.clock.set(at("2026-01-10T09:45"))
      await h.planner.tick()
      try expectEqual(h.notifier.sent, [TabyNotification(title: "Termin bald", body: "Meeting um 10:00 – in 15 Minuten")])
    },
    CheckCase("C: geänderte Vorlaufzeit greift nach invalidateReminders") {
      let lead = Box(10)
      let h = makeHarness(ControllableClock("2026-01-10T09:00"),
                          events: [event("e1", "Meeting", start: "2026-01-10T10:00")], leadMinutes: lead)
      await h.planner.tick()
      lead.value = 30
      await h.planner.invalidateReminders()
      await h.planner.tick()
      try expectEqual(try h.reminders.listAll().first?.dueAt, "2026-01-10T09:30")
    },
    CheckCase("E: nach 8 h Ruhezustand genau einmal 'Verpasst', keine Flut") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"),
                          tasks: [task("t1", "Medikament nehmen", due: "2026-01-10T09:00")])
      await h.planner.tick()
      let v2 = await h.planner.missed.count
      try expectEqual(v2, 0)
      h.clock.advance(seconds: 8 * 3600)
      await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      let v3 = await h.planner.missed.map(\.sourceRef)
      try expectEqual(v3, ["t1"])
      await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      let v4 = await h.planner.missed.count
      try expectEqual(v4, 1)
      let titled = await h.planner.missedWithTitles()
      try expectEqual(titled.map(\.title), ["Medikament nehmen"])
    },
    CheckCase("E: Bestätigen entfernt Verpasstes dauerhaft") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"),
                          tasks: [task("t1", "Verpasst", due: "2026-01-10T08:30")])
      await h.planner.tick()
      h.clock.advance(seconds: 8 * 3600)
      await h.planner.tick()
      let v5 = await h.planner.missed.count
      try expectEqual(v5, 1)
      try await h.planner.acknowledgeMissed()
      let v6 = await h.planner.missed.count
      try expectEqual(v6, 0)
      h.clock.advance(seconds: 6 * 60)
      await h.planner.tick()  // auch nach erneutem Abgleich
      let v7 = await h.planner.missed.count
      try expectEqual(v7, 0)
      try expectEqual(h.notifier.sent.count, 0)
    },
    CheckCase("E: Bestätigen nur ausgewählter IDs") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"),
                          tasks: [task("a", "A", due: "2026-01-10T08:10"), task("b", "B", due: "2026-01-10T08:20")])
      await h.planner.tick()
      h.clock.advance(seconds: 3600)
      await h.planner.tick()
      try await h.planner.acknowledgeMissed(["task:a"])
      await h.planner.tick()
      let v8 = await h.planner.missed.map(\.id)
      try expectEqual(v8, ["task:b"])
    },
    CheckCase("D: Auftrag < 24 h überfällig wird genau einmal nachgeholt") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"),
                          jobs: [dailyJob("09:00", createdAt: "2026-01-10T07:00")])
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 0)
      h.clock.advance(seconds: 6 * 3600)
      let r = await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 1)
      try expectEqual(r.jobRuns.map(\.status), [.ok])
      try expectEqual(try h.jobRuns.listByJob("j1").map(\.scheduledFor), ["2026-01-10T09:00"])
      try expect(h.notifier.sent.contains(TabyNotification(title: "Tagesreport", body: "erledigt: Tagesreport")))
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 1)
      try expectEqual(try h.jobRuns.listByJob("j1").count, 1)
    },
    CheckCase("D: Auftrag läuft zu seiner Zeit (Montag 08:00, wöchentlich)") {
      let job = Job(id: "j1", name: "Montag", prompt: "erinnere mich", rule: .weekly(days: [1], time: "08:00"),
                    mode: .readOnly, createdAt: "2026-01-11T20:00")  // per Chat am Sonntag angelegt
      let h = makeHarness(ControllableClock("2026-01-12T07:59"), jobs: [job])  // Montag
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 0)
      h.clock.set(at("2026-01-12T08:00"))
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 1)
      try expectEqual(try h.jobRuns.listByJob("j1").first?.scheduledFor, "2026-01-12T08:00")
    },
    CheckCase("D/E: > 24 h überfällig → skipped-stale, nicht ausgeführt") {
      let job = Job(id: "j1", name: "Wochenreport", prompt: "x", rule: .weekly(days: [1], time: "09:00"),
                    mode: .readOnly, createdAt: "2026-01-01T00:00")
      let h = makeHarness(ControllableClock("2026-01-05T09:00"), jobs: [job])
      h.clock.advance(seconds: 2 * 86400)
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 0)
      try expectEqual(try h.jobRuns.listByJob("j1").map(\.status), [.skippedStale])
      await h.planner.tick()
      try expectEqual(try h.jobRuns.listByJob("j1").count, 1)
      try expectEqual(h.notifier.sent.count, 0)
    },
    CheckCase("D: vor Anlage fällig gewesen → nicht nachholen") {
      let h = makeHarness(ControllableClock("2026-01-10T10:00"),
                          jobs: [dailyJob("09:00", createdAt: "2026-01-10T09:30")])
      await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 0)
      try expectEqual(try h.jobRuns.listByJob("j1").count, 0)
    },
    CheckCase("D: einmaliger Auftrag läuft genau einmal") {
      let job = Job(id: "j1", name: "Einmal", prompt: "x", rule: .once(at: "2026-01-10T12:00"),
                    createdAt: "2026-01-10T08:00")
      let h = makeHarness(ControllableClock("2026-01-10T11:59"), jobs: [job])
      await h.planner.tick()
      h.clock.set(at("2026-01-10T12:00")); await h.planner.tick()
      h.clock.set(at("2026-01-11T12:00")); await h.planner.tick()
      try expectEqual(h.runnerCalls.value.count, 1)
    },
    CheckCase("D: Fehler im Auftrag → status error + Benachrichtigung, kein Absturz") {
      struct Boom: Error {}
      let h = makeHarness(ControllableClock("2026-01-10T09:00"),
                          jobs: [dailyJob("09:00", createdAt: "2026-01-01T00:00")], runner: { _ in throw Boom() })
      await h.planner.tick()
      try expectEqual(try h.jobRuns.listByJob("j1").map(\.status), [.error])
      try expectEqual(h.notifier.sent, [TabyNotification(title: "Tagesreport", body: "Auftrag fehlgeschlagen.")])
    },
    CheckCase("Takt: Erinnerungs-Abgleich nur alle 5 Minuten") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"))
      await h.planner.tick()
      try expectEqual(h.taskCalls.value, 1)
      h.clock.advance(seconds: 60)
      await h.planner.tick()
      try expectEqual(h.taskCalls.value, 1)
      h.clock.advance(seconds: 5 * 60)
      await h.planner.tick()
      try expectEqual(h.taskCalls.value, 2)
    },
    CheckCase("Takt: überlappender Tick wird übersprungen (nie doppelt)") {
      let gate = Box(false)
      let h = makeHarness(ControllableClock("2026-01-10T09:00"),
                          jobs: [dailyJob("09:00", createdAt: "2026-01-01T00:00")],
                          runner: { _ in
                            while !gate.value { try await Task.sleep(nanoseconds: 1_000_000) }
                            return JobRunResult(ok: true)
                          })
      async let first = h.planner.tick()
      try await Task.sleep(nanoseconds: 20_000_000)
      let second = await h.planner.tick()
      gate.value = true
      _ = await first
      try expect(second.skipped, "zweiter Tick hätte übersprungen werden sollen")
      try expectEqual(h.runnerCalls.value.count, 1)
      try expectEqual(try h.jobRuns.listByJob("j1").count, 1)
    },
    CheckCase("Runner: Aufwachen (tickNow) zeigt Verpasstes sofort") {
      let clock = ControllableClock("2026-01-10T08:00")
      let h = makeHarness(clock, tasks: [task("t1", "X", due: "2026-01-10T08:30")])
      await h.planner.tick()
      clock.advance(seconds: 8 * 3600)
      let runner = PlannerRunner(planner: h.planner, interval: 3600, observeSystemWake: false)
      runner.tickNow()
      for _ in 0..<100 where await h.planner.missed.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
      let v9 = await h.planner.missed.count
      try expectEqual(v9, 1)
    },
    CheckCase("Runner: start tickt wiederholt, stop beendet") {
      let ticks = Box(0)
      let h = makeHarness(ControllableClock("2026-01-10T08:00"))
      let runner = PlannerRunner(planner: h.planner, interval: 0.02, observeSystemWake: true) { _ in
        ticks.value += 1
      }
      runner.start()
      try expect(runner.isRunning)
      for _ in 0..<200 where ticks.value < 3 { try await Task.sleep(nanoseconds: 5_000_000) }
      runner.stop()
      try expect(ticks.value >= 3, "nur \(ticks.value) Ticks")
      try await Task.sleep(nanoseconds: 60_000_000)
      let after = ticks.value
      try await Task.sleep(nanoseconds: 80_000_000)
      try expectEqual(ticks.value, after, "nach stop() darf nicht mehr getickt werden")
      try expect(!runner.isRunning)
    },
    CheckCase("B: App-Start fragt, Später → nach 30 min erneut, Ja → heute nie wieder") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"))
      let first = await h.planner.onAppStart()
      try expect(first.showQuestion)
      try expectEqual(first.state.state, .asked)
      let v10 = await h.planner.answerDayStart(.later).snoozeUntil
      try expectEqual(v10, "2026-01-10T08:30")
      h.clock.advance(seconds: 29 * 60)
      let v11 = await h.planner.tick()
      try expect(!v11.showDayStart, "vor Ablauf nicht fragen")
      h.clock.advance(seconds: 60)
      let v12 = await h.planner.tick()
      try expect(v12.showDayStart, "nach 30 min erneut fragen")
      let v13 = await h.planner.dailyState.state
      try expectEqual(v13, .asked)
      let v14 = await h.planner.answerDayStart(.yes).state
      try expectEqual(v14, .done)
      h.clock.advance(seconds: 3600)
      let v15 = await h.planner.tick()
      try expect(!v15.showDayStart)
      let v16 = await h.planner.onAppStart()
      try expect(!v16.showQuestion)
      try expectEqual(h.savedStates.value.map(\.state), [.asked, .snoozed, .asked, .done])
    },
    CheckCase("B: einmal pro Tag — Heute nicht, am nächsten Tag wieder") {
      let h = makeHarness(ControllableClock("2026-01-10T08:00"),
                          dailyState: DailyState(date: "2026-01-10", state: .skipped))
      let v17 = await h.planner.onAppStart()
      try expect(!v17.showQuestion)
      let v18 = await h.planner.tick()
      try expect(!v18.showDayStart)
      h.clock.set(at("2026-01-11T07:30"))
      let v19 = await h.planner.tick()
      try expect(v19.showDayStart)
      let v20 = await h.planner.dailyState
      try expectEqual(v20, DailyState(date: "2026-01-11", state: .asked))
      let v21 = await h.planner.tick()
      try expect(!v21.showDayStart, "Tick fragt nicht doppelt")
      let v22 = await h.planner.onAppStart()
      try expect(v22.showQuestion, "unbeantwortet → beim nächsten Start erneut")
    },
  ]

  // MARK: Zurückziehen veralteter Erinnerungen und Actor-Reentranz

  /// Planer mit veränderlichen Quellen: Der Test ändert Aufgaben/Termine zwischen den Ticks.
  private struct LiveHarness {
    let planner: Planner
    let notifier: SinkNotifier
    let reminders: InMemoryPlannerReminderStore
  }

  private static func liveHarness(
    _ clock: ControllableClock, tasks: Box<[TabyTask]>, events: Box<[CalendarEvent]>, lead: Int = 10
  ) -> LiveHarness {
    let notifier = SinkNotifier()
    let reminders = InMemoryPlannerReminderStore()
    let planner = Planner(
      clock: clock, notifier: notifier, reminders: reminders, jobRuns: InMemoryPlannerJobRunStore(),
      tasksSource: { tasks.value },
      eventsSource: { from, to in
        PlannerEventRead(events: events.value.filter { LocalTime.datePart($0.start) >= from && LocalTime.datePart($0.start) <= to })
      },
      jobsSource: { [] },
      jobRunner: { _ in JobRunResult(ok: true) },
      eventLeadMinutes: { lead }
    )
    return LiveHarness(planner: planner, notifier: notifier, reminders: reminders)
  }

  static let retirement: [CheckCase] = [
    CheckCase("R: erledigte Aufgabe löst zur Fälligkeit nicht aus") {
      let clock = ControllableClock("2026-01-10T08:00")
      let tasks = Box([task("t1", "Zahnarzt", due: "2026-01-10T09:00")])
      let h = liveHarness(clock, tasks: tasks, events: Box([]))
      await h.planner.tick()
      tasks.value = [task("t1", "Zahnarzt", due: "2026-01-10T09:00", done: true)]
      clock.set(at("2026-01-10T09:00"))
      await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      try expectEqual(try h.reminders.listAll().first?.acknowledgedAt, "2026-01-10T09:00")
    },
    CheckCase("R: gelöschte Aufgabe löst nicht aus und erscheint nicht als verpasst") {
      let clock = ControllableClock("2026-01-10T08:00")
      let tasks = Box([task("t1", "Alt", due: "2026-01-10T08:30")])
      let h = liveHarness(clock, tasks: tasks, events: Box([]))
      await h.planner.tick()
      tasks.value = []
      clock.advance(seconds: 8 * 3600)
      let r = await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      try expectEqual(r.fired.count, 0)
      let missed = await h.planner.missed
      try expect(missed.isEmpty, "gelöschte Aufgabe darf nicht verpasst sein")
      let titled = await h.planner.missedWithTitles()
      try expect(titled.isEmpty)
    },
    CheckCase("R: gelöschte Aufgabe wird auch bei kurzem Abstand nicht verpasst") {
      let clock = ControllableClock("2026-01-10T08:00")
      let tasks = Box([task("t1", "Alt", due: "2026-01-10T08:30")])
      let h = liveHarness(clock, tasks: tasks, events: Box([]))
      await h.planner.tick()
      tasks.value = []
      clock.advance(seconds: 60)
      await h.planner.tick()
      clock.advance(seconds: 8 * 3600)
      await h.planner.tick()
      let missed = await h.planner.missed
      try expect(missed.isEmpty, "Verpasst darf nach Löschen nicht auftauchen")
      try expectEqual(h.notifier.sent.count, 0)
    },
    CheckCase("R: Termin aus der Quelle entfernt löst nicht aus") {
      let clock = ControllableClock("2026-01-10T09:00")
      let events = Box([event("e1", "Meeting", start: "2026-01-10T10:00")])
      let h = liveHarness(clock, tasks: Box([]), events: events)
      await h.planner.tick()
      try expectEqual(try h.reminders.listAll().first?.dueAt, "2026-01-10T09:50")
      events.value = []
      clock.set(at("2026-01-10T09:50"))
      await h.planner.tick()
      try expectEqual(h.notifier.sent.count, 0)
      let missed = await h.planner.missed
      try expect(missed.isEmpty)
    },
    CheckCase("R: nicht erreichbare Kalenderquelle lässt Termin-Erinnerung offen") {
      let clock = ControllableClock("2026-01-10T09:00")
      let events = Box([event("e1", "Meeting", start: "2026-01-10T10:00")])
      let unreachable = Box<[String]>([])
      let reminders = InMemoryPlannerReminderStore()
      let planner = Planner(
        clock: clock, notifier: SinkNotifier(), reminders: reminders, jobRuns: InMemoryPlannerJobRunStore(),
        tasksSource: { [] },
        eventsSource: { from, to in
          PlannerEventRead(events: events.value.filter { LocalTime.datePart($0.start) >= from && LocalTime.datePart($0.start) <= to },
                           unreachableSources: unreachable.value)
        },
        jobsSource: { [] }, jobRunner: { _ in JobRunResult(ok: true) }, eventLeadMinutes: { 10 })
      await planner.invalidateReminders()
      await planner.tick()
      try expectEqual(try reminders.listAll().first?.dueAt, "2026-01-10T09:50")
      // Quelle antwortet nicht: der fehlende Termin darf seine Erinnerung nicht zurückziehen.
      events.value = []
      unreachable.value = ["google"]
      await planner.invalidateReminders()
      await planner.tick()
      try expect(try reminders.listAll().first?.acknowledgedAt == nil, "Quelle nicht erreichbar: Erinnerung bleibt offen")
      // Alle Quellen antworten und der Termin ist weg: jetzt gilt die Erinnerung als bestätigt.
      unreachable.value = []
      await planner.invalidateReminders()
      await planner.tick()
      try expect(try reminders.listAll().first?.acknowledgedAt != nil, "Termin weg, Quelle da: bestätigt")
    },
    CheckCase("R: wieder geöffnete Aufgabe: Erinnerungen in der Zukunft werden wieder offen") {
      let store = try Store.inMemory(clock: ControllableClock("2026-01-10T08:00"))
      let t = try store.tasks.add(title: "Zahnarzt", due: "2026-01-10T09:00")
      let other = try store.tasks.add(title: "Anderes", due: "2026-01-10T09:00")
      _ = try store.tasks.complete(t.id)
      try store.reminders.upsert(Reminder(id: "r-future", source: .task, sourceRef: t.id,
                                          dueAt: "2026-01-10T09:00", acknowledgedAt: "2026-01-10T07:55"))
      try store.reminders.upsert(Reminder(id: "r-past", source: .task, sourceRef: t.id,
                                          dueAt: "2026-01-10T07:00", acknowledgedAt: "2026-01-10T07:05"))
      try store.reminders.upsert(Reminder(id: "r-other", source: .task, sourceRef: other.id,
                                          dueAt: "2026-01-10T09:00", acknowledgedAt: "2026-01-10T07:55"))
      _ = try store.tasks.reopen(t.id)
      let rows = try store.reminders.listAll()
      func ack(_ id: String) -> String? { rows.first { $0.id == id }?.acknowledgedAt }
      try expectEqual(ack("r-future"), nil, "Zukunft: wieder offen")
      try expectEqual(ack("r-past"), "2026-01-10T07:05", "Vergangenheit bleibt bestätigt")
      try expectEqual(ack("r-other"), "2026-01-10T07:55", "andere Aufgabe unberührt")
    },
    CheckCase("R: Termin außerhalb des Abgleichsfensters wird nicht zurückgezogen") {
      let clock = ControllableClock("2026-01-10T09:00")
      let h = liveHarness(clock, tasks: Box([]), events: Box([]))
      // Termin am 13.01. liegt außerhalb des Abrufs 10.01.–12.01.
      try h.reminders.upsert(Reminder(id: "event:e9", source: .event, sourceRef: "e9", dueAt: "2026-01-13T09:50"))
      await h.planner.tick()
      let kept = try h.reminders.findBySource(.event, "e9")
      try expect(kept?.acknowledgedAt == nil, "Termin außerhalb des Fensters darf nicht zurückgezogen werden")
      try expectEqual(kept?.firedAt, nil)
    },
    CheckCase("R: Abgleich über die Race-Grenze: invalidate während des Lesens erzwingt Neuabgleich") {
      let clock = ControllableClock("2026-01-10T08:00")
      let holder = Box<Planner?>(nil)
      let tasks = Box<[TabyTask]>([])
      let calls = Box(0)
      let reminders = InMemoryPlannerReminderStore()
      let planner = Planner(
        clock: clock, notifier: SinkNotifier(), reminders: reminders, jobRuns: InMemoryPlannerJobRunStore(),
        tasksSource: {
          calls.value += 1
          let snapshot = tasks.value
          if calls.value == 1, let p = holder.value {
            // Während der Abgleich die Aufgaben liest: Aufgabe kommt hinzu und die Erinnerung wird ungültig.
            tasks.value = [task("t1", "Neu", due: "2026-01-10T09:00")]
            await p.invalidateReminders()
          }
          return snapshot
        },
        eventsSource: { _, _ in PlannerEventRead(events: []) },
        jobsSource: { [] },
        jobRunner: { _ in JobRunResult(ok: true) }
      )
      holder.value = planner
      let first = await planner.tick()
      try expect(first.resynced, "erster Tick muss abgleichen")
      let second = await planner.tick()
      try expect(second.resynced, "zweiter Tick muss nach invalidate erneut abgleichen")
      try expectEqual(calls.value, 2)
      try expectEqual(try reminders.findBySource(.task, "t1")?.dueAt, "2026-01-10T09:00")
    },
  ]

  // MARK: Notifier

  static let notifiers: [CheckCase] = [
    CheckCase("FileSinkNotifier schreibt JSON-Zeilen") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-planner-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("sub/notify.jsonl")
      let n = FileSinkNotifier(url: url)
      n.send(TabyNotification(title: "Erinnerung", body: "Zahnarzt / 9 Uhr"))
      n.send(TabyNotification(title: "B", body: "Ä\"ö"))
      try expectEqual(FileSinkNotifier.read(url), [TabyNotification(title: "Erinnerung", body: "Zahnarzt / 9 Uhr"),
                                                   TabyNotification(title: "B", body: "Ä\"ö")])
      let text = try String(contentsOf: url, encoding: .utf8)
      try expectEqual(text.split(separator: "\n").count, 2)
    },
    CheckCase("UserNotificationsNotifier ohne App-Bundle: protokolliert, kein Absturz") {
      let logged = Box<[String]>([])
      let n = UserNotificationsNotifier(log: { logged.value.append($0) })
      if UserNotificationsNotifier.systemAvailable { return }  // nur im App-Bundle relevant
      try expect(!n.usesSystem)
      n.send(TabyNotification(title: "T", body: "B"))
      try expectEqual(logged.value, ["[notify] T: B"])
    },
    CheckCase("FanOutNotifier verteilt an alle") {
      let a = SinkNotifier(), b = SinkNotifier()
      FanOutNotifier([a, b]).send(TabyNotification(title: "x", body: "y"))
      try expectEqual(a.sent.count + b.sent.count, 2)
    },
  ]
}
