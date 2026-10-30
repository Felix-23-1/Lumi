// get_overview: deterministisch im Code zusammengestellt (BAUPLAN Abschnitt
// 7/9), Port von src/main/tools/overview.ts. Wird auch in jeden Systemprompt
// eingebettet und vom Tagesstart-Briefing weiterverwendet.
import Foundation

/// Termine/Aufgaben bis einschließlich heute + 7 Tage gelten als "kommend".
let overviewUpcomingDays = 8

/// Stand für Überblick, Systemprompt und Briefing. Zeitvergleiche in lokaler,
/// zonenloser Zeit aus der injizierten Uhr.
public func buildOverview(store: Store, clock: Clock, calendar: ToolCalendarAccess) async throws -> Overview {
  let today = StoreDates.today(clock)
  let horizon = StoreDates.shiftDateOnly(today, overviewUpcomingDays)

  // Kategorie wie in der Oberfläche: die wirksame (Notion-Zugang, eigene, Ordner), nicht die gespeicherte.
  let defs = try store.settings.get().taskCategories
  let folders = try store.taskFolders.list()
  let notionCategories = NotionTaskOwnership.categories(store: store)
  // Einheitliche Reihenfolge überall (Heute, Island, Briefing): Fälligkeit (mit Uhrzeit) aufsteigend, ohne Datum zuletzt, dann Titel.
  let openTasks = try store.tasks.list().filter { !$0.done }.sorted { a, b in
    let x = a.due ?? "", y = b.due ?? ""
    if x != y { return x.isEmpty ? false : (y.isEmpty ? true : x < y) }
    return a.title.localizedStandardCompare(b.title) == .orderedAscending
  }.map { task in
    var shown = task
    shown.category = TaskCategoryRules.effective(task, folders: folders, defs: defs,
                                                 notionCategories: notionCategories).map { TaskCategory(rawValue: $0) }
    return shown
  }
  func dueDay(_ t: TabyTask) -> String? { t.due.map(LocalTime.datePart) }
  let overdueTasks = openTasks.filter { dueDay($0).map { $0 < today } ?? false }
  let todayTasks = openTasks.filter { dueDay($0) == today }
  let upcomingTasks = openTasks.filter { dueDay($0).map { $0 > today } ?? false }

  let habitsToday = try store.habits.list().filter { !$0.checkedToday }

  let listing = await calendar.listAllEvents(from: today, to: horizon)
  let events = listing.events
  let eventsToday = events.filter { LocalTime.datePart($0.start) == today }
  let eventsUpcoming = events.filter { LocalTime.datePart($0.start) > today }
  let conflicts = pairwiseConflicts(events)

  var taskTitles: [String: String] = [:]
  for t in try store.tasks.list() { taskTitles[t.id] = t.title }
  var eventTitles: [String: String] = [:]
  for e in events { eventTitles[e.id] = e.title }
  var jobNames: [String: String] = [:]
  for j in try store.jobs.list() { jobNames[j.id] = j.name }

  func withTitle(_ r: Reminder) -> ReminderWithTitle {
    let title: String?
    switch r.source {
    case .task: title = taskTitles[r.sourceRef]
    case .event: title = eventTitles[r.sourceRef]
    case .job: title = jobNames[r.sourceRef]
    }
    return ReminderWithTitle(reminder: r, title: title ?? r.sourceRef)
  }

  let remindersToday = try store.reminders.listOpen().filter { LocalTime.datePart($0.dueAt) == today }.map(withTitle)
  let missed = try store.reminders.listMissed(now: StoreDates.now(clock)).map(withTitle)

  return Overview(overdueTasks: overdueTasks, todayTasks: todayTasks, upcomingTasks: upcomingTasks,
                  habitsToday: habitsToday, eventsToday: eventsToday, eventsUpcoming: eventsUpcoming,
                  conflicts: conflicts, remindersToday: remindersToday, missed: missed,
                  unreachableCalendarSources: listing.unreachable)
}

enum OverviewTools {
  static let defs: [ToolDef] = [
    ToolDef(
      name: "get_overview",
      description:
        "Liefert den aktuellen Stand: überfällige/heutige/kommende Aufgaben, Habits ohne heutigen Haken, Termine heute/kommend über alle Kalendermodule, Konflikte darunter, heutige Erinnerungen und Verpasstes.",
      parameters: ToolSchema.object()),
  ]

  static let handlers: [String: ToolHandler] = [
    "get_overview": { ctx, _ in
      let overview = try await buildOverview(store: ctx.store, clock: ctx.clock, calendar: ctx.calendar)
      let categories = TaskCategoryRules.summary(try ctx.store.settings.get().taskCategories)
      return ToolJSON.ok(["overview": ToolJSON.encode(overview), "kategorien": .string(categories)])
    },
  ]
}
