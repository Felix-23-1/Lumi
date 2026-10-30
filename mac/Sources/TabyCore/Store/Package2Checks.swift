// Prüfungen für Paket 2 im Speicher: Einstellungen, Tagesabschluss,
// Fokus-Sitzungen, gemerkte Fakten und Migrationen.
import Foundation

private func p2Store(_ now: String = "2024-03-04T08:00") throws -> (Store, ControllableClock) {
  let clock = ControllableClock(now)
  return (try Store.inMemory(clock: clock), clock)
}

private func p2Equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                   file: StaticString = #fileID, line: UInt = #line) throws {
  if actual != expected {
    let extra = message.isEmpty ? "" : " — \(message)"
    throw CheckFailure(message: "erwartet \(expected), war \(actual)\(extra)", location: "\(file):\(line)")
  }
}

extension StoreChecks {
  static let packageTwoChecks: [CheckCase] = [
    CheckCase("Paket 2 Einstellungen: Standardwerte") {
      let (store, _) = try p2Store()
      let s = try store.settings.get()
      try p2Equal(s.dayEndEnabled, true)
      try p2Equal(s.dayEndTime, "20:00")
      try p2Equal(s.focusMinutes, 25)
      try p2Equal(s.breakMinutes, 5)
      try p2Equal(s.exportFolder, "")
      try p2Equal(s.mcpEnabled, false)
    },
    CheckCase("Paket 2 Einstellungen: entfernte Notion-Seitenschlüssel in alten Zeilen stören nicht") {
      let (store, _) = try p2Store()
      _ = try store.db.run("INSERT INTO app_settings (key, value) VALUES (?, ?)",
                           [.text("notionPageURL"), .text("\"https://example.com/alt\"")])
      _ = try store.db.run("INSERT INTO app_settings (key, value) VALUES (?, ?)",
                           [.text("notionPageTitle"), .text("\"Alt\"")])
      let s = try store.settings.get()
      try p2Equal(s.dayEndTime, "20:00")
      try p2Equal(s.notionTasksEnabled, false)
    },
    CheckCase("Paket 2 Einstellungen: Round Trip aller sechs Felder") {
      let (store, _) = try p2Store()
      _ = try store.settings.update(SettingsPatch(dayEndEnabled: false, dayEndTime: "07:30", focusMinutes: 50,
                                                  breakMinutes: 10, exportFolder: "~/Lumi-Export", mcpEnabled: true))
      let s = try store.settings.get(hasApiKey: true)
      try p2Equal(s.dayEndEnabled, false)
      try p2Equal(s.dayEndTime, "07:30")
      try p2Equal(s.focusMinutes, 50)
      try p2Equal(s.breakMinutes, 10)
      try p2Equal(s.exportFolder, "~/Lumi-Export")
      try p2Equal(s.mcpEnabled, true)
      try p2Equal(s.hasApiKey, true, "hasApiKey kommt vom Aufrufer")
    },
    CheckCase("Paket 2 Einstellungen: Fokus 1…180 und Pause 1…60 werden begrenzt") {
      let (store, _) = try p2Store()
      var s = try store.settings.update(SettingsPatch(focusMinutes: 500, breakMinutes: 0))
      try p2Equal(s.focusMinutes, 180)
      try p2Equal(s.breakMinutes, 1)
      s = try store.settings.update(SettingsPatch(focusMinutes: -4, breakMinutes: 999))
      try p2Equal(s.focusMinutes, 1)
      try p2Equal(s.breakMinutes, 60)
    },
    CheckCase("Paket 2 Einstellungen: ungültige Uhrzeit lässt den alten Wert") {
      let (store, _) = try p2Store()
      _ = try store.settings.update(SettingsPatch(dayEndTime: "21:15"))
      for bad in ["25:00", "7:30", "12:60", "abends", "12:30:00", ""] {
        let s = try store.settings.update(SettingsPatch(dayEndTime: bad))
        try p2Equal(s.dayEndTime, "21:15", "\"\(bad)\" darf nicht gespeichert werden")
      }
      try p2Equal(SettingsRepository.isValidTimeOfDay("00:00"), true)
      try p2Equal(SettingsRepository.isValidTimeOfDay("23:59"), true)
    },
    CheckCase("Tagesabschluss: get leer, set legt an, set ersetzt") {
      let (store, _) = try p2Store()
      try p2Equal(try store.dayEnd.get("2024-03-04") == nil, true)
      try store.dayEnd.set(DayEndRecord(date: "2024-03-04", state: .snoozed, snoozeUntil: "2024-03-04T21:00"))
      let first = try expectNotNil(try store.dayEnd.get("2024-03-04"))
      try p2Equal(first.state, .snoozed)
      try p2Equal(first.snoozeUntil, "2024-03-04T21:00")
      try store.dayEnd.set(DayEndRecord(date: "2024-03-04", state: .done))
      let second = try expectNotNil(try store.dayEnd.get("2024-03-04"))
      try p2Equal(second.state, .done)
      try p2Equal(second.snoozeUntil, nil)
    },
    CheckCase("Fokus: start, laufende Sitzung wird vorher beendet (nicht abgeschlossen)") {
      let (store, _) = try p2Store("2024-03-04T08:00")
      let first = try store.focus.start(taskId: "t1", title: "Erste", phase: .work, minutes: 25)
      try p2Equal(first.startedAt, "2024-03-04T08:00:00")
      try p2Equal(first.endsAt, "2024-03-04T08:25:00")
      try p2Equal(try store.focus.current()?.id, first.id)
      let second = try store.focus.start(taskId: nil, title: "Fokus", phase: .rest, minutes: 5)
      try p2Equal(try store.focus.current()?.id, second.id, "neueste laufende Sitzung")
      try p2Equal(second.taskId, nil)
      try p2Equal(second.phase, .rest)
      try p2Equal(try store.focus.minutesToday(), 0, "nichts abgeschlossen")
    },
    CheckCase("Fokus: finish(completed:) und minutesToday zählen nur abgeschlossene Arbeit") {
      let (store, clock) = try p2Store("2024-03-04T08:00")
      let work = try store.focus.start(taskId: nil, title: "Arbeit", phase: .work, minutes: 25)
      clock.advance(seconds: 25 * 60)
      try store.focus.finish(work.id, completed: true)
      try p2Equal(try store.focus.current() == nil, true)
      try p2Equal(try store.focus.minutesToday(), 25)
      // Pause und abgebrochene Arbeit zählen nicht.
      let rest = try store.focus.start(taskId: nil, title: "Pause", phase: .rest, minutes: 5)
      try store.focus.finish(rest.id, completed: true)
      let aborted = try store.focus.start(taskId: nil, title: "Abbruch", phase: .work, minutes: 25)
      try store.focus.finish(aborted.id, completed: false)
      try p2Equal(try store.focus.minutesToday(), 25)
      // Beenden einer schon beendeten Sitzung ändert nichts.
      try store.focus.finish(work.id, completed: false)
      try p2Equal(try store.focus.minutesToday(), 25)
    },
    CheckCase("Fokus: minutesToday zählt nur den heutigen Tag") {
      let (store, clock) = try p2Store("2024-03-03T10:00")
      let gestern = try store.focus.start(taskId: nil, title: "Gestern", phase: .work, minutes: 30)
      try store.focus.finish(gestern.id, completed: true)
      clock.set(try expectNotNil(LocalTime.parse("2024-03-04T08:00")))
      try p2Equal(try store.focus.minutesToday(), 0)
      _ = try store.focus.start(taskId: nil, title: "Heute", phase: .work, minutes: 15)
      try store.focus.finish(try expectNotNil(try store.focus.current()).id, completed: true)
      try p2Equal(try store.focus.minutesToday(), 15)
    },
    CheckCase("Fakten: add trimmt, leer wird abgelehnt, list ältestes zuerst, delete") {
      let (store, clock) = try p2Store("2024-03-04T08:00")
      let a = try store.memories.add("  Erster Fakt  ")
      try p2Equal(a.text, "Erster Fakt")
      clock.advance(seconds: 3600)
      let b = try store.memories.add("Zweiter")
      try await expectThrows("leerer Fakt muss fehlschlagen") { _ = try store.memories.add(" \n ") }
      try p2Equal(try store.memories.list().map(\.id), [a.id, b.id])
      try p2Equal(try store.memories.delete(a.id), true)
      try p2Equal(try store.memories.delete(a.id), false)
      try p2Equal(try store.memories.list().map(\.text), ["Zweiter"])
    },
    CheckCase("Migrationen 5–7 (Tagesabschluss, Fokus, Fakten): Tabellen da, idempotent beim erneuten Öffnen") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-p2-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.db").path
      let clock = ControllableClock("2024-03-04T08:00")
      do {
        let first = try Store.open(path: path, clock: clock)
        let tables = try first.db.tableNames()
        for t in ["day_end", "focus_sessions", "memories"] {
          try p2Equal(tables.contains(t), true, "Tabelle \(t) fehlt")
        }
        try first.memories.add("Bleibt")
      }
      let again = try Store.open(path: path, clock: clock)
      try p2Equal(try again.db.appliedMigrations(), Migrations.all.map(\.version))
      try p2Equal(Migrations.all.map(\.version).filter { (5...7).contains($0) }, [5, 6, 7])
      try p2Equal(try again.memories.list().map(\.text), ["Bleibt"], "Daten überleben das erneute Öffnen")
    },
  ]
}
