// VERTRAG (nur Orchestrator ändert). Port von src/shared/ipc.ts:
// Was die Oberfläche (TabyUI) vom Kern braucht. In Electron war das die
// Preload-/IPC-API; nativ ist es ein Protokoll, das der Integrator mit dem
// echten Kern erfüllt und TabyUI für Vorschauen mit `FakeServices`.
import Foundation

public struct AppState: Equatable, Sendable {
  public var overview: Overview
  public var settings: TabySettings
  public var dayStartState: DayStartState
  public var tasks: [TabyTask]
  public var notes: [Note]
  public var habits: [Habit]
  public var jobs: [Job]
  public var calendarSources: [CalendarSourceConfig]
  /// true, wenn der Tagesstart-Automat jetzt die Frage zeigen soll (BAUPLAN 9).
  public var dayStartPrompt: Bool
  /// Chatverlauf, auch Ergebnisse geplanter Aufträge (Szenario D).
  public var messages: [ChatMessage]
  /// Modell-Verbrauch und Limits (Paket 1).
  public var usage: UsageSummary
  /// Vom Modell angefragte Lösch-Aktionen, die der Nutzer erst bestätigen muss.
  public var pendingConfirmations: [PendingConfirmation]
  /// Paket 2: Tagesabschluss jetzt zeigen; offene Aufgaben dafür stehen in overview.todayTasks/overdueTasks.
  public var dayEndPrompt: Bool
  /// Laufende Fokus-Sitzung (nil = keine).
  public var focus: FocusSession?
  /// Fokus-Minuten heute (abgeschlossene Arbeitsphasen).
  public var focusMinutesToday: Int
  /// Gemerkte Fakten.
  public var memories: [Memory]
  /// Paket 3: Mod-Bibliothek.
  public var mods: [ModInfo]
  /// Letzter Fehler beim Abgleich mit Apple Erinnerungen (nil = ok / aus).
  public var remindersError: String?
  /// true, wenn der Fehler eine fehlende Freigabe ist (Knopf "Systemeinstellungen öffnen").
  public var remindersAccessDenied: Bool
  /// Apple Intelligence (Sprachmodell auf dem Mac) ist verfügbar.
  public var appleIntelligenceAvailable: Bool
  // Paket 4:
  /// Tagesplan von heute (nil = nicht eingeplant).
  public var plan: DayPlan?
  /// Meeting-Karte, die gerade gezeigt werden soll (nil = keine).
  public var meeting: MeetingBrief?
  /// Läuft gerade eine Mitschrift (nil = nein).
  /// Lumi spricht gerade (Vorlesen, Briefing, Erklären): die Ansicht zeigt dann einen Stopp-Knopf.
  public var speaking: Bool = false
  public var listening: MeetingListening?
  /// Wochenplanung jetzt zeigen; Inhalt steht in `weeklyReview`.
  public var weeklyReviewPrompt: Bool
  public var weeklyReview: WeeklyReview?
  /// Ziele der laufenden Woche.
  public var weeklyGoals: [WeeklyGoal]
  /// Paket 5: Posteingang (nil = Mail aus).
  public var mail: MailOverview?
  /// Paket 6: Netzwerk (nil = Werkzeuge aus).
  public var network: NetworkState?
  /// Paket 8: aktueller Mod-Kurztext für die Insel (nil = keiner / abgelaufen).
  public var islandMessage: IslandMessage?
  /// Alle gültigen Mod-Kurztexte (einer je Mod, neuester zuerst) für das Durchrollen in der geschlossenen Notch.
  public var islandMessages: [IslandMessage]
  /// Aufgaben-Ordner, nach Name sortiert.
  public var taskFolders: [TaskFolder]
  /// Laufende Kurzzeitwecker (Notch zeigt den nächsten).
  public var timers: [TabyTimer]
  /// Gerade laufende Musik (Musik-App oder Spotify), nil = nichts / aus.
  public var nowPlaying: NowPlaying?
  /// Beschreibung der letzten rückgängig machbaren Aktion (z. B. „Aufgabe gelöscht“), nil = nichts.
  public var undoLabel: String?
  /// Letzter Fehler beim Speichern von Einstellungen/Schlüssel (nil = ok); die Ansicht zeigt ihn statt „Gespeichert“.
  public var saveError: String?
  /// Notizen im verbundenen Obsidian-Vault (0 = nicht verbunden oder leer).
  public var vaultNoteCount: Int
  /// Zustand der Netzlaufwerke nach `NetworkShare.id`.
  public var shareStates: [String: ShareState]
  /// `NotionAccount.id` der Zugänge mit gespeichertem Zugangscode.
  public var notionConnectedAccounts: [String]
  /// Kategorie je Notion-Aufgabe (Aufgaben-ID → Kategorie-ID), aus Quelle → Zugang berechnet.
  /// Notion-Aufgaben haben nur diese Kategorie, nie eine eigene (`TaskCategoryRules.effective`).
  public var notionTaskCategories: [String: String]
  /// Rückgängig-Stapel, neueste zuerst (höchstens 10); `undoLabel` ist der erste Eintrag.
  public var undoLabels: [String]
  /// Paket „Kontakte“: heutige Geburtstage aus den Kontakten (leer ohne Freigabe).
  public var birthdaysToday: [ContactCard]
  /// Paket „Eingang-Runde“: offene Punkte über Mail und Chats („Antwort nötig“ / „Wartet auf Antwort“).
  public var inbox: [InboxItem]
  /// Neuere Lumi-Version an der Update-Adresse (nil = aktuell oder noch nicht geprüft).
  public var update: AppUpdate?
  /// Paket 9: Stand des Notion-Aufgaben-Imports (nil = ausgeschaltet).
  public var notionTasksSync: NotionTaskSync?
  /// Notion-Token im Schlüsselbund hinterlegt (unabhängig vom Ein-Schalter).
  public var notionTasksConnected: Bool
  /// Paket 10: Aufgaben-IDs in Prioritäts-Reihenfolge (nur offene, vom Nutzer gesetzt).
  public var taskPriority: [String]
  /// Paket 9: Aufgaben, die aus Notion importiert und noch verknüpft sind (offen und erledigt).
  public var notionLinkedTasks: [TabyTask]
  /// Paket 11: eingerichtete Notion-Quellen (Tickets/To-dos/Weekly), Reihenfolge = Anzeige.
  public var notionSources: [NotionSource]
  /// Paket 11: Aufgaben-ID → Quellen-ID, zur Zuordnung von `notionLinkedTasks` zu `notionSources`.
  public var notionSourceLinks: [String: String]
  /// Paket 11: Aufgaben-ID → Gruppe (bei Weekly: die Woche), nur für gruppierte Einträge.
  public var notionTaskGroups: [String: String]
  /// Paket 11: Aufgaben-ID → Notion-ID der Seite/des Blocks (für „In Notion öffnen“).
  public var notionTaskPages: [String: String]
  /// Paket 11: Aufgaben-ID → Ticket-Metadaten (Erstelldatum, Ersteller, Status), nur wo vorhanden.
  public var notionTaskMeta: [String: NotionTaskMeta]
  /// Paket 12: verbundene Chat-Konten und ihre Unterhaltungen (neueste zuerst).
  public var messengerAccounts: [MessengerAccount]
  public var messengerConversations: [MessengerConversation]
  /// Laufende Geräte-Bestätigung (nil = keine).
  public var messengerVerification: MessengerVerification?

