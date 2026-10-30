import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  func appendMessages(_ messages: [ChatMessage]) {
    for m in messages { _ = try? store.messages.add(m) }
  }

  func overview() async -> Overview {
    (try? await buildOverview(store: store, clock: clock, calendar: calendarAccess)) ?? .empty
  }

  // MARK: - TabyServices

  public func state() async -> AppState {
    let ov = await overview()
    let birthdays = await todaysBirthdays()
    let vaultCount = currentVaultNoteCount()
    announceNewConflicts(ov)
    let (daily, showQuestion) = await planner.onAppStart()
    let s = settings  // einmal lesen: jedes `settings` fragt SQLite und den Schlüsselbund
    let notionCategories = NotionTaskOwnership.categories(store: store)  // einmal je Zustand, ohne Notion-Verknüpfungen leer
    // Reine Speicher-Lesezugriffe im Hintergrund (Database ist per Lock threadsicher); AppState wird danach auf dem Hauptthread gebaut.
    let today = LocalTime.formatDate(clock.now())
    let values = await Task.detached(priority: .userInitiated) { [store] in
      StateStoreValues.read(store, settings: s, today: today, weekMonday: WeeklyReviewBuilder.monday(of: today))
    }.value
    var state = AppState(
      overview: ov,
      settings: s,
      dayStartState: daily.state,
      tasks: values.tasks,
      notes: values.notes,
      habits: values.habits,
      jobs: values.jobs,
      calendarSources: values.calendarSources.map(publicSource),
      dayStartPrompt: showQuestion,
      messages: values.messages,
      usage: values.usage,
      pendingConfirmations: pending.map(\.confirmation),
      dayEndPrompt: await planner.dayEndOnAppStart(),
      focus: values.focus,
      focusMinutesToday: values.focusMinutesToday,
      memories: values.memories,
      mods: (try? mods.all()) ?? [],
      remindersError: s.appleRemindersSync ? remindersError : nil,
      remindersAccessDenied: s.appleRemindersSync && remindersAccessDenied,
      appleIntelligenceAvailable: appleIntelligenceAvailable,
      plan: values.plan,
      meeting: currentMeeting(),
      weeklyReviewPrompt: p4.weeklyPrompt,
      weeklyReview: p4.weeklyPrompt ? await buildWeeklyReview() : nil,
      weeklyGoals: values.weeklyGoals,
      mail: s.mailEnabled ? (mailCache ?? MailOverview()) : nil,
      network: networkState(),
      islandMessage: currentIslandMessage(),
      notionTasksSync: s.notionTasksEnabled ? notionTasksSyncState : nil,
      notionTasksConnected: !notionConnectedAccountIds(s.notionAccounts).isEmpty,
      taskPriority: values.taskPriority,
      notionLinkedTasks: s.notionTasksEnabled ? notionLinkedTasks() : [],
      notionSources: values.notionSources,
      notionSourceLinks: s.notionTasksEnabled ? notionSourceLinks() : [:],
      notionTaskGroups: s.notionTasksEnabled ? notionTaskGroups() : [:],
      notionTaskPages: s.notionTasksEnabled ? notionTaskPages() : [:],
      notionTaskMeta: s.notionTasksEnabled ? notionTaskMeta() : [:],
      messengerAccounts: messenger.accountList(),
      messengerConversations: messenger.conversationList(),
      messengerVerification: messenger.verification, islandMessages: currentIslandMessages(),
      update: availableUpdate.map { u in
        var withProgress = u
        withProgress.downloadPercent = downloadPercent
        return withProgress
      },
      taskFolders: values.taskFolders,
      timers: timerList(),
      nowPlaying: media.nowPlaying,
      undoLabel: currentUndoLabel(),
      vaultNoteCount: vaultCount,
      shareStates: shareStatesNow(s.networkShares),
      notionConnectedAccounts: notionConnectedAccountIds(s.notionAccounts),
      // Unabhängig vom Schalter: die Kategorie bleibt, auch wenn der Abgleich aus ist.
      notionTaskCategories: notionCategories,
      birthdaysToday: birthdays,
      inbox: await inboxItems(), undoLabels: currentUndoLabels()
    )
    state.saveError = saveError
    state.listening = listenSession?.info
    state.speaking = speaker.isSpeaking
    return state
  }

  public func subscribe(_ handler: @escaping @MainActor (AppEvent) -> Void) {
    handlers.append(handler)
  }
}

/// Speicher-Werte für `AppState`, aus der Datenbank gelesen (im Hintergrund, siehe `state()`).
/// Nur Lesezugriffe; Ergebnis entspricht den bisherigen `try? store.…`-Aufrufen.
struct StateStoreValues: Sendable {
  var tasks: [TabyTask] = []
  var notes: [Note] = []
  var habits: [Habit] = []
  var jobs: [Job] = []
  var calendarSources: [CalendarSourceConfig] = []
  var messages: [ChatMessage] = []
  var usage = UsageSummary()
  var focus: FocusSession?
  var focusMinutesToday = 0
  var memories: [Memory] = []
  var plan: DayPlan?
  var weeklyGoals: [WeeklyGoal] = []
  var taskFolders: [TaskFolder] = []
  var taskPriority: [String] = []
  var notionSources: [NotionSource] = []

  static func read(_ store: Store, settings s: TabySettings, today: String, weekMonday: String) -> StateStoreValues {
    var v = StateStoreValues()
    v.tasks = (try? store.tasks.list()) ?? []
    v.notes = (try? store.notes.list()) ?? []
    v.habits = (try? store.habits.list()) ?? []
    v.jobs = (try? store.jobs.list()) ?? []
    v.calendarSources = (try? store.calendarSources.list()) ?? []
    v.messages = (try? store.messages.list(limit: CoreServices.historyLimit)) ?? []
    v.usage = (try? store.usage.summary(dailyLimit: s.dailyCostLimitUsd, monthlyLimit: s.monthlyCostLimitUsd)) ?? UsageSummary()
    v.focus = try? store.focus.current()
    v.focusMinutesToday = (try? store.focus.minutesToday()) ?? 0
    v.memories = (try? store.memories.list()) ?? []
    v.plan = try? store.dayPlans.get(today)
    v.weeklyGoals = (try? store.weeklyGoals.list(week: weekMonday)) ?? []
    v.taskFolders = (try? store.taskFolders.list()) ?? []
    v.taskPriority = (try? store.taskPriority.list()) ?? []
    v.notionSources = (try? store.notionSources.list()) ?? []
    return v
  }
}
