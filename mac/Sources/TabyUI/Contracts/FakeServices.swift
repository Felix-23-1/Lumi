// VERTRAG (nur Orchestrator ändert).
// Kern im Speicher für Vorschauen, Snapshots und UI-Prüfungen (Gegenstück zur
// Fake-Preload-API der Electron-Version). Keine echte Konfliktlogik, kein
// Modell: `chatSend` antwortet mit einem festen Text.
import Foundation
import TabyCore

@MainActor
public final class FakeServices: TabyServices {
  public var current: AppState
  private var handlers: [@MainActor (AppEvent) -> Void] = []
  private var agentsAreInstalled = false
  private var counter = 0
  /// Vorschau-Nachrichten je Unterhaltung (Paket 12).
  public var fakeMessengerMessages: [String: [MessengerMessage]] = [:]
  /// Vorschau-Protokoll; `clearAudit()` leert es.
  public var auditEntries: [AuditEntry] = [
    AuditEntry(id: "a1", at: "2026-10-18T09:00:00", actor: "Modell", tool: "add_task", summary: "Aufgabe angelegt", confirmed: false, ok: true)
  ]
  private let today: String

  /// `sample: true` füllt Beispieldaten (Aufgaben, Termine, Habits, Notizen, Chat).
  public init(sample: Bool = true, today: String = "2026-10-11") {
    self.today = today
    current = AppState()
    if sample { fillSample(); fillNotionSample() }
  }

  private func nextId(_ prefix: String) -> String {
    counter += 1
    return "\(prefix)-\(counter)"
  }

  private var now: String { "\(today)T09:00" }

  private func fillSample() {
    current.tasks = [
      TabyTask(id: nextId("t"), title: "Steuererklärung abschicken", due: "2026-10-09", createdAt: now, category: .privat),
      TabyTask(id: nextId("t"), title: "Zahnarzt anrufen", due: "\(today)T11:00", createdAt: now, category: .privat),
      TabyTask(id: nextId("t"), title: "Präsentation üben", due: today, createdAt: now, category: .arbeit),
      TabyTask(id: nextId("t"), title: "Milch kaufen", done: true, doneAt: now, createdAt: now),
    ]
    current.vaultNoteCount = 12
    current.notes = [
      Note(id: nextId("n"), title: "Ideen für Lumi", content: "Wetter im Briefing, Fokus-Timer, Spotify", createdAt: now,
           updatedAt: now),
      Note(id: nextId("n"), title: "Einkaufsliste", content: "Kaffee, Hafermilch, Äpfel", createdAt: now, updatedAt: now),
    ]
    current.habits = [
      Habit(id: nextId("h"), name: "Lesen", createdAt: now, streak: 6, checkedToday: true),
      Habit(id: nextId("h"), name: "Sport", createdAt: now, streak: 2),
      Habit(id: nextId("h"), name: "Wasser trinken", createdAt: now, streak: 12),
    ]
    let events = [
      CalendarEvent(id: nextId("e"), sourceId: "local", title: "Standup", start: "\(today)T09:30", end: "\(today)T09:45"),
      CalendarEvent(id: nextId("e"), sourceId: "apple", title: "Mittag mit Lena", start: "\(today)T12:30",
                    end: "\(today)T13:30"),
      CalendarEvent(id: nextId("e"), sourceId: "notion:team", title: "Design-Review", start: "\(today)T15:00",
                    end: "\(today)T16:00"),
    ]
    current.messages = [
      ChatMessage(role: .user, content: "Was steht heute an?"),
      ChatMessage(role: .assistant, content: "Drei Termine, zwei Aufgaben – und die Steuererklärung ist überfällig."),
    ]
    current.calendarSources = [
      CalendarSourceConfig(id: "local", kind: .local, isDefaultWrite: true),
      CalendarSourceConfig(id: "apple", kind: .apple),
    ]
    current.settings.llmModel = "anthropic/claude-sonnet-4.5"
    current.settings.hasApiKey = true
    current.usage = UsageSummary(todayUsd: 0.042, monthUsd: 1.37, todayTokens: 18_400, monthTokens: 612_000)
    current.memories = [
      Memory(id: nextId("m"), text: "Zahnarzt ist Dr. Weber, Tel. 0221 123456", createdAt: now),
      Memory(id: nextId("m"), text: "Arbeitet am liebsten morgens konzentriert", createdAt: now),
    ]
    current.focusMinutesToday = 50
    current.islandMessage = IslandMessage(text: "Deadline: noch 3 Tage", until: "\(today)T23:59", modId: "countdown")
    current.appleIntelligenceAvailable = true
    current.mods = [
      ModInfo(manifest: ModManifest(id: "fokus-an", name: "Fokus an", description: "Schaltet Nicht stören ein",
                                    kind: .shortcut, shortcutName: "Fokus an", triggers: [.focusStarted]),
              enabled: true, approved: true, lastRunAt: "\(today)T08:55"),
      ModInfo(manifest: ModManifest(id: "wetter", name: "Wetter", description: "Wetter für das Briefing",
                                    kind: .script, entry: "main.js",
                                    tool: ModTool(description: "Liefert das Wetter für heute"),
                                    permissions: ["http:api.open-meteo.com"]),
              code: "async function run(input) {\n  const r = await taby.http.get(\"https://api.open-meteo.com/v1/forecast?latitude=50.9&longitude=6.9&current=temperature_2m\")\n  return r\n}"),
    ]
    recomputeOverview(events: events)
  }

  private func recomputeOverview(events: [CalendarEvent]? = nil) {
    let open = current.tasks.filter { !$0.done }
    current.overview.overdueTasks = open.filter { ($0.due.map { LocalTime.datePart($0) } ?? "9999") < today }
    current.overview.todayTasks = open.filter { $0.due.map { LocalTime.datePart($0) } == today }
    current.overview.upcomingTasks = open.filter { ($0.due.map { LocalTime.datePart($0) } ?? "") > today }
    current.overview.habitsToday = current.habits.filter { !$0.checkedToday }
    if let events { current.overview.eventsToday = events }
  }

  private func changed() {
    recomputeOverview()
    for h in handlers { h(.stateChanged) }
  }

  /// Für Vorschauen/Prüfungen: ein Kern-Ereignis auslösen.
  public func emit(_ event: AppEvent) {
    for h in handlers { h(event) }
  }

  // MARK: - TabyServices

  public func state() async -> AppState { current }

  public func chatSend(_ text: String) async throws -> [ChatMessage] {
    let user = ChatMessage(role: .user, content: text)
    let reply = ChatMessage(role: .assistant, content: "(Vorschau) Verstanden: \(text)")
    current.messages += [user, reply]
    changed()
    return [user, reply]
  }

  public func quickCapture(_ text: String) async throws -> [ChatMessage] {
    let t = TabyTask(id: nextId("t"), title: text, createdAt: now)
    current.tasks.append(t)
    let reply = ChatMessage(role: .assistant, content: "Aufgabe angelegt: \(text)")
    current.messages.append(reply)
    changed()
    return [reply]
  }

  public func appleReminderLists() async -> ToolResult<[ReminderListInfo]> {
    .ok([ReminderListInfo(id: "r1", title: "Erinnerungen"), ReminderListInfo(id: "r2", title: "Einkauf")])
  }

  public func syncAppleReminders() async -> ToolResult<Empty> { .ok(Empty()) }

  public func chatClear() async {
    current.messages = []
    changed()
  }

  public func updateSettings(_ patch: SettingsPatch, apiKey: String?) async -> TabySettings {
    var s = current.settings
    if let v = patch.llmBaseUrl { s.llmBaseUrl = v }
    if let v = patch.llmModel { s.llmModel = v }
    if let v = patch.personality { s.personality = v }
    if let v = patch.customInstructions { s.customInstructions = v }
    if let v = patch.reminderLeadMinutes { s.reminderLeadMinutes = v }
    if let v = patch.startOnLogin { s.startOnLogin = v }
    if let v = patch.globalShortcut { s.globalShortcut = v }
    if let v = patch.askAfterUnlock { s.askAfterUnlock = v }
    if let v = patch.tabOrder { s.tabOrder = v }
    if let v = patch.hiddenTabs { s.hiddenTabs = v }
    if let v = patch.workHours { s.workHours = v }
    if let v = patch.taskCategories { s.taskCategories = v }
    if let v = patch.hiddenTickerKinds { s.hiddenTickerKinds = v }
    if let v = patch.messengerEnabled { s.messengerEnabled = v }
    if let v = patch.notchText { s.notchText = v }
    if let v = patch.captureContextShortcut { s.captureContextShortcut = v }
    if let v = patch.explainShortcut { s.explainShortcut = v }
    if let v = patch.circleShortcut { s.circleShortcut = v }
    if let v = patch.notionStatusMap { s.notionStatusMap = v }
    if let v = patch.autoStatus { s.autoStatus = v }
    if let v = patch.privateListId { s.privateListId = v }
    if let v = patch.localOnly { s.localOnly = v }
    if let v = patch.cloudConsentAt { s.cloudConsentAt = v }
    if let v = patch.chatHistoryDays { s.chatHistoryDays = v }
    if let v = patch.backupRetentionDays { s.backupRetentionDays = v }
    if let v = patch.auditRetentionDays { s.auditRetentionDays = v }
    if let v = patch.mcpServers { s.mcpServers = v }
    if let v = patch.markdownVaultPath { s.markdownVaultPath = v }
    if let v = patch.vaultWriteFolder { s.vaultWriteFolder = v }
    if let v = patch.networkShares { s.networkShares = v }
    if let v = patch.notionAccounts { s.notionAccounts = v }
    if let v = patch.microsoftClientId { s.microsoftClientId = v }
    if let v = patch.microsoftAccount { s.microsoftAccount = v }
    if let v = patch.mailBackend { s.mailBackend = v }
    if let v = patch.imapHost { s.imapHost = v }
    if let v = patch.imapUser { s.imapUser = v }
    if let v = patch.homeCity { s.homeCity = v }
    if let v = patch.updateSource { s.updateSource = v }
    if let v = patch.notchCountdown { s.notchCountdown = v }
    if let apiKey { s.hasApiKey = !apiKey.isEmpty }
    current.settings = s
    changed()
    return s
  }