  public init(overview: Overview = .empty, settings: TabySettings = .defaults, dayStartState: DayStartState = .none,
              tasks: [TabyTask] = [], notes: [Note] = [], habits: [Habit] = [], jobs: [Job] = [],
              calendarSources: [CalendarSourceConfig] = [], dayStartPrompt: Bool = false,
              messages: [ChatMessage] = [], usage: UsageSummary = UsageSummary(),
              pendingConfirmations: [PendingConfirmation] = [], dayEndPrompt: Bool = false,
              focus: FocusSession? = nil, focusMinutesToday: Int = 0, memories: [Memory] = [],
              mods: [ModInfo] = [], remindersError: String? = nil, remindersAccessDenied: Bool = false,
              appleIntelligenceAvailable: Bool = false, plan: DayPlan? = nil, meeting: MeetingBrief? = nil, listening: MeetingListening? = nil,
              weeklyReviewPrompt: Bool = false, weeklyReview: WeeklyReview? = nil, weeklyGoals: [WeeklyGoal] = [],
              mail: MailOverview? = nil, network: NetworkState? = nil, islandMessage: IslandMessage? = nil,
              notionTasksSync: NotionTaskSync? = nil, notionTasksConnected: Bool = false,
              taskPriority: [String] = [], notionLinkedTasks: [TabyTask] = [],
              notionSources: [NotionSource] = [], notionSourceLinks: [String: String] = [:],
              notionTaskGroups: [String: String] = [:], notionTaskPages: [String: String] = [:],
              notionTaskMeta: [String: NotionTaskMeta] = [:],
              messengerAccounts: [MessengerAccount] = [], messengerConversations: [MessengerConversation] = [],
              messengerVerification: MessengerVerification? = nil, islandMessages: [IslandMessage] = [],
              update: AppUpdate? = nil, taskFolders: [TaskFolder] = [], timers: [TabyTimer] = [],
              nowPlaying: NowPlaying? = nil, undoLabel: String? = nil, vaultNoteCount: Int = 0, shareStates: [String: ShareState] = [:],
              notionConnectedAccounts: [String] = [], notionTaskCategories: [String: String] = [:], birthdaysToday: [ContactCard] = [],
              inbox: [InboxItem] = [], undoLabels: [String] = []) {
    self.overview = overview; self.settings = settings; self.dayStartState = dayStartState
    self.tasks = tasks; self.notes = notes; self.habits = habits; self.jobs = jobs
    self.calendarSources = calendarSources; self.dayStartPrompt = dayStartPrompt; self.messages = messages
    self.usage = usage
    self.pendingConfirmations = pendingConfirmations
    self.dayEndPrompt = dayEndPrompt; self.focus = focus
    self.focusMinutesToday = focusMinutesToday; self.memories = memories
    self.mods = mods
    self.remindersError = remindersError; self.remindersAccessDenied = remindersAccessDenied
    self.appleIntelligenceAvailable = appleIntelligenceAvailable
    self.plan = plan; self.meeting = meeting; self.listening = listening; self.weeklyReviewPrompt = weeklyReviewPrompt
    self.weeklyReview = weeklyReview; self.weeklyGoals = weeklyGoals
    self.mail = mail; self.network = network; self.islandMessage = islandMessage
    self.notionTasksSync = notionTasksSync; self.notionTasksConnected = notionTasksConnected
    self.taskPriority = taskPriority
    self.notionLinkedTasks = notionLinkedTasks
    self.notionSources = notionSources
    self.notionSourceLinks = notionSourceLinks
    self.notionTaskGroups = notionTaskGroups
    self.notionTaskPages = notionTaskPages
    self.notionTaskMeta = notionTaskMeta
    self.messengerAccounts = messengerAccounts
    self.messengerConversations = messengerConversations
    self.messengerVerification = messengerVerification
    self.islandMessages = islandMessages
    self.update = update
    self.taskFolders = taskFolders
    self.timers = timers; self.nowPlaying = nowPlaying; self.undoLabel = undoLabel; self.vaultNoteCount = vaultNoteCount; self.shareStates = shareStates
    self.notionConnectedAccounts = notionConnectedAccounts; self.notionTaskCategories = notionTaskCategories
    self.birthdaysToday = birthdaysToday; self.inbox = inbox; self.undoLabels = undoLabels
  }
}

/// Eine Stimme zum Vorlesen.
public struct VoiceInfo: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  /// "Standard", "Erweitert" oder "Premium".
  public var quality: String
  public init(id: String, name: String, quality: String) { self.id = id; self.name = name; self.quality = quality }
}

/// Systemfreigaben, die der Einrichtungs-Assistent anfragt.
public enum PermissionKind: String, Codable, Sendable, CaseIterable {
  case calendar, reminders, notifications
  /// Paket 4: Sprechen (Mikrofon + Spracherkennung) und markierten Text übernehmen (Bedienungshilfen).
  case microphone, speechRecognition, accessibility
  /// Paket 5: Apple Mail steuern (Automation).
  case mail
}

/// Antwort auf den Tagesabschluss.
public enum DayEndAnswer: String, Codable, Sendable {
  /// Alle offenen Aufgaben von heute/überfällig auf morgen schieben, Abschluss erledigt.
  case moveAllToTomorrow
  /// Einzeln erledigt (Nutzer hat selbst sortiert) – nur abschließen.
  case done
  /// In 30 Minuten noch mal fragen.
  case later
  /// Heute nicht mehr fragen.
  case skip
}

/// Ergebnis des Markdown-Exports.
public struct ExportResult: Equatable, Sendable {
  public var folder: String
  public var files: Int
  /// Ordner mit den vorherigen Exportdateien (nil = nichts ersetzt).
  public var backupFolder: String?
  public init(folder: String, files: Int, backupFolder: String? = nil) {
    self.folder = folder; self.files = files; self.backupFolder = backupFolder
  }
}

/// Eine zerstörende Aktion des Modells (löschen, Auftrag stoppen), die erst
/// nach Bestätigung durch den Nutzer ausgeführt wird (Schutz gegen
/// Prompt-Injection über Kalender-/Notiz-Inhalte).
public struct PendingConfirmation: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// Werkzeugname, z. B. "delete_task".
  public var tool: String
  /// Deutsche Beschreibung, z. B. "Aufgabe „Steuer machen“ löschen".
  public var summary: String
  public var createdAt: String
  /// Vollständige (bereinigte) Werte, die ausgeführt würden; die Karte zeigt sie unter „Alles anzeigen“.
  public var detail: String?
  public init(id: String, tool: String, summary: String, createdAt: String, detail: String? = nil) {
    self.id = id; self.tool = tool; self.summary = summary; self.createdAt = createdAt; self.detail = detail
  }
}

/// Modell-Verbrauch heute und im laufenden Monat (lokale Zeit).
public struct UsageSummary: Codable, Equatable, Sendable {
  public var todayUsd: Double
  public var monthUsd: Double
  public var todayTokens: Int
  public var monthTokens: Int
  /// true, wenn Tages- oder Monatslimit erreicht ist (Modell wird dann nicht mehr gerufen).
  public var limitReached: Bool
  /// true ab 80 % eines Limits (Warnung in der Oberfläche).
  public var nearLimit: Bool

