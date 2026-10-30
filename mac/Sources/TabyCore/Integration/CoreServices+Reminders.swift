import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  /// Nur bei sichtbaren Änderungen neu laden – ein Neuladen fragt alle
  /// (auch entfernten) Kalender ab.
  func handleTick(_ report: PlannerTickReport) {
    if report.showDayStart { emit(.dayStartPrompt) }
    if report.showDayEnd {
      emit(.dayEndPrompt)
      Task { await self.speakEvening() }
    }
    let missedIds = Set(report.missed.map(\.id))
    let missedChanged = missedIds != lastMissedIds
    lastMissedIds = missedIds
    if !report.fired.isEmpty || !report.jobRuns.isEmpty || missedChanged || report.showDayStart || report.showDayEnd {
      emit(.stateChanged)
    }
  }

  func changed() {
    searchCalendarMemo = nil
    Task { await planner.invalidateReminders() }
    emit(.stateChanged)
    scheduleRemindersSync()
  }

  /// Nach Änderungen kurz warten (mehrere Klicks bündeln), dann abgleichen.
  func scheduleRemindersSync() {
    guard settings.appleRemindersSync else { return }
    remindersDebounce?.cancel()
    remindersDebounce = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled, let self else { return }
      _ = await self.runRemindersSync()
    }
  }

  @discardableResult
  /// Rückgängig für Änderungen aus dem Abgleich: neue Fälle aus `removedFromApple` (jeder Abgleich
  /// meldet die offenen Fälle erneut) und Lumi-Änderungen, die Apple überschrieben hat.
  func recordReminderUndo(_ report: SyncReport, before: [String: TabyTask]) {
    let removed = Set(report.removedFromApple)
    for id in report.removedFromApple where !removedFromAppleSeen.contains(id) {
      pushUndo(.unlinkedFromApple(taskId: id), "Aus Erinnerungen entfernt – rückgängig?")
    }
    removedFromAppleSeen = removed
    for id in report.overwrittenLumiEdits {
      guard let old = before[id] else { continue }
      pushUndo(.updatedTask(old), "Von Erinnerungen überschrieben – rückgängig?")
    }
  }

  func runRemindersSync() async -> ToolResult<Empty> {
    guard !remindersSyncing else { return .ok(Empty()) }
    remindersSyncing = true
    defer { remindersSyncing = false }
    let s = settings
    let engine = ReminderSyncEngine(backend: remindersBackend, taskSide: StoreTaskSide(store))
    // Notion-Aufgaben gehören nicht nach Apple; vor dem Abgleich merken, was Lumi vorher hatte.
    let notionTaskIds = Set(((try? store.notionTaskLinks.all()) ?? []).map(\.taskId))
    let before = Dictionary(((try? store.tasks.list()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    do {
      let report = try await engine.sync(listId: s.appleRemindersListId.isEmpty ? nil : s.appleRemindersListId,
                                         now: LocalTime.format(clock.now()), excludedTaskIds: notionTaskIds)
      recordReminderUndo(report, before: before)
      if report.createdTask + report.pulled + report.deletedTask > 0 {
        Task { await planner.invalidateReminders() }
        emit(.stateChanged)
      }
      let previous = remindersError
      remindersAccessDenied = false
      if let first = report.errors.first {
        remindersError = first.hasPrefix("Abgleich mit Erinnerungen pausiert") ? first : "Abgleich teilweise fehlgeschlagen: \(first)"
        if previous != remindersError { emit(.stateChanged) }
        return .failure(code: "PARTIAL", error: remindersError!)
      }
      remindersError = nil
      if previous != nil { emit(.stateChanged) }
      return .ok(Empty())
    } catch {
      let denied = (error as? RemindersError) == .accessDenied
      let text = denied
        ? "Kein Zugriff auf Erinnerungen. Bitte in den Systemeinstellungen unter Datenschutz → Erinnerungen Lumi erlauben."
        : ((error as? LocalizedError)?.errorDescription ?? "Abgleich mit Apple Erinnerungen fehlgeschlagen.")
      let changedNow = text != remindersError || denied != remindersAccessDenied
      remindersError = text
      remindersAccessDenied = denied
      if changedNow { emit(.stateChanged) }
      return .failure(code: denied ? "ACCESS" : "REMINDERS", error: text)
    }
  }

  public func appleReminderLists() async -> ToolResult<[ReminderListInfo]> {
    guard await remindersBackend.requestAccess() else {
      return .failure(code: "ACCESS", error: "Kein Zugriff auf Erinnerungen. Bitte in den Systemeinstellungen freigeben.")
    }
    do { return .ok(try await remindersBackend.lists()) } catch {
      return .failure(code: "REMINDERS", error: "Listen aus Apple Erinnerungen konnten nicht geladen werden.")
    }
  }

  public func syncAppleReminders() async -> ToolResult<Empty> {
    await runRemindersSync()
  }
}
