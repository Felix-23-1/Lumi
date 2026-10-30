// add_event mit Konflikt-Wächter (BAUPLAN Abschnitt 7), list_events,
// list_calendars, delete_event und move_event, Port von
// src/main/tools/events.ts. Reiner Code, kein Modell: findConflicts über
// alle aktiven Module; bei Konflikt wird NICHTS gespeichert, erst
// allow_conflict:true schreibt. Ohne Angabe wird ins "Standard zum
// Schreiben"-Modul geschrieben; mit `calendar` in eine bestimmte Quelle.
// delete_event und move_event löschen und verlangen Bestätigung
// (`ToolRegistry.confirmationRequired`).
import Foundation

enum EventTools {
  static let overlapMessage = "Der Termin überschneidet sich mit einem bestehenden Termin."

  /// Überschneidung hat Vorrang vor "zu knapp" (Puffer).
  static func conflictMessage(_ conflicts: [Conflict], bufferMinutes: Int) -> String {
    if conflicts.contains(where: { $0.kind != .tooClose }) { return overlapMessage }
    return "Der Termin ist zu knapp (weniger als \(bufferMinutes) Minuten Abstand) an einem bestehenden Termin."
  }

  static let defs: [ToolDef] = [
    ToolDef(
      name: "add_event",
      description:
        "Legt einen Termin an. Prüft zuerst auf Überschneidungen über alle aktiven Kalendermodule; bei Konflikt wird nichts gespeichert, außer allow_conflict ist true. Ohne calendar wird ins Standard-Modul geschrieben (siehe list_calendars).",
      parameters: ToolSchema.object([
        "title": ToolSchema.string(),
        "start": ToolSchema.string("\"JJJJ-MM-TT\" (ganztägig) oder \"JJJJ-MM-TTTHH:mm\""),
        "end": ToolSchema.string("optional, gleiches Format wie start"),
        "notes": ToolSchema.string(),
        "calendar": ToolSchema.string("Kalenderquelle: 'apple', 'local', 'notion', 'ics' oder die Quellen-ID; leer = Standard"),
        "allow_conflict": ["type": "boolean", "description": "true, um trotz gemeldeter Konflikte zu speichern"],
      ], required: ["title", "start"])),
    ToolDef(
      name: "list_events",
      description:
        "Listet Termine eines Zeitraums über alle aktiven Kalendermodule. Jeder Termin trägt id und source_id (für delete_event und move_event).",
      parameters: ToolSchema.object([
        "from": ToolSchema.string("\"JJJJ-MM-TT\", inklusiv"),
        "to": ToolSchema.string("\"JJJJ-MM-TT\", exklusiv"),
      ], required: ["from", "to"])),
    ToolDef(
      name: "list_calendars",
      description:
        "Listet die aktiven Kalenderquellen mit id, kind, Name, beschreibbar und isDefault (Standard für neue Termine).",
      parameters: ToolSchema.object()),
    ToolDef(
      name: "delete_event",
      description: "Löscht einen Termin in seiner Kalenderquelle. Nur nach Bestätigung durch den Nutzer.",
      parameters: ToolSchema.object([
        "id": ToolSchema.string("Termin-ID aus list_events"),
        "source_id": ToolSchema.string("source_id aus list_events"),
      ], required: ["id", "source_id"])),
    ToolDef(
      name: "move_event",
      description:
        "Verschiebt einen Termin: legt den neuen Termin zuerst an und löscht erst dann den alten. Titel und Notizen bleiben. Ohne calendar bleibt er in seiner Quelle. Nur nach Bestätigung durch den Nutzer.",
      parameters: ToolSchema.object([
        "id": ToolSchema.string("Termin-ID aus list_events"),
        "source_id": ToolSchema.string("source_id aus list_events"),
        "start": ToolSchema.string("neuer Beginn: \"JJJJ-MM-TT\" (ganztägig) oder \"JJJJ-MM-TTTHH:mm\""),
        "end": ToolSchema.string("optional, gleiches Format wie start"),
        "calendar": ToolSchema.string("Ziel-Kalenderquelle: 'apple', 'local', 'notion', 'ics' oder die Quellen-ID; leer = gleiche Quelle"),
        "allow_conflict": ["type": "boolean", "description": "true, um trotz gemeldeter Konflikte zu verschieben"],
      ], required: ["id", "source_id", "start"])),
  ]

