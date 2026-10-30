// Sicherungen der Datenbankdatei: vor Schema-Migrationen und höchstens einmal pro Tag beim Öffnen.
// Sicherung per `VACUUM INTO` (konsistent, auch bei WAL). Gelöscht werden Sicherungen, deren Tag
// älter als `backupRetentionDays` ist; die neueste bleibt immer.
// Vor dem Migrieren läuft `PRAGMA quick_check`; schlägt er fehl, wird die Datei als
// `taby-broken-<stamp>.sqlite` aufgehoben und der Vorgang geht weiter.
import Foundation

enum DatabaseBackup {
  /// Nur für Aufrufe ohne Einstellungen (Migration vor dem Start); sonst `backupRetentionDays`.
  static let defaultRetentionDays = 7
  /// Höchstens so viele defekte Kopien (`taby-broken-*`) bleiben liegen.
  static let keepBrokenCopies = 3

  /// Ordner `<dbdir>/Backups`.
  static func directory(for dbPath: String) -> String {
    (((dbPath as NSString).deletingLastPathComponent) as NSString).appendingPathComponent("Backups")
  }

  /// "2024-03-04-0800"
  static func stamp(_ clock: Clock) -> String {
    LocalTime.format(clock.now()).replacingOccurrences(of: "T", with: "-").replacingOccurrences(of: ":", with: "")
  }

  /// Nur Ereignisse, keine Dateinamen (siehe TabyLog).
  static func log(_ message: String) {
    TabyLog.info(.core, "taby-db: \(message)")
  }

  /// Was beim Öffnen sofort läuft. Ohne ausstehende Migration gibt es keinen Grund zur Prüfung
  /// und keine Sicherung vor dem Start: die tägliche Sicherung läuft im Hintergrund (`dailyIfDue`).
  struct StartupPlan: Equatable {
    let quickCheck: Bool
    let backupNow: Bool
  }

  static func startupPlan(pendingMigration: Bool) -> StartupPlan {
    StartupPlan(quickCheck: pendingMigration, backupNow: pendingMigration)
  }

