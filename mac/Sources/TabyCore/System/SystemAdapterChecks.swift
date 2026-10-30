// Prüfungen der Systemanbindung: Diktat-Text, Fokus-Umgebung, installierte Apps.
import Foundation

/// Fake-Kurzbefehl-Programm: zeichnet Aufrufe auf; „Kaputt“ schlägt fehl.
private final class FakeShortcutRunner: ShortcutsRunning {
  private let lock = NSLock()
  private var ran: [String] = []

  var names: [String] {
    lock.lock(); defer { lock.unlock() }
    return ran
  }

  func list() throws -> [String] { [] }

  func run(_ name: String, input: String?, timeout: TimeInterval) throws -> String {
    lock.lock()
    ran.append(name)
    lock.unlock()
    if name == "Kaputt" { throw FakeShortcutFailure() }
    return ""
  }
}

private struct FakeShortcutFailure: Error {}

/// Fake-App-Zugriff: zeichnet auf, welche Apps ausgeblendet wurden.
private final class FakeAppHider: AppHider {
  let running: [String]
  private(set) var hidden: [String] = []

  init(running: [String]) { self.running = running }

  func runningApps() -> [(bundleId: String, hide: () -> Void)] {
    running.map { id in
      (bundleId: id, hide: { [self] in self.hidden.append(id) })
    }
  }
}

public enum SystemAdapterChecks {
  @MainActor public static var suite: CheckSuite {
    CheckSuite("SystemAdapters", [
      CheckCase("SpeechRecognizer.cleanTranscript: Leerraum, Großschreibung") {
        try expectEqual(SpeechRecognizer.cleanTranscript("  hallo   welt\n\nbitte "), "Hallo welt bitte")
        try expectEqual(SpeechRecognizer.cleanTranscript("Schon groß"), "Schon groß")
        try expectEqual(SpeechRecognizer.cleanTranscript("   "), "")
        try expectEqual(SpeechRecognizer.cleanTranscript(""), "")
      },
      CheckCase("SpeechRecognizer.emptyResultReason: Stille, Abbruch, nur kurz gedrückt") {
        let silent = SpeechRecognizer.emptyResultReason(peak: 0, seconds: 2, error: nil) ?? ""
        try expect(silent.contains("Mikrofon"), silent)
        let failed = SpeechRecognizer.emptyResultReason(peak: 0.3, seconds: 2, error: "kAFAssistantErrorDomain 1101: x") ?? ""
        try expect(failed.contains("1101") && failed.contains("Diktat"), failed)
        try expect(SpeechRecognizer.emptyResultReason(peak: 0, seconds: 0.2, error: nil) == nil, "kurzer Tipp ist keine Stille")
        try expect(SpeechRecognizer.emptyResultReason(peak: 0.003, seconds: 2, error: nil) == nil, "nichts gesagt (nur leise)")
        let heard = SpeechRecognizer.emptyResultReason(peak: 0.3, seconds: 2, error: nil) ?? ""
        try expect(heard.contains("gehört") && heard.contains("Diktat"), "gesprochen, aber kein Text: Hinweis aufs Diktat")
      },
      CheckCase("FocusEnvironment: Kurzbefehl an, nur gelistete Apps ausblenden, Ende") {
        let runner = FakeShortcutRunner()
        let hider = FakeAppHider(running: ["com.a", "com.b", "com.c"])
        let env = FocusEnvironment(runner: runner, hider: hider)
        env.begin(shortcutOn: "Fokus an", hideApps: ["com.a", "com.d"])
        await env.awaitShortcuts()
        try expect(env.active, "Fokus sollte aktiv sein")
        try expectEqual(runner.names, ["Fokus an"])
        try expectEqual(hider.hidden, ["com.a"], "nur com.a ist gelistet und läuft")

        env.end(shortcutOff: "Fokus aus")
        await env.awaitShortcuts()
        try expect(!env.active, "Fokus sollte beendet sein")
        try expectEqual(runner.names, ["Fokus an", "Fokus aus"])
        try expectEqual(hider.hidden, ["com.a"], "Ende hebt das Ausblenden nicht auf")
        try expect(env.lastError == nil, "kein Fehler erwartet")
      },
      CheckCase("FocusEnvironment: leerer Kurzbefehl wird nicht gestartet") {
        let runner = FakeShortcutRunner()
        let env = FocusEnvironment(runner: runner, hider: FakeAppHider(running: ["com.a"]))
        env.begin(shortcutOn: "", hideApps: [])
        await env.awaitShortcuts()
        try expect(runner.names.isEmpty, "kein Kurzbefehl erwartet")
        env.end(shortcutOff: "")
        await env.awaitShortcuts()
        try expect(runner.names.isEmpty, "auch beim Ende nicht")
      },
      CheckCase("FocusEnvironment: fehlgeschlagener Kurzbefehl setzt lastError") {
        let runner = FakeShortcutRunner()
        let env = FocusEnvironment(runner: runner, hider: FakeAppHider(running: []))
        env.begin(shortcutOn: "Kaputt", hideApps: [])
        await env.awaitShortcuts()
        let message = try expectNotNil(env.lastError, "lastError fehlt")
        try expect(message.contains("„Kaputt“"), "Name fehlt in: \(message)")
        try expect(message.contains("fehlgeschlagen"), "Meldung fehlt in: \(message)")
      },
      CheckCase("InstalledApps: sortiert, ohne Dubletten, ohne Lumi, Safari dabei") {
        let apps = InstalledApps.list()
        try expect(!apps.isEmpty, "keine Apps gefunden")
        let ids = apps.map(\.id)
        try expectEqual(Set(ids).count, ids.count, "doppelte Bundle-IDs")
        try expect(!ids.contains("de.felix.taby"), "Lumi selbst darf nicht gelistet sein")
        let names = apps.map(\.name)
        try expectEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                        "nicht nach Name sortiert")
        try expect(ids.contains("com.apple.Safari"), "Safari fehlt")
      },
    ])
  }
}