  public func listModels() async -> ToolResult<[String]> {
    .ok(["anthropic/claude-sonnet-4.5", "openai/gpt-5", "google/gemini-2.5-pro"])
  }

  public func testLlm() async -> LlmTestResult {
    LlmTestResult(ok: current.settings.hasApiKey, message: current.settings.hasApiKey ? "Verbindung ok." : "Kein Schlüssel.")
  }

  public func answerDayStart(_ answer: DayStartAnswer) async {
    current.dayStartPrompt = false
    current.dayStartState = answer == .yes ? .done : answer == .later ? .snoozed : .skipped
    changed()
  }

  public func acknowledgeMissed(_ reminderIds: [String]) async {
    current.overview.missed.removeAll { reminderIds.contains($0.id) }
    changed()
  }

  public func appleCalendars() async -> [AppleCalendarInfo] {
    [AppleCalendarInfo(id: "a", title: "Privat", account: "iCloud"), AppleCalendarInfo(id: "b", title: "Arbeit", account: "iCloud"),
     AppleCalendarInfo(id: "c", title: "Geburtstage", account: "iCloud")]
  }

  public func upsertCalendarSource(_ draft: CalendarSourceDraft) async -> ToolResult<CalendarSourceConfig> {
    if let id = draft.id, let i = current.calendarSources.firstIndex(where: { $0.id == id }) {
      var s = current.calendarSources[i]
      if let c = draft.config { s.config = c }
      if let e = draft.enabled { s.enabled = e }
      if let d = draft.isDefaultWrite { s.isDefaultWrite = d }
      current.calendarSources[i] = s
      changed()
      return .ok(s)
    }
    let s = CalendarSourceConfig(id: nextId(draft.kind.rawValue), kind: draft.kind, config: draft.config ?? [:],
                                 enabled: draft.enabled ?? true, isDefaultWrite: draft.isDefaultWrite ?? false)
    current.calendarSources.append(s)
    changed()
    return .ok(s)
  }

  public func calendarHealthCheck(_ id: String) async -> HealthResult { HealthResult(ok: true) }