  /// Deutscher Name einer Quellenart für Modelle und Oberfläche.
  static func sourceName(_ kind: CalendarSourceKind) -> String {
    switch kind {
    case .local: "Lokal"
    case .apple: "Apple Kalender"
    case .notion: "Notion"
    case .ics: "ICS-Kalender"
    case .caldav: "CalDAV-Kalender"
    case .microsoft: "Outlook-Kalender"
    }
  }

  /// Beschreibbare Quelle zu einer Angabe: exakte ID, sonst erste beschreibbare
  /// Quelle derselben Art. Unbekannt oder nicht beschreibbar → INVALID_ARGS mit
  /// der Liste der beschreibbaren Quellen.
  static func writableSource(_ ref: String, in calendar: ToolCalendarAccess) throws -> CalendarProvider {
    let providers = calendar.activeProviders()
    if let p = providers.first(where: { $0.id == ref && $0.canWrite })
      ?? providers.first(where: { $0.kind.rawValue == ref && $0.canWrite }) {
      return p
    }
    let writable = providers.filter(\.canWrite).map { "\($0.id) (\(sourceName($0.kind)))" }
    throw ToolValidationError(
      "Kalender \"\(ref)\" ist unbekannt oder nicht beschreibbar. Beschreibbar: \(writable.isEmpty ? "keine" : writable.joined(separator: ", ")).")
  }

  /// Gewünschtes Ziel: leer/nicht angegeben = Standard (nil), sonst die Quelle.
  static func targetProvider(_ ref: String?, in calendar: ToolCalendarAccess) throws -> CalendarProvider? {
    guard let ref, !ref.isEmpty else { return nil }
    return try writableSource(ref, in: calendar)
  }

  /// Konflikte eines Termins mit allen aktiven Modulen. `ignoring`: der alte Termin beim Verschieben.
  static func checkConflicts(_ e: NewEvent, calendar: ToolCalendarAccess, bufferMinutes: Int,
                             ignoring: CalendarEvent? = nil) async
    -> (conflicts: [Conflict], others: [CalendarEvent], unreachable: [SourceProblem])
  {
    // Ab dem Vortag laden, damit ein Termin, der vor Mitternacht beginnt und
    // in den neuen Tag hineinreicht, ebenfalls geprüft wird (mehrtägige: siehe CalendarSupport.inRange).
    let from = StoreDates.shiftDateOnly(LocalTime.datePart(e.start), -1)
    let to = StoreDates.shiftDateOnly(LocalTime.datePart(e.end ?? e.start), 1)
    // Konfliktprüfung auf frischen Ferndaten, nicht auf einem bis zu 5 Min alten Cache.
    calendar.refreshRemoteCaches()
    let listing = await calendar.listAllEvents(from: from, to: to)
    let others = listing.events.filter { ev in
      guard let old = ignoring else { return true }
      return !(ev.id == old.id && ev.sourceId == old.sourceId)
    }
    return (findConflicts(e, others, bufferMinutes: bufferMinutes), others, listing.unreachable)
  }

  /// Der eigentliche Wächter (ohne Protokoll/Lesemodus – das macht der Dispatcher).
  /// `target`: Zielmodul (nil = Standard). `ignoring`: Termin, der nicht als
  /// Konflikt zählt (beim Verschieben der alte Termin).
  static func addEvent(_ req: AddEventRequest, calendar: ToolCalendarAccess, bufferMinutes: Int = 0,
                       target: CalendarProvider? = nil, ignoring: CalendarEvent? = nil) async
    -> AddEventResult
  {
    let e = req.event
    let check = await checkConflicts(e, calendar: calendar, bufferMinutes: bufferMinutes, ignoring: ignoring)
    if !check.conflicts.isEmpty && !req.allowConflict {
      return .conflict(error: conflictMessage(check.conflicts, bufferMinutes: bufferMinutes), conflicts: check.conflicts)
    }
    guard let provider = target ?? calendar.defaultWriteProvider() else {
      return .failure(code: "NO_WRITE_PROVIDER", error: "Kein beschreibbares Kalendermodul verfügbar.")
    }
    do {
      let created = try await provider.createEvent(e)
      return .ok(event: created, info: allDayNotices(e, check.others), unreachable: check.unreachable)
    } catch {
      return .failure(code: "CALENDAR_ERROR", error: calendarErrorMessage(error))
    }
  }

