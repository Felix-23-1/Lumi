// Repositories für Erinnerungen, Aufträge, Tagesstart, Chat, Protokoll,
// Kalenderquellen und Einstellungen (Port von src/main/store/repositories/
// {reminders,jobs,dailyState,messages,actionLog,calendarSources,settings}.ts).
import Foundation

private func jsonText<T: Encodable>(_ value: T) -> String {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return (try? enc.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

// MARK: - Erinnerungen

public final class RemindersRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toReminder(_ r: SQLRow) -> Reminder {
    Reminder(id: r.text("id"), source: ReminderSource(rawValue: r.text("source")) ?? .task,
             sourceRef: r.text("source_ref"), dueAt: r.text("due_at"), firedAt: r.string("fired_at"),
             acknowledgedAt: r.string("acknowledged_at"))
  }

  public func listAll() throws -> [Reminder] {
    try db.query("SELECT * FROM reminders ORDER BY due_at, rowid").map(toReminder)
  }

  public func get(_ id: String) throws -> Reminder? {
    try db.query("SELECT * FROM reminders WHERE id = ?", [.text(id)]).first.map(toReminder)
  }

  public func find(source: ReminderSource, sourceRef: String) throws -> Reminder? {
    try db.query("SELECT * FROM reminders WHERE source = ? AND source_ref = ?",
                 [.text(source.rawValue), .text(sourceRef)]).first.map(toReminder)
  }

  /// Legt neu an oder aktualisiert dueAt/firedAt (Planer-Abgleich);
  /// acknowledgedAt bleibt bei bestehenden Einträgen erhalten.
  public func upsert(_ r: Reminder) throws {
    try db.run(
      "INSERT INTO reminders (id, source, source_ref, due_at, fired_at, acknowledged_at) VALUES (?, ?, ?, ?, ?, ?) "
        + "ON CONFLICT(id) DO UPDATE SET due_at = excluded.due_at, fired_at = excluded.fired_at",
      [.text(r.id), .text(r.source.rawValue), .text(r.sourceRef), .text(r.dueAt), .of(r.firedAt), .of(r.acknowledgedAt)])
  }

  @discardableResult
  public func add(source: ReminderSource, sourceRef: String, dueAt: String) throws -> Reminder {
    let r = Reminder(id: StoreIds.make(), source: source, sourceRef: sourceRef, dueAt: dueAt)
    try upsert(r)
    return r
  }

  /// Noch nicht ausgelöste Erinnerungen.
  public func listOpen() throws -> [Reminder] {
    try db.query("SELECT * FROM reminders WHERE fired_at IS NULL ORDER BY due_at, rowid").map(toReminder)
  }

  /// Verpasst: nicht ausgelöst, nicht bestätigt, fällig vor `now` (lokaler ISO-String).
  public func listMissed(now: String) throws -> [Reminder] {
    try db.query(
      "SELECT * FROM reminders WHERE fired_at IS NULL AND acknowledged_at IS NULL AND due_at < ? ORDER BY due_at, rowid",
      [.text(now)]
    ).map(toReminder)
  }

  public func markFired(_ id: String, at: String) throws {
    try db.run("UPDATE reminders SET fired_at = ? WHERE id = ?", [.text(at), .text(id)])
  }

  public func acknowledge(_ ids: [String], at: String) throws {
    try db.transaction {
      for id in ids { try db.run("UPDATE reminders SET acknowledged_at = ? WHERE id = ?", [.text(at), .text(id)]) }
    }
  }

  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.run("DELETE FROM reminders WHERE id = ?", [.text(id)]) > 0
  }
}

// MARK: - Aufträge