  public func addTask(title: String, notes: String?, due: String?) async -> ToolResult<TabyTask> {
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
      return .failure(code: "INVALID", error: "Titel fehlt.")
    }
    let t = TabyTask(id: nextId("t"), title: title, notes: notes, due: due, createdAt: now)
    current.tasks.append(t)
    changed()
    return .ok(t)
  }

  private func mutateTask(_ id: String, _ f: (inout TabyTask) -> Void) -> ToolResult<TabyTask> {
    guard let i = current.tasks.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Aufgabe nicht gefunden.")
    }
    f(&current.tasks[i])
    changed()
    return .ok(current.tasks[i])
  }

  public func updateTask(_ id: String, _ patch: TaskPatch) async -> ToolResult<TabyTask> {
    mutateTask(id) { t in
      if let v = patch.title { t.title = v }
      if let v = patch.notes { t.notes = v }
      if let v = patch.due { t.due = v }
      if let v = patch.category { t.category = v.isEmpty ? nil : TaskCategory(rawValue: v) }
      if let v = patch.folderId { t.folderId = v.isEmpty ? nil : v }
      if let v = patch.recurrence { t.recurrence = v.isEmpty ? nil : TaskRecurrence(rawValue: v) }
      if let v = patch.minutes { t.minutes = v > 0 ? v : nil }
      if let v = patch.tags { t.tags = TagRules.normalize(v) }
      if let v = patch.status { t.status = v.isEmpty ? .open : (TaskStatus(rawValue: v) ?? t.status) }
      if let v = patch.priority { t.priority = v.isEmpty ? .none : (TaskPriority(rawValue: v) ?? t.priority) }
    }
  }

  public func addTaskFolder(name: String) async -> ToolResult<TaskFolder> {
    await addTaskFolder(name: name, categoryId: nil)
  }

  public func setTaskFolderCategory(_ id: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    guard let i = current.taskFolders.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
    }
    current.taskFolders[i].categoryId = (categoryId ?? "").isEmpty ? nil : categoryId
    changed()
    return .ok(current.taskFolders[i])
  }

  public func addTaskFolder(name: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty, n.count <= 60 else { return .failure(code: "INVALID", error: "Ordnername fehlt oder ist zu lang.") }
    guard !current.taskFolders.contains(where: { $0.name.lowercased() == n.lowercased() }) else {
      return .failure(code: "EXISTS", error: "Diesen Ordner gibt es schon.")
    }
    let f = TaskFolder(id: nextId("f"), name: n, createdAt: now, categoryId: (categoryId ?? "").isEmpty ? nil : categoryId)
    current.taskFolders.append(f)
    current.taskFolders.sort { $0.name.lowercased() < $1.name.lowercased() }
    changed()
    return .ok(f)
  }

  public func renameTaskFolder(_ id: String, name: String) async -> ToolResult<TaskFolder> {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty, n.count <= 60 else { return .failure(code: "INVALID", error: "Ordnername fehlt oder ist zu lang.") }
    guard let i = current.taskFolders.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
    }
    current.taskFolders[i].name = n
    changed()
    return .ok(current.taskFolders[i])
  }

  public func deleteTaskFolder(_ id: String) async -> ToolResult<Empty> {
    current.taskFolders.removeAll { $0.id == id }
    for i in current.tasks.indices where current.tasks[i].folderId == id { current.tasks[i].folderId = nil }
    changed()
    return .ok(Empty())
  }

  public func completeTask(_ id: String) async -> ToolResult<TabyTask> {
    mutateTask(id) { $0.done = true; $0.doneAt = self.now }
  }

  public func reopenTask(_ id: String) async -> ToolResult<TabyTask> {
    mutateTask(id) { $0.done = false; $0.doneAt = nil }
  }

  public func deleteTask(_ id: String) async -> ToolResult<Empty> {
    current.tasks.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func addNote(title: String, content: String) async -> ToolResult<Note> {
    let n = Note(id: nextId("n"), title: title, content: content, createdAt: now, updatedAt: now)
    current.notes.insert(n, at: 0)
    changed()
    return .ok(n)
  }

  public func updateNote(_ id: String, _ patch: NotePatch) async -> ToolResult<Note> {
    guard let i = current.notes.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notiz nicht gefunden.")
    }
    if let v = patch.title { current.notes[i].title = v }
    if let v = patch.content { current.notes[i].content = v }
    if let v = patch.taskId { current.notes[i].taskId = v.isEmpty ? nil : v }
    if let v = patch.tags { current.notes[i].tags = TagRules.normalize(v) }
    current.notes[i].updatedAt = now
    changed()
    return .ok(current.notes[i])
  }

  public func deleteNote(_ id: String) async -> ToolResult<Empty> {
    current.notes.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func addHabit(name: String, description: String?) async -> ToolResult<Habit> {
    let h = Habit(id: nextId("h"), name: name, description: description, createdAt: now)
    current.habits.append(h)
    changed()
    return .ok(h)
  }

  public func checkHabit(_ id: String, date: String) async -> ToolResult<Habit> {
    guard let i = current.habits.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Habit nicht gefunden.")
    }
    if !current.habits[i].checkedToday {
      current.habits[i].checkedToday = true
      current.habits[i].streak += 1
    }
    changed()
    return .ok(current.habits[i])
  }

  public func deleteHabit(_ id: String) async -> ToolResult<Empty> {
    current.habits.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func addEvent(_ req: AddEventRequest) async -> AddEventResult {
    let e = CalendarEvent(id: nextId("e"), sourceId: "local", title: req.event.title, start: req.event.start,
                          end: req.event.end, notes: req.event.notes)
    current.overview.eventsToday.append(e)
    changed()
    return .ok(event: e, info: [], unreachable: [])
  }

  public func listEvents(from: String, to: String) async -> [CalendarEvent] {
    current.overview.eventsToday + current.overview.eventsUpcoming
  }

  public func deleteEvent(id: String, sourceId: String) async -> ToolResult<Empty> {
    let before = current.overview.eventsToday.count + current.overview.eventsUpcoming.count
    current.overview.eventsToday.removeAll { $0.id == id }
    current.overview.eventsUpcoming.removeAll { $0.id == id }
    changed()
    let after = current.overview.eventsToday.count + current.overview.eventsUpcoming.count
    return after < before ? .ok(Empty()) : .failure(code: "NOT_FOUND", error: "Termin nicht gefunden.")
  }

  public func scheduleJob(_ req: ScheduleJobRequest) async -> ToolResult<Job> {
    let j = Job(id: nextId("j"), name: req.name, prompt: req.prompt, rule: req.rule, createdAt: now)
    current.jobs.append(j)
    changed()
    return .ok(j)
  }

  public func cancelJob(_ id: String) async -> ToolResult<Empty> {
    current.jobs.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func confirmAction(_ id: String) async -> ToolResult<Empty> {
    current.pendingConfirmations.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func rejectAction(_ id: String) async {
    current.pendingConfirmations.removeAll { $0.id == id }
    changed()
  }

  // MARK: Einrichtung

  public func requestPermission(_ kind: PermissionKind) async -> Bool { true }

  // MARK: Sprache

  public func availableVoices() async -> [VoiceInfo] {
    [VoiceInfo(id: "de.anna.premium", name: "Anna", quality: "Premium"),
     VoiceInfo(id: "de.markus", name: "Markus", quality: "Erweitert"),
     VoiceInfo(id: "de.flo", name: "Flo", quality: "Standard")]
  }
  public func previewVoice(_ id: String?) async {}
  public func stopSpeaking() async {}
  public func speakOverview() async {}
  public func explainText(_ text: String, speak: Bool) async -> ToolResult<String> {
    .ok("Vorschau: Lumi erklärt „\(text)“ in wenigen Sätzen.")
  }
  public func draftReply(_ text: String, signature: String) async -> ToolResult<String> {
    .ok("Guten Tag,\n\nvielen Dank für Ihre Nachricht. Vorschau-Entwurf zu „\(text)“.\n\n\(signature.isEmpty ? "Freundliche Grüße" : signature)")
  }
  public func askAboutText(_ text: String, question: String, speak: Bool) async -> ToolResult<String> {
    .ok("Vorschau: Antwort auf „\(question.isEmpty ? "Erkläre" : question)“ zu „\(text)“.")
  }

  // MARK: Paket 3

  public func listShortcuts() async -> ToolResult<[String]> { .ok(["Fokus an", "Licht dimmen", "Playlist Arbeit"]) }

  public func createShortcutMod(shortcutName: String, description: String, asTool: Bool,
                                triggers: [ModTrigger]) async -> ToolResult<ModInfo> {
    let id = shortcutName.lowercased().replacingOccurrences(of: " ", with: "-")
    let m = ModInfo(manifest: ModManifest(id: id, name: shortcutName, description: description, kind: .shortcut,
                                          shortcutName: shortcutName,
                                          tool: asTool ? ModTool(description: description) : nil, triggers: triggers))
    current.mods.append(m)
    changed()
    return .ok(m)
  }

  public func setModSetting(_ id: String, key: String, value: String) async -> ToolResult<ModInfo> {
    guard let i = current.mods.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mod nicht gefunden.")
    }
    current.mods[i].settingValues[key] = value
    changed()
    return .ok(current.mods[i])
  }

  public func runSkill(_ id: String, input: String) async throws -> [ChatMessage] {
    let reply = ChatMessage(role: .assistant, content: "Skill „\(id)“ ausgeführt.")
    current.messages.append(reply)
    changed()
    return [reply]
  }

  public func setModEnabled(_ id: String, _ enabled: Bool) async -> ToolResult<ModInfo> {
    guard let i = current.mods.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mod nicht gefunden.")
    }
    current.mods[i].enabled = enabled
    if enabled { current.mods[i].approved = true }
    changed()
    return .ok(current.mods[i])
  }

  public func deleteMod(_ id: String) async -> ToolResult<Empty> {
    current.mods.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func runMod(_ id: String, input: String?) async -> ToolResult<String> { .ok("(Vorschau) Mod \(id) ausgeführt.") }
  public func exportMod(_ id: String, to folder: String) async -> ToolResult<String> { .ok("\(folder)/\(id).tabymod") }
  public func importMod(from path: String) async -> ToolResult<ModInfo> {
    .failure(code: "PREVIEW", error: "In der Vorschau nicht verfügbar.")
  }

  public func modCatalog() async -> [CatalogMod] { ModCatalog.entries }

  // Paket 12: Chat-Dienste (Vorschau: ein Konto mit festen Unterhaltungen).
  public func connectMessenger(_ login: MessengerLogin) async -> ToolResult<MessengerAccount> {
    let a = MessengerAccount(id: nextId("acc"), service: login.service, server: login.server, user: login.user)
    current.messengerAccounts.append(a)
    changed(); return .ok(a)
  }
  public func unlockMessenger(_ accountId: String, recoveryKey: String) async -> ToolResult<Empty> {
    guard let i = current.messengerAccounts.firstIndex(where: { $0.id == accountId }) else {
      return .failure(code: "NOT_FOUND", error: "Konto nicht gefunden.")
    }
    current.messengerAccounts[i].status = .connected
    changed(); return .ok(Empty())
  }
  public func disconnectMessenger(_ accountId: String) async {
    current.messengerAccounts.removeAll { $0.id == accountId }
    current.messengerConversations.removeAll { $0.accountId == accountId }
    changed()
  }
  public func messengerMessages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]> {
    .ok(fakeMessengerMessages[conversationId] ?? [])
  }
  public func sendMessengerMessage(_ conversationId: String, text: String, replyTo: String?) async -> ToolResult<Empty> {
    let m = MessengerMessage(id: nextId("msg"), conversationId: conversationId, sender: "Ich", text: text, at: now, mine: true)
    fakeMessengerMessages[conversationId, default: []].append(m)
    if let i = current.messengerConversations.firstIndex(where: { $0.id == conversationId }) {
      current.messengerConversations[i].lastText = text
      current.messengerConversations[i].lastAt = now
    }
    changed(); return .ok(Empty())
  }
  public func startMessengerVerification(_ accountId: String) async -> ToolResult<Empty> {
    current.messengerVerification = MessengerVerification(accountId: accountId, phase: .showEmojis, emojis: [
      MessengerEmoji(symbol: "🐶", name: "Hund"), MessengerEmoji(symbol: "🔑", name: "Schlüssel"),
      MessengerEmoji(symbol: "🌍", name: "Weltkugel"), MessengerEmoji(symbol: "🎸", name: "Gitarre"),
      MessengerEmoji(symbol: "☂️", name: "Regenschirm"), MessengerEmoji(symbol: "🚀", name: "Rakete"),
      MessengerEmoji(symbol: "🍎", name: "Apfel")])
    changed(); return .ok(Empty())
  }
  public func answerMessengerVerification(_ accountId: String, matches: Bool) async -> ToolResult<Empty> {
    current.messengerVerification = MessengerVerification(accountId: accountId, phase: matches ? .done : .cancelled)
    if matches, let i = current.messengerAccounts.firstIndex(where: { $0.id == accountId }) {
      current.messengerAccounts[i].status = .connected
    }
    changed(); return .ok(Empty())
  }
  public func cancelMessengerVerification(_ accountId: String) async {
    current.messengerVerification = nil
    changed()
  }

  public func refreshCalendars() async { changed() }

  public func startTimer(minutes: Int, label: String) async -> ToolResult<TabyTimer> {
    guard (1...720).contains(minutes) else { return .failure(code: "INVALID", error: "1 bis 720 Minuten.") }
    let t = TabyTimer(id: nextId("w"), label: label.isEmpty ? "Timer" : label, endsAt: now)
    current.timers.append(t)
    changed()
    return .ok(t)
  }

  public func cancelTimer(_ id: String) async {
    current.timers.removeAll { $0.id == id }
    changed()
  }

  public func mediaControl(_ command: MediaCommand) async -> ToolResult<Empty> {
    if command == .playPause, var p = current.nowPlaying { p.playing.toggle(); current.nowPlaying = p; changed() }
    return .ok(Empty())
  }

  // MARK: Musik (vorbelegt: Spotify verbunden, Apple Musik lokal, YouTube/Amazon öffnen nur)

  /// Schalter für Prüfungen: Spotify angemeldet, und ob Anmelden scheitert.
  public var musicSpotifyConnected = true
  public var musicConnectError: String?
  public private(set) var musicClientId = ""
  /// Zähler je Aktion („status", „connect", „search", „playlists", „play", „disconnect", „setClientId").
  public private(set) var musicCallCount: [String: Int] = [:]
  public private(set) var musicLastPlayed: MusicItem?

  private func musicCount(_ key: String) { musicCallCount[key, default: 0] += 1 }

  private var musicSpotifyHits: [MusicItem] {
    [MusicItem(id: "spotify:track:1", service: .spotify, kind: .track, title: "Nachtfahrt", subtitle: "Lumen Trio"),
     MusicItem(id: "spotify:track:2", service: .spotify, kind: .track, title: "Sommerregen", subtitle: "Mira Vale"),
     MusicItem(id: "spotify:album:1", service: .spotify, kind: .album, title: "Leise Stadt", subtitle: "Mira Vale"),
     MusicItem(id: "spotify:playlist:1", service: .spotify, kind: .playlist, title: "Fokus Mix", subtitle: "Taby")]
  }

  private var musicSpotifyPlaylists: [MusicItem] {
    ["Morgenmusik", "Konzentration", "Sonntag"].map {
      MusicItem(id: "spotify:playlist:\($0)", service: .spotify, kind: .playlist, title: $0, subtitle: "Spotify")
    }
  }

  private var musicApplePlaylists: [MusicItem] {
    ["Lieblingssongs", "Joggen", "Abend"].map {
      MusicItem(id: $0, service: .appleMusic, kind: .playlist, title: $0, subtitle: "Mediathek")
    }
  }

  private func musicWebHit(_ service: MusicService, _ query: String) -> [MusicItem] {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let base = service == .youtubeMusic ? "https://music.youtube.com/search?q=" : "https://music.amazon.de/search/"
    return [MusicItem(id: base + q, service: service, kind: .track, title: "Suche: \(query)",
                      subtitle: service.title)]
  }

  public func musicStatus() async -> [MusicServiceStatus] {
    musicCount("status")
    return [
      MusicServiceStatus(service: .spotify, connected: musicSpotifyConnected, canSearch: true, canListPlaylists: true,
                         canControl: true, clientId: musicClientId,
                         note: "Suche und Wiedergabe brauchen Spotify Premium."),
      MusicServiceStatus(service: .appleMusic, connected: true, canSearch: false, canListPlaylists: true,
                         canControl: true, note: "Lokale Bibliothek der Musik-App."),
      MusicServiceStatus(service: .youtube, connected: true, canSearch: true, canListPlaylists: false,
                         canControl: false, note: "Nur Öffnen im Browser."),
      MusicServiceStatus(service: .youtubeMusic, connected: true, canSearch: true, canListPlaylists: false,
                         canControl: false, note: "Nur Öffnen im Browser."),
      MusicServiceStatus(service: .amazonMusic, connected: true, canSearch: true, canListPlaylists: false,
                         canControl: false, note: "Nur Öffnen im Browser."),
    ]
  }

  public func musicSetClientId(_ service: MusicService, _ clientId: String) async {
    musicCount("setClientId")
    if service == .spotify { musicClientId = clientId }
  }

  public func musicConnect(_ service: MusicService) async -> ToolResult<Empty> {
    musicCount("connect")
    guard service == .spotify else { return .ok(Empty()) }
    if let e = musicConnectError { return .failure(code: "AUTH", error: e) }
    guard !musicClientId.isEmpty else { return .failure(code: "AUTH", error: "Client-ID fehlt.") }
    musicSpotifyConnected = true
    return .ok(Empty())
  }

  public func musicDisconnect(_ service: MusicService) async {
    musicCount("disconnect")
    if service == .spotify { musicSpotifyConnected = false }
  }

  public func musicSearch(_ service: MusicService, query: String) async -> ToolResult<[MusicItem]> {
    musicCount("search")
    switch service {
    case .spotify:
      guard musicSpotifyConnected else { return .failure(code: "AUTH", error: "Nicht mit Spotify verbunden.") }
      return .ok(musicSpotifyHits)
    case .youtube, .youtubeMusic, .amazonMusic:
      return .ok(musicWebHit(service, query))
    case .appleMusic:
      return .failure(code: "UNSUPPORTED", error: "Apple Musik hat keine Katalogsuche. Playlists nutzen.")
    }
  }

  public func musicPlaylists(_ service: MusicService) async -> ToolResult<[MusicItem]> {
    musicCount("playlists")
    switch service {
    case .spotify:
      guard musicSpotifyConnected else { return .failure(code: "AUTH", error: "Nicht mit Spotify verbunden.") }
      return .ok(musicSpotifyPlaylists)
    case .appleMusic: return .ok(musicApplePlaylists)
    case .youtube, .youtubeMusic, .amazonMusic: return .ok([])
    }
  }

  public func musicPlay(_ item: MusicItem) async -> ToolResult<Empty> {
    musicCount("play")
    if item.service == .spotify && !musicSpotifyConnected {
      return .failure(code: "AUTH", error: "Nicht mit Spotify verbunden.")
    }
    musicLastPlayed = item
    return .ok(Empty())
  }

  public func search(_ query: String) async -> [SearchHit] {
    let q = query.lowercased()
    guard !q.isEmpty else { return [] }
    let tasks = current.tasks.filter { $0.title.lowercased().contains(q) }
      .map { SearchHit(id: $0.id, kind: .task, title: $0.title, date: $0.due) }
    let notes = current.notes.filter { $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q) }
      .map { SearchHit(id: $0.id, kind: .note, title: $0.title) }
    return Array((tasks + notes).prefix(30))
  }

  public func undoLast() async -> ToolResult<String> {
    guard let label = current.undoLabel else { return .failure(code: "NOTHING", error: "Nichts zum Rückgängigmachen.") }
    current.undoLabel = nil
    changed()
    return .ok(label)
  }

  public func findContacts(_ query: String) async -> [ContactCard] {
    let q = query.lowercased()
    return [ContactCard(id: "c1", name: "Anna Beispiel", organization: "Muster GmbH", emails: ["anna@example.com"],
                        phones: ["+49 30 1234567"], birthday: "10-15")]
      .filter { q.isEmpty || $0.name.lowercased().contains(q) }
  }

  /// Vorschau: schreibt nichts, gibt eine Beispieldatei im Unterordner zurück und zählt sie mit.
  public func saveVaultNote(title: String, content: String, append: Bool) async -> ToolResult<FileHit> {
    current.vaultNoteCount += append ? 0 : 1
    changed()
    return .ok(FileHit(path: "/Vault/Lumi/\(title).md", name: "\(title).md", modifiedAt: today, kind: "Markdown-Notiz"))
  }

  public func findFiles(_ query: String) async -> [FileHit] {
    query.isEmpty ? [] : [FileHit(path: "/Users/ich/Documents/Angebot.pdf", name: "Angebot.pdf",
                                  modifiedAt: "2026-10-14T16:20", kind: "PDF-Dokument")]
  }

  public func summarizeFile(_ path: String) async -> ToolResult<String> {
    .failure(code: "PREVIEW", error: "In der Vorschau gibt es keine Zusammenfassung.")
  }

  public func captureContext() async -> ToolResult<CapturedContext> {
    .ok(CapturedContext(app: "Safari", title: "Beispielseite", url: "https://example.com"))
  }

  public func saveCapture(_ context: CapturedContext, as target: CaptureTarget) async -> ToolResult<Empty> {
    if target == .task { _ = await addTask(title: context.title, notes: context.url, due: nil) }
    else { _ = await addNote(title: context.title, content: [context.url, context.text].compactMap { $0 }.joined(separator: "\n")) }
    return .ok(Empty())
  }

  public func markInboxDone(_ id: String) async {
    current.inbox.removeAll { $0.id == id }
    changed()
  }

  public func draftReply(_ id: String) async -> ToolResult<Empty> { .ok(Empty()) }

  public func draftMeetingFollowUp(eventId: String) async -> ToolResult<Empty> { .ok(Empty()) }

  public func exportDiagnostics(to folder: String?) async -> ToolResult<String> { .ok("/tmp/Lumi-Diagnose.zip") }

  public func listAudit(limit: Int) async -> [AuditEntry] {
    Array(auditEntries.prefix(max(0, limit)))
  }

  public func clearAudit() async -> ToolResult<Empty> {
    auditEntries = []
    return .ok(Empty())
  }

  public func mountShare(_ id: String) async -> ToolResult<Empty> {
    current.shareStates[id] = ShareState(mounted: true, mountPath: "/Volumes/Dokumente")
    changed()
    return .ok(Empty())
  }

  public func unmountShare(_ id: String) async -> ToolResult<Empty> {
    current.shareStates[id] = ShareState()
    changed()
    return .ok(Empty())
  }

  public func setSharePassword(_ id: String, password: String) async -> ToolResult<Empty> { .ok(Empty()) }

  public func lookupSecret(query: String) async -> ToolResult<SecretLookup> {
    .ok(SecretLookup(source: "router.md", line: 3, copied: true))
  }

  public func testMCPServer(_ config: MCPServerConfig) async -> ToolResult<[String]> { .ok(["search", "read_page"]) }

  public func whatNow() async -> ToolResult<WhatNowPick> {
    guard let t = current.tasks.first(where: { !$0.done }) else {
      return .failure(code: "EMPTY", error: "Nichts offen – genieß die Pause.")
    }
    return .ok(WhatNowPick(task: t, reason: "Als Nächstes dran"))
  }

  public func listBackups() async -> [BackupInfo] {
    [BackupInfo(name: "taby-2026-10-15-0830.sqlite", createdAt: "2026-10-15T08:30", sizeBytes: 524_288)]
  }

  public func restoreBackup(_ name: String) async -> ToolResult<Empty> {
    .failure(code: "PREVIEW", error: "In der Vorschau gibt es keine Sicherungen.")
  }

  public func exportBackup(to folder: String) async -> ToolResult<String> {
    .failure(code: "PREVIEW", error: "In der Vorschau gibt es keinen Export.")
  }

  public func importBackup(from path: String) async -> ToolResult<String> {
    .failure(code: "PREVIEW", error: "In der Vorschau gibt es keinen Import.")
  }

  public func lyrics(artist: String, title: String) async -> ToolResult<String> {
    .ok("Erste Zeile des Beispieltextes\nZweite Zeile des Beispieltextes\n\nRefrain, Zeile eins\nRefrain, Zeile zwei\n\nStrophe, Zeile eins\nStrophe, Zeile zwei")
  }

  public func checkForUpdate() async -> ToolResult<AppUpdate?> {
    .ok(current.update)
  }

  public func installUpdate() async -> ToolResult<Empty> {
    .failure(code: "UPDATE", error: "In der Vorschau gibt es keine Updates.")
  }

  public func markMessengerRead(_ conversationId: String) async {
    if let i = current.messengerConversations.firstIndex(where: { $0.id == conversationId }) {
      current.messengerConversations[i].unread = 0
      changed()
    }
  }

  public func installCatalogMod(_ id: String) async -> ToolResult<ModInfo> {
    guard let entry = ModCatalog.entries.first(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mod nicht in der Bibliothek.")
    }
    let info = ModInfo(manifest: entry.manifest, code: entry.code)
    current.mods.removeAll { $0.manifest.id == id }
    current.mods.append(info)
    changed()
    return .ok(info)
  }

  // MARK: Paket 2

  public func answerDayEnd(_ answer: DayEndAnswer) async {
    if answer == .moveAllToTomorrow {
      let ids = (current.overview.overdueTasks + current.overview.todayTasks).map(\.id)
      _ = await moveTasksToTomorrow(ids)
    }
    current.dayEndPrompt = false
    changed()
  }

  public func moveTasksToTomorrow(_ ids: [String]) async -> ToolResult<Empty> {
    for i in current.tasks.indices where ids.contains(current.tasks[i].id) {
      let time = current.tasks[i].due.flatMap { $0.count > 10 ? String($0.suffix(6)) : nil } ?? ""
      current.tasks[i].due = "2026-10-12" + time
    }
    changed()
    return .ok(Empty())
  }

  public func startFocus(taskId: String?, minutes: Int?) async -> ToolResult<FocusSession> {
    let m = minutes ?? current.settings.focusMinutes
    let title = current.tasks.first(where: { $0.id == taskId })?.title ?? "Fokus"
    let f = FocusSession(id: nextId("f"), taskId: taskId, title: title, startedAt: "\(today)T09:00:00",
                         endsAt: "\(today)T09:\(String(format: "%02d", m)):00", minutes: m)
    current.focus = f
    changed()
    return .ok(f)
  }

  public func stopFocus() async {
    current.focus = nil
    changed()
  }

  public func addMemory(_ text: String) async -> ToolResult<Memory> {
    let m = Memory(id: nextId("m"), text: text, createdAt: now)
    current.memories.append(m)
    changed()
    return .ok(m)
  }

  public func deleteMemory(_ id: String) async -> ToolResult<Empty> {
    current.memories.removeAll { $0.id == id }
    changed()
    return .ok(Empty())
  }

  public func exportMarkdown(to folder: String?) async -> ToolResult<ExportResult> {
    .ok(ExportResult(folder: folder ?? "~/Documents/Lumi", files: current.notes.count + 1))
  }

  public func mcpCommandPath() async -> String? { "/Applications/Lumi.app/Contents/MacOS/taby-mcp" }

  public func agentsInstalled() async -> Bool { agentsAreInstalled }

  public func agentsInstall() async -> ToolResult<Empty> {
    agentsAreInstalled = true
    return .ok(Empty())
  }

  public func agentsUninstall() async { agentsAreInstalled = false }

  public func resolveAgentRequest(_ id: String, _ decision: AgentPermissionDecision) async {
    emit(.agentRequestClosed(id: id))
  }

  public func subscribe(_ handler: @escaping @MainActor (AppEvent) -> Void) {
    handlers.append(handler)
  }

  // MARK: Paket 4

  /// Für Snapshots/Prüfungen: Beispiel-Plan, -Meeting und -Wochenplanung setzen.
  public func fillPackageFour() {
    current.plan = DayPlan(date: today, blocks: [
      PlannedBlock(id: "b1", taskId: current.tasks.first?.id ?? "t-1", title: "Steuererklärung abschicken",
                   start: "\(today)T10:00", end: "\(today)T10:30"),
      PlannedBlock(id: "b2", taskId: "t-3", title: "Präsentation üben", start: "\(today)T13:45", end: "\(today)T14:15"),
    ])
    current.weeklyGoals = [
      WeeklyGoal(id: "g1", week: today, text: "Steuer fertig machen", done: true),
      WeeklyGoal(id: "g2", week: today, text: "3x Sport"),
      WeeklyGoal(id: "g3", week: today, text: "Lumi-Mods ausprobieren"),
    ]
  }

  public func sampleMeeting(_ phase: MeetingBrief.Phase) -> MeetingBrief {
    MeetingBrief(id: "apple|e-3|\(today)T15:00", phase: phase, title: "Design-Review", start: "\(today)T15:00",
                 end: "\(today)T16:00", link: "https://meet.google.com/abc-defg-hij",
                 notes: [MeetingRef(id: "n-1", title: "Ideen für Lumi")],
                 tasks: [MeetingRef(id: "t-3", title: "Präsentation üben")])
  }

  public func sampleWeeklyReview() -> WeeklyReview {
    WeeklyReview(weekStart: "2026-10-05", focusMinutes: 340, tasksDone: 12,
                 doneTitles: ["Milch kaufen", "Steuer vorbereiten", "Zahnarzt anrufen"],
                 habits: [HabitWeek(name: "Lesen", days: 6, streak: 6), HabitWeek(name: "Sport", days: 2, streak: 2)],
                 events: 9, goals: current.weeklyGoals)
  }

  public func planDay() async -> ToolResult<DayPlan> {
    var blocks: [PlannedBlock] = []
    var hour = 10
    for t in current.tasks where !t.done {
      blocks.append(PlannedBlock(id: nextId("b"), taskId: t.id, title: t.title, start: String(format: "%@T%02d:00", today, hour),
                                 end: String(format: "%@T%02d:30", today, hour)))
      hour += 1
    }
    let plan = DayPlan(date: today, blocks: blocks)
    current.plan = plan
    changed()
    return .ok(plan)
  }

  public func clearPlan() async {
    current.plan = nil
    changed()
  }

  public func dismissMeeting(_ id: String) async {
    if current.meeting?.id == id { current.meeting = nil }
    changed()
  }

  public func submitMeetingNotes(_ id: String, text: String) async -> ToolResult<MeetingNotesResult> {
    let title = "Notizen: " + (current.meeting?.title ?? "Termin")
    let note = Note(id: nextId("n"), title: title, content: text, createdAt: now, updatedAt: now)
    current.notes.insert(note, at: 0)
    var tasks: [TabyTask] = []
    for line in text.split(separator: "\n") {
      let l = line.trimmingCharacters(in: .whitespaces)
      for p in ["- ", "* ", "• ", "[ ] "] where l.hasPrefix(p) {
        let t = TabyTask(id: nextId("t"), title: String(l.dropFirst(p.count)), createdAt: now)
        tasks.append(t)
        current.tasks.append(t)
      }
    }
    current.meeting = nil
    changed()
    return .ok(MeetingNotesResult(note: note, tasks: tasks))
  }

  public func prepareMeeting(_ id: String, noteIds: [String], taskIds: [String]) async -> ToolResult<Note> {
    if let existing = current.notes.first(where: { $0.id == current.meeting?.prepNoteId }) { return .ok(existing) }
    let items = current.notes.filter { noteIds.contains($0.id) }.map(\.title)
      + current.tasks.filter { taskIds.contains($0.id) }.map(\.title)
    let agenda = items.map { "- \($0)" }.joined(separator: "\n")
    let note = Note(id: nextId("n"), title: "Termin: " + (current.meeting?.title ?? "Termin"),
                    content: "## Agenda\n" + agenda + "\n\n## Mitschrift\n", createdAt: now, updatedAt: now,
                    meetingKey: id)
    current.notes.insert(note, at: 0)
    current.meeting?.prepNoteId = note.id
    changed()
    return .ok(note)
  }

  public func summarizeMeeting(_ id: String) async -> ToolResult<MeetingNotesResult> {
    guard let idx = current.notes.firstIndex(where: { $0.id == current.meeting?.prepNoteId }) else {
      return .failure(code: "NO_NOTE", error: "Erst „Notizen mitnehmen“ – dann gibt es eine Termin-Notiz.")
    }
    let task = TabyTask(id: nextId("t"), title: "Nachfassen: " + (current.meeting?.title ?? "Termin"), createdAt: now)
    current.tasks.append(task)
    current.notes[idx].content += "\n\n## Zusammenfassung\nBesprochen (Vorschau)."
    current.notes[idx].updatedAt = now
    changed()
    return .ok(MeetingNotesResult(note: current.notes[idx], tasks: [task]))
  }

  public func startMeetingListening(_ id: String, mode: MeetingListenMode, consentGiven: Bool) async -> ToolResult<Empty> {
    if mode == .everyone && !consentGiven {
      return .failure(code: "CONSENT", error: "Bei „Alle“ müssen alle Teilnehmer einverstanden sein.")
    }
    let title = current.meeting?.id == id ? (current.meeting?.title ?? "Termin") : "Termin"
    current.listening = MeetingListening(meetingId: id, title: title, mode: mode, startedAt: now,
                                         consentAt: mode == .everyone ? now : nil)
    changed()
    return .ok(Empty())
  }

  public func stopMeetingListening() async {
    current.listening = nil
    changed()
  }

  public func markMeetingMoment() async {
    guard current.listening != nil else { return }
    current.listening?.markers += 1
    current.listening?.lines += 1
    changed()
  }

  /// Vorschau: drei Kandidaten gemischt (vermutet, klar, mit Merker).
  public func extractMeetingActions(_ id: String) async -> ToolResult<[ActionCandidate]> {
    .ok([
      ActionCandidate(id: "a2", text: "Folie 3 überarbeiten", owner: "Jonas", due: nil, confidence: .guess,
                      evidence: "Folie 3 sollte man vielleicht noch anpassen.", atSeconds: 300),
      ActionCandidate(id: "a1", text: "Angebot an Frau Kern schicken", owner: "ich", due: "2026-10-16",
                      confidence: .clear, evidence: "Ich schicke dir das Angebot bis Freitag.", atSeconds: 120),
      ActionCandidate(id: "a3", text: "Termin mit dem Lieferanten abstimmen", owner: nil, due: nil,
                      confidence: .marked, evidence: "Das ist eine Aufgabe: Termin mit dem Lieferanten abstimmen.",
                      atSeconds: 480),
    ])
  }

  public func acceptMeetingActions(_ id: String, _ items: [ActionCandidate]) async -> ToolResult<[TabyTask]> {
    let tasks = items.map { c in
      TabyTask(id: nextId("t"), title: c.text, due: c.due, createdAt: now, tags: ["meeting"])
    }
    current.tasks.append(contentsOf: tasks)
    changed()
    return .ok(tasks)
  }

  public func ingestFile(path: String) async throws -> [ChatMessage] {
    let name = (path as NSString).lastPathComponent
    let reply = ChatMessage(role: .assistant, content: "„\(name)“ gelesen: kurze Zusammenfassung (Vorschau).")
    current.messages.append(reply)
    changed()
    return [reply]
  }

  public func answerWeeklyReview(_ answer: WeeklyReviewAnswer) async {
    if case .save(let goals) = answer {
      current.weeklyGoals = goals.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
        .map { WeeklyGoal(id: nextId("g"), week: today, text: $0) }
    }
    current.weeklyReviewPrompt = false
    current.weeklyReview = nil
    changed()
  }

  public func openWeeklyReview() async {
    current.weeklyReview = sampleWeeklyReview()
    current.weeklyReviewPrompt = true
    changed()
    emit(.weeklyReviewPrompt)
  }

  public func setWeeklyGoalDone(_ id: String, _ done: Bool) async -> ToolResult<WeeklyGoal> {
    guard let i = current.weeklyGoals.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Ziel nicht gefunden.")
    }
    current.weeklyGoals[i].done = done
    changed()
    return .ok(current.weeklyGoals[i])
  }

  public func installedApps() async -> [AppInfo] {
    [AppInfo(id: "com.apple.mail", name: "Mail"), AppInfo(id: "com.apple.MobileSMS", name: "Nachrichten"),
     AppInfo(id: "com.tinyspeck.slackmacgap", name: "Slack")]
  }

  /// Prüfungen: was `startListening` „hört“.
  public var fakeTranscript = "Erinner mich morgen an den Zahnarzt"

  public func startListening(_ onText: @escaping @MainActor (String, Bool) -> Void) async -> ToolResult<Empty> {
    onText(fakeTranscript, false)
    return .ok(Empty())
  }

  public func stopListening() async -> String { fakeTranscript }

  // MARK: Paket 5 – Mail

  public func sampleMail() -> MailOverview {
    MailOverview(messages: [
      MailMessage(id: "m1", senderName: "Lena Weber", senderAddress: "lena@example.com", subject: "Kommst du heute Abend?",
                  date: "\(today)T08:41", category: .important),
      MailMessage(id: "m2", senderName: "Stadtwerke", senderAddress: "rechnung@stadtwerke.example",
                  subject: "Ihre Rechnung – fällig am 20.10.", date: "\(today)T07:15", flagged: true, category: .important),
      MailMessage(id: "m3", senderName: "Max", senderAddress: "max@example.com", subject: "Fotos vom Wochenende",
                  date: "2026-10-10T19:02", read: true, category: .normal),
      MailMessage(id: "m4", senderName: "Zalando", senderAddress: "newsletter@zalando.example",
                  subject: "Nur heute: 20 % auf alles", date: "\(today)T06:00", category: .newsletter),
    ], unread: 3, fetchedAt: "\(today)T09:00")
  }

  public func refreshMail() async -> ToolResult<MailOverview> {
    let m = current.mail ?? sampleMail()
    current.mail = m
    changed()
    return .ok(m)
  }

  public func mailBody(_ id: String) async -> ToolResult<String> {
    .ok("Hi Felix,\n\nkommst du heute Abend um 19 Uhr mit ins Kino?\n\nLG Lena")
  }

  private func updateMail(_ id: String, _ f: (inout MailMessage) -> Void) -> ToolResult<Empty> {
    guard var m = current.mail, let i = m.messages.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mail nicht gefunden.")
    }
    f(&m.messages[i])
    m.unread = m.messages.filter { !$0.read }.count
    current.mail = m
    changed()
    return .ok(Empty())
  }

  public func setMailRead(_ id: String, _ read: Bool) async -> ToolResult<Empty> { updateMail(id) { $0.read = read } }
  public func setMailFlagged(_ id: String, _ flagged: Bool) async -> ToolResult<Empty> {
    updateMail(id) { $0.flagged = flagged }
  }

  private func removeMail(_ id: String) -> ToolResult<Empty> {
    guard var m = current.mail, m.messages.contains(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mail nicht gefunden.")
    }
    m.messages.removeAll { $0.id == id }
    m.unread = m.messages.filter { !$0.read }.count
    current.mail = m
    changed()
    return .ok(Empty())
  }

  public func archiveMail(_ id: String) async -> ToolResult<Empty> { removeMail(id) }
  public func trashMail(_ id: String) async -> ToolResult<Empty> { removeMail(id) }

  public func mailToTask(_ id: String) async -> ToolResult<TabyTask> {
    let subject = current.mail?.messages.first(where: { $0.id == id })?.subject ?? "Mail"
    return await addTask(title: "Antworten: \(subject)", notes: nil, due: nil)
  }

  public func draftMailReply(_ id: String, instruction: String) async throws -> MailDraft {
    let m = current.mail?.messages.first(where: { $0.id == id })
    return MailDraft(replyToId: id, to: [m?.senderAddress ?? "lena@example.com"], subject: "Re: \(m?.subject ?? "")",
                     body: "Hi Lena,\n\nja, ich bin dabei!\n\nLG Felix")
  }

  public func sendMail(_ draft: MailDraft) async -> ToolResult<Empty> { .ok(Empty()) }

  // MARK: Paket 6 – Netzwerk

  public func sampleNetwork() -> NetworkState {
    let seen = "\(today)T08:55"
    return NetworkState(
      info: NetworkInfo(ssid: "FRITZ!Box 7590", rssi: -54, noise: -92, channel: 44, band: "5 GHz", txRate: 866,
                        interfaceName: "WLAN", localIP: "192.168.178.24", subnet: "192.168.178.0/24",
                        router: "192.168.178.1", dns: ["192.168.178.1"], online: true),
      devices: [
        NetworkDevice(id: "3c:a6:2f:00:00:01", ip: "192.168.178.1", mac: "3c:a6:2f:00:00:01", name: "fritz.box",
                      vendor: "AVM", isRouter: true, known: true, firstSeen: seen, lastSeen: seen),
        NetworkDevice(id: "a4:83:e7:00:00:02", ip: "192.168.178.24", mac: "a4:83:e7:00:00:02", name: "Felix MacBook Pro",
                      vendor: "Apple", isThisMac: true, known: true, firstSeen: seen, lastSeen: seen),
        NetworkDevice(id: "f0:18:98:00:00:03", ip: "192.168.178.31", mac: "f0:18:98:00:00:03", name: "iPhone",
                      vendor: "Apple", known: true, firstSeen: seen, lastSeen: seen),
        NetworkDevice(id: "b8:27:eb:00:00:04", ip: "192.168.178.40", mac: "b8:27:eb:00:00:04", name: nil,
                      vendor: "Raspberry Pi", firstSeen: seen, lastSeen: seen),
      ],
      lastScan: seen,
      lastSpeed: SpeedResult(downMbps: 243.5, upMbps: 41.2, responsiveness: 1180, testedAt: seen))
  }

  private var networkOn: Bool { current.settings.networkToolsEnabled }
  private func networkOff<T>() -> ToolResult<T> { .failure(code: "NETWORK_OFF", error: "Netzwerk-Werkzeuge sind aus.") }

  public func refreshNetworkInfo() async -> ToolResult<NetworkInfo> {
    guard networkOn else { return networkOff() }
    if current.network == nil { current.network = sampleNetwork() }
    changed()
    return .ok(current.network!.info!)
  }

  public func scanNetwork() async -> ToolResult<[NetworkDevice]> {
    guard networkOn else { return networkOff() }
    let n = current.network ?? sampleNetwork()
    current.network = n
    changed()
    return .ok(n.devices)
  }

  public func updateNetworkDevice(_ id: String, name: String?, known: Bool?) async -> ToolResult<NetworkDevice> {
    guard var n = current.network, let i = n.devices.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Gerät nicht gefunden.")
    }
    if let name { n.devices[i].name = name }
    if let known { n.devices[i].known = known }
    current.network = n
    changed()
    return .ok(n.devices[i])
  }

  public func ping(_ host: String) async -> ToolResult<PingResult> {
    guard networkOn else { return networkOff() }
    return .ok(PingResult(host: host, ip: "192.168.178.1", sent: 3, received: 3, minMs: 2.1, avgMs: 3.4, maxMs: 5.0))
  }

  public func checkPorts(_ host: String, ports: [Int]?) async -> ToolResult<[PortResult]> {
    guard networkOn else { return networkOff() }
    return .ok([PortResult(port: 22, open: true, service: "SSH"), PortResult(port: 80, open: true, service: "HTTP"),
                PortResult(port: 445, open: false, service: "SMB")])
  }

  public func speedTest() async -> ToolResult<SpeedResult> {
    guard networkOn else { return networkOff() }
    return .ok(SpeedResult(downMbps: 243.5, upMbps: 41.2, responsiveness: 1180, testedAt: now))
  }

  public func wakeOnLan(mac: String) async -> ToolResult<Empty> { networkOn ? .ok(Empty()) : networkOff() }

  public func dnsLookup(_ name: String) async -> ToolResult<DnsResult> {
    guard networkOn else { return networkOff() }
    return .ok(DnsResult(name: name, a: ["93.184.215.14"], aaaa: ["2606:2800:21f:cb07:6820:80da:af6b:8b2c"],
                         mx: ["10 mail.example.com"]))
  }

  public func publicIP() async -> ToolResult<String> { networkOn ? .ok("84.150.12.34") : networkOff() }

  // MARK: Paket 7 – Profi-Netzwerk

  private func net() -> NetworkState { current.network ?? sampleNetwork() }

  public func deepScan(_ host: String, depth: ScanDepth) async -> ToolResult<ScanReport> {
    guard current.settings.networkToolsEnabled else { return .failure(code: "NETWORK_OFF", error: "Aus.") }
    let r = ScanReport(host: host, ip: host, up: true, os: depth == .deep ? "Linux 5.x" : nil,
                       ports: [ScanPort(port: 22, state: "open", service: "ssh", version: depth == .quick ? nil : "OpenSSH 9.6"),
                               ScanPort(port: 80, state: "open", service: "http", version: depth == .quick ? nil : "nginx 1.24"),
                               ScanPort(port: 443, state: "open", service: "https")],
                       tool: "nmap", startedAt: now, durationMs: 2400)
    var n = net(); n.lastScan2 = r; current.network = n
    changed(); return .ok(r)
  }

  public func listConnections() async -> ToolResult<[Connection]> {
    guard current.settings.networkToolsEnabled else { return .failure(code: "NETWORK_OFF", error: "Aus.") }
    let c = [
      Connection(id: "c1", app: "Safari", pid: 501, proto: "tcp", localAddress: "192.168.178.24:52344",
                 remoteAddress: "140.82.121.4:443", remoteHost: "github.com", state: "ESTABLISHED", isLocal: false),
      Connection(id: "c2", app: "Mail", pid: 502, proto: "tcp", localAddress: "192.168.178.24:52890",
                 remoteAddress: "17.57.144.22:993", remoteHost: "imap.mail.me.com", state: "ESTABLISHED", isLocal: false),
      Connection(id: "c3", app: "Lumi", pid: 777, proto: "tcp", localAddress: "192.168.178.24:52901",
                 remoteAddress: "192.168.178.1:53", remoteHost: "fritz.box", state: "ESTABLISHED", isLocal: true),
    ]
    var n = net(); n.connections = c; current.network = n
    changed(); return .ok(c)
  }

  public func addOwnServer(host: String, label: String) async -> ToolResult<OwnServer> {
    let srv = OwnServer(id: nextId("srv"), host: host, label: label.isEmpty ? host : label, authorized: true, addedAt: now)
    var n = net(); n.ownServers.append(srv); current.network = n
    changed(); return .ok(srv)
  }

  public func removeOwnServer(_ id: String) async -> ToolResult<Empty> {
    var n = net(); n.ownServers.removeAll { $0.id == id }; current.network = n
    changed(); return .ok(Empty())
  }

  public func startCapture(interface: String?, filter: String) async -> ToolResult<CaptureState> {
    let cap = CaptureState(running: true, interface: interface ?? "en0", filter: filter, startedAt: now,
                           packetCount: 3,
                           byHost: [CaptureHostStat(id: "github.com", packets: 2, bytes: 1840),
                                    CaptureHostStat(id: "fritz.box", packets: 1, bytes: 120)])
    var n = net(); n.capturing = true; n.capture = cap
    n.recentPackets = [
      CapturePacket(id: 1, t: 0.01, proto: "TCP", source: "192.168.178.24", dest: "140.82.121.4", length: 920, info: "443 ACK"),
      CapturePacket(id: 2, t: 0.03, proto: "TCP", source: "140.82.121.4", dest: "192.168.178.24", length: 920, info: "443 PSH"),
      CapturePacket(id: 3, t: 0.05, proto: "UDP", source: "192.168.178.24", dest: "192.168.178.1", length: 120, info: "53 DNS"),
    ]
    current.network = n
    changed(); return .ok(cap)
  }

  public func stopCapture() async -> ToolResult<CaptureState> {
    var n = net(); n.capturing = false
    if var c = n.capture { c.running = false; n.capture = c }
    current.network = n
    changed(); return .ok(n.capture ?? CaptureState())
  }

  public func saveCapture(to folder: String?) async -> ToolResult<String> {
    let path = (folder ?? "~/Documents/Lumi") + "/mitschnitt-\(today).pcap"
    var n = net(); if var c = n.capture { c.savedPath = path; n.capture = c }; current.network = n
    changed(); return .ok(path)
  }

  public func captureInterfaces() async -> [String] { ["en0", "en1", "utun0", "lo0"] }

  // MARK: Paket 9 – Notion-Aufgaben

  /// Nur Vorschau: ob der Standard-Zugang einen Code hat. Den Code selbst speichert die Vorschau nie.
  private var notionConnected: Bool { current.notionConnectedAccounts.contains(NotionAccount.legacyId) }

  private func setNotionConnected(_ accountId: String, _ connected: Bool) {
    current.notionConnectedAccounts.removeAll { $0 == accountId }
    if connected { current.notionConnectedAccounts.append(accountId) }
    if accountId == NotionAccount.legacyId { current.notionTasksConnected = connected }
  }

  public func connectNotionTasks(token: String) async -> ToolResult<Empty> {
    guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(code: "INVALID", error: "Token fehlt.") }
    setNotionConnected(NotionAccount.legacyId, true)
    changed(); return .ok(Empty())
  }

  public func disconnectNotionTasks() async {
    setNotionConnected(NotionAccount.legacyId, false)
    current.settings.notionTasksEnabled = false
    current.notionTasksSync = nil
    changed()
  }

  public func syncNotionTasks() async -> ToolResult<Int> {
    guard current.settings.notionTasksEnabled else { return .failure(code: "OFF", error: "Notion-Aufgaben sind ausgeschaltet.") }
    guard notionConnected else { return .failure(code: "NO_TOKEN", error: "Kein Notion-Token hinterlegt.") }
    let imported = [
      TabyTask(id: nextId("t"), title: "Angebot für Kunde X", createdAt: now),
      TabyTask(id: nextId("t"), title: "Review PR #42", createdAt: now),
    ]
    current.tasks.append(contentsOf: imported)
    current.notionTasksSync = NotionTaskSync(lastSyncAt: now, lastError: nil, importedCount: imported.count)
    changed(); return .ok(imported.count)
  }

  public func addNotionSource(name: String, category: NotionSourceCategory, link: String) async -> ToolResult<NotionSource> {
    await addNotionSource(name: name, category: category, link: link, accountId: NotionAccount.legacyId)
  }

  public func addNotionSource(name: String, category: NotionSourceCategory, link: String,
                              accountId: String) async -> ToolResult<NotionSource> {
    guard current.settings.notionAccounts.contains(where: { $0.id == accountId }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    let s = NotionSource(id: nextId("ns"), name: name, category: category, link: link, accountId: accountId)
    current.notionSources.append(s)
    changed(); return .ok(s)
  }

  // MARK: Notion-Zugänge (Vorschau)

  /// Name und Kategorie wie im Kern (`NotionAccountRules`); der Zugangscode wird nur geprüft, nie gespeichert.
  public func addNotionAccount(name: String, categoryId: String, token: String) async -> ToolResult<NotionAccount> {
    let accounts = current.settings.notionAccounts
    guard accounts.count < NotionAccountRules.maxCount else {
      return .failure(code: "VALIDATION", error: "Höchstens \(NotionAccountRules.maxCount) Notion-Zugänge.")
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = NotionAccountRules.nameProblem(trimmed, others: accounts.map(\.name)) {
      return .failure(code: "VALIDATION", error: problem)
    }
    if let problem = NotionAccountRules.categoryProblem(categoryId, defs: current.settings.taskCategories) {
      return .failure(code: "VALIDATION", error: problem)
    }
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(code: "INVALID", error: "Zugangscode fehlt.")
    }
    let account = NotionAccount(id: nextId("nacc"), name: trimmed, categoryId: categoryId)
    current.settings.notionAccounts.append(account)
    setNotionConnected(account.id, true)
    syncNotionOwnership()
    changed(); return .ok(account)
  }

  public func updateNotionAccount(_ id: String, name: String?, categoryId: String?) async -> ToolResult<NotionAccount> {
    var accounts = current.settings.notionAccounts
    guard let index = accounts.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    var account = accounts[index]
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let problem = NotionAccountRules.nameProblem(trimmed, others: accounts.filter { $0.id != id }.map(\.name)) {
        return .failure(code: "VALIDATION", error: problem)
      }
      account.name = trimmed
    }
    if let categoryId {
      if let problem = NotionAccountRules.categoryProblem(categoryId, defs: current.settings.taskCategories) {
        return .failure(code: "VALIDATION", error: problem)
      }
      account.categoryId = categoryId
    }
    accounts[index] = account
    current.settings.notionAccounts = accounts
    syncNotionOwnership()
    changed(); return .ok(account)
  }

  public func setNotionAccountToken(_ id: String, token: String) async -> ToolResult<Empty> {
    guard current.settings.notionAccounts.contains(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .failure(code: "INVALID", error: "Zugangscode fehlt.")
    }
    setNotionConnected(id, true)
    changed(); return .ok(Empty())
  }

  /// Der Standard-Zugang bleibt; andere entfernen samt Quellen. Ihre Aufgaben bleiben oder fallen weg.
  public func removeNotionAccount(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty> {
    guard id != NotionAccount.legacyId else {
      return .failure(code: "VALIDATION", error: "Der Standard-Zugang lässt sich nicht entfernen.")
    }
    guard current.settings.notionAccounts.contains(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    let sourceIds = Set(current.notionSources.filter { $0.accountId == id }.map(\.id))
    let taskIds = Set(current.notionSourceLinks.filter { sourceIds.contains($0.value) }.map(\.key))
    current.settings.notionAccounts.removeAll { $0.id == id }
    current.notionSources.removeAll { $0.accountId == id }
    setNotionConnected(id, false)
    for taskId in taskIds {
      current.notionSourceLinks[taskId] = nil
      current.notionTaskPages[taskId] = nil
      current.notionTaskGroups[taskId] = nil
    }
    current.notionLinkedTasks.removeAll { taskIds.contains($0.id) }
    if deleteTasks { current.tasks.removeAll { taskIds.contains($0.id) } }
    syncNotionOwnership()
    changed(); return .ok(Empty())
  }

  /// Kategorie je Notion-Aufgabe = Kategorie ihres Zugangs (über die Quelle).
  private func syncNotionOwnership() {
    current.notionTaskCategories = [:]
    for (taskId, sourceId) in current.notionSourceLinks {
      guard let source = current.notionSources.first(where: { $0.id == sourceId }),
            let account = current.settings.notionAccounts.first(where: { $0.id == source.accountId }) else { continue }
      current.notionTaskCategories[taskId] = account.categoryId
    }
  }

  /// Beispiel: Zwei Zugänge mit Code (Geschäftlich → Arbeit, Privat → Privat), je eine Quelle mit einer Aufgabe.
  private func fillNotionSample() {
    current.settings.notionAccounts = [
      NotionAccount(id: NotionAccount.legacyId, name: "Geschäftlich", categoryId: "arbeit"),
      NotionAccount(id: "notion-privat", name: "Privat", categoryId: "privat"),
    ]
    current.notionConnectedAccounts = [NotionAccount.legacyId, "notion-privat"]
    current.notionTasksConnected = true
    current.notionSources = [
      NotionSource(id: "ns-work", name: "Tickets Projekt", category: .tickets, link: "1a2b3c", accountId: NotionAccount.legacyId),
      NotionSource(id: "ns-privat", name: "Privat-Liste", category: .todos, link: "4d5e6f", accountId: "notion-privat"),
    ]
    current.notionLinkedTasks = [
      TabyTask(id: "nt-work", title: "Angebot für Kunde X", done: true, doneAt: now, createdAt: now),
      TabyTask(id: "nt-privat", title: "Wohnung ausmessen", done: true, doneAt: now, createdAt: now),
    ]
    current.notionSourceLinks = ["nt-work": "ns-work", "nt-privat": "ns-privat"]
    syncNotionOwnership()
  }

  public func updateNotionSource(_ id: String, name: String?, category: NotionSourceCategory?,
                                 link: String?) async -> ToolResult<NotionSource> {
    guard let i = current.notionSources.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Quelle nicht gefunden.")
    }
    if let name { current.notionSources[i].name = name }
    if let category { current.notionSources[i].category = category }
    if let link { current.notionSources[i].link = link }
    changed(); return .ok(current.notionSources[i])
  }

  public func removeNotionSource(_ id: String) async -> ToolResult<Empty> {
    current.notionSources.removeAll { $0.id == id }
    syncNotionOwnership()
    changed(); return .ok(Empty())
  }

  public func completeNotionOAuth(code: String) async -> ToolResult<Empty> {
    guard !code.isEmpty else { return .failure(code: "INVALID", error: "Kein Code.") }
    setNotionConnected(NotionAccount.legacyId, true)
    changed(); return .ok(Empty())
  }

  public func planTasks(_ items: [PlanItem]) async -> ToolResult<DayPlan> {
    var blocks: [PlannedBlock] = []
    var cursor = 9 * 60
    for item in items {
      guard let t = current.tasks.first(where: { $0.id == item.taskId && !$0.done }) else { continue }
      let startMin: Int
      if let s = item.start, let h = Int(s.prefix(2)), let m = Int(s.suffix(2)) { startMin = h * 60 + m } else { startMin = cursor }
      func fmt(_ v: Int) -> String { "\(today)T" + String(format: "%02d:%02d", v / 60, v % 60) }
      blocks.append(PlannedBlock(id: nextId("b"), taskId: t.id, title: t.title, start: fmt(startMin),
                                 end: fmt(startMin + item.minutes), pinned: item.start != nil ? true : nil))
      cursor = max(cursor, startMin + item.minutes)
    }
    let plan = DayPlan(date: today, blocks: blocks.sorted { $0.start < $1.start })
    current.plan = plan
    changed(); return .ok(plan)
  }

  public func reorderPlan(taskIds: [String]) async -> ToolResult<DayPlan> {
    var blocks: [PlannedBlock] = []
    var hour = 10
    for id in taskIds {
      guard let t = current.tasks.first(where: { $0.id == id && !$0.done }) else { continue }
      blocks.append(PlannedBlock(id: nextId("b"), taskId: t.id, title: t.title, start: String(format: "%@T%02d:00", today, hour),
                                 end: String(format: "%@T%02d:30", today, hour)))
      hour += 1
    }
    let plan = DayPlan(date: today, blocks: blocks)
    current.plan = plan
    changed()
    return .ok(plan)
  }

  public func setTaskPriority(taskIds: [String]) async -> ToolResult<Empty> {
    let open = Set(current.tasks.filter { !$0.done }.map(\.id))
    var seen = Set<String>()
    current.taskPriority = taskIds.filter { open.contains($0) && seen.insert($0).inserted }
    changed()
    return .ok(Empty())
  }

  // MARK: Microsoft
  public func startMicrosoftSignIn() async -> ToolResult<MicrosoftSignIn> {
    .ok(MicrosoftSignIn(userCode: "ABCD-1234", verificationUrl: "https://microsoft.com/devicelogin", expiresInSeconds: 900))
  }

  public func finishMicrosoftSignIn() async -> ToolResult<String> {
    current.settings.microsoftAccount = "felix@beispiel.de"
    changed()
    return .ok("felix@beispiel.de")
  }

  public func disconnectMicrosoft() async -> ToolResult<Empty> {
    current.settings.microsoftAccount = ""
    changed()
    return .ok(Empty())
  }
}
