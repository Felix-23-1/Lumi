// find_free_time (Paket 1): freie Zeitfenster zwischen Terminen mit Uhrzeit.
// Reiner Code, kein Modell. Ganztägige Termine werden ignoriert; der Puffer
// (TabySettings.bufferMinutes) liegt rund um jeden Termin mit Uhrzeit.
import Foundation

/// Freies Zeitfenster; Start und Ende als lokale ISO-Strings "YYYY-MM-DDTHH:mm".
public struct FreeSlot: Codable, Equatable, Sendable {
  public var start: String
  public var end: String

  public init(start: String, end: String) {
    self.start = start; self.end = end
  }
}

public enum FreeTime {
  /// Höchstens so viele Fenster werden zurückgegeben.
  public static let maxSlots = 20
  /// Schutz gegen sehr lange Zeiträume (Tage werden einzeln durchlaufen).
  static let maxDays = 400

  /// Minuten seit 1970 in lokaler Wanduhrzeit (ohne Zeitzone, UTC-gerechnet).
  private static func minutes(_ s: String) -> Int? {
    guard let d = StoreDates.wallClock(s) else { return nil }
    return Int((d.timeIntervalSince1970 / 60).rounded(.down))
  }

  /// Gegenstück zu `minutes`: "YYYY-MM-DDTHH:mm".
  private static func wallString(_ minutes: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let d = Date(timeIntervalSince1970: TimeInterval(minutes) * 60)
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }

  /// Freie Lücken im Tagesfenster `dayStart`–`dayEnd` für jeden Tag in
  /// [`from`, `to`) (beide "YYYY-MM-DD", `to` exklusiv), die mindestens
  /// `durationMinutes` lang sind. Termine mit Uhrzeit blockieren ihr Intervall
  /// (Ende ohne Angabe = Start + 60 Minuten), erweitert um `bufferMinutes` auf
  /// beiden Seiten. Am heutigen Tag (laut `now`, lokal "YYYY-MM-DDTHH:mm") gilt
  /// nichts vor `now`. Ergebnis chronologisch, höchstens `maxSlots` Fenster.
  public static func slots(events: [CalendarEvent], from: String, to: String, durationMinutes: Int,
                           dayStart: String = "08:00", dayEnd: String = "20:00", bufferMinutes: Int = 0,
                           now: String) -> [FreeSlot] {
    let buffer = max(0, bufferMinutes)
    var busy: [(start: Int, end: Int)] = []
    for ev in events where !ev.allDay && !LocalTime.isDateOnly(ev.start) {
      guard let s = minutes(ev.start) else { continue }
      let e = max(s, ev.end.flatMap { minutes($0) } ?? (s + 60))
      busy.append((start: s - buffer, end: e + buffer))
    }

    let today = LocalTime.datePart(now)
    let nowMinutes = minutes(now)
    var slots: [FreeSlot] = []
    var day = from
    var dayCount = 0

    while day < to && dayCount < maxDays && slots.count < maxSlots {
      dayCount += 1
      defer { day = StoreDates.shiftDateOnly(day, 1) }
      guard let windowStart = minutes("\(day)T\(dayStart)"), let windowEnd = minutes("\(day)T\(dayEnd)"),
            windowEnd > windowStart else { continue }

      var cursor = windowStart
      if day == today, let nowMinutes { cursor = max(cursor, nowMinutes) }

      func addGap(_ from: Int, _ to: Int) {
        guard to - from >= durationMinutes, slots.count < maxSlots else { return }
        slots.append(FreeSlot(start: wallString(from), end: wallString(to)))
      }

      let overlapping = busy
        .filter { $0.start < windowEnd && $0.end > windowStart }
        .sorted { $0.start < $1.start }
      for b in overlapping {
        if cursor >= windowEnd { break }
        if b.start > cursor { addGap(cursor, min(b.start, windowEnd)) }
        cursor = max(cursor, b.end)
      }
      if cursor < windowEnd { addGap(cursor, windowEnd) }
    }
    return slots
  }
}

/// Werkzeug find_free_time (lesend, im Lesemodus erlaubt).
enum FreeTimeTools {
  static let defs: [ToolDef] = [
    ToolDef(
      name: "find_free_time",
      description:
        "Sucht freie Zeitfenster zwischen Terminen mit Uhrzeit (ganztägige Termine werden ignoriert, der Puffer zwischen Terminen wird berücksichtigt). Vergangene Zeit am heutigen Tag entfällt. Liefert höchstens 20 Fenster.",
      parameters: ToolSchema.object([
        "from": ToolSchema.string("\"JJJJ-MM-TT\", inklusiv"),
        "to": ToolSchema.string("\"JJJJ-MM-TT\", exklusiv"),
        "duration_minutes": ["type": "integer", "description": "Mindestlänge des Fensters in Minuten (5 bis 720)"],
        "day_start": ToolSchema.string("\"HH:mm\", Beginn des Tagesfensters (Standard \"08:00\")"),
        "day_end": ToolSchema.string("\"HH:mm\", Ende des Tagesfensters (Standard \"20:00\")"),
      ], required: ["from", "to", "duration_minutes"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "find_free_time": { ctx, args in
      let from = try args.requireDateOnly("from")
      let to = try args.requireDateOnly("to")
      guard let wallFrom = StoreDates.wallClock(from), let wallTo = StoreDates.wallClock(to) else {
        throw ToolValidationError("\"from\" und \"to\" müssen gültige Datumsangaben sein")
      }
      guard wallTo > wallFrom else { throw ToolValidationError("\"to\" muss nach \"from\" liegen") }
      guard case .number(let n)? = args.raw["duration_minutes"], n.rounded() == n, n >= 5, n <= 720 else {
        throw ToolValidationError("\"duration_minutes\" muss eine ganze Zahl von 5 bis 720 sein")
      }
      let dayStart = try optionalTime(args, "day_start") ?? "08:00"
      let dayEnd = try optionalTime(args, "day_end") ?? "20:00"
      guard dayEnd > dayStart else { throw ToolValidationError("\"day_end\" muss nach \"day_start\" liegen") }

      // Einen Tag früher laden, damit ein Termin aus dem Vortag, der in den
      // ersten Tag hineinreicht, berücksichtigt wird.
      let listing = await ctx.calendar.listAllEvents(from: StoreDates.shiftDateOnly(from, -1), to: to)
      let buffer = try ctx.store.settings.get().bufferMinutes
      let slots = FreeTime.slots(events: listing.events, from: from, to: to, durationMinutes: Int(n),
                                 dayStart: dayStart, dayEnd: dayEnd, bufferMinutes: buffer,
                                 now: StoreDates.now(ctx.clock))
      return ToolJSON.ok([
        "slots": ToolJSON.encode(slots),
        "unreachable": ToolJSON.encode(listing.unreachable),
      ])
    },
  ]

  /// Optional "HH:mm" (00:00 bis 23:59).
  private static func optionalTime(_ args: ToolArgs, _ key: String) throws -> String? {
    guard let s = try args.optionalString(key) else { return nil }
    let valid = s.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
    guard valid, let h = Int(s.prefix(2)), let m = Int(s.suffix(2)), h <= 23, m <= 59 else {
      throw ToolValidationError("\"\(key)\" muss \"HH:mm\" sein")
    }
    return s
  }
}
