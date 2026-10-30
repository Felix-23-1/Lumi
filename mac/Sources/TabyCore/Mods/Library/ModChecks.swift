// Prüfungen für Sources/TabyCore/Mods (Bibliothek + Skripte).
import Foundation

enum ModChecks {
  @MainActor static var suite: CheckSuite {
    CheckSuite("Mods", LibraryModChecks.cases + ScriptModChecks.cases + CatalogModChecks.cases + ModApiChecks.cases
      + SkillChecks.cases)
  }
}

/// Prüfungen für Mods/Library (Manifest, Bibliothek, Kurzbefehle, Teilen).
/// Echte Kurzbefehle werden nie gestartet: die Prüfungen nutzen ein Ersatzprogramm in einem Temp-Ordner.
enum LibraryModChecks {
  static let cases: [CheckCase] = [
    CheckCase("Manifest: gültiger Kurzbefehl-Mod ist gültig") {
      try expectEqual(ModValidation.validate(libShortcutManifest()), [], "Kurzbefehl-Manifest")
    },
    CheckCase("Manifest: ungültige IDs werden abgelehnt") {
      let longID = String(repeating: "a", count: 41)
      for id in ["ab", "Mein Mod", "a_b", "Wetter", longID, ""] {
        var m = libScriptManifest()
        m.id = id
        try expect(!ModValidation.validate(m).isEmpty, "ID „\(id)“ hätte abgelehnt werden müssen")
      }
      var ok = libScriptManifest()
      ok.id = "wetter-2-tage"
      try expectEqual(ModValidation.validate(ok), [], "gültige ID")
    },
    CheckCase("Manifest: leerer Name und leere Beschreibung werden abgelehnt") {
      var m = libScriptManifest()
      m.name = "   "
      try expect(!ModValidation.validate(m).isEmpty, "leerer Name")
      var d = libScriptManifest()
      d.description = ""
      try expect(!ModValidation.validate(d).isEmpty, "leere Beschreibung")
    },
    CheckCase("Manifest: Kurzbefehl ohne Kurzbefehlsname wird abgelehnt") {
      let m = ModManifest(id: "ohne-name", name: "Ohne Name", description: "x", kind: .shortcut)
      try expect(!ModValidation.validate(m).isEmpty, "Kurzbefehl ohne shortcutName")
    },
    CheckCase("Manifest: Skriptdatei muss .js ohne Ordner sein") {
      for entry in ["main.txt", "../x.js", "ordner/main.js", ".versteckt.js", "mod.json", ".js"] {
        var m = libScriptManifest()
        m.entry = entry
        try expect(!ModValidation.validate(m).isEmpty, "Eintrag „\(entry)“ hätte abgelehnt werden müssen")
      }
      var ok = libScriptManifest()
      ok.entry = "main.js"
      try expectEqual(ModValidation.validate(ok), [], "main.js")
    },
    CheckCase("Manifest: Rechte und Domains werden geprüft") {
      let good = ["tasks.read", "tasks.write", "notes.read", "notes.write", "calendar.read", "notify",
                  "http:api.open-meteo.com", "http:example.de"]
      var ok = libScriptManifest()
      ok.permissions = good
      try expectEqual(ModValidation.validate(ok), [], "bekannte Rechte und Domains")
      for bad in ["http:https://x.de", "http:*.example.com", "http:example.com/pfad", "http:example.com:8080",
                  "http:localhost", "http:", "unbekannt", "fs.read"] {
        var m = libScriptManifest()
        m.permissions = [bad]
        try expect(!ModValidation.validate(m).isEmpty, "Recht „\(bad)“ hätte abgelehnt werden müssen")
      }
    },
    CheckCase("Manifest: Werkzeug-Parameter müssen ein Objekt-Schema sein") {
      var m = libScriptManifest()
      m.tool = ModTool(description: "Macht etwas", parameters: "kein Schema")
      try expect(!ModValidation.validate(m).isEmpty, "Parameter als Text")
      var n = libScriptManifest()
      n.tool = ModTool(description: "Macht etwas", parameters: ["type": "array"])
      try expect(!ModValidation.validate(n).isEmpty, "Parameter vom Typ array")
      var ok = libScriptManifest()
      ok.tool = ModTool(description: "Macht etwas", parameters: ["type": "object", "properties": ["ort": ["type": "string"]]])
      try expectEqual(ModValidation.validate(ok), [], "Objekt-Schema")
    },
    CheckCase("Slug: Umlaute, Leerzeichen, Sonderzeichen") {
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "Wetter für Köln & Straße!", description: "d", asTool: false, triggers: []).id,
                      "wetter-fuer-koeln-strasse", "Umlaute")
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "  Hallo   Welt  ", description: "d", asTool: false, triggers: []).id,
                      "hallo-welt", "Leerzeichen")
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "Äpfel", description: "d", asTool: false, triggers: []).id,
                      "aepfel", "Ä")
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "Café Été", description: "d", asTool: false, triggers: []).id,
                      "cafe-ete", "Akzente")
    },
    CheckCase("Slug: Länge 3 bis 40 und immer gültige ID") {
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "Ab", description: "d", asTool: false, triggers: []).id,
                      "mod-ab", "zu kurz")
      try expectEqual(ShortcutModFactory.manifest(shortcutName: "!!!", description: "d", asTool: false, triggers: []).id,
                      "mod", "nur Sonderzeichen")
      let long = ShortcutModFactory.manifest(shortcutName: String(repeating: "abcde ", count: 20), description: "d",
                                             asTool: false, triggers: [])
      try expectEqual(long.id.count, 40, "lange Namen werden gekürzt")
      try expect(!ModValidation.validate(long).contains { $0.contains("ID") }, "gekürzte ID ist gültig")
      for name in ["Wetter heute", "Äpfel & Öl", "x", "Ünïcødé Ωmega 123"] {
        let m = ShortcutModFactory.manifest(shortcutName: name, description: "d", asTool: true, triggers: [])
        try expectEqual(ModValidation.validate(m), [], "Factory-Manifest für „\(name)“")
      }
    },
    CheckCase("Bibliothek: Liste wird neu gelesen, wenn sich der Mod-Ordner ändert (sonst aus dem Zwischenspeicher)") {
      let base = try libTempDir("cache")
      defer { try? FileManager.default.removeItem(at: base) }
      let root = base.appendingPathComponent("Mods")
      let lib = ModLibrary(root: root)
      _ = try lib.install(libScriptManifest(id: "eins"), code: "function run() { return 1; }")
      try expectEqual(try lib.all().map(\.manifest.id), ["eins"])
      try expectEqual(try lib.all().map(\.manifest.id), ["eins"], "ohne Änderung dasselbe Ergebnis")
      // Außen angelegter Mod (ohne install()): der Ordner ändert sich, also wird neu geladen.
      let dir = root.appendingPathComponent("zwei")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try ModLibrary.encoder().encode(libScriptManifest(id: "zwei")).write(to: dir.appendingPathComponent("mod.json"))
      try "function run() { return 2; }".write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
      try expectEqual(try lib.all().map(\.manifest.id).sorted(), ["eins", "zwei"])
      // Gelöschter Mod verschwindet ebenfalls.
      try FileManager.default.removeItem(at: dir)
      try expectEqual(try lib.all().map(\.manifest.id), ["eins"])
    },
    CheckCase("Bibliothek: neuer Kurzbefehl-Mod ist ausgeschaltet und nicht freigegeben") {
      let base = try libTempDir("neu")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      let info = try lib.install(libShortcutManifest(), code: nil)
      try expect(!info.enabled && !info.approved, "frisch installiert: aus und nicht freigegeben")
      let all = try lib.all()
      try expectEqual(all.count, 1, "Anzahl Mods")
      try expect(!all[0].enabled && !all[0].approved, "all(): aus und nicht freigegeben")
      try expect(all[0].code == nil, "Kurzbefehl hat keinen Code")
      try expect(!(try lib.isRunnable("wetter-heute")), "nicht lauffähig ohne Freigabe")
    },
    CheckCase("Bibliothek: Skript-Mod braucht Code und gültiges Manifest") {
      let base = try libTempDir("skriptfehler")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      try await expectThrows("Skript ohne Code hätte fehlschlagen müssen") {
        _ = try lib.install(libScriptManifest(), code: nil)
      }
      var broken = libScriptManifest()
      broken.id = "X"
      try await expectThrows("ungültiges Manifest hätte fehlschlagen müssen") {
        _ = try lib.install(broken, code: "function run() {}")
      }
      try expectEqual(try lib.all().count, 0, "nichts installiert")
    },
    CheckCase("Bibliothek: Einschalten gibt frei, Codeänderung sperrt bis zum erneuten Einschalten") {
      let base = try libTempDir("freigabe")
      defer { try? FileManager.default.removeItem(at: base) }
      let root = base.appendingPathComponent("Mods")
      let lib = ModLibrary(root: root)
      _ = try lib.install(libScriptManifest(), code: "function run(input) { return 'a'; }")
      let id = libScriptManifest().id

      let on = try lib.setEnabled(id, true, now: "2026-10-12T09:00")
      try expect(on.enabled && on.approved, "eingeschaltet = freigegeben")
      try expect(try lib.isRunnable(id), "lauffähig nach Einschalten")
      try expectEqual(try lib.code(id), "function run(input) { return 'a'; }", "Code lesbar")

      // Änderung direkt an der Datei: Hash stimmt nicht mehr.
      try "function run(input) { return 'b'; }".write(to: root.appendingPathComponent(id).appendingPathComponent("main.js"),
                                                    atomically: true, encoding: .utf8)
      try expect(!(try lib.isRunnable(id)), "nach Dateiänderung nicht lauffähig")
      let changed = try lib.all()
      try expect(!changed[0].approved, "all(): nach Änderung nicht freigegeben")

      // Neu installierte Fassung ist ebenfalls nicht freigegeben.
      _ = try lib.install(libScriptManifest(), code: "function run(input) { return 'c'; }")
      try expect(!(try lib.isRunnable(id)), "neue Fassung nicht lauffähig")
      let again = try lib.setEnabled(id, true, now: "2026-10-12T09:05")
      try expect(again.approved, "erneut eingeschaltet = freigegeben")
      try expect(try lib.isRunnable(id), "lauffähig nach erneutem Einschalten")
    },
    CheckCase("Bibliothek: Neuinstallation mit gleichem Inhalt behält Freigabe") {
      let base = try libTempDir("gleich")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      let m = libScriptManifest()
      _ = try lib.install(m, code: "function run() { return 1; }")
      _ = try lib.setEnabled(m.id, true, now: "2026-10-12T09:00")
      let info = try lib.install(m, code: "function run() { return 1; }")
      try expect(info.enabled && info.approved, "gleicher Inhalt: Freigabe bleibt")
    },
    CheckCase("Bibliothek: Ausschalten nimmt die Lauffähigkeit weg") {
      let base = try libTempDir("aus")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      let m = libScriptManifest()
      _ = try lib.install(m, code: "function run() { return 1; }")
      _ = try lib.setEnabled(m.id, true, now: "2026-10-12T09:00")
      let off = try lib.setEnabled(m.id, false, now: "2026-10-12T09:10")
      try expect(!off.enabled && !off.approved, "ausgeschaltet")
      try expect(!(try lib.isRunnable(m.id)), "nach Ausschalten nicht lauffähig")
      _ = try lib.setEnabled(m.id, true, now: "2026-10-12T09:20")
      try expect(try lib.isRunnable(m.id), "wieder lauffähig nach Einschalten")
    },
    CheckCase("Bibliothek: Lauf-Protokoll wird gespeichert und gelöscht") {
      let base = try libTempDir("lauf")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      _ = try lib.install(libShortcutManifest(), code: nil)
      try lib.recordRun("wetter-heute", at: "2026-10-12T08:00", error: "Kaputt")
      var info = try expectNotNil(try lib.all().first)
      try expectEqual(info.lastRunAt, "2026-10-12T08:00", "Zeitpunkt")
      try expectEqual(info.lastError, "Kaputt", "Fehler")
      try lib.recordRun("wetter-heute", at: "2026-10-12T08:05", error: nil)
      info = try expectNotNil(try lib.all().first)
      try expect(info.lastError == nil, "Fehler wird gelöscht")
    },
    CheckCase("Bibliothek: Löschen entfernt Ordner und Zustand") {
      let base = try libTempDir("loeschen")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      let m = libScriptManifest()
      _ = try lib.install(m, code: "function run() { return 1; }")
      _ = try lib.setEnabled(m.id, true, now: "2026-10-12T09:00")
      try lib.delete(m.id)
      try expectEqual(try lib.all().count, 0, "keine Mods mehr")
      try expect(try lib.manifest(m.id) == nil, "manifest nil")
      try expect(try lib.code(m.id) == nil, "code nil")
      try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Mods/\(m.id)").path), "Ordner weg")
      try await expectThrows("Löschen eines fehlenden Mods hätte fehlschlagen müssen") {
        try lib.delete(m.id)
      }
    },
    CheckCase("Bibliothek: Fehlende Mods und ungültige IDs als Fehler, Ordner ohne gültiges Manifest wird übersprungen") {
      let base = try libTempDir("kaputt")
      defer { try? FileManager.default.removeItem(at: base) }
      let root = base.appendingPathComponent("Mods")
      let lib = ModLibrary(root: root)
      try await expectThrows("setEnabled bei fehlendem Mod") {
        _ = try lib.setEnabled("gibt-es-nicht", true, now: "2026-10-12T09:00")
      }
      try await expectThrows("recordRun bei ungültiger ID") {
        try lib.recordRun("../etwas", at: "2026-10-12T09:00", error: nil)
      }
      _ = try lib.install(libShortcutManifest(), code: nil)
      let broken = root.appendingPathComponent("zerbrochen", isDirectory: true)
      try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
      try "{ kaputt".write(to: broken.appendingPathComponent("mod.json"), atomically: true, encoding: .utf8)
      let all = try lib.all()
      try expectEqual(all.map { $0.id }, ["wetter-heute"], "nur der gültige Mod erscheint")
    },
    CheckCase("Teilen: Export und Import ergeben einen ausgeschalteten Mod mit gleichem Code") {
      let base = try libTempDir("teilen")
      defer { try? FileManager.default.removeItem(at: base) }
      let src = ModLibrary(root: base.appendingPathComponent("A"))
      let m = libScriptManifest()
      let code = "function run(input) { return 'teilen'; }"
      _ = try src.install(m, code: code)
      _ = try src.setEnabled(m.id, true, now: "2026-10-12T09:00")
      let file = try src.export(m.id, to: base.appendingPathComponent("Export"))
      try expectEqual(file.lastPathComponent, "\(m.id).tabymod", "Dateiname")
      try expect(FileManager.default.fileExists(atPath: file.path), "Datei vorhanden")

      let dst = ModLibrary(root: base.appendingPathComponent("B"))
      let info = try dst.importMod(from: file)
      try expectEqual(info.id, m.id, "ID")
      try expect(!info.enabled && !info.approved, "importiert: ausgeschaltet und nicht freigegeben")
      try expectEqual(info.code, code, "Code gleich")
      try expect(!(try dst.isRunnable(m.id)), "importiert nicht lauffähig")
    },
    CheckCase("Teilen: Import in dieselbe Bibliothek schaltet den Mod aus") {
      let base = try libTempDir("selbst")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      let m = libScriptManifest()
      _ = try lib.install(m, code: "function run() { return 2; }")
      _ = try lib.setEnabled(m.id, true, now: "2026-10-12T09:00")
      let file = try lib.export(m.id, to: base.appendingPathComponent("Export"))
      let info = try lib.importMod(from: file)
      try expect(!info.enabled && !info.approved, "gleicher Inhalt, Import: trotzdem ausgeschaltet")
    },
    CheckCase("Teilen: Paket mit ../ im Pfad wird abgelehnt") {
      let base = try libTempDir("traversal")
      defer { try? FileManager.default.removeItem(at: base) }
      let zip = base.appendingPathComponent("boese.tabymod")
      try libRunPython("""
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1], 'w')
        z.writestr('../evil.json', '{}')
        z.writestr('wetter/mod.json', '{}')
        z.close()
        """, [zip.path])
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      try expectArchiveRejected(lib, zip, "../ im Paket hätte abgelehnt werden müssen")
      try expectEqual(try lib.all().count, 0, "nichts installiert")
      try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("evil.json").path),
                 "keine Datei außerhalb geschrieben")
    },
    CheckCase("Teilen: Paket mit Symlink wird abgelehnt") {
      let base = try libTempDir("symlink")
      defer { try? FileManager.default.removeItem(at: base) }
      let folder = base.appendingPathComponent("pkg/wetter-link", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let lib0 = ModLibrary(root: base.appendingPathComponent("Quelle"))
      let m = libScriptManifest()
      _ = try lib0.install(m, code: "function run() { return 3; }")
      try FileManager.default.copyItem(at: base.appendingPathComponent("Quelle/\(m.id)/mod.json"),
                                       to: folder.appendingPathComponent("mod.json"))
      try FileManager.default.copyItem(at: base.appendingPathComponent("Quelle/\(m.id)/main.js"),
                                       to: folder.appendingPathComponent("main.js"))
      try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("geheim.txt"),
                                                 withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
      let zip = base.appendingPathComponent("link.tabymod")
      try libZip(folder, to: zip)
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      try expectArchiveRejected(lib, zip, "Symlink im Paket hätte abgelehnt werden müssen")
      try expectEqual(try lib.all().count, 0, "nichts installiert")
    },
    CheckCase("Teilen: Paket mit ungültigem Manifest wird abgelehnt") {
      let base = try libTempDir("manifest")
      defer { try? FileManager.default.removeItem(at: base) }
      let folder = base.appendingPathComponent("pkg/schlecht", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var m = libScriptManifest()
      m.id = "Schlecht Gross"
      let data = try ModLibrary.encoder().encode(m)
      try data.write(to: folder.appendingPathComponent("mod.json"))
      try "function run() {}".write(to: folder.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
      let zip = base.appendingPathComponent("schlecht.tabymod")
      try libZip(folder, to: zip)
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      do {
        _ = try lib.importMod(from: zip)
        throw fail("ungültiges Manifest hätte abgelehnt werden müssen")
      } catch let e as ModError {
        guard case .invalid = e else { throw fail("erwartet .invalid, war \(e)") }
      }
      try expectEqual(try lib.all().count, 0, "nichts installiert")
    },
    CheckCase("Teilen: zu viele Dateien oder Datei über 1 MB werden abgelehnt") {
      let base = try libTempDir("grenzen")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))

      let many = base.appendingPathComponent("pkg/viele", isDirectory: true)
      try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
      _ = try lib.install(libShortcutManifest(), code: nil)
      try FileManager.default.copyItem(at: base.appendingPathComponent("Mods/wetter-heute/mod.json"),
                                       to: many.appendingPathComponent("mod.json"))
      for i in 0..<21 {
        try "x".write(to: many.appendingPathComponent("datei\(i).txt"), atomically: true, encoding: .utf8)
      }
      let zipMany = base.appendingPathComponent("viele.tabymod")
      try libZip(many, to: zipMany)
      try await expectThrows("21 Dateien hätten abgelehnt werden müssen") { _ = try lib.importMod(from: zipMany) }

      let big = base.appendingPathComponent("pkg/gross", isDirectory: true)
      try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
      let m = libScriptManifest(id: "gross-skript")
      try ModLibrary.encoder().encode(m).write(to: big.appendingPathComponent("mod.json"))
      try Data(repeating: 0x2F, count: 1_100_000).write(to: big.appendingPathComponent("main.js"))
      let zipBig = base.appendingPathComponent("gross.tabymod")
      try libZip(big, to: zipBig)
      try await expectThrows("Datei über 1 MB hätte abgelehnt werden müssen") { _ = try lib.importMod(from: zipBig) }
      try expectEqual(try lib.all().count, 1, "nur der Kurzbefehl ist installiert")
    },
    CheckCase("Kurzbefehle: Liste und Aufruf über Ersatzprogramm") {
      let base = try libTempDir("kurzbefehle")
      defer { try? FileManager.default.removeItem(at: base) }
      let cli = try libFakeShortcuts(base)
      try expectEqual(try cli.list(), ["Wetter heute", "Kurzbefehl zwei"], "Liste ohne Leerzeilen")
      try expectEqual(try cli.run("Wetter heute", input: "Hallo Welt", timeout: 10), "Hallo Welt", "Eingabe kommt zurück")
      try expectEqual(try cli.run("Wetter heute", input: nil, timeout: 10), "ok", "Ausgabe ohne Eingabe")
      try expectEqual(try cli.run("leer", input: nil, timeout: 10), "", "keine Ausgabe ist leerer Text")
    },
    CheckCase("Kurzbefehle: Fehlerlauf meldet Fehlertext auf Deutsch") {
      let base = try libTempDir("kurzfehler")
      defer { try? FileManager.default.removeItem(at: base) }
      let cli = try libFakeShortcuts(base)
      do {
        _ = try cli.run("kaputt", input: nil, timeout: 10)
        throw fail("Fehlerlauf hätte werfen müssen")
      } catch let e as ModError {
        guard case .process(let text) = e else { throw fail("erwartet .process, war \(e)") }
        try expect(text.contains("Fehler im Kurzbefehl"), "Stderr-Text fehlt: \(text)")
      }
    },
    CheckCase("Kurzbefehle: Zeitlimit bricht ab") {
      let base = try libTempDir("kurzzeit")
      defer { try? FileManager.default.removeItem(at: base) }
      let cli = try libFakeShortcuts(base)
      do {
        _ = try cli.run("langsam", input: nil, timeout: 0.5)
        throw fail("Zeitlimit hätte greifen müssen")
      } catch let e as ModError {
        guard case .process(let text) = e else { throw fail("erwartet .process, war \(e)") }
        try expect(text.contains("zu lange"), "Zeitüberschreitung fehlt: \(text)")
      }
    },
  ]
}