public final class JobsRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  private func toJob(_ r: SQLRow) -> Job? {
    guard let rule = try? JSONDecoder().decode(JobRule.self, from: Data(r.text("rule").utf8)) else { return nil }
    return Job(id: r.text("id"), name: r.text("name"), prompt: r.text("prompt"), rule: rule,
               mode: JobMode(rawValue: r.text("mode")) ?? .readOnly, enabled: r.bool("enabled"),
               lastRunAt: r.string("last_run_at"), createdAt: r.text("created_at"))
  }

  /// Standardmodus ist read-only (BAUPLAN Abschnitt 7).
  @discardableResult
  public func add(name: String, prompt: String, rule: JobRule, mode: JobMode = .readOnly) throws -> Job {
    let job = Job(id: StoreIds.make(), name: name, prompt: prompt, rule: rule, mode: mode, enabled: true,
                  createdAt: StoreDates.now(clock))
    try db.run(
      "INSERT INTO jobs (id, name, prompt, rule, mode, enabled, last_run_at, created_at) VALUES (?, ?, ?, ?, ?, 1, NULL, ?)",
      [.text(job.id), .text(name), .text(prompt), .text(jsonText(rule)), .text(mode.rawValue), .text(job.createdAt)])
    return job
  }

  /// Alle Aufträge (auch deaktivierte); Zeilen mit unlesbarer Regel werden übersprungen.
  public func list() throws -> [Job] {
    try db.query("SELECT * FROM jobs ORDER BY created_at, rowid").compactMap(toJob)
  }

  public func get(_ id: String) throws -> Job? {
    try db.query("SELECT * FROM jobs WHERE id = ?", [.text(id)]).first.flatMap(toJob)
  }

  /// Deaktiviert; false, wenn unbekannt oder schon deaktiviert.
  @discardableResult
  /// Laufender Auftrag: ausschalten. Schon beendeter (z. B. einmaliger, bereits gelaufener): ganz entfernen.
  public func cancel(_ id: String) throws -> Bool {
    if try db.run("UPDATE jobs SET enabled = 0 WHERE id = ? AND enabled = 1", [.text(id)]) > 0 { return true }
    try db.run("DELETE FROM job_runs WHERE job_id = ?", [.text(id)])
    return try db.run("DELETE FROM jobs WHERE id = ?", [.text(id)]) > 0
  }

  public func markRan(_ id: String, at: String) throws {
    try db.run("UPDATE jobs SET last_run_at = ? WHERE id = ?", [.text(at), .text(id)])
  }

  private func toRun(_ r: SQLRow) -> JobRun {
    JobRun(id: r.text("id"), jobId: r.text("job_id"), scheduledFor: r.text("scheduled_for"),
           startedAt: r.text("started_at"), status: JobRunStatus(rawValue: r.text("status")) ?? .error,
           output: r.string("output"))
  }

  @discardableResult
  public func addRun(jobId: String, scheduledFor: String, startedAt: String, status: JobRunStatus,
                     output: String? = nil) throws -> JobRun {
    let run = JobRun(id: StoreIds.make(), jobId: jobId, scheduledFor: scheduledFor, startedAt: startedAt,
                     status: status, output: output)
    try db.run(
      "INSERT INTO job_runs (id, job_id, scheduled_for, started_at, status, output) VALUES (?, ?, ?, ?, ?, ?)",
      [.text(run.id), .text(jobId), .text(scheduledFor), .text(startedAt), .text(status.rawValue), .of(output)])
    return run
  }

  public func listRuns(jobId: String) throws -> [JobRun] {
    try db.query("SELECT * FROM job_runs WHERE job_id = ? ORDER BY scheduled_for, rowid", [.text(jobId)]).map(toRun)
  }

  /// Jüngster Lauf (nach `scheduled_for`) ohne die Ausgaben aller anderen Läufe zu laden.
  public func latestRun(jobId: String) throws -> JobRun? {
    try db.query("SELECT * FROM job_runs WHERE job_id = ? ORDER BY scheduled_for DESC, rowid DESC LIMIT 1",
                 [.text(jobId)]).first.map(toRun)
  }

  /// Löscht Läufe, die vor den letzten `keepDays` Tagen gestartet wurden (0 = nie löschen).
  public func pruneRuns(keepDays: Int) throws {
    guard keepDays > 0 else { return }
    let cutoff = StoreDates.shiftDateOnly(StoreDates.today(clock), -(keepDays - 1))
    try db.run("DELETE FROM job_runs WHERE started_at < ?", [.text(cutoff)])
  }
}

// MARK: - Tagesstart-Zustand

public final class DailyStateRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  public func get(_ date: String) throws -> DailyState? {
    try db.query("SELECT * FROM daily_state WHERE date = ?", [.text(date)]).first.map {
      DailyState(date: $0.text("date"), state: DayStartState(rawValue: $0.text("state")) ?? .none,
                 snoozeUntil: $0.string("snooze_until"))
    }
  }

  @discardableResult
  public func set(_ date: String, _ state: DayStartState, snoozeUntil: String? = nil) throws -> DailyState {
    try db.run(
      "INSERT INTO daily_state (date, state, snooze_until) VALUES (?, ?, ?) "
        + "ON CONFLICT(date) DO UPDATE SET state = excluded.state, snooze_until = excluded.snooze_until",
      [.text(date), .text(state.rawValue), .of(snoozeUntil)])
    return DailyState(date: date, state: state, snoozeUntil: snoozeUntil)
  }
}

// MARK: - Chatverlauf

public final class MessagesRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  /// Speichert die vollständige Nachricht (inkl. tool_calls) als JSON.
  @discardableResult
  public func add(_ message: ChatMessage) throws -> String {
    let id = StoreIds.make()
    try db.run("INSERT INTO messages (id, json, created_at) VALUES (?, ?, ?)",
               [.text(id), .text(jsonText(message)), .text(StoreDates.now(clock))])
    return id
  }

  /// Die letzten `limit` Nachrichten in Einfüge-Reihenfolge (älteste zuerst).
  public func list(limit: Int) throws -> [ChatMessage] {
    let rows = try db.query("SELECT * FROM messages ORDER BY created_at DESC, rowid DESC LIMIT ?", [.of(limit)])
    return rows.compactMap { try? JSONDecoder().decode(ChatMessage.self, from: Data($0.text("json").utf8)) }.reversed()
  }

  public func clear() throws {
    try db.run("DELETE FROM messages")
  }

  /// Löscht Nachrichten vor dem Zeitraum der letzten `keepDays` Tage (heute zählt mit; 0 = nie löschen).
  public func prune(keepDays: Int) throws {
    guard keepDays > 0 else { return }
    let cutoff = StoreDates.shiftDateOnly(StoreDates.today(clock), -(keepDays - 1))
    try db.run("DELETE FROM messages WHERE created_at < ?", [.text(cutoff)])
  }
}

// MARK: - Aktionsprotokoll

