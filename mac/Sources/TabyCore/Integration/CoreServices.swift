// Integrator (Welle 2): der echte Kern hinter `TabyServices` – nativer
// Gegenpart zu src/main/appContext.ts + src/main/ipc/index.ts. Verdrahtet
// Speicher, Werkzeuge, Modell, Planer, Kalender und die Claude-Code-Anbindung.
//
// Grundsätze (BAUPLAN 3/9, CLAUDE.md):
// - Klick-Aktionen der Oberfläche laufen durch denselben Werkzeug-Dispatcher
//   wie der Chat (Validierung, Konflikt-Wächter, Aktionsprotokoll), nur mit
//   actor .user.
// - Konflikt-Prüfung, Erinnerungen, Tagesstart sind Code; das Modell
//   formuliert nur (Chat, Briefing, Aufträge).
// - Zeit nur über die injizierte `Clock`.
import AppKit
import EventKit
import Foundation
import UserNotifications

@MainActor
public final class CoreServices: TabyServices {
  public struct Options {
    /// Datenbank-Datei (z. B. ~/Library/Application Support/Taby/taby.sqlite).
    public var databasePath: String?
    /// Socket für das Hook-Relay (nil = Claude-Code-Anbindung aus).
    public var socketPath: String?
    /// Pfad des gebauten `taby-hook-relay` (für die Hook-Installation).
    public var relayPath: String?
    public var claudeSettingsURL: URL
    public var clock: Clock
    public var keyStore: ApiKeyStore
    /// System-Benachrichtigungen (die Insel bekommt zusätzlich `.flash`).
    public var systemNotifier: Notifier
    public var session: URLSession
    /// Planer-Takt in Sekunden; nil = kein Hintergrund-Takt (Prüfungen).
    public var plannerInterval: TimeInterval?
    /// Start bei Anmeldung umsetzen (App-Ebene, z. B. SMAppService).
    public var applyStartOnLogin: ((Bool) -> Void)?
    /// Geheimnis-Speicher je Kalenderquelle (Notion-Token) – nie in SQLite.
    public var calendarSecrets: (String) -> ApiKeyStore
    /// Notion-OAuth-Client-Secret (Paket 11) – injizierbar wie `calendarSecrets`,
    /// damit Prüfungen nicht den echten Schlüsselbund anfassen.
    public var notionOAuthClientSecrets: () -> ApiKeyStore
    /// API-Schlüssel je Anbieter-Host (außer openrouter.ai): nie an einen anderen Host senden.
    public var llmHostKeyStore: (String) -> ApiKeyStore
    /// Apple Erinnerungen (nil = EventKit). Prüfungen setzen eine Attrappe.
    public var remindersBackend: RemindersBackend?
    /// Socket der MCP-Brücke (nil = MCP aus) und Pfad von `taby-mcp` für die Anzeige.
    public var mcpSocketPath: String?
    public var mcpCommandPath: String?
    /// Ordner der Mod-Bibliothek (nil = eigener Temp-Ordner, z. B. Prüfungen).
    public var modsRoot: URL?
    /// Kurzbefehle-Ausführung (nil = /usr/bin/shortcuts).
    public var shortcuts: ShortcutsRunning?
    /// Vorlesen (nil = Systemstimmen). Prüfungen setzen SinkSpeaker.
    public var speaker: Speaking?
    /// Apple Intelligence verfügbar? (nil = beim System nachfragen)
    public var appleIntelligence: Bool?
    /// Bedienungshilfen-Freigabe anfragen (App-Ebene); nil = nicht möglich.
    public var requestAccessibility: (() -> Bool)?
    /// Paket 4: Fokus-Umgebung (nil = echte; Prüfungen setzen Attrappen).
    public var focusEnvironment: FocusEnvironment?
    /// Paket 5: Mail-Zugang (nil = Apple Mail).
    public var mailBackend: MailBackend?
    /// Paket Kontakte: Zugriff auf die Kontakte (nil = Apple Kontakte). Prüfungen setzen eine Attrappe.
    public var contactsBackend: ContactsBackend?
    /// Paket 6: Netzwerk-Systemaufrufe (nil = echtes System).
    public var networkSystem: NetworkSystem?
    /// Paket 12: Chat-Datenbank (nil = ~/Library/Messages/chat.db), AppleScript-Start (nil = osascript),
    /// Abfrage-Takt (nil = kein Takt; Prüfungen).
    public var messengerChatDbPath: String?
    public var messengerScriptRunner: (@Sendable (String) throws -> ProcessOutput)?
    public var messengerPollInterval: TimeInterval? = 60
    /// Microsoft: Schlüsselbund für das Erneuerungs-Token (nil = Schlüsselbund; Prüfungen setzen einen Speicher)
    /// und Wartefunktion der Anmeldung (Prüfungen setzen eine Attrappe).
    public var microsoftRefreshStore: ApiKeyStore = KeychainApiKeyStore(account: "microsoft-refresh")
    public var microsoftPause: (@Sendable (TimeInterval) async -> Void)?
    /// Musik: AppleScript-Start (nil = osascript) und laufende Bundle-IDs (nil = NSWorkspace).
    public var mediaScriptRunner: (@Sendable (String) throws -> ProcessOutput)?
    public var mediaRunningBundles: (@Sendable () -> Set<String>)?
    /// Mediatasten des Systems (nil = nicht verfügbar, Prüfungen lassen es leer); Rückgabe false = nicht erlaubt.
    public var mediaKeySender: (@Sendable (MediaCommand) -> Bool)?
    /// Commit der laufenden App für die Update-Prüfung (Tests setzen einen festen Wert).
    public var appCommit: () -> String = CoreServices.bundleCommit
    /// Build der laufenden App (0 = nie Update) und Speicher für die letzte Benachrichtigung.
    public var appBuild: () -> Int = CoreServices.bundleBuild
    public var updateDefaults: UserDefaults = .standard
    /// Dateien: mdfind-Lauf (nil = echter Aufruf) und Startordner der Suche (nil = Benutzerordner).
    public var fileSearchRunner: FileSearch.Runner?
    public var fileSearchHome: String?
    /// Merk dir das: vorderste App (nil = echte, über FrontAppTracker) und AppleScript-Lauf (nil = osascript).
    public var captureFrontApp: (() -> CaptureFrontApp?)?
    public var captureScriptRunner: (@Sendable (String) throws -> ProcessOutput)?
    /// Netzlaufwerke: Einhängen, Trennen, Mount-Tabelle (nil = echte; Prüfungen setzen Attrappen).
    public var shares: ShareSystem = .live
    /// Passwort je Netzlaufwerk im Schlüsselbund („share-<id>“); Prüfungen setzen einen Speicher im Arbeitsspeicher.
    public var shareSecrets: (String) -> ApiKeyStore = { KeychainApiKeyStore(account: "share-\($0)") }
    /// Lokales Modell für die Geheimnis-Suche (immer Apple Intelligence); Prüfungen setzen eine Attrappe.
    public var secretModel: () -> LlmClient = { AppleIntelligenceClient() }
    /// Zwischenablage für Funde der Geheimnis-Suche (Prüfungen setzen eine Attrappe).
    public var secretClipboard: SecretClipboard = .live

