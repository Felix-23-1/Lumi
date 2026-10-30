// Einstiegspunkt des Datenkerns: eine Verbindung + alle Repositories mit
// derselben injizierten Uhr (Port von src/main/store/index.ts).
import Foundation

public final class Store: @unchecked Sendable {
  public let db: Database
  public let clock: Clock

  public let tasks: TasksRepository
  public let taskFolders: TaskFoldersRepository
  public let notes: NotesRepository
  public let habits: HabitsRepository
  public let events: EventsRepository
  public let reminders: RemindersRepository
  public let jobs: JobsRepository
  public let dailyState: DailyStateRepository
  public let messages: MessagesRepository
  public let actionLog: ActionLogRepository
  public let calendarSources: CalendarSourcesRepository
  public let settings: SettingsRepository
  public let usage: UsageRepository
  public let reminderLinks: ReminderLinksRepository
  public let dayEnd: DayEndRepository
  public let focus: FocusRepository
  public let memories: MemoriesRepository
  public let dayPlans: DayPlanRepository
  public let weeklyGoals: WeeklyGoalsRepository
  public let weeklyReview: WeeklyReviewStateRepository
  public let weeklyStats: WeeklyStatsRepository
  public let networkDevices: NetworkDevicesRepository
  public let ownServers: OwnServersRepository
  public let notionTaskLinks: NotionTaskLinksRepository
  public let taskPriority: TaskPriorityRepository
  public let notionSources: NotionSourcesRepository
  public let messengerAccounts: MessengerAccountsRepository
  public let messengerReads: MessengerReadRepository
  public let inboxDismissed: InboxDismissedRepository
  public let autoStatus: AutoStatusRepository
  public let audit: AuditRepository

  public init(db: Database, clock: Clock) {
    self.db = db
    self.clock = clock
    tasks = TasksRepository(db: db, clock: clock)
    taskFolders = TaskFoldersRepository(db: db, clock: clock)
    notes = NotesRepository(db: db, clock: clock)
    habits = HabitsRepository(db: db, clock: clock)
    events = EventsRepository(db: db)
    reminders = RemindersRepository(db: db)
    jobs = JobsRepository(db: db, clock: clock)
    dailyState = DailyStateRepository(db: db)
    messages = MessagesRepository(db: db, clock: clock)
    actionLog = ActionLogRepository(db: db, clock: clock)
    calendarSources = CalendarSourcesRepository(db: db)
    settings = SettingsRepository(db: db)
    usage = UsageRepository(db: db, clock: clock)
    reminderLinks = ReminderLinksRepository(db: db)
    dayEnd = DayEndRepository(db: db)
    focus = FocusRepository(db: db, clock: clock)
    memories = MemoriesRepository(db: db, clock: clock)
    dayPlans = DayPlanRepository(db: db)
    weeklyGoals = WeeklyGoalsRepository(db: db)
    weeklyReview = WeeklyReviewStateRepository(db: db)
    weeklyStats = WeeklyStatsRepository(db: db)
    networkDevices = NetworkDevicesRepository(db: db)
    ownServers = OwnServersRepository(db: db)
    notionTaskLinks = NotionTaskLinksRepository(db: db)
    taskPriority = TaskPriorityRepository(db: db)
    notionSources = NotionSourcesRepository(db: db)
    messengerAccounts = MessengerAccountsRepository(db: db, clock: clock)
    messengerReads = MessengerReadRepository(db: db)
    inboxDismissed = InboxDismissedRepository(db: db)
    autoStatus = AutoStatusRepository(db: db)
    audit = AuditRepository(db: db, clock: clock)
  }

  /// Öffnet/legt die Datei an und migriert (z. B. ~/Library/Application Support/Taby/taby.db).
  public static func open(path: String, clock: Clock) throws -> Store {
    Store(db: try Database.open(path: path, clock: clock), clock: clock)
  }

  /// Flüchtiger, migrierter Speicher (Prüfungen, Testmodus).
  public static func inMemory(clock: Clock) throws -> Store {
    Store(db: try Database.openInMemory(clock: clock), clock: clock)
  }
}