/// Protokoll jeder ausgeführten Änderung. Nie Geheimnisse übergeben: die
/// Werkzeuge reichen nur ihre Argumente durch (keine Header/Tokens).
public final class ActionLogRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  @discardableResult
  public func log(actor: ActionActor, tool: String, args: JSONValue, ok: Bool, error: String? = nil) throws
    -> ActionLogEntry
  {
    let e = ActionLogEntry(id: StoreIds.make(), at: StoreDates.now(clock), actor: actor, tool: tool,
                           argsJson: args.jsonString(), ok: ok, error: error)
    try db.run("INSERT INTO action_log (id, at, actor, tool, args_json, ok, error) VALUES (?, ?, ?, ?, ?, ?, ?)",
               [.text(e.id), .text(e.at), .text(actor.rawValue), .text(tool), .text(e.argsJson), .of(ok), .of(error)])
    return e
  }

  /// Neueste zuerst.
  public func list(limit: Int) throws -> [ActionLogEntry] {
    try db.query("SELECT * FROM action_log ORDER BY at DESC, rowid DESC LIMIT ?", [.of(limit)]).map {
      ActionLogEntry(id: $0.text("id"), at: $0.text("at"), actor: ActionActor(rawValue: $0.text("actor")) ?? .user,
                     tool: $0.text("tool"), argsJson: $0.text("args_json"), ok: $0.bool("ok"), error: $0.string("error"))
    }
  }
}

// MARK: - Kalenderquellen

public final class CalendarSourcesRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toConfig(_ r: SQLRow) -> CalendarSourceConfig {
    let config = JSONValue.parse(r.text("config_json"))?.objectValue ?? [:]
    return CalendarSourceConfig(id: r.text("id"), kind: CalendarSourceKind(rawValue: r.text("kind")) ?? .local,
                                config: config, enabled: r.bool("enabled"), isDefaultWrite: r.bool("is_default_write"))
  }

  /// Es gibt höchstens ein "Standard zum Schreiben"-Modul: wird eines gesetzt,
  /// verlieren alle anderen die Markierung.
  private func clearOtherDefaults(except id: String) throws {
    try db.run("UPDATE calendar_sources SET is_default_write = 0 WHERE id <> ?", [.text(id)])
  }

  @discardableResult
  public func add(kind: CalendarSourceKind, config: [String: JSONValue] = [:], enabled: Bool = true,
                  isDefaultWrite: Bool = false, id fixedId: String? = nil) throws -> CalendarSourceConfig {
    let id = fixedId ?? StoreIds.make()
    try db.transaction {
      try db.run("INSERT INTO calendar_sources (id, kind, config_json, enabled, is_default_write) VALUES (?, ?, ?, ?, ?)",
                 [.text(id), .text(kind.rawValue), .text(JSONValue.object(config).jsonString()), .of(enabled),
                  .of(isDefaultWrite)])
      if isDefaultWrite { try clearOtherDefaults(except: id) }
    }
    return try get(id)!
  }

  public func get(_ id: String) throws -> CalendarSourceConfig? {
    try db.query("SELECT * FROM calendar_sources WHERE id = ?", [.text(id)]).first.map(toConfig)
  }

  /// nil-Felder bleiben unverändert; nil-Ergebnis = unbekannte ID.
  public func update(_ id: String, config: [String: JSONValue]? = nil, enabled: Bool? = nil,
                     isDefaultWrite: Bool? = nil) throws -> CalendarSourceConfig? {
    guard let existing = try get(id) else { return nil }
    let next = CalendarSourceConfig(id: id, kind: existing.kind, config: config ?? existing.config,
                                    enabled: enabled ?? existing.enabled,
                                    isDefaultWrite: isDefaultWrite ?? existing.isDefaultWrite)
    try db.transaction {
      try db.run("UPDATE calendar_sources SET config_json = ?, enabled = ?, is_default_write = ? WHERE id = ?",
                 [.text(JSONValue.object(next.config).jsonString()), .of(next.enabled), .of(next.isDefaultWrite),
                  .text(id)])
      if isDefaultWrite == true { try clearOtherDefaults(except: id) }
    }
    return try get(id)
  }

  /// Anlegen (draft.id == nil) oder Aktualisieren; nil = ID unbekannt.
  public func upsert(_ draft: CalendarSourceDraft) throws -> CalendarSourceConfig? {
    if let id = draft.id {
      return try update(id, config: draft.config, enabled: draft.enabled, isDefaultWrite: draft.isDefaultWrite)
    }
    return try add(kind: draft.kind, config: draft.config ?? [:], enabled: draft.enabled ?? true,
                   isDefaultWrite: draft.isDefaultWrite ?? false)
  }

  public func list() throws -> [CalendarSourceConfig] {
    try db.query("SELECT * FROM calendar_sources ORDER BY rowid").map(toConfig)
  }

  public func listActive() throws -> [CalendarSourceConfig] {
    try db.query("SELECT * FROM calendar_sources WHERE enabled = 1 ORDER BY rowid").map(toConfig)
  }

  @discardableResult
  public func delete(_ id: String) throws -> Bool {
    try db.run("DELETE FROM calendar_sources WHERE id = ?", [.text(id)]) > 0
  }
}

// MARK: - Einstellungen (ohne Geheimnisse)

