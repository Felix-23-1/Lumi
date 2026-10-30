// Planer (Port von src/main/planner/planner.ts, BAUPLAN 9). Reine, prüfbare Logik:
// `tick()` liest die Zeit ausschließlich aus der injizierten `Clock`. Den Takt
// (alle 30 s, beim Aufwachen) liefert `PlannerRunner` getrennt davon.
import Foundation

/// Was ein Tick getan hat (für Prüfungen und damit der Integrator `stateChanged` meldet).
public struct PlannerTickReport: Equatable, Sendable {
  /// Tick übersprungen, weil noch ein anderer läuft (z. B. langer Auftrag).
  public var skipped = false
  public var resynced = false
  public var fired: [Reminder] = []
  public var missed: [Reminder] = []
  public var jobRuns: [JobRun] = []
  /// Tagesstart-Frage jetzt zeigen (neuer Tag oder "Später" abgelaufen).
  public var showDayStart = false
  /// Tagesabschluss-Frage jetzt zeigen (ab der Abend-Uhrzeit, offene Aufgaben vorhanden).
  public var showDayEnd = false
  /// Abgefangene Fehler aus Speicher/Quellen (deutsch, ohne Geheimnisse).
  public var errors: [String] = []

  public init() {}

  /// true, wenn sich sichtbarer Zustand geändert haben kann.
  public var changed: Bool {
    !fired.isEmpty || !jobRuns.isEmpty || showDayStart || showDayEnd || resynced
  }
}

