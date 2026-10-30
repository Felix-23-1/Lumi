// Prüfungen für Welle C der Mods: neue `taby.*`-Schnittstellen mit Recht und ohne,
// Speicher-Obergrenze, Einstellungen (Zusammenführung, Prüfung) und Zeitpläne.
// Kein echtes Netz, kein echter Speicher: Hosts und Dateien sind Fakes/temporär.
import Foundation

enum ModApiChecks {
  static let cases: [CheckCase] = [
    CheckCase("Neue taby-Funktionen: ohne Recht abgelehnt, mit Recht ausgeführt") {
      // (Aufruf, Recht, Eintrag im Host-Protokoll)
      let rows: [(call: String, perm: String, logged: String)] = [
        ("taby.habits.list()", "habits.read", "habits.list"),
        (#"taby.habits.check("h1")"#, "habits.write", "habits.check:h1"),
        ("taby.focus.start(25)", "focus", "focus.start:25"),
        ("taby.focus.stop()", "focus", "focus.stop"),
        ("taby.focus.isRunning()", "focus", "focus.isRunning"),
        (#"taby.timer.start(5, "Tee")"#, "timer", "timer.start:5:Tee"),
        ("taby.messages.recent(50)", "messages.read", "messages.recent:20"),
        (#"taby.mail.draft({to:"anna@example.de", subject:"Hi", body:"Text"})"#, "mail.draft", "mail.draft:anna@example.de"),
        (#"taby.storage.get("k")"#, "storage", "storage.get:k"),
        (#"taby.storage.set("k", 1)"#, "storage", "storage.set:k"),
      ]
      for row in rows {
        let code = "async function run(){ await \(row.call); return \"ok\" }"
        // Ohne Recht: die Sandbox lehnt ab, bevor der Host etwas tut.
        let denied = ApiFakeHost()
        var refusal: String?
        do { _ = try await apiRun(code, perms: [], host: denied) } catch let ScriptModError.permissionDenied(message) {
          refusal = message
        }
        try expect(refusal?.contains("Recht \(row.perm) fehlt") == true, "\(row.call): ohne Recht muss abgelehnt werden")
        try expectEqual(denied.calls.isEmpty, true, "\(row.call): ohne Recht darf der Host nicht aufgerufen werden")
        // Mit Recht: der Host bekommt genau diesen Aufruf.
        let host = ApiFakeHost()
        let r = try await apiRun(code, perms: [row.perm], host: host)
        try expectEqual(r.output, "ok", "\(row.call) mit Recht")
        try expectEqual(host.calls, [row.logged], "\(row.call): Host-Aufruf")
      }
    },
    CheckCase("Speicher: lesen, schreiben, 64-KB-Grenze je Mod") {
      let lib = ModLibrary(root: try apiTempDir("speicher"))
      try expectEqual(try lib.storageGet("m1", key: "a"), JSONValue.null, "unbekannter Schlüssel ist null")
      try lib.storageSet("m1", key: "a", value: .string("x"))
      try expectEqual(try lib.storageGet("m1", key: "a"), JSONValue.string("x"))
      try lib.storageSet("m2", key: "a", value: .number(7))
      try expectEqual(try lib.storageGet("m1", key: "a"), JSONValue.string("x"), "Mods sind getrennt")
      // Knapp unter der Grenze geht es, darüber nicht – und ein Fehlversuch ändert nichts.
      try lib.storageSet("m1", key: "gross", value: .string(String(repeating: "y", count: 60_000)))
      var failure: Error?
      do { try lib.storageSet("m1", key: "mehr", value: .string(String(repeating: "z", count: 10_000))) } catch { failure = error }
      try expectEqual(failure as? ModStorageError, ModStorageError.full)
      try expectEqual(try lib.storageGet("m1", key: "mehr"), JSONValue.null, "abgelehnter Wert wird nicht gespeichert")
      try expectEqual(try lib.storageGet("m2", key: "a"), JSONValue.number(7))
      var badKey: Error?
      do { try lib.storageSet("m1", key: "", value: .null) } catch { badKey = error }
      try expectEqual(badKey as? ModStorageError, ModStorageError.invalidKey)
    },
    CheckCase("Einstellungen: Standardwerte, gespeicherte Werte, Prüfung") {
      let manifest = apiManifest(settings: [
        ModSetting(key: "city", label: "Stadt", kind: .text, defaultValue: "Berlin"),
        ModSetting(key: "days", label: "Tage", kind: .number, defaultValue: "3"),
        ModSetting(key: "on", label: "An", kind: .toggle, defaultValue: "false"),
      ])
      let defaults = ModSettingRules.input(manifest: manifest, stored: [:])
      try expectEqual(defaults["city"], JSONValue.string("Berlin"))
      try expectEqual(defaults["days"], JSONValue.number(3))
      try expectEqual(defaults["on"], JSONValue.bool(false))
      let stored = ModSettingRules.input(manifest: manifest, stored: ["city": "Köln", "days": "5", "on": "true", "fremd": "x"])
      try expectEqual(stored["city"], JSONValue.string("Köln"))
      try expectEqual(stored["days"], JSONValue.number(5))
      try expectEqual(stored["on"], JSONValue.bool(true))
      try expectEqual(stored["fremd"], nil, "nur deklarierte Schlüssel")

      let number = manifest.settings![1], toggle = manifest.settings![2], text = manifest.settings![0]
      try expect(ModSettingRules.problem("abc", for: number) != nil, "Zahl muss eine Zahl sein")
      try expect(ModSettingRules.problem("2.5", for: number) == nil, "Dezimalzahl ist eine Zahl")
      try expect(ModSettingRules.problem("yes", for: toggle) != nil, "Schalter nur true/false")
      try expect(ModSettingRules.problem("false", for: toggle) == nil)
      try expect(ModSettingRules.problem(String(repeating: "a", count: 501), for: text) != nil, "Text max. 500 Zeichen")

      let withNull = ModSettingRules.withSettings(.null, settings: ["city": .string("Köln")])
      try expectEqual(withNull, JSONValue.object(["settings": .object(["city": .string("Köln")])]))
      let withText = ModSettingRules.withSettings(.string("hi"), settings: [:])
      try expectEqual(withText, JSONValue.object(["input": .string("hi"), "settings": .object([:])]))
    },
    CheckCase("Skript bekommt input.settings mit gespeicherten Werten") {
      let manifest = apiManifest(settings: [
        ModSetting(key: "city", label: "Stadt", kind: .text, defaultValue: "Berlin"),
        ModSetting(key: "days", label: "Tage", kind: .number, defaultValue: "3"),
      ])
      let host = ApiFakeHost()
      let r = try await apiRun(
        "function run(input){ return JSON.stringify(input.settings) }",
        perms: [], host: host, manifest: manifest, settingValues: ["city": "Köln"])
      try expect(r.output.contains(#""city":"Köln""#), "gespeicherte Stadt fehlt: \(r.output)")
      try expect(r.output.contains(#""days":3"#), "Standardwert fehlt: \(r.output)")
      // Vom Aufrufer mitgegebene Einstellungen bleiben erhalten (z. B. stopId).
      let kept = try await apiRun("function run(input){ return JSON.stringify(input.settings) }", perms: [],
                                  host: host, manifest: manifest, settingValues: [:])
      try expect(kept.output.contains(#""city":"Berlin""#), "Standard fehlt: \(kept.output)")
    },
    CheckCase("Einstellung ändern braucht keine neue Freigabe") {
      let lib = ModLibrary(root: try apiTempDir("einstellung"))
      let m = apiManifest(id: "wetter-test", settings: [ModSetting(key: "city", label: "Stadt", kind: .text, defaultValue: "Berlin")])
      _ = try lib.install(m, code: "function run(){ return 1 }")
      _ = try lib.setEnabled("wetter-test", true, now: "2026-10-12T08:00")
      try expectEqual(try lib.isRunnable("wetter-test"), true)
      let info = try lib.setSettingValue("wetter-test", key: "city", value: "Hamburg")
      try expectEqual(info.settingValues, ["city": "Hamburg"])
      try expectEqual(info.approved, true, "Freigabe bleibt")
      try expectEqual(try lib.isRunnable("wetter-test"), true, "weiterhin lauffähig")
      try expectEqual(lib.settingValues("wetter-test"), ["city": "Hamburg"], "Werte bleiben in state.json")
      try expectEqual(try lib.all().first?.settingValues, ["city": "Hamburg"])
    },
    CheckCase("Zeitplan: Minute und Wochentag, höchstens einmal je Minute") {
      let weekdays = ModSchedule(time: "08:00", weekdays: [1, 2, 3, 4, 5])
      let candidates = [(id: "a", schedule: [weekdays])]
      var last: [String: String] = [:]
      func at(_ stamp: String, _ wd: Int) -> [(stamp: String, weekday: Int)] { [(stamp: stamp, weekday: wd)] }
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-12T08:00", 1), lastRun: &last), ["a"], "Montag 08:00")
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-12T08:00", 1), lastRun: &last), [], "zweiter Takt in derselben Minute")
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-12T08:01", 1), lastRun: &last), [], "andere Minute")
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-13T08:00", 2), lastRun: &last), ["a"], "Dienstag 08:00")
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-17T08:00", 6), lastRun: &last), [], "Samstag nicht")
      let daily = [(id: "b", schedule: [ModSchedule(time: "08:00")])]
      try expectEqual(ModScheduleRules.due(daily, minutes: at("2026-10-17T08:00", 6), lastRun: &last), ["b"], "ohne Wochentage jeden Tag")
      try expectEqual(ModScheduleRules.due(daily, minutes: at("2026-10-17T08:00", 6), lastRun: &last), [], "auch hier einmal je Minute")
      try expectEqual(ModScheduleRules.due(candidates, minutes: at("2026-10-19T08:00", 1), lastRun: &last), ["a"], "Montag darauf wieder")
      try expectEqual(ModScheduleRules.matches(ModSchedule(time: "18:30"), time: "18:30", weekday: 7), true)
      try expectEqual(ModScheduleRules.matches(ModSchedule(time: "18:30"), time: "18:31", weekday: 7), false)
    },
    CheckCase("Zeitplan: ein langer Takt verpasst keine Minute (höchstens 5 zurück)") {
      let candidates = [(id: "c", schedule: [ModSchedule(time: "08:02")])]
      var last: [String: String] = [:]
      // Takt lief nach 08:00 und dauerte 2 Minuten und 40 s: 08:01 und 08:02 liegen dazwischen.
      let ticks = ModScheduleRules.minutes(after: "2026-10-12T08:00", until: LocalTime.parse("2026-10-12T08:02:40")!)
      try expectEqual(ticks.map(\.stamp), ["2026-10-12T08:01", "2026-10-12T08:02"], "beide Minuten")
      try expectEqual(ModScheduleRules.due(candidates, minutes: ticks, lastRun: &last), ["c"], "08:02 wird nicht übersehen")
      let far = ModScheduleRules.minutes(after: "2026-10-12T07:00", until: LocalTime.parse("2026-10-12T08:00")!)
      try expectEqual(far.count, 6, "höchstens 5 Minuten zurück, plus die aktuelle")
      try expectEqual(far.first?.stamp, "2026-10-12T07:55", "Untergrenze")
      try expectEqual(ModScheduleRules.minutes(after: nil, until: LocalTime.parse("2026-10-12T08:00")!).map(\.stamp),
                      ["2026-10-12T08:00"], "ohne letzte Minute nur die aktuelle")
    },
    CheckCase("Speicher: gleichzeitige Schreibvorgänge verlieren keinen Wert") {
      let lib = ModLibrary(root: try apiTempDir("speicher-parallel"))
      DispatchQueue.concurrentPerform(iterations: 60) { i in
        try? lib.storageSet("m1", key: "k\(i)", value: .number(Double(i)))
      }
      for i in 0..<60 {
        try expectEqual(try lib.storageGet("m1", key: "k\(i)"), JSONValue.number(Double(i)), "k\(i) fehlt")
      }
    },
    CheckCase("Skript-Zahlen: nicht endlich oder zu groß wird abgelehnt, nicht abgestürzt") {
      for bad in [1e300, Double.infinity, -1e20] {
        do {
          _ = try scriptInt(.number(bad))
          throw fail("\(bad) wurde angenommen")
        } catch let e as ScriptBridgeError {
          try expectEqual(e.message, "Ungültige Zahl.")
        }
      }
      try expectEqual(try scriptInt(.number(12.7)), 12)
      try expectEqual(try scriptInt(nil), nil)
    },
    CheckCase("Einstellungen: input.settings aus dem Modell überschreibt nichts") {
      let forged: JSONValue = .object(["settings": .object(["city": .string("Hack"), "extra": .number(1)])])
      let out = ModSettingRules.withSettings(forged, settings: ["city": .string("Berlin")])
      try expectEqual(out, JSONValue.object(["settings": .object(["city": .string("Berlin")])]))
    },
    CheckCase("Mod-Mail: nur reine Adressen erreichen den Host") {
      let host = ApiFakeHost()
      _ = try? await apiRun(#"async function run(){ await taby.mail.draft({to:"Anna <a@b.de>", subject:"Hi", body:"x"}); return "ok" }"#,
                            perms: ["mail.draft"], host: host)
      try expectEqual(host.calls, [], "Anzeigename wird abgelehnt")
      _ = try await apiRun(#"async function run(){ await taby.mail.draft({to:"anna@example.de", subject:"Hi", body:"x"}); return "ok" }"#,
                           perms: ["mail.draft"], host: host)
      try expectEqual(host.calls, ["mail.draft:anna@example.de"], "gültige Adresse geht durch")
    },
  ]
}

private func apiManifest(id: String = "api-test", settings: [ModSetting]? = nil) -> ModManifest {
  ModManifest(id: id, name: "Test", description: "Test", kind: .script, entry: "main.js",
              triggers: [], permissions: [], settings: settings)
}

private func apiTempDir(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("taby-apicheck-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func apiRun(_ code: String, perms: [String], host: ApiFakeHost, manifest: ModManifest? = nil,
                    settingValues: [String: String] = [:]) async throws -> ScriptRunResult {
  let m = manifest ?? ModManifest(id: "api-test", name: "Test", description: "Test", kind: .script,
                                  entry: "main.js", triggers: [], permissions: perms)
  return try await ScriptModRunner(host: host, session: URLSession(configuration: .ephemeral), timeout: 5)
    .run(code: code, manifest: m, input: .null, settingValues: settingValues)
}

/// Host für die neuen Funktionen: zeichnet jeden Aufruf in `calls` auf.
private final class ApiFakeHost: ModHostAPI, @unchecked Sendable {
  var calls: [String] = []

  func listTasks() async throws -> [TabyTask] { [] }
  func addTask(title: String, due: String?) async throws -> TabyTask { throw ScriptBridgeError("nicht genutzt") }
  func completeTask(id: String) async throws {}
  func listNotes() async throws -> [Note] { [] }
  func addNote(title: String, content: String) async throws -> Note { throw ScriptBridgeError("nicht genutzt") }
  func listEvents(from: String, to: String) async throws -> [CalendarEvent] { [] }
  func notify(_ n: TabyNotification) {}
  func setIslandText(_ text: String, seconds: Double) {}

  func listHabits() async throws -> [Habit] {
    calls.append("habits.list")
    return [Habit(id: "h1", name: "Wasser", createdAt: "2026-10-01T09:00")]
  }
  func checkHabit(id: String) async throws -> Habit {
    calls.append("habits.check:\(id)")
    return Habit(id: id, name: "Wasser", createdAt: "2026-10-01T09:00", checkedToday: true)
  }
  func startFocus(minutes: Int?) async throws { calls.append("focus.start:\(minutes ?? 0)") }
  func stopFocus() async throws { calls.append("focus.stop") }
  func focusIsRunning() async throws -> Bool {
    calls.append("focus.isRunning")
    return false
  }
  func startTimer(minutes: Int, label: String) async throws { calls.append("timer.start:\(minutes):\(label)") }
  func recentMessages(limit: Int) async throws -> [JSONValue] {
    calls.append("messages.recent:\(limit)")
    return []
  }
  func openMailDraft(_ draft: MailDraft) async throws { calls.append("mail.draft:\(draft.to.joined(separator: ","))") }
  func storageGet(key: String) async throws -> JSONValue {
    calls.append("storage.get:\(key)")
    return .null
  }
  func storageSet(key: String, value: JSONValue) async throws { calls.append("storage.set:\(key)") }
}
