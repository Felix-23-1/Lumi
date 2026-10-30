import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  /// Eingabe eines Trigger-Laufs: Auslöser plus Zeit (aus der Clock) und Wochentag (ISO 1…7).
  static func triggerInput(_ t: ModTrigger, now: Date) -> JSONValue {
    ["trigger": .string(t.rawValue), "now": .string(LocalTime.format(now)),
     "weekday": .number(Double(isoWeekday(now)))]
  }

  /// Wohnort aus den Einstellungen als `input.city` (nur wenn gesetzt und nicht schon mitgegeben).
  nonisolated static func withCity(_ input: JSONValue, _ city: String) -> JSONValue {
    let c = city.trimmingCharacters(in: .whitespaces)
    guard !c.isEmpty, case .object(var fields) = input, fields["city"] == nil else { return input }
    fields["city"] = .string(c)
    return .object(fields)
  }

  /// Von Hand gestartete Skripte bekommen Zeit und Wochentag wie Trigger-Läufe (ohne Auslöser).
  static func withTime(_ input: JSONValue, now: Date) -> JSONValue {
    guard case .object(var fields) = input, fields["now"] == nil else { return input }
    fields["now"] = .string(LocalTime.format(now))
    fields["weekday"] = .number(Double(isoWeekday(now)))
    return .object(fields)
  }

  /// ISO-Wochentag: Montag = 1 … Sonntag = 7.
  static func isoWeekday(_ date: Date) -> Int {
    let wd = LocalTime.calendar.component(.weekday, from: date)  // So=1 … Sa=7
    return ((wd + 5) % 7) + 1
  }

  /// Mod setzt einen Insel-Kurztext; Dauer 5…86400 s, Text max. 40 Zeichen. Einer gleichzeitig.
  private func setModIslandText(_ modId: String, _ text: String, seconds: Double) {
    let clamped = min(max(seconds, 5), 86_400)
    let until = LocalTime.format(clock.now().addingTimeInterval(clamped))
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    modIsland[modId] = IslandMessage(text: trimmed, until: until, modId: modId)
    emit(.stateChanged)
  }

  /// Gültiger Insel-Text (nil, wenn abgelaufen).
  func currentIslandMessage() -> IslandMessage? { currentIslandMessages().first }

  /// Alle gültigen Mod-Texte, zuletzt gesetzter zuerst (until wächst mit der Setzzeit nicht zwingend – daher nach Ablauf sortiert).
  func currentIslandMessages() -> [IslandMessage] {
    let now = LocalTime.format(clock.now())
    return modIsland.values.filter { $0.until >= now }.sorted { ($0.until, $0.modId) > ($1.until, $1.modId) }
  }

  // MARK: Paket 3 – Mods

  /// Werkzeuge eingeschalteter, freigegebener Mods (für das Modell im Chat).
  /// Karte für einen Mod-Aufruf des Modells: Name, Art, Rechte und die Eingabe (max. 300 Zeichen).
  func describeModRun(name: String, args: JSONValue) -> String {
    guard let id = ModRuntime.modId(fromTool: name), let m = try? mods.manifest(id) else {
      return "Mod „\(name)“ ausführen"
    }
    let kind = m.kind == .shortcut ? "Kurzbefehl" : "Skript"
    let rights = m.permissions.isEmpty ? "keine" : m.permissions.joined(separator: ", ")
    let raw = args == .object([:]) ? "" : (args.stringValue ?? args.jsonString())
    let input = raw.isEmpty ? "keine" : String(raw.prefix(300)) + (raw.count > 300 ? "…" : "")
    return "Mod „\(m.name)“ ausführen (\(kind)). Rechte: \(rights). Eingabe: \(input)"
  }

  func modToolDefs() -> [ToolDef] {
    ((try? mods.all()) ?? []).filter { $0.manifest.kind != .skill && (try? mods.isRunnable($0.id)) == true }
      .compactMap { ModRuntime.toolDef($0.manifest) }
  }

  func createModFromChat(_ argsJson: String) -> JSONValue {
    let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) ?? .object([:])
    guard let (m, code) = ModRuntime.manifest(fromCreateArgs: args) else {
      return ["ok": false, "code": "INVALID_ARGS", "error": "id, name, description und code sind nötig."]
    }
    let problems = ModValidation.validate(m)
    guard problems.isEmpty else {
      return ["ok": false, "code": "INVALID_MOD", "error": .string(problems.joined(separator: " "))]
    }
    // Das Modell darf keinen vorhandenen (womöglich freigegebenen) Mod überschreiben.
    if ((try? mods.manifest(m.id)) ?? nil) != nil {
      return ["ok": false, "code": "EXISTS", "error": "Einen Mod mit dieser id gibt es schon. Wähle eine neue id; vorhandene Mods ändert nur der Nutzer."]
    }
    do {
      _ = try mods.install(m, code: code)
      emit(.flash(TabyNotification(title: "Neuer Mod: \(m.name)", body: "Im Reiter „Mods“ prüfen und einschalten.")))
      emit(.stateChanged)
      return ["ok": true, "message": "Mod angelegt, aber AUSGESCHALTET. Der Nutzer muss Rechte und Code im Reiter „Mods“ prüfen und ihn einschalten."]
    } catch {
      return ["ok": false, "code": "ERROR", "error": .string((error as? LocalizedError)?.errorDescription ?? "Mod konnte nicht gespeichert werden.")]
    }
  }

  /// Führt einen Mod aus (nur eingeschaltet + freigegeben).
  func executeMod(_ id: String, input: JSONValue, confirmed: Bool = false) async -> ToolResult<String> {
    let result = await runMod(id, input: input)
    audit(actor: AuditActor.mod, tool: id, confirmed: confirmed, ok: result.isOk, summary: "Mod ausgeführt")
    return result
  }

  private func runMod(_ id: String, input: JSONValue) async -> ToolResult<String> {
    guard (try? mods.isRunnable(id)) == true, let m = try? mods.manifest(id) else {
      return .failure(code: "NOT_ALLOWED", error: "Mod ist aus oder nicht freigegeben.")
    }
    let now = LocalTime.format(clock.now())
    do {
      let output: String
      switch m.kind {
      case .shortcut:
        let runner = shortcutsRunner
        let name = m.shortcutName ?? m.name
        let text: String? = input == .object([:]) ? nil : (input.stringValue ?? input.jsonString())
        output = try await Blocking.run { try runner.run(name, input: text, timeout: 30) }
      case .script:
        guard let code = try mods.code(id) else { throw ScriptModError.scriptError("Skript fehlt.") }
        let box = calendarBox
        let host = StoreModHost(store: store, calendar: { box.value }, notifier: modNotifier,
                                onChange: { [weak self] in Task { @MainActor in self?.changed() } },
                                modId: id,
                                onIslandText: { [weak self] mid, text, seconds in
                                  Task { @MainActor in self?.setModIslandText(mid, text, seconds: seconds) }
                                },
                                actions: modHostActions(), mods: mods)
        output = try await ScriptModRunner(host: host, session: options.session, localOnly: settings.localOnly)
          .run(code: code, manifest: m, input: Self.withCity(Self.withTime(input, now: clock.now()), settings.homeCity),
               settingValues: mods.settingValues(id))
          .output
      case .skill:
        // shortcut: Skills laufen über runSkill (Chat-Durchgang), nicht als Werkzeug-Ausführung.
        output = "Skill „\(m.name)“: bitte im Chat mit /\(m.command ?? m.id) starten."
      }
      try? mods.recordRun(id, at: now, error: nil)
      return .ok(output)
    } catch {
      let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      try? mods.recordRun(id, at: now, error: msg)
      return .failure(code: "MOD_ERROR", error: msg)
    }
  }

  /// Automatiken: alle freigegebenen Mods mit diesem Auslöser (im Hintergrund).
  /// Aufbewahrung je Tabelle: Auftrags-Läufe 90 Tage, Verbrauch 400 Tage (Jahresvergleich).
  static let jobRunRetentionDays = 90
  static let usageRetentionDays = 400

  /// Chatverlauf und alte Zeilen (Aufträge, Verbrauch) aufräumen; läuft beim Start und im Stundentakt, höchstens einmal pro Tag.
  func pruneChatHistoryIfDue() {
    let today = StoreDates.today(clock)
    guard chatPrunedDay != today else { return }
    chatPrunedDay = today
    try? store.messages.prune(keepDays: settings.chatHistoryDays)
    try? store.jobs.pruneRuns(keepDays: Self.jobRunRetentionDays)
    try? store.usage.prune(keepDays: Self.usageRetentionDays)
    try? store.audit.pruneOlderThan(days: settings.auditRetentionDays, now: clock.now())
    // Reste: Papierkorb der Mods und Export-Kopien aus `Lumi/.vorher` (nur für den gemerkten Export-Ordner).
    Leftovers.removeOlder(in: modTrashRoot, now: clock.now())
    if !settings.exportFolder.isEmpty {
      MarkdownExporter.removeOldBackups(folder: settings.exportFolder, now: clock.now())
    }
  }

  /// Tägliche Sicherung und Prüfung außerhalb des Hauptthreads. Ein Befund erscheint einmal am Tag als Hinweis.
  func dailyBackupInBackground() {
    let db = store.db
    let backupClock = clock
    let retention = settings.backupRetentionDays
    Task.detached(priority: .utility) { [weak self] in
      DatabaseBackup.dailyIfDue(db, clock: backupClock, retentionDays: retention) { _ in
        Task { @MainActor in
          self?.emit(.flash(TabyNotification(title: "Datenbank-Prüfung",
                                             body: "Lumi hat ein Problem in der Datenbank gefunden. Bitte Einstellungen → Allgemein → Sicherungen prüfen.")))
        }
      }
    }
  }

  /// Papierkorb für gelöschte Mods (neben dem Mod-Ordner).
  var modTrashRoot: URL {
    mods.root.deletingLastPathComponent().appendingPathComponent("Papierkorb-Mods", isDirectory: true)
  }

  func runTriggers(_ t: ModTrigger, only: String? = nil) {
    let ids = ((try? mods.all()) ?? []).filter { $0.manifest.triggers.contains(t) && (only == nil || $0.id == only) }
      .map(\.id)
    guard !ids.isEmpty else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      let input = Self.triggerInput(t, now: self.clock.now())
      for id in ids { _ = await self.executeMod(id, input: input) }
      self.emit(.stateChanged)
    }
  }

  public func listShortcuts() async -> ToolResult<[String]> {
    let runner = shortcutsRunner
    do { return .ok(try await Blocking.run { try runner.list() }) } catch {
      return .failure(code: "SHORTCUTS", error: (error as? LocalizedError)?.errorDescription ?? "Kurzbefehle nicht lesbar.")
    }
  }

  public func createShortcutMod(shortcutName: String, description: String, asTool: Bool,
                                triggers: [ModTrigger]) async -> ToolResult<ModInfo> {
    var m = ShortcutModFactory.manifest(shortcutName: shortcutName, description: description, asTool: asTool,
                                        triggers: triggers)
    let existing = Set(((try? mods.all()) ?? []).map(\.id))
    var n = 2
    let base = m.id
    while existing.contains(m.id) { m.id = String("\(base)-\(n)".prefix(40)); n += 1 }
    do {
      let info = try mods.install(m, code: nil)
      emit(.stateChanged)
      return .ok(info)
    } catch {
      return .failure(code: "INVALID_MOD", error: (error as? LocalizedError)?.errorDescription ?? "Mod ungültig.")
    }
  }

  public func setModEnabled(_ id: String, _ enabled: Bool) async -> ToolResult<ModInfo> {
    do {
      let info = try mods.setEnabled(id, enabled, now: LocalTime.format(clock.now()))
      if !enabled { modIsland[id] = nil }
      emit(.stateChanged)
      // Stündliche Mods (z. B. Wetter) sofort einmal laufen lassen, statt bis zur nächsten Stunde zu warten.
      if enabled, info.manifest.triggers.contains(.hourly) { runTriggers(.hourly, only: id) }
      return .ok(info)
    } catch {
      return .failure(code: "ERROR", error: (error as? LocalizedError)?.errorDescription ?? "Mod nicht gefunden.")
    }
  }

  public func deleteMod(_ id: String) async -> ToolResult<Empty> {
    // Vor jedem Pfadzugriff prüfen: die ID wird an den Papierkorb-Pfad angehängt.
    guard ModValidation.isValidID(id) else { return .failure(code: "ERROR", error: "Mod nicht gefunden.") }
    // Ordner vorher in den Papierkorb legen, damit „Rückgängig“ ihn zurückholen kann.
    // shortcut: Papierkorb wird nicht geleert, pro Mod-ID liegt nur eine Kopie (die nächste ersetzt sie).
    let fm = FileManager.default
    let trashRoot = modTrashRoot
    let dir = mods.root.appendingPathComponent(id, isDirectory: true)
    var trash: String?
    if fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: trashRoot, withIntermediateDirectories: true)
      let target = trashRoot.appendingPathComponent(id, isDirectory: true)
      try? fm.removeItem(at: target)
      if (try? fm.copyItem(at: dir, to: target)) != nil {
        // Das Datum zählt ab dem Löschen, nicht ab dem Ändern des Mods (Aufräumen nach 24 h).
        try? fm.setAttributes([.modificationDate: clock.now()], ofItemAtPath: target.path)
        trash = target.path
      }
    }
    do {
      try mods.delete(id)
      if let trash { pushUndo(.deletedMod(id: id, trash: trash), "Mod gelöscht") }
      emit(.stateChanged)
      return .ok(Empty())
    } catch {
      return .failure(code: "ERROR", error: "Mod konnte nicht gelöscht werden.")
    }
  }

  public func runMod(_ id: String, input: String?) async -> ToolResult<String> {
    let value: JSONValue = input.flatMap { JSONValue.parse($0) ?? .string($0) } ?? .object([:])
    let r = await executeMod(id, input: value)
    emit(.stateChanged)
    return r
  }

  public func exportMod(_ id: String, to folder: String) async -> ToolResult<String> {
    do { return .ok(try mods.export(id, to: URL(fileURLWithPath: folder)).path) } catch {
      return .failure(code: "EXPORT", error: (error as? LocalizedError)?.errorDescription ?? "Export fehlgeschlagen.")
    }
  }

  public func importMod(from path: String) async -> ToolResult<ModInfo> {
    do {
      let info = try mods.importMod(from: URL(fileURLWithPath: path))
      emit(.stateChanged)
      return .ok(info)
    } catch {
      return .failure(code: "IMPORT", error: (error as? LocalizedError)?.errorDescription ?? "Import fehlgeschlagen.")
    }
  }

  public func modCatalog() async -> [CatalogMod] { ModCatalog.entries }

  public func installCatalogMod(_ id: String) async -> ToolResult<ModInfo> {
    guard let entry = ModCatalog.entries.first(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Mod nicht in der Bibliothek.")
    }
    do {
      let info = try mods.install(entry.manifest, code: entry.code)
      emit(.stateChanged)
      return .ok(info)
    } catch {
      return .failure(code: "INSTALL", error: (error as? LocalizedError)?.errorDescription ?? "Installieren fehlgeschlagen.")
    }
  }
}