// MARK: Hilfsfunktionen der Prüfungen

private func libShortcutManifest() -> ModManifest {
  ShortcutModFactory.manifest(shortcutName: "Wetter heute", description: "Zeigt das Wetter", asTool: true,
                              triggers: [.dayStarted])
}

private func libScriptManifest(id: String = "tagesgruss") -> ModManifest {
  ModManifest(id: id, name: "Tagesgruß", description: "Grüßt am Morgen", kind: .script,
              entry: "main.js", triggers: [.dayStarted], permissions: ["notify"])
}

private func libTempDir(_ name: String) throws -> URL {
  let u = FileManager.default.temporaryDirectory
    .appendingPathComponent("taby-modcheck-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}

/// Prüft, dass der Import mit einem Archiv-Fehler (nicht z. B. einem Lesefehler) abbricht.
private func expectArchiveRejected(_ lib: ModLibrary, _ zip: URL, _ message: String) throws {
  do {
    _ = try lib.importMod(from: zip)
  } catch let e as ModError {
    guard case .archive = e else { throw fail("\(message) (Fehler war \(e))") }
    return
  }
  throw fail(message)
}

/// Zippt einen Ordner wie das Export-Format (ditto, mit Ordner obendrauf).
private func libZip(_ folder: URL, to zip: URL) throws {
  let r = try ModProcess.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path], timeout: 60)
  try expect(r.status == 0, "ditto zippen fehlgeschlagen: \(r.stderr)")
}