    public init(databasePath: String? = nil, socketPath: String? = nil, relayPath: String? = nil,
                claudeSettingsURL: URL = ClaudeHookInstaller.defaultSettingsURL, clock: Clock = SystemClock(),
                keyStore: ApiKeyStore = KeychainApiKeyStore(), systemNotifier: Notifier = SinkNotifier(),
                session: URLSession = .shared, plannerInterval: TimeInterval? = 30,
                applyStartOnLogin: ((Bool) -> Void)? = nil,
                calendarSecrets: @escaping (String) -> ApiKeyStore = {
                  KeychainApiKeyStore(account: "calendar-token-\($0)")
                },
                notionOAuthClientSecrets: @escaping () -> ApiKeyStore = { NotionOAuthConfig.clientSecretStore() },
                llmHostKeyStore: @escaping (String) -> ApiKeyStore = {
                  KeychainApiKeyStore(account: LlmConnection.keyAccount(host: $0))
                }) {
      self.databasePath = databasePath; self.socketPath = socketPath; self.relayPath = relayPath
      self.claudeSettingsURL = claudeSettingsURL; self.clock = clock; self.keyStore = keyStore
      self.systemNotifier = systemNotifier; self.session = session; self.plannerInterval = plannerInterval
      self.applyStartOnLogin = applyStartOnLogin
      self.calendarSecrets = calendarSecrets
      self.notionOAuthClientSecrets = notionOAuthClientSecrets
      self.llmHostKeyStore = llmHostKeyStore
    }
  }

