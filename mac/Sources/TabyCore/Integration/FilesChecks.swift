// Prüfungen für das Paket Dateien: Abfrage, Ausschlüsse, Zuordnung mit Attrappe
// (kein echtes mdfind) und das Datenschutz-Gate (Cloud-Modell sieht keine Dateien).
import Foundation

@MainActor
enum FilesChecks {
  final class ArgsBox: @unchecked Sendable {
    var calls: [(String, [String])] = []
  }

  /// Leerer Startordner in einem temporären Verzeichnis.
  static func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("taby-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
  }

  /// Legt eine Datei mit festem Änderungsdatum an; liefert ihren Pfad.
  static func put(_ rel: String, in home: URL, modified: String) throws -> String {
    let url = home.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
    let date = try expectNotNil(LocalTime.parse(modified), "Datum")
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url.path
  }

  static func rig(apple: Bool, model: String) async throws -> CoreServices {
    var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                    keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
    opts.appleIntelligence = apple
    let svc = try CoreServices(options: opts)
    _ = await svc.updateSettings(SettingsPatch(llmModel: model), apiKey: nil)
    return svc
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Dateien: Abfrage setzt jedes Wort in Anführung und escaped Sonderzeichen") {
        try expectEqual(FileSearch.query(for: "Angebot"),
                        "(kMDItemDisplayName == \"*Angebot*\"cd || kMDItemTextContent == \"*Angebot*\"cd)")
        try expect(FileSearch.query(for: "   ") == nil, "leer ergibt keine Abfrage")
        try expect(FileSearch.query(for: "a b")?.contains(" && ") == true, "Wörter werden UND-verknüpft")
        try expect(FileSearch.query(for: "x\"y")?.contains("*x\\\"y*") == true, "Anführungszeichen escaped")
        try expect(FileSearch.query(for: "a*")?.contains("*a\\**") == true, "Stern escaped")
        try expect(FileSearch.query(for: "a\\b")?.contains("*a\\\\b*") == true, "Backslash escaped")
      },
      CheckCase("Dateien: Ausschluss ~/Library, versteckte Ordner und .app; fremde Pfade fallen weg") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let good = try put("Dokumente/Angebot.pdf", in: home, modified: "2026-10-14T16:20")
        let lib = try put("Library/Angebot.txt", in: home, modified: "2026-10-15T09:00")
        let hidden = try put(".versteckt/Angebot.txt", in: home, modified: "2026-10-15T09:00")
        let app = try put("Tool.app/Contents/Angebot.txt", in: home, modified: "2026-10-15T09:00")
        let dot = try put(".Angebot-Kopie.txt", in: home, modified: "2026-10-15T09:00")
        let lines = [good, lib, hidden, app, dot, "/etc/hosts"].joined(separator: "\n")
        let stub: FileSearch.Runner = { _, _ in ProcessOutput(status: 0, stdout: lines) }
        let hits = FileSearch.find("Angebot", home: home.path, run: stub)
        try expectEqual(hits.map(\.name), ["Angebot.pdf"], "nur der normale Treffer bleibt")
        try expectEqual(hits.first?.modifiedAt, "2026-10-14T16:20", "Datum als lokale Zeit")
      },
      CheckCase("Dateien: neueste zuerst, höchstens 20 Treffer") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var paths: [String] = []
        for i in 0..<25 {
          paths.append(try put("f\(i).txt", in: home, modified: "2026-10-01T08:\(String(format: "%02d", i))"))
        }
        let stub: FileSearch.Runner = { _, _ in ProcessOutput(status: 0, stdout: paths.joined(separator: "\n")) }
        let hits = FileSearch.find("f", home: home.path, run: stub)
        try expectEqual(hits.count, 20, "Obergrenze 20")
        try expectEqual(hits.first?.name, "f24.txt", "neueste zuerst")
        try expectEqual(hits.last?.name, "f5.txt", "älteste der 20 zuletzt")
      },
      CheckCase("Dateien: mdfind nur mit Argumentliste, Startordner ist der Benutzerordner") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let box = ArgsBox()
        let stub: FileSearch.Runner = { exe, args in
          box.calls.append((exe, args))
          return ProcessOutput(status: 0)
        }
        _ = FileSearch.find("a\"; rm -rf ~", home: home.path, run: stub)
        let call = try expectNotNil(box.calls.first, "mdfind gestartet")
        try expectEqual(call.0, "/usr/bin/mdfind")
        try expectEqual(call.1.count, 3, "drei Argumente, kein Shell-Text")
        try expectEqual(call.1[0], "-onlyin")
        try expectEqual(call.1[1], home.path)
        try expect(call.1[2].contains("kMDItemDisplayName"), "Abfrage als ein Argument")
      },
      CheckCase("Dateien: Fehler oder Zeitüberschreitung ergeben keine Treffer") {
        let failing: FileSearch.Runner = { _, _ in throw CocoaError(.fileReadUnknown) }
        try expect(FileSearch.find("x", home: "/tmp", run: failing).isEmpty, "Fehler")
        let slow: FileSearch.Runner = { _, _ in ProcessOutput(status: 0, timedOut: true, stdout: "/tmp/x") }
        try expect(FileSearch.find("x", home: "/tmp", run: slow).isEmpty, "Zeitüberschreitung")
      },
      CheckCase("Dateien: Kern-Suche nutzt Startordner und Attrappe") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try put("Angebot.pdf", in: home, modified: "2026-10-14T16:20")
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                        keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.fileSearchHome = home.path
        opts.fileSearchRunner = { _, _ in ProcessOutput(status: 0, stdout: path) }
        let svc = try CoreServices(options: opts)
        let hits = await svc.findFiles("Angebot")
        try expectEqual(hits.map(\.name), ["Angebot.pdf"])
        try expectEqual(hits.first?.path, path)
      },
      CheckCase("Datenschutz: find_files nur bei Apple Intelligence, nie bei einem Cloud-Modell") {
        let cloud = try await rig(apple: true, model: "openai/gpt-5")
        try expect(cloud.filesToolDefs().isEmpty, "Cloud-Modell bekommt kein find_files")
        let off = try await rig(apple: false, model: TabySettings.appleIntelligenceModel)
        try expect(off.filesToolDefs().isEmpty, "Apple aus: kein find_files")
        let on = try await rig(apple: true, model: TabySettings.appleIntelligenceModel)
        try expectEqual(on.filesToolDefs().map(\.name), ["find_files"])
        try expect(!ToolRegistry.definitions.contains { $0.name == "find_files" }, "nie in der Werkzeugliste")
        let denied = await cloud.filesTool("find_files", "{\"query\":\"Angebot\"}")
        try expectEqual(denied?["code"]?.stringValue, "FILES_OFF", "Ausführung trotzdem gesperrt")
      },
      CheckCase("Datenschutz: Cloud-Verlauf ohne find_files-Turn, Dateinamen erreichen das Modell nicht") {
        let history = [
          ChatMessage(role: .user, content: "Such mein Angebot"),
          ChatMessage(role: .assistant, content: nil,
                      toolCalls: [ToolCall(id: "f1", name: "find_files", arguments: "{\"query\":\"Angebot\"}")]),
          ChatMessage(role: .tool, content: "{\"files\":[{\"path\":\"/Users/ich/Documents/Angebot.pdf\"}]}",
                      name: "find_files", toolCallId: "f1"),
          ChatMessage(role: .assistant, content: "Gefunden: Angebot.pdf"),
          ChatMessage(role: .user, content: "Danke"),
          ChatMessage(role: .assistant, content: "Gern"),
        ]
        let llm = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "Ok"))])
        _ = try await AgentLoop.run(AgentLoopChecks.deps(llm), history: FileSearch.cloudHistory(history),
                                    userText: "Was war noch?")
        let sent = llm.requests.flatMap { $0.messages }.compactMap(\.content).joined(separator: "\n")
        try expect(!sent.contains("Angebot"), "kein Dateiname in der ausgehenden Anfrage")
        try expect(sent.contains("Gern"), "übrige Turns bleiben im Verlauf")
      },
      CheckCase("Datenschutz: Chat-Modell Apple ist lokal, Cloud-Client nie mit Apple-Namen") {
        let on = try await rig(apple: true, model: TabySettings.appleIntelligenceModel)
        try expect(on.llmClient() is AppleIntelligenceClient, "lokaler Client")
        let unavailable = try await rig(apple: false, model: TabySettings.appleIntelligenceModel)
        try expect(unavailable.llmClient() == nil, "ohne Apple kein Cloud-Ausweichen")
        let cloud = try await rig(apple: true, model: "openai/gpt-5")
        try expect(!(cloud.llmClient() is AppleIntelligenceClient), "Cloud bleibt Cloud")
      },
      CheckCase("Datenschutz: Zusammenfassen ohne Apple Intelligence verweigert mit Hinweis") {
        let cloud = try await rig(apple: true, model: "openai/gpt-5")
        let r = await cloud.summarizeFile("/Users/ich/Documents/Angebot.pdf")
        try expectEqual(r.errorMessage, "Zusammenfassen gibt es nur mit Apple Intelligence – so verlässt die Datei deinen Mac nicht.")
        let off = try await rig(apple: false, model: TabySettings.appleIntelligenceModel)
        let offResult = await off.summarizeFile("/x.pdf")
        try expect(offResult.errorMessage?.contains("nicht verfügbar") == true, "Apple aus: Hinweis statt Cloud")
        let unsupported = try await rig(apple: true, model: TabySettings.appleIntelligenceModel)
        let typeResult = await unsupported.summarizeFile("/x.png")
        try expect(typeResult.errorMessage?.contains("txt, md, rtf, pdf, docx") == true, "Dateityp abgelehnt")
      },
    ]
  }
}
