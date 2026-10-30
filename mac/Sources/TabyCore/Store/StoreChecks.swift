// Prüfungen für Sources/TabyCore/Store (Port von test/unit/store/*.test.ts).
// Echte SQLite-Datenbank (im Speicher bzw. Temp-Datei), steuerbare Uhr.
import Foundation

private func freshStore(_ now: String = "2024-03-04T08:00") throws -> (Store, ControllableClock) {
  let clock = ControllableClock(now)
  return (try Store.inMemory(clock: clock), clock)
}

private func ev(_ id: String, _ start: String, _ end: String? = nil, allDay: Bool = false, title: String = "Termin")
  -> CalendarEvent
{
  CalendarEvent(id: id, sourceId: "local", title: title, start: start, end: end, allDay: allDay)
}

enum StoreChecks {
  static let suite = CheckSuite(
    "Store",
    migrationChecks + repoChecks + systemRepoChecks + packageOneChecks + bufferChecks + conflictChecks
      + streakChecks + packageTwoChecks + backupChecks + taskFolderChecks + recurrenceChecks + noteTaskChecks + taskCategoryChecks)

  // MARK: Sicherungen

  static let backupChecks: [CheckCase] = [
    CheckCase("Sicherung: erstes Öffnen einer bestehenden Datei legt eine Sicherung an") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      _ = try Database.open(path: path, clock: clock)  // neue Datei: keine Sicherung
      try expectEqual(DatabaseBackup.backups(dir: DatabaseBackup.directory(for: path)), [])
      let db = try Database.open(path: path, clock: clock)  // bestehende Datei, keine Migration offen: keine Sicherung beim Öffnen
      try expectEqual(DatabaseBackup.backups(dir: DatabaseBackup.directory(for: path)), [])
      DatabaseBackup.dailyIfDue(db, clock: clock)  // Hintergrund-Sicherung (läuft 30 s nach dem Start)
      let names = DatabaseBackup.backups(dir: DatabaseBackup.directory(for: path))
      try expectEqual(names, ["taby-2024-03-04-0800.sqlite"])
      let copy = try Database.open(path: (DatabaseBackup.directory(for: path) as NSString)
        .appendingPathComponent(names[0]), clock: clock)
      try expect(try copy.tableNames().contains("tasks"), "Sicherung enthält Tabellen")
    },
    CheckCase("Sicherung: notion-lokal.json geht mit und kommt bei der Wiederherstellung zurück, Rotation räumt sie weg") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      let state = (dir.path as NSString).appendingPathComponent("notion-lokal.json")
      // Datenbank nur kurz offen: die Wiederherstellung verschiebt die Dateien unter ihr.
      let backup: String = try {
        let db = try Database.open(path: path, clock: clock)
        try "{\"deleted\":[\"abc\"]}".write(toFile: state, atomically: true, encoding: .utf8)
        return try DatabaseBackup.create(db, clock: clock)
      }()
      let sidecar = DatabaseBackup.notionSidecar(forBackup: backup)
      try expect(FileManager.default.fileExists(atPath: sidecar), "Sicherung enthält notion-lokal.json")
      try FileManager.default.removeItem(atPath: state)
      try RestorePlan.write(backup: (backup as NSString).lastPathComponent, dbPath: path, clock: clock)
      RestorePlan.applyIfPending(dbPath: path, clock: clock)
      let restored = try String(contentsOfFile: state, encoding: .utf8)
      try expect(restored.contains("abc"), "nach der Wiederherstellung zurück")
      // Rotation: die alte Sicherung (nicht die neueste) geht samt Begleitdatei.
      clock.advance(seconds: 40 * 86_400)
      let db = try Database.open(path: path, clock: clock)
      _ = try DatabaseBackup.create(db, clock: clock)
      DatabaseBackup.rotate(dir: DatabaseBackup.directory(for: path), days: 7, clock: clock)
      try expect(!FileManager.default.fileExists(atPath: backup), "alte Sicherung entfernt")
      try expect(!FileManager.default.fileExists(atPath: sidecar), "Begleitdatei mit der Sicherung entfernt")
    },
    CheckCase("Tagesprüfung: quick_check höchstens einmal pro Tag, Befund wird je Tag einmal gemeldet") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      let db = try Database.open(path: path, clock: clock)
      var checks = 0
      var notes: [String] = []
      let first = DatabaseBackup.dailyIntegrity(db, clock: clock, check: { _ in checks += 1; return "Seite 3 defekt" },
                                                onProblem: { notes.append($0) })
      try expectEqual(first, "Seite 3 defekt")
      _ = DatabaseBackup.dailyIntegrity(db, clock: clock, check: { _ in checks += 1; return "Seite 3 defekt" },
                                        onProblem: { notes.append($0) })
      try expectEqual(checks, 1, "am selben Tag nicht erneut prüfen")
      try expectEqual(notes.count, 1, "einmal am Tag melden")
      clock.advance(seconds: 86_400)
      _ = DatabaseBackup.dailyIntegrity(db, clock: clock, check: { _ in checks += 1; return nil }, onProblem: { notes.append($0) })
      try expectEqual(checks, 2, "am nächsten Tag wieder prüfen")
      try expectEqual(notes.count, 1, "in Ordnung wird nicht gemeldet")
    },
    CheckCase("Sicherung: höchstens einmal pro Tag, bei Schema-Migration trotzdem") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      let db = try Database.open(path: path, clock: clock)
      let backupDir = DatabaseBackup.directory(for: path)
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1)
      clock.advance(seconds: 3600)
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1, "gleicher Tag: keine zweite Sicherung")
      DatabaseBackup.beforeMigrate(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1, "ohne offene Migration keine Sicherung beim Öffnen")
      // Offene Migration (Version fehlt): Sicherung auch am selben Tag
      try db.run("DELETE FROM schema_migrations WHERE version = ?", [.of(Migrations.all.last!.version)])
      clock.advance(seconds: 60)
      DatabaseBackup.beforeMigrate(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 2, "offene Migration: Sicherung")
    },
    CheckCase("Sicherung: Rotation nach Alter, die neueste bleibt immer") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-01T08:00")
      let db = try Database.open(path: path, clock: clock)
      let backupDir = DatabaseBackup.directory(for: path)
      for _ in 0..<3 {
        try DatabaseBackup.create(db, clock: clock)
        clock.advance(seconds: 86_400)
      }
      // Stand 2024-03-04: 30 Tage Aufbewahrung behält alle drei.
      DatabaseBackup.rotate(dir: backupDir, days: 30, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 3)
      // 1 Tag Aufbewahrung: die beiden älteren fallen weg.
      DatabaseBackup.rotate(dir: backupDir, days: 1, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir), ["taby-2024-03-03-0800.sqlite"])
      // Auch die letzte Sicherung ist irgendwann zu alt, bleibt aber als neueste.
      clock.advance(seconds: 40 * 86_400)
      DatabaseBackup.rotate(dir: backupDir, days: 7, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir), ["taby-2024-03-03-0800.sqlite"], "neueste bleibt")
      // dailyIfDue mit den Tagen aus den Einstellungen rotiert auch ohne neue Sicherung.
      clock.advance(seconds: 3600)
      DatabaseBackup.dailyIfDue(db, clock: clock, retentionDays: 7)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1, "neueste bleibt, Tagessicherung legt eine an")
    },
    CheckCase("Sicherung: Rotation behält die neuesten 7 (alt)") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-01T08:00")
      let db = try Database.open(path: path, clock: clock)
      let backupDir = DatabaseBackup.directory(for: path)
      for _ in 0..<9 {
        try DatabaseBackup.create(db, clock: clock)
        clock.advance(seconds: 86_400)
      }
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 9)
      DatabaseBackup.rotate(dir: backupDir, days: 7, clock: clock)
      let kept = DatabaseBackup.backups(dir: backupDir)
      try expectEqual(kept.count, 7)
      try expectEqual(kept.first, "taby-2024-03-03-0800.sqlite", "älteste zwei gelöscht")
      try expectEqual(kept.last, "taby-2024-03-09-0800.sqlite")
    },
    CheckCase("Sicherung: quick_check-Fehler hebt die defekte Datei auf") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      // Eine Migration fehlt: nur dann prüft das Öffnen (quick_check) die Datei.
      do {
        let first = try Database.open(path: path, clock: clock)
        try first.run("DELETE FROM schema_migrations WHERE version = ?", [.of(Migrations.all.last!.version)])
      }
      // Eine Datenseite (ab Seite 3) mit Müll überschreiben, Kopfzeile bleibt.
      var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
      try expect(bytes.count >= 4096 * 4, "Datei groß genug")
      bytes.replaceSubrange(4096 * 2..<4096 * 3, with: Data(repeating: 0xFF, count: 4096))
      try bytes.write(to: URL(fileURLWithPath: path))
      _ = try? Database.open(path: path, clock: clock)  // Öffnen darf scheitern, die Kopie muss trotzdem da sein
      let broken = (try FileManager.default.contentsOfDirectory(atPath: DatabaseBackup.directory(for: path)))
        .filter { $0.hasPrefix("taby-broken-") && $0.hasSuffix(".sqlite") }
      try expectEqual(broken, ["taby-broken-2024-03-04-0800.sqlite"])
    },
    CheckCase("Sicherung: Tagessicherung im Betrieb höchstens einmal pro Tag") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      let db = try Database.open(path: path, clock: clock)
      let backupDir = DatabaseBackup.directory(for: path)
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1, "erste Tagessicherung")
      clock.advance(seconds: 3600)
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 1, "gleicher Tag: keine zweite")
      clock.advance(seconds: 86400)
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backupDir).count, 2, "neuer Tag: wieder eine")
    },
    CheckCase("Sicherung: defekte Kopien werden auf 3 begrenzt, die ältesten fallen weg") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-bak-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-04T08:00")
      let db = try Database.open(path: path, clock: clock)
      for _ in 0..<5 {
        DatabaseBackup.keepBroken(db, clock: clock)
        clock.advance(seconds: 60)
      }
      let broken = (try FileManager.default.contentsOfDirectory(atPath: DatabaseBackup.directory(for: path)))
        .filter { $0.hasPrefix("taby-broken-") && $0.hasSuffix(".sqlite") }.sorted()
      try expectEqual(broken, ["taby-broken-2024-03-04-0802.sqlite", "taby-broken-2024-03-04-0803.sqlite",
                               "taby-broken-2024-03-04-0804.sqlite"])
    },
  ]

  // MARK: Migrationen

  static let migrationChecks: [CheckCase] = [
    CheckCase("Migrationen: frische DB hat alle Tabellen aus Abschnitt 6") {
      let (store, _) = try freshStore()
      let tables = try store.db.tableNames()
      for t in ["tasks", "notes", "habits", "habit_checks", "local_events", "reminders", "jobs", "job_runs",
                "daily_state", "messages", "action_log", "calendar_sources", "app_settings", "llm_usage",
                "reminder_links", "schema_migrations"] {
        try expect(tables.contains(t), "Tabelle \(t) fehlt: \(tables)")
      }
      try expectEqual(try store.db.appliedMigrations(), Migrations.all.map(\.version))
    },
    CheckCase("Migrationen: Paket-1-Migrationen laufen auf frischer DB und sind idempotent") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-mig-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.db").path
      let clock = ControllableClock("2024-03-04T08:00")
      do {
        let fresh = try Store.open(path: path, clock: clock)
        try expectEqual(try fresh.db.appliedMigrations(), Migrations.all.map(\.version))
        try expect(Migrations.all.map(\.version).contains(3) && Migrations.all.map(\.version).contains(4))
        try fresh.usage.record(LlmUsage(model: "m", promptTokens: 1, completionTokens: 1, costUsd: 0.1))
      }
      let again = try Store.open(path: path, clock: clock)
      try expectEqual(try again.db.appliedMigrations(), Migrations.all.map(\.version))
      try expectEqual(try again.usage.summary(dailyLimit: 0, monthlyLimit: 0).todayTokens, 2, "Daten bleiben erhalten")
      let count = try again.db.query("SELECT COUNT(*) AS n FROM schema_migrations").first?.int("n")
      try expectEqual(count, Int64(Migrations.all.count))
    },
    CheckCase("Migrationen: Fremdschlüssel sind aktiv") {
      let (store, _) = try freshStore()
      try await expectThrows("habit_checks ohne Habit muss scheitern") {
        try store.db.run("INSERT INTO habit_checks (habit_id, date) VALUES ('fehlt', '2024-03-04')")
      }
    },
    CheckCase("Migrationen: erneutes Öffnen derselben Datei ist idempotent und erhält Daten") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-store-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("sub/taby.db").path
      let clock = ControllableClock("2024-03-04T08:00")
      do {
        let s = try Store.open(path: path, clock: clock)
        try s.tasks.add(title: "Bleibt erhalten")
      }
      let again = try Store.open(path: path, clock: clock)
      try expectEqual(try again.tasks.list().map(\.title), ["Bleibt erhalten"])
      try expectEqual(try again.db.appliedMigrations(), Migrations.all.map(\.version))
      let count = try again.db.query("SELECT COUNT(*) AS n FROM schema_migrations").first?.int("n")
      try expectEqual(count, Int64(Migrations.all.count))
    },
    CheckCase("SQLite: Transaktion rollt bei Fehler zurück") {
      let (store, _) = try freshStore()
      try await expectThrows {
        try store.db.transaction {
          try store.tasks.add(title: "halb")
          throw ToolValidationError("Abbruch")
        }
      }
      try expectEqual(try store.tasks.list().count, 0)
    },
  ]

  // MARK: Aufgaben, Notizen, Habits, Termine

  static let repoChecks: [CheckCase] = [
    CheckCase("Aufgaben: anlegen und zurücklesen, createdAt aus der Uhr (lokal)") {
      let (store, _) = try freshStore()
      let t = try store.tasks.add(title: "Einkaufen", due: "2024-03-05")
      try expect(!t.done)
      try expectEqual(t.createdAt, "2024-03-04T08:00")
      try expectEqual(try store.tasks.get(t.id)?.title, "Einkaufen")
      try expectEqual(try store.tasks.get(t.id)?.due, "2024-03-05")
      try expect(t.id.count == 36, "UUID erwartet: \(t.id)")
    },
    CheckCase("Aufgaben: complete/reopen ändern done und doneAt") {
      let (store, clock) = try freshStore()
      let t = try store.tasks.add(title: "X")
      clock.set(LocalTime.parse("2024-03-04T09:00")!)
      let done = try expectNotNil(try store.tasks.complete(t.id))
      try expect(done.done)
      try expectEqual(done.doneAt, "2024-03-04T09:00")
      let reopened = try expectNotNil(try store.tasks.reopen(t.id))
      try expect(!reopened.done)
      try expect(reopened.doneAt == nil)
      try expect(try store.tasks.complete("fehlt") == nil)
    },
    CheckCase("Aufgaben: update (inkl. Leeren) und delete") {
      let (store, _) = try freshStore()
      let t = try store.tasks.add(title: "Alt", notes: "n", due: "2024-03-05")
      try expectEqual(try store.tasks.update(t.id, title: "Neu")?.title, "Neu")
      let cleared = try expectNotNil(try store.tasks.update(t.id, notes: .set(nil), due: .keep))
      try expect(cleared.notes == nil)
      try expectEqual(cleared.due, "2024-03-05")
      let viaPatch = try expectNotNil(try store.tasks.update(t.id, TaskPatch(due: "")))
      try expect(viaPatch.due == nil, "leerer Text im Patch leert due")
      try expectEqual(viaPatch.title, "Neu")
      try expect(try store.tasks.update("fehlt", title: "x") == nil)
      try expect(try store.tasks.delete(t.id))
      try expect(try store.tasks.get(t.id) == nil)
      try expect(!(try store.tasks.delete(t.id)))
    },
    CheckCase("Aufgaben: Liste in Anlage-Reihenfolge, auch bei gleicher Minute") {
      let (store, _) = try freshStore()
      for title in ["a", "b", "c"] { try store.tasks.add(title: title) }
      try expectEqual(try store.tasks.list().map(\.title), ["a", "b", "c"])
    },
    CheckCase("Notizen: anlegen, LIKE-Suche, updatedAt, löschen") {
      let (store, clock) = try freshStore()
      let n = try store.notes.add(title: "Einkaufsliste", content: "Milch, Brot")
      try expectEqual(try store.notes.search("Milch").count, 1)
      try expectEqual(try store.notes.search("einkauf").count, 1)
      try expectEqual(try store.notes.search("Käse").count, 0)
      try expectEqual(try store.notes.search("%").count, 0, "% ist kein Platzhalter")
      clock.set(LocalTime.parse("2024-03-04T09:00")!)
      let u = try expectNotNil(try store.notes.update(n.id, content: "Milch, Brot, Käse"))
      try expect(u.content.contains("Käse"))
      try expectEqual(u.title, "Einkaufsliste")
      try expect(u.updatedAt != n.updatedAt)
      try expectEqual(u.createdAt, n.createdAt)
      try expect(try store.notes.delete(n.id))
      try expectEqual(try store.notes.list().count, 0)
    },
    CheckCase("Habits: streak und checkedToday aus echten Haken") {
      let (store, _) = try freshStore()
      let h = try store.habits.add(name: "Lesen")
      try expectEqual(h.streak, 0)
      try expect(!h.checkedToday)
      _ = try store.habits.check(h.id, date: "2024-03-03")
      let after = try expectNotNil(try store.habits.check(h.id, date: "2024-03-04"))
      try expectEqual(after.streak, 2)
      try expect(after.checkedToday)
      let again = try expectNotNil(try store.habits.check(h.id, date: "2024-03-04"))
      try expectEqual(again.streak, 2, "doppeltes Abhaken verdoppelt nicht")
      try expectEqual(try store.habits.checkCount(h.id), 2)
      try expect(try store.habits.check("fehlt", date: "2024-03-04") == nil)
    },
    CheckCase("Habits: Streak folgt der Uhr (Tageswechsel)") {
      let (store, clock) = try freshStore("2024-03-04T23:50")
      let h = try store.habits.add(name: "Sport")
      _ = try store.habits.check(h.id, date: "2024-03-04")
      clock.advance(seconds: 20 * 60)  // 2024-03-05T00:10
      let next = try expectNotNil(try store.habits.get(h.id))
      try expect(!next.checkedToday)
      try expectEqual(next.streak, 1, "gestern abgehakt: Serie läuft weiter")
      clock.advance(seconds: 24 * 3600)  // 2024-03-06
      try expectEqual(try store.habits.get(h.id)?.streak, 0)
      let unchecked = try expectNotNil(try store.habits.uncheck(h.id, date: "2024-03-04"))
      try expectEqual(unchecked.streak, 0)
    },
    CheckCase("Habits: delete entfernt Habit und Haken") {
      let (store, _) = try freshStore()
      let h = try store.habits.add(name: "Sport")
      _ = try store.habits.check(h.id, date: "2024-03-04")
      try expect(try store.habits.delete(h.id))
      try expectEqual(try store.habits.checkCount(h.id), 0)
      try expectEqual(try store.habits.list().count, 0)
      try expect(!(try store.habits.delete(h.id)))
    },
    CheckCase("Lokale Termine: anlegen, Zeitraum (from inkl., to exkl.), ganztägig") {
      let (store, _) = try freshStore()
      let e = try store.events.add(NewEvent(title: "Zahnarzt", start: "2024-03-05T14:00"))
      try expectEqual(e.sourceId, "local")
      try expect(!e.allDay)
      try expectEqual(try store.events.list(from: "2024-03-05", to: "2024-03-06").map(\.id), [e.id])
      try expectEqual(try store.events.list(from: "2024-03-06", to: "2024-03-07").count, 0)
      try expectEqual(try store.events.list(from: "2024-03-04", to: "2024-03-05").count, 0)
      let u = try store.events.add(NewEvent(title: "Urlaub", start: "2024-03-05"))
      try expect(u.allDay)
      try expectEqual(try store.events.listAll().map(\.title), ["Urlaub", "Zahnarzt"])
    },
  ]

  // MARK: Erinnerungen, Aufträge, Tagesstart, Chat, Protokoll, Quellen, Einstellungen

  static let systemRepoChecks: [CheckCase] = [
    CheckCase("Erinnerungen: verpasst = offen, unbestätigt und überfällig") {
      let (store, _) = try freshStore()
      let r1 = try store.reminders.add(source: .task, sourceRef: "t1", dueAt: "2024-03-04T08:00")
      try store.reminders.add(source: .task, sourceRef: "t2", dueAt: "2024-03-04T12:00")
      try expectEqual(try store.reminders.listMissed(now: "2024-03-04T10:00").map(\.id), [r1.id])
      try store.reminders.markFired(r1.id, at: "2024-03-04T10:01")
      try expectEqual(try store.reminders.listMissed(now: "2024-03-04T10:00").count, 0)
      try expectEqual(try store.reminders.listOpen().map(\.sourceRef), ["t2"])
    },
    CheckCase("Erinnerungen: bestätigen setzt acknowledgedAt, verpasst ist dann leer") {
      let (store, _) = try freshStore()
      let r = try store.reminders.add(source: .event, sourceRef: "e1", dueAt: "2024-03-04T08:00")
      try store.reminders.acknowledge([r.id], at: "2024-03-04T09:00")
      let row = try store.db.query("SELECT acknowledged_at FROM reminders WHERE id = ?", [.text(r.id)]).first
      try expectEqual(row?.string("acknowledged_at"), "2024-03-04T09:00")
      try expectEqual(try store.reminders.listMissed(now: "2024-03-04T10:00").count, 0)
    },
    CheckCase("Erinnerungen: upsert aktualisiert dueAt/firedAt, behält acknowledgedAt; find nach Quelle") {
      let (store, _) = try freshStore()
      let r = try store.reminders.add(source: .task, sourceRef: "t1", dueAt: "2024-03-04T08:00")
      try store.reminders.acknowledge([r.id], at: "2024-03-04T07:00")
      var moved = r
      moved.dueAt = "2024-03-05T08:00"
      try store.reminders.upsert(moved)
      let got = try expectNotNil(try store.reminders.find(source: .task, sourceRef: "t1"))
      try expectEqual(got.dueAt, "2024-03-05T08:00")
      try expectEqual(got.acknowledgedAt, "2024-03-04T07:00")
      try expectEqual(try store.reminders.listAll().count, 1)
      try expect(try store.reminders.find(source: .event, sourceRef: "t1") == nil)
      try expect(try store.reminders.delete(r.id))
    },
    CheckCase("Aufträge: Regel als JSON (TS-Form), Standardmodus read-only") {
      let (store, _) = try freshStore()
      let job = try store.jobs.add(name: "Montag", prompt: "Wochenplanung", rule: .weekly(days: [1], time: "08:00"))
      try expectEqual(job.mode, .readOnly)
      try expectEqual(try store.jobs.get(job.id)?.rule, .weekly(days: [1], time: "08:00"))
      let raw = try store.db.query("SELECT rule FROM jobs WHERE id = ?", [.text(job.id)]).first?.string("rule")
      try expectEqual(raw, #"{"days":[1],"time":"08:00","type":"weekly"}"#)
    },
    CheckCase("Aufträge: cancel schaltet erst aus, zweites Mal entfernt") {
      let (store, _) = try freshStore()
      let gone = try store.jobs.add(name: "Weg", prompt: "x", rule: .once(at: "2024-03-10T08:00"))
      try expect(try store.jobs.cancel(gone.id))
      try expectEqual(try store.jobs.get(gone.id)?.enabled, false)
      try expect(try store.jobs.cancel(gone.id), "beendeter Auftrag wird entfernt")
      try expect(try store.jobs.get(gone.id) == nil, "nicht mehr in der Liste")
      try expect(!(try store.jobs.cancel(gone.id)), "unbekannt")
    },
    CheckCase("Aufträge: markRan, Läufe") {
      let (store, _) = try freshStore()
      let job = try store.jobs.add(name: "Once", prompt: "x", rule: .once(at: "2024-03-10T08:00"))
      try store.jobs.markRan(job.id, at: "2024-03-10T08:00")
      try expectEqual(try store.jobs.get(job.id)?.lastRunAt, "2024-03-10T08:00")
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2024-03-10T08:00", startedAt: "2024-03-10T08:01",
                            status: .ok, output: "fertig")
      let runs = try store.jobs.listRuns(jobId: job.id)
      try expectEqual(runs.count, 1)
      try expectEqual(runs.first?.status, .ok)
      try expectEqual(runs.first?.output, "fertig")
    },
    CheckCase("Verbrauch: Monats- und Tagessumme über die Bereichsabfrage (Februar und April zählen nicht)") {
      let (store, clock) = try freshStore("2024-02-20T10:00")
      try store.usage.record(LlmUsage(model: "m", promptTokens: 10, completionTokens: 5, costUsd: 1.0))
      clock.set(try expectNotNil(LocalTime.parse("2024-02-29T23:00")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 10, completionTokens: 5, costUsd: 1.0))
      clock.set(try expectNotNil(LocalTime.parse("2024-03-01T00:30")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 10, completionTokens: 5, costUsd: 2.0))
      clock.set(try expectNotNil(LocalTime.parse("2024-03-10T09:00")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 10, completionTokens: 5, costUsd: 0.5))
      clock.set(try expectNotNil(LocalTime.parse("2024-04-01T08:00")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 10, completionTokens: 5, costUsd: 9.0))
      clock.set(try expectNotNil(LocalTime.parse("2024-03-10T10:00")))
      let s = try store.usage.summary(dailyLimit: 0, monthlyLimit: 0)
      try expectEqual(s.monthUsd, 2.5, "März: 2,0 + 0,5")
      try expectEqual(s.todayUsd, 0.5)
      try expectEqual(s.monthTokens, 30, "zwei Antworten im März zu je 15 Tokens")
      try expectEqual(s.todayTokens, 15)
    },
    CheckCase("Aufträge: jüngster Lauf per Abfrage, ohne alle Läufe zu laden") {
      let (store, _) = try freshStore()
      let job = try store.jobs.add(name: "Täglich", prompt: "x", rule: .once(at: "2024-03-10T08:00"))
      try expect(try store.jobs.latestRun(jobId: job.id) == nil, "noch kein Lauf")
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2024-03-08T08:00", startedAt: "2024-03-08T08:00", status: .ok, output: "a")
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2024-03-10T08:00", startedAt: "2024-03-10T08:00", status: .ok, output: "b")
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2024-03-09T08:00", startedAt: "2024-03-09T08:00", status: .ok, output: "c")
      let latest = try expectNotNil(try store.jobs.latestRun(jobId: job.id))
      try expectEqual(latest.scheduledFor, "2024-03-10T08:00")
      try expectEqual(latest.output, "b")
    },
    CheckCase("Aufbewahrung: Läufe über 90 Tage und Verbrauch über 400 Tage gehen, neuere bleiben") {
      let (store, clock) = try freshStore("2024-03-10T08:00")
      let job = try store.jobs.add(name: "Alt", prompt: "x", rule: .once(at: "2023-11-01T08:00"))
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2023-11-01T08:00", startedAt: "2023-11-01T08:00", status: .ok)
      try store.jobs.addRun(jobId: job.id, scheduledFor: "2024-02-01T08:00", startedAt: "2024-02-01T08:00", status: .ok)
      try store.jobs.pruneRuns(keepDays: 90)
      try expectEqual(try store.jobs.listRuns(jobId: job.id).map(\.scheduledFor), ["2024-02-01T08:00"])
      clock.set(try expectNotNil(LocalTime.parse("2023-01-15T10:00")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 1, completionTokens: 1, costUsd: 1))
      clock.set(try expectNotNil(LocalTime.parse("2024-02-01T10:00")))
      try store.usage.record(LlmUsage(model: "m", promptTokens: 1, completionTokens: 1, costUsd: 1))
      clock.set(try expectNotNil(LocalTime.parse("2024-03-10T08:00")))
      try store.usage.prune(keepDays: 400)
      let rows = try store.db.query("SELECT COUNT(*) AS n FROM llm_usage")
      try expectEqual(rows.first?.int("n"), 1, "nur der Eintrag von 2024-02-01 bleibt")
      try store.jobs.pruneRuns(keepDays: 0)  // 0 = nie löschen
      try expectEqual(try store.jobs.listRuns(jobId: job.id).count, 1)
    },
    CheckCase("Schema: Indizes für Nachrichten, Verbrauch und Läufe sind angelegt") {
      let (store, _) = try freshStore()
      let names = Set(try store.db.query("SELECT name FROM sqlite_master WHERE type = 'index'").compactMap { $0.text("name") })
      try expect(names.isSuperset(of: ["idx_messages_created_at", "idx_llm_usage_at", "idx_job_runs_job_scheduled"]),
                 "fehlende Indizes: \(names)")
    },
    CheckCase("Start: Prüfung und Sicherung nur bei ausstehender Migration; sonst später im Hintergrund") {
      try expectEqual(DatabaseBackup.startupPlan(pendingMigration: false),
                      DatabaseBackup.StartupPlan(quickCheck: false, backupNow: false))
      try expectEqual(DatabaseBackup.startupPlan(pendingMigration: true),
                      DatabaseBackup.StartupPlan(quickCheck: true, backupNow: true))
    },
    CheckCase("Start: ohne Migration keine Sicherung beim Öffnen, die tägliche läuft danach im Hintergrund") {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-backup-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("taby.sqlite").path
      let clock = ControllableClock("2024-03-10T08:00")
      _ = try Database.open(path: path, clock: clock)  // neue Datei: keine Sicherung
      let db = try Database.open(path: path, clock: clock)  // bestehende Datei, Migrationen aktuell
      let backups = DatabaseBackup.directory(for: path)
      try expectEqual(DatabaseBackup.backups(dir: backups).count, 0, "beim Öffnen keine Sicherung")
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backups).count, 1, "tägliche Sicherung im Hintergrund")
      DatabaseBackup.dailyIfDue(db, clock: clock)
      try expectEqual(DatabaseBackup.backups(dir: backups).count, 1, "höchstens eine pro Tag")
    },
    CheckCase("Tagesstart: anlegen und per upsert aktualisieren") {
      let (store, _) = try freshStore()
      try expect(try store.dailyState.get("2024-03-04") == nil)
      try store.dailyState.set("2024-03-04", .asked)
      try expectEqual(try store.dailyState.get("2024-03-04")?.state, .asked)
      try store.dailyState.set("2024-03-04", .snoozed, snoozeUntil: "2024-03-04T09:00")
      let after = try expectNotNil(try store.dailyState.get("2024-03-04"))
      try expectEqual(after.state, .snoozed)
      try expectEqual(after.snoozeUntil, "2024-03-04T09:00")
      try store.dailyState.set("2024-03-04", .done)
      try expect(try store.dailyState.get("2024-03-04")?.snoozeUntil == nil)
    },
    CheckCase("Chat: Rundreise inkl. tool_calls, Reihenfolge, Limit, Leeren") {
      let (store, _) = try freshStore()
      try store.messages.add(ChatMessage(role: .user, content: "Hallo"))
      try store.messages.add(ChatMessage(role: .assistant, content: nil,
                                         toolCalls: [ToolCall(id: "c1", name: "add_task", arguments: "{}")]))
      try store.messages.add(ChatMessage(role: .tool, content: "{\"ok\":true}", name: "add_task", toolCallId: "c1"))
      let all = try store.messages.list(limit: 50)
      try expectEqual(all.map(\.role), [.user, .assistant, .tool])
      try expectEqual(all[1].toolCalls?.first?.function.name, "add_task")
      try expectEqual(all[2].toolCallId, "c1")
      try expectEqual(try store.messages.list(limit: 2).map(\.role), [.assistant, .tool])
      try store.messages.clear()
      try expectEqual(try store.messages.list(limit: 50).count, 0)
    },
    CheckCase("Chat: Aufräumen behält die letzten Tage (heute zählt mit), 0 = nie") {
      let (store, clock) = try freshStore("2024-03-10T08:00")
      for (day, text) in [("2024-03-01T10:00", "alt"), ("2024-03-08T10:00", "mittel"), ("2024-03-10T09:00", "heute")] {
        clock.set(try expectNotNil(LocalTime.parse(day)))
        try store.messages.add(ChatMessage(role: .user, content: text))
      }
      try store.messages.prune(keepDays: 0)
      try expectEqual(try store.messages.list(limit: 50).count, 3)
      try store.messages.prune(keepDays: 7)  // 04.03. bis 10.03. bleiben: „alt“ (01.03.) fällt weg
      try expectEqual(try store.messages.list(limit: 50).compactMap(\.content), ["mittel", "heute"])
      try store.messages.prune(keepDays: 1)  // nur heute
      try expectEqual(try store.messages.list(limit: 50).compactMap(\.content), ["heute"])
    },
    CheckCase("Protokoll: ok und Fehler, neueste zuerst") {
      let (store, _) = try freshStore()
      try store.actionLog.log(actor: .user, tool: "add_task", args: ["title": "X"], ok: true)
      try store.actionLog.log(actor: .assistant, tool: "delete_task", args: ["id": "missing"], ok: false,
                              error: "nicht gefunden")
      let entries = try store.actionLog.list(limit: 10)
      try expectEqual(entries.count, 2)
      try expectEqual(entries.first?.tool, "delete_task")
      try expect(entries.contains { !$0.ok && $0.error == "nicht gefunden" })
      try expectEqual(entries.last?.argsJson, #"{"title":"X"}"#)
      try expectEqual(entries.last?.at, "2024-03-04T08:00")
    },
    CheckCase("Kalenderquellen: anlegen, aktive filtern, Konfiguration als JSON") {
      let (store, _) = try freshStore()
      try store.calendarSources.add(kind: .local, isDefaultWrite: true)
      let ics = try store.calendarSources.add(kind: .ics, config: ["url": "https://example.invalid/cal.ics"],
                                              enabled: false)
      try expectEqual(try store.calendarSources.list().count, 2)
      try expectEqual(try store.calendarSources.listActive().count, 1)
      try expectEqual(try store.calendarSources.get(ics.id)?.config["url"], "https://example.invalid/cal.ics")
    },
    CheckCase("Kalenderquellen: upsert, höchstens ein Standard-zum-Schreiben") {
      let (store, _) = try freshStore()
      let local = try store.calendarSources.add(kind: .local, isDefaultWrite: true)
      let created = try expectNotNil(try store.calendarSources.upsert(
        CalendarSourceDraft(kind: .notion, config: ["databaseId": "abc"], isDefaultWrite: true)))
      try expect(created.enabled)
      try expectEqual(try store.calendarSources.get(local.id)?.isDefaultWrite, false)
      let updated = try expectNotNil(try store.calendarSources.upsert(
        CalendarSourceDraft(id: created.id, kind: .notion, enabled: false)))
      try expect(!updated.enabled)
      try expectEqual(updated.config["databaseId"], "abc", "nil-Felder bleiben")
      try expect(try store.calendarSources.upsert(CalendarSourceDraft(id: "fehlt", kind: .ics)) == nil)
      try expect(try store.calendarSources.delete(created.id))
    },
    CheckCase("Einstellungen: Standardwerte, Patch, hasApiKey nie aus der DB") {
      let (store, _) = try freshStore()
      try expectEqual(try store.settings.get(), TabySettings.defaults)
      let s = try store.settings.update(SettingsPatch(llmModel: "anthropic/claude", personality: .coach,
                                                      reminderLeadMinutes: 0, askAfterUnlock: true), hasApiKey: true)
      try expectEqual(s.llmModel, "anthropic/claude")
      try expectEqual(s.personality, .coach)
      try expectEqual(s.reminderLeadMinutes, 0)
      try expect(s.askAfterUnlock)
      try expect(s.hasApiKey)
      try expectEqual(s.llmBaseUrl, TabySettings.defaults.llmBaseUrl)
      let reread = try store.settings.get()
      try expect(!reread.hasApiKey)
      try expectEqual(reread.personality, .coach)
      let keys = try store.db.query("SELECT key FROM app_settings").map { $0.text("key") }
      let allowed: Set<String> = ["llmBaseUrl", "llmModel", "personality", "customInstructions",
                                  "reminderLeadMinutes", "startOnLogin", "globalShortcut", "askAfterUnlock",
                                  "briefingModel", "bufferMinutes", "dailyCostLimitUsd", "monthlyCostLimitUsd",
                                  "quickCaptureShortcut", "appleRemindersSync", "appleRemindersListId"]
      try expect(Set(keys).isSubset(of: allowed), "nur nicht-geheime Felder gespeichert: \(keys)")
      try expect(!keys.contains("hasApiKey"))
    },
  ]

  // MARK: Paket 1: Einstellungen, Verbrauch, Erinnerungs-Verknüpfungen

  static let packageOneChecks: [CheckCase] = [
    CheckCase("Einstellungen: Briefing-Vorgabe und Vorlese-Fenster überleben Speichern und Lesen") {
      let (store, _) = try freshStore()
      _ = try store.settings.update(SettingsPatch(readAloudMinutes: 2, briefingPrompt: "Kurz und knapp."))
      let reread = try store.settings.get()
      try expectEqual(reread.briefingPrompt, "Kurz und knapp.")
      try expectEqual(reread.readAloudMinutes, 5)
    },
    CheckCase("Einstellungen Paket 1: alle sieben neuen Felder überleben Speichern und Lesen") {
      let (store, _) = try freshStore()
      let s = try store.settings.update(SettingsPatch(
        briefingModel: "openai/gpt-4o-mini", bufferMinutes: 15, dailyCostLimitUsd: 0.5, monthlyCostLimitUsd: 12.25,
        quickCaptureShortcut: "Control+Option+M", appleRemindersSync: true, appleRemindersListId: "list-7"))
      try expectEqual(s.briefingModel, "openai/gpt-4o-mini")
      try expectEqual(s.bufferMinutes, 15)
      try expectEqual(s.dailyCostLimitUsd, 0.5)
      try expectEqual(s.monthlyCostLimitUsd, 12.25)
      try expectEqual(s.quickCaptureShortcut, "Control+Option+M")
      try expect(s.appleRemindersSync)
      try expectEqual(s.appleRemindersListId, "list-7")
      let reread = try store.settings.get()
      try expectEqual(reread.briefingModel, "openai/gpt-4o-mini")
      try expectEqual(reread.bufferMinutes, 15)
      try expectEqual(reread.dailyCostLimitUsd, 0.5)
      try expectEqual(reread.monthlyCostLimitUsd, 12.25)
      try expectEqual(reread.quickCaptureShortcut, "Control+Option+M")
      try expect(reread.appleRemindersSync)
      try expectEqual(reread.appleRemindersListId, "list-7")
    },
    CheckCase("Einstellungen Paket 1: Standardwerte und Klammern auf 0") {
      let (store, _) = try freshStore()
      let d = try store.settings.get()
      try expectEqual(d.bufferMinutes, 0)
      try expectEqual(d.dailyCostLimitUsd, 0)
      try expectEqual(d.quickCaptureShortcut, "Control+Option+N")
      try expect(!d.appleRemindersSync)
      try expectEqual(d.briefingModel, "")
      let clamped = try store.settings.update(SettingsPatch(bufferMinutes: -5, dailyCostLimitUsd: -1,
                                                            monthlyCostLimitUsd: -2))
      try expectEqual(clamped.bufferMinutes, 0)
      try expectEqual(clamped.dailyCostLimitUsd, 0)
      try expectEqual(clamped.monthlyCostLimitUsd, 0)
    },
    CheckCase("Verbrauch: Summen heute/Monat, NULL-Kosten als 0, Tokens = Prompt + Antwort") {
      let (store, clock) = try freshStore("2024-03-03T23:00")
      try store.usage.record(LlmUsage(model: "a", promptTokens: 10, completionTokens: 10, costUsd: 1.0))
      clock.set(LocalTime.parse("2024-03-04T08:00")!)
      try store.usage.record(LlmUsage(model: "a", promptTokens: 100, completionTokens: 50, costUsd: 0.5))
      try store.usage.record(LlmUsage(model: "b", promptTokens: 200, completionTokens: 100, costUsd: nil))
      let s = try store.usage.summary(dailyLimit: 0, monthlyLimit: 0)
      try expectEqual(s.todayUsd, 0.5, "heute: nur der 4. März zählt")
      try expectEqual(s.monthUsd, 1.5, "Monat: 3. und 4. März")
      try expectEqual(s.todayTokens, 450)
      try expectEqual(s.monthTokens, 470)
      try expect(!s.limitReached)
      try expect(!s.nearLimit)
    },
    CheckCase("Verbrauch: limitReached ab dem Limit, nearLimit ab 80 %") {
      let (store, clock) = try freshStore("2024-03-04T08:00")
      try store.usage.record(LlmUsage(model: "a", promptTokens: 1, completionTokens: 1, costUsd: 0.5))
      let atDailyLimit = try store.usage.summary(dailyLimit: 0.5, monthlyLimit: 0)
      try expect(atDailyLimit.limitReached, "bei exakt erreichtem Tageslimit gesperrt")
      try expect(atDailyLimit.nearLimit)
      let nearDaily = try store.usage.summary(dailyLimit: 0.6, monthlyLimit: 0)
      try expect(!nearDaily.limitReached)
      try expect(nearDaily.nearLimit, "0,5 von 0,6 ist über 80 %")
      let farFromDaily = try store.usage.summary(dailyLimit: 1.0, monthlyLimit: 0)
      try expect(!farFromDaily.nearLimit, "0,5 von 1,0 ist unter 80 %")
      try expect(!(try store.usage.summary(dailyLimit: 0, monthlyLimit: 0)).limitReached, "Limit 0 = kein Limit")
      try expect(!(try store.usage.summary(dailyLimit: 0, monthlyLimit: 0)).nearLimit)
      let monthly = try store.usage.summary(dailyLimit: 0, monthlyLimit: 0.5)
      try expect(monthly.limitReached, "Monatslimit allein sperrt auch")
      clock.set(LocalTime.parse("2024-04-01T00:30")!)
      let april = try store.usage.summary(dailyLimit: 0.1, monthlyLimit: 0.5)
      try expectEqual(april.todayUsd, 0)
      try expectEqual(april.monthUsd, 0, "neuer Monat beginnt bei 0")
      try expect(!april.limitReached)
    },
    CheckCase("Erinnerungs-Verknüpfungen: anlegen, aktualisieren, lesen, löschen") {
      let (store, _) = try freshStore()
      let link = StoredReminderLink(taskId: "t1", externalId: "x-1", snapTitle: "Milch", snapDue: nil,
                                    snapDone: false, syncedAt: "2024-03-04T08:00")
      try store.reminderLinks.upsert(link)
      try expectEqual(try store.reminderLinks.all(), [link])
      var changed = link
      changed.snapTitle = "Milch, Brot"
      changed.snapDue = "2024-03-05T09:00"
      changed.snapDone = true
      try store.reminderLinks.upsert(changed)
      try expectEqual(try store.reminderLinks.all(), [changed], "Upsert ersetzt, legt nicht doppelt an")
      try expect(try store.reminderLinks.delete(taskId: "t1"))
      try expectEqual(try store.reminderLinks.all().count, 0)
      try expect(!(try store.reminderLinks.delete(taskId: "t1")), "zweites Löschen meldet false")
    },
    CheckCase("Erinnerungs-Verknüpfungen: Liste wird gespeichert und gelesen (Migration 19)") {
      let (store, _) = try freshStore()
      try store.reminderLinks.upsert(StoredReminderLink(taskId: "t1", externalId: "x-1", snapTitle: "Milch", snapDue: nil,
                                                        snapDone: false, syncedAt: "2024-03-04T08:00", listId: "L2"))
      try expectEqual(try store.reminderLinks.all().first?.listId, "L2")
      try store.reminderLinks.upsert(StoredReminderLink(taskId: "t1", externalId: "x-1", snapTitle: "Milch", snapDue: nil,
                                                        snapDone: false, syncedAt: "2024-03-04T08:00"))
      try expectEqual(try store.reminderLinks.all().first?.listId, nil, "ohne Liste bleibt nil")
    },
    CheckCase("Erinnerungs-Verknüpfungen: externe Kennung ist eindeutig") {
      let (store, _) = try freshStore()
      try store.reminderLinks.upsert(StoredReminderLink(taskId: "t1", externalId: "dup", snapTitle: "A",
                                                        snapDone: false, syncedAt: "2024-03-04T08:00"))
      try await expectThrows("gleiche externe Kennung für zwei Aufgaben muss scheitern") {
        try store.reminderLinks.upsert(StoredReminderLink(taskId: "t2", externalId: "dup", snapTitle: "B",
                                                          snapDone: false, syncedAt: "2024-03-04T08:00"))
      }
    },
  ]

  // MARK: Puffer zwischen Terminen (Paket 1)

  static let bufferChecks: [CheckCase] = [
    CheckCase("Puffer: Abstand kleiner als Puffer ist tooClose") {
      // Bestehend 10:00–11:00, neu 11:10–12:00: 10 Minuten Abstand bei Puffer 15
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T11:10", end: "2024-03-04T12:00"),
                            [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 15)
      try expectEqual(c.map(\.kind), [.tooClose])
      try expectEqual(c.first?.with.id, "1")
    },
    CheckCase("Puffer: genau der Puffer ist ausreichend (kein Konflikt)") {
      let after = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T11:15", end: "2024-03-04T12:00"),
                                [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 15)
      try expectEqual(after.count, 0)
      let before = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T08:00", end: "2024-03-04T09:45"),
                                 [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 15)
      try expectEqual(before.count, 0, "Ende 09:45 ist genau 15 Minuten vor 10:00")
    },
    CheckCase("Puffer: knapp davor ist tooClose, auch wenn der neue Termin früher endet") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T08:00", end: "2024-03-04T09:50"),
                            [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 15)
      try expectEqual(c.map(\.kind), [.tooClose])
    },
    CheckCase("Puffer: Überschneidung bleibt overlap bzw. same-start") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:30", end: "2024-03-04T11:30"),
                            [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 15)
      try expectEqual(c.map(\.kind), [.overlap])
    },
    CheckCase("Puffer: ganztägige Termine zählen nie, auch nicht mit Puffer") {
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:05", end: "2024-03-04T10:30"),
                                    [ev("1", "2024-03-04", allDay: true)], bufferMinutes: 60).count, 0)
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04"),
                                    [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 60).count, 0)
    },
    CheckCase("Puffer 0: Berührung bleibt ohne Konflikt") {
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T11:00", end: "2024-03-04T12:00"),
                                    [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")], bufferMinutes: 0).count, 0)
    },
  ]

  // MARK: Konflikte (Port von conflicts.test.ts)

  static let conflictChecks: [CheckCase] = [
    CheckCase("Konflikt: echte Überschneidung ist overlap") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:30", end: "2024-03-04T11:30"),
                            [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")])
      try expectEqual(c.count, 1)
      try expectEqual(c.first?.kind, .overlap)
      try expectEqual(c.first?.with.id, "1")
    },
    CheckCase("Konflikt: gleicher Start ist same-start") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:00", end: "2024-03-04T10:30"),
                            [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")])
      try expectEqual(c.map(\.kind), [.sameStart])
    },
    CheckCase("Konflikt: Berührung (Ende A = Start B) ist keiner") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:00", end: "2024-03-04T11:00"),
                            [ev("1", "2024-03-04T11:00", "2024-03-04T12:00")])
      try expectEqual(c.count, 0)
    },
    CheckCase("Konflikt: fehlendes Ende = start + 60 Minuten") {
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:30"),
                                    [ev("1", "2024-03-04T10:00")]).count, 1)
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T11:00"),
                                    [ev("1", "2024-03-04T10:00")]).count, 0)
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T09:30"),
                                    [ev("1", "2024-03-04T10:00")]).count, 1, "neuer Termin ohne Ende reicht hinein")
    },
    CheckCase("Konflikt: ganztägig ist nie ein Konflikt (neu oder bestehend)") {
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04"),
                                    [ev("1", "2024-03-04T10:00", "2024-03-04T11:00")]).count, 0)
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:00", end: "2024-03-04T11:00"),
                                    [ev("1", "2024-03-04", allDay: true)]).count, 0)
      // Datumsform ohne allDay-Flag zählt ebenfalls als ganztägig
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:00"),
                                    [ev("1", "2024-03-04")]).count, 0)
    },
    CheckCase("Konflikt: Mitternachtsübergang") {
      let existing = [ev("1", "2024-03-04T23:00", "2024-03-05T01:00")]
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-05T00:30", end: "2024-03-05T02:00"), existing)
      try expectEqual(c.map(\.kind), [.overlap])
      try expectEqual(findConflicts(NewEvent(title: "Neu", start: "2024-03-05T01:00", end: "2024-03-05T02:00"),
                                    existing).count, 0)
    },
    CheckCase("Konflikt: Sommerzeit-Umstellung (02:30 existiert lokal nicht) wird trotzdem erkannt") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-31T02:30"),
                            [ev("1", "2024-03-31T02:00", "2024-03-31T03:00")])
      try expectEqual(c.count, 1)
    },
    CheckCase("Konflikt: mehrere bestehende, nur echte Treffer") {
      let c = findConflicts(NewEvent(title: "Neu", start: "2024-03-04T10:00", end: "2024-03-04T12:00"), [
        ev("a", "2024-03-04T09:00", "2024-03-04T10:00"),
        ev("b", "2024-03-04T11:00", "2024-03-04T11:30"),
        ev("c", "2024-03-04T10:00"),
        ev("d", "2024-03-04T12:00"),
      ])
      try expectEqual(c.map(\.with.id), ["b", "c"])
      try expectEqual(c.map(\.kind), [.overlap, .sameStart])
    },
    CheckCase("allDayNotices: gleicher Tag ja, anderer Tag nein") {
      try expectEqual(allDayNotices(NewEvent(title: "Neu", start: "2024-03-04T10:00"),
                                    [ev("1", "2024-03-04", allDay: true)]).map(\.id), ["1"])
      try expectEqual(allDayNotices(NewEvent(title: "Neu", start: "2024-03-04T10:00"),
                                    [ev("1", "2024-03-05", allDay: true)]).count, 0)
    },
    CheckCase("pairwiseConflicts: jedes Paar genau einmal") {
      let c = pairwiseConflicts([
        ev("a", "2024-03-04T10:00"), ev("b", "2024-03-04T10:30"), ev("c", "2024-03-04T12:00"),
      ])
      try expectEqual(c.count, 1)
      try expectEqual(c.first?.with.id, "b")
    },
  ]

  // MARK: Streak und Datumsarithmetik (Port von streak.test.ts)

  static let streakChecks: [CheckCase] = [
    CheckCase("Streak: Grundfälle") {
      try expectEqual(HabitStreak.compute([], today: "2024-03-04"), 0)
      try expectEqual(HabitStreak.compute(["2024-03-04"], today: "2024-03-04"), 1)
      try expectEqual(HabitStreak.compute(["2024-03-02", "2024-03-03", "2024-03-04"], today: "2024-03-04"), 3)
    },
    CheckCase("Streak: heute offen, gestern abgehakt bricht nicht ab") {
      try expectEqual(HabitStreak.compute(["2024-03-02", "2024-03-03"], today: "2024-03-04"), 2)
    },
    CheckCase("Streak: Lücke bricht ab, weder heute noch gestern = 0") {
      try expectEqual(HabitStreak.compute(["2024-03-01", "2024-03-03", "2024-03-04"], today: "2024-03-04"), 2)
      try expectEqual(HabitStreak.compute(["2024-03-01"], today: "2024-03-04"), 0)
    },
    CheckCase("Streak: über Monats-/Jahreswechsel und Schalttag") {
      try expectEqual(HabitStreak.compute(["2024-02-29", "2024-03-01"], today: "2024-03-01"), 2)
      try expectEqual(HabitStreak.compute(["2023-12-31", "2024-01-01"], today: "2024-01-01"), 2)
    },
    CheckCase("shiftDateOnly: Monats-, Jahreswechsel, Sommerzeit") {
      try expectEqual(StoreDates.shiftDateOnly("2024-02-28", 1), "2024-02-29")
      try expectEqual(StoreDates.shiftDateOnly("2024-03-01", -1), "2024-02-29")
      try expectEqual(StoreDates.shiftDateOnly("2023-12-31", 1), "2024-01-01")
      try expectEqual(StoreDates.shiftDateOnly("2024-03-30", 1), "2024-03-31")
      try expectEqual(StoreDates.shiftDateOnly("2024-03-31", 1), "2024-04-01")
      try expectEqual(StoreDates.shiftDateOnly("2024-03-04", 8), "2024-03-12")
    },
  ]
}