  public let store: Store
  public let clock: Clock
  public let planner: Planner
  let options: Options
  let keyStore: ApiKeyStore
  /// Aktueller Kalender-Zugang; auch vom Planer-Actor gelesen, daher hinter einer Sperre.
  let calendarBox: LockedBox<ToolCalendarAccess>
  var calendarAccess: ToolCalendarAccess {
    get { calendarBox.value }
    set { calendarBox.value = newValue }
  }
  var handlers: [@MainActor (AppEvent) -> Void] = []
  var runner: PlannerRunner?
  var hookServer: AgentHookServer?
  /// Zuletzt gemeldete Verpasst-IDs (nur bei Änderung neu zeichnen).
  var lastMissedIds: Set<String> = []
  /// add_event nacheinander: sonst könnten zwei gleichzeitige Aufrufe beide
  /// die Konfliktprüfung bestehen und beide speichern.
  var addEventTail: Task<Void, Never>?
  var chatInFlight = false
  /// Vom Modell angefragte Lösch-Aktionen (nur im Speicher: nach einem Neustart
  /// verfallen sie – das Modell muss dann neu fragen).
  var pending: [(confirmation: PendingConfirmation, name: String, args: JSONValue, mcp: MCPPin?)] = []
  /// Eingang (Inbox.swift): alle Punkte vor dem Ausblenden erledigter, und die letzte Nachricht je Chat
  /// (nur neu geholt, wenn sich der Chat geändert hat).
  var lastInboxItems: [InboxItem] = []
  var inboxLastMessages: [String: (lastAt: String, message: MessengerMessage)] = [:]