/// Schlüssel/Wert-Ablage (Wert = JSON) für `TabySettings` ohne `hasApiKey`.
/// Der API-Key liegt im Schlüsselbund und wird hier nie gespeichert.
public final class SettingsRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func stored() throws -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for r in try db.query("SELECT key, value FROM app_settings") {
      if let v = JSONValue.parse(r.text("value")) { out[r.text("key")] = v }
    }
    return out
  }

  /// Gespeicherte Werte über den Standardwerten; `hasApiKey` kommt vom Aufrufer
  /// (Schlüsselbund), nie aus der Datenbank.
  public func get(hasApiKey: Bool = false) throws -> TabySettings {
    let s = try stored()
    var out = TabySettings.defaults
    out.hasApiKey = hasApiKey
    if let v = s["llmBaseUrl"]?.stringValue { out.llmBaseUrl = v }
    if let v = s["llmModel"]?.stringValue { out.llmModel = v }
    if let v = s["personality"]?.stringValue, let p = Personality(rawValue: v) { out.personality = p }
    if let v = s["customInstructions"]?.stringValue { out.customInstructions = v }
    if let v = s["reminderLeadMinutes"]?.numberValue { out.reminderLeadMinutes = Int(v) }
    if let v = s["startOnLogin"]?.boolValue { out.startOnLogin = v }
    if let v = s["globalShortcut"]?.stringValue { out.globalShortcut = v }
    if let v = s["askAfterUnlock"]?.boolValue { out.askAfterUnlock = v }
    if let v = s["briefingModel"]?.stringValue { out.briefingModel = v }
    if let v = s["bufferMinutes"]?.numberValue { out.bufferMinutes = max(0, Int(v)) }
    if let v = s["dailyCostLimitUsd"]?.numberValue { out.dailyCostLimitUsd = max(0, v) }
    if let v = s["monthlyCostLimitUsd"]?.numberValue { out.monthlyCostLimitUsd = max(0, v) }
    if let v = s["quickCaptureShortcut"]?.stringValue { out.quickCaptureShortcut = v }
    if let v = s["appleRemindersSync"]?.boolValue { out.appleRemindersSync = v }
    if let v = s["appleRemindersListId"]?.stringValue { out.appleRemindersListId = v }
    if let v = s["dayEndEnabled"]?.boolValue { out.dayEndEnabled = v }
    if let v = s["dayEndTime"]?.stringValue, Self.isValidTimeOfDay(v) { out.dayEndTime = v }
    if let v = s["focusMinutes"]?.numberValue { out.focusMinutes = Int(Self.clampFocus(v)) }
    if let v = s["breakMinutes"]?.numberValue { out.breakMinutes = Int(Self.clampBreak(v)) }
    if let v = s["exportFolder"]?.stringValue { out.exportFolder = v }
    if let v = s["mcpEnabled"]?.boolValue { out.mcpEnabled = v }
    if let v = s["voiceEnabled"]?.boolValue { out.voiceEnabled = v }
    if let v = s["voiceBriefings"]?.boolValue { out.voiceBriefings = v }
    if let v = s["voiceAlerts"]?.boolValue { out.voiceAlerts = v }
    if let v = s["voiceName"]?.stringValue { out.voiceName = v }
    if let v = s["onboardingDone"]?.boolValue { out.onboardingDone = v }
    if let v = s["planBlockMinutes"]?.numberValue { out.planBlockMinutes = Int(min(max(v, 5), 240)) }
    if let v = s["meetingCompanion"]?.boolValue { out.meetingCompanion = v }
    if let v = s["meetingLeadMinutes"]?.numberValue { out.meetingLeadMinutes = Int(min(max(v, 1), 60)) }
    if let v = s["readAloudMinutes"]?.numberValue { out.readAloudMinutes = Int(min(max(v, 5), 1440)) }
    if let v = s["briefingPrompt"]?.stringValue { out.briefingPrompt = v }
    if let v = s["captureSelectionShortcut"]?.stringValue { out.captureSelectionShortcut = v }
    if let v = s["voiceInputShortcut"]?.stringValue { out.voiceInputShortcut = v }
    if let v = s["weeklyReviewEnabled"]?.boolValue { out.weeklyReviewEnabled = v }
    if let v = s["weeklyReviewDay"]?.numberValue { out.weeklyReviewDay = Int(min(max(v, 1), 7)) }
    if let v = s["weeklyReviewTime"]?.stringValue, Self.isValidTimeOfDay(v) { out.weeklyReviewTime = v }
    if let v = s["focusShortcutOn"]?.stringValue { out.focusShortcutOn = v }
    if let v = s["focusShortcutOff"]?.stringValue { out.focusShortcutOff = v }
    if let v = s["focusHideApps"]?.arrayValue { out.focusHideApps = v.compactMap(\.stringValue) }
    if let v = s["tabOrder"]?.arrayValue { out.tabOrder = v.compactMap(\.stringValue) }
    if let v = s["hiddenTabs"]?.arrayValue { out.hiddenTabs = v.compactMap(\.stringValue) }
    if let v = s["workHours"]?.arrayValue, v.count == 7 { out.workHours = v.compactMap(\.stringValue) }
    if let v = s["hiddenTickerKinds"]?.arrayValue { out.hiddenTickerKinds = v.compactMap(\.stringValue) }
    if let v = s["messengerEnabled"]?.boolValue { out.messengerEnabled = v }
    if let v = s["notchText"]?.stringValue { out.notchText = v }
    if let v = s["captureContextShortcut"]?.stringValue { out.captureContextShortcut = v }
    if let v = s["explainShortcut"]?.stringValue { out.explainShortcut = v }
    if let v = s["circleShortcut"]?.stringValue { out.circleShortcut = v }
    if let v = s["notionStatusMap"]?.stringValue, let d = v.data(using: .utf8),
       let m = try? JSONDecoder().decode([String: String].self, from: d) { out.notionStatusMap = NotionStatusRules.cleaned(m) }
    if let v = s["autoStatus"]?.boolValue { out.autoStatus = v }
    if let v = s["privateListId"]?.stringValue { out.privateListId = v }
    if let v = s["localOnly"]?.boolValue { out.localOnly = v }
    if let v = s["cloudConsentAt"]?.stringValue { out.cloudConsentAt = v }
    if let v = s["chatHistoryDays"]?.numberValue { out.chatHistoryDays = Int(v) }
    if let v = s["backupRetentionDays"]?.numberValue { out.backupRetentionDays = Int(v) }
    if let v = s["auditRetentionDays"]?.numberValue { out.auditRetentionDays = Int(v) }
    if let v = s["mcpServers"], let data = v.jsonString().data(using: .utf8),
       let list = try? JSONDecoder().decode([MCPServerConfig].self, from: data) { out.mcpServers = list }
    // Ungültig gespeichert: die eingebauten Kategorien bleiben (Standardwert).
    if let v = s["taskCategories"], let data = v.jsonString().data(using: .utf8),
       let list = try? JSONDecoder().decode([TaskCategoryDef].self, from: data),
       let clean = TaskCategoryRules.sanitize(list) { out.taskCategories = clean }
    if let v = s["markdownVaultPath"]?.stringValue { out.markdownVaultPath = v }
    if let v = s["vaultWriteFolder"]?.stringValue { out.vaultWriteFolder = v }
    if let v = s["networkShares"], let data = v.jsonString().data(using: .utf8),
       let list = try? JSONDecoder().decode([NetworkShare].self, from: data) { out.networkShares = list }
    // Ungültige Kennungen fallen weg, mindestens der Standard-Zugang bleibt (`NotionAccountRules.loadable`).
    if let v = s["notionAccounts"], let data = v.jsonString().data(using: .utf8),
       let list = try? JSONDecoder().decode([NotionAccount].self, from: data) { out.notionAccounts = NotionAccountRules.loadable(list) }
    if let v = s["microsoftClientId"]?.stringValue { out.microsoftClientId = v }
    if let v = s["microsoftAccount"]?.stringValue { out.microsoftAccount = v }
    if let v = s["mailBackend"]?.stringValue { out.mailBackend = v }
    if let v = s["imapHost"]?.stringValue { out.imapHost = v }
    if let v = s["imapUser"]?.stringValue { out.imapUser = v }
    if let v = s["homeCity"]?.stringValue { out.homeCity = v }
    if let v = s["updateSource"]?.stringValue { out.updateSource = v }
    if let v = s["notchCountdown"]?.stringValue { out.notchCountdown = v }
    if let v = s["mailEnabled"]?.boolValue { out.mailEnabled = v }
    if let v = s["mailLocalOnly"]?.boolValue { out.mailLocalOnly = v }
    if let v = s["mailBriefing"]?.boolValue { out.mailBriefing = v }
    if let v = s["claudeNotify"]?.boolValue { out.claudeNotify = v }
    if let v = s["networkToolsEnabled"]?.boolValue { out.networkToolsEnabled = v }
    if let v = s["networkWatch"]?.boolValue { out.networkWatch = v }
    if let v = s["seasonalDecor"]?.boolValue { out.seasonalDecor = v }
    if let v = s["birthday"]?.stringValue, Self.isValidBirthday(v) { out.birthday = v }
    if let v = s["notionTasksEnabled"]?.boolValue { out.notionTasksEnabled = v }
    if let v = s["notionTasksDatabaseId"]?.stringValue { out.notionTasksDatabaseId = v }
    if let v = s["notionTasksPageId"]?.stringValue { out.notionTasksPageId = v }
    return out
  }

  /// "HH:mm" mit gültiger Uhrzeit (00:00 bis 23:59).
  public static func isValidTimeOfDay(_ s: String) -> Bool {
    guard s.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil,
          let h = Int(s.prefix(2)), let m = Int(s.suffix(2)) else { return false }
    return h <= 23 && m <= 59
  }

  /// Geburtstag "MM-DD" (leer erlaubt = keiner).
  public static func isValidBirthday(_ s: String) -> Bool {
    if s.isEmpty { return true }
    guard s.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) != nil,
          let m = Int(s.prefix(2)), let d = Int(s.suffix(2)) else { return false }
    return (1...12).contains(m) && (1...31).contains(d)
  }

  /// Fokus-Länge in Minuten: 1 bis 180.
  static func clampFocus(_ v: Double) -> Double { min(max(v, 1), 180) }

  /// Pausen-Länge in Minuten: 1 bis 60.
  static func clampBreak(_ v: Double) -> Double { min(max(v, 1), 60) }

  /// Schreibt alle gesetzten Felder des Patches.
  @discardableResult
  public func update(_ patch: SettingsPatch, hasApiKey: Bool = false) throws -> TabySettings {
    var pairs: [(String, JSONValue)] = []
    if let v = patch.llmBaseUrl { pairs.append(("llmBaseUrl", .string(v))) }
    if let v = patch.llmModel { pairs.append(("llmModel", .string(v))) }
    if let v = patch.personality { pairs.append(("personality", .string(v.rawValue))) }
    if let v = patch.customInstructions { pairs.append(("customInstructions", .string(v))) }
    if let v = patch.reminderLeadMinutes { pairs.append(("reminderLeadMinutes", .number(Double(max(0, v))))) }
    if let v = patch.startOnLogin { pairs.append(("startOnLogin", .bool(v))) }
    if let v = patch.globalShortcut { pairs.append(("globalShortcut", .string(v))) }
    if let v = patch.askAfterUnlock { pairs.append(("askAfterUnlock", .bool(v))) }
    if let v = patch.briefingModel { pairs.append(("briefingModel", .string(v))) }
    if let v = patch.bufferMinutes { pairs.append(("bufferMinutes", .number(Double(max(0, v))))) }
    if let v = patch.dailyCostLimitUsd { pairs.append(("dailyCostLimitUsd", .number(max(0, v)))) }
    if let v = patch.monthlyCostLimitUsd { pairs.append(("monthlyCostLimitUsd", .number(max(0, v)))) }
    if let v = patch.quickCaptureShortcut { pairs.append(("quickCaptureShortcut", .string(v))) }
    if let v = patch.appleRemindersSync { pairs.append(("appleRemindersSync", .bool(v))) }
    if let v = patch.appleRemindersListId { pairs.append(("appleRemindersListId", .string(v))) }
    if let v = patch.dayEndEnabled { pairs.append(("dayEndEnabled", .bool(v))) }
    // Ungültige Uhrzeit: der bisherige Wert bleibt erhalten.
    if let v = patch.dayEndTime, Self.isValidTimeOfDay(v) { pairs.append(("dayEndTime", .string(v))) }
    if let v = patch.focusMinutes { pairs.append(("focusMinutes", .number(Self.clampFocus(Double(v))))) }
    if let v = patch.breakMinutes { pairs.append(("breakMinutes", .number(Self.clampBreak(Double(v))))) }
    if let v = patch.exportFolder { pairs.append(("exportFolder", .string(v))) }
    if let v = patch.mcpEnabled { pairs.append(("mcpEnabled", .bool(v))) }
    if let v = patch.voiceEnabled { pairs.append(("voiceEnabled", .bool(v))) }
    if let v = patch.voiceBriefings { pairs.append(("voiceBriefings", .bool(v))) }
    if let v = patch.voiceAlerts { pairs.append(("voiceAlerts", .bool(v))) }
    if let v = patch.voiceName { pairs.append(("voiceName", .string(v))) }
    if let v = patch.onboardingDone { pairs.append(("onboardingDone", .bool(v))) }
    if let v = patch.planBlockMinutes { pairs.append(("planBlockMinutes", .number(Double(min(max(v, 5), 240))))) }
    if let v = patch.meetingCompanion { pairs.append(("meetingCompanion", .bool(v))) }
    if let v = patch.meetingLeadMinutes { pairs.append(("meetingLeadMinutes", .number(Double(min(max(v, 1), 60))))) }
    if let v = patch.readAloudMinutes { pairs.append(("readAloudMinutes", .number(Double(min(max(v, 5), 1440))))) }
    if let v = patch.briefingPrompt { pairs.append(("briefingPrompt", .string(v))) }
    if let v = patch.captureSelectionShortcut { pairs.append(("captureSelectionShortcut", .string(v))) }
    if let v = patch.voiceInputShortcut { pairs.append(("voiceInputShortcut", .string(v))) }
    if let v = patch.weeklyReviewEnabled { pairs.append(("weeklyReviewEnabled", .bool(v))) }
    if let v = patch.weeklyReviewDay { pairs.append(("weeklyReviewDay", .number(Double(min(max(v, 1), 7))))) }
    if let v = patch.weeklyReviewTime, Self.isValidTimeOfDay(v) { pairs.append(("weeklyReviewTime", .string(v))) }
    if let v = patch.focusShortcutOn { pairs.append(("focusShortcutOn", .string(v))) }
    if let v = patch.focusShortcutOff { pairs.append(("focusShortcutOff", .string(v))) }
    if let v = patch.focusHideApps { pairs.append(("focusHideApps", .array(v.map { .string($0) }))) }
    if let v = patch.tabOrder { pairs.append(("tabOrder", .array(v.map { .string($0) }))) }
    if let v = patch.hiddenTabs { pairs.append(("hiddenTabs", .array(v.map { .string($0) }))) }
    if let v = patch.workHours, v.count == 7 { pairs.append(("workHours", .array(v.map { .string($0) }))) }
    if let v = patch.hiddenTickerKinds { pairs.append(("hiddenTickerKinds", .array(v.map { .string($0) }))) }
    if let v = patch.messengerEnabled { pairs.append(("messengerEnabled", .bool(v))) }
    if let v = patch.notchText { pairs.append(("notchText", .string(v))) }
    if let v = patch.captureContextShortcut { pairs.append(("captureContextShortcut", .string(v))) }
    if let v = patch.explainShortcut { pairs.append(("explainShortcut", .string(v))) }
    if let v = patch.circleShortcut { pairs.append(("circleShortcut", .string(v))) }
    if let v = patch.notionStatusMap, let d = try? JSONEncoder().encode(NotionStatusRules.cleaned(v)),
       let json = String(data: d, encoding: .utf8) { pairs.append(("notionStatusMap", .string(json))) }
    if let v = patch.autoStatus { pairs.append(("autoStatus", .bool(v))) }
    if let v = patch.privateListId { pairs.append(("privateListId", .string(v))) }
    if let v = patch.localOnly { pairs.append(("localOnly", .bool(v))) }
    if let v = patch.cloudConsentAt { pairs.append(("cloudConsentAt", .string(v))) }
    if let v = patch.chatHistoryDays { pairs.append(("chatHistoryDays", .number(Double(v)))) }
    if let v = patch.backupRetentionDays { pairs.append(("backupRetentionDays", .number(Double(min(max(v, 1), 365))))) }
    if let v = patch.auditRetentionDays { pairs.append(("auditRetentionDays", .number(Double(min(max(v, 1), 365))))) }
    if let v = patch.mcpServers, let data = try? JSONEncoder().encode(v), let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
      pairs.append(("mcpServers", json))
    }
    // Ungültige Liste (Kennung, Name, Anzahl, Doppelte): der bisherige Wert bleibt erhalten.
    if let v = patch.taskCategories, let clean = TaskCategoryRules.sanitize(v),
       let data = try? JSONEncoder().encode(clean), let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
      pairs.append(("taskCategories", json))
    }
    if let v = patch.markdownVaultPath { pairs.append(("markdownVaultPath", .string(v))) }
    if let v = patch.networkShares, v.count <= 20,
       let data = try? JSONEncoder().encode(v), let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
      pairs.append(("networkShares", json))
    }
    // Mindestens ein Zugang, höchstens 8, Kennungen gültig und eindeutig (sonst bleibt alles beim Alten);
    // Namen und Kategorien prüft der Kern vor dem Speichern.
    if let v = patch.notionAccounts, !v.isEmpty, v.count <= 8, NotionAccountRules.idsValid(v),
       let data = try? JSONEncoder().encode(v), let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
      pairs.append(("notionAccounts", json))
    }
    if let v = patch.microsoftClientId { pairs.append(("microsoftClientId", .string(v.trimmingCharacters(in: .whitespacesAndNewlines)))) }
    if let v = patch.microsoftAccount { pairs.append(("microsoftAccount", .string(v))) }
    if let v = patch.vaultWriteFolder {
      // Nur ein sicherer Ordnername (wie Dateinamen), sonst die Vorgabe „Lumi“.
      let safe = MarkdownVault.isSafeFolder(v) ? v.trimmingCharacters(in: .whitespacesAndNewlines) : "Lumi"
      pairs.append(("vaultWriteFolder", .string(safe)))
    }
    if let v = patch.mailBackend { pairs.append(("mailBackend", .string(v))) }
    if let v = patch.imapHost { pairs.append(("imapHost", .string(v))) }
    if let v = patch.imapUser { pairs.append(("imapUser", .string(v))) }
    if let v = patch.homeCity { pairs.append(("homeCity", .string(v))) }
    if let v = patch.updateSource { pairs.append(("updateSource", .string(v))) }
    if let v = patch.notchCountdown { pairs.append(("notchCountdown", .string(v))) }
    if let v = patch.mailEnabled { pairs.append(("mailEnabled", .bool(v))) }
    if let v = patch.mailLocalOnly { pairs.append(("mailLocalOnly", .bool(v))) }
    if let v = patch.mailBriefing { pairs.append(("mailBriefing", .bool(v))) }
    if let v = patch.claudeNotify { pairs.append(("claudeNotify", .bool(v))) }
    if let v = patch.networkToolsEnabled { pairs.append(("networkToolsEnabled", .bool(v))) }
    if let v = patch.networkWatch { pairs.append(("networkWatch", .bool(v))) }
    if let v = patch.seasonalDecor { pairs.append(("seasonalDecor", .bool(v))) }
    if let v = patch.birthday, Self.isValidBirthday(v) { pairs.append(("birthday", .string(v))) }
    if let v = patch.notionTasksEnabled { pairs.append(("notionTasksEnabled", .bool(v))) }
    if let v = patch.notionTasksDatabaseId { pairs.append(("notionTasksDatabaseId", .string(v))) }
    if let v = patch.notionTasksPageId { pairs.append(("notionTasksPageId", .string(v))) }
    try db.transaction {
      for (k, v) in pairs {
        try db.run("INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(k), .text(v.jsonString())])
      }
    }
    return try get(hasApiKey: hasApiKey)
  }
}

