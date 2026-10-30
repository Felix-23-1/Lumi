// Paket 13 im Integrator: Aufgaben selbst für heute einplanen. Festgesetzte
// Uhrzeiten bleiben stehen, der Rest wird in die freien Lücken gepackt (reiner Code).
import Foundation

extension CoreServices {
  /// Plant nur die gewählten Aufgaben für heute und speichert den Plan. Leere Liste löscht den Plan.
  public func planTasks(_ items: [PlanItem]) async -> ToolResult<DayPlan> {
    let today = LocalTime.formatDate(clock.now())
    guard !items.isEmpty else {
      await clearPlan()
      return .ok(DayPlan(date: today))
    }
    let s = settings
    let w = AutoPlanner.window(s, date: today)
    let tasks = (try? store.tasks.list()) ?? []
    let plan = AutoPlanner.planChosen(items: items, tasks: tasks, events: await todaysEvents() + breakBusyEvents(),
                                      now: LocalTime.format(clock.now()), dayStart: w.start, dayEnd: w.end,
                                      bufferMinutes: s.bufferMinutes)
    do {
      try store.dayPlans.save(plan)
    } catch {
      return .failure(code: "ERROR", error: "Der Plan konnte nicht gespeichert werden.")
    }
    emit(.stateChanged)
    if plan.blocks.isEmpty {
      return .failure(code: "EMPTY", error: plan.unplanned.isEmpty
        ? "Keine der gewählten Aufgaben ist noch offen."
        : "Heute ist keine freie Zeit mehr für diese Aufgaben.")
    }
    return .ok(plan)
  }
}
