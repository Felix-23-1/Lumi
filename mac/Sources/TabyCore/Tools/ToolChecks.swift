// Prüfungen für Sources/TabyCore/Tools (Port von test/unit/tools/*.test.ts).
// Echte Datenbank und echter Dispatcher; nur an der Grenze (fremde
// Kalendermodule) wird mit `BoundaryCalendarProvider` gearbeitet.
import Foundation

/// Fremdes Kalendermodul an der Grenze (Notion/ICS/Apple-Ersatz).
private final class BoundaryCalendarProvider: CalendarProvider {
  let id: String
  let kind: CalendarSourceKind
  let canWrite: Bool
  var events: [CalendarEvent]
  var failure: Error?
  var created: [NewEvent] = []
  var deleted: [String] = []
  var failCreate = false

  init(id: String, kind: CalendarSourceKind = .notion, canWrite: Bool = false, events: [CalendarEvent] = [],
       failure: Error? = nil) {
    self.id = id; self.kind = kind; self.canWrite = canWrite; self.events = events; self.failure = failure
  }

  func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    if let failure { throw failure }
    return events.filter { LocalTime.datePart($0.start) >= from && LocalTime.datePart($0.start) < to }
  }

  func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    guard canWrite else { throw CalendarError.notWritable(id) }
    if let failure { throw failure }
    if failCreate { throw CalendarError.unreachable("\(id) antwortet nicht.") }
    created.append(e)
    return CalendarEvent(id: "ext-\(created.count)", sourceId: id, title: e.title, start: e.start, end: e.end,
                         allDay: LocalTime.isDateOnly(e.start), notes: e.notes)
  }

  func deleteEvent(id: String) async throws {
    guard canWrite else { throw CalendarError.notWritable(self.id) }
    deleted.append(id)
  }

  func healthCheck() async -> HealthResult { HealthResult(ok: failure == nil) }
}

// Wie expect/expectEqual, aber ohne Autoclosure, damit `await` im Argument geht.
private func check(_ condition: Bool, _ message: String = "Bedingung nicht erfüllt", file: StaticString = #fileID,
                   line: UInt = #line) throws {
  if !condition { throw CheckFailure(message: message, location: "\(file):\(line)") }
}

private func same<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #fileID,
                                line: UInt = #line) throws {
  if actual != expected {
    let extra = message.isEmpty ? "" : " — \(message)"
    throw CheckFailure(message: "erwartet \(expected), war \(actual)\(extra)", location: "\(file):\(line)")
  }
}

private func makeCtx(now: String = "2024-03-04T08:00", mode: JobMode = .standard, actor: ActionActor = .assistant,
                     extra: [CalendarProvider] = [], defaultWriteId: String? = nil) throws -> ToolContext {
  let store = try Store.inMemory(clock: ControllableClock(now))
  let calendar = ProviderCalendarAccess(
    providers: [StoreLocalCalendarProvider(events: store.events)] + extra, defaultWriteId: defaultWriteId)
  return ToolContext(store: store, calendar: calendar, mode: mode, actor: actor)
}

private func run(_ name: String, _ args: JSONValue = [:], _ ctx: ToolContext) async -> JSONValue {
  await executeTool(name: name, args: args, ctx: ctx)
}

private func expectOk(_ r: JSONValue, file: StaticString = #fileID, line: UInt = #line) throws {
  try check(r["ok"] == true, "erwartet ok:true, war \(r.jsonString())", file: file, line: line)
}

private func expectCode(_ r: JSONValue, _ code: String, file: StaticString = #fileID, line: UInt = #line) throws {
  try check(r["ok"] == false, "erwartet ok:false, war \(r.jsonString())", file: file, line: line)
  try same(r["code"]?.stringValue, code, r.jsonString(), file: file, line: line)
}

private func idOf(_ r: JSONValue, _ key: String) throws -> String {
  try expectNotNil(r[key]?["id"]?.stringValue, "keine ID unter \(key): \(r.jsonString())")
}

private func titles(_ v: JSONValue?, _ field: String = "title") -> [String] {
  v?.arrayValue?.compactMap { $0[field]?.stringValue } ?? []
}

private func tev(_ id: String, _ start: String, _ end: String? = nil, allDay: Bool = false) -> CalendarEvent {
  CalendarEvent(id: id, sourceId: "local", title: "Termin", start: start, end: end, allDay: allDay)
}

private func fs(_ start: String, _ end: String) -> FreeSlot {
  FreeSlot(start: start, end: end)
}

enum ToolChecks {
  static let suite = CheckSuite(
    "Tools",
    dispatcherChecks + entityChecks + eventChecks + modeAndLogChecks + validationChecks + overviewChecks
      + bufferAndFreeTimeChecks + package2Checks + calendarToolChecks + assistantToolChecks)

  // MARK: Kalenderquellen: Standard, calendar-Argument, list/delete/move_event

