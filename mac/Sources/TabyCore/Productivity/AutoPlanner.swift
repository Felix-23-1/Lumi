// Automatisch einplanen (Paket 4): offene Aufgaben in die freien Lücken des
// heutigen Tages legen. Reiner Code, kein Modell. Die Lücken liefert
// FreeTime.slots (mit Puffer um Termine mit Uhrzeit); `now` kommt als Parameter.
import Foundation

public enum AutoPlanner {
  /// Höchstens so viele Blöcke pro Tag.
  static let maxBlocks = 12
  /// Pause zwischen zwei Blöcken in Minuten.
  static let breakMinutes = 5
  /// Aufgaben mit Fälligkeit bis so viele Tage voraus gelten als Kandidaten.
  static let lookaheadDays = 3
  static let minEstimate = 5
  static let maxEstimate = 240
  /// Dauer je gewählter Aufgabe (PlanItem.minutes), 5 bis 480.
  static let maxPlanMinutes = 480

  /// Freie Lücke in Minuten seit der Epoche (Wanduhrzeit, UTC-gerechnet). `reason` begründet einen Block,
  /// der am Anfang der Lücke landet; `endReason` gilt für den Rest hinter einem Block in derselben Lücke.
  struct Gap: Equatable {
    var start: Int
    var end: Int
    var reason: String
    var endReason: String
  }

  // MARK: - Dauer