// MARK: - Aufgaben-Kategorien

/// Regeln für `TabySettings.taskCategories`: Arbeit und Privat bleiben eingebaut und vorn; die
/// Kennung ist `[a-z0-9-]` (1…24 Zeichen), der Name 1…24 Zeichen, höchstens 12 Kategorien insgesamt.
/// Wird eine Kategorie aus der Liste entfernt, behalten Aufgaben und Ordner ihre Kennung; sie zählen
/// dann als „keine Kategorie“ (Anzeige und Werkzeuge behandeln unbekannte Kennungen so).
public enum TaskCategoryRules {
  public static let maxCount = 12

  /// Grund, warum eine Liste nicht gilt (für die Anzeige).
  public struct Problem: Error, Equatable {
    public let reason: String
  }

  /// Bereinigte Liste (Eingebaute zuerst, fehlende mit Standardwert ergänzt). Wirft mit Grund bei ungültigen Einträgen.
  public static func sanitized(_ list: [TaskCategoryDef]) throws -> [TaskCategoryDef] {
    var seen = Set<String>()
    var cleaned: [TaskCategoryDef] = []
    for def in list {
      let name = def.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let symbol = def.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
      guard def.id.range(of: #"^[a-z0-9-]{1,24}$"#, options: .regularExpression) != nil else {
        throw Problem(reason: "Die Kennung „\(def.id)“ ist ungültig.")
      }
      guard (1...24).contains(name.count) else { throw Problem(reason: "Der Name „\(name)“ hat 1 bis 24 Zeichen.") }
      guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw Problem(reason: "Der Name enthält Steuerzeichen.")
      }
      guard symbol.count <= 64 else { throw Problem(reason: "Das Symbol ist länger als 64 Zeichen.") }
      guard seen.insert(def.id).inserted else { throw Problem(reason: "Die Kennung „\(def.id)“ gibt es doppelt.") }
      cleaned.append(TaskCategoryDef(id: def.id, name: name, symbol: symbol.isEmpty ? "tag.fill" : symbol))
    }
    var result = TaskCategoryDef.builtIn.map { builtIn in cleaned.first { $0.id == builtIn.id } ?? builtIn }
    result += cleaned.filter { c in !TaskCategoryDef.builtIn.contains { $0.id == c.id } }
    guard result.count <= maxCount else { throw Problem(reason: "Höchstens \(maxCount) Kategorien.") }
    return result
  }

  /// Bereinigte Liste oder nil bei ungültigen Einträgen.
  public static func sanitize(_ list: [TaskCategoryDef]) -> [TaskCategoryDef]? {
    try? sanitized(list)
  }

  /// Der Grund, warum die Liste nicht gespeichert wird; nil, wenn sie gilt.
  public static func problem(_ list: [TaskCategoryDef]) -> String? {
    do { _ = try sanitized(list); return nil } catch let p as Problem { return p.reason } catch { return "unbekannter Fehler" }
  }

  /// Kennung aus dem Nutzerwert: getrimmt, klein geschrieben; leer = keine Kategorie (nil).
  public static func normalize(_ raw: String?) -> String? {
    guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !v.isEmpty else { return nil }
    return v
  }

  /// Fehlertext für eine unbekannte Kennung; nennt die erlaubten Kategorien.
  public static func unknownMessage(_ id: String, in defs: [TaskCategoryDef]) -> String {
    "Kategorie \"\(id)\" gibt es nicht. Erlaubt: \(summary(defs)) (oder \"\" für keine Kategorie)."
  }

  /// „Arbeit (arbeit), Privat (privat), Sport (sport)“ für Werkzeuge und Systemprompt.
  public static func summary(_ defs: [TaskCategoryDef]) -> String {
    defs.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
  }

  /// Wirksame Kategorie einer Aufgabe (Kennung) oder nil. Notion-Aufgaben (Kennung in `notionCategories`,
  /// je Aufgabe die Kategorie ihres Notion-Zugangs) haben nie eine eigene: nur diese zählt, sonst nichts.
  /// Andere: eigene Kategorie, sonst die ihres Ordners. Unbekannte Kennungen zählen nicht.
  public static func effective(_ task: TabyTask, folders: [TaskFolder], defs: [TaskCategoryDef],
                               notionCategories: [String: String]) -> String? {
    func known(_ id: String?) -> String? { id.flatMap { v in defs.contains { $0.id == v } ? v : nil } }
    if let notion = notionCategories[task.id] { return known(notion) }
    if let own = known(task.category?.rawValue) { return own }
    guard let fid = task.folderId, let folder = folders.first(where: { $0.id == fid }) else { return nil }
    return known(folder.categoryId)
  }
}

