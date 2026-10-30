// Welle C für Mods: Einstellungen (`input.settings`), Zeitpläne (im bestehenden
// Takt geprüft) und die Dienste, die Skripte über `taby.*` bekommen. Die Regeln
// sind reine Funktionen (prüfbar); CoreServices verdrahtet sie nur.
import Foundation

enum ModSettingRules {
  /// Prüft einen Wert vor dem Speichern; nil = in Ordnung.
  static func problem(_ value: String, for setting: ModSetting) -> String? {
    switch setting.kind {
    case .number:
      return Double(value.trimmingCharacters(in: .whitespaces)) == nil ? "„\(setting.label)“ braucht eine Zahl." : nil
    case .toggle:
      return ["true", "false"].contains(value) ? nil : "„\(setting.label)“ ist Ja/Nein (true oder false)."
    case .text:
      return value.count > 500 ? "„\(setting.label)“ ist zu lang (max. 500 Zeichen)." : nil
    }
  }

  /// Einstellungen für `input.settings`: Standardwerte, von gespeicherten Werten überschrieben.
  /// Nur im Manifest deklarierte Schlüssel; Zahl → Zahl, Schalter → Bool, Text → Text.
  static func input(manifest: ModManifest, stored: [String: String]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for setting in manifest.settings ?? [] {
      guard let raw = stored[setting.key] ?? setting.defaultValue else { continue }
      switch setting.kind {
      case .number:
        out[setting.key] = Double(raw.trimmingCharacters(in: .whitespaces)).map { JSONValue.number($0) } ?? .string(raw)
      case .toggle:
        out[setting.key] = .bool(raw == "true")
      case .text:
        out[setting.key] = .string(raw)
      }
    }
    return out
  }

  /// Hängt `settings` an die Eingabe. Ohne Objekt wird die Eingabe als `input` mitgegeben.
  static func withSettings(_ input: JSONValue, settings: [String: JSONValue]) -> JSONValue {
    switch input {
    case .object(var fields):
      // Nur die deklarierten Einstellungen; was das Modell in input.settings schreibt, wird verworfen.
      fields["settings"] = .object(settings)
      return .object(fields)
    case .null:
      return .object(["settings": .object(settings)])
    default:
      return .object(["input": input, "settings": .object(settings)])
    }
  }

  /// Ergebnis eines Dienstes in ein Ergebnis für das Skript (Fehler → abgelehnte Zusage).
  static func unwrap<T>(_ result: ToolResult<T>) throws -> T {
    switch result {
    case .ok(let value): return value
    case .failure(_, let message): throw ScriptBridgeError(message)
    }
  }
}

enum ModScheduleRules {
  /// Alle Minuten seit `last` (exklusiv) bis `now` (inklusiv), höchstens 5 Minuten zurück.
  /// Ohne `last` nur die aktuelle Minute.
  static func minutes(after last: String?, until now: Date) -> [(stamp: String, weekday: Int)] {
    let cal = LocalTime.calendar
    guard let floor = cal.date(byAdding: .minute, value: -5, to: now) else { return [] }
    let next = last.flatMap { LocalTime.parse($0) }.flatMap { cal.date(byAdding: .minute, value: 1, to: $0) }
    var t = max(next ?? now, floor)
    var out: [(stamp: String, weekday: Int)] = []
    while t <= now {
      let w = cal.component(.weekday, from: t)
      out.append((stamp: LocalTime.format(t), weekday: w == 1 ? 7 : w - 1))
      guard let step = cal.date(byAdding: .minute, value: 1, to: t) else { break }
      t = step
    }
    return out
  }

  /// Mods, deren Zeitplan zu einer der Minuten passt. Je Mod höchstens einmal pro Minute;
  /// `lastRun` merkt sich die letzte Minute (nur im Speicher).
  static func due(_ candidates: [(id: String, schedule: [ModSchedule])],
                  minutes: [(stamp: String, weekday: Int)], lastRun: inout [String: String]) -> [String] {
    var out: [String] = []
    for m in minutes {
      let time = String(m.stamp.suffix(5))
      for candidate in candidates {
        guard candidate.schedule.contains(where: { matches($0, time: time, weekday: m.weekday) }) else { continue }
        guard lastRun[candidate.id] != m.stamp else { continue }
        lastRun[candidate.id] = m.stamp
        out.append(candidate.id)
      }
    }
    return out
  }

  static func matches(_ schedule: ModSchedule, time: String, weekday: Int) -> Bool {
    guard schedule.time == time else { return false }
    guard let days = schedule.weekdays else { return true }
    return days.contains(weekday)
  }
}