  public init(todayUsd: Double = 0, monthUsd: Double = 0, todayTokens: Int = 0, monthTokens: Int = 0,
              limitReached: Bool = false, nearLimit: Bool = false) {
    self.todayUsd = todayUsd; self.monthUsd = monthUsd; self.todayTokens = todayTokens
    self.monthTokens = monthTokens; self.limitReached = limitReached; self.nearLimit = nearLimit
  }
}

/// Eine Liste in Apple Erinnerungen (für die Auswahl in den Einstellungen).
public struct ReminderListInfo: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum DayStartAnswer: String, Codable, Sendable {
  case yes, later, skip
}

public struct TaskPatch: Equatable, Sendable {
  public var title: String?
  public var notes: String?
  public var due: String?
  /// nil = unverändert, "" = Kategorie entfernen, sonst `TaskCategory.rawValue` ("arbeit"/"privat").
  public var category: String?
  /// nil = unverändert, "" = aus dem Ordner nehmen, sonst `TaskFolder.id`.
  public var folderId: String?
  /// nil = unverändert, "" = keine Wiederholung, sonst `TaskRecurrence.rawValue`.
  public var recurrence: String?
  /// nil = unverändert, 0 = Dauer entfernen, sonst geschätzte Minuten.
  public var minutes: Int?
  /// nil = unverändert, "" = offen, sonst `TaskStatus.rawValue`.
  public var status: String?
  /// nil = unverändert, [] = alle entfernen.
  public var tags: [String]?
  public init(title: String? = nil, notes: String? = nil, due: String? = nil, category: String? = nil,
              folderId: String? = nil, recurrence: String? = nil, minutes: Int? = nil, status: String? = nil,
              tags: [String]? = nil) {
    self.status = status; self.tags = tags
    self.title = title; self.notes = notes; self.due = due; self.category = category; self.folderId = folderId
    self.recurrence = recurrence; self.minutes = minutes
  }
}

public struct NotePatch: Equatable, Sendable {
  public var title: String?
  public var content: String?
  /// nil = unverändert, "" = Zuordnung lösen, sonst `TabyTask.id`.
  public var taskId: String?
  /// nil = unverändert, [] = alle entfernen.
  public var tags: [String]?
  public init(title: String? = nil, content: String? = nil, taskId: String? = nil, tags: [String]? = nil) {
    self.title = title; self.content = content; self.taskId = taskId; self.tags = tags
  }
}

public struct AddEventRequest: Equatable, Sendable {
  public var event: NewEvent
  /// Nutzer hat den Konflikt bestätigt ("trotzdem speichern").
  public var allowConflict: Bool
  public init(event: NewEvent, allowConflict: Bool = false) {
    self.event = event; self.allowConflict = allowConflict
  }
}

/// add_event meldet Konflikte strukturiert (Titel+Zeit des Konflikttermins
/// über `conflicts[].with`, Szenario A). Ganztägige Überschneidungen kommen
/// als `info` zurück (kein Konflikt, Abschnitt 7).
public enum AddEventResult: Equatable, Sendable {
  case ok(event: CalendarEvent, info: [CalendarEvent], unreachable: [SourceProblem])
  case conflict(error: String, conflicts: [Conflict])
  case failure(code: String, error: String)
}

public struct ScheduleJobRequest: Equatable, Sendable {
  public var name: String
  public var prompt: String
  public var rule: JobRule
  public init(name: String, prompt: String, rule: JobRule) {
    self.name = name; self.prompt = prompt; self.rule = rule
  }
}

/// Benachrichtigung (System + kurzes Aufpoppen der Notch-Insel).
public struct TabyNotification: Codable, Equatable, Sendable {
  public var title: String
  public var body: String
  /// Erinnerung zu einer Aufgabe: die Notch bietet dann „Erledigt“ / „In 10 Min“ an.
  public var taskId: String?
  /// Fokuszeit einer Aufgabe ist um: die Notch fragt „Fertig oder brauchst du noch?“ statt der Erinnerungs-Knöpfe.
  public var overrun: Bool
  public init(title: String, body: String, taskId: String? = nil, overrun: Bool = false) {
    self.title = title; self.body = body; self.taskId = taskId; self.overrun = overrun
  }
}

public protocol Notifier: AnyObject {
  func send(_ n: TabyNotification)
}

/// Sammelt gesendete Benachrichtigungen (Prüfungen).
public final class SinkNotifier: Notifier {
  public private(set) var sent: [TabyNotification] = []
  private let lock = NSLock()
  public init() {}
  public func send(_ n: TabyNotification) {
    lock.lock(); sent.append(n); lock.unlock()
  }
}

/// Claude-Code-PermissionRequest (docs/decisions/0005-agents-hooks.md).
public struct AgentPermissionRequest: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var toolName: String
  public var toolInput: JSONValue
  public var cwd: String?
  public init(id: String, toolName: String, toolInput: JSONValue, cwd: String? = nil) {
    self.id = id; self.toolName = toolName; self.toolInput = toolInput; self.cwd = cwd
  }
}

public struct AgentPermissionDecision: Codable, Equatable, Sendable {
  public enum Behavior: String, Codable, Sendable { case allow, deny }
  public var behavior: Behavior
  /// Nur bei .deny (siehe PermissionRequest-Hook-Doku).
  public var message: String?
  public init(behavior: Behavior, message: String? = nil) {
    self.behavior = behavior; self.message = message
  }
}

/// Ereignisse Kern → Oberfläche.
public enum AppEvent: Equatable, Sendable {
  case stateChanged
  case dayStartPrompt
  case briefingReady(Briefing)
  case agentRequest(AgentPermissionRequest)
  case agentRequestClosed(id: String)
  /// Erinnerung/Benachrichtigung: die Insel poppt kurz auf.
  case flash(TabyNotification)
  /// Das Modell möchte etwas löschen – Bestätigung nötig (Insel öffnet sich).
  case confirmationRequested(PendingConfirmation)
  /// Zeit für den Tagesabschluss (Insel öffnet sich).
  case dayEndPrompt
  /// Fokus- oder Pausenphase ist abgelaufen.
  case focusFinished(FocusSession)
  /// Paket 4: Meeting-Karte (vorher/nachher) – Insel öffnet sich.
  case meetingPrompt(MeetingBrief)
  /// Zeit für die Wochenplanung – Insel öffnet sich.
  case weeklyReviewPrompt
  /// Paket 5: Claude Code wartet auf Eingabe oder ist fertig – Insel poppt auf.
  case claudeNotice(ClaudeNotice)
  /// Paket 7: neue Pakete im laufenden Mitschnitt (gebündelt).
  case capturePackets([CapturePacket])
}

/// Alles, was die Oberfläche aufrufen darf. Fehler kommen als `ToolResult`
/// zurück; nur `chatSend` wirft (`LlmError`, Abbruch über Task-Cancellation).
@MainActor
public protocol TabyServices: AnyObject {
  func state() async -> AppState