  lazy var remindersBackend: RemindersBackend = options.remindersBackend ?? EventKitRemindersBackend()
  var remindersSyncing = false
  var focusTimer: Task<Void, Never>?
  /// Wecker und Rückgängig (TimersUndoSearch.swift).
  let timersUndo = TimersUndoState()
  /// Index des Markdown-Ordners („Wissen“); baut sich bei der ersten Suche auf.
  let vault = MarkdownVault()
  /// Musikanzeige (MediaAndBackups.swift).
  let media = MediaState()
  var mcpServer: MCPBridgeServer?
  public let mods: ModLibrary
  lazy var shortcutsRunner: ShortcutsRunning = options.shortcuts ?? ShortcutsCLI()
  /// Notifier für Mods (System + Insel), gesetzt in init.
  var modNotifier: Notifier = SinkNotifier()
  private var remindersLoop: Task<Void, Never>?
  var remindersDebounce: Task<Void, Never>?
  /// Sicherheits-Takt für den Abgleich mit Apple Erinnerungen (Änderungen auf
  /// Apple-Seite lösen über EKEventStoreChanged sofort einen Abgleich aus).
  static let remindersInterval: UInt64 = 15 * 60
  /// Termine für die Suche (siehe `searchCalendarEvents`), höchstens 60 s alt.
  var searchCalendarMemo: (at: Date, day: String, events: [CalendarEvent])?
  var remindersError: String?
  /// Fehler beim letzten Speichern der Einstellungen (nil = gespeichert); im nächsten Zustand.
  var saveError: String?
  var remindersAccessDenied = false
  private var storeChangeObserver: NSObjectProtocol?
  lazy var speaker: Speaking = options.speaker ?? SystemSpeaker()
  /// Schon angesagte Konflikt-Paare (jedes nur einmal).
  var announcedConflicts: Set<String> = []
  /// Termin-Stand der letzten Konfliktprüfung (siehe `announceNewConflicts`).
  var conflictScanKey: String?
  /// Paket 8: aktueller Mod-Kurztext für die Insel (im Speicher, mit Ablauf).
  /// Kurztexte je Mod (der neueste Text eines Mods ersetzt seinen alten).
  var modIsland: [String: IslandMessage] = [:]
  private var hourlyTimer: Task<Void, Never>?
  /// Tag des letzten Chatverlauf-Aufräumens (höchstens einmal pro Tag).
  var chatPrunedDay: String?
  var availableUpdate: AppUpdate?
  /// Fortschritt des Update-Downloads in Prozent (nil = kein Download läuft).
  var downloadPercent: Int?
  /// Aufgaben, deren Apple-Erinnerung im letzten Abgleich fehlte (nur neue Fälle bekommen einen Rückgängig-Eintrag).
  var removedFromAppleSeen: Set<String> = []
  /// Paket 4: Laufzeit-Zustand (Meeting-Karte, Wochenplanung, Spracheingabe, Fokus-Umgebung).
  let p4: ProductivityRuntime
  /// Paket 5: Mail-Zugang und Posteingang im Speicher (nie in SQLite).
  let mailBackend: MailBackend
  var mailCache: MailOverview?
  var mailFetchedAt: Date?
  /// Wann Lumi zuletzt an ungelesene Mails erinnert hat (nur im Speicher).
  var mailReminderLastAt: Date?
  /// Paket Kontakte: Zugriff auf die Kontakte und die Geburtstage des Tages (nur im Speicher).
  let contactsBackend: ContactsBackend
  let birthdayToday: BirthdayToday
  /// Paket 9: Stand des letzten Notion-Aufgaben-Imports (nur im Speicher).
  var notionTasksSyncState: NotionTaskSync?
  var notionTasksLastAutoSync: Date?
  var urlSession: URLSession { options.session }
  /// Schlüsselbund-Zugang für ein Paket-9-Geheimnis (z. B. das Notion-Aufgaben-Token).
  func secretStore(_ id: String) -> ApiKeyStore { options.calendarSecrets(id) }
  func notionOAuthSecretStore() -> ApiKeyStore { options.notionOAuthClientSecrets() }
  /// Paket 6: Netzwerk-Laufzeit (nur im Speicher; Geräte liegen in SQLite).
  let network: NetworkRuntime
  /// Paket 12: Chat-Konten, Verbindungen und Unterhaltungs-Zwischenspeicher.
  let messenger: MessengerHub
  /// Microsoft (Outlook, Teams): Anmeldung per Gerätecode, Erneuerung im Schlüsselbund.
  let microsoft: MicrosoftAuth
  /// Netzlaufwerke: letzter Fehler je Freigabe (nur im Speicher) und die Beobachter der Einhänge-Meldungen.
  var shareErrors: [String: String] = [:]
  var shareObservers: [NSObjectProtocol] = []
  /// Status automatisch (Slack während Fokus und Termin).
  let autoStatus: AutoStatusController
  private var p4Loop: Task<Void, Never>?
  /// Laufende Mitschrift (höchstens eine) und die Quelle dafür (Prüfungen setzen eine Attrappe).
  var listenSession: ListenSession?
  /// Musikdienste, beim ersten Gebrauch angelegt (siehe CoreServices+Music.swift).
  var musicRegistry: [MusicService: MusicProvider]?
  var audioSourceFactory: () -> AudioTextSource = { LiveMeetingListener() }

  var appleIntelligenceAvailable: Bool {
    options.appleIntelligence ?? AppleIntelligenceClient.isAvailable
  }

  /// Wie in TS: Chatverlauf für Anzeige und Kontext.
  static let historyLimit = 80

  static let tokensMovedKey = "calendarTokensMovedToKeychain"

  static func tokensMovedToKeychain(store: Store) -> Bool {
    !((try? store.db.query("SELECT key FROM app_settings WHERE key = ?", [.text(tokensMovedKey)])) ?? []).isEmpty
  }

  /// Flag nur setzen, wenn keine Calendar-Quelle mehr ein Token in der Datenbank hat (sonst im nächsten Start erneut).
  static func markTokensMovedIfClean(store: Store) {
    let leftover = ((try? store.calendarSources.list()) ?? []).contains { $0.config[CoreServices.tokenKey] != nil }
    guard !leftover else { return }
    _ = try? store.db.run("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)", [.text(tokensMovedKey), .text("true")])
  }