  /// Schätzt die Dauer aus dem Titel: "(45 min)", "45min", "1h", "1,5 h",
  /// "90 Minuten". Ohne Angabe gilt `d`. Ergebnis liegt zwischen 5 und 240.
  public static func estimateMinutes(_ title: String, default d: Int) -> Int {
    let hours = firstNumber(title, pattern: #"(\d+(?:[.,]\d+)?)\s*(?:stunden|stunde|std\.?|h)(?!\p{L})"#)
    let minutes = firstNumber(title, pattern: #"(\d+)\s*(?:minuten|minutes|minute|min\.?)(?!\p{L})"#)
    guard hours != nil || minutes != nil else { return clampEstimate(d) }
    let total = (hours ?? 0) * 60 + (minutes ?? 0)
    // Unsinnige Zahlen im Titel („99999999999999999999 h“) dürfen nicht überlaufen.
    guard total.isFinite else { return clampEstimate(240) }
    return clampEstimate(Int(min(total, 100_000).rounded()))
  }

  private static func firstNumber(_ text: String, pattern: String) -> Double? {
    guard let regex = RegexCache.compile(pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return Double(text[range].replacingOccurrences(of: ",", with: "."))
  }

  private static func clampEstimate(_ v: Int) -> Int {
    min(max(v, minEstimate), maxEstimate)
  }

  /// Planungsfenster für `date`: die Arbeitszeit dieses Tages. Ein freier Tag (ausdrücklich geplant)
  /// nutzt 08:00 bis Feierabend wie bisher.
  public static func window(_ settings: TabySettings, date: String) -> (start: String, end: String) {
    WorkWeek.hours(settings, date: date) ?? (start: "08:00", end: settings.dayEndTime)
  }

  // MARK: - Tagesplan

  /// Plant den heutigen Tag (Datum von `now`). Reihenfolge: überfällig (nach
  /// Fälligkeit), heute fällig, ohne Fälligkeit (nach Anlage), in den nächsten
  /// drei Tagen fällig. Später fällige Aufgaben sind keine Kandidaten.
  /// Festgesetzte Blöcke (`pinned`) offener Aufgaben bleiben stehen; der Rest wird um sie herum gepackt.
  public static func plan(tasks: [TabyTask], events: [CalendarEvent], now: String, dayStart: String = "08:00", dayEnd: String = "20:00",
                          blockMinutes: Int, bufferMinutes: Int, priority: [String] = [],
                          pinned: [PlannedBlock] = []) -> DayPlan {
    let today = LocalTime.datePart(now)
    let fixed = fixedBlocks(stored: pinned, tasks: tasks, now: now, blockMinutes: blockMinutes)
    let fixedIds = Set(fixed.map(\.taskId))
    let gaps = freeGaps(events: events + busy(fixed), now: now, dayStart: dayStart, dayEnd: dayEnd, bufferMinutes: bufferMinutes)
    let candidates = ordered(tasks, today: today, priority: priority).filter { !fixedIds.contains($0.id) }
    let result = place(candidates, gaps: gaps, blockMinutes: blockMinutes, limit: maxBlocks - fixed.count)
    return DayPlan(date: today, blocks: sortedBlocks(fixed + result.blocks), unplanned: result.unplanned)
  }

  /// Packt den Tag neu, aber in genau der Reihenfolge aus `order` (Nutzer hat den Vorschlag von Hand
  /// umsortiert oder eine Aufgabe herausgenommen). IDs, die nicht offen/unbekannt sind, fallen weg.
  /// Festgesetzte Blöcke (`pinned`) bleiben auf ihrer Uhrzeit; nur der Rest wird neu gepackt.
  public static func reorder(_ order: [String], tasks: [TabyTask], events: [CalendarEvent], now: String,
                             dayStart: String = "08:00", dayEnd: String = "20:00", blockMinutes: Int, bufferMinutes: Int,
                             pinned: [PlannedBlock] = []) -> DayPlan {
    let today = LocalTime.datePart(now)
    // Nur festgesetzte Blöcke, deren Aufgabe noch in `order` steht (✕ nimmt auch sie heraus).
    let fixed = fixedBlocks(stored: pinned, tasks: tasks, now: now, blockMinutes: blockMinutes, onlyIds: Set(order))
    let fixedIds = Set(fixed.map(\.taskId))
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let candidates = order.compactMap { byId[$0] }.filter { !$0.done && !fixedIds.contains($0.id) }
    let gaps = freeGaps(events: events + busy(fixed), now: now, dayStart: dayStart, dayEnd: dayEnd, bufferMinutes: bufferMinutes)
    let result = place(candidates, gaps: gaps, blockMinutes: blockMinutes, limit: maxBlocks - fixed.count)
    return DayPlan(date: today, blocks: sortedBlocks(fixed + result.blocks), unplanned: result.unplanned)
  }

  /// Plant nur die gewählten Aufgaben für heute. Mit gültiger Uhrzeit ("HH:mm") festgesetzt
  /// (`pinned`, bleibt genau dort, auch über einem Termin; die Oberfläche warnt). Ohne oder mit
  /// ungültiger Uhrzeit in die freien Lücken um Termine und festgesetzte Blöcke, in gegebener
  /// Reihenfolge. Dauer 5…480 Minuten. Was nicht passt, landet in `unplanned`.
  public static func planChosen(items: [PlanItem], tasks: [TabyTask], events: [CalendarEvent], now: String,
                                dayStart: String = "08:00", dayEnd: String = "20:00", bufferMinutes: Int) -> DayPlan {
    let today = LocalTime.datePart(now)
    let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    let nowMinutes = toMinutes(now) ?? Int.min
    var seen = Set<String>()
    var fixed: [PlannedBlock] = []
    var automatic: [(task: TabyTask, minutes: Int)] = []
    for item in items {
      guard let task = byId[item.taskId], !task.done, seen.insert(item.taskId).inserted else { continue }
      let minutes = min(max(item.minutes, minEstimate), maxPlanMinutes)
      // Gewählte Uhrzeit geht vor; sonst die Uhrzeit der Fälligkeit heute, falls noch nicht vorbei.
      if let hhmm = item.start, isClock(hhmm), let start = toMinutes("\(today)T\(hhmm)") {
        fixed.append(fixedBlock(task, start: start, minutes: minutes, reason: userPinReason))
      } else if let start = dueStart(task.due, today: today), start >= nowMinutes {
        fixed.append(fixedBlock(task, start: start, minutes: minutes, reason: clockReason(start)))
      } else {
        automatic.append((task: task, minutes: minutes))
      }
    }
    let gaps = freeGaps(events: events + busy(fixed), now: now, dayStart: dayStart, dayEnd: dayEnd, bufferMinutes: bufferMinutes)
    let result = placeSized(automatic, gaps: gaps, limit: maxBlocks - fixed.count)
    return DayPlan(date: today, blocks: sortedBlocks(fixed + result.blocks), unplanned: result.unplanned)
  }

  /// Hält den Plan aktuell. Begonnene Blöcke (Start <= `now`) bleiben. Erledigte
  /// oder gelöschte Aufgaben fallen weg. Kollidiert ein künftiger Block mit einem
  /// Termin mit Uhrzeit (samt Puffer) oder gilt der Plan nicht für heute, werden
  /// die Aufgaben der künftigen Blöcke neu in die Lücken gelegt (gleiche
  /// Reihenfolge). `moved` nennt die Blöcke auf neuer Position.
  public static func replan(_ plan: DayPlan, tasks: [TabyTask], events: [CalendarEvent], now: String,
                            dayStart: String = "08:00", dayEnd: String, blockMinutes: Int, bufferMinutes: Int)
    -> (plan: DayPlan, moved: [PlannedBlock]) {
    let today = LocalTime.datePart(now)
    let taskById = tasks.reduce(into: [String: TabyTask]()) { $0[$1.id] = $1 }
    func isOpen(_ taskId: String) -> Bool { taskById[taskId].map { !$0.done } ?? false }

    let sameDay = plan.date == today
    let nowMinutes = toMinutes(now) ?? Int.min
    // Festgesetzte Blöcke offener Aufgaben bleiben; gilt der Plan für einen anderen Tag, behalten sie nur
    // ihre Uhrzeit. Dazu kommen Aufgaben mit Uhrzeit heute (Fälligkeit). Ihre Zeit steht fest.
    let storedPins = plan.blocks.filter(\.isPinned).map { sameDay ? $0 : redated($0, to: today) }
    let pinned = fixedBlocks(stored: storedPins, tasks: tasks, now: now, blockMinutes: blockMinutes)
    let fixedIds = Set(pinned.map(\.taskId))
    let open = plan.blocks.filter { !$0.isPinned && isOpen($0.taskId) && !fixedIds.contains($0.taskId) }
      .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    let started = sameDay ? open.filter { (toMinutes($0.start) ?? Int.max) <= nowMinutes } : []
    let future = open.filter { block in !started.contains { $0.id == block.id } }
    let openUnplanned = plan.unplanned.filter { isOpen($0) && !fixedIds.contains($0) }

    let conflict = sameDay && future.contains {
      conflicts($0, events: events, started: started + pinned, buffer: bufferMinutes)
    }
    if !conflict && sameDay {
      return (DayPlan(date: today, blocks: sortedBlocks(started + pinned + future), unplanned: openUnplanned), [])
    }

    let keptBusy = busy(started + pinned)
    let gaps = freeGaps(events: events + keptBusy, now: now, dayStart: dayStart, dayEnd: dayEnd, bufferMinutes: bufferMinutes)
    let candidates = future.compactMap { block -> (task: TabyTask, minutes: Int)? in
      guard let task = taskById[block.taskId] else { return nil }
      return (task: task, minutes: blockLength(block) ?? estimateMinutes(task.title, default: blockMinutes))
    }
    let result = placeSized(candidates, gaps: gaps, limit: maxBlocks - started.count - pinned.count)
    // Ein Block auf neuer Uhrzeit nennt den Termin, der ihn verdrängt hat.
    var moved: [PlannedBlock] = []
    let placed = result.blocks.map { block -> PlannedBlock in
      guard let old = future.first(where: { $0.taskId == block.taskId }), old.start != block.start else { return block }
      var b = block
      b.reason = conflictingEvent(old, events: events, buffer: bufferMinutes).map { "Verschoben wegen „\($0.title)“" }
        ?? "Neu verteilt"
      moved.append(b)
      return b
    }
    let unplanned = uniqued((sameDay ? openUnplanned : []) + result.unplanned)
    return (DayPlan(date: today, blocks: sortedBlocks(started + pinned + placed), unplanned: unplanned), sortedBlocks(moved))
  }

  // MARK: - Hilfsfunktionen

  /// Festgesetzte Blöcke für heute: gespeicherte (`pinned`, noch offen) und Aufgaben mit Uhrzeit heute
  /// in der Fälligkeit, die noch nicht vorbei ist. Gespeicherte gehen vor, eine Aufgabe hat höchstens einen.
  /// `onlyIds` begrenzt auf die Aufgaben einer Reihenfolge.
  static func fixedBlocks(stored: [PlannedBlock], tasks: [TabyTask], now: String, blockMinutes: Int,
                          onlyIds: Set<String>? = nil) -> [PlannedBlock] {
    let kept = keptPinned(stored, tasks: tasks).filter { onlyIds?.contains($0.taskId) ?? true }.map { block -> PlannedBlock in
      var b = block
      if b.reason?.hasPrefix("Feste Uhrzeit") != true { b.reason = userPinReason }
      return b
    }
    let keptIds = Set(kept.map(\.taskId))
    let today = LocalTime.datePart(now)
    let nowMinutes = toMinutes(now) ?? Int.min
    let due = tasks.compactMap { task -> PlannedBlock? in
      guard !task.done, !keptIds.contains(task.id), onlyIds?.contains(task.id) ?? true,
            let start = dueStart(task.due, today: today), start >= nowMinutes else { return nil }
      return fixedBlock(task, start: start, minutes: blockMinutes, reason: clockReason(start))
    }
    return kept + due
  }

  /// Uhrzeit heute aus der Fälligkeit ("YYYY-MM-DDTHH:mm"), nil ohne Uhrzeit oder an einem anderen Tag.
  private static func dueStart(_ due: String?, today: String) -> Int? {
    guard let due, due.count >= 16, LocalTime.datePart(due) == today else { return nil }
    let hhmm = String(due.dropFirst(11).prefix(5))
    guard isClock(hhmm) else { return nil }
    return toMinutes("\(today)T\(hhmm)")
  }

  /// Festgesetzter Block ab `start` (Minuten seit 1970) mit `minutes` Dauer. Nie über Mitternacht: Ende höchstens 23:59.
  private static func fixedBlock(_ task: TabyTask, start: Int, minutes: Int, reason: String) -> PlannedBlock {
    let end = min(start + minutes, start - start % 1440 + 1439)
    return PlannedBlock(id: "\(task.id)@\(toStamp(start))", taskId: task.id, title: task.title,
                        start: toStamp(start), end: toStamp(end), pinned: true, reason: reason)
  }

  static let userPinReason = "Von dir festgelegt"
  static func clockReason(_ start: Int) -> String { "Feste Uhrzeit \(String(toStamp(start).suffix(5)))" }

  /// Offene Aufgaben in Planungsreihenfolge (siehe `plan`).
  static func ordered(_ tasks: [TabyTask], today: String, priority: [String] = []) -> [TabyTask] {
    let limit = StoreDates.shiftDateOnly(today, lookaheadDays)
    var overdue: [TabyTask] = []
    var dueToday: [TabyTask] = []
    var undated: [TabyTask] = []
    var upcoming: [TabyTask] = []
    for task in tasks where !task.done {
      guard let due = task.due, !due.isEmpty else { undated.append(task); continue }
      let day = LocalTime.datePart(due)
      if day < today {
        overdue.append(task)
      } else if day == today {
        dueToday.append(task)
      } else if day <= limit {
        upcoming.append(task)
      }
    }
    let rest = sortByDue(overdue) + sortByDue(dueToday) + undated.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      + sortByDue(upcoming)
    guard !priority.isEmpty else { return rest }
    // Priorisierte Aufgaben zuerst, in der gemerkten Reihenfolge; der Rest wie gehabt dahinter.
    let byId = Dictionary(uniqueKeysWithValues: rest.map { ($0.id, $0) })
    let prioritized = priority.compactMap { byId[$0] }
    let prioritizedIds = Set(prioritized.map(\.id))
    return prioritized + rest.filter { !prioritizedIds.contains($0.id) }
  }

  private static func sortByDue(_ tasks: [TabyTask]) -> [TabyTask] {
    tasks.sorted { ($0.due ?? "", $0.createdAt, $0.id) < ($1.due ?? "", $1.createdAt, $1.id) }
  }

  /// Freie Lücken des heutigen Tages (ab `now`, bis `dayEnd`), mindestens 5 Minuten.
  private static func freeGaps(events: [CalendarEvent], now: String, dayStart: String, dayEnd: String, bufferMinutes: Int) -> [Gap] {
    let today = LocalTime.datePart(now)
    let slots = FreeTime.slots(events: events, from: today, to: StoreDates.shiftDateOnly(today, 1),
                               durationMinutes: minEstimate, dayStart: dayStart, dayEnd: dayEnd,
                               bufferMinutes: bufferMinutes, now: now)
    let buffer = max(0, bufferMinutes)
    let timed = events.filter { !$0.allDay && !LocalTime.isDateOnly($0.start) }
    let dayEndMinutes = toMinutes("\(today)T\(dayEnd)")
    return slots.compactMap { slot in
      guard let start = toMinutes(slot.start), let end = toMinutes(slot.end), end > start else { return nil }
      // Lücke endet vor einem Termin mit Uhrzeit (samt Puffer), beginnt nach einer Pause aus dem Gedächtnis.
      let before = timed.first { ev in toMinutes(ev.start).map { $0 - buffer == end } ?? false }
      let after = timed.first { ev in
        guard ev.sourceId == "memory", let s = toMinutes(ev.start) else { return false }
        return max(s, ev.end.flatMap { toMinutes($0) } ?? (s + 60)) + buffer == start
      }
      let endReason = before.map { "Freie Lücke vor „\($0.title)“" }
        ?? (end == dayEndMinutes ? "Freie Lücke bis Feierabend" : "Freie Lücke")
      let reason = after.map { "Nach der \($0.title)" } ?? endReason
      return Gap(start: start, end: end, reason: reason, endReason: endReason)
    }
  }

  /// Legt die Aufgaben nacheinander in die erste Lücke, in die sie passen.
  /// Zwischen zwei Blöcken bleiben `breakMinutes` frei. Was nicht passt, oder
  /// über `limit` hinausgeht, landet in `unplanned`.
  private static func place(_ candidates: [TabyTask], gaps: [Gap], blockMinutes: Int, limit: Int)
    -> (blocks: [PlannedBlock], unplanned: [String]) {
    placeSized(candidates.map { (task: $0, minutes: estimateMinutes($0.title, default: blockMinutes)) },
               gaps: gaps, limit: limit)
  }

  /// Wie `place`, aber mit fester Dauer je Aufgabe.
  private static func placeSized(_ candidates: [(task: TabyTask, minutes: Int)], gaps initial: [Gap], limit: Int)
    -> (blocks: [PlannedBlock], unplanned: [String]) {
    var gaps = initial
    var blocks: [PlannedBlock] = []
    var unplanned: [String] = []
    for (task, duration) in candidates {
      guard blocks.count < limit, let fit = firstFit(gaps, duration: duration) else {
        unplanned.append(task.id)
        continue
      }
      let gap = gaps[fit.index]
      let end = fit.start + duration
      let rest = Gap(start: end + breakMinutes, end: gap.end, reason: gap.endReason, endReason: gap.endReason)
      gaps.remove(at: fit.index)
      if rest.start < rest.end { gaps.insert(rest, at: fit.index) }
      blocks.append(PlannedBlock(id: "\(task.id)@\(toStamp(fit.start))", taskId: task.id, title: task.title,
                                 start: toStamp(fit.start), end: toStamp(end), reason: gap.reason))
    }
    return (blocks, unplanned)
  }

  private static func firstFit(_ gaps: [Gap], duration: Int) -> (index: Int, start: Int)? {
    for (index, gap) in gaps.enumerated() {
      let start = roundUpToFive(gap.start)
      if start + duration <= gap.end { return (index, start) }
    }
    return nil
  }

  private static func roundUpToFive(_ minutes: Int) -> Int {
    ((minutes + 4) / 5) * 5
  }

  /// Festgesetzte Blöcke, deren Aufgabe noch offen ist.
  private static func keptPinned(_ blocks: [PlannedBlock], tasks: [TabyTask]) -> [PlannedBlock] {
    let open = Set(tasks.filter { !$0.done }.map(\.id))
    return blocks.filter { $0.isPinned && open.contains($0.taskId) }
  }

  /// Festgesetzte Blöcke als belegte Termine (Lücken werden um sie herum berechnet).
  private static func busy(_ blocks: [PlannedBlock]) -> [CalendarEvent] {
    blocks.map { CalendarEvent(id: $0.id, sourceId: "plan", title: $0.title, start: $0.start, end: $0.end) }
  }

  /// "HH:mm" mit zweistelliger Stunde und Minute, gültige Uhrzeit.
  static func isClock(_ s: String) -> Bool {
    s.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
  }

  /// Länge eines Blocks in Minuten, nil wenn Start/Ende fehlen oder ungültig sind.
  private static func blockLength(_ block: PlannedBlock) -> Int? {
    guard let s = toMinutes(block.start), let e = toMinutes(block.end), e > s else { return nil }
    return e - s
  }

  /// Gleicher Block, aber auf `day` verschoben (Uhrzeit und Dauer bleiben).
  private static func redated(_ block: PlannedBlock, to day: String) -> PlannedBlock {
    let newStart = day + "T" + String(block.start.dropFirst(11))
    guard let s = toMinutes(newStart), let length = blockLength(block) else { return block }
    return PlannedBlock(id: "\(block.taskId)@\(toStamp(s))", taskId: block.taskId, title: block.title,
                        start: toStamp(s), end: toStamp(s + length), pinned: true, reason: block.reason)
  }

  /// Kollidiert ein Block mit einem Termin mit Uhrzeit (samt Puffer) oder mit
  /// einem bereits begonnenen Block?
  private static func conflicts(_ block: PlannedBlock, events: [CalendarEvent], started: [PlannedBlock],
                                buffer: Int) -> Bool {
    guard let s = toMinutes(block.start), let e = toMinutes(block.end) else { return true }
    if conflictingEvent(block, events: events, buffer: buffer) != nil { return true }
    for other in started {
      guard let os = toMinutes(other.start), let oe = toMinutes(other.end) else { continue }
      if s < oe && e > os { return true }
    }
    return false
  }

  /// Der erste Termin mit Uhrzeit, der den Block samt Puffer überlappt.
  private static func conflictingEvent(_ block: PlannedBlock, events: [CalendarEvent], buffer: Int) -> CalendarEvent? {
    guard let s = toMinutes(block.start), let e = toMinutes(block.end) else { return nil }
    return events.first { ev in
      guard !ev.allDay, !LocalTime.isDateOnly(ev.start), let es = toMinutes(ev.start) else { return false }
      let ee = max(es, ev.end.flatMap { toMinutes($0) } ?? (es + 60))
      return s < ee + buffer && e > es - buffer
    }
  }

  private static func sortedBlocks(_ blocks: [PlannedBlock]) -> [PlannedBlock] {
    blocks.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
  }

  private static func uniqued(_ ids: [String]) -> [String] {
    var out: [String] = []
    for id in ids where !out.contains(id) { out.append(id) }
    return out
  }

  /// "YYYY-MM-DDTHH:mm" → Minuten seit 1970 (Wanduhrzeit).
  static func toMinutes(_ s: String) -> Int? {
    guard let d = StoreDates.wallClock(s) else { return nil }
    return Int((d.timeIntervalSince1970 / 60).rounded(.down))
  }

  /// Minuten seit 1970 → "YYYY-MM-DDTHH:mm".
  static func toStamp(_ minutes: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let d = Date(timeIntervalSince1970: TimeInterval(minutes) * 60)
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }
}