extension CoreServices {
  /// Schaltet eine Einstellung eines installierten Mods (ändert die Freigabe nicht).
  public func setModSetting(_ id: String, key: String, value: String) async -> ToolResult<ModInfo> {
    do {
      guard let manifest = try mods.manifest(id) else {
        return .failure(code: "NOT_FOUND", error: "Der Mod „\(id)“ wurde nicht gefunden.")
      }
      guard let setting = manifest.settings?.first(where: { $0.key == key }) else {
        return .failure(code: "VALIDATION", error: "Der Mod kennt die Einstellung „\(key)“ nicht.")
      }
      if let problem = ModSettingRules.problem(value, for: setting) {
        return .failure(code: "VALIDATION", error: problem)
      }
      let info = try mods.setSettingValue(id, key: key, value: value)
      emit(.stateChanged)
      return .ok(info)
    } catch {
      return .failure(code: "ERROR", error: "Einstellung konnte nicht gespeichert werden.")
    }
  }

  /// Läuft im bestehenden Takt (`packageFourTick`): startet freigegebene Mods, deren Zeitplan jetzt passt.
  func runScheduledMods() {
    let now = clock.now()
    let minutes = ModScheduleRules.minutes(after: p4.modScheduleChecked, until: now)
    p4.modScheduleChecked = LocalTime.format(now)
    let candidates = ((try? mods.all()) ?? [])
      .filter { $0.enabled && $0.approved && !($0.manifest.schedule ?? []).isEmpty }
      .map { (id: $0.id, schedule: $0.manifest.schedule ?? []) }
    guard !candidates.isEmpty else { return }
    let due = ModScheduleRules.due(candidates, minutes: minutes, lastRun: &p4.modScheduleRuns)
    for id in due {
      Task { @MainActor [weak self] in
        guard let self else { return }
        _ = await self.executeMod(id, input: Self.withTime(["trigger": .string("schedule")], now: now))
        self.emit(.stateChanged)
      }
    }
  }

  /// Dienste für die Mod-Sandbox (`taby.habits`, `taby.focus`, `taby.timer`, `taby.messages`, `taby.mail`).
  func modHostActions() -> ModHostActions {
    var actions = ModHostActions()
    actions.checkHabit = { [weak self] id in
      guard let self else { throw ScriptBridgeError.unavailable }
      return try ModSettingRules.unwrap(await self.checkHabit(id, date: StoreDates.today(self.clock)))
    }
    actions.startFocus = { [weak self] minutes in
      guard let self else { throw ScriptBridgeError.unavailable }
      _ = try ModSettingRules.unwrap(await self.startFocus(taskId: nil, minutes: minutes))
    }
    actions.stopFocus = { [weak self] in await self?.stopFocus() }
    actions.focusIsRunning = { [weak self] in ((try? self?.store.focus.current()) ?? nil) != nil }
    actions.startTimer = { [weak self] minutes, label in
      guard let self else { throw ScriptBridgeError.unavailable }
      _ = try ModSettingRules.unwrap(await self.startTimer(minutes: minutes, label: label))
    }
    actions.recentMessages = { [weak self] limit in
      guard let self else { return [] }
      return self.modRecentMessages(limit)
    }
    actions.completeTask = { [weak self] id in
      guard let self else { throw ScriptBridgeError.unavailable }
      let result = await self.runUndoable("complete_task", ["id": .string(id)], ctx: self.toolContext(actor: .user),
                                          auditActor: AuditActor.mod)
      guard result["ok"]?.boolValue == true else {
        throw ScriptBridgeError(result["error"]?.stringValue ?? "Aufgabe nicht erledigt.")
      }
    }
    actions.openMailDraft = { [weak self] draft in
      guard let self else { throw ScriptBridgeError.unavailable }
      guard self.mailToolsAllowed else { throw ScriptBridgeError("Mail ist aus oder nur lokal erlaubt.") }
      try await self.mailBackend.openNewDraft(draft)
    }
    return actions
  }

  /// Letzte Nachricht je Unterhaltung aus dem Zwischenspeicher; der Text kommt als fremder Inhalt.
  func modRecentMessages(_ limit: Int) -> [JSONValue] {
    messenger.conversationList().compactMap { conversation -> JSONValue? in
      guard let text = conversation.lastText, !text.isEmpty else { return nil }
      return .object([
        "conversation": .string(ForeignContent.wrap(String(conversation.title.prefix(200)))),
        "at": .string(conversation.lastAt ?? ""),
        "text": .string(ForeignContent.wrap(String(text.prefix(500)))),
      ])
    }
    .prefix(limit)
    .map { $0 }
  }
}