  public init(options: Options) throws {
    // Geheimnisse höchstens einmal je Lauf aus dem Schlüsselbund lesen (jede Abfrage kann blockieren).
    var options = options
    CaptureLeftovers.removeStale(now: options.clock.now())  // best effort, nur alte Reste
    options.keyStore = CachedApiKeyStore(options.keyStore)
    options.calendarSecrets = CachedApiKeyStore.memoized(options.calendarSecrets)
    options.llmHostKeyStore = CachedApiKeyStore.memoized(options.llmHostKeyStore)
    let oauthSecret = CachedApiKeyStore(options.notionOAuthClientSecrets())
    options.notionOAuthClientSecrets = { oauthSecret }
    self.options = options
    clock = options.clock
    keyStore = options.keyStore
    if let path = options.databasePath {
      store = try Store.open(path: path, clock: options.clock)
    } else {
      store = try Store.inMemory(clock: options.clock)
    }
    let mailSettings = store.settings
    let clientIdSettings = store.settings
    microsoft = MicrosoftAuth(session: options.session, clock: options.clock,
                              clientId: { ((try? clientIdSettings.get()) ?? .defaults).microsoftClientId },
                              refreshStore: options.microsoftRefreshStore,
                              pause: options.microsoftPause ?? MicrosoftAuth.sleep)
    mailBackend = options.mailBackend ?? SwitchingMailBackend(
      settings: { (try? mailSettings.get()) ?? .defaults }, clock: options.clock)
    let contacts = options.contactsBackend ?? CNContactsBackend()
    contactsBackend = contacts
    birthdayToday = BirthdayToday(backend: contacts, clock: options.clock)
    network = NetworkRuntime(system: options.networkSystem ?? SystemNetwork())
    messenger = MessengerHub(
      store: store, secrets: options.calendarSecrets,
      chatDbPath: options.messengerChatDbPath ?? IMessageConnector.defaultChatDbPath,
      runScript: options.messengerScriptRunner ?? IMessageConnector.osascript, clock: options.clock,
      microsoft: microsoft)
    p4 = ProductivityRuntime(focus: options.focusEnvironment ?? FocusEnvironment(runner: options.shortcuts ?? ShortcutsCLI()))
    let settingsRepo = store.settings
    let hub = messenger
    let auto = AutoStatusController(
      repo: store.autoStatus, clock: options.clock,
      targets: { hub.statusTargets() },
      enabled: { ((try? settingsRepo.get()) ?? .defaults).autoStatus })
    auto.onHint = { id, hint in hub.setStatusHint(id, hint) }
    autoStatus = auto
    mods = ModLibrary(root: options.modsRoot
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("taby-mods-\(UUID().uuidString)"))
    // Einmalig (Flag in app_settings): ohne Flag wird der Schlüsselbund nur berührt, wenn noch ein Token in der DB steht.
    if !Self.tokensMovedToKeychain(store: store) {
      Self.moveTokensToKeychain(store: store, secrets: options.calendarSecrets)
      Self.markTokensMovedIfClean(store: store)
    }
    Self.migrateLegacyLlmKey(store: store, keyStore: options.keyStore, hostKeyStore: options.llmHostKeyStore)
    let calendarBox = LockedBox(Self.makeCalendarAccess(store: store, session: options.session,
                                                        secrets: options.calendarSecrets, clock: clock,
                                                        microsoft: microsoft))
    self.calendarBox = calendarBox

    // Benachrichtigungen gehen ans System UND lassen die Insel aufpoppen.
    var emitFlash: (TabyNotification) -> Void = { _ in }
    let notifier = FanOutNotifier([options.systemNotifier, ClosureNotifier { emitFlash($0) }])
    modNotifier = notifier

    let store = self.store
    let clock = self.clock
    let today = LocalTime.formatDate(clock.now())
    let dailyRepo = store.dailyState
    var jobRunnerImpl: PlannerJobRunner = { _ in JobRunResult(ok: false, output: "Nicht bereit.") }

    planner = Planner(
      clock: clock,
      notifier: notifier,
      reminders: StoreReminderAdapter(store.reminders),
      jobRuns: StoreJobRunAdapter(store.jobs),
      tasksSource: { try store.tasks.list() },
      eventsSource: { from, to in
        let listing = await calendarBox.value.listAllEvents(from: from, to: to)
        return PlannerEventRead(events: listing.events, unreachableSources: listing.unreachable.map(\.id))
      },
      jobsSource: { try store.jobs.list() },
      jobRunner: { job in try await jobRunnerImpl(job) },
      eventLeadMinutes: { (try? store.settings.get().reminderLeadMinutes) ?? 10 },
      dailyState: try dailyRepo.get(today),
      onDailyStateChange: { s in _ = try? dailyRepo.set(s.date, s.state, snoozeUntil: s.snoozeUntil) },
      dayEnd: try store.dayEnd.get(today),
      dayEndSettings: {
        let s = (try? store.settings.get()) ?? .defaults
        return (s.dayEndEnabled, s.dayEndTime)
      },
      workSettings: { (try? store.settings.get()) ?? .defaults },
      onDayEndChange: { r in try? store.dayEnd.set(r) }
    )

    // Nach `init` verfügbare Rückverweise.
    messenger.emit = { [weak self] e in self?.emit(e) }
    emitFlash = { [weak self] n in
      Task { @MainActor in
        self?.emit(.flash(n))
        self?.say("\(n.title). \(n.body)", briefing: false)
      }
    }
    jobRunnerImpl = { [weak self] job in
      guard let self else { return JobRunResult(ok: false, output: nil) }
      return await self.runJob(job)
    }

    if let interval = options.plannerInterval {
      let runner = PlannerRunner(planner: planner, interval: interval) { [weak self] report in
        await MainActor.run { self?.handleTick(report) }
      }
      self.runner = runner
      runner.start()
    }

    if let socketPath = options.socketPath {
      let server = AgentHookServer(
        socketPath: socketPath,
        onRequest: { [weak self] req in Task { @MainActor in self?.emit(.agentRequest(req)) } },
        onClosed: { [weak self] id, _ in Task { @MainActor in self?.emit(.agentRequestClosed(id: id)) } },
        onNotice: { [weak self] notice in
          Task { @MainActor in
            guard let self, self.settings.claudeNotify else { return }
            self.emit(.claudeNotice(notice))
            self.say(notice.kind == .finished ? "Claude ist fertig." : "Claude wartet auf dich.", briefing: false)
          }
        }
      )
      do {
        try server.start()
        hookServer = server
        if let relay = options.relayPath, let socket = options.socketPath, FileManager.default.isExecutableFile(atPath: relay) {
          // Eingetragener Hook zeigt nach einer Umbenennung/Verschiebung der App ins Leere: Pfad nachziehen.
          _ = try? ClaudeHookInstaller.refreshPaths(settingsURL: options.claudeSettingsURL, relayPath: relay, socketPath: socket)
        }
      } catch {
        TabyLog.error(.core, "Agenten-Server nicht gestartet (\(TabyLog.code(error)))")
      }
    }

    resumeFocusTimer()
    startTimerLoop()
    startMediaLoop()
    applyMcp()
    pruneChatHistoryIfDue()
    // Tägliche Sicherung nicht vor dem Fenster, sondern 30 s nach dem Start im Hintergrund.
    if options.databasePath != nil {
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        self?.dailyBackupInBackground()
      }
    }

