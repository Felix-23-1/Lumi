// Prüfungen für den Diagnose-Export: Ringpuffer, Bereinigung der Einstellungen, Zip-Inhalt (Attrappe statt ditto).
import Foundation

private final class RunRecorder: @unchecked Sendable {
  var path = ""
  var args: [String] = []
  var files: [String] = []
}

enum DiagnosticsChecks {
  static let cases: [CheckCase] = [
    CheckCase("Diagnose: MCP-Startargumente und Zugangsdaten in smb://-Adressen fliegen raus") {
      let cleaned = DiagnosticsExport.sanitize([
        "mcpServers": [["name": "x", "args": ["--token", "TESTWERT-1"]]],
        "url": "smb://nutzer:TESTWERT-2@nas.local/share?x=1",
        "web": "https://a:b@example.com/p?q=TESTWERT-3",
        "plain": "nur Text",
      ] as [String: Any])
      let json = String(data: try JSONSerialization.data(withJSONObject: cleaned), encoding: .utf8) ?? ""
      try expect(!json.contains("TESTWERT"), "Geheimnis im Export: \(json)")
      try expect(json.contains("nur Text") && json.contains("nas.local"), "Rest bleibt erhalten")
    },
    CheckCase("Protokoll: Ringpuffer begrenzt und älteste zuerst") {
      let buffer = TabyLogBuffer(capacity: 3, clock: ControllableClock("2024-03-04T08:00"))
      for i in 1...5 { buffer.append(.core, .info, "m\(i)") }
      let lines = buffer.snapshot()
      try expectEqual(buffer.count, 3)
      try expectEqual(lines.count, 3)
      try expect(lines[0].hasSuffix("m3") && lines[1].hasSuffix("m4") && lines[2].hasSuffix("m5"), "Reihenfolge")
      try expect(lines[0].contains("[core]") && lines[0].hasPrefix("2024-03-04T08:00"), "Format")
    },
    CheckCase("Protokoll: Zeilenumbrüche werden entschärft, Zeilen gekürzt") {
      let buffer = TabyLogBuffer(capacity: 10, clock: ControllableClock("2024-03-04T08:00"))
      buffer.append(.model, .error, "a\nb\rc")
      buffer.append(.mail, .info, String(repeating: "x", count: 1000))
      let lines = buffer.snapshot()
      try expectEqual(lines.count, 2)
      try expect(!lines[0].contains("\n") && !lines[0].contains("\r"), "Umbruch")
      try expect(lines[1].count < 500, "Länge")
    },
    CheckCase("Einstellungen: Geheimnisse und URL-Zugangsdaten fallen weg") {
      var settings = TabySettings.defaults
      settings.hasApiKey = true
      settings.llmBaseUrl = "https://user:pw@api.example.com/v1?key=abc#frag"
      let text = String(decoding: try DiagnosticsExport.settingsJSON(settings), as: UTF8.self)
      try expect(!text.contains("hasApiKey"), "Schlüssel-Feld")
      try expect(!text.contains("pw@") && !text.contains("abc") && !text.contains("frag"), "URL-Teile")
      try expect(text.contains("https://api.example.com/v1"), "URL ohne Zugangsdaten bleibt")
    },
    CheckCase("Einstellungen: Geburtstag fällt weg") {
      var settings = TabySettings.defaults
      settings.birthday = "10-15"
      let text = String(decoding: try DiagnosticsExport.settingsJSON(settings), as: UTF8.self)
      try expect(!text.contains("birthday") && !text.contains("10-15"), "Geburtstag nicht in der Diagnose")
    },
    CheckCase("Diagnose-Zip: Inhalt, Name und Eindeutigkeit mit Attrappe") {
      let recorder = RunRecorder()
      let stub: DiagnosticsExport.ProcessRunner = { path, args in
        recorder.path = path
        recorder.args = args
        recorder.files = (try? FileManager.default.contentsOfDirectory(atPath: args[3])) ?? []
        FileManager.default.createFile(atPath: args[4], contents: Data())
        return true
      }
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taby-diag-check-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: folder) }
      let clock = ControllableClock("2026-10-16T15:30")
      let first = await DiagnosticsExport.export(folder: folder.path, clock: clock, settings: Data("{}".utf8),
                                                 logText: "l", versionText: "v", statsText: "s", runner: stub)
      let firstPath = try expectNotNil(first.value, "Ergebnis")
      try expect(firstPath.hasSuffix("/Lumi-Diagnose-2026-10-16-1530.zip"), "Name \(firstPath)")
      try expectEqual(recorder.files.sorted(), DiagnosticsExport.fileNames.sorted())
      try expectEqual(recorder.path, "/usr/bin/ditto")
      try expectEqual(recorder.args.prefix(3).joined(separator: " "), "-c -k --sequesterRsrc")
      let second = await DiagnosticsExport.export(folder: folder.path, clock: clock, settings: Data("{}".utf8),
                                                  logText: "l", versionText: "v", statsText: "s", runner: stub)
      let secondPath = try expectNotNil(second.value, "Ergebnis 2")
      try expect(secondPath.hasSuffix("/Lumi-Diagnose-2026-10-16-1530-2.zip"), "Eindeutig \(secondPath)")
    },
    CheckCase("Diagnose-Zip: fehlgeschlagener Zip-Lauf meldet Fehler") {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taby-diag-fail-\(StoreIds.make())")
      defer { try? FileManager.default.removeItem(at: folder) }
      let result = await DiagnosticsExport.export(folder: folder.path, clock: ControllableClock("2026-10-16T15:30"),
                                                  settings: Data("{}".utf8), logText: "", versionText: "",
                                                  statsText: "", runner: { _, _ in false })
      try expectEqual(result.isOk, false)
    },
    CheckCase("Diagnose-Statistik: Zeilen je Tabelle, ohne interne Tabellen") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let text = DiagnosticsExport.statsText(db: store.db, databaseBytes: 42)
      try expect(text.hasPrefix("Datenbank-Bytes: 42\n"), "Kopf")
      try expect(text.contains("tasks: 0"), "Tabelle tasks")
      try expect(!text.contains("sqlite_"), "interne Tabellen")
    },
  ]
}