  static func toJSON(_ r: AddEventResult) -> JSONValue {
    switch r {
    case .ok(let event, let info, let unreachable):
      return ToolJSON.ok([
        "event": ToolJSON.encode(event), "info": ToolJSON.encode(info),
        "unreachableCalendarSources": ToolJSON.encode(unreachable),
      ])
    case .conflict(let error, let conflicts):
      return ToolJSON.failure(code: "CONFLICT", error: error, ["conflicts": ToolJSON.encode(conflicts)])
    case .failure(let code, let error):
      return ToolJSON.failure(code: code, error: error)
    }
  }

  static func fromJSON(_ v: JSONValue) -> AddEventResult {
    if v["ok"]?.boolValue == true,
       let event = v["event"].flatMap({ ToolJSON.decode(CalendarEvent.self, from: $0) }) {
      let info = v["info"].flatMap { ToolJSON.decode([CalendarEvent].self, from: $0) } ?? []
      let unreachable = v["unreachableCalendarSources"].flatMap { ToolJSON.decode([SourceProblem].self, from: $0) } ?? []
      return .ok(event: event, info: info, unreachable: unreachable)
    }
    let code = v["code"]?.stringValue ?? "ERROR"
    let error = v["error"]?.stringValue ?? "Unbekannter Fehler"
    if code == "CONFLICT" {
      let conflicts = v["conflicts"].flatMap { ToolJSON.decode([Conflict].self, from: $0) } ?? []
      return .conflict(error: error, conflicts: conflicts)
    }
    return .failure(code: code, error: error)
  }

  /// Ende mit der Dauer des alten Termins ab `newStart` (Wanduhr, ohne Zeitzone); nil, wenn er keins hatte.
  static func keepDuration(of old: CalendarEvent, newStart: String) -> String? {
    guard let oldEnd = old.end, let s = StoreDates.wallClock(old.start), let e = StoreDates.wallClock(oldEnd),
          let ns = StoreDates.wallClock(newStart) else { return nil }
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")  // wallClock rechnet in UTC
    f.dateFormat = LocalTime.isDateOnly(newStart) ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
    return f.string(from: ns.addingTimeInterval(e.timeIntervalSince(s)))
  }

