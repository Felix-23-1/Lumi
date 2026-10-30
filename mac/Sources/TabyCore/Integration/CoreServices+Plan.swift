import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  // MARK: Paket 2

  public func answerDayEnd(_ answer: DayEndAnswer) async {
    if answer == .moveAllToTomorrow {
      let ov = await overview()
      let ids = (ov.overdueTasks + ov.todayTasks).filter { !$0.done }.map(\.id)
      if !ids.isEmpty { _ = await moveTasksToTomorrow(ids) }
    }
    _ = await planner.answerDayEnd(answer)
    if answer != .later { runTriggers(.dayEnded) }
    autoStatusSoon()
    changed()
  }

  public func moveTasksToTomorrow(_ ids: [String]) async -> ToolResult<Empty> {
    await mutateEmpty("postpone_tasks", ["ids": .array(ids.map { .string($0) })])
  }

  public func answerDayStart(_ answer: DayStartAnswer) async {
    _ = await planner.answerDayStart(answer)
    if answer == .yes { runTriggers(.dayStarted) }
    emit(.stateChanged)
    guard answer == .yes else { return }
    let ov = await overview()
    let llm = limitReached ? nil : cheapLlmClient()
    let names = await todaysBirthdays().map(\.name)
    // Geburtstage nur an ein lokales Modell; bei Cloud hängen sie danach an (wie die Mail-Zeile).
    let local = llm is AppleIntelligenceClient
    let briefing = (try? await BriefingBuilder.build(ov, llm: llm, customPrompt: settings.briefingPrompt,
                                                     birthdays: names, birthdaysToModel: local))
      ?? Briefing(overview: ov, text: BriefingBuilder.fallbackText(ov, birthdays: names), generatedByModel: false)
    var shown = briefing
    if briefing.generatedByModel && !local && !names.isEmpty {
      shown.text += "\n" + names.map { "Geburtstag: \($0)." }.joined(separator: "\n")
    }
    // Mail nur als Anzahl + Absender, nach dem Modell angehängt (geht nicht an die Cloud).
    if settings.mailEnabled && settings.mailBriefing, let line = await mailBriefingLine() {
      shown.text += "\n" + line
    }
    emit(.briefingReady(shown))
    say(shown.text, briefing: true)
  }

  public func acknowledgeMissed(_ reminderIds: [String]) async {
    try? await planner.acknowledgeMissed(reminderIds.isEmpty ? nil : reminderIds)
    emit(.stateChanged)
  }

  // MARK: - Paket 10 (Tagesplan bearbeiten, Prioritätsliste)

  /// Packt den Tagesplan in genau dieser Reihenfolge neu (Nutzer hat umsortiert oder entfernt).
  public func reorderPlan(taskIds: [String]) async -> ToolResult<DayPlan> {
    let s = settings
    let w = AutoPlanner.window(s, date: LocalTime.formatDate(clock.now()))
    let tasks = (try? store.tasks.list()) ?? []
    let pinned = ((try? store.dayPlans.get(LocalTime.formatDate(clock.now())))?.blocks ?? []).filter(\.isPinned)
    let plan = AutoPlanner.reorder(taskIds, tasks: tasks, events: await todaysEvents() + breakBusyEvents(),
                                   now: LocalTime.format(clock.now()), dayStart: w.start, dayEnd: w.end,
                                   blockMinutes: s.planBlockMinutes, bufferMinutes: s.bufferMinutes,
                                   pinned: pinned)
    do {
      try store.dayPlans.save(plan)
    } catch {
      return .failure(code: "ERROR", error: "Der Plan konnte nicht gespeichert werden.")
    }
    emit(.stateChanged)
    return .ok(plan)
  }

  /// Ersetzt die Prioritätsliste; nur offene, bekannte Aufgaben, ohne Dubletten.
  public func setTaskPriority(taskIds: [String]) async -> ToolResult<Empty> {
    let open = Set(((try? store.tasks.list()) ?? []).filter { !$0.done }.map(\.id))
    var seen = Set<String>()
    let ids = taskIds.filter { open.contains($0) && seen.insert($0).inserted }
    do {
      try store.taskPriority.set(ids)
    } catch {
      return .failure(code: "ERROR", error: "Die Prioritätsliste konnte nicht gespeichert werden.")
    }
    emit(.stateChanged)
    return .ok(Empty())
  }
}
