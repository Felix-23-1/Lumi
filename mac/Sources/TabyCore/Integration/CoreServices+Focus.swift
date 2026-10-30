import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  public func startFocus(taskId: String?, minutes: Int?) async -> ToolResult<FocusSession> {
    let s = settings
    let task = taskId.flatMap { (try? store.tasks.get($0)) ?? nil }
    let title = task?.title ?? "Fokus"
    do {
      let f = try store.focus.start(taskId: taskId, title: title, phase: .work,
                                    minutes: minutes ?? task?.minutes ?? s.focusMinutes)
      scheduleFocusEnd(f)
      p4.focus.begin(shortcutOn: s.focusShortcutOn, hideApps: s.focusHideApps)
      autoStatusSoon()
      runTriggers(.focusStarted)
      if taskId != nil { await reflowDay(runningTaskId: taskId, blockEnd: LocalTime.parse(f.endsAt)) }
      emit(.stateChanged)
      return .ok(f)
    } catch {
      return .failure(code: "ERROR", error: "Fokus konnte nicht gestartet werden.")
    }
  }

  /// Schiebt spätere Aufgaben des Tages hinter den laufenden Block (Fälligkeiten werden wirklich geändert).
  func reflowDay(runningTaskId: String?, blockEnd: Date?) async {
    guard let blockEnd, let tasks = try? store.tasks.list() else { return }
    let day = LocalTime.formatDate(blockEnd)
    let events = await listEvents(from: day, to: day)
    let moves = TaskReflow.moves(tasks: tasks, excluding: runningTaskId, blockEnd: blockEnd,
                                 defaultMinutes: settings.focusMinutes, busy: TaskReflow.busy(events))
    for m in moves { _ = await updateTask(m.id, TaskPatch(due: m.due)) }
  }

  public func startBreak(minutes: Int) async -> ToolResult<FocusSession> {
    do {
      let f = try store.focus.start(taskId: nil, title: "Pause", phase: .rest, minutes: minutes)
      scheduleFocusEnd(f)
      if p4.focus.active { p4.focus.end(shortcutOff: settings.focusShortcutOff) }
      await reflowDay(runningTaskId: nil, blockEnd: LocalTime.parse(f.endsAt))
      autoStatusSoon()
      emit(.stateChanged)
      return .ok(f)
    } catch {
      return .failure(code: "ERROR", error: "Pause konnte nicht gestartet werden.")
    }
  }

  public func pauseFocus() async {
    guard let f = (try? store.focus.current()) ?? nil, f.pausedAt == nil else { return }
    focusTimer?.cancel()
    try? store.focus.pause(f.id)
    emit(.stateChanged)
  }

  public func resumeFocus() async {
    guard let f = (try? store.focus.current()) ?? nil, f.pausedAt != nil,
          let resumed = (try? store.focus.resume(f.id)) ?? nil else { return }
    scheduleFocusEnd(resumed)
    if resumed.phase == .work {
      await reflowDay(runningTaskId: resumed.taskId, blockEnd: LocalTime.parse(resumed.endsAt))
    }
    emit(.stateChanged)
  }

  public func stopFocus() async {
    focusTimer?.cancel()
    if let f = try? store.focus.current() { try? store.focus.finish(f.id, completed: false) }
    if p4.focus.active { p4.focus.end(shortcutOff: settings.focusShortcutOff) }
    autoStatusSoon()
    emit(.stateChanged)
  }

  /// Nach dem Neustart: laufende Sitzung weiter überwachen (oder abschließen, falls vorbei).
  func resumeFocusTimer() {
    guard let f = try? store.focus.current(), f.pausedAt == nil else { return }
    scheduleFocusEnd(f)
  }

  private func scheduleFocusEnd(_ f: FocusSession) {
    focusTimer?.cancel()
    guard let end = LocalTime.parse(f.endsAt) else { return }
    let wait = max(0, end.timeIntervalSince(clock.now()))
    focusTimer = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.finishFocus(f)
    }
  }

  /// Phase vorbei: abschließen, melden; nach der Arbeitsphase startet die Pause.
  func finishFocus(_ f: FocusSession) {
    guard (try? store.focus.current())??.id == f.id else { return }
    try? store.focus.finish(f.id, completed: true)
    // Fokus mit offener Aufgabe: erst fragen, ob sie fertig ist; die Pause folgt nicht von selbst.
    if f.phase == .work, let id = f.taskId, let task = (try? store.tasks.get(id)) ?? nil, !task.done {
      options.systemNotifier.send(TabyNotification(
        title: "Zeit um: \(task.title)", body: "Bist du fertig oder brauchst du noch Zeit?", taskId: id, overrun: true))
      emit(.flash(TabyNotification(title: "Zeit um: \(task.title)", body: "Bist du fertig oder brauchst du noch Zeit?",
                                   taskId: id, overrun: true)))
      autoStatusSoon()
      emit(.focusFinished(f))
      runTriggers(.focusFinished)
      if p4.focus.active { p4.focus.end(shortcutOff: settings.focusShortcutOff) }
      emit(.stateChanged)
      return
    }
    let note = f.phase == .work
      ? TabyNotification(title: "Fokus geschafft!", body: "\(f.title) – \(settings.breakMinutes) Minuten Pause.")
      : TabyNotification(title: "Pause vorbei", body: "Bereit für die nächste Runde?")
    options.systemNotifier.send(note)
    autoStatusSoon()
    emit(.focusFinished(f))
    if f.phase == .work {
      runTriggers(.focusFinished)
      if p4.focus.active { p4.focus.end(shortcutOff: settings.focusShortcutOff) }
    }
    if f.phase == .work,
       let rest = try? store.focus.start(taskId: f.taskId, title: f.title, phase: .rest, minutes: settings.breakMinutes) {
      scheduleFocusEnd(rest)
    }
    emit(.stateChanged)
  }
}
