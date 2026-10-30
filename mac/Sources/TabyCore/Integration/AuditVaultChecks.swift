// Prüfungen für das Audit-Protokoll (Einträge, Akteure, Obergrenze, CSV) und den Markdown-Vault
// (Suche, Pfadsperre gegen Ausbrüche und Symlinks, Verpackung fremden Inhalts).
// Läuft über die Suite „Integration“ (IntegrationChecks).
import Foundation

@MainActor
enum AuditVaultChecks {
  static func tempDir() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  /// Legt die Dateien (relativ zur Wurzel) in einem neuen Temp-Ordner an.
  static func tempVault(_ files: [String: String]) throws -> String {
    let root = try tempDir()
    for (rel, text) in files {
      let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Protokoll: Akteure, Kennzeichen und neueste zuerst") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        svc.audit(actor: AuditActor.user, tool: "add_task", confirmed: false, ok: true)
        svc.audit(actor: AuditActor.model, tool: "delete_note", confirmed: true, ok: true)
        svc.audit(actor: AuditActor.model, tool: "x", confirmed: false, ok: false)
        let rows = await svc.listAudit(limit: 10)
        try expectEqual(rows.map(\.tool), ["x", "delete_note", "add_task"], "neueste zuerst")
        try expectEqual(rows[1].summary, "Notiz gelöscht", "Kurzbeschreibung")
        try expectEqual(rows[1].confirmed, true, "bestätigt")
        try expectEqual(rows[0].ok, false, "fehlgeschlagen")
        try expectEqual(rows[2].actor, "Nutzer", "Akteur Nutzer")
      },
      CheckCase("Protokoll: Werkzeugaufruf schreibt Zeile ohne Inhalte") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let made = await svc.addNote(title: "Geheimtitel", content: "Geheimtext")
        _ = try expectNotNil(made.value, "Notiz angelegt")
        _ = await svc.deleteNote("gibt-es-nicht")
        let rows = await svc.listAudit(limit: 5)
        try expectEqual(rows.count, 2, "zwei Ausführungen")
        try expectEqual(rows[0].tool, "delete_note", "zuletzt der Fehlschlag")
        try expectEqual(rows[0].ok, false, "Fehlschlag wird vermerkt")
        try expectEqual(rows[1].summary, "Notiz angelegt", "Kurzbeschreibung")
        try expectEqual(rows[1].actor, "Nutzer", "Akteur aus dem Kontext")
        try expect(!rows.contains { $0.summary.contains("Geheim") || $0.tool.contains("Geheim") },
                   "keine Titel oder Texte im Protokoll")
      },
      CheckCase("Einstellungen: Schlüsselfehler setzt saveError, nächstes Speichern löscht ihn") {
        final class FailingKeys: ApiKeyStore {
          func get() throws -> String? { nil }
          func set(_ key: String) throws { throw ApiKeyStoreError("Schlüsselbund gesperrt") }
          func delete() throws {}
          func hasKey() -> Bool { false }
        }
        let clock = ControllableClock("2026-10-12T08:00")
        let opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: clock, keyStore: FailingKeys(),
                                        systemNotifier: SinkNotifier(), plannerInterval: nil)
        let svc = try CoreServices(options: opts)
        _ = await svc.updateSettings(SettingsPatch(), apiKey: "sk-test")
        let failed = await svc.state().saveError
        try expectNotNil(failed, "Schlüsselfehler sichtbar")
        _ = await svc.updateSettings(SettingsPatch(tabOrder: []), apiKey: nil)
        let later = await svc.state().saveError
        try expect(later == nil, "erfolgreiches Speichern löscht den Fehler")
      },
      CheckCase("Abgleich: Rückgängig nur für neue Fälle aus Apple und für überschriebene Lumi-Änderungen") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let made = try svc.store.tasks.add(title: "Milch", due: nil)
        var report = SyncReport()
        report.removedFromApple = [made.id]
        svc.recordReminderUndo(report, before: [:])
        try expectEqual(svc.currentUndoLabels(), ["Aus Erinnerungen entfernt – rückgängig?"], "neuer Fall")
        // Jeder Abgleich meldet offene Fälle erneut: kein zweiter Eintrag.
        svc.recordReminderUndo(report, before: [:])
        try expectEqual(svc.currentUndoLabels().count, 1, "gleicher Fall, kein neuer Eintrag")
        var overwritten = SyncReport()
        overwritten.overwrittenLumiEdits = [made.id]
        svc.recordReminderUndo(overwritten, before: [made.id: made])
        try expectEqual(svc.currentUndoLabels().first, "Von Erinnerungen überschrieben – rückgängig?", "überschrieben")
        // Rückgängig stellt die vorherige Lumi-Fassung wieder her.
        let r = await svc.undoLast()
        try expect(r.isOk, "Rückgängig gelingt")
      },
      CheckCase("Mod: Aufgabe erledigen geht über den App-Weg mit Rückgängig") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let t = try svc.store.tasks.add(title: "Brot", due: nil)
        try await svc.modHostActions().completeTask!(t.id)
        try expect(try svc.store.tasks.get(t.id)?.done == true, "erledigt")
        try expect(!svc.currentUndoLabels().isEmpty, "Rückgängig-Eintrag vorhanden")
      },
      CheckCase("Notion-Quelle: Aufgaben löschen entfernt die Aufgaben, Rückgängig holt sie zurück") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let src = try svc.store.notionSources.add(name: "Projekte", category: .weekly, link: "abc")
        let t = try svc.store.tasks.add(title: "Angebot", due: nil)
        try svc.store.notionTaskLinks.upsert(notionId: "n-1", taskId: t.id, sourceId: src.id, now: "2026-10-16T09:00")
        _ = await svc.removeNotionSource(src.id, deleteTasks: true)
        try expectEqual(try svc.store.tasks.get(t.id), nil, "Aufgabe gelöscht")
        _ = await svc.undoLast()
        _ = await svc.undoLast()
        try expectEqual(try svc.store.notionSources.get(src.id)?.name, "Projekte", "Quelle zurück")
        try expectEqual(try svc.store.tasks.get(t.id)?.title, "Angebot", "Aufgabe zurück")
      },
      CheckCase("Export: vorherige Notiz-Dateien liegen in .vorher und das Ergebnis nennt den Ordner") {
        let clock = ControllableClock("2026-10-17T09:00")
        let store = try Store.inMemory(clock: clock)
        _ = try store.notes.add(title: "Einkauf", content: "Milch")
        let dir = try tempDir()
        let first = try MarkdownExporter.export(store: store, folder: dir, clock: clock)
        try expectEqual(first.backupFolder, nil, "erster Export: nichts vorher")
        let second = try MarkdownExporter.export(store: store, folder: dir, clock: clock)
        try expect(second.backupFolder?.hasSuffix("/.vorher") == true, "zweiter Export nennt den Sicherungsordner")
      },
      CheckCase("Bestätigung: Alles anzeigen nur für MCP und Mods, vollständig") {
        try expect(CoreServices.confirmationDetail("delete_task", .object(["id": .string("x")])) == nil,
                   "interne Werkzeuge: kein Detail")
        let d = CoreServices.confirmationDetail("mcp_srv_tool", .object(["text": .string("Hallo Welt")]))
        try expect(d?.contains("Hallo Welt") == true, "MCP: vollständige Argumente")
        try expect(CoreServices.confirmationDetail("mod_wetter", .object([:])) == nil, "leere Argumente: kein Detail")
        try expect(CoreServices.confirmationDetail("mod_wetter", .object(["city": .string("Bonn")]))?.contains("Bonn") == true,
                   "Mod-Lauf: Eingabe vollständig")
      },
      CheckCase("Protokoll: Aufbewahrung löscht nur ältere Einträge, Leeren löscht alles") {
        let clock = ControllableClock("2026-10-01T09:00")
        let store = try Store.inMemory(clock: clock)
        store.audit.add(actor: AuditActor.model, tool: "alt", summary: "s", confirmed: false, ok: true)
        clock.advance(seconds: 9 * 86_400)
        store.audit.add(actor: AuditActor.model, tool: "neu", summary: "s", confirmed: false, ok: true)
        try store.audit.pruneOlderThan(days: 7, now: clock.now())
        try expectEqual(try store.audit.list(limit: 10).map(\.tool), ["neu"], "7 Tage: alter Eintrag weg")
        try store.audit.pruneOlderThan(days: 1, now: clock.now().addingTimeInterval(-86_400 * 60))
        try expectEqual(try store.audit.list(limit: 10).map(\.tool), ["neu"], "Stichtag in der Vergangenheit: nichts weg")
        try store.audit.clear()
        try expectEqual(try store.audit.list(limit: 10).count, 0, "Leeren: alles weg")
      },
      CheckCase("Protokoll: höchstens 5000 Zeilen, älteste fallen weg") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-16T09:00"))
        for i in 0..<5100 {
          store.audit.add(actor: AuditActor.model, tool: "t\(i)", summary: "s", confirmed: false, ok: true)
        }
        let all = try store.audit.list(limit: 6000)
        try expectEqual(all.count, AuditRepository.maxRows, "Obergrenze")
        try expectEqual(all.first?.tool, "t5099", "neueste bleibt")
        try expectEqual(all.last?.tool, "t100", "älteste fallen weg")
      },
      CheckCase("Protokoll: Kurzbeschreibungen und CSV-Export") {
        try expectEqual(AuditSummary.of("add_task"), "Aufgabe angelegt")
        try expectEqual(AuditSummary.of("unbekannt_xyz"), "Aktion ausgeführt", "neutrale Zeile")
        try expectEqual(AuditActor.of(.job), "Auftrag")
        let csv = AuditExport.csv([AuditEntry(id: "1", at: "2026-10-16T09:00", actor: "Modell", tool: "add_note",
                                              summary: "Notiz \"x\"", confirmed: true, ok: true)])
        try expect(csv.contains("\"Modell\";\"add_note\""), "Felder mit Semikolon getrennt")
        try expect(csv.contains("\"Notiz \"\"x\"\"\";\"ja\";\"ja\""), "Anführungszeichen verdoppelt")
      },
      CheckCase("Vault: Suche über Name, Überschrift und Inhalt, höchstens 20 Treffer") {
        var files: [String: String] = ["Plan.md": "# Wochenplan\nBlah", "Ideen/Kochen.md": "Rezept mit Tomate",
                                       "Notiz.txt": "Tomate"]
        for i in 0..<25 { files["Sammlung/eintrag\(i).md"] = "Tomaten \(i)" }
        let vault = MarkdownVault()
        let root = try tempVault(files)
        try expectEqual(vault.search(root: root, query: "tomate").count, MarkdownVault.maxHits, "Obergrenze 20")
        let heading = vault.search(root: root, query: "wochenplan")
        try expectEqual(heading.map(\.title), ["Wochenplan"], "erste Überschrift als Titel")
        let name = vault.search(root: root, query: "kochen")
        try expectEqual(name.map(\.title), ["Kochen"], "Dateiname ohne .md")
        try expect(name.first?.id.hasPrefix(MarkdownVault.hitPrefix) == true, "Kennzeichen vault:")
        try expect(vault.search(root: root, query: "notiz").isEmpty, ".txt wird nicht durchsucht")
      },
      CheckCase("Vault: Änderungen erscheinen beim nächsten Suchen") {
        let root = try tempVault(["Plan.md": "alt"])
        let vault = MarkdownVault()
        try expect(vault.search(root: root, query: "zitrone").isEmpty, "noch nicht vorhanden")
        try "Neu: Zitrone und mehr Text".write(toFile: root + "/Plan.md", atomically: true, encoding: .utf8)
        try expectEqual(vault.search(root: root, query: "zitrone").count, 1, "geänderte Datei wird neu gelesen")
        try FileManager.default.removeItem(atPath: root + "/Plan.md")
        try expect(vault.search(root: root, query: "zitrone").isEmpty, "gelöschte Datei fällt aus dem Index")
      },
      CheckCase("Vault: Pfadsperre gegen Ausbrüche, Nicht-Markdown und Symlinks") {
        let root = try tempVault(["a.md": "x", "sub/b.md": "y", "c.txt": "z"])
        let outside = try tempVault(["secret.md": "geheim"])
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root + "/link.md", withDestinationPath: outside + "/secret.md")
        try fm.createSymbolicLink(atPath: root + "/outdir", withDestinationPath: outside)
        try expect(MarkdownVault.resolve(root: root, path: "../secret.md") == nil, "Ausbruch mit ..")
        try expect(MarkdownVault.resolve(root: root, path: "sub/../../secret.md") == nil, "Ausbruch über Unterordner")
        try expect(MarkdownVault.resolve(root: root, path: outside + "/secret.md") == nil, "absoluter Pfad außerhalb")
        try expect(MarkdownVault.resolve(root: root, path: "c.txt") == nil, "keine .md-Datei")
        try expect(MarkdownVault.resolve(root: root, path: "link.md") == nil, "Symlink nach außen")
        try expect(MarkdownVault.resolve(root: root, path: "outdir/secret.md") == nil, "Ordner-Symlink nach außen")
        try expect(MarkdownVault.resolve(root: root, path: "") == nil, "leerer Pfad")
        try expect(MarkdownVault.readNote(root: root, path: "../secret.md") == nil, "Lesen blockiert")
        try expectEqual(MarkdownVault.readNote(root: root, path: "sub/b.md")?.text, "y", "innerhalb erlaubt")
        try expect(MarkdownVault.resolve(root: root, path: "sub/b.md") != nil, "Unterordner erlaubt")
        let hits = MarkdownVault().search(root: root, query: "geheim")
        try expect(hits.isEmpty, "Symlink-Ziel wird nicht indexiert")
      },
      CheckCase("Vault: Chat-Werkzeug und Suche verpacken fremden Inhalt") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let root = try tempVault(["Plan.md": "# Plan\nGeheimer Satz", "sub/b.md": "y"])
        _ = await svc.updateSettings(SettingsPatch(markdownVaultPath: root), apiKey: nil)
        let read = svc.vaultTool("read_vault_note", "{\"path\":\"Plan.md\"}")
        try expectEqual(read?["ok"]?.boolValue, true, "Notiz gelesen")
        let content = read?["content"]?.stringValue ?? ""
        try expect(content.hasPrefix(ForeignContent.open) && content.hasSuffix(ForeignContent.close),
                   "Inhalt zwischen fremden Markern")
        try expect(content.contains("Geheimer Satz"), "Text enthalten")
        let blocked = svc.vaultTool("read_vault_note", "{\"path\":\"../etc/passwd\"}")
        try expectEqual(blocked?["ok"]?.boolValue, false, "Traversal abgelehnt")
        let found = await svc.timerSearchTool("search", "{\"query\":\"Geheimer\"}")
        let first = found?["hits"]?.arrayValue?.first
        try expect((first?["title"]?.stringValue ?? "").hasPrefix(ForeignContent.open), "Titel verpackt")
        try expect((first?["id"]?.stringValue ?? "").hasPrefix(MarkdownVault.hitPrefix), "Vault-Treffer")
      },
    ]
  }
}