  static let handlers: [String: ToolHandler] = [
    "add_event": { ctx, args in
      let title = try args.requireString("title")
      let start = try args.requireLocalDateTime("start")
      let end = try args.optionalLocalDateTime("end")
      let notes = try args.optionalString("notes")
      let allowConflict = try args.optionalBool("allow_conflict") ?? false
      if let end, let s = StoreDates.wallClock(start), let e = StoreDates.wallClock(end), e < s {
        throw ToolValidationError("\"end\" darf nicht vor \"start\" liegen")
      }
      let target = try targetProvider(try args.optionalString("calendar"), in: ctx.calendar)
      let req = AddEventRequest(event: NewEvent(title: title, start: start, end: end, notes: notes),
                                allowConflict: allowConflict)
      let bufferMinutes = try ctx.store.settings.get().bufferMinutes
      return toJSON(await addEvent(req, calendar: ctx.calendar, bufferMinutes: bufferMinutes, target: target))
    },
    "list_events": { ctx, args in
      let from = try args.requireDateOnly("from")
      let to = try args.requireDateOnly("to")
      let listing = await ctx.calendar.listAllEvents(from: from, to: to)
      // Titel und Notizen fremder Termine sind Material, keine Anweisungen.
      return ToolJSON.ok([
        "events": ToolJSON.encode(listing.events),
        "note": .string(ForeignContent.note),
        "unreachableCalendarSources": ToolJSON.encode(listing.unreachable),
      ])
    },
    "list_calendars": { ctx, _ in
      let defaultId = ctx.calendar.defaultWriteProvider()?.id
      let items: [JSONValue] = ctx.calendar.activeProviders().map { p in
        .object([
          "id": .string(p.id), "kind": .string(p.kind.rawValue), "name": .string(sourceName(p.kind)),
          "writable": .bool(p.canWrite), "isDefault": .bool(p.id == defaultId),
        ])
      }
      return ToolJSON.ok(["calendars": .array(items)])
    },
    "delete_event": { ctx, args in
      let id = try args.requireId()
      let sourceId = try args.requireString("source_id")
      guard ctx.calendar.activeProviders().contains(where: { $0.id == sourceId }) else {
        throw ToolValidationError("Kalendermodul \"\(sourceId)\" ist nicht aktiv.")
      }
      do { try await ctx.calendar.deleteEvent(id: id, sourceId: sourceId) } catch {
        return ToolJSON.failure(code: "CALENDAR_ERROR", error: calendarErrorMessage(error))
      }
      return ToolJSON.ok()
    },
    "move_event": { ctx, args in
      let id = try args.requireId()
      let sourceId = try args.requireString("source_id")
      let start = try args.requireLocalDateTime("start")
      let end = try args.optionalLocalDateTime("end")
      let calendarRef = try args.optionalString("calendar")
      let allowConflict = try args.optionalBool("allow_conflict") ?? false
      if let end, let s = StoreDates.wallClock(start), let e = StoreDates.wallClock(end), e < s {
        throw ToolValidationError("\"end\" darf nicht vor \"start\" liegen")
      }
      guard let source = ctx.calendar.activeProviders().first(where: { $0.id == sourceId }) else {
        throw ToolValidationError("Kalendermodul \"\(sourceId)\" ist nicht aktiv.")
      }
      // Vor dem Anlegen prüfen: sonst entstünde ein Duplikat, wenn das Löschen scheitert.
      guard source.canWrite else {
        return ToolJSON.failure(code: "CALENDAR_ERROR", error: calendarErrorMessage(CalendarError.notWritable(sourceId)))
      }
      var target = source
      if let ref = calendarRef, !ref.isEmpty { target = try writableSource(ref, in: ctx.calendar) }

      // Den alten Termin suchen (ein Jahr vor/nach dem neuen Beginn).
      let day = LocalTime.datePart(start)
      let old: CalendarEvent
      do {
        let near = try await source.listEvents(from: StoreDates.shiftDateOnly(day, -366),
                                               to: StoreDates.shiftDateOnly(day, 367))
        guard let found = near.first(where: { $0.id == id }) else {
          return ToolJSON.failure(code: "NOT_FOUND", error: "Termin \"\(id)\" in \"\(sourceId)\" nicht gefunden.")
        }
        old = found
      } catch {
        return ToolJSON.failure(code: "CALENDAR_ERROR", error: calendarErrorMessage(error))
      }

      // Titel und Notizen bleiben; ganztägig bleibt ganztägig; ohne end bleibt die Dauer.
      let newStart = old.allDay ? day : start
      let newEnd = end.map { old.allDay ? LocalTime.datePart($0) : $0 } ?? keepDuration(of: old, newStart: newStart)
      let newEvent = NewEvent(title: old.title, start: newStart, end: newEnd, notes: old.notes)
      let bufferMinutes = try ctx.store.settings.get().bufferMinutes
      // Apple Kalender: den Termin in place verschieben, damit Teilnehmer, Ort, Alarme und URL bleiben.
      if target.id == source.id, let apple = source as? AppleCalendarProvider {
        let check = await checkConflicts(newEvent, calendar: ctx.calendar, bufferMinutes: bufferMinutes, ignoring: old)
        if !check.conflicts.isEmpty && !allowConflict {
          return toJSON(.conflict(error: conflictMessage(check.conflicts, bufferMinutes: bufferMinutes),
                                  conflicts: check.conflicts))
        }
        do {
          let moved = try await apple.moveEvent(id: old.id, start: newStart, end: newEnd)
          return toJSON(.ok(event: moved, info: allDayNotices(newEvent, check.others), unreachable: check.unreachable))
        } catch {
          return ToolJSON.failure(code: "CALENDAR_ERROR", error: calendarErrorMessage(error))
        }
      }
      // Andere Module: neu anlegen (Titel, Notizen, Ganztägig, Ende) und danach das Original löschen.
      let result = await addEvent(AddEventRequest(event: newEvent, allowConflict: allowConflict),
                                  calendar: ctx.calendar, bufferMinutes: bufferMinutes, target: target, ignoring: old)
      guard case .ok(let created, _, _) = result else { return toJSON(result) }

      do { try await ctx.calendar.deleteEvent(id: old.id, sourceId: sourceId) } catch {
        return ToolJSON.failure(
          code: "CALENDAR_ERROR",
          error: "Der neue Termin „\(created.title)“ wurde angelegt, das Original konnte aber nicht gelöscht werden: \(calendarErrorMessage(error))",
          ["event": ToolJSON.encode(created)])
      }
      return toJSON(result)
    },
  ]
}
