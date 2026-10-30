// Prüfungen für das Schreiben in den Obsidian-Vault: Datei mit Front matter, Anhängen,
// Dateinamen, Ordnersperre, Namensdubletten und Anzahl der Notizen im Index.
import Foundation

@MainActor
enum VaultWriteChecks {
  static func at(_ iso: String) throws -> Date {
    try expectNotNil(LocalTime.parse(iso), "Zeit \(iso)")
  }

  /// Schreibt eine Notiz in den Lumi-Ordner der Testwurzel.
  static func save(_ root: String, _ title: String, _ content: String, append: Bool = false,
                   folder: String = "Lumi", at iso: String = "2026-10-18T10:00") throws -> FileHit {
    try MarkdownVault.write(root: root, title: title, content: content, append: append,
                            folder: folder, now: at(iso))
  }

  /// Der Zustand zählt den Ordner im Hintergrund: bis zur erwarteten Zahl warten (höchstens 2 s).
  static func awaitCount(_ svc: CoreServices, _ n: Int) async -> AppState {
    var st = await svc.state()
    for _ in 0..<100 where st.vaultNoteCount != n {
      try? await Task.sleep(nanoseconds: 20_000_000)
      st = await svc.state()
    }
    return st
  }

  static func rejects(_ body: () throws -> FileHit) -> Bool {
    do { _ = try body(); return false } catch { return true }
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Vault schreiben: neue Datei mit Front matter im Lumi-Ordner") {
        let root = try AuditVaultChecks.tempVault([:])
        let hit = try save(root, "Plan", "Hallo Welt")
        try expectEqual(try String(contentsOfFile: hit.path, encoding: .utf8),
                        "---\ncreated: 2026-10-18T10:00\nsource: Lumi\n---\nHallo Welt", "Front matter und Inhalt")
        try expect(hit.path.hasSuffix("/Lumi/Plan.md"), "im Lumi-Ordner")
        try expectEqual(hit.name, "Plan.md")
        try expectEqual(hit.modifiedAt, "2026-10-18T10:00")
      },
      CheckCase("Vault schreiben: Anhängen fügt einen Abschnitt mit Uhrzeit an, sonst neue Datei") {
        let root = try AuditVaultChecks.tempVault([:])
        _ = try save(root, "Plan", "Erster Satz")
        let hit = try save(root, "Plan", "Zweiter Satz", append: true, at: "2026-10-18T11:30")
        let text = try String(contentsOfFile: hit.path, encoding: .utf8)
        try expect(text.hasSuffix("Erster Satz\n\n## 2026-10-18T11:30\nZweiter Satz"), "Abschnitt mit Uhrzeit")
        try expect(text.hasPrefix("---\n"), "Front matter bleibt")
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root + "/Lumi").count, 1, "keine zweite Datei")
        let fresh = try save(root, "Neu", "Inhalt", append: true)
        try expectEqual(fresh.name, "Neu.md", "ohne vorhandene Datei entsteht eine neue")
        try expect(try String(contentsOfFile: fresh.path, encoding: .utf8).hasPrefix("---\ncreated:"), "mit Front matter")
      },
      CheckCase("Vault schreiben: Dateiname wird bereinigt, höchstens 80 Zeichen, sonst „Notiz“") {
        let root = try AuditVaultChecks.tempVault([:])
        try expectEqual(try save(root, "Mein/Plan: \"Ideen\" ?* 2026!", "x").name, "MeinPlan Ideen 2026.md")
        try expectEqual(try save(root, "../../etc", "x").name, "etc.md", "Punkte und Schrägstriche fallen weg")
        try expectEqual(try save(root, "  ...  ", "x").name, "Notiz.md", "leer nach Bereinigung")
        try expectEqual(try save(root, String(repeating: "a", count: 120), "x").name.count, 83, "80 Zeichen plus .md")
      },
      CheckCase("Vault schreiben: gleicher Titel bekommt -2 und -3, nichts wird überschrieben") {
        let root = try AuditVaultChecks.tempVault([:])
        _ = try save(root, "Idee", "eins")
        try expectEqual(try save(root, "Idee", "zwei").name, "Idee-2.md")
        try expectEqual(try save(root, "Idee", "drei").name, "Idee-3.md")
        try expect(try String(contentsOfFile: root + "/Lumi/Idee.md").contains("eins"), "Original unverändert")
      },
      CheckCase("Vault schreiben: Ordner mit .., absolutem Pfad oder Symlink nach außen wird abgelehnt") {
        let root = try AuditVaultChecks.tempVault([:])
        let outside = try AuditVaultChecks.tempVault([:])
        try expect(rejects { try save(root, "A", "x", folder: "../x") }, "..")
        try expect(rejects { try save(root, "A", "x", folder: "Lumi/../../x") }, "Ausbruch über Unterordner")
        try expect(rejects { try save(root, "A", "x", folder: outside) }, "absoluter Pfad")
        try expect(rejects { try save(root, "A", "x", folder: "") }, "leer")
        try FileManager.default.createSymbolicLink(atPath: root + "/Links", withDestinationPath: outside)
        try expect(rejects { try save(root, "A", "x", folder: "Links") }, "Symlink nach außen")
        try expect(rejects { try save(root, "A", "x", folder: "Links/tief") }, "Unterordner eines Symlinks")
        try expect(!FileManager.default.fileExists(atPath: outside + "/A.md"), "nichts außerhalb geschrieben")
      },
      CheckCase("Vault: Anzahl der Notizen aus dem Index, höchstens alle 60 s neu gelesen") {
        let root = try AuditVaultChecks.tempVault(["a.md": "x", "b.md": "y"])
        let vault = MarkdownVault()
        let t0 = try at("2026-10-18T10:00")
        try expectEqual(vault.noteCount(root: root, now: t0), 2)
        try "z".write(toFile: root + "/c.md", atomically: true, encoding: .utf8)
        try expectEqual(vault.noteCount(root: root, now: t0.addingTimeInterval(30)), 2, "innerhalb von 60 s nicht neu gelesen")
        try expectEqual(vault.noteCount(root: root, now: t0.addingTimeInterval(61)), 3, "nach 60 s neu gelesen")
        try expectEqual(vault.noteCount(root: "", now: t0), 0, "ohne Ordner 0")
      },
      CheckCase("Vault schreiben: Oberfläche und Werkzeug bleiben im Lumi-Ordner, Titel ist Pflicht") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let root = try AuditVaultChecks.tempVault([:])
        _ = await svc.updateSettings(SettingsPatch(markdownVaultPath: root), apiKey: nil)
        let outside = await svc.writeVaultNote(title: "A", content: "x", append: false, folder: "Projekte")
        try expect(!outside.isOk && outside.errorMessage?.contains("Lumi") == true, "fremder Ordner abgelehnt")
        let sub = await svc.writeVaultNote(title: "A", content: "x", append: false, folder: "Lumi/Sub")
        try expect(sub.isOk && FileManager.default.fileExists(atPath: root + "/Lumi/Sub/A.md"), "Unterordner erlaubt")
        try expectEqual(svc.vaultTool("save_vault_note", "{\"content\":\"x\"}")?["code"]?.stringValue, "INVALID_ARGS", "Titel fehlt")
        try expect(svc.vaultTool("save_vault_note", "{\"title\":\"A\",\"content\":\"x\"}") == nil, "geht zur Bestätigung")
        let (plain, _, _) = try TimersUndoSearchChecks.rig()
        let none = await plain.saveVaultNote(title: "A", content: "x", append: false)
        try expectEqual(none.errorMessage, "Kein Obsidian-Ordner verbunden – Einstellungen → Verbindungen (mit „Erweitert anzeigen“) → Obsidian.", "ohne Ordner")
      },
      CheckCase("Vault: Chat-Notiz nur nach Bestätigung, Zählung im Zustand, Protokoll") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let root = try AuditVaultChecks.tempVault(["Alt.md": "x"])
        _ = await svc.updateSettings(SettingsPatch(markdownVaultPath: root), apiKey: nil)
        try expect(ToolRegistry.confirmationRequired.contains("save_vault_note"), "Bestätigung nötig")
        try expect(svc.vaultToolDefs.contains { $0.name == "save_vault_note" }, "Werkzeug angeboten")
        let before = await awaitCount(svc, 1)
        try expectEqual(before.vaultNoteCount, 1, "Zählung aus dem Index")
        let asked = await svc.requestConfirmation(name: "save_vault_note", argumentsJSON: "{\"title\":\"Plan\",\"content\":\"Hallo\"}")
        try expectEqual(asked["code"]?.stringValue, "NEEDS_CONFIRMATION", "wartet auf Bestätigung")
        try expectEqual(asked["summary"]?.stringValue, "Notiz „Plan.md“ in Obsidian unter Lumi", "Text der Karte")
        try expect(!FileManager.default.fileExists(atPath: root + "/Lumi/Plan.md"), "vor Bestätigung nichts geschrieben")
        let open = await svc.state()
        let id = try expectNotNil(open.pendingConfirmations.first?.id, "Anfrage offen")
        let done = await svc.confirmAction(id)
        try expect(done.isOk, "bestätigt")
        try expect(FileManager.default.fileExists(atPath: root + "/Lumi/Plan.md"), "nach Bestätigung geschrieben")
        let after = await awaitCount(svc, 2)
        try expectEqual(after.vaultNoteCount, 2, "neue Notiz im Index")
        let audit = await svc.listAudit(limit: 5)
        try expect(audit.contains { $0.tool == "save_vault_note" }, "im Protokoll")
      },
      CheckCase("Vault schreiben: Skriptblöcke aus dem Modell werden entschärft") {
        let root = try AuditVaultChecks.tempVault([:])
        let hit = try save(root, "Skript", "```dataviewjs\nTABLE\n```\n```dataview\nLIST\n```\n<% tp.file.title %>")
        let text = try String(contentsOfFile: hit.path, encoding: .utf8)
        try expect(!text.contains("dataview"), "kein Dataview-Block")
        try expect(!text.contains("<%"), "keine Templater-Klammer")
        try expect(text.contains("```text\nTABLE"), "Block als Text")
      },
      CheckCase("Vault schreiben: Ordnerteile mit Punkt oder Sonderzeichen werden abgewiesen") {
        let root = try AuditVaultChecks.tempVault([:])
        try expect(rejects { try save(root, "A", "x", folder: "Lumi/..") }, "..")
        try expect(rejects { try save(root, "A", "x", folder: "Lumi/.versteckt") }, "versteckter Ordner")
        try expect(rejects { try save(root, "A", "x", folder: "Lumi/a(b)") }, "Klammern")
        try expect(MarkdownVault.isSafeFolder("Lumi/Projekte Plan"), "einfacher Unterordner erlaubt")
        try expect(!MarkdownVault.isSafeFolder("v1.2"), "Punkt im Namen")
        try expect(!MarkdownVault.isSafeFolder(""), "leer")
        try expectEqual(CoreServices.vaultTargetFolder(configured: "Lumi", typed: "Andere"), nil, "außerhalb Lumi")
      },
      CheckCase("Vault schreiben: fehlender Vault-Ordner wird nicht angelegt, Anhängen über 5 MB wird abgewiesen") {
        let missing = NSTemporaryDirectory() + "lumi-fehlt-\(UUID().uuidString)"
        var caught: MarkdownVault.WriteError?
        do { _ = try save(missing, "A", "x") } catch let e as MarkdownVault.WriteError { caught = e }
        try expectEqual(caught, .rootMissing, "Ordner fehlt")
        try expect(!FileManager.default.fileExists(atPath: missing), "nichts angelegt")
        let big = try AuditVaultChecks.tempVault(["Lumi/Gross.md": String(repeating: "a", count: 5 * 1024 * 1024 + 1)])
        caught = nil
        do { _ = try save(big, "Gross", "x", append: true) } catch let e as MarkdownVault.WriteError { caught = e }
        try expectEqual(caught, .tooLarge, "zu groß zum Anhängen")
      },
      CheckCase("Vault: Bestätigung nennt Datei, Ordner, Anhängen und den Anfang des Inhalts") {
        let (svc, _, _) = try TimersUndoSearchChecks.rig()
        let root = try AuditVaultChecks.tempVault(["Lumi/Alt.md": "x"])
        _ = await svc.updateSettings(SettingsPatch(markdownVaultPath: root), apiKey: nil)
        let asked = await svc.requestConfirmation(name: "save_vault_note",
                                                  argumentsJSON: "{\"title\":\"Alt\",\"content\":\"Neu\",\"append\":true}")
        try expectEqual(asked["summary"]?.stringValue, "Notiz „Alt.md“ in Obsidian unter Lumi (anhängen)", "Text mit Anhängen")
        let long = String(repeating: "b", count: 400)
        let detail = CoreServices.confirmationDetail("save_vault_note", .object(["content": .string(long)]))
        try expectEqual(detail?.count, 300, "höchstens 300 Zeichen")
      },
      CheckCase("Vault: Systemprompt nennt die Ablage-Regel nur mit verbundenem Ordner") {
        var settings = TabySettings()
        let clock = ControllableClock("2026-10-18T09:00")
        let plain = SystemPrompt.build(clock: clock, personality: .direkt, customInstructions: "",
                                       overview: .empty, settings: settings)
        try expect(!plain.contains("save_vault_note"), "ohne Ordner keine Regel")
        settings.markdownVaultPath = "/Wissen"
        let linked = SystemPrompt.build(clock: clock, personality: .direkt, customInstructions: "",
                                        overview: .empty, settings: settings)
        try expect(linked.contains(SystemPrompt.vaultRule), "Regel mit verbundenem Ordner")
      },
    ]
  }
}