    if options.plannerInterval != nil {
      p4Loop = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          await self?.packageFourTick()
          try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
      }
    }

    // Änderungen in Apple Erinnerungen/Kalender (auch vom iPhone über iCloud)
    // meldet macOS sofort – dann gleich abgleichen statt auf den Takt zu warten.
    if options.plannerInterval != nil {
      storeChangeObserver = NotificationCenter.default.addObserver(
        forName: .EKEventStoreChanged, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.p4.eventsCache.clear()
          self?.scheduleRemindersSync()
        }
      }
    }

    if options.plannerInterval != nil {
      hourlyTimer = Task { @MainActor [weak self] in
        self?.runTriggers(.hourly)  // gleich beim Start, sonst bleibt die Notch bis zur ersten Stunde leer
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 3_600_000_000_000)
          guard !Task.isCancelled else { break }
          self?.runTriggers(.hourly)
          self?.pruneChatHistoryIfDue()
          self?.dailyBackupInBackground()
        }
      }
    }

    if options.plannerInterval != nil {
      Task { @MainActor [weak self] in await self?.quietUpdateCheck() }
    }

    if options.plannerInterval != nil { startShareWatch() }

    if let interval = options.messengerPollInterval {
      messenger.start(interval: interval)
    }

    if options.plannerInterval != nil {
      remindersLoop = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          if let self, self.settings.appleRemindersSync { _ = await self.runRemindersSync() }
          try? await Task.sleep(nanoseconds: Self.remindersInterval * 1_000_000_000)
        }
      }
    }
  }

  public func shutdown() {
    if let o = storeChangeObserver { NotificationCenter.default.removeObserver(o) }
    for o in shareObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    options.secretClipboard.clearOnShutdown()  // offener Geheimnis-Fund verschwindet mit Lumi
    remindersLoop?.cancel()
    clearTeamsPresenceAtExit()
    messenger.stop()
    hourlyTimer?.cancel()
    p4Loop?.cancel()
    finishListening(reason: nil)
    focusTimer?.cancel()
    timersUndo.loop?.cancel()
    stopMediaObservers()
    mcpServer?.stop()
    MCPManager.shared.terminateAll()  // fremde MCP-Server nicht überleben lassen
    runner?.stop()
    hookServer?.stop()
  }

  // MARK: - Hilfen

  func emit(_ event: AppEvent) {
    for h in handlers { h(event) }
  }

}