// MARK: - Notion-Zugänge

/// Regeln für `NotionAccount`: Name 1…24 Zeichen ohne Steuerzeichen, eindeutig ohne Groß/Klein,
/// höchstens 8 Zugänge; die Kategorie muss in den Einstellungen stehen.
public enum NotionAccountRules {
  public static let maxCount = 8

  /// Grund, warum der (getrimmte) Name nicht gilt; nil = gilt. `others` sind die Namen der anderen Zugänge.
  public static func nameProblem(_ name: String, others: [String]) -> String? {
    guard (1...24).contains(name.count) else { return "Der Name des Notion-Zugangs hat 1 bis 24 Zeichen." }
    guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      return "Der Name enthält Steuerzeichen."
    }
    guard !others.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
      return "Den Notion-Zugang „\(name)“ gibt es schon."
    }
    return nil
  }

  /// Kennung eines Zugangs: der Standard-Zugang „notion“ oder eine UUID (`[0-9A-Fa-f-]{36}`). Sie landet im
  /// Schlüsselbund-Namen und in Dateinamen, darum nichts anderes.
  public static func idIsValid(_ id: String) -> Bool {
    id == NotionAccount.legacyId || id.range(of: #"^[0-9A-Fa-f-]{36}$"#, options: .regularExpression) != nil
  }

  /// Alle Kennungen gültig und keine doppelt. Beim Speichern gilt die ganze Liste sonst als abgelehnt.
  public static func idsValid(_ list: [NotionAccount]) -> Bool {
    list.allSatisfy { idIsValid($0.id) } && Set(list.map(\.id)).count == list.count
  }

  /// Beim Laden: ungültige und doppelte Einträge fallen weg; nie leer (mindestens der Standard-Zugang).
  public static func loadable(_ list: [NotionAccount]) -> [NotionAccount] {
    var seen = Set<String>()
    let valid = list.filter { idIsValid($0.id) && seen.insert($0.id).inserted }
    return valid.isEmpty ? [NotionAccount.legacy] : valid
  }

  /// Grund, warum die Kategorie nicht zu den Einstellungen gehört; nil = gehört dazu.
  public static func categoryProblem(_ categoryId: String, defs: [TaskCategoryDef]) -> String? {
    defs.contains { $0.id == categoryId } ? nil : "Die Kategorie „\(categoryId)“ gibt es nicht."
  }
}