  func chatSend(_ text: String) async throws -> [ChatMessage]
  /// Wie `chatSend`, meldet die Antwort aber schon während sie entsteht (gesamter bisheriger Text).
  /// Standard: ohne Teiltexte über `chatSend`.
  func chatSendStreaming(_ text: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> [ChatMessage]
  /// Wählt nach festen Regeln die nächste Aufgabe (überfällig > fest terminiert > Priorität > kürzeste) und
  /// startet dafür den Fokus. Liefert die gewählte Aufgabe und den Grund.
  func whatNow() async -> ToolResult<WhatNowPick>
  func chatClear() async
  /// Schnellerfassung: freier Gedanke → das Modell legt Aufgabe, Notiz oder
  /// Termin an (über dieselben Werkzeuge). Wirft `LlmError` wie `chatSend`.
  func quickCapture(_ text: String) async throws -> [ChatMessage]

  func updateSettings(_ patch: SettingsPatch, apiKey: String?) async -> TabySettings
  func listModels() async -> ToolResult<[String]>
  func testLlm() async -> LlmTestResult

  func answerDayStart(_ answer: DayStartAnswer) async
  func acknowledgeMissed(_ reminderIds: [String]) async

  func upsertCalendarSource(_ draft: CalendarSourceDraft) async -> ToolResult<CalendarSourceConfig>
  /// Alle Kalender, die macOS kennt (für die Auswahl bei der Apple-Quelle). Ohne Freigabe: leer.
  func appleCalendars() async -> [AppleCalendarInfo]
  func calendarHealthCheck(_ id: String) async -> HealthResult

  func addTask(title: String, notes: String?, due: String?) async -> ToolResult<TabyTask>
  func updateTask(_ id: String, _ patch: TaskPatch) async -> ToolResult<TabyTask>
  func completeTask(_ id: String) async -> ToolResult<TabyTask>
  func reopenTask(_ id: String) async -> ToolResult<TabyTask>
  func deleteTask(_ id: String) async -> ToolResult<Empty>
  /// Aufgaben-Ordner. Name 1…60 Zeichen, eindeutig (Groß/Klein egal).
  func addTaskFolder(name: String) async -> ToolResult<TaskFolder>
  /// Ordner in einer Kategorie anlegen bzw. die Kategorie eines Ordners ändern ("" = keine).
  func addTaskFolder(name: String, categoryId: String?) async -> ToolResult<TaskFolder>
  func setTaskFolderCategory(_ id: String, categoryId: String?) async -> ToolResult<TaskFolder>
  func renameTaskFolder(_ id: String, name: String) async -> ToolResult<TaskFolder>
  /// Löscht nur den Ordner; seine Aufgaben bleiben erhalten (ohne Ordner).
  func deleteTaskFolder(_ id: String) async -> ToolResult<Empty>
  // Runde 3: Wecker, Musik, Suche, Rückgängig, Sicherungen (docs/team/VORSCHLAEGE.md).
  /// Kurzzeitwecker, 1…720 Minuten; beim Ablauf Hinweis + Notch.
  func startTimer(minutes: Int, label: String) async -> ToolResult<TabyTimer>
  func cancelTimer(_ id: String) async
  func mediaControl(_ command: MediaCommand) async -> ToolResult<Empty>
  /// Musik-Reiter (siehe Contracts/Music.swift).
  func musicStatus() async -> [MusicServiceStatus]
  /// YouTube im Browser anzeigen (liest Tab-Titel; aus, bis der Nutzer es einschaltet).
  func musicBrowserDetection() async -> Bool
  func musicSetBrowserDetection(_ on: Bool) async
  /// Liest den aktuellen Titel neu (Reiter erscheint).
  func musicRefreshNowPlaying() async
  func musicSetClientId(_ service: MusicService, _ clientId: String) async
  func musicConnect(_ service: MusicService) async -> ToolResult<Empty>
  func musicDisconnect(_ service: MusicService) async
  func musicSearch(_ service: MusicService, query: String) async -> ToolResult<[MusicItem]>
  func musicPlaylists(_ service: MusicService) async -> ToolResult<[MusicItem]>
  func musicPlay(_ item: MusicItem) async -> ToolResult<Empty>
  /// Sucht in Aufgaben, Notizen, Terminen (±30 Tage) und Gedächtnis; höchstens 30 Treffer.
  func search(_ query: String) async -> [SearchHit]
  /// Macht die letzte Aktion rückgängig (siehe `AppState.undoLabel`); liefert, was zurückgenommen wurde.
  func undoLast() async -> ToolResult<String>
  /// Vorhandene Datenbank-Sicherungen, neueste zuerst.
  func listBackups() async -> [BackupInfo]
  /// Beispiel-Tag für den ersten Start: drei Aufgaben, eine Notiz, ein Termin (markiert, in einem Zug entfernbar).
  func seedSampleDay() async -> ToolResult<Empty>
  func removeSampleDay() async -> ToolResult<Empty>
  // Alltags-Pakete (docs/team/IDEEN-ALLTAG.md).
  /// Kontakte nach Name/Firma/E-Mail (höchstens 10). Ohne Freigabe leer.
  func findContacts(_ query: String) async -> [ContactCard]
  /// Spotlight-Suche nach Dateien (Name/Inhalt), höchstens 20. Läuft nur lokal, ohne Modell.
  func findFiles(_ query: String) async -> [FileHit]
  /// Fasst eine Datei zusammen – nur mit Apple Intelligence (auf dem Mac); sonst Fehler, nichts verlässt den Mac.
  func summarizeFile(_ path: String) async -> ToolResult<String>
  /// Holt den Kontext der vordersten App (Safari-Seite, Mail-Auswahl, Finder-Auswahl, sonst markierter Text).
  func captureContext() async -> ToolResult<CapturedContext>
  /// Speichert den geholten Kontext als Notiz, Aufgabe oder „Später lesen“ (Notiz mit Kennzeichen).
  func saveCapture(_ context: CapturedContext, as target: CaptureTarget) async -> ToolResult<Empty>
  /// Eingang: Punkt als erledigt markieren (verschwindet aus der Liste).
  func markInboxDone(_ id: String) async
  /// Eingang: Antwort-Entwurf öffnen (Mail-Entwurf bzw. Chat mit vorbereitetem Text) – sendet nie selbst.
  func draftReply(_ id: String) async -> ToolResult<Empty>
  /// Nach einem Termin: Zusammenfassung als Mail-Entwurf an die Teilnehmer (sendet nie selbst).
  func draftMeetingFollowUp(eventId: String) async -> ToolResult<Empty>
  // Runde 4 Welle A (docs/team/PLAN-RUNDE4.md).
  /// Schreibt eine Diagnose-Datei (Zip) in `folder` (nil = Schreibtisch) und liefert den Pfad.
  /// Enthält Protokoll, Version, Einstellungen ohne Geheimnisse, Datenbank-Statistik – nie Schlüssel oder Nachrichtentexte.
  func exportDiagnostics(to folder: String?) async -> ToolResult<String>
  // Welle D: Audit-Protokoll aller Werkzeugausführungen (lokal).
  /// Protokoll (Datenschutz) vollständig leeren; nur der Nutzer löst das aus.
  func clearAudit() async -> ToolResult<Empty>
  /// Notion-Zugänge: anlegen (mit eigenem Zugangscode), umbenennen/Kategorie ändern, Code ersetzen, entfernen.
  /// Entfernen löscht den Zugangscode und die Quellen des Zugangs; die importierten Aufgaben bleiben oder werden gelöscht.
  func addNotionAccount(name: String, categoryId: String, token: String) async -> ToolResult<NotionAccount>
  func updateNotionAccount(_ id: String, name: String?, categoryId: String?) async -> ToolResult<NotionAccount>
  func setNotionAccountToken(_ id: String, token: String) async -> ToolResult<Empty>
  func removeNotionAccount(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty>
  /// Quelle in einem bestimmten Zugang anlegen (die alte Form ohne Zugang nutzt den Standard-Zugang).
  func addNotionSource(name: String, category: NotionSourceCategory, link: String,
                       accountId: String) async -> ToolResult<NotionSource>
  /// Netzlaufwerk einhängen bzw. trennen (`NetworkShare.id`); Fehlertexte in Alltagssprache.
  func mountShare(_ id: String) async -> ToolResult<Empty>
  func unmountShare(_ id: String) async -> ToolResult<Empty>
  /// Passwort eines Netzlaufwerks im Schlüsselbund ablegen (leer = löschen).
  func setSharePassword(_ id: String, password: String) async -> ToolResult<Empty>
  /// Geheimnis in den freigegebenen Ordnern suchen (nur mit lokalem Modell, Wert nur in die Zwischenablage).
  func lookupSecret(query: String) async -> ToolResult<SecretLookup>
  /// Microsoft (Outlook, Teams): Gerätecode holen, auf die Bestätigung warten, trennen.
  func startMicrosoftSignIn() async -> ToolResult<MicrosoftSignIn>
  /// Anmeldung mit nur den Rechten, die gebraucht werden: Kalender immer, Teams (Chats lesen/schreiben, Status) nur mit `includeTeams`.
  func startMicrosoftSignIn(includeTeams: Bool) async -> ToolResult<MicrosoftSignIn>
  /// Laufende Anmeldung abbrechen (Gerätecode verwerfen, Warteschleife beenden).
  func cancelMicrosoftSignIn() async
  func finishMicrosoftSignIn() async -> ToolResult<String>
  func disconnectMicrosoft() async -> ToolResult<Empty>
  /// Notiz in den Obsidian-Vault schreiben (nur im `vaultWriteFolder`; `append` hängt an eine bestehende Datei an).
  func saveVaultNote(title: String, content: String, append: Bool) async -> ToolResult<FileHit>
  func listAudit(limit: Int) async -> [AuditEntry]
  /// Prüft einen MCP-Server (startet ihn kurz, listet Werkzeuge) und liefert deren Namen.
  func testMCPServer(_ config: MCPServerConfig) async -> ToolResult<[String]>
  /// Spielt eine Sicherung zurück: aktuelle Datenbank wird vorher selbst gesichert; danach startet Lumi neu.
  func restoreBackup(_ name: String) async -> ToolResult<Empty>
  /// Legt eine frische Sicherung an und kopiert sie in `folder` (für den Umzug auf einen anderen Mac); liefert den Dateipfad.
  func exportBackup(to folder: String) async -> ToolResult<String>
  /// Prüft eine Sicherungsdatei von einem anderen Mac und legt sie in den Sicherungsordner; liefert den Namen für `restoreBackup`.
  func importBackup(from path: String) async -> ToolResult<String>
  /// Liedtext zu Interpret und Titel (nur wenn der Nutzer ihn eingeschaltet hat; sendet beide an den Textdienst). Reiner Text, ohne Zeitmarken.
  func lyrics(artist: String, title: String) async -> ToolResult<String>

  func addNote(title: String, content: String) async -> ToolResult<Note>
  func updateNote(_ id: String, _ patch: NotePatch) async -> ToolResult<Note>
  func deleteNote(_ id: String) async -> ToolResult<Empty>

  func addHabit(name: String, description: String?) async -> ToolResult<Habit>
  /// date: "YYYY-MM-DD"
  func checkHabit(_ id: String, date: String) async -> ToolResult<Habit>
  func deleteHabit(_ id: String) async -> ToolResult<Empty>

  func addEvent(_ req: AddEventRequest) async -> AddEventResult
  func listEvents(from: String, to: String) async -> [CalendarEvent]
  /// Löscht einen Termin (nur beschreibbare Module). Die Oberfläche fragt vorher sicher nach.
  func deleteEvent(id: String, sourceId: String) async -> ToolResult<Empty>

  func scheduleJob(_ req: ScheduleJobRequest) async -> ToolResult<Job>
  func cancelJob(_ id: String) async -> ToolResult<Empty>

  /// Listen aus Apple Erinnerungen (fragt beim ersten Mal nach der Freigabe).
  func appleReminderLists() async -> ToolResult<[ReminderListInfo]>
  /// Abgleich mit Apple Erinnerungen sofort anstoßen.
  func syncAppleReminders() async -> ToolResult<Empty>

  // Paket 2
  func answerDayEnd(_ answer: DayEndAnswer) async
  /// Verschiebt die Fälligkeit dieser Aufgaben auf morgen (Uhrzeit bleibt erhalten).
  func moveTasksToTomorrow(_ ids: [String]) async -> ToolResult<Empty>
  /// Startet eine Fokus-Sitzung (minutes nil = Einstellung focusMinutes). Eine laufende wird ersetzt.
  func startFocus(taskId: String?, minutes: Int?) async -> ToolResult<FocusSession>
  func stopFocus() async
  /// Spontane Pause (beliebige Länge): beendet den Fokus, späteren Aufgaben rücken um die Pause nach.
  func startBreak(minutes: Int) async -> ToolResult<FocusSession>
  /// Hält die laufende Sitzung an (Countdown steht) bzw. lässt sie weiterlaufen; später rücken Aufgaben nach.
  func pauseFocus() async
  func resumeFocus() async
  func addMemory(_ text: String) async -> ToolResult<Memory>
  func deleteMemory(_ id: String) async -> ToolResult<Empty>
  /// Exportiert Notizen und Aufgaben als Markdown in `folder` (nil = Einstellung exportFolder).
  func exportMarkdown(to folder: String?) async -> ToolResult<ExportResult>
  /// Pfad des `taby-mcp`-Programms für die Konfiguration in Hermes/Claude (nil = nur in der App verfügbar).
  func mcpCommandPath() async -> String?

  // Einrichtung
  /// Fragt die macOS-Freigabe an (Dialog beim ersten Mal); true = erteilt.
  func requestPermission(_ kind: PermissionKind) async -> Bool

  // Sprache
  /// Deutsche Stimmen des Systems (beste Qualität zuerst).
  func availableVoices() async -> [VoiceInfo]
  /// Spricht einen Probesatz mit der Stimme (nil = eingestellte).
  func previewVoice(_ id: String?) async
  func stopSpeaking() async
  /// Liest Termine der nächsten `readAloudMinutes` und offene Aufgaben vor – immer, auch wenn Ansagen aus sind.
  func speakOverview() async
  /// Gesprächsmodus: Antwort vorlesen und warten, bis sie zu Ende gesprochen ist.
  func speakReply(_ text: String) async
  func stopSpeaking()

  // Paket 3: Mods
  /// Namen aller Kurzbefehle (Apple-App „Kurzbefehle“).
  func listShortcuts() async -> ToolResult<[String]>
  /// Legt einen Kurzbefehl-Mod an (ausgeschaltet). `asTool`: das Modell darf ihn aufrufen.
  func createShortcutMod(shortcutName: String, description: String, asTool: Bool,
                         triggers: [ModTrigger]) async -> ToolResult<ModInfo>
  /// Ein-/Ausschalten. Einschalten gibt die aktuelle Fassung samt Rechten frei.
  func setModEnabled(_ id: String, _ enabled: Bool) async -> ToolResult<ModInfo>
  /// Speichert einen Einstellungswert eines Mods (ändert nicht die Freigabe).
  func setModSetting(_ id: String, key: String, value: String) async -> ToolResult<ModInfo>
  /// Führt einen Skill aus (Chat-Befehl „/<command>“ oder Knopf); Ergebnis landet im Chat.
  func runSkill(_ id: String, input: String) async throws -> [ChatMessage]
  func deleteMod(_ id: String) async -> ToolResult<Empty>
  /// Probelauf mit Eingabe (Text oder JSON). Ergebnis als Text.
  func runMod(_ id: String, input: String?) async -> ToolResult<String>
  /// Exportiert als `.tabymod`-Datei in `folder`; liefert den Dateipfad.
  func exportMod(_ id: String, to folder: String) async -> ToolResult<String>
  /// Importiert eine `.tabymod`-Datei (ausgeschaltet, muss freigegeben werden).
  func importMod(from path: String) async -> ToolResult<ModInfo>
  /// Eingebaute Mod-Bibliothek (fertige Mods zum Hinzufügen).
  func modCatalog() async -> [CatalogMod]
  /// Installiert einen Bibliotheks-Mod (ausgeschaltet, muss freigegeben werden).
  func installCatalogMod(_ id: String) async -> ToolResult<ModInfo>

  // Paket 4
  /// Plant offene Aufgaben (überfällig, heute, ohne Datum, dann bald fällig) in die freien Lücken von jetzt bis
  /// Tagesende; ersetzt den bisherigen Plan von heute.
  func planDay() async -> ToolResult<DayPlan>
  func clearPlan() async
  /// Meeting-Karte schließen (kommt für diesen Termin/diese Phase nicht wieder).
  func dismissMeeting(_ id: String) async
  /// Stichpunkte nach dem Termin: speichert eine Notiz; Zeilen mit "-", "*", "•" oder "[ ]" werden Aufgaben.
  func submitMeetingNotes(_ id: String, text: String) async -> ToolResult<MeetingNotesResult>
  /// Bereitet den Termin vor: legt die Termin-Notiz an (Agenda aus den gewählten Notizen/Aufgaben, leerer Abschnitt
  /// „Mitschrift“) bzw. ergänzt sie. `id` = `MeetingBrief.id`. Ohne Modell entsteht die Agenda im Code aus den Titeln.
  func prepareMeeting(_ id: String, noteIds: [String], taskIds: [String]) async -> ToolResult<Note>
  /// Nach dem Termin: fasst die Termin-Notiz (Mitschrift) zusammen, hängt „Zusammenfassung“ an und legt Aufgaben an.
  func summarizeMeeting(_ id: String) async -> ToolResult<MeetingNotesResult>
  /// Startet die lokale Mitschrift in die Termin-Notiz (Abschnitt „Mitschrift“). Bei `.everyone` muss
  /// `consentGiven` wahr sein (der Nutzer hat bestätigt, dass alle informiert sind), sonst Fehler.
  func startMeetingListening(_ id: String, mode: MeetingListenMode, consentGiven: Bool) async -> ToolResult<Empty>
  func stopMeetingListening() async
  /// „Das ist eine Aufgabe“: markiert den Moment (die letzten ~30 s) als sichere Aufgaben-Stelle.
  func markMeetingMoment() async
  /// Aufgaben-Kandidaten aus der Mitschrift; nichts wird angelegt.
  func extractMeetingActions(_ id: String) async -> ToolResult<[ActionCandidate]>
  /// Legt die bestätigten Kandidaten als Aufgaben an (Fälligkeit, Kennzeichen `meeting`, Verweis auf die Termin-Notiz).
  func acceptMeetingActions(_ id: String, _ items: [ActionCandidate]) async -> ToolResult<[TabyTask]>
  /// Erklärt einen Text (markiert oder aus einem Bildschirmbereich), optional laut. Kein Anlegen, nur Antwort.
  func explainText(_ text: String, speak: Bool) async -> ToolResult<String>
  /// Antwortentwurf (Sie-Form) auf einen Text, z. B. eine Kundenanfrage. Fehlende Angaben werden zu [Platzhaltern];
  /// `signature` ist die Grußformel am Ende (leer = „Freundliche Grüße“). Nichts wird gesendet.
  func draftReply(_ text: String, signature: String) async -> ToolResult<String>
  /// Frage zu einem Text (markiert oder per OCR aus einem Bildschirmausschnitt). Leere Frage = erklären.
  func askAboutText(_ text: String, question: String, speak: Bool) async -> ToolResult<String>
  /// Datei (PDF, Text, Bild, …) lesen und vom Modell zusammenfassen bzw. Aufgaben/Termine daraus anlegen lassen.
  /// Wirft `LlmError` wie `chatSend`; Lesefehler kommen als Assistenten-Nachricht zurück.
  func ingestFile(path: String) async throws -> [ChatMessage]
  /// Datei mit eigener Bitte ans Modell („mach daraus eine Mail“). Standard: wie ingestFile.
  func askAboutFile(path: String, request: String) async throws -> [ChatMessage]
  func answerWeeklyReview(_ answer: WeeklyReviewAnswer) async
  /// Wochenplanung jetzt zeigen (auch außerhalb des Termins).
  func openWeeklyReview() async
  func setWeeklyGoalDone(_ id: String, _ done: Bool) async -> ToolResult<WeeklyGoal>
  /// Installierte Apps (für „während Fokus ausblenden“), alphabetisch.
  func installedApps() async -> [AppInfo]
  /// Sprechen: Spracherkennung starten (Deutsch). `onText(text, final)` liefert Zwischenstände.
  /// Fehler (keine Freigabe, kein Mikrofon) als `.failure`.
  func startListening(_ onText: @escaping @MainActor (String, Bool) -> Void) async -> ToolResult<Empty>
  /// Stoppt und liefert den erkannten Text (leer, wenn nichts erkannt).
  func stopListening() async -> String

  // Paket 5: Mail (Apple Mail). Aktionen hier sind Klicks des Nutzers und
  // brauchen keine weitere Bestätigung; das Modell geht über Werkzeuge mit Bestätigung.
  /// Posteingang neu abrufen (fragt beim ersten Mal nach der Automations-Freigabe).
  func refreshMail() async -> ToolResult<MailOverview>
  /// Text einer Mail (nur zur Anzeige, wird nicht gespeichert).
  func mailBody(_ id: String) async -> ToolResult<String>
  func setMailRead(_ id: String, _ read: Bool) async -> ToolResult<Empty>
  func setMailFlagged(_ id: String, _ flagged: Bool) async -> ToolResult<Empty>
  /// In den Archiv-Ordner des Kontos verschieben.
  func archiveMail(_ id: String) async -> ToolResult<Empty>
  /// In den Papierkorb (nicht endgültig).
  func trashMail(_ id: String) async -> ToolResult<Empty>
  /// Aufgabe aus einer Mail ("Antworten: <Betreff>" bzw. vom Modell erkannte Aufgabe), Notiz mit Absender.
  func mailToTask(_ id: String) async -> ToolResult<TabyTask>
  /// Antwortentwurf vom Modell (bei mailLocalOnly nur mit Apple Intelligence). Wirft `LlmError`.
  func draftMailReply(_ id: String, instruction: String) async throws -> MailDraft
  /// Senden nach Klick in der Vorschau.
  func sendMail(_ draft: MailDraft) async -> ToolResult<Empty>

  // Paket 6: Netzwerk (nur wenn networkToolsEnabled; sonst `.failure("NETWORK_OFF")`).
  func refreshNetworkInfo() async -> ToolResult<NetworkInfo>
  /// Geräte im eigenen Netz finden (Ping-Durchlauf + ARP + Bonjour), dauert einige Sekunden.
  func scanNetwork() async -> ToolResult<[NetworkDevice]>
  /// Eigener Name und/oder „bekannt“ für ein Gerät (id = MAC oder IP).
  func updateNetworkDevice(_ id: String, name: String?, known: Bool?) async -> ToolResult<NetworkDevice>
  func ping(_ host: String) async -> ToolResult<PingResult>
  /// Nur private Adressen/.local; ports nil = gängige Ports.
  func checkPorts(_ host: String, ports: [Int]?) async -> ToolResult<[PortResult]>
  /// Apples networkQuality (dauert ~20 s, geht ins Internet).
  func speedTest() async -> ToolResult<SpeedResult>
  func wakeOnLan(mac: String) async -> ToolResult<Empty>
  func dnsLookup(_ name: String) async -> ToolResult<DnsResult>
  /// Öffentliche IP über ipify (nur auf Knopfdruck).
  func publicIP() async -> ToolResult<String>
  // Paket 9: Notion-Aufgaben importieren (read-only, kein Schreibzugriff auf Notion).
  /// Token im Schlüsselbund speichern; schaltet nichts automatisch ein.
  func connectNotionTasks(token: String) async -> ToolResult<Empty>
  /// Entfernt den Token und schaltet den Import aus.
  func disconnectNotionTasks() async
  /// Jetzt abgleichen (alle Quellen); liefert die Anzahl gefundener Notion-Einträge.
  func syncNotionTasks() async -> ToolResult<Int>
  /// OAuth-Alternative zum manuellen Token (z. B. für Gäste ohne eigenen Admin-Zugang):
  /// tauscht den Code aus der eingefügten Browser-Adresse (`https://notion-callback?code=…`) gegen ein Token.
  func completeNotionOAuth(code: String) async -> ToolResult<Empty>

  // Paket 12: Chat-Dienste ("Nachrichten").
  /// Meldet ein Chat-Konto an; das Geheimnis landet nur im Schlüsselbund.
  func connectMessenger(_ login: MessengerLogin) async -> ToolResult<MessengerAccount>
  /// Entsperrt verschlüsselte Chats (Element: Sicherheitsschlüssel).
  func unlockMessenger(_ accountId: String, recoveryKey: String) async -> ToolResult<Empty>
  func disconnectMessenger(_ accountId: String) async
  /// Letzte Nachrichten einer Unterhaltung (älteste zuerst).
  func messengerMessages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]>
  /// `replyTo`: Nachrichten-Id, auf die geantwortet wird (Element: bleibt im Thread der Nachricht; sonst ignoriert).
  func sendMessengerMessage(_ conversationId: String, text: String, replyTo: String?) async -> ToolResult<Empty>
  func markMessengerRead(_ conversationId: String) async
  /// Lumi von einem anderen eigenen Gerät bestätigen lassen (Element: Emoji-Vergleich).
  func startMessengerVerification(_ accountId: String) async -> ToolResult<Empty>
  /// Emojis stimmen überein (true) bzw. nicht (false → Abbruch).
  func answerMessengerVerification(_ accountId: String, matches: Bool) async -> ToolResult<Empty>
  func cancelMessengerVerification(_ accountId: String) async
  // Updates (docs/decisions/0011-self-update.md).
  /// Fragt die Update-Adresse; liefert die neuere Version oder nil (schon aktuell). Setzt `AppState.update`.
  /// Entfernte Kalender (ICS/Notion) sofort neu laden, Zwischenspeicher verwerfen.
  func refreshCalendars() async
  func checkForUpdate() async -> ToolResult<AppUpdate?>
  /// Lädt die neue DMG, startet den Austausch (App ersetzen, mit dem Zertifikat dieses Macs signieren,
  /// neu öffnen) in einem eigenen Prozess. Bei `.ok` beendet sich die Oberfläche danach selbst.
  func installUpdate() async -> ToolResult<Empty>
  // Paket 11: mehrere benannte Notion-Quellen (Tickets/To-dos/Weekly).
  func addNotionSource(name: String, category: NotionSourceCategory, link: String) async -> ToolResult<NotionSource>
  func updateNotionSource(_ id: String, name: String?, category: NotionSourceCategory?,
                          link: String?) async -> ToolResult<NotionSource>
  func removeNotionSource(_ id: String) async -> ToolResult<Empty>
  /// Quelle entfernen und wahlweise die daraus importierten Aufgaben löschen (Standard: behalten).
  func removeNotionSource(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty>
  // Paket 10: Tagesplan bearbeiten + Prioritätsliste (docs/decisions/0010-plan-editing.md).
  /// Tagesplan neu packen, aber in genau dieser Aufgaben-Reihenfolge (Nutzer hat verschoben/entfernt).
  /// Aufgaben-IDs, die nicht mehr offen oder unbekannt sind, werden ignoriert.
  func reorderPlan(taskIds: [String]) async -> ToolResult<DayPlan>
  /// Paket 13: Nutzer wählt Aufgaben für heute (mit fester Uhrzeit oder automatisch) und Dauer.
  /// Ersetzt den heutigen Plan; Einträge mit Uhrzeit werden angeheftet (`pinned`), die übrigen in
  /// freie Lücken gepackt. Erneut aufrufen zum Ändern.
  func planTasks(_ items: [PlanItem]) async -> ToolResult<DayPlan>
  /// Ersetzt die komplette Prioritätsliste (Reihenfolge = Priorität, höchste zuerst).
  func setTaskPriority(taskIds: [String]) async -> ToolResult<Empty>
  // Paket 7 (nur im eigenen Netz oder gegen eingetragene eigene Server):
  /// Gründlicher Scan (nmap, sonst eigener TCP-Scan). `deep` fragt nach Admin-Rechten.
  func deepScan(_ host: String, depth: ScanDepth) async -> ToolResult<ScanReport>
  /// Offene Verbindungen dieses Macs (lsof). Scannt nichts.
  func listConnections() async -> ToolResult<[Connection]>
  /// Eigene Server verwalten (erlauben Scans außerhalb des Heimnetzes).
  func addOwnServer(host: String, label: String) async -> ToolResult<OwnServer>
  func removeOwnServer(_ id: String) async -> ToolResult<Empty>
  /// Paket-Mitschnitt starten (fragt pro Mal nach Admin-Rechten). `filter`: tcpdump-Ausdruck, z. B. "port 80".
  func startCapture(interface: String?, filter: String) async -> ToolResult<CaptureState>
  func stopCapture() async -> ToolResult<CaptureState>
  /// Mitschnitt als .pcap speichern (für Wireshark); liefert den Pfad.
  func saveCapture(to folder: String?) async -> ToolResult<String>
  /// Verfügbare Netzwerkschnittstellen (en0, …) für die Auswahl.
  func captureInterfaces() async -> [String]

  /// Bestätigt bzw. verwirft eine vom Modell angefragte Lösch-Aktion.
  func confirmAction(_ id: String) async -> ToolResult<Empty>
  func rejectAction(_ id: String) async

  func agentsInstalled() async -> Bool
  func agentsInstall() async -> ToolResult<Empty>
  func agentsUninstall() async
  func resolveAgentRequest(_ id: String, _ decision: AgentPermissionDecision) async

  /// Registriert einen Empfänger für Kern-Ereignisse (auf dem MainActor).
  func subscribe(_ handler: @escaping @MainActor (AppEvent) -> Void)
}

extension TabyServices {
  public func musicStatus() async -> [MusicServiceStatus] { [] }
  public func musicBrowserDetection() async -> Bool { false }
  public func musicSetBrowserDetection(_ on: Bool) async {}
  public func musicRefreshNowPlaying() async {}
  public func exportBackup(to folder: String) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Export nicht verfügbar.")
  }
  public func importBackup(from path: String) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Import nicht verfügbar.")
  }
  public func lyrics(artist: String, title: String) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Liedtexte nicht verfügbar.")
  }
  public func musicSetClientId(_ service: MusicService, _ clientId: String) async {}
  public func musicConnect(_ service: MusicService) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Musik nicht verfügbar.")
  }
  public func musicDisconnect(_ service: MusicService) async {}
  public func musicSearch(_ service: MusicService, query: String) async -> ToolResult<[MusicItem]> {
    .failure(code: "UNSUPPORTED", error: "Musik nicht verfügbar.")
  }
  public func musicPlaylists(_ service: MusicService) async -> ToolResult<[MusicItem]> {
    .failure(code: "UNSUPPORTED", error: "Musik nicht verfügbar.")
  }
  public func musicPlay(_ item: MusicItem) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Musik nicht verfügbar.")
  }
  /// Vorgabe für Dienste ohne Fokus-Zeitplan (Vorschau, Prüfungen).
  public func startMeetingListening(_ id: String, mode: MeetingListenMode, consentGiven: Bool) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Mitschrift nicht verfügbar.")
  }
  public func stopMeetingListening() async {}
  public func markMeetingMoment() async {}
  public func extractMeetingActions(_ id: String) async -> ToolResult<[ActionCandidate]> {
    .failure(code: "UNSUPPORTED", error: "Aufgaben-Erkennung nicht verfügbar.")
  }
  public func acceptMeetingActions(_ id: String, _ items: [ActionCandidate]) async -> ToolResult<[TabyTask]> {
    .failure(code: "UNSUPPORTED", error: "Anlegen nicht verfügbar.")
  }
  public func explainText(_ text: String, speak: Bool) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Erklären nicht verfügbar.")
  }
  public func draftReply(_ text: String, signature: String) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Antwortentwurf nicht verfügbar.")
  }
  public func askAboutText(_ text: String, question: String, speak: Bool) async -> ToolResult<String> {
    .failure(code: "UNSUPPORTED", error: "Fragen zum Text nicht verfügbar.")
  }
  public func prepareMeeting(_ id: String, noteIds: [String], taskIds: [String]) async -> ToolResult<Note> {
    .failure(code: "UNSUPPORTED", error: "Termin-Vorbereitung nicht verfügbar.")
  }
  public func summarizeMeeting(_ id: String) async -> ToolResult<MeetingNotesResult> {
    .failure(code: "UNSUPPORTED", error: "Zusammenfassung nicht verfügbar.")
  }
  public func pauseFocus() async {}
  public func resumeFocus() async {}
  public func startBreak(minutes: Int) async -> ToolResult<FocusSession> {
    .failure(code: "UNSUPPORTED", error: "Pause nicht verfügbar.")
  }
  public func appleCalendars() async -> [AppleCalendarInfo] { [] }
  public func sendMessengerMessage(_ conversationId: String, text: String) async -> ToolResult<Empty> {
    await sendMessengerMessage(conversationId, text: text, replyTo: nil)
  }

  public func addNotionAccount(name: String, categoryId: String, token: String) async -> ToolResult<NotionAccount> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func updateNotionAccount(_ id: String, name: String?, categoryId: String?) async -> ToolResult<NotionAccount> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func setNotionAccountToken(_ id: String, token: String) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func removeNotionAccount(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func addNotionSource(name: String, category: NotionSourceCategory, link: String,
                              accountId: String) async -> ToolResult<NotionSource> {
    await addNotionSource(name: name, category: category, link: link)
  }

  public func mountShare(_ id: String) async -> ToolResult<Empty> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }
  public func unmountShare(_ id: String) async -> ToolResult<Empty> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }
  public func setSharePassword(_ id: String, password: String) async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func lookupSecret(query: String) async -> ToolResult<SecretLookup> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func startMicrosoftSignIn(includeTeams: Bool) async -> ToolResult<MicrosoftSignIn> {
    await startMicrosoftSignIn()
  }
  public func cancelMicrosoftSignIn() async {}
  public func startMicrosoftSignIn() async -> ToolResult<MicrosoftSignIn> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }
  public func finishMicrosoftSignIn() async -> ToolResult<String> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }
  public func disconnectMicrosoft() async -> ToolResult<Empty> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }

  public func addTaskFolder(name: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    await addTaskFolder(name: name)
  }
  public func setTaskFolderCategory(_ id: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.")
  }

  public func seedSampleDay() async -> ToolResult<Empty> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }
  public func removeSampleDay() async -> ToolResult<Empty> { .failure(code: "UNSUPPORTED", error: "Nicht verfügbar.") }

  public func saveVaultNote(title: String, content: String, append: Bool) async -> ToolResult<FileHit> {
    .failure(code: "NO_VAULT", error: "Kein Obsidian-Ordner verbunden.")
  }

  public func clearAudit() async -> ToolResult<Empty> {
    .failure(code: "UNSUPPORTED", error: "Löschen ist in dieser Ansicht nicht verfügbar.")
  }

  public func removeNotionSource(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty> {
    await removeNotionSource(id)
  }

  public func speakReply(_ text: String) async {}
  public func stopSpeaking() {}

  public func askAboutFile(path: String, request: String) async throws -> [ChatMessage] {
    try await ingestFile(path: path)
  }

  public func chatSendStreaming(_ text: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> [ChatMessage] {
    try await chatSend(text)
  }
}

/// Ergebnis von „Was jetzt?“.
public struct WhatNowPick: Codable, Equatable, Sendable {
  public var task: TabyTask
  /// Kurzer Grund, z. B. „überfällig seit Montag“ oder „fester Termin um 15:00“.
  public var reason: String
  public init(task: TabyTask, reason: String) { self.task = task; self.reason = reason }
}

/// Eine ausgeführte Werkzeug-Aktion fürs Audit-Protokoll.
public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// Lokale Zeit.
  public var at: String
  /// "Nutzer", "Modell", "Auftrag", "MCP", "Mod", "Skill".
  public var actor: String
  public var tool: String
  /// Kurze Beschreibung ohne Inhalte (z. B. „Aufgabe angelegt“), keine Texte aus Mails/Nachrichten.
  public var summary: String
  /// Nach Bestätigung des Nutzers ausgeführt.
  public var confirmed: Bool
  public var ok: Bool
  public init(id: String, at: String, actor: String, tool: String, summary: String, confirmed: Bool, ok: Bool) {
    self.id = id; self.at = at; self.actor = actor; self.tool = tool; self.summary = summary
    self.confirmed = confirmed; self.ok = ok
  }
}