/// Führt ein kurzes Python-Skript im isolierten Modus aus (nur zum Bauen böser Testpakete).
private func libRunPython(_ script: String, _ args: [String]) throws {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  p.arguments = ["-I", "-c", script] + args
  try p.run()
  p.waitUntilExit()
  try expect(p.terminationStatus == 0, "python3 zum Bauen des Testpakets fehlgeschlagen")
}

/// Ersatz für /usr/bin/shortcuts: ein Shell-Skript, das `list` und `run` nachahmt.
private func libFakeShortcuts(_ base: URL) throws -> ShortcutsCLI {
  let script = base.appendingPathComponent("fake-shortcuts.sh")
  let body = """
    #!/bin/sh
    if [ "$1" = "list" ]; then
      printf 'Wetter heute\\n  Kurzbefehl zwei  \\n\\n'
      exit 0
    fi
    out=""
    in=""
    name="$2"
    while [ $# -gt 0 ]; do
      case "$1" in
        --output-path) out="$2"; shift ;;
        --input-path) in="$2"; shift ;;
      esac
      shift
    done
    if [ "$name" = "kaputt" ]; then
      echo "Fehler im Kurzbefehl" >&2
      exit 3
    fi
    if [ "$name" = "langsam" ]; then
      sleep 5
      exit 0
    fi
    if [ "$name" = "leer" ]; then
      exit 0
    fi
    if [ -n "$in" ]; then
      cat "$in" > "$out"
    else
      printf 'ok' > "$out"
    fi
    exit 0
    """
  try body.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  return ShortcutsCLI(executablePath: script.path)
}