// MARK: - Adapter Speicher → Planer/Kalender

final class StoreReminderAdapter: PlannerReminderStore {
  private let repo: RemindersRepository
  init(_ repo: RemindersRepository) { self.repo = repo }
  func findBySource(_ source: ReminderSource, _ sourceRef: String) throws -> Reminder? {
    try repo.find(source: source, sourceRef: sourceRef)
  }
  func upsert(_ reminder: Reminder) throws { try repo.upsert(reminder) }
  func listAll() throws -> [Reminder] { try repo.listAll() }
  func markFired(_ id: String, firedAt: String) throws { try repo.markFired(id, at: firedAt) }
  func acknowledge(_ ids: [String], acknowledgedAt: String) throws { try repo.acknowledge(ids, at: acknowledgedAt) }
}

final class StoreJobRunAdapter: PlannerJobRunStore {
  private let repo: JobsRepository
  init(_ repo: JobsRepository) { self.repo = repo }
  func add(_ run: JobRun) throws {
    _ = try repo.addRun(jobId: run.jobId, scheduledFor: run.scheduledFor, startedAt: run.startedAt,
                        status: run.status, output: run.output)
    if run.status != .skippedStale { try repo.markRan(run.jobId, at: run.startedAt) }
  }
  func listByJob(_ jobId: String) throws -> [JobRun] { try repo.listRuns(jobId: jobId) }
  func latestRun(jobId: String) throws -> JobRun? { try repo.latestRun(jobId: jobId) }
}

final class StoreLocalEventStore: LocalEventStore {
  private let repo: EventsRepository
  init(_ repo: EventsRepository) { self.repo = repo }
  func list(from: String, to: String) async throws -> [CalendarEvent] { try repo.list(from: from, to: to) }
  func create(_ e: NewEvent) async throws -> CalendarEvent { try repo.add(e) }
  func delete(id: String) async throws { _ = try repo.delete(id) }
}

/// Kleiner threadsicherer Behälter (Wert wird zwischen MainActor und Planer-Actor geteilt).
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

/// Lumi-Seite des Abgleichs mit Apple Erinnerungen, direkt auf dem Speicher.
final class StoreTaskSide: TaskSide {
  private let store: Store
  init(_ store: Store) { self.store = store }
  func tasks() throws -> [TabyTask] { try store.tasks.list() }
  func addTask(title: String, notes: String?, due: String?) throws -> TabyTask {
    try store.tasks.add(title: title, notes: notes, due: due)
  }
  func updateTask(id: String, title: String, notes: String?, due: String?) throws {
    _ = try store.tasks.update(id, title: title, notes: .set(notes), due: .set(due))
  }
  func setDone(id: String, done: Bool) throws {
    _ = done ? try store.tasks.complete(id) : try store.tasks.reopen(id)
  }
  func deleteTask(id: String) throws { _ = try store.tasks.delete(id) }
  func links() throws -> [ReminderLink] {
    try store.reminderLinks.all().map {
      ReminderLink(taskId: $0.taskId, externalId: $0.externalId, snapTitle: $0.snapTitle, snapDue: $0.snapDue,
                   snapDone: $0.snapDone, syncedAt: $0.syncedAt, listId: $0.listId)
    }
  }
  func saveLink(_ l: ReminderLink) throws {
    try store.reminderLinks.upsert(StoredReminderLink(taskId: l.taskId, externalId: l.externalId, snapTitle: l.snapTitle,
                                                      snapDue: l.snapDue, snapDone: l.snapDone, syncedAt: l.syncedAt,
                                                      listId: l.listId))
  }
  func deleteLink(taskId: String) throws { try store.reminderLinks.delete(taskId: taskId) }
}