  static let calendarToolChecks: [CheckCase] = [
    CheckCase("Standard: ohne Markierung gewinnt der Apple-Kalender vor dem lokalen") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ctx = try makeCtx(extra: [apple])
      let r = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T09:00"], ctx)
      try same(r["event"]?["sourceId"], "apple")
      try same(apple.created.map(\.title), ["Zahnarzt"])
      try same(try ctx.store.events.listAll().count, 0)
    },
    CheckCase("Standard: eine ausdrücklich markierte Quelle gewinnt vor Apple") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let notion = BoundaryCalendarProvider(id: "notion:w", canWrite: true)
      let ctx = try makeCtx(extra: [apple, notion], defaultWriteId: "notion:w")
      try same(await run("add_event", ["title": "X", "start": "2024-03-05T09:00"], ctx)["event"]?["sourceId"], "notion:w")
      try same(apple.created.count, 0)
    },
    CheckCase("add_event: calendar \"apple\" legt im Apple-Modul an, \"local\" lokal") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ctx = try makeCtx(extra: [apple])
      try same(await run("add_event", ["title": "A", "start": "2024-03-05T09:00", "calendar": "apple"], ctx)["event"]?["sourceId"],
               "apple")
      try same(apple.created.map(\.title), ["A"])
      try same(await run("add_event", ["title": "B", "start": "2024-03-05T11:00", "calendar": "local"], ctx)["event"]?["sourceId"],
               "local")
      try same(try ctx.store.events.listAll().count, 1)
    },
    CheckCase("add_event: unbekannter oder nicht beschreibbarer calendar → INVALID_ARGS mit Liste, nichts gespeichert") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ics = BoundaryCalendarProvider(id: "ics:x", kind: .ics, canWrite: false)
      let ctx = try makeCtx(extra: [apple, ics])
      let unknown = await run("add_event", ["title": "X", "start": "2024-03-05T09:00", "calendar": "outlook"], ctx)
      try expectCode(unknown, "INVALID_ARGS")
      try check((unknown["error"]?.stringValue ?? "").contains("apple"), unknown.jsonString())
      try expectCode(await run("add_event", ["title": "X", "start": "2024-03-05T09:00", "calendar": "ics:x"], ctx),
                     "INVALID_ARGS")
      try same(apple.created.count, 0)
      try same(try ctx.store.events.listAll().count, 0)
    },
    CheckCase("list_calendars: Quellen mit id, kind, Name, beschreibbar und Standard") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ics = BoundaryCalendarProvider(id: "ics:x", kind: .ics, canWrite: false)
      let ctx = try makeCtx(extra: [apple, ics])
      let r = await run("list_calendars", [:], ctx)
      try expectOk(r)
      let items = r["calendars"]?.arrayValue ?? []
      try same(items.compactMap { $0["id"]?.stringValue }, ["local", "apple", "ics:x"])
      try same(items.first { $0["id"]?.stringValue == "apple" }?["name"], "Apple Kalender")
      try same(items.first { $0["id"]?.stringValue == "ics:x" }?["writable"], false)
      try same(items.filter { $0["isDefault"] == true }.compactMap { $0["id"]?.stringValue }, ["apple"])
      try check(ToolRegistry.readOnlyAllowed.contains("list_calendars"))
    },
    CheckCase("list_events: jeder Termin trägt id und source_id") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true,
                                           events: [CalendarEvent(id: "e9", sourceId: "apple", title: "T", start: "2024-03-05T10:00")])
      let ctx = try makeCtx(extra: [apple])
      let ev = await run("list_events", ["from": "2024-03-05", "to": "2024-03-06"], ctx)["events"]?.arrayValue?.first
      try same(ev?["id"], "e9")
      try same(ev?["sourceId"], "apple")
    },
    CheckCase("delete_event: Bestätigung nötig; nach Bestätigung löscht es im Quellmodul") {
      try check(ToolRegistry.confirmationRequired.contains("delete_event"))
      try check(ToolRegistry.confirmationRequired.contains("move_event"))
      try check(ToolRegistry.confirmationRequired.contains("remember_fact"))
      try check(ToolRegistry.mutatingTools.contains("delete_event") && ToolRegistry.mutatingTools.contains("move_event"))
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ctx = try makeCtx(extra: [apple])
      try expectOk(await run("delete_event", ["id": "e1", "source_id": "apple"], ctx))
      try same(apple.deleted, ["e1"])
      try expectCode(await run("delete_event", ["id": "e1", "source_id": "gibt-es-nicht"], ctx), "INVALID_ARGS")
      let ics = BoundaryCalendarProvider(id: "ics:x", kind: .ics, canWrite: false)
      let ctx2 = try makeCtx(extra: [ics])
      try expectCode(await run("delete_event", ["id": "e1", "source_id": "ics:x"], ctx2), "CALENDAR_ERROR")
    },
    CheckCase("move_event: legt neu an (Titel/Notiz bleiben), löscht danach das Original") {
      let old = CalendarEvent(id: "old-1", sourceId: "apple", title: "Zahnarzt", start: "2024-03-05T10:00",
                              end: "2024-03-05T11:00", notes: "Nüchtern")
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true, events: [old])
      let ctx = try makeCtx(extra: [apple])
      // Verschieben um 30 Minuten: der alte Termin selbst ist kein Konflikt.
      let r = await run("move_event", ["id": "old-1", "source_id": "apple", "start": "2024-03-05T10:30",
                                       "end": "2024-03-05T11:30"], ctx)
      try expectOk(r)
      try same(apple.created.map(\.title), ["Zahnarzt"])
      try same(apple.created.first?.notes, "Nüchtern")
      try same(apple.created.first?.start, "2024-03-05T10:30")
      try same(apple.deleted, ["old-1"])
      try same(r["event"]?["sourceId"], "apple")
    },
    CheckCase("move_event: ohne end bleibt die Dauer (auch über Mitternacht und ganztägig)") {
      let timed = CalendarEvent(id: "t", sourceId: "apple", title: "Lang", start: "2024-03-05T10:00", end: "2024-03-05T11:30")
      let day = CalendarEvent(id: "d", sourceId: "apple", title: "Urlaub", start: "2024-03-05", end: "2024-03-08", allDay: true)
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true, events: [timed, day])
      let ctx = try makeCtx(extra: [apple])
      try expectOk(await run("move_event", ["id": "t", "source_id": "apple", "start": "2024-03-09T23:00"], ctx))
      try same(apple.created.last?.end, "2024-03-10T00:30")
      try expectOk(await run("move_event", ["id": "d", "source_id": "apple", "start": "2024-04-01"], ctx))
      try same(apple.created.last?.start, "2024-04-01")
      try same(apple.created.last?.end, "2024-04-04")
    },
    CheckCase("move_event: schlägt das Anlegen fehl, bleibt das Original unangetastet") {
      let old = CalendarEvent(id: "old-1", sourceId: "apple", title: "Zahnarzt", start: "2024-03-05T10:00")
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true, events: [old])
      apple.failCreate = true
      let ctx = try makeCtx(extra: [apple])
      try expectCode(await run("move_event", ["id": "old-1", "source_id": "apple", "start": "2024-03-06T10:00"], ctx),
                     "CALENDAR_ERROR")
      try same(apple.deleted, [])
      try same(apple.events.map(\.id), ["old-1"])
    },
    CheckCase("move_event: calendar verschiebt in eine andere Quelle; Konflikt blockiert, nichts gelöscht") {
      let old = CalendarEvent(id: "old-1", sourceId: "apple", title: "Zahnarzt", start: "2024-03-05T10:00",
                              end: "2024-03-05T11:00")
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true, events: [old])
      let notion = BoundaryCalendarProvider(id: "notion:w", canWrite: true,
                                            events: [CalendarEvent(id: "n1", sourceId: "notion:w", title: "Team",
                                                                   start: "2024-03-06T10:00", end: "2024-03-06T11:00")])
      let ctx = try makeCtx(extra: [apple, notion])
      let moved = await run("move_event", ["id": "old-1", "source_id": "apple", "start": "2024-03-06T10:30",
                                          "end": "2024-03-06T11:30", "calendar": "notion:w"], ctx)
      try expectCode(moved, "CONFLICT")
      try same(apple.deleted, [])
      try expectOk(await run("move_event", ["id": "old-1", "source_id": "apple", "start": "2024-03-07T10:00",
                                           "end": "2024-03-07T11:00", "calendar": "notion"], ctx))
      try same(notion.created.map(\.title), ["Zahnarzt"])
      try same(apple.deleted, ["old-1"])
    },
    CheckCase("move_event: unbekannter Termin → NOT_FOUND; unbekannte Quelle → INVALID_ARGS") {
      let apple = BoundaryCalendarProvider(id: "apple", kind: .apple, canWrite: true)
      let ctx = try makeCtx(extra: [apple])
      try expectCode(await run("move_event", ["id": "nope", "source_id": "apple", "start": "2024-03-05T10:00"], ctx),
                     "NOT_FOUND")
      try expectCode(await run("move_event", ["id": "x", "source_id": "gibt-es-nicht", "start": "2024-03-05T10:00"], ctx),
                     "INVALID_ARGS")
      try same(apple.created.count, 0)
    },
  ]

  // MARK: Puffer im add_event und freie Zeiten (Paket 1)

  static let bufferAndFreeTimeChecks: [CheckCase] = [
    CheckCase("add_event: Puffer blockiert zu knappe Termine (too-close), nichts gespeichert") {
      let ctx = try makeCtx()
      _ = try ctx.store.settings.update(SettingsPatch(bufferMinutes: 15))
      _ = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00", "end": "2024-03-05T15:00"], ctx)
      let r = await run("add_event", ["title": "Meeting", "start": "2024-03-05T15:10", "end": "2024-03-05T16:00"], ctx)
      try expectCode(r, "CONFLICT")
      try same(r["conflicts"]?.arrayValue?.first?["kind"], "too-close")
      let error = r["error"]?.stringValue ?? ""
      try check(error.contains("zu knapp") && error.contains("15 Minuten"), error)
      try check(!error.contains("überschneidet"), error)
      try same(try ctx.store.events.listAll().count, 1)
    },
    CheckCase("add_event: Puffer mit allow_conflict speichert trotzdem") {
      let ctx = try makeCtx()
      _ = try ctx.store.settings.update(SettingsPatch(bufferMinutes: 15))
      _ = await run("add_event", ["title": "A", "start": "2024-03-05T14:00", "end": "2024-03-05T15:00"], ctx)
      try expectOk(await run("add_event", ["title": "B", "start": "2024-03-05T15:15", "end": "2024-03-05T16:00"], ctx))
      try expectCode(await run("add_event", ["title": "C", "start": "2024-03-05T16:05", "end": "2024-03-05T16:30"], ctx),
                     "CONFLICT")
      try expectOk(await run("add_event", ["title": "C", "start": "2024-03-05T16:05", "end": "2024-03-05T16:30",
                                           "allow_conflict": true], ctx))
      try same(try ctx.store.events.listAll().count, 3)
    },
    CheckCase("add_event: Puffer 0 lässt knappe Termine zu; Überschneidung nennt \"überschneidet sich\"") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "A", "start": "2024-03-05T14:00", "end": "2024-03-05T15:00"], ctx)
      try expectOk(await run("add_event", ["title": "B", "start": "2024-03-05T15:01", "end": "2024-03-05T16:00"], ctx))
      _ = try ctx.store.settings.update(SettingsPatch(bufferMinutes: 15))
      let r = await run("add_event", ["title": "C", "start": "2024-03-05T14:30", "end": "2024-03-05T15:30"], ctx)
      try expectCode(r, "CONFLICT")
      try check((r["error"]?.stringValue ?? "").contains("überschneidet sich"), r.jsonString())
    },
    CheckCase("Freie Zeit: leerer Tag ergibt das ganze Tagesfenster 08:00–20:00") {
      try same(FreeTime.slots(events: [], from: "2024-03-04", to: "2024-03-05", durationMinutes: 60,
                              now: "2024-03-01T10:00"),
               [fs("2024-03-04T08:00", "2024-03-04T20:00")])
    },
    CheckCase("Freie Zeit: belegter Tag liefert die Lücken dazwischen") {
      let events = [tev("a", "2024-03-04T10:00", "2024-03-04T11:00"), tev("b", "2024-03-04T14:00", "2024-03-04T15:00")]
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-05", durationMinutes: 60,
                              now: "2024-03-01T10:00"),
               [fs("2024-03-04T08:00", "2024-03-04T10:00"), fs("2024-03-04T11:00", "2024-03-04T14:00"),
                fs("2024-03-04T15:00", "2024-03-04T20:00")])
    },
    CheckCase("Freie Zeit: Dauer filtert kurze Lücken aus") {
      let events = [tev("a", "2024-03-04T10:00", "2024-03-04T11:00"), tev("b", "2024-03-04T14:00", "2024-03-04T15:00")]
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-05", durationMinutes: 150,
                              now: "2024-03-01T10:00"),
               [fs("2024-03-04T11:00", "2024-03-04T14:00"), fs("2024-03-04T15:00", "2024-03-04T20:00")])
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-05", durationMinutes: 300,
                              now: "2024-03-01T10:00"),
               [fs("2024-03-04T15:00", "2024-03-04T20:00")])
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-05", durationMinutes: 301,
                              now: "2024-03-01T10:00"), [])
    },
    CheckCase("Freie Zeit: 720 Minuten passen genau in das Standardfenster") {
      try same(FreeTime.slots(events: [], from: "2024-03-04", to: "2024-03-05", durationMinutes: 720,
                              now: "2024-03-01T10:00").count, 1)
    },
    CheckCase("Freie Zeit: Puffer rund um Termine wird abgezogen") {
      let events = [tev("a", "2024-03-04T10:00", "2024-03-04T11:00"), tev("b", "2024-03-04T14:00", "2024-03-04T15:00")]
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-05", durationMinutes: 60,
                              bufferMinutes: 15, now: "2024-03-01T10:00"),
               [fs("2024-03-04T08:00", "2024-03-04T09:45"), fs("2024-03-04T11:15", "2024-03-04T13:45"),
                fs("2024-03-04T15:15", "2024-03-04T20:00")])
    },
    CheckCase("Freie Zeit: vergangene Zeit heute entfällt, andere Tage nicht") {
      let events = [tev("a", "2024-03-04T10:00", "2024-03-04T11:00"), tev("b", "2024-03-04T14:00", "2024-03-04T15:00")]
      try same(FreeTime.slots(events: events, from: "2024-03-04", to: "2024-03-06", durationMinutes: 30,
                              now: "2024-03-04T13:30"),
               [fs("2024-03-04T13:30", "2024-03-04T14:00"), fs("2024-03-04T15:00", "2024-03-04T20:00"),
                fs("2024-03-05T08:00", "2024-03-05T20:00")])
      try same(FreeTime.slots(events: [], from: "2024-03-04", to: "2024-03-05", durationMinutes: 60,
                              now: "2024-03-04T21:00"), [])
    },
    CheckCase("Freie Zeit: ganztägige Termine werden ignoriert") {
      try same(FreeTime.slots(events: [tev("a", "2024-03-04", allDay: true)], from: "2024-03-04",
                              to: "2024-03-05", durationMinutes: 60, now: "2024-03-01T10:00"),
               [fs("2024-03-04T08:00", "2024-03-04T20:00")])
    },
    CheckCase("Freie Zeit: eigenes Tagesfenster, Termin ohne Ende dauert 60 Minuten") {
      try same(FreeTime.slots(events: [tev("a", "2024-03-04T10:00")], from: "2024-03-04", to: "2024-03-05",
                              durationMinutes: 30, dayStart: "09:00", dayEnd: "12:00", now: "2024-03-01T10:00"),
               [fs("2024-03-04T09:00", "2024-03-04T10:00"), fs("2024-03-04T11:00", "2024-03-04T12:00")])
    },
    CheckCase("Freie Zeit: Termin aus dem Vortag über Mitternacht blockiert den Morgen") {
      try same(FreeTime.slots(events: [tev("a", "2024-03-03T23:00", "2024-03-04T09:00")], from: "2024-03-04",
                              to: "2024-03-05", durationMinutes: 60, now: "2024-03-01T10:00"),
               [fs("2024-03-04T09:00", "2024-03-04T20:00")])
    },
    CheckCase("Freie Zeit: mehrere Tage, höchstens 20 Fenster") {
      let days = FreeTime.slots(events: [tev("a", "2024-03-05T10:00", "2024-03-05T11:00")], from: "2024-03-04",
                                to: "2024-03-06", durationMinutes: 60, now: "2024-03-01T10:00")
      try same(days, [fs("2024-03-04T08:00", "2024-03-04T20:00"), fs("2024-03-05T08:00", "2024-03-05T10:00"),
                      fs("2024-03-05T11:00", "2024-03-05T20:00")])
      let many = FreeTime.slots(events: [], from: "2024-03-01", to: "2024-03-31", durationMinutes: 60,
                                now: "2024-02-01T00:00")
      try same(many.count, FreeTime.maxSlots)
      try same(many.first, fs("2024-03-01T08:00", "2024-03-01T20:00"))
    },
    CheckCase("find_free_time: Ergebnis mit slots und unreachable, Puffer aus den Einstellungen") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Arzt", "start": "2024-03-04T10:00", "end": "2024-03-04T11:00"], ctx)
      let r = await run("find_free_time", ["from": "2024-03-04", "to": "2024-03-05", "duration_minutes": 60], ctx)
      try expectOk(r)
      try same(r["slots"]?.arrayValue?.compactMap { $0["end"]?.stringValue },
               ["2024-03-04T10:00", "2024-03-04T20:00"])
      try same(r["unreachable"]?.arrayValue?.count, 0)
      _ = try ctx.store.settings.update(SettingsPatch(bufferMinutes: 60))
      let buffered = await run("find_free_time", ["from": "2024-03-04", "to": "2024-03-05",
                                                  "duration_minutes": 60], ctx)
      try same(buffered["slots"]?.arrayValue?.compactMap { $0["end"]?.stringValue },
               ["2024-03-04T09:00", "2024-03-04T20:00"])
    },
    CheckCase("find_free_time: nicht erreichbares Kalendermodul landet in unreachable, Abfrage bleibt ok") {
      let broken = BoundaryCalendarProvider(id: "ics:x", kind: .ics,
                                            failure: CalendarError.unreachable("Kalender offline"))
      let ctx = try makeCtx(extra: [broken])
      let r = await run("find_free_time", ["from": "2024-03-04", "to": "2024-03-05", "duration_minutes": 60], ctx)
      try expectOk(r)
      try same(r["unreachable"]?.arrayValue?.first?["id"], "ics:x")
      try same(r["slots"]?.arrayValue?.count, 1)
    },
    CheckCase("find_free_time: Argumente werden strikt geprüft") {
      let ctx = try makeCtx()
      let base: JSONValue = ["from": "2024-03-04", "to": "2024-03-05", "duration_minutes": 60]
      func with(_ key: String, _ value: JSONValue) -> JSONValue {
        var o = base.objectValue ?? [:]
        o[key] = value
        return .object(o)
      }
      try expectCode(await run("find_free_time", with("duration_minutes", 4), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("duration_minutes", 721), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("duration_minutes", 60.5), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("duration_minutes", "60"), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("to", "2024-03-04"), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("from", "04.03.2024"), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("day_start", "8:00"), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", with("day_end", "07:00"), ctx), "INVALID_ARGS")
      try expectCode(await run("find_free_time", ["from": "2024-03-04", "to": "2024-03-05"], ctx), "INVALID_ARGS")
      try expectOk(await run("find_free_time", with("day_start", "09:00"), ctx))
    },
    CheckCase("find_free_time: im Lesemodus erlaubt und nichts wird protokolliert") {
      let ctx = try makeCtx(mode: .readOnly, actor: .job)
      try expectOk(await run("find_free_time", ["from": "2024-03-04", "to": "2024-03-05", "duration_minutes": 60], ctx))
      try same(try ctx.store.actionLog.list(limit: 10).count, 0)
    },
  ]

  // MARK: Dispatcher

  static let dispatcherChecks: [CheckCase] = [
    CheckCase("Dispatcher: unbekanntes Werkzeug → UNKNOWN_TOOL, protokolliert") {
      let ctx = try makeCtx()
      try expectCode(await run("does_not_exist", [:], ctx), "UNKNOWN_TOOL")
      try same(try ctx.store.actionLog.list(limit: 10).map(\.tool), ["does_not_exist"])
    },
    CheckCase("Dispatcher: alle Werkzeuge mit Objekt-Schema und Handler") {
      let names = ToolRegistry.definitions.map(\.name)
      try same(names, [
        "get_overview", "add_task", "list_tasks", "update_task", "complete_task", "reopen_task", "delete_task",
        "add_note", "list_notes", "search_notes", "update_note", "delete_note", "add_event", "list_events", "list_calendars", "delete_event", "move_event", "find_free_time", "schedule_job", "list_jobs",
        "cancel_job", "remember_fact", "list_memories", "forget_fact", "postpone_tasks",
        "list_messages", "send_message", "list_habits", "check_habit", "add_habit", "start_focus", "stop_focus",
        "plan_day", "what_now", "show_plan", "list_weekly_goals", "find_contact",
      ])
      for def in ToolRegistry.definitions {
        try same(def.parameters["type"], "object", def.name)
        try check(ToolRegistry.handlers[def.name] != nil, "Handler fehlt: \(def.name)")
        try check(!def.description.isEmpty, def.name)
        let props = def.parameters["properties"]?.objectValue ?? [:]
        for req in def.parameters["required"]?.arrayValue ?? [] {
          try check(props[req.stringValue ?? ""] != nil, "\(def.name): required \(req) nicht in properties")
        }
      }
      try same(ToolRegistry.handlers.count, 37)
    },
    CheckCase("Dispatcher: Lesemodus bietet dem Modell nur erlaubte Werkzeuge an") {
      let ro = Set(ToolRegistry.definitions(for: .readOnly).map(\.name))
      try same(ro, ToolRegistry.readOnlyAllowed)
      try check(ro.contains("find_free_time"), "find_free_time ist im Lesemodus erlaubt")
      try same(ToolRegistry.definitions(for: .standard).count, 37)
    },
    CheckCase("Dispatcher: Argumente als JSON-Text, leer = {}, kaputt = INVALID_ARGS") {
      let ctx = try makeCtx()
      try expectOk(await ToolRegistry.execute(name: "list_tasks", argumentsJSON: "", ctx: ctx))
      try expectOk(await ToolRegistry.execute(name: "add_task", argumentsJSON: #"{"title":"Aus JSON"}"#, ctx: ctx))
      try expectCode(await ToolRegistry.execute(name: "add_task", argumentsJSON: "{title:", ctx: ctx), "INVALID_ARGS")
      try same(try ctx.store.tasks.list().map(\.title), ["Aus JSON"])
    },
    CheckCase("Dispatcher: typisierte Sicht auf Ergebnisse") {
      let ctx = try makeCtx()
      let r: ToolResult<TabyTask> = ToolRegistry.typed(await run("add_task", ["title": "T"], ctx), key: "task")
      try same(r.value?.title, "T")
      let missing = ToolRegistry.empty(await run("delete_task", ["id": "x"], ctx))
      try check(!missing.isOk)
      try check(missing.errorMessage?.contains("nicht gefunden") == true)
    },
  ]

  // MARK: Aufgaben, Notizen, Habits, Aufträge

  static let entityChecks: [CheckCase] = [
    CheckCase("add_task legt an und list_tasks findet sie") {
      let ctx = try makeCtx()
      let added = await run("add_task", ["title": "Einkaufen", "due": "2024-03-05T10:00"], ctx)
      try expectOk(added)
      let id = try idOf(added, "task")
      try check(titles(await run("list_tasks", [:], ctx)["tasks"]).contains("Einkaufen"))
      try same(try ctx.store.tasks.get(id)?.due, "2024-03-05T10:00")
    },
    CheckCase("list_tasks: Kategorie-Filter nimmt die Kategorie des Ordners, wenn die Aufgabe keine eigene hat") {
      let ctx = try makeCtx()
      let folder = try ctx.store.taskFolders.add(name: "Ordner", categoryId: "arbeit")
      _ = try ctx.store.tasks.add(title: "Im Ordner", notes: nil, due: nil, folderId: folder.id, category: nil, recurrence: nil)
      _ = try ctx.store.tasks.add(title: "Ohne", notes: nil, due: nil, folderId: nil, category: nil, recurrence: nil)
      let shown = titles(await run("list_tasks", ["category": "arbeit"], ctx)["tasks"])
      try check(shown.contains("Im Ordner") && !shown.contains("Ohne"))
    },
    CheckCase("add_task ohne title / mit falschem due → INVALID_ARGS, nichts gespeichert") {
      let ctx = try makeCtx()
      try expectCode(await run("add_task", [:], ctx), "INVALID_ARGS")
      try expectCode(await run("add_task", ["title": "   "], ctx), "INVALID_ARGS")
      try expectCode(await run("add_task", ["title": "X", "due": "morgen"], ctx), "INVALID_ARGS")
      try expectCode(await run("add_task", ["title": 5], ctx), "INVALID_ARGS")
      try expectCode(await run("add_task", ["x", "y"], ctx), "INVALID_ARGS")
      try same(try ctx.store.tasks.list().count, 0)
    },
    CheckCase("update/complete/reopen/delete_task wirken auf die echte DB") {
      let ctx = try makeCtx()
      let id = try idOf(await run("add_task", ["title": "Alt", "due": "2024-03-05"], ctx), "task")
      try same(await run("update_task", ["id": .string(id), "title": "Neu"], ctx)["task"]?["title"], "Neu")
      try same(await run("update_task", ["id": .string(id), "category": "arbeit"], ctx)["task"]?["category"], "arbeit")
      // Kategorien müssen in den Einstellungen stehen (sonst INVALID_ARGS, siehe TaskCategoryChecks).
      _ = try ctx.store.settings.update(SettingsPatch(taskCategories: TaskCategoryDef.builtIn + [TaskCategoryDef(id: "hobby", name: "Hobby", symbol: "star.fill")]))
      try same(await run("update_task", ["id": .string(id), "category": "hobby"], ctx)["task"]?["category"], "hobby")
      try expectCode(await run("update_task", ["id": .string(id), "category": "kein leerzeichen!"], ctx), "INVALID_ARGS")
      let uncat = await run("update_task", ["id": .string(id), "category": ""], ctx)
      try check(uncat["task"]?["category"] == nil, "category: \"\" entfernt die Kategorie")
      let cleared = await run("update_task", ["id": .string(id), "due": nil], ctx)
      try check(cleared["task"]?["due"] == nil, "due: null leert die Fälligkeit")
      try same(await run("complete_task", ["id": .string(id)], ctx)["task"]?["done"], true)
      try same(await run("reopen_task", ["id": .string(id)], ctx)["task"]?["done"], false)
      try expectOk(await run("delete_task", ["id": .string(id)], ctx))
      try expectCode(await run("delete_task", ["id": .string(id)], ctx), "NOT_FOUND")
      try expectCode(await run("update_task", ["id": "fehlt", "title": "x"], ctx), "NOT_FOUND")
    },
    CheckCase("Notizen: anlegen, suchen, ändern, löschen; ohne content abgelehnt") {
      let ctx = try makeCtx()
      let id = try idOf(await run("add_note", ["title": "Einkaufsliste", "content": "Milch, Brot"], ctx), "note")
      try same(titles(await run("search_notes", ["query": "Milch"], ctx)["notes"]), ["Einkaufsliste"])
      try same(await run("search_notes", ["query": "Käse"], ctx)["notes"], [])
      let upd = await run("update_note", ["id": .string(id), "content": "Milch, Brot, Käse"], ctx)
      try check(upd["note"]?["content"]?.stringValue?.contains("Käse") == true)
      try expectOk(await run("delete_note", ["id": .string(id)], ctx))
      try same(await run("list_notes", [:], ctx)["notes"], [])
      try expectCode(await run("add_note", ["title": "X"], ctx), "INVALID_ARGS")
      try expectCode(await run("delete_note", ["id": .string(id)], ctx), "NOT_FOUND")
    },
    CheckCase("Aufträge: schedule_job (read-only Standard), list, cancel stoppt dann entfernt") {
      let ctx = try makeCtx()
      let r = await run("schedule_job", ["name": "Montagserinnerung", "prompt": "Wochenplanung",
                                         "rule": ["type": "weekly", "days": [1], "time": "08:00"]], ctx)
      try expectOk(r)
      try same(r["job"]?["mode"], "read-only")
      try same(r["job"]?["rule"], ["type": "weekly", "days": [1], "time": "08:00"])
      let id = try idOf(r, "job")
      try check(titles(await run("list_jobs", [:], ctx)["jobs"], "id").contains(id))
      try expectOk(await run("cancel_job", ["id": .string(id)], ctx))
      try expectOk(await run("cancel_job", ["id": .string(id)], ctx))  // zweites Mal: entfernt
      try expectCode(await run("cancel_job", ["id": .string(id)], ctx), "NOT_FOUND")
    },
    CheckCase("Aufträge: ungültige Regel → INVALID_ARGS, kein Job angelegt") {
      let ctx = try makeCtx()
      try expectCode(await run("schedule_job", ["name": "X", "prompt": "Y", "rule": ["type": "monthly"]], ctx),
                     "INVALID_ARGS")
      try expectCode(await run("schedule_job", ["name": "X", "prompt": "Y",
                                                "rule": ["type": "weekly", "days": [0, 8], "time": "08:00"]], ctx),
                     "INVALID_ARGS")
      try same(await run("list_jobs", [:], ctx)["jobs"], [])
    },
  ]

  // MARK: Termine und Konflikt-Wächter

  static let eventChecks: [CheckCase] = [
    CheckCase("add_event speichert ohne Konflikt im lokalen Modul") {
      let ctx = try makeCtx()
      let r = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      try expectOk(r)
      try same(r["event"]?["sourceId"], "local")
      try same(try ctx.store.events.listAll().count, 1)
    },
    CheckCase("add_event: Konflikt → CONFLICT mit Titel des Konflikttermins, NICHTS gespeichert") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      let r = await run("add_event", ["title": "Meeting", "start": "2024-03-05T14:30"], ctx)
      try expectCode(r, "CONFLICT")
      try same(r["conflicts"]?.arrayValue?.first?["with"]?["title"], "Zahnarzt")
      try same(r["conflicts"]?.arrayValue?.first?["kind"], "overlap")
      try same(try ctx.store.events.listAll().count, 1)
    },
    CheckCase("add_event: allow_conflict:true speichert trotzdem") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      try expectOk(await run("add_event", ["title": "Meeting", "start": "2024-03-05T14:30", "allow_conflict": true], ctx))
      try same(try ctx.store.events.listAll().count, 2)
    },
    CheckCase("add_event: Wächter nicht umgehbar (falscher Typ, false, null, Lesemodus)") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-05T14:30", "allow_conflict": "true"], ctx),
                     "INVALID_ARGS")
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-05T14:30", "allow_conflict": 1], ctx),
                     "INVALID_ARGS")
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-05T14:30", "allow_conflict": false], ctx),
                     "CONFLICT")
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-05T14:30", "allow_conflict": nil], ctx),
                     "CONFLICT")
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-05T14:30", "end": "2024-03-05T14:00"], ctx),
                     "INVALID_ARGS")
      var ro = ctx
      ro.mode = .readOnly
      try expectCode(await run("add_event", ["title": "M", "start": "2024-03-06T09:00", "allow_conflict": true], ro),
                     "READ_ONLY")
      try same(try ctx.store.events.listAll().map(\.title), ["Zahnarzt"])
    },
    CheckCase("add_event: Konflikt mit Termin aus einem anderen Modul (alle aktiven Module)") {
      let notion = BoundaryCalendarProvider(id: "notion:abc", events: [
        CalendarEvent(id: "n1", sourceId: "notion:abc", title: "Teamrunde", start: "2024-03-05T09:00",
                      end: "2024-03-05T10:00", readOnly: true),
      ])
      let ctx = try makeCtx(extra: [notion])
      let r = await run("add_event", ["title": "Arzt", "start": "2024-03-05T09:30"], ctx)
      try expectCode(r, "CONFLICT")
      try same(r["conflicts"]?.arrayValue?.first?["with"]?["sourceId"], "notion:abc")
      try same(try ctx.store.events.listAll().count, 0)
    },
    CheckCase("add_event: Termin vom Vortag über Mitternacht wird erkannt") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Nachtschicht", "start": "2024-03-04T22:00", "end": "2024-03-05T02:00"], ctx)
      let r = await run("add_event", ["title": "Früh", "start": "2024-03-05T01:00"], ctx)
      try expectCode(r, "CONFLICT")
      try same(r["conflicts"]?.arrayValue?.first?["with"]?["title"], "Nachtschicht")
    },
    CheckCase("add_event: ganztägig ist kein Konflikt, kommt aber als info") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Urlaub", "start": "2024-03-05"], ctx)
      let r = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      try expectOk(r)
      try same(titles(r["info"]), ["Urlaub"])
    },
    CheckCase("add_event: abgelehnter Versuch landet im Protokoll") {
      let ctx = try makeCtx()
      _ = await run("add_event", ["title": "Zahnarzt", "start": "2024-03-05T14:00"], ctx)
      _ = await run("add_event", ["title": "Meeting", "start": "2024-03-05T14:30"], ctx)
      let rejected = try ctx.store.actionLog.list(limit: 100).first { $0.tool == "add_event" && !$0.ok }
      try check(rejected?.error?.contains("überschneidet") == true)
    },
    CheckCase("add_event: schreibt ins Standard-Modul; nicht beschreibbar → Rückfall local") {
      let writable = BoundaryCalendarProvider(id: "notion:w", canWrite: true)
      let ctx = try makeCtx(extra: [writable], defaultWriteId: "notion:w")
      let r = await run("add_event", ["title": "Extern", "start": "2024-03-05T09:00"], ctx)
      try same(r["event"]?["sourceId"], "notion:w")
      try same(writable.created.map(\.title), ["Extern"])
      try same(try ctx.store.events.listAll().count, 0)

      let readOnly = BoundaryCalendarProvider(id: "ics:x", kind: .ics, canWrite: false)
      let ctx2 = try makeCtx(extra: [readOnly], defaultWriteId: "ics:x")
      try same(await run("add_event", ["title": "Lokal", "start": "2024-03-05T09:00"], ctx2)["event"]?["sourceId"],
                      "local")
    },
    CheckCase("add_event: kein beschreibbares Modul / Schreibfehler") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let none = ToolContext(store: store, calendar: ProviderCalendarAccess(providers: [
        BoundaryCalendarProvider(id: "ics:x", kind: .ics),
      ]))
      try expectCode(await run("add_event", ["title": "X", "start": "2024-03-05T09:00"], none), "NO_WRITE_PROVIDER")
      let broken = BoundaryCalendarProvider(id: "notion:b", canWrite: true,
                                            failure: CalendarError.unreachable("Notion antwortet nicht."))
      let ctx = ToolContext(store: store, calendar: ProviderCalendarAccess(providers: [broken], defaultWriteId: "notion:b"))
      let r = await run("add_event", ["title": "X", "start": "2024-03-05T09:00"], ctx)
      try expectCode(r, "CALENDAR_ERROR")
      try check(try store.actionLog.list(limit: 10).contains { $0.tool == "add_event" && !$0.ok })
    },
    CheckCase("add_event/list_events: ausgefallenes Modul kippt nichts, wird gemeldet") {
      let down = BoundaryCalendarProvider(id: "ics:down", kind: .ics,
                                          failure: CalendarError.unreachable("ICS-Feed nicht erreichbar."))
      let ctx = try makeCtx(extra: [down])
      let r = await run("add_event", ["title": "Termin", "start": "2024-03-05T09:00"], ctx)
      try expectOk(r)
      try same(r["unreachableCalendarSources"]?.arrayValue?.first?["id"], "ics:down")
      let l = await run("list_events", ["from": "2024-03-05", "to": "2024-03-06"], ctx)
      try same(titles(l["events"]), ["Termin"])
      try same(l["unreachableCalendarSources"]?.arrayValue?.first?["message"], "ICS-Feed nicht erreichbar.")
    },
    CheckCase("list_events: Zeitraum über alle Module, sortiert") {
      let other = BoundaryCalendarProvider(id: "notion:abc", events: [
        CalendarEvent(id: "n1", sourceId: "notion:abc", title: "Notion früh", start: "2024-03-05T08:00"),
      ])
      let ctx = try makeCtx(extra: [other])
      _ = await run("add_event", ["title": "Im Bereich", "start": "2024-03-05T10:00"], ctx)
      _ = await run("add_event", ["title": "Außerhalb", "start": "2024-03-10T10:00"], ctx)
      let r = await run("list_events", ["from": "2024-03-05", "to": "2024-03-06"], ctx)
      try same(titles(r["events"]), ["Notion früh", "Im Bereich"])
      try expectCode(await run("list_events", ["from": "2024-03-05"], ctx), "INVALID_ARGS")
    },
    CheckCase("ToolRegistry.addEvent: Vertragstyp für die Oberfläche") {
      let ctx = try makeCtx(actor: .user)
      guard case .ok(let e, _, _) = await ToolRegistry.addEvent(
        AddEventRequest(event: NewEvent(title: "Zahnarzt", start: "2024-03-05T14:00")), ctx: ctx) else {
        throw fail("erwartet .ok")
      }
      try same(e.title, "Zahnarzt")
      let second = await ToolRegistry.addEvent(
        AddEventRequest(event: NewEvent(title: "Meeting", start: "2024-03-05T14:00", end: "2024-03-05T15:00")), ctx: ctx)
      guard case .conflict(let msg, let conflicts) = second else { throw fail("erwartet .conflict: \(second)") }
      try same(msg, EventTools.overlapMessage)
      try same(conflicts.map(\.with.title), ["Zahnarzt"])
      try same(conflicts.map(\.kind), [.sameStart])
      try same(try ctx.store.actionLog.list(limit: 10).first?.actor, .user)
      guard case .ok = await ToolRegistry.addEvent(
        AddEventRequest(event: NewEvent(title: "Meeting", start: "2024-03-05T14:00"), allowConflict: true), ctx: ctx)
      else { throw fail("allowConflict sollte speichern") }
      try same(try ctx.store.events.listAll().count, 2)
    },
  ]

  // MARK: Lesemodus und Protokoll

  static let modeAndLogChecks: [CheckCase] = [
    CheckCase("Lesemodus: Lesewerkzeuge + add_task + add_note erlaubt") {
      let ctx = try makeCtx(mode: .readOnly, actor: .job)
      let allowed: [(String, JSONValue)] = [
        ("get_overview", [:]), ("list_tasks", [:]), ("add_task", ["title": "x"]), ("list_notes", [:]),
        ("search_notes", ["query": "x"]), ("add_note", ["title": "x", "content": "y"]),
        ("list_events", ["from": "2024-03-04", "to": "2024-03-05"]), ("list_jobs", [:]),
      ]
      for (name, args) in allowed {
        try check(await run(name, args, ctx)["ok"] == true, "\(name) sollte im Lesemodus erlaubt sein")
      }
    },
    CheckCase("Lesemodus: update_*, delete_*, add_event usw. gesperrt, ohne Seiteneffekte") {
      let ctx = try makeCtx(mode: .readOnly, actor: .job)
      let task = try ctx.store.tasks.add(title: "Bestehend")
      let note = try ctx.store.notes.add(title: "N", content: "C")
      let blocked: [(String, JSONValue)] = [
        ("update_task", ["id": .string(task.id), "title": "Geändert"]), ("complete_task", ["id": .string(task.id)]),
        ("reopen_task", ["id": .string(task.id)]), ("delete_task", ["id": .string(task.id)]),
        ("update_note", ["id": .string(note.id), "title": "X"]), ("delete_note", ["id": .string(note.id)]),
        ("add_event", ["title": "Termin", "start": "2024-03-05T10:00"]),
        ("schedule_job", ["name": "X", "prompt": "Y", "rule": ["type": "daily", "time": "08:00"]]),
        ("cancel_job", ["id": "x"]),
      ]
      for (name, args) in blocked {
        try expectCode(await run(name, args, ctx), "READ_ONLY")
      }
      let still = try expectNotNil(try ctx.store.tasks.get(task.id))
      try same(still.title, "Bestehend")
      try check(!still.done)
      try same(try ctx.store.notes.get(note.id)?.title, "N")
      try same(try ctx.store.events.listAll().count, 0)
      try same(try ctx.store.jobs.list().count, 0)
      let log = try ctx.store.actionLog.list(limit: 100)
      try same(log.count, blocked.count)
      try check(log.allSatisfy { !$0.ok && $0.actor == .job })
    },
    CheckCase("Protokoll: erfolgreiche Änderung mit actor/tool/argsJson/ok") {
      let ctx = try makeCtx(actor: .assistant)
      _ = await run("add_task", ["title": "Steuererklärung"], ctx)
      let entries = try ctx.store.actionLog.list(limit: 10)
      try same(entries.count, 1)
      try same(entries[0].actor, .assistant)
      try same(entries[0].tool, "add_task")
      try check(entries[0].ok)
      try same(JSONValue.parse(entries[0].argsJson), ["title": "Steuererklärung"])
    },
    CheckCase("Protokoll: Fehlschlag mit Fehlertext; Lesewerkzeuge nicht protokolliert") {
      let ctx = try makeCtx()
      _ = await run("delete_task", ["id": "unbekannt"], ctx)
      var entries = try ctx.store.actionLog.list(limit: 10)
      try same(entries.count, 1)
      try check(!entries[0].ok)
      try check(entries[0].error?.contains("unbekannt") == true)
      _ = await run("add_task", ["title": "X"], ctx)
      _ = await run("list_tasks", [:], ctx)
      _ = await run("get_overview", [:], ctx)
      _ = await run("search_notes", ["query": "x"], ctx)
      entries = try ctx.store.actionLog.list(limit: 10)
      try same(entries.map(\.tool), ["add_task", "delete_task"])
    },
    CheckCase("Protokoll: nur Werkzeug-Argumente, keine Geheimnisse") {
      let ctx = try makeCtx()
      _ = await run("add_note", ["title": "Zugang", "content": "kein Token hier"], ctx)
      let json = try ctx.store.actionLog.list(limit: 1)[0].argsJson
      try check(json.range(of: #"sk-|Bearer|api[_-]?key"#, options: [.regularExpression, .caseInsensitive]) == nil)
    },
  ]

  // MARK: Validierung (Port von validate.test.ts)

  static let validationChecks: [CheckCase] = [
    CheckCase("Validierung: Argumente müssen ein Objekt sein") {
      for bad: JSONValue in [[], nil, "x", 5] {
        try await expectThrows("\(bad) sollte abgelehnt werden") { _ = try ToolArgs.from(bad) }
      }
      try same(try ToolArgs.from(["a": 1]).raw, ["a": 1])
    },
    CheckCase("Validierung: requireString lehnt fehlend/leer/nicht-Text ab") {
      try await expectThrows { _ = try ToolArgs([:]).requireString("title") }
      try await expectThrows { _ = try ToolArgs(["title": "  "]).requireString("title") }
      try await expectThrows { _ = try ToolArgs(["title": 5]).requireString("title") }
      try same(try ToolArgs(["title": "x"]).requireString("title"), "x")
      do {
        _ = try ToolArgs([:]).requireString("title")
      } catch let e as ToolValidationError {
        try same(e.message, "\"title\" fehlt oder ist leer")
      }
    },
    CheckCase("Validierung: Datum oder Datum+Uhrzeit, sonst Fehler") {
      try same(try ToolArgs(["due": "2024-03-04"]).requireLocalDateTime("due"), "2024-03-04")
      try same(try ToolArgs(["due": "2024-03-04T10:00"]).requireLocalDateTime("due"), "2024-03-04T10:00")
      try await expectThrows { _ = try ToolArgs(["due": "04.03.2024"]).requireLocalDateTime("due") }
      try await expectThrows { _ = try ToolArgs(["due": "2024-03-04T10:00:00"]).requireLocalDateTime("due") }
      try check(try ToolArgs([:]).optionalLocalDateTime("due") == nil)
      try check(try ToolArgs(["due": nil]).optionalLocalDateTime("due") == nil)
      try await expectThrows { _ = try ToolArgs(["due": "morgen"]).optionalLocalDateTime("due") }
      try await expectThrows { _ = try ToolArgs(["d": "2024-03-04T10:00"]).requireDateOnly("d") }
    },
    CheckCase("Validierung: Kalenderwerte – Monat, Tag im Monat, Schaltjahr, Stunde und Minute") {
      try await expectThrows { _ = try ToolArgs(["d": "2026-13-01"]).requireDateOnly("d") }
      try await expectThrows { _ = try ToolArgs(["d": "2026-00-10"]).requireDateOnly("d") }
      try await expectThrows { _ = try ToolArgs(["d": "2026-02-30"]).requireDateOnly("d") }
      try await expectThrows { _ = try ToolArgs(["d": "2025-02-29"]).requireDateOnly("d") }
      try same(try ToolArgs(["d": "2028-02-29"]).requireDateOnly("d"), "2028-02-29")
      try await expectThrows { _ = try ToolArgs(["due": "2026-04-31T10:00"]).requireLocalDateTime("due") }
      try await expectThrows { _ = try ToolArgs(["due": "2026-10-17T24:00"]).requireLocalDateTime("due") }
      try await expectThrows { _ = try ToolArgs(["due": "2026-10-17T09:60"]).optionalLocalDateTime("due") }
      try same(try ToolArgs(["due": "2026-10-17T23:59"]).requireLocalDateTime("due"), "2026-10-17T23:59")
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "daily", "time": "25:00"]]).jobRule("rule") }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "daily", "time": "12:61"]]).jobRule("rule") }
      try same(try ToolArgs(["rule": ["type": "daily", "time": "23:59"]]).jobRule("rule"), JobRule.daily(time: "23:59"))
    },
    CheckCase("Validierung: JobRule daily/weekly/once") {
      try same(try ToolArgs(["rule": ["type": "daily", "time": "08:00"]]).jobRule(), .daily(time: "08:00"))
      try same(try ToolArgs(["rule": ["type": "weekly", "days": [1, 3], "time": "08:00"]]).jobRule(),
                      .weekly(days: [1, 3], time: "08:00"))
      try same(try ToolArgs(["rule": ["type": "once", "at": "2024-03-10T08:00"]]).jobRule(),
                      .once(at: "2024-03-10T08:00"))
    },
    CheckCase("Validierung: JobRule lehnt unbekannten Typ, fehlende Felder, falsche Wochentage ab") {
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "monthly"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "daily"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "daily", "time": "8:00"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "weekly", "days": [0, 8], "time": "08:00"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "weekly", "days": [], "time": "08:00"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": ["type": "weekly", "days": [1.5], "time": "08:00"]]).jobRule() }
      try await expectThrows { _ = try ToolArgs(["rule": "daily"]).jobRule() }
    },
  ]

  // MARK: Überblick (Port von overview.test.ts)

  static let overviewChecks: [CheckCase] = [
    CheckCase("get_overview bündelt Aufgaben, Termine, Konflikte deterministisch") {
      let ctx = try makeCtx(now: "2024-03-04T08:00")
      _ = await run("add_task", ["title": "Überfällig", "due": "2024-03-01"], ctx)
      _ = await run("add_task", ["title": "Heute", "due": "2024-03-04T17:00"], ctx)
      _ = await run("add_task", ["title": "Bald", "due": "2024-03-06"], ctx)
      _ = await run("add_task", ["title": "Ohne Datum"], ctx)
      let doneId = try idOf(await run("add_task", ["title": "Erledigt", "due": "2024-03-01"], ctx), "task")
      _ = await run("complete_task", ["id": .string(doneId)], ctx)
      _ = await run("add_event", ["title": "Termin A", "start": "2024-03-04T10:00"], ctx)
      _ = await run("add_event", ["title": "Termin B", "start": "2024-03-04T10:30", "allow_conflict": true], ctx)
      _ = await run("add_event", ["title": "Später", "start": "2024-03-07T10:00"], ctx)
      _ = await run("add_event", ["title": "Zu weit", "start": "2024-03-20T10:00"], ctx)

      let r = await run("get_overview", [:], ctx)
      try expectOk(r)
      let o = try expectNotNil(r["overview"].flatMap { ToolJSON.decode(Overview.self, from: $0) })
      try same(o.overdueTasks.map(\.title), ["Überfällig"])
      try same(o.todayTasks.map(\.title), ["Heute"])
      try same(o.upcomingTasks.map(\.title), ["Bald"])
      try same(o.habitsToday.isEmpty, true)
      try same(o.eventsToday.map(\.title).sorted(), ["Termin A", "Termin B"])
      try same(o.eventsUpcoming.map(\.title), ["Später"])
      try same(o.conflicts.count, 1)
      try same(o.unreachableCalendarSources, [])
    },
    CheckCase("buildOverview: Erinnerungen heute, Verpasstes mit Titel, ausgefallene Quelle") {
      let down = BoundaryCalendarProvider(id: "notion:down", failure: CalendarError.unreachable("Notion antwortet nicht."))
      let ctx = try makeCtx(now: "2024-03-04T10:00", extra: [down])
      let task = try ctx.store.tasks.add(title: "Steuer", due: "2024-03-04T09:00")
      let job = try ctx.store.jobs.add(name: "Morgenrunde", prompt: "x", rule: .daily(time: "07:00"))
      let missedTask = try ctx.store.reminders.add(source: .task, sourceRef: task.id, dueAt: "2024-03-04T08:50")
      try ctx.store.reminders.add(source: .job, sourceRef: job.id, dueAt: "2024-03-04T18:00")
      let ack = try ctx.store.reminders.add(source: .event, sourceRef: "weg", dueAt: "2024-03-04T07:00")
      try ctx.store.reminders.acknowledge([ack.id], at: "2024-03-04T07:30")
      try ctx.store.reminders.add(source: .event, sourceRef: "morgen", dueAt: "2024-03-05T07:00")

      let o = try await buildOverview(store: ctx.store, clock: ctx.clock, calendar: ctx.calendar)
      try same(o.missed.map(\.reminder.id), [missedTask.id])
      try same(o.missed.map(\.title), ["Steuer"])
      try same(o.remindersToday.map(\.title), ["weg", "Steuer", "Morgenrunde"], "nach Fälligkeit")
      try same(o.unreachableCalendarSources, [SourceProblem(id: "notion:down", message: "Notion antwortet nicht.")])
      try same(o.todayTasks.map(\.title), ["Steuer"])
    },
  ]
}