  /// Aufruf vor den Migrationen einer bestehenden Datei (eine neue, leere Datei wird nicht gesichert).
  static func beforeMigrate(_ db: Database, clock: Clock, retentionDays: Int = defaultRetentionDays) {
    let size = ((try? FileManager.default.attributesOfItem(atPath: db.path))?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else { return }
    let applied = Set((try? db.appliedMigrations()) ?? [])
    let pending = Migrations.all.contains { !applied.contains($0.version) }
    let plan = startupPlan(pendingMigration: pending)
    guard plan.quickCheck || plan.backupNow else { return }
    if let problem = integrityProblem(db) {
      log("quick_check fehlgeschlagen: \(problem)")
      keepBroken(db, clock: clock)
      return
    }
    guard plan.backupNow else { return }
    backupNow(db, clock: clock, retentionDays: retentionDays)
  }

  /// Tägliche Sicherung (höchstens einmal pro Tag): 30 s nach dem Start und im stündlichen Takt.
  /// Läuft außerhalb des Hauptthreads (VACUUM hält die Datenbank-Sperre); `onProblem` meldet einen Befund.
  static func dailyIfDue(_ db: Database, clock: Clock, retentionDays: Int = defaultRetentionDays,
                         onProblem: (String) -> Void = { _ in }) {
    let size = ((try? FileManager.default.attributesOfItem(atPath: db.path))?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else { return }  // In-Memory-Datenbank oder leere Datei: nichts zu sichern
    let dir = directory(for: db.path)
    // Auch ohne neue Sicherung: geänderte Aufbewahrungsdauer greift beim nächsten Durchlauf.
    rotate(dir: dir, days: retentionDays, clock: clock)
    // Die Prüfung läuft vor dem Vorhandensein-Check, damit sie auch an Tagen mit Sicherung stattfindet.
    let problem = dailyIntegrity(db, clock: clock, onProblem: onProblem)
    guard !hasBackupToday(dir: dir, clock: clock) else { return }
    // Eine defekte Datei nicht über gute Sicherungen kopieren; die Datei bleibt dann unangetastet
    // (das Aufheben als taby-broken geschieht nur beim Öffnen vor dem Start).
    if let problem {
      log("Tagessicherung übersprungen, quick_check: \(problem)")
      return
    }
    backupNow(db, clock: clock, retentionDays: retentionDays)
  }

  /// Befund der Tagesprüfung je Datei: Tag und Ergebnis (nil = in Ordnung).
  private static let dayLock = NSLock()
  private static var integrityByDay: [String: (day: String, problem: String?)] = [:]

  /// `quick_check` höchstens einmal pro Tag und Datei. Ein Befund wird geloggt und einmal am Tag über
  /// `onProblem` gemeldet; bis zum nächsten Tag gilt der Befund weiter (für die Sicherung).
  static func dailyIntegrity(_ db: Database, clock: Clock, check: (Database) -> String? = DatabaseBackup.integrityProblem,
                             onProblem: (String) -> Void) -> String? {
    let today = LocalTime.formatDate(clock.now())
    if let known = dayLock.withLock({ integrityByDay[db.path] }), known.day == today { return known.problem }
    let problem = check(db)
    dayLock.withLock { integrityByDay[db.path] = (today, problem) }
    if let problem = problem {
      log("Tagesprüfung: quick_check meldet ein Problem: \(problem)")
      onProblem(problem)
    }
    return problem
  }

  private static func backupNow(_ db: Database, clock: Clock, retentionDays: Int) {
    let dir = directory(for: db.path)
    do {
      _ = try create(db, clock: clock)
      log("Sicherung angelegt")
      rotate(dir: dir, days: retentionDays, clock: clock)
    } catch {
      log("Sicherung fehlgeschlagen (\(TabyLog.code(error)))")
    }
  }

  /// nil, wenn `PRAGMA quick_check` genau "ok" liefert, sonst eine Beschreibung.
  static func integrityProblem(_ db: Database) -> String? {
    do {
      let results = try db.query("PRAGMA quick_check").compactMap { $0.string("quick_check") }
      return results == ["ok"] ? nil : results.prefix(3).joined(separator: "; ")
    } catch {
      return "\(error)"
    }
  }

  /// Erstellt `taby-<stamp>.sqlite` im Backups-Ordner und liefert den Pfad.
  /// Existiert der Name schon (gleiche Minute), wird `-2`, `-3`, … angehängt; nie überschrieben.
  @discardableResult
  static func create(_ db: Database, clock: Clock) throws -> String {
    let dir = directory(for: db.path)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let target = (dir as NSString).appendingPathComponent(freeName(in: dir, base: "taby-\(stamp(clock))"))
    try db.execute("VACUUM INTO '\(target.replacingOccurrences(of: "'", with: "''"))';")
    // Zustand der Notion-Aufgaben (liegt neben der Datenbank) geht mit in die Sicherung.
    let state = ((db.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(notionStateName)
    if FileManager.default.fileExists(atPath: state) {
      try? FileManager.default.copyItem(atPath: state, toPath: notionSidecar(forBackup: target))
    }
    return target
  }

  static let notionStateName = "notion-lokal.json"

  /// Begleitdatei einer Sicherung: `taby-X.sqlite` → `taby-X.notion-lokal.json`.
  static func notionSidecar(forBackup backupPath: String) -> String {
    (backupPath as NSString).deletingPathExtension + ".notion-lokal.json"
  }

  /// Freier Dateiname `<base>.sqlite`, sonst `<base>-2.sqlite`, `<base>-3.sqlite`, …
  static func freeName(in dir: String, base: String) -> String {
    var name = "\(base).sqlite"
    var n = 2
    while FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) {
      name = "\(base)-\(n).sqlite"
      n += 1
    }
    return name
  }

  /// Sicherungen (ohne defekte Kopien), aufsteigend nach Zeit (siehe BackupNames.isOlder).
  static func backups(dir: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.hasPrefix("taby-") && $0.hasSuffix(".sqlite") && !$0.hasPrefix("taby-broken-") }
      .sorted(by: BackupNames.isOlder)
  }

  static func hasBackupToday(dir: String, clock: Clock) -> Bool {
    let prefix = "taby-\(LocalTime.formatDate(clock.now()))-"
    return backups(dir: dir).contains { $0.hasPrefix(prefix) }
  }

  /// Löscht Sicherungen, deren Tag mehr als `days` Tage zurückliegt. Die neueste bleibt immer.
  static func rotate(dir: String, days: Int, clock: Clock) {
    let cutoff = LocalTime.formatDate(clock.now().addingTimeInterval(-Double(days) * 86_400))
    for name in backups(dir: dir).dropLast() where day(of: name) < cutoff {
      let path = (dir as NSString).appendingPathComponent(name)
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: notionSidecar(forBackup: path))
    }
  }

  /// "taby-2024-03-04-0800.sqlite" → "2024-03-04"
  static func day(of name: String) -> String {
    String(BackupNames.key(name).stamp.prefix(10))
  }

  /// Kopiert die defekte Datei (samt WAL, falls vorhanden) nach `taby-broken-<stamp>.sqlite`.
  static func keepBroken(_ db: Database, clock: Clock) {
    let dir = directory(for: db.path)
    do {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      let target = (dir as NSString).appendingPathComponent(freeName(in: dir, base: "taby-broken-\(stamp(clock))"))
      try FileManager.default.copyItem(atPath: db.path, toPath: target)
      if FileManager.default.fileExists(atPath: db.path + "-wal") {
        try? FileManager.default.copyItem(atPath: db.path + "-wal", toPath: target + "-wal")
      }
      log("defekte Datei gesichert")
      rotateBroken(dir: dir)
    } catch {
      log("defekte Datei konnte nicht gesichert werden (\(TabyLog.code(error)))")
    }
  }

  /// Behält nur die neuesten `keepBrokenCopies` defekten Kopien (samt WAL-Kopie).
  static func rotateBroken(dir: String) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
      .filter { $0.hasPrefix("taby-broken-") && $0.hasSuffix(".sqlite") }
    // "taby-broken-X.sqlite" wie eine normale Sicherung sortieren (Zeit aus dem Stempel).
    let ordered = names.sorted { BackupNames.isOlder("taby-" + $0.dropFirst("taby-broken-".count),
                                                     "taby-" + $1.dropFirst("taby-broken-".count)) }
    for name in ordered.dropLast(keepBrokenCopies) {
      let path = (dir as NSString).appendingPathComponent(name)
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: path + "-wal")
    }
  }
}