public actor Planner {
  public static let defaultReminderSyncInterval: TimeInterval = 5 * 60
  /// 2 × 30-s-Takt (wie TS): einfache Heuristik gegen Takt-Schwankungen.
  public static let defaultMissedGrace: TimeInterval = 60
  /// Nachholen nur, wenn die Fälligkeit weniger als 24 h zurückliegt.
  public static let staleAfter: TimeInterval = 24 * 60 * 60

  private let clock: Clock
  private let notifier: Notifier
  private let reminders: PlannerReminderStore
  private let jobRuns: PlannerJobRunStore
  private let tasksSource: PlannerTaskSource
  private let eventsSource: PlannerEventSource
  private let jobsSource: PlannerJobSource
  private let jobRunner: PlannerJobRunner
  private let eventLeadMinutes: () -> Int
  private let reminderSyncInterval: TimeInterval
  private let missedGrace: TimeInterval
  private let onDailyStateChange: ((DailyState) -> Void)?
  private let dayEndSettings: () -> (enabled: Bool, time: String)
  private let workSettings: () -> TabySettings
  private let onDayEndChange: ((DayEndRecord) -> Void)?

  private var lastReminderSync: Date?
  /// Erhöht bei jedem `invalidateReminders()`. Ein Tick, der während seines Abgleichs
  /// (Suspendierung) invalidiert wurde, darf `lastReminderSync` nicht wieder setzen.
  private var syncGeneration = 0
  /// Aufgaben-IDs, die beim letzten Abgleich offen waren (nil = noch nie abgeglichen).
  private var openTaskRefs: Set<String>?
  private var ticking = false
  private var taskTitles: [String: String] = [:]
  private var eventTitles: [String: String] = [:]
  private var jobNames: [String: String] = [:]

  public private(set) var dailyState: DailyState
  /// Tagesabschluss-Zustand des heutigen Tages.
  public private(set) var dayEndRecord: DayEndRecord
  /// Verpasste, noch nicht bestätigte Erinnerungen (Stand des letzten Ticks).
  public private(set) var missed: [Reminder] = []

  /// - eventLeadMinutes: Vorlauf für Termin-Erinnerungen, bei jedem Abgleich neu gelesen
  ///   (Integrator: `{ settings.reminderLeadMinutes }`; 0 = aus).
  /// - dailyState: gespeicherter Tagesstart-Zustand (nil = heute, `.none`).
  /// - onDailyStateChange: zum Speichern in `daily_state` bei jeder Änderung.
  public init(
    clock: Clock,
    notifier: Notifier,
    reminders: PlannerReminderStore,
    jobRuns: PlannerJobRunStore,
    tasksSource: @escaping PlannerTaskSource,
    eventsSource: @escaping PlannerEventSource,
    jobsSource: @escaping PlannerJobSource,
    jobRunner: @escaping PlannerJobRunner,
    eventLeadMinutes: @escaping () -> Int = { 10 },
    reminderSyncInterval: TimeInterval = Planner.defaultReminderSyncInterval,
    missedGrace: TimeInterval = Planner.defaultMissedGrace,
    dailyState: DailyState? = nil,
    onDailyStateChange: ((DailyState) -> Void)? = nil,
    dayEnd: DayEndRecord? = nil,
    dayEndSettings: @escaping () -> (enabled: Bool, time: String) = { (true, "20:00") },
    workSettings: @escaping () -> TabySettings = { .defaults },
    onDayEndChange: ((DayEndRecord) -> Void)? = nil
  ) {
    self.clock = clock
    self.notifier = notifier
    self.reminders = reminders
    self.jobRuns = jobRuns
    self.tasksSource = tasksSource
    self.eventsSource = eventsSource
    self.jobsSource = jobsSource
    self.jobRunner = jobRunner
    self.eventLeadMinutes = eventLeadMinutes
    self.reminderSyncInterval = reminderSyncInterval
    self.missedGrace = missedGrace
    self.dailyState = dailyState ?? DailyState(date: LocalTime.formatDate(clock.now()), state: .none)
    self.onDailyStateChange = onDailyStateChange
    self.dayEndRecord = DayEndMachine.forToday(dayEnd, now: clock.now())
    self.dayEndSettings = dayEndSettings
    self.workSettings = workSettings
    self.onDayEndChange = onDayEndChange
  }

  // MARK: Tick

  /// Ein Tick: Tagesstart prüfen, ggf. Erinnerungen abgleichen (alle 5 min), fällige
  /// Erinnerungen genau einmal auslösen, Verpasstes sammeln, Aufträge prüfen.
  /// Läuft schon ein Tick (z. B. ein langer Auftrag), wird dieser übersprungen — so kann
  /// nichts doppelt ausgelöst werden.
  @discardableResult
  public func tick() async -> PlannerTickReport {
    var report = PlannerTickReport()
    if ticking {
      report.skipped = true
      return report
    }
    ticking = true
    defer { ticking = false }

    let now = clock.now()
    report.showDayStart = checkDailyStart(now, trigger: .tick)
    do {
      report.showDayEnd = try await checkDayEnd(now, trigger: .tick)
    } catch {
      report.errors.append("Tagesabschluss konnte nicht geprüft werden: \(error)")
    }

    let syncDue: Bool
    if let last = lastReminderSync {
      // Uhr zurückgestellt → ebenfalls neu abgleichen.
      syncDue = now.timeIntervalSince(last) >= reminderSyncInterval || now < last
    } else {
      syncDue = true
    }
    if syncDue {
      let generation = syncGeneration
      do {
        try await syncReminders(now)
        // Während des Abgleichs kann `invalidateReminders()` gelaufen sein (Actor-Reentranz):
        // dann bleibt `lastReminderSync` nil, und der nächste Tick gleicht erneut ab.
        if generation == syncGeneration { lastReminderSync = now }
        report.resynced = true
      } catch {
        report.errors.append("Erinnerungs-Abgleich fehlgeschlagen: \(error)")
      }
    }

    do {
      let (fired, missed) = try checkReminders(now)
      report.fired = fired
      report.missed = missed
    } catch {
      report.errors.append("Erinnerungen konnten nicht geprüft werden: \(error)")
    }

    do {
      for job in try await jobsSource() where job.enabled {
        jobNames[job.id] = job.name
        do {
          if let run = try await checkJob(job, now: now) { report.jobRuns.append(run) }
        } catch {
          report.errors.append("Auftrag \(job.name) konnte nicht geprüft werden: \(error)")
        }
      }
    } catch {
      report.errors.append("Aufträge konnten nicht geladen werden: \(error)")
    }
    return report
  }

  /// Erzwingt beim nächsten Tick einen Erinnerungs-Abgleich (nach Änderungen an Aufgaben,
  /// Terminen oder Einstellungen — sonst könnte eine bald fällige Erinnerung erst nach bis
  /// zu 5 min angelegt und dann als "verpasst" statt "fällig" eingestuft werden).
  public func invalidateReminders() {
    lastReminderSync = nil
    syncGeneration &+= 1
  }

  private func syncReminders(_ now: Date) async throws {
    let tasks = try await tasksSource()
    let from = LocalTime.formatDate(now)
    let toDate = LocalTime.calendar.date(byAdding: .day, value: 2, to: now) ?? now
    let to = LocalTime.formatDate(toDate)
    let read = try await eventsSource(from, to)
    let events = read.events

    taskTitles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    eventTitles = Dictionary(events.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    eventStarts = Dictionary(events.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
    openTaskRefs = Set(tasks.filter { !$0.done }.map(\.id))

    let lead = eventLeadMinutes()
    let wanted = ReminderSync.taskReminders(tasks) + ReminderSync.eventReminders(events, leadMinutes: lead)
    try ReminderSync.sync(wanted, into: reminders)
    try ReminderSync.retireStale(wanted, eventsFrom: from, eventsTo: to, eventLeadMinutes: lead,
                                 acknowledgedAt: LocalTime.format(now),
                                 eventSourcesReachable: read.unreachableSources.isEmpty, in: reminders)
  }

  private func checkReminders(_ now: Date) throws -> (fired: [Reminder], missed: [Reminder]) {
    // Aufgaben, die seit dem letzten Abgleich nicht mehr offen sind, weder auslösen noch als
    // "verpasst" zeigen (der nächste Abgleich zieht ihre Erinnerungen zurück).
    let candidates = try reminders.listAll().filter { r in
      guard r.source == .task, let open = openTaskRefs else { return true }
      return open.contains(r.sourceRef)
    }
    let (due, missed) = ReminderSync.partitionDue(candidates, now: now, grace: missedGrace)
    self.missed = missed
    var fired: [Reminder] = []
    for var r in due {
      // Erst markieren, dann senden: scheitert das Speichern, wird lieber nicht als doppelt benachrichtigt.
      let at = LocalTime.format(now)
      try reminders.markFired(r.id, firedAt: at)
      notifier.send(ReminderText.notification(for: r, title: title(for: r),
                                              eventStart: r.source == .event ? eventStarts[r.sourceRef] : nil, now: now))
      r.firedAt = at
      fired.append(r)
    }
    return (fired, missed)
  }

  /// Anzeigetitel (Aufgabe/Termin/Auftrag) einer Erinnerung, sonst die Referenz.
  /// Terminbeginn je Termin-Id (für die Ansage „um HH:mm“).
  private var eventStarts: [String: String] = [:]

  public func title(for r: Reminder) -> String {
    switch r.source {
    case .task: return taskTitles[r.sourceRef] ?? r.sourceRef
    case .event: return eventTitles[r.sourceRef] ?? r.sourceRef
    case .job: return jobNames[r.sourceRef] ?? r.sourceRef
    }
  }

  /// Verpasstes mit Titeln (für `Overview.missed`).
  public func missedWithTitles() -> [ReminderWithTitle] {
    missed.map { ReminderWithTitle(reminder: $0, title: title(for: $0)) }
  }

  /// Bestätigt Verpasstes; nil oder leer = alles aktuell Verpasste.
  public func acknowledgeMissed(_ ids: [String]? = nil) throws {
    let targets = (ids?.isEmpty == false) ? ids! : missed.map(\.id)
    guard !targets.isEmpty else { return }
    try reminders.acknowledge(targets, acknowledgedAt: LocalTime.format(clock.now()))
    let set = Set(targets)
    missed.removeAll { set.contains($0.id) }
  }

  // MARK: Aufträge

  private func checkJob(_ job: Job, now: Date) async throws -> JobRun? {
    guard let lastDue = JobSchedule.lastDue(job.rule, now: now) else { return nil }
    // Vor Anlage des Auftrags fällig gewesen: nicht nachholen.
    if let created = LocalTime.parse(job.createdAt), lastDue < created { return nil }

    let scheduledFor = LocalTime.format(lastDue)
    // Nur der jüngste Lauf zählt: liegt er schon bei (oder nach) diesem Termin, ist er erledigt.
    if let latest = try jobRuns.latestRun(jobId: job.id), latest.scheduledFor >= scheduledFor { return nil }

    let startedAt = LocalTime.format(now)
    if now.timeIntervalSince(lastDue) > Planner.staleAfter {
      let run = JobRun(id: UUID().uuidString, jobId: job.id, scheduledFor: scheduledFor, startedAt: startedAt,
                       status: .skippedStale)
      try jobRuns.add(run)
      return run
    }

    let run: JobRun
    let body: String
    do {
      let result = try await jobRunner(job)
      run = JobRun(id: UUID().uuidString, jobId: job.id, scheduledFor: scheduledFor, startedAt: startedAt,
                   status: result.ok ? .ok : .error, output: result.output)
      body = result.output ?? (result.ok ? "Auftrag erledigt." : "Auftrag fehlgeschlagen.")
    } catch {
      run = JobRun(id: UUID().uuidString, jobId: job.id, scheduledFor: scheduledFor, startedAt: startedAt,
                   status: .error, output: String(describing: error))
      body = "Auftrag fehlgeschlagen."
    }
    try jobRuns.add(run)
    notifier.send(TabyNotification(title: job.name, body: body))
    return run
  }

  // MARK: Tagesstart

  @discardableResult
  private func checkDailyStart(_ now: Date, trigger: DayStartTrigger) -> Bool {
    let result = DayStartMachine.evaluate(dailyState, now: now, trigger: trigger)
    // Nur an Arbeitstagen fragen; an freien Tagen bleibt der Zustand unverändert.
    if result.showQuestion && !WorkWeek.isWorkday(workSettings(), date: LocalTime.formatDate(now)) { return false }
    setDailyState(result.state)
    return result.showQuestion
  }

  private func setDailyState(_ s: DailyState) {
    guard s != dailyState else { return }
    dailyState = s
    onDailyStateChange?(s)
  }

  /// Bei App-Start/Anmeldung (zeigt die Frage bei `asked` erneut).
  public func onAppStart() -> (state: DailyState, showQuestion: Bool) {
    let show = checkDailyStart(clock.now(), trigger: .restart)
    return (dailyState, show)
  }

  /// Optional bei Entsperren/Aufwachen (Einstellung `askAfterUnlock`).
  public func onUnlock() -> (state: DailyState, showQuestion: Bool) {
    onAppStart()
  }

  /// Ja → done (Integrator erzeugt danach das Briefing), Später → snoozed +30 min, Heute nicht → skipped.
  @discardableResult
  public func answerDayStart(_ answer: DayStartAnswer) -> DailyState {
    setDailyState(DayStartMachine.answer(answer, state: dailyState, now: clock.now()))
    return dailyState
  }

  // MARK: Tagesabschluss

  /// Bei App-Start/Anmeldung: true, wenn die Abend-Frage jetzt gezeigt werden soll
  /// (auch erneut, wenn sie beim letzten Mal unbeantwortet geschlossen wurde).
  public func dayEndOnAppStart() async -> Bool {
    (try? await checkDayEnd(clock.now(), trigger: .restart)) ?? false
  }

  /// Antwort auf die Abend-Frage. Die Aufgaben-Verschiebung übernimmt der Integrator.
  @discardableResult
  public func answerDayEnd(_ answer: DayEndAnswer) -> DayEndRecord {
    setDayEndRecord(DayEndMachine.answer(answer, record: dayEndRecord, now: clock.now()))
    return dayEndRecord
  }

  /// Liest offene Aufgaben (heute oder überfällig, nicht erledigt) nur, wenn nötig.
  private func checkDayEnd(_ now: Date, trigger: DayStartTrigger) async throws -> Bool {
    let settings = dayEndSettings()
    var hasOpen = false
    if DayEndMachine.needsOpenTasks(dayEndRecord, now: now, time: settings.time, enabled: settings.enabled) {
      let today = LocalTime.formatDate(now)
      hasOpen = try await tasksSource().contains { task in
        guard !task.done, let due = task.due else { return false }
        return LocalTime.datePart(due) <= today
      }
    }
    let result = DayEndMachine.evaluate(dayEndRecord, now: now, time: settings.time, enabled: settings.enabled,
                                        trigger: trigger, hasOpenTasks: hasOpen)
    setDayEndRecord(result.record)
    return result.showQuestion
  }

  private func setDayEndRecord(_ r: DayEndRecord) {
    guard r != dayEndRecord else { return }
    dayEndRecord = r
    onDayEndChange?(r)
  }
}
