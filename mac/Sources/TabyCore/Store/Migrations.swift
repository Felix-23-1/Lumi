// Nummerierte, sequenziell ausgeführte Migrationen (BAUPLAN.md Abschnitt 6),
// Port von src/main/store/migrations.ts – gleiches Schema, damit eine
// Datenbank der Electron-App weiter lesbar bleibt. Jede Migration läuft genau
// einmal (Tabelle schema_migrations); vorhandene Einträge nie verändern, nur
// neue anhängen.
import Foundation

public struct Migration: Sendable {
  public let version: Int
  public let sql: String
}

public enum Migrations {
  public static let all: [Migration] = [
    Migration(version: 1, sql: """
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        notes TEXT,
        due TEXT,
        done INTEGER NOT NULL DEFAULT 0,
        done_at TEXT,
        created_at TEXT NOT NULL
      );

      CREATE TABLE notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE habits (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );

      CREATE TABLE habit_checks (
        habit_id TEXT NOT NULL REFERENCES habits(id),
        date TEXT NOT NULL,
        PRIMARY KEY (habit_id, date)
      );

      CREATE TABLE local_events (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        start TEXT NOT NULL,
        "end" TEXT,
        all_day INTEGER NOT NULL DEFAULT 0,
        notes TEXT
      );

      CREATE TABLE reminders (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        source_ref TEXT NOT NULL,
        due_at TEXT NOT NULL,
        fired_at TEXT,
        acknowledged_at TEXT
      );

      CREATE TABLE jobs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        prompt TEXT NOT NULL,
        rule TEXT NOT NULL,
        mode TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        last_run_at TEXT,
        created_at TEXT NOT NULL
      );

      CREATE TABLE job_runs (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES jobs(id),
        scheduled_for TEXT NOT NULL,
        started_at TEXT NOT NULL,
        status TEXT NOT NULL,
        output TEXT
      );

      CREATE TABLE daily_state (
        date TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        snooze_until TEXT
      );

      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        created_at TEXT NOT NULL
      );

      CREATE TABLE action_log (
        id TEXT PRIMARY KEY,
        at TEXT NOT NULL,
        actor TEXT NOT NULL,
        tool TEXT NOT NULL,
        args_json TEXT NOT NULL,
        ok INTEGER NOT NULL,
        error TEXT
      );

      CREATE TABLE calendar_sources (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        config_json TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        is_default_write INTEGER NOT NULL DEFAULT 0
      );
      """),
    // Nicht-geheime Einstellungen (TabySettings ohne hasApiKey) als
    // Schlüssel/Wert (Wert = JSON). Der API-Key liegt im Schlüsselbund, nie hier.
    Migration(version: 2, sql: """
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      """),
    // Modell-Verbrauch je Antwort (Paket 1: Tages-/Monatslimits). cost_usd ist
    // NULL, wenn der Anbieter keine Kosten meldet.
    Migration(version: 3, sql: """
      CREATE TABLE llm_usage (
        id TEXT PRIMARY KEY,
        at TEXT NOT NULL,
        model TEXT NOT NULL,
        prompt_tokens INTEGER NOT NULL,
        completion_tokens INTEGER NOT NULL,
        cost_usd REAL
      );
      """),
    // Verknüpfung Lumi-Aufgabe ↔ Apple-Erinnerung mit dem letzten Abgleichstand
    // (snap_*) für den Zwei-Wege-Abgleich.
    Migration(version: 4, sql: """
      CREATE TABLE reminder_links (
        task_id TEXT PRIMARY KEY,
        external_id TEXT NOT NULL UNIQUE,
        snap_title TEXT NOT NULL,
        snap_due TEXT,
        snap_done INTEGER NOT NULL,
        synced_at TEXT NOT NULL
      );
      """),
    // Paket 2: Tagesabschluss je Tag (gleiche Zustände wie der Tagesstart).
    Migration(version: 5, sql: """
      CREATE TABLE day_end (
        date TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        snooze_until TEXT
      );
      """),
    // Paket 2: Fokus-Sitzungen (Pomodoro), optional an eine Aufgabe gebunden.
    // finished_at NULL = läuft noch; completed = 1 nur bei vollständig abgelaufener Sitzung.
    Migration(version: 6, sql: """
      CREATE TABLE focus_sessions (
        id TEXT PRIMARY KEY,
        task_id TEXT,
        title TEXT NOT NULL,
        phase TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ends_at TEXT NOT NULL,
        minutes INTEGER NOT NULL,
        finished_at TEXT,
        completed INTEGER NOT NULL DEFAULT 0
      );
      """),
    // Paket 2: gemerkte Fakten über den Nutzer für den Systemprompt.
    Migration(version: 7, sql: """
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      """),
    // Paket 4: Tagesplan (JSON je Tag), Wochenziele, Stand des Wochenrückblicks.
    Migration(version: 8, sql: """
      CREATE TABLE day_plans (
        date TEXT PRIMARY KEY,
        json TEXT NOT NULL
      );

      CREATE TABLE weekly_goals (
        id TEXT PRIMARY KEY,
        week TEXT NOT NULL,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );

      CREATE TABLE weekly_review (
        week TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        snooze_until TEXT
      );
      """),
    // Paket 6: Geräte aus dem Netz-Scan (MAC bevorzugt, sonst IP als Kennung).
    Migration(version: 9, sql: """
      CREATE TABLE network_devices (
        id TEXT PRIMARY KEY,
        ip TEXT NOT NULL,
        mac TEXT,
        name TEXT,
        custom_name INTEGER NOT NULL DEFAULT 0,
        vendor TEXT,
        known INTEGER NOT NULL DEFAULT 0,
        first_seen TEXT NOT NULL,
        last_seen TEXT NOT NULL
      );
      """),
    // Paket 7: eigene Server, die der Nutzer selbst prüfen darf (Scan außerhalb des Heimnetzes).
    Migration(version: 10, sql: """
      CREATE TABLE own_servers (
        id TEXT PRIMARY KEY,
        host TEXT NOT NULL,
        label TEXT NOT NULL,
        authorized INTEGER NOT NULL DEFAULT 1,
        added_at TEXT NOT NULL
      );
      """),
    // Paket 9: Verknüpfung importierter Notion-Aufgaben (Dubletten-Schutz beim erneuten Abgleich).
    Migration(version: 11, sql: """
      CREATE TABLE notion_task_links (
        notion_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      """),
    // Paket 10: Prioritätsliste offener Aufgaben (rank = Position).
    Migration(version: 12, sql: """
      CREATE TABLE task_priority (
        task_id TEXT PRIMARY KEY,
        rank INTEGER NOT NULL
      );
      """),
    // Paket 11: Aufgaben-Kategorie (Arbeit/Privat, nil = keine).
    Migration(version: 13, sql: "ALTER TABLE tasks ADD COLUMN category TEXT"),
    // Paket 11: mehrere benannte Notion-Quellen statt einer Datenbank-/Seiten-ID.
    Migration(version: 14, sql: """
      CREATE TABLE notion_source (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        link TEXT NOT NULL,
        sort_order INTEGER NOT NULL
      );
      """),
    // Paket 11: jede Verknüpfung merkt sich auch ihre Notion-Quelle (für das
    // Abhaken-synchron: Datenbank-Zeile vs. To-do-Block entscheidet die Quelle,
    // nicht mehr geraten).
    Migration(version: 15, sql: "ALTER TABLE notion_task_links ADD COLUMN source_id TEXT NOT NULL DEFAULT ''"),
    // Paket 11: Gruppe eines importierten Eintrags (bei Weekly: die Woche, aus der die Aufgabe stammt).
    Migration(version: 16, sql: "ALTER TABLE notion_task_links ADD COLUMN group_name TEXT"),
    // Paket 11: Ticket-Metadaten aus Notion (Erstelldatum lokal, Erstellername, Status).
    Migration(version: 17, sql: """
      ALTER TABLE notion_task_links ADD COLUMN created_at TEXT;
      ALTER TABLE notion_task_links ADD COLUMN created_by_name TEXT;
      ALTER TABLE notion_task_links ADD COLUMN status TEXT;
      """),
    // Paket 12: verbundene Chat-Konten (ohne Geheimnis) und Lese-Marker je Unterhaltung.
    Migration(version: 18, sql: """
      CREATE TABLE messenger_accounts (
        id TEXT PRIMARY KEY,
        service TEXT NOT NULL,
        server TEXT NOT NULL,
        user TEXT NOT NULL,
        created_at TEXT NOT NULL
      );

      CREATE TABLE messenger_read (
        conversation_id TEXT PRIMARY KEY,
        last_rowid INTEGER NOT NULL
      );
      """),
    // Liste je Verknüpfung: damit "ganze Liste verschwunden" erkannt wird (Massenlöschung).
    Migration(version: 19, sql: "ALTER TABLE reminder_links ADD COLUMN list_id TEXT;"),
    // Notion-Aufgaben: letzter gemeinsamer Stand (Titel, Fälligkeit) je Verknüpfung. Ohne ihn erkennt
    // ein Neustart lokale Änderungen nicht mehr und schreibt sie nicht zurück.
    Migration(version: 20, sql: """
      ALTER TABLE notion_task_links ADD COLUMN synced_title TEXT;
      ALTER TABLE notion_task_links ADD COLUMN synced_due TEXT;
      """),
    // Aufgaben-Ordner: Name eindeutig ohne Groß/Klein; Aufgabe trägt optional ihren Ordner.
    Migration(version: 21, sql: """
      CREATE TABLE task_folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE UNIQUE INDEX task_folders_name_nocase ON task_folders (name COLLATE NOCASE);
      ALTER TABLE tasks ADD COLUMN folder_id TEXT;
      """),
    // Wiederholung einer Aufgabe ("daily", "weekdays", "weekly", "monthly"); NULL = keine.
    Migration(version: 22, sql: "ALTER TABLE tasks ADD COLUMN recurrence TEXT;"),
    // Notiz einer Aufgabe zuordnen; NULL = keine. Beim Löschen der Aufgabe wird nur die Zuordnung gelöst.
    Migration(version: 23, sql: "ALTER TABLE notes ADD COLUMN task_id TEXT; CREATE INDEX notes_task_id ON notes (task_id);"),
    // Nächste Aufgabe einer wiederholten Aufgabe, die beim Erledigen angelegt wurde; NULL = keine.
    Migration(version: 24, sql: "ALTER TABLE tasks ADD COLUMN followup_id TEXT;"),
    // Eingang: erledigte Punkte; kommen erst wieder, wenn eine neuere Nachricht (at) eintrifft.
    Migration(version: 25, sql: "CREATE TABLE inbox_dismissed (item_id TEXT PRIMARY KEY, at TEXT NOT NULL);"),
    // Status automatisch: was Lumi je Konto gesetzt hat (bis ends_at); nach dem Neustart aufgeräumt.
    Migration(version: 26, sql: "CREATE TABLE auto_status (account_id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, emoji TEXT NOT NULL, ends_at TEXT NOT NULL);"),
    // Audit-Protokoll: eine Zeile je Werkzeug-Ausführung, ohne Inhalte; höchstens AuditRepository.maxRows.
    Migration(version: 27, sql: "CREATE TABLE audit_log (id TEXT PRIMARY KEY, at TEXT NOT NULL, actor TEXT NOT NULL, tool TEXT NOT NULL, summary TEXT NOT NULL, confirmed INTEGER NOT NULL DEFAULT 0, ok INTEGER NOT NULL DEFAULT 1);"),
    // Netz, in dem ein Gerät zuletzt gesehen wurde (Kennung: Router-MAC oder Teilnetz); NULL = altes Netz.
    Migration(version: 28, sql: "ALTER TABLE network_devices ADD COLUMN network TEXT;"),
    // Indizes für Zeitbereichs- und Lookup-Abfragen; Aufbewahrung räumt alte Zeilen weg (siehe CoreServices+Mods).
    Migration(version: 29, sql: """
      CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
      CREATE INDEX IF NOT EXISTS idx_llm_usage_at ON llm_usage(at);
      CREATE INDEX IF NOT EXISTS idx_job_runs_job_scheduled ON job_runs(job_id, scheduled_for);
      """),
    // Ordner gehören zu einer Kategorie (Kennung aus den Einstellungen); NULL = keine.
    // Name ist nur noch innerhalb derselben Kategorie eindeutig (ohne Groß/Klein).
    Migration(version: 30, sql: """
      ALTER TABLE task_folders ADD COLUMN category_id TEXT;
      DROP INDEX task_folders_name_nocase;
      CREATE UNIQUE INDEX task_folders_category_name ON task_folders (IFNULL(category_id, ''), name COLLATE NOCASE);
      """),
    // Notion-Quelle gehört zu einem Notion-Zugang (`NotionAccount.id`); bestehende Quellen bleiben beim Standard-Zugang.
    Migration(version: 31, sql: "ALTER TABLE notion_source ADD COLUMN account_id TEXT NOT NULL DEFAULT 'notion';"),
    // Geschätzte Dauer einer Aufgabe in Minuten.
    Migration(version: 32, sql: "ALTER TABLE tasks ADD COLUMN minutes INTEGER;"),
    // Bearbeitungsstand einer Aufgabe; angehaltener Fokus.
    Migration(version: 33, sql: "ALTER TABLE tasks ADD COLUMN status TEXT; ALTER TABLE focus_sessions ADD COLUMN paused_at TEXT;"),
    // Kennzeichen für Aufgaben und Notizen; Notiz kann zu einem Termin gehören.
    Migration(version: 34, sql: "ALTER TABLE tasks ADD COLUMN tags TEXT; ALTER TABLE notes ADD COLUMN tags TEXT; ALTER TABLE notes ADD COLUMN meeting_key TEXT;"),
    // Wichtigkeit einer Aufgabe (high / medium / low).
    Migration(version: 35, sql: "ALTER TABLE tasks ADD COLUMN priority TEXT;"),
  ]

  /// Wendet alle noch fehlenden Migrationen an (je Migration eine Transaktion).
  static func migrate(_ db: Database, clock: Clock) throws {
    try db.execute(
      "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
    let applied = Set(try db.appliedMigrations())
    for m in all where !applied.contains(m.version) {
      try db.transaction {
        try db.execute(m.sql)
        try db.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                   [.of(m.version), .text(LocalTime.format(clock.now()))])
      }
    }
  }
}
