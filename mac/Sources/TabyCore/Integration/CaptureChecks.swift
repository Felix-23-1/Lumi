// Prüfungen für „Merk dir das“: Ausgabe-Auswertung (Safari, Mail, Finder), Rückfall
// auf den App-Namen, Automation-Hinweis und die Ziele Notiz, Aufgabe, Später lesen.
// Skripte laufen über eine Attrappe; die Zeit ist steuerbar.
import Foundation

@MainActor
enum CaptureChecks {
  static func rig(front: CaptureFrontApp?, answer: @escaping (String) -> ProcessOutput = { _ in ProcessOutput(status: 0) })
    throws -> (CoreServices, MediaAndBackupsChecks.ScriptStub) {
    let stub = MediaAndBackupsChecks.ScriptStub(answer)
    var opts = CoreServices.Options(databasePath: try MediaAndBackupsChecks.tempDir() + "/taby.sqlite", socketPath: nil,
                                    clock: ControllableClock("2026-10-15T08:30"), keyStore: InMemoryApiKeyStore(),
                                    systemNotifier: SinkNotifier(), plannerInterval: nil)
    opts.captureScriptRunner = { script in stub.run(script) }
    opts.captureFrontApp = { front }
    return (try CoreServices(options: opts), stub)
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Merk dir das: Safari-Tab wird aus URL und Titel gelesen") {
        let s = CaptureParser.safari("https://example.de/artikel\tEin Artikel\n")
        try expectEqual(s, CapturedContext(app: "Safari", title: "Ein Artikel", url: "https://example.de/artikel"))
        try expectEqual(CaptureParser.safari("https://x.de\t\n")?.title, "https://x.de", "ohne Titel: URL als Titel")
        try expect(CaptureParser.safari("") == nil, "kein Fenster: nichts")
        try expect(CaptureParser.safari("\tTitel") == nil, "ohne URL: nichts")
      },
      CheckCase("Merk dir das: Mail-Link wird aus der Message-ID gebaut") {
        try expectEqual(CaptureParser.mailLink(messageId: "<abc@x.y>"), "message://%3Cabc%40x.y%3E")
        try expectEqual(CaptureParser.mailLink(messageId: "abc-1_2"), "message://%3Cabc-1_2%3E")
        try expect(CaptureParser.mailLink(messageId: "<>") == nil, "leere ID: kein Link")
        let m = CaptureParser.mail("Rechnung\tAnna <a@b.de>\t<id@host>")
        try expectEqual(m?.title, "Rechnung")
        try expectEqual(m?.text, "Von: Anna <a@b.de>")
        try expectEqual(m?.url, "message://%3Cid%40host%3E")
        try expect(CaptureParser.mail("") == nil, "keine Auswahl: nichts")
      },
      CheckCase("Merk dir das: Finder-Auswahl wird zu file://-Links") {
        let one = CaptureParser.finder("/Users/anna/Notiz.txt\n")
        try expectEqual(one?.title, "Notiz.txt")
        try expectEqual(one?.url, "file:///Users/anna/Notiz.txt")
        try expect(one?.text == nil, "eine Datei: kein Zusatz")
        let many = CaptureParser.finder("/a/b.pdf\n/c d/e.pdf\n")
        try expectEqual(many?.title, "b.pdf und 1 weitere")
        try expect(many?.text?.contains("c%20d/e.pdf") == true, "weitere Dateien mit Link")
        try expect(CaptureParser.finder("") == nil, "keine Auswahl: nichts")
      },
      CheckCase("Merk dir das: fehlende Automation meldet den deutschen Hinweis") {
        try expect(CaptureParser.denied("execution error: Not authorized to send Apple events (-1743)"), "-1743 erkannt")
        try expect(!CaptureParser.denied("syntax error"), "anderer Fehler ist keine Freigabe")
        let (svc, _) = try rig(front: CaptureFrontApp(bundleId: "com.apple.Safari", name: "Safari")) { _ in
          ProcessOutput(status: 1, stderr: "(-1743) denied")
        }
        let r = await svc.captureContext()
        try expect(r.errorMessage?.contains("Automation") == true, "Hinweis nennt Automation")
        try expect(r.errorMessage?.contains("Safari") == true, "Hinweis nennt die App")
      },
      CheckCase("Merk dir das: Safari liefert Kontext, ohne die App zu starten") {
        let (svc, stub) = try rig(front: CaptureFrontApp(bundleId: "com.apple.Safari", name: "Safari")) { _ in
          ProcessOutput(status: 0, stdout: "https://example.de\tStartseite\n")
        }
        let ctx = await svc.captureContext().value
        try expectEqual(ctx, CapturedContext(app: "Safari", title: "Startseite", url: "https://example.de"))
        try expect(stub.scripts.first?.contains("is running") == true, "Skript prüft erst, ob Safari läuft")
      },
      CheckCase("Merk dir das: andere App und leere Auswahl fallen auf den App-Namen zurück") {
        let (svc, stub) = try rig(front: CaptureFrontApp(bundleId: "com.apple.iCal", name: "Kalender"))
        let other = await svc.captureContext().value
        try expectEqual(other, CapturedContext(app: "Kalender", title: "Kalender"))
        try expectEqual(stub.scripts.count, 0, "für andere Apps kein Skript")

        let (empty, _) = try rig(front: CaptureFrontApp(bundleId: "com.apple.mail", name: "Mail")) { _ in
          ProcessOutput(status: 0, stdout: "\n")
        }
        let emptyCtx = await empty.captureContext().value
        try expectEqual(emptyCtx, CapturedContext(app: "Mail", title: "Mail"))
      },
      CheckCase("Merk dir das: Lumi selbst vorn nimmt die zuletzt aktive App") {
        let taby = CaptureFrontApp(bundleId: "de.felix.taby", name: "Lumi")
        let safari = CaptureFrontApp(bundleId: "com.apple.Safari", name: "Safari")
        try expectEqual(CaptureParser.pick(front: taby, previous: safari), safari)
        try expectEqual(CaptureParser.pick(front: safari, previous: nil), safari)
        try expectEqual(CaptureParser.pick(front: nil, previous: safari), safari)
      },
      CheckCase("Merk dir das: Notiz, Aufgabe und Später lesen landen im Speicher") {
        let (svc, _) = try rig(front: nil)
        let ctx = CapturedContext(app: "Safari", title: "Ein Artikel", url: "https://example.de", text: nil)
        let savedNote = await svc.saveCapture(ctx, as: .note)
        let savedTask = await svc.saveCapture(ctx, as: .task)
        let savedLater = await svc.saveCapture(ctx, as: .readLater)
        try expect(savedNote.isOk && savedTask.isOk && savedLater.isOk, "alle drei Ziele gespeichert")

        let state = await svc.state()
        let note = state.notes.first { $0.title == "Ein Artikel" }
        try expectEqual(note?.content, "https://example.de")
        let later = state.notes.first { $0.title == "📖 Später lesen: Ein Artikel" }
        try expectEqual(later?.content, "https://example.de")
        let task = state.tasks.first { $0.title == "Ein Artikel" }
        try expectEqual(task?.notes, "https://example.de")
      },
    ]
  }
}
