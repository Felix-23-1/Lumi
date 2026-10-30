// Abnahme-Prüfungen der Szenarien A–E gegen CoreServices (BAUPLAN 2).
// Grenzen: Modell-HTTP per StubServer (URLProtocol), Benachrichtigung per SinkNotifier,
// Uhr per ControllableClock, Planer-Takt von Hand (`tick()`), Speicher im Arbeitsspeicher.
import CryptoKit
import Foundation

/// Sammelt die Ereignisse, die CoreServices an die Oberfläche meldet.
@MainActor
final class IntegrationEventLog {
  private(set) var events: [AppEvent] = []

  func record(_ event: AppEvent) { events.append(event) }

  var briefings: [Briefing] {
    events.compactMap { event -> Briefing? in
      if case .briefingReady(let b) = event { return b }
      return nil
    }
  }

  var flashes: [TabyNotification] {
    events.compactMap { event -> TabyNotification? in
      if case .flash(let n) = event { return n }
      return nil
    }
  }
}

/// Frisch verdrahteter CoreServices mit steuerbarer Uhr, Speicher im Arbeitsspeicher
/// und optional gestubbtem Modell (jede Antwort der Reihe nach, danach die letzte).
@MainActor
final class IntegrationRig {
  let clock: ControllableClock
  let sink: SinkNotifier
  let log: IntegrationEventLog
  let stub: StubServer?
  let svc: CoreServices

  init(start: String = "2026-10-12T08:00", modelReplies: [StubReply]? = nil) throws {
    let clock = ControllableClock(start)
    let sink = SinkNotifier()
    let stub = modelReplies.map { StubServer($0) }
    let svc = try CoreServices(options: .init(
      databasePath: nil, socketPath: nil, clock: clock,
      keyStore: InMemoryApiKeyStore(), systemNotifier: sink,
      session: stub?.session ?? .shared, plannerInterval: nil))
    let log = IntegrationEventLog()
    svc.subscribe { log.record($0) }
    self.clock = clock
    self.sink = sink
    self.stub = stub
    self.svc = svc
    self.log = log
  }

  /// Hinterlegt Modell-Endpunkt und Schlüssel (nur für Prüfungen mit Stub).
  func configureModel(reminderLeadMinutes: Int? = nil) async {
    guard let stub else { return }
    _ = await svc.updateSettings(
      SettingsPatch(llmBaseUrl: stub.baseUrl, llmModel: "m", reminderLeadMinutes: reminderLeadMinutes, cloudConsentAt: PrivacyChecks.consent(for: stub.baseUrl)),
      apiKey: "sk-integration-test")
  }

  func goTo(_ iso: String) throws {
    clock.set(try expectNotNil(LocalTime.parse(iso), "ungültige Zeit \(iso)"))
  }

  /// Lässt `Task { @MainActor }`-Zustellungen (z. B. `.flash`) durchlaufen.
  func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }
}


/// Apple-Erinnerungen-Attrappe für Abnahme-Prüfungen über CoreServices.
final class IntegrationRemindersBackend: RemindersBackend {
  var items: [ExternalReminder] = []
  private var counter = 0
  func requestAccess() async -> Bool { true }
  func lists() async throws -> [ReminderListInfo] { [ReminderListInfo(id: "L1", title: "Erinnerungen")] }
  func fetchAll(listIds: [String]?) async throws -> [ExternalReminder] { items }
  func create(_ r: ExternalReminder, listId: String?) async throws -> String {
    counter += 1
    var n = r
    n.id = "ext-\(counter)"
    n.listId = listId ?? "L1"
    items.append(n)
    return n.id
  }
  func update(_ r: ExternalReminder) async throws {
    if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r }
  }
  func delete(id: String) async throws { items.removeAll { $0.id == id } }
}


/// Rig mit einer Aufgabe und einem Modell, das genau diese Aufgabe löschen will.
@MainActor
func deleteRig() async throws -> (IntegrationRig, String) {
  // Die ID entsteht erst beim Anlegen; das Modell-Skript liest sie daher aus
  // einer Variable, die vor dem Chat gesetzt wird.
  let box = DeleteTargetBox()
  let r = try IntegrationRig(modelReplies: [
    .dynamic { StubServer.toolCall("delete_task", #"{"id":"\#(box.id)"}"#) },
    StubServer.text("Ich habe das Löschen angefragt."),
  ])
  await r.configureModel()
  guard case .ok(let t) = await r.svc.addTask(title: "Steuer machen", notes: nil, due: nil) else {
    throw fail("Aufgabe nicht angelegt")
  }
  box.id = t.id
  return (r, t.id)
}

final class DeleteTargetBox: @unchecked Sendable { var id = "" }


/// Kurzbefehle-Attrappe: merkt sich Aufrufe, führt nichts Echtes aus.
final class IntegrationShortcuts: ShortcutsRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _runs: [String] = []
  var runs: [String] { lock.lock(); defer { lock.unlock() }; return _runs }
  func list() throws -> [String] { ["Fokus an", "Licht dimmen"] }
  func run(_ name: String, input: String?, timeout: TimeInterval) throws -> String {
    lock.lock(); _runs.append(name); lock.unlock()
    return "ok: \(name)"
  }
}

@MainActor
func modRig(modelReplies: [StubReply]? = nil) throws -> (CoreServices, IntegrationShortcuts, StubServer?) {
  let shortcuts = IntegrationShortcuts()
  let stub = modelReplies.map { StubServer($0) }
  var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                  keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
                                  session: stub?.session ?? .shared, plannerInterval: nil)
  opts.shortcuts = shortcuts
  return (try CoreServices(options: opts), shortcuts, stub)
}


@MainActor
func voiceRig(start: String = "2026-10-12T08:00", voice: Bool = true) async throws -> (CoreServices, SinkSpeaker, ControllableClock) {
  let speaker = SinkSpeaker()
  let clock = ControllableClock(start)
  var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: clock, keyStore: InMemoryApiKeyStore(),
                                  systemNotifier: SinkNotifier(), plannerInterval: nil)
  opts.speaker = speaker
  opts.appleIntelligence = false
  let svc = try CoreServices(options: opts)
  if voice { _ = await svc.updateSettings(SettingsPatch(voiceEnabled: true), apiKey: nil) }
  return (svc, speaker, clock)
}

enum IntegrationChecks {
  static let day = "2026-10-12"
  // list_events: `to` ist exklusiv.
  static let nextDay = "2026-10-13"

  static func isOk(_ result: AddEventResult) -> Bool {
    if case .ok = result { return true }
    return false
  }

  static func event(_ title: String, _ start: String, _ end: String) -> NewEvent {
    NewEvent(title: title, start: start, end: end)
  }

  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration", TaskFolderServiceChecks.cases + TimersUndoSearchChecks.cases + SampleDayChecks.cases + SelfSigningChecks.cases + LoadChecks.cases + FilesChecks.cases
      + ContactsChecks.cases + DiagnosticsChecks.cases + PrivacyChecks.cases + AuditVaultChecks.cases + VaultWriteChecks.cases + SharesChecks.cases
      + ExplainTextChecks.cases + AskTextChecks.cases + NotionStatusSyncChecks.cases + [
      CheckCase("Mod-Trigger: Eingabe trägt Auslöser, Zeit und ISO-Wochentag") {
        let mon = try expectNotNil(LocalTime.parse("2026-01-05T08:00"), "Mo")  // Montag
        try expectEqual(CoreServices.isoWeekday(mon), 1)
        let sun = try expectNotNil(LocalTime.parse("2026-01-11T08:00"), "So")  // Sonntag
        try expectEqual(CoreServices.isoWeekday(sun), 7)
        let input = CoreServices.triggerInput(.hourly, now: mon)
        try expectEqual(input["trigger"]?.stringValue, "hourly")
        try expectEqual(input["now"]?.stringValue, "2026-01-05T08:00")
        try expectEqual(input["weekday"]?.numberValue, 1)
      },
      CheckCase("Mod-Lauf von Hand: fehlende Zeit wird ergänzt, vorhandene bleibt") {
        let t = try expectNotNil(LocalTime.parse("2026-01-05T08:00"), "Mo")
        let manual = CoreServices.withTime(.object([:]), now: t)
        try expectEqual(manual["now"]?.stringValue, "2026-01-05T08:00")
        try expectEqual(manual["weekday"]?.numberValue, 1)
        try expect(manual["trigger"] == nil, "von Hand ohne Auslöser")
        let given = CoreServices.withTime(.object(["now": .string("2026-01-06T08:00")]), now: t)
        try expectEqual(given["now"]?.stringValue, "2026-01-06T08:00")
      },
      CheckCase("Reste: Einträge älter als 24 h gehen, neuere und fremde bleiben") {
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("taby-leftovers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for name in ["taby-capture.alt", "taby-capture.neu", "fremd"] {
          let url = dir.appendingPathComponent(name, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let old = now.addingTimeInterval(-25 * 3600), fresh = now.addingTimeInterval(-23 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("taby-capture.alt").path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent("fremd").path)
        try FileManager.default.setAttributes([.modificationDate: fresh], ofItemAtPath: dir.appendingPathComponent("taby-capture.neu").path)
        let removed = Leftovers.removeOlder(in: dir, now: now, prefix: "taby-capture.")
        try expectEqual(removed, 1, "nur der alte Taby-Eintrag")
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("taby-capture.alt").path), "alt weg")
        try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("taby-capture.neu").path), "neu bleibt")
        try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fremd").path), "fremder Eintrag bleibt")
        try expectEqual(Leftovers.removeOlder(in: dir.appendingPathComponent("gibt-es-nicht"), now: now), 0, "fehlender Ordner ist kein Fehler")
      },
      CheckCase("Mods löschen: ungültige ID wird abgewiesen, bevor Papierkorb-Pfade berührt werden") {
        let root = FileManager.default.temporaryDirectory
          .appendingPathComponent("taby-del-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // „../x“ würde ohne Prüfung genau diesen Ordner neben „Mods“ treffen.
        let victim = root.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "behalten".write(to: victim.appendingPathComponent("datei.txt"), atomically: true, encoding: .utf8)
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                        keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.modsRoot = root.appendingPathComponent("Mods", isDirectory: true)
        let svc = try CoreServices(options: opts)
        let r = await svc.deleteMod("../x")
        try expect(!r.isOk, "ungültige ID abgewiesen")
        try expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("datei.txt").path), "Fremder Ordner bleibt")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Papierkorb-Mods").path), "kein Papierkorb angelegt")
      },
      CheckCase("Bibliothek im echten Kern: Installieren legt den Mod ausgeschaltet an, ohne Dubletten") {
        let root = FileManager.default.temporaryDirectory
          .appendingPathComponent("taby-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                        keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
        opts.modsRoot = root.appendingPathComponent("Mods", isDirectory: true)
        let svc = try CoreServices(options: opts)
        let first = await svc.installCatalogMod("wetter-notch")
        try expect(first.isOk, "erste Installation")
        let second = await svc.installCatalogMod("wetter-notch")
        try expect(second.isOk, "zweite Installation")
        let mods = await svc.state().mods
        try expectEqual(mods.filter { $0.id == "wetter-notch" }.count, 1, "keine Dublette")
        let info = try expectNotNil(mods.first { $0.id == "wetter-notch" }, "Mod da")
        try expect(!info.enabled && !info.approved, "ausgeschaltet und ungeprüft")
        let unknown = await svc.installCatalogMod("gibt-es-nicht")
        try expect(!unknown.isOk && unknown.errorMessage != nil, "unbekannte ID scheitert")
        let after = await svc.state().mods
        try expectEqual(after.count, 1, "unbekannte ID legt nichts an")
      },
      // MARK: Sprache

      CheckCase("Sprache: ohne Einschalten wird nichts gesprochen") {
        let (svc, speaker, _) = try await voiceRig(voice: false)
        await svc.answerDayStart(.yes)
        _ = await svc.state()
        try expectEqual(speaker.spoken, [])
      },

      CheckCase("Sprache: Briefing wird morgens vorgelesen (ohne Modell: Fallback-Text)") {
        let (svc, speaker, _) = try await voiceRig()
        _ = await svc.addTask(title: "Steuer", notes: nil, due: "2026-10-12")
        await svc.answerDayStart(.yes)
        try expectEqual(speaker.spoken.count, 1)
        try expect(speaker.spoken[0].count > 10, speaker.spoken[0])
      },

      CheckCase("Sprache: im Termin und im Fokus schweigt Lumi, danach wieder") {
        let (svc, speaker, clock) = try await voiceRig()
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Team", start: "2026-10-12T08:00", end: "2026-10-12T09:00")))
        await svc.packageFourTick()
        svc.say("Ansage im Termin", briefing: false)
        try expectEqual(speaker.spoken, [], "während des Termins")
        clock.advance(seconds: 3600)  // 09:00: Termin vorbei
        await svc.packageFourTick()
        svc.say("Ansage nach dem Termin", briefing: false)
        try expectEqual(speaker.spoken.count, 1, "nach dem Termin wieder")
        _ = await svc.startFocus(taskId: nil, minutes: 25)
        svc.say("Ansage im Fokus", briefing: false)
        await svc.speakOverview()
        await svc.previewVoice(nil)
        try expectEqual(speaker.spoken.count, 1, "im Fokus still")
        await svc.stopFocus()
        svc.say("Ansage nach dem Fokus", briefing: false)
        try expectEqual(speaker.spoken.count, 2, "nach dem Fokus wieder")
      },

      CheckCase("Sprache: doppelt eingetragene Termine werden genau einmal angesagt") {
        let (svc, speaker, _) = try await voiceRig()
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Zahnarzt", start: "2026-10-12T10:00", end: "2026-10-12T11:00")))
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Meeting", start: "2026-10-12T10:30", end: "2026-10-12T11:30"),
                                               allowConflict: true))
        _ = await svc.state()
        _ = await svc.state()
        let conflicts = speaker.spoken.filter { $0.hasPrefix("Achtung") }
        try expectEqual(conflicts.count, 1, "\(speaker.spoken)")
        try expect(conflicts[0].contains("Zahnarzt") && conflicts[0].contains("Meeting") && conflicts[0].contains("10:00"),
                   conflicts[0])
      },

      CheckCase("Sprache: Erinnerung wird angesagt; mit Ansagen aus nicht") {
        let (svc, speaker, clock) = try await voiceRig()
        _ = await svc.addTask(title: "Zahnarzt anrufen", notes: nil, due: "2026-10-12T08:03")
        clock.set(try expectNotNil(LocalTime.parse("2026-10-12T08:03")))
        _ = await svc.planner.tick()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try expect(speaker.spoken.contains { $0.contains("Zahnarzt anrufen") }, "\(speaker.spoken)")
        let (svc2, speaker2, clock2) = try await voiceRig()
        _ = await svc2.updateSettings(SettingsPatch(voiceAlerts: false), apiKey: nil)
        _ = await svc2.addTask(title: "Still", notes: nil, due: "2026-10-12T08:03")
        clock2.set(try expectNotNil(LocalTime.parse("2026-10-12T08:03")))
        _ = await svc2.planner.tick()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(speaker2.spoken, [])
      },

      CheckCase("Sprache: Abendansage nennt Offenes und den ersten Termin morgen") {
        let (svc, speaker, _) = try await voiceRig(start: "2026-10-12T20:30")
        _ = await svc.addTask(title: "Steuer", notes: nil, due: "2026-10-12")
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Standup", start: "2026-10-13T09:30", end: "2026-10-13T09:45")))
        await svc.speakEvening()
        let text = speaker.spoken.last ?? ""
        try expect(text.contains("Steuer") && text.contains("09:30") && text.contains("Standup"), text)
      },

      CheckCase("Sprache: Texte für Ansagen") {
        try expectEqual(SpeechText.clean("**Heute**\n- Steuer\n- Zahnarzt"), "Heute. Steuer. Zahnarzt")
        try expectEqual(SpeechText.evening(open: [], doneToday: 1, firstTomorrow: nil),
                        "Feierabend! Heute hast du 1 Aufgabe erledigt. Es ist nichts mehr offen.")
      },

      CheckCase("Sprache: Vorlese-Text nennt Termine im Zeitfenster und offene Aufgaben") {
        let ev = { (t: String, s: String) in CalendarEvent(id: t, sourceId: "local", title: t, start: s) }
        let events = [ev("Standup", "2026-10-12T09:30"), ev("Vorbei", "2026-10-12T07:00"),
                      ev("Später", "2026-10-12T11:00"), ev("Nacht", "2026-10-13T00:30"),
                      CalendarEvent(id: "u", sourceId: "local", title: "Urlaub", start: "2026-10-12", allDay: true)]
        let tasks = [TabyTask(id: "1", title: "Steuer", due: "2026-10-10", createdAt: "2026-10-01T08:00"),
                     TabyTask(id: "2", title: "Einkaufen", due: "2026-10-12", createdAt: "2026-10-01T08:00"),
                     TabyTask(id: "3", title: "Fertig", due: "2026-10-12", done: true, createdAt: "2026-10-01T08:00")]
        try expectEqual(SpeechText.readAloud(events: events, tasks: tasks, now: "2026-10-12T09:00", windowMinutes: 60),
                        "In der nächsten Stunde: um 09:30 „Standup“. Überfällig: „Steuer“. Heute offen: „Einkaufen“.")
        try expectEqual(SpeechText.readAloud(events: events, tasks: [], now: "2026-10-12T09:00", windowMinutes: 120),
                        "In den nächsten 2 Stunden hast du 2 Termine: um 09:30 „Standup“ und um 11:00 „Später“. Für heute ist keine Aufgabe offen.")
        try expectEqual(SpeechText.readAloud(events: events, tasks: [], now: "2026-10-12T23:50", windowMinutes: 45),
                        "In den nächsten 45 Minuten: morgen um 00:30 „Nacht“. Für heute ist keine Aufgabe offen.")
        try expectEqual(SpeechText.readAloud(events: [], tasks: [], now: "2026-10-12T09:00", windowMinutes: 30),
                        "In den nächsten 30 Minuten hast du keine Termine. Für heute ist keine Aufgabe offen.")
      },

      CheckCase("Sprache: Vorlesen-Knopf spricht auch bei ausgeschalteten Ansagen, Fenster aus Einstellung") {
        let (svc, speaker, _) = try await voiceRig(start: "2026-10-12T09:00", voice: false)
        _ = await svc.updateSettings(SettingsPatch(readAloudMinutes: 30), apiKey: nil)
        let set30 = await svc.state().settings.readAloudMinutes
        try expectEqual(set30, 30)
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Standup", start: "2026-10-12T09:20", end: "2026-10-12T09:30")))
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Mittag", start: "2026-10-12T12:00", end: "2026-10-12T13:00")))
        await svc.speakOverview()
        let text = speaker.spoken.last ?? ""
        try expect(text.contains("Standup") && !text.contains("Mittag") && text.contains("30 Minuten"), text)
        _ = await svc.updateSettings(SettingsPatch(readAloudMinutes: 99999), apiKey: nil)
        let clamped = await svc.state().settings.readAloudMinutes
        try expectEqual(clamped, 1440)
      },

      // MARK: Paket 3 – Mods

      CheckCase("P3: Vom Modell geschriebener Mod bleibt aus, bis der Nutzer freigibt; dann läuft er") {
        let code = "async function run(input) { const t = await taby.tasks.list(); return 'Aufgaben: ' + t.length }"
        let args = JSONValue.object([
          "id": "aufgaben-zaehler", "name": "Aufgaben-Zähler", "description": "Zählt Aufgaben",
          "code": .string(code), "permissions": ["tasks.read"], "tool_description": "Zählt die Aufgaben",
        ]).jsonString()
        let (svc, _, stub) = try modRig(modelReplies: [
          StubServer.toolCall("create_mod", args), StubServer.text("Mod angelegt."),
        ])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        _ = await svc.addTask(title: "A", notes: nil, due: nil)
        _ = try await svc.chatSend("Bau mir einen Mod, der meine Aufgaben zählt")
        let mods = await svc.state().mods
        try expectEqual(mods.map(\.id), ["aufgaben-zaehler"])
        try expect(!mods[0].enabled && !mods[0].approved, "muss ausgeschaltet ankommen")
        let blocked = await svc.runMod("aufgaben-zaehler", input: nil)
        try expect(!blocked.isOk, "darf ohne Freigabe nicht laufen")
        _ = await svc.setModEnabled("aufgaben-zaehler", true)
        let out = await svc.runMod("aufgaben-zaehler", input: nil)
        try expectEqual(out.value, "Aufgaben: 1")
      },

      CheckCase("P3: Geänderter Mod ist wieder gesperrt") {
        let (svc, _, _) = try modRig()
        let m = ModManifest(id: "echo-mod", name: "Echo", description: "x", kind: .script, entry: "main.js")
        _ = try svc.mods.install(m, code: "function run(i) { return 'eins' }")
        _ = await svc.setModEnabled("echo-mod", true)
        let first = await svc.runMod("echo-mod", input: nil)
        try expectEqual(first.value, "eins")
        _ = try svc.mods.install(m, code: "function run(i) { return 'zwei' }")
        let again = await svc.runMod("echo-mod", input: nil)
        try expect(!again.isOk, "neue Fassung braucht neue Freigabe")
      },

      CheckCase("P3: Mod-Aufruf durch das Modell braucht immer Bestätigung und zeigt Art, Rechte und Eingabe") {
        let (svc, _, stub) = try modRig(modelReplies: [
          StubServer.toolCall("mod_echo_mod", "{\"text\":\"hallo\"}"), StubServer.text("Wartet."),
        ])
        _ = await svc.updateSettings(SettingsPatch(llmBaseUrl: stub!.baseUrl, llmModel: "m", cloudConsentAt: PrivacyChecks.consent(for: stub!.baseUrl)), apiKey: "k")
        let m = ModManifest(id: "echo-mod", name: "Echo", description: "x", kind: .script, entry: "main.js",
                            tool: ModTool(description: "Echo"))
        _ = try svc.mods.install(m, code: "function run(i) { return 'ausgeführt' }")
        _ = await svc.setModEnabled("echo-mod", true)
        _ = try await svc.chatSend("Echo bitte")
        let s = await svc.state()
        try expectEqual(s.pendingConfirmations.count, 1, "Mod ohne Internetrechte muss trotzdem bestätigt werden")
        let summary = s.pendingConfirmations[0].summary
        try expect(summary.contains("„Echo“") && summary.contains("Skript") && summary.contains("Rechte: keine"), summary)
        try expect(summary.contains("hallo"), "Eingabe fehlt auf der Karte: \(summary)")
        let ok = await svc.confirmAction(s.pendingConfirmations[0].id)
        try expect(ok.isOk, "\(String(describing: ok.errorMessage))")
      },

      CheckCase("P3: Kurzbefehl-Mod läuft bei Fokus-Start nur, wenn freigegeben") {
        let (svc, shortcuts, _) = try modRig()
        guard case .ok(let m) = await svc.createShortcutMod(shortcutName: "Fokus an", description: "Nicht stören",
                                                            asTool: false, triggers: [.focusStarted]) else {
          throw fail("nicht angelegt")
        }
        _ = await svc.startFocus(taskId: nil, minutes: 25)
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(shortcuts.runs, [], "ausgeschaltet darf nichts laufen")
        _ = await svc.setModEnabled(m.id, true)
        await svc.stopFocus()
        _ = await svc.startFocus(taskId: nil, minutes: 25)
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        try expectEqual(shortcuts.runs, ["Fokus an"])
      },

      // MARK: Paket 2

      CheckCase("P2: Tagesabschluss – „Alles auf morgen“ verschiebt offene Aufgaben (Uhrzeit bleibt)") {
        let r = try IntegrationRig(start: "2026-10-12T20:30")
        _ = await r.svc.addTask(title: "Steuer", notes: nil, due: "2026-10-12T15:00")
        _ = await r.svc.addTask(title: "Alt", notes: nil, due: "2026-10-10")
        _ = await r.svc.addTask(title: "Später", notes: nil, due: "2026-10-20")
        let before = await r.svc.state()
        try expect(before.dayEndPrompt, "Tagesabschluss sollte nach 20:00 fragen")
        await r.svc.answerDayEnd(.moveAllToTomorrow)
        let s = await r.svc.state()
        let due = Dictionary(uniqueKeysWithValues: s.tasks.map { ($0.title, $0.due ?? "") })
        try expectEqual(due["Steuer"], "2026-10-13T15:00")
        try expectEqual(due["Alt"], "2026-10-13")
        try expectEqual(due["Später"], "2026-10-20")
        try expect(!s.dayEndPrompt, "nach der Antwort nicht erneut fragen")
      },

      CheckCase("P2: Fokus – Start, Ende meldet und startet Pause, Minuten zählen") {
        let r = try IntegrationRig()
        guard case .ok(let f) = await r.svc.startFocus(taskId: nil, minutes: 25) else { throw fail("Fokus") }
        try expectEqual(f.title, "Fokus")
        let running = await r.svc.state().focus
        try expectEqual(running?.id, f.id)
        r.svc.finishFocus(f)
        await r.settle()
        let s = await r.svc.state()
        try expectEqual(s.focus?.phase, .rest, "nach der Arbeit startet die Pause")
        try expectEqual(s.focusMinutesToday, 25)
        try expect(r.sink.sent.contains { $0.title == "Fokus geschafft!" })
        try expect(r.log.events.contains { if case .focusFinished = $0 { return true }; return false })
        await r.svc.stopFocus()
        let stopped = await r.svc.state().focus
        try expect(stopped == nil)
      },

      CheckCase("Fokus mit Aufgabe: Dauer der Aufgabe, spätere Aufgaben rücken nach, Ende fragt statt Pause, „noch Zeit“ schiebt weiter") {
        let r = try IntegrationRig(start: "2026-10-12T09:00")
        guard case .ok(let a) = await r.svc.addTask(title: "Bericht", notes: nil, due: "2026-10-12T09:00"),
              case .ok(let b) = await r.svc.addTask(title: "Anruf", notes: nil, due: "2026-10-12T09:30"),
              case .ok(let c) = await r.svc.addTask(title: "Abend", notes: nil, due: "2026-10-12T17:00") else { throw fail("Aufgaben") }
        _ = await r.svc.updateTask(a.id, TaskPatch(minutes: 45))
        guard case .ok(let f) = await r.svc.startFocus(taskId: a.id, minutes: nil) else { throw fail("Fokus") }
        try expectEqual(f.minutes, 45, "Dauer der Aufgabe statt Standardzeit")
        var tasks = await r.svc.state().tasks
        try expectEqual(tasks.first { $0.id == b.id }?.due, "2026-10-12T09:45", "Anruf rückt hinter den Block")
        try expectEqual(tasks.first { $0.id == c.id }?.due, "2026-10-12T17:00", "Abend bleibt")
        r.svc.finishFocus(f)
        await r.settle()
        let s = await r.svc.state()
        try expect(s.focus == nil, "keine automatische Pause bei offener Aufgabe")
        try expect(r.sink.sent.contains { $0.overrun && $0.taskId == a.id }, "Nachfrage „fertig oder noch?“")
        r.clock.advance(seconds: 45 * 60)
        guard case .ok(let g) = await r.svc.startFocus(taskId: a.id, minutes: 30) else { throw fail("Verlängern") }
        try expectEqual(g.minutes, 30)
        tasks = await r.svc.state().tasks
        try expectEqual(tasks.first { $0.id == b.id }?.due, "2026-10-12T10:15", "Anruf rückt um die neue Zeit weiter")
      },

      CheckCase("Pause: beendet den Fokus, startet die Pausen-Sitzung und schiebt spätere Aufgaben um die Pause") {
        let r = try IntegrationRig(start: "2026-10-12T09:00")
        guard case .ok(let a) = await r.svc.addTask(title: "Anruf", notes: nil, due: "2026-10-12T09:10"),
              case .ok(let b) = await r.svc.addTask(title: "Abend", notes: nil, due: "2026-10-12T17:00") else { throw fail("Aufgaben") }
        guard case .ok(let f) = await r.svc.startBreak(minutes: 20) else { throw fail("Pause") }
        try expectEqual(f.phase, .rest)
        try expectEqual(f.minutes, 20)
        let s = await r.svc.state()
        try expectEqual(s.focus?.id, f.id)
        try expectEqual(s.tasks.first { $0.id == a.id }?.due, "2026-10-12T09:20", "Anruf rückt hinter die Pause")
        try expectEqual(s.tasks.first { $0.id == b.id }?.due, "2026-10-12T17:00")
      },

      CheckCase("Fokus anhalten: Countdown steht, Weiterlaufen verschiebt das Ende um die Pause und die Aufgaben nach") {
        let r = try IntegrationRig(start: "2026-10-12T09:00")
        guard case .ok(let a) = await r.svc.addTask(title: "Bericht", notes: nil, due: nil),
              case .ok(let b) = await r.svc.addTask(title: "Anruf", notes: nil, due: "2026-10-12T09:40") else { throw fail("Aufgaben") }
        guard case .ok(let f) = await r.svc.startFocus(taskId: a.id, minutes: 30) else { throw fail("Fokus") }
        try expectEqual(f.endsAt, "2026-10-12T09:30:00")
        r.clock.advance(seconds: 10 * 60)
        await r.svc.pauseFocus()
        var s = await r.svc.state()
        try expectEqual(s.focus?.pausedAt, "2026-10-12T09:10:00")
        r.clock.advance(seconds: 15 * 60)
        await r.svc.resumeFocus()
        s = await r.svc.state()
        try expect(s.focus?.pausedAt == nil, "läuft wieder")
        try expectEqual(s.focus?.endsAt, "2026-10-12T09:45:00", "Ende um 15 Min Pause nach hinten")
        try expectEqual(s.tasks.first { $0.id == b.id }?.due, "2026-10-12T09:45", "Anruf rückt hinter das neue Ende")
        await r.svc.pauseFocus(); await r.svc.pauseFocus()
        let again = await r.svc.state().focus
        try expectEqual(again?.pausedAt, "2026-10-12T09:25:00", "doppeltes Anhalten ändert die Zeit nicht")
      },

      CheckCase("Aufgaben-Stand: Patch und Werkzeug setzen offen / in Bearbeitung / Info fehlt, ungültig wird abgelehnt") {
        let r = try IntegrationRig()
        guard case .ok(let t) = await r.svc.addTask(title: "Angebot", notes: nil, due: nil) else { throw fail("Aufgabe") }
        try expectEqual(t.status, .open)
        var u = await r.svc.updateTask(t.id, TaskPatch(status: "inProgress"))
        try expectEqual(u.value?.status, .inProgress)
        u = await r.svc.updateTask(t.id, TaskPatch(title: "Angebot 2"))
        try expectEqual(u.value?.status, .inProgress, "nil lässt den Stand")
        u = await r.svc.updateTask(t.id, TaskPatch(status: "needsInfo"))
        try expectEqual(u.value?.status, .needsInfo)
        u = await r.svc.updateTask(t.id, TaskPatch(status: ""))
        try expectEqual(u.value?.status, .open, "\"\" = offen")
        let bad = await r.svc.tool("update_task", ["id": .string(t.id), "status": .string("unfug")])
        guard case .object(let o) = bad, o["ok"] == .bool(false) else { throw fail("ungültiger Stand muss scheitern") }
      },

      CheckCase("P2: Gedächtnis landet im Prompt; Vergessen durch das Modell braucht Bestätigung") {
        let box = DeleteTargetBox()
        let r = try IntegrationRig(modelReplies: [
          .dynamic { StubServer.toolCall("forget_fact", #"{"id":"\#(box.id)"}"#) },
          StubServer.text("Angefragt."),
        ])
        await r.configureModel()
        guard case .ok(let m) = await r.svc.addMemory("Zahnarzt ist Dr. Weber") else { throw fail("Fakt") }
        box.id = m.id
        _ = try await r.svc.chatSend("Vergiss den Zahnarzt")
        let firstBody = r.stub?.requests.first?.body?.jsonString() ?? ""
        try expect(firstBody.contains("Zahnarzt ist Dr. Weber"), "Fakt fehlt im Prompt")
        let s = await r.svc.state()
        try expectEqual(s.memories.map(\.text), ["Zahnarzt ist Dr. Weber"], "darf ohne Bestätigung nicht vergessen werden")
        try expectEqual(s.pendingConfirmations.first?.tool, "forget_fact")
      },

      CheckCase("P2: MCP-Host – kein Löschen freigegeben, Anlegen wirkt") {
        let r = try IntegrationRig()
        let host = TabyMCPHost(store: r.svc.store, clock: r.clock,
                               calendar: { ProviderCalendarAccess.localOnly(r.svc.store) }, onMutation: {})
        let names = Set(host.tools().map(\.name))
        try expect(!names.contains { $0.hasPrefix("delete_") || $0 == "forget_fact" || $0 == "cancel_job" || $0 == "schedule_job" },
                   "\(names)")
        let denied = await host.call(name: "delete_task", arguments: ["id": "x"])
        try expect(denied.isError)
        let added = await host.call(name: "add_task", arguments: ["title": "Von Hermes"])
        try expect(!added.isError, added.text)
        let titles = await r.svc.state().tasks.map(\.title)
        try expectEqual(titles, ["Von Hermes"])
      },

      CheckCase("P2: Markdown-Export schreibt Notizen und Aufgaben") {
        let r = try IntegrationRig()
        _ = await r.svc.addNote(title: "Ideen", content: "Fokus-Timer")
        _ = await r.svc.addTask(title: "Export testen", notes: nil, due: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = await r.svc.exportMarkdown(to: dir.path)
        guard case .ok(let out) = res else { throw fail("Export: \(String(describing: res.errorMessage))") }
        try expect(out.files >= 2)
        let note = try String(contentsOf: dir.appendingPathComponent("Lumi/Notizen/Ideen.md"), encoding: .utf8)
        try expect(note.contains("Fokus-Timer"))
        let tasks = try String(contentsOf: dir.appendingPathComponent("Lumi/Aufgaben.md"), encoding: .utf8)
        try expect(tasks.contains("- [ ] Export testen"), tasks)
      },

      // MARK: Sicherheit – Löschen durch das Modell nur nach Bestätigung

      CheckCase("Sicherheit: Modell kann nicht ohne Bestätigung löschen; Bestätigen löscht") {
        let (r, taskId) = try await deleteRig()
        _ = try await r.svc.chatSend("Lösch die Steuer-Aufgabe")
        await r.settle()
        let s1 = await r.svc.state()
        try expectEqual(s1.tasks.map(\.id), [taskId], "Aufgabe darf ohne Bestätigung nicht gelöscht sein")
        try expectEqual(s1.pendingConfirmations.count, 1)
        let pc = s1.pendingConfirmations[0]
        try expect(pc.summary.contains("Steuer machen"), pc.summary)
        try expect(r.log.events.contains { if case .confirmationRequested = $0 { return true }; return false },
                   "Insel muss benachrichtigt werden")
        // Das Modell bekam "wartet auf Bestätigung" als Werkzeug-Ergebnis.
        try expect(s1.messages.contains { $0.role == .tool && ($0.content ?? "").contains("NEEDS_CONFIRMATION") })
        let ok = await r.svc.confirmAction(pc.id)
        try expect(ok.isOk, "\(String(describing: ok.errorMessage))")
        let s2 = await r.svc.state()
        try expectEqual(s2.tasks.count, 0)
        try expectEqual(s2.pendingConfirmations.count, 0)
      },

      CheckCase("Sicherheit: delete_event und move_event aus dem Chat warten auf Bestätigung") {
        let box = DeleteTargetBox()
        let r = try IntegrationRig(modelReplies: [
          .dynamic { StubServer.toolCall("delete_event", #"{"id":"\#(box.id)","source_id":"local"}"#) },
          .dynamic { StubServer.toolCall("move_event", #"{"id":"\#(box.id)","source_id":"local","start":"2026-10-14T15:00"}"#) },
          StubServer.text("Bitte bestätigen."),
        ])
        await r.configureModel()
        let added = await r.svc.addEvent(AddEventRequest(event: NewEvent(title: "Zahnarzt", start: "2026-10-13T10:00",
                                                                        end: "2026-10-13T11:00")))
        guard case .ok(let ev, _, _) = added else { throw fail("Termin nicht angelegt") }
        box.id = ev.id
        _ = try await r.svc.chatSend("Lösch den Zahnarzt-Termin")
        await r.settle()
        let s1 = await r.svc.state()
        let summaries = s1.pendingConfirmations.map(\.summary)
        try expectEqual(summaries, ["Termin „Zahnarzt“ löschen", "Termin „Zahnarzt“ verschieben auf 2026-10-14 15:00"])
        let still = await r.svc.listEvents(from: "2026-10-13", to: "2026-10-15")
        try expectEqual(still.map(\.start), ["2026-10-13T10:00"], "nichts darf ohne Bestätigung passieren")
        let moved = await r.svc.confirmAction(s1.pendingConfirmations[1].id)
        try expect(moved.isOk, "\(String(describing: moved.errorMessage))")
        let after = await r.svc.listEvents(from: "2026-10-13", to: "2026-10-15")
        try expectEqual(after.map(\.start), ["2026-10-14T15:00"])
        try expectEqual(after.map(\.end), ["2026-10-14T16:00"], "Dauer bleibt")
      },

      CheckCase("Sicherheit: Ablehnen behält die Aufgabe; Klick-Löschen in der Oberfläche bleibt sofort") {
        let (r, taskId) = try await deleteRig()
        _ = try await r.svc.chatSend("Lösch die Steuer-Aufgabe")
        let firstPending = await r.svc.state().pendingConfirmations.first
        let pc = try expectNotNil(firstPending)
        await r.svc.rejectAction(pc.id)
        let s = await r.svc.state()
        try expectEqual(s.tasks.map(\.id), [taskId])
        try expectEqual(s.pendingConfirmations.count, 0)
        let del = await r.svc.deleteTask(taskId)
        try expect(del.isOk)
        let after = await r.svc.state().tasks.count
        try expectEqual(after, 0)
      },

      // MARK: Paket 1 – Verbrauch/Limit, Apple Erinnerungen

      CheckCase("P1: Verbrauch aus der Modell-Antwort wird gezählt") {
        let reply = StubReply.json(status: 200, body: #"{"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"Hallo"}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"cost":0.0123}}"#)
        let r = try IntegrationRig(modelReplies: [reply])
        await r.configureModel()
        _ = try await r.svc.chatSend("Hi")
        let usage = await r.svc.state().usage
        try expectEqual(usage.todayTokens, 120)
        try expect(abs(usage.todayUsd - 0.0123) < 0.000_001, "Kosten: \(usage.todayUsd)")
      },

      CheckCase("P1: über dem Tageslimit ruft der Chat das Modell nicht mehr") {
        let reply = StubReply.json(status: 200, body: #"{"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"Hallo"}}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cost":0.5}}"#)
        let r = try IntegrationRig(modelReplies: [reply])
        await r.configureModel()
        _ = await r.svc.updateSettings(SettingsPatch(dailyCostLimitUsd: 0.4), apiKey: nil)
        _ = try await r.svc.chatSend("Erste Frage")
        let reached = await r.svc.state().usage.limitReached
        try expect(reached, "Limit sollte erreicht sein")
        let callsBefore = r.stub?.requests.count ?? 0
        do {
          _ = try await r.svc.chatSend("Zweite Frage")
          throw fail("sollte wegen Limit werfen")
        } catch let e as LlmError {
          try expectEqual(e.code, .quota)
        }
        try expectEqual(r.stub?.requests.count ?? 0, callsBefore, "Modell darf nicht gerufen werden")
      },

      CheckCase("P1: Apple Erinnerungen werden über den Kern in beide Richtungen abgeglichen") {
        let backend = IntegrationRemindersBackend()
        backend.items = [ExternalReminder(id: "a1", title: "Paket abholen", due: "2026-10-12", listId: "L1")]
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                        keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
                                        plannerInterval: nil)
        opts.remindersBackend = backend
        let svc = try CoreServices(options: opts)
        _ = await svc.addTask(title: "Steuer machen", notes: nil, due: nil)
        _ = await svc.updateSettings(SettingsPatch(appleRemindersSync: true), apiKey: nil)
        let result = await svc.syncAppleReminders()
        try expect(result.isOk, "Abgleich: \(String(describing: result.errorMessage))")
        let titles = await svc.state().tasks.map(\.title).sorted()
        try expectEqual(titles, ["Paket abholen", "Steuer machen"])
        try expectEqual(backend.items.map(\.title).sorted(), ["Paket abholen", "Steuer machen"])
        // Zweiter Lauf ändert nichts (keine Duplikate).
        _ = await svc.syncAppleReminders()
        let count = await svc.state().tasks.count
        try expectEqual(count, 2)
        try expectEqual(backend.items.count, 2)
      },


      // MARK: A – Terminkonflikt

      CheckCase("A: überlappender Termin wird nicht gespeichert, Antwort nennt Titel und Zeit des Konflikts") {
        let r = try IntegrationRig()
        let first = await r.svc.addEvent(AddEventRequest(event: event("Zahnarzt", "2026-10-12T10:00", "2026-10-12T11:00")))
        try expect(isOk(first), "Ausgangstermin nicht angelegt: \(first)")
        let before = await r.svc.listEvents(from: day, to: nextDay)
        try expectEqual(before.map(\.title), ["Zahnarzt"])

        let result = await r.svc.addEvent(AddEventRequest(event: event("Kundentermin", "2026-10-12T10:30", "2026-10-12T11:30")))
        guard case .conflict(_, let conflicts) = result else {
          throw fail("erwartet .conflict, war \(result)")
        }
        try expectEqual(conflicts.map { $0.with.title }, ["Zahnarzt"])
        try expectEqual(conflicts.first?.with.start, "2026-10-12T10:00")

        let after = await r.svc.listEvents(from: day, to: nextDay)
        try expectEqual(after, before, "Konflikt-Termin darf nicht gespeichert werden")
      },

      CheckCase("A: mit allowConflict (\"trotzdem eintragen\") wird der Termin gespeichert") {
        let r = try IntegrationRig()
        _ = await r.svc.addEvent(AddEventRequest(event: event("Zahnarzt", "2026-10-12T10:00", "2026-10-12T11:00")))
        let forced = await r.svc.addEvent(AddEventRequest(
          event: event("Kundentermin", "2026-10-12T10:30", "2026-10-12T11:30"), allowConflict: true))
        try expect(isOk(forced), "mit allowConflict nicht gespeichert: \(forced)")
        let saved = await r.svc.listEvents(from: day, to: nextDay)
        try expectEqual(saved.map(\.title).sorted(), ["Kundentermin", "Zahnarzt"])
      },

      CheckCase("A: nicht überlappender Termin direkt nach dem ersten wird ohne Rückfrage gespeichert") {
        let r = try IntegrationRig()
        _ = await r.svc.addEvent(AddEventRequest(event: event("Zahnarzt", "2026-10-12T10:00", "2026-10-12T11:00")))
        let next = await r.svc.addEvent(AddEventRequest(event: event("Mittag", "2026-10-12T11:00", "2026-10-12T12:00")))
        try expect(isOk(next), "Terminen ohne Überschneidung abgelehnt: \(next)")
      },

      // MARK: B – Tagesstart

      CheckCase("B: erster state() des Tages fragt, nach Ja nicht mehr am selben Tag") {
        let r = try IntegrationRig()
        let first = await r.svc.state()
        try expectEqual(first.dayStartPrompt, true, "erster Start des Tages muss fragen")
        await r.svc.answerDayStart(.yes)
        let second = await r.svc.state()
        try expectEqual(second.dayStartPrompt, false, "nach Ja nicht erneut fragen")
      },

      CheckCase("B: Ja liefert ein Briefing ohne Modell mit Terminen, überfälligen Aufgaben und Konflikten") {
        let r = try IntegrationRig()
        _ = await r.svc.addEvent(AddEventRequest(event: event("Zahnarzt", "2026-10-12T10:00", "2026-10-12T11:00")))
        _ = await r.svc.addTask(title: "Steuer abgeben", notes: nil, due: "2026-10-10")
        _ = await r.svc.state()
        await r.svc.answerDayStart(.yes)
        await r.settle()

        try expectEqual(r.log.briefings.count, 1, "genau ein .briefingReady erwartet")
        let briefing = try expectNotNil(r.log.briefings.first)
        try expect(!briefing.generatedByModel, "ohne Modell muss der Fallback greifen")
        try expect(!briefing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Fallback-Text leer")
        try expect(briefing.text.contains("Zahnarzt"), "Termin fehlt im Briefing: \(briefing.text)")
        try expect(briefing.text.contains("Steuer abgeben"), "überfällige Aufgabe fehlt im Briefing: \(briefing.text)")
        try expectEqual(briefing.overview.overdueTasks.map(\.title), ["Steuer abgeben"])
      },

      CheckCase("B: Später fragt erst nach 30 Minuten erneut") {
        let r = try IntegrationRig()
        _ = await r.svc.state()
        await r.svc.answerDayStart(.later)
        r.clock.advance(seconds: 29 * 60)
        let early = await r.svc.state()
        try expectEqual(early.dayStartPrompt, false, "nach 29 Min noch nicht erneut fragen")
        r.clock.advance(seconds: 60)
        let due = await r.svc.state()
        try expectEqual(due.dayStartPrompt, true, "nach 30 Min erneut fragen")
      },

      CheckCase("B: Heute nicht fragt am selben Tag nicht mehr, am nächsten Tag wieder") {
        let r = try IntegrationRig()
        _ = await r.svc.state()
        await r.svc.answerDayStart(.skip)
        r.clock.advance(seconds: 3 * 3600)
        let sameDay = await r.svc.state()
        try expectEqual(sameDay.dayStartPrompt, false, "Heute nicht: am selben Tag nicht fragen")
        try r.goTo("2026-10-13T08:00")
        let laterDay = await r.svc.state()
        try expectEqual(laterDay.dayStartPrompt, true, "am nächsten Tag wieder fragen")
      },

      CheckCase("B: nach Ja am Tag wird am nächsten Tag wieder gefragt") {
        let r = try IntegrationRig()
        _ = await r.svc.state()
        await r.svc.answerDayStart(.yes)
        try r.goTo("2026-10-13T08:00")
        let laterDay = await r.svc.state()
        try expectEqual(laterDay.dayStartPrompt, true, "neuer Tag muss wieder fragen")
      },

      // MARK: C – Auslösen zur Uhrzeit

      CheckCase("C: Aufgabe mit Uhrzeit löst genau einmal über mehrere Takte aus, plus .flash") {
        let r = try IntegrationRig()
        _ = await r.svc.addTask(title: "Anruf Bank", notes: nil, due: "2026-10-12T08:03")
        _ = await r.svc.planner.tick()
        try expectEqual(r.sink.sent.count, 0, "vor Fälligkeit keine Benachrichtigung")

        try r.goTo("2026-10-12T08:02:30")
        _ = await r.svc.planner.tick()
        try expectEqual(r.sink.sent.count, 0, "21 s vor Fälligkeit keine Benachrichtigung")

        try r.goTo("2026-10-12T08:03:00")
        let firstReport = await r.svc.planner.tick()
        try expectEqual(firstReport.fired.count, 1, "zur Uhrzeit muss genau ausgelöst werden")
        try expectEqual(r.sink.sent.count, 1)

        for later in ["2026-10-12T08:03:30", "2026-10-12T08:04:00", "2026-10-12T08:08:00"] {
          try r.goTo(later)
          let report = await r.svc.planner.tick()
          try expectEqual(report.fired.count, 0, "bereits ausgelöst, nicht erneut (\(later))")
        }
        // Aufgaben-Erinnerung trägt die Aufgaben-Id (Knöpfe „Erledigt“ / „In 10 Min“).
        try expectEqual(r.sink.sent.map { [$0.title, $0.body] }, [["Erinnerung", "Anruf Bank"]])
        try expect(r.sink.sent.first?.taskId != nil, "Aufgaben-Erinnerung braucht taskId")

        await r.settle()
        try expectEqual(r.log.flashes.map { [$0.title, $0.body] }, [["Erinnerung", "Anruf Bank"]],
                        "die Insel soll genau einmal aufpoppen")
      },

      CheckCase("C: Termin mit Uhrzeit löst zum Vorlauf (Standard 10 Min) aus, Text nennt den Termin") {
        let r = try IntegrationRig()
        await r.configureModel(reminderLeadMinutes: 10)
        _ = await r.svc.addEvent(AddEventRequest(event: event("Zahnarzt", "2026-10-12T10:00", "2026-10-12T11:00")))
        _ = await r.svc.planner.tick()
        try r.goTo("2026-10-12T09:49")
        _ = await r.svc.planner.tick()
        try expectEqual(r.sink.sent.count, 0, "vor dem Vorlauf keine Benachrichtigung")
        try r.goTo("2026-10-12T09:50")
        _ = await r.svc.planner.tick()
        try expectEqual(r.sink.sent, [TabyNotification(title: "Termin bald", body: "Zahnarzt um 10:00 – in 10 Minuten")])
      },

      // MARK: D – Wiederkehrender Auftrag per Chat

      CheckCase("D: Chat legt Auftrag an; Planer führt ihn zur Zeit aus; Ergebnis als Benachrichtigung und im Chat") {
        let args = #"{"name":"Müll raustragen","prompt":"Erinnere an den Müll.","rule":{"type":"weekly","days":[1],"time":"08:00"}}"#
        let r = try IntegrationRig(start: "2026-10-11T20:00", modelReplies: [
          StubServer.toolCall("schedule_job", args),
          StubServer.text("Auftrag eingerichtet."),
          StubServer.text("Müll ist draußen."),
        ])
        await r.configureModel()

        let reply = try await r.svc.chatSend("erinnere mich jeden Montag um 8 an den Müll")
        try expectEqual(reply.last?.content, "Auftrag eingerichtet.")
        let jobs = await r.svc.state().jobs
        try expectEqual(jobs.map(\.name), ["Müll raustragen"])
        try expectEqual(jobs.first?.rule, JobRule.weekly(days: [1], time: "08:00"))

        // Sonntag 20:00: noch nicht fällig.
        let early = await r.svc.planner.tick()
        try expectEqual(early.jobRuns.count, 0, "vor der Zeit darf nichts laufen")

        try r.goTo("2026-10-12T08:00")
        let due = await r.svc.planner.tick()
        try expectEqual(due.jobRuns.count, 1, "Auftrag muss zur Zeit genau einmal laufen")
        try expectEqual(due.jobRuns.first?.output, "Müll ist draußen.")
        try expectEqual(r.sink.sent, [TabyNotification(title: "Müll raustragen", body: "Müll ist draußen.")])

        let messages = await r.svc.state().messages
        try expect(messages.contains { $0.content == "Müll ist draußen." },
                   "Ergebnis des Auftrags fehlt im Chatverlauf")

        try r.goTo("2026-10-12T08:01")
        _ = await r.svc.planner.tick()
        try expectEqual(r.sink.sent.count, 1, "Auslösen ist idempotent: keine zweite Benachrichtigung")
      },

      // MARK: E – Nachholen nach Ruhezustand

      CheckCase("E: verpasste Erinnerungen erscheinen einmal unter Verpasst, ohne Benachrichtigungsflut") {
        let r = try IntegrationRig()
        _ = await r.svc.addTask(title: "Steuer", notes: nil, due: "2026-10-12T09:00")
        _ = await r.svc.addTask(title: "Post", notes: nil, due: "2026-10-12T09:30")
        _ = await r.svc.addTask(title: "Müll", notes: nil, due: "2026-10-12T10:00")
        _ = await r.svc.planner.tick()

        // Mac war aus: die Uhr springt ohne Takt viele Stunden vor.
        try r.goTo("2026-10-12T15:00")
        let report = await r.svc.planner.tick()
        try expectEqual(report.fired.count, 0, "Verpasstes darf nicht als fällig ausgelöst werden")
        try expectEqual(r.sink.sent.count, 0, "keine Benachrichtigungsflut für verpasste Erinnerungen")

        let overview = await r.svc.state().overview
        try expectEqual(overview.missed.map(\.title).sorted(), ["Müll", "Post", "Steuer"])

        r.clock.advance(seconds: 30)
        _ = await r.svc.planner.tick()
        _ = await r.svc.planner.tick()
        let again = await r.svc.state().overview
        try expectEqual(again.missed.count, 3, "Verpasstes bleibt genau einmal gelistet")
        try expectEqual(r.sink.sent.count, 0)
      },

      CheckCase("E: bestätigtes Verpasstes verschwindet aus der Liste und kommt nicht zurück") {
        let r = try IntegrationRig()
        _ = await r.svc.addTask(title: "Steuer", notes: nil, due: "2026-10-12T09:00")
        _ = await r.svc.addTask(title: "Post", notes: nil, due: "2026-10-12T09:30")
        _ = await r.svc.planner.tick()
        try r.goTo("2026-10-12T15:00")
        _ = await r.svc.planner.tick()

        let missed = await r.svc.state().overview.missed
        try expectEqual(missed.count, 2)
        let steuer = try expectNotNil(missed.first { $0.title == "Steuer" }).id
        await r.svc.acknowledgeMissed([steuer])
        let afterOne = await r.svc.state().overview.missed.map(\.title)
        try expectEqual(afterOne, ["Post"])

        _ = await r.svc.planner.tick()
        let afterTick = await r.svc.state().overview.missed.map(\.title)
        try expectEqual(afterTick, ["Post"], "bestätigt darf nach einem Takt nicht zurückkommen")

        await r.svc.acknowledgeMissed([])
        let cleared = await r.svc.state().overview.missed
        try expectEqual(cleared.count, 0, "leere Liste bestätigt alles Verpasste")
        try expectEqual(r.sink.sent.count, 0)
      },

      CheckCase("E: fälliger geplanter Auftrag nach dem Ruhezustand läuft einmal nach") {
        let r = try IntegrationRig(start: "2026-10-11T20:00", modelReplies: [StubServer.text("Nachgeholt.")])
        await r.configureModel()
        _ = await r.svc.scheduleJob(ScheduleJobRequest(
          name: "Wochenrückblick", prompt: "Rückblick.", rule: .weekly(days: [1], time: "08:00")))

        try r.goTo("2026-10-12T15:00")
        let report = await r.svc.planner.tick()
        try expectEqual(report.jobRuns.count, 1, "verpasster Auftrag läuft einmal nach")
        try expectEqual(report.jobRuns.first?.output, "Nachgeholt.")
        try expectEqual(r.sink.sent.count, 1)

        let again = await r.svc.planner.tick()
        try expectEqual(again.jobRuns.count, 0, "nicht ein zweites Mal nachholen")
        try expectEqual(r.sink.sent.count, 1)
      },
    ] + AppUpdateChecks.cases + AppUpdateNoticeChecks.cases + QuickCaptureChecks.cases + MediaAndBackupsChecks.cases + MusicLocalChecks.cases + LyricsChecks.cases + InboxChecks.cases + CaptureChecks.cases + SettingsSaveChecks.cases)
  }
}

/// Selbst-Update: Adressen, Prüfung gegen einen Stub, Benachrichtigung, Austausch-Skript.
enum AppUpdateChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Update-Adresse: GitHub-Repo, Ordner und Fehler") {
        try expectEqual(try CoreServices.updateBase(""), "https://raw.githubusercontent.com/Felix-23-1/Lumi/main/download/")
        try expectEqual(try CoreServices.updateBase("https://github.com/a/b.git/"),
                        "https://raw.githubusercontent.com/a/b/main/download/")
        try expectEqual(try CoreServices.updateBase("https://example.com/taby"), "https://example.com/taby/")
        try expectEqual(try CoreServices.updateBase(" https://example.com/taby/ "), "https://example.com/taby/")
        var message: String?
        do { _ = try CoreServices.updateBase("http://example.com/taby") } catch let f as UpdateFailure { message = f.message }
        try expectEqual(message, "Die Update-Adresse muss mit https:// beginnen.")
      },
      CheckCase("Update-Prüfung: höherer Build neu, gleich oder niedriger nil, fehlender Build nil, 404 auf Deutsch") {
        let same = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"abc1234","build":5,"date":"2026-10-14T10:00"}"#)])
        let sameResult = await same.svc.checkForUpdate()
        try expectEqual(sameResult, .ok(nil))
        try expectEqual(same.stub.requests.first?.url.absoluteString, "https://\(same.stub.host)/taby/version.json")

        let lower = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"old0001","build":4,"date":"2026-10-14T10:00"}"#)])
        let lowerResult = await lower.svc.checkForUpdate()
        try expectEqual(lowerResult, .ok(nil))

        let unversioned = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"def5678","date":"2026-10-14T10:00"}"#)])
        let unversionedResult = await unversioned.svc.checkForUpdate()
        try expectEqual(unversionedResult, .ok(nil))

        let newer = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00"}"#)])
        let expected = AppUpdate(commit: "def5678", date: "2026-10-14T10:00", currentCommit: "abc1234", build: 6, currentBuild: 5)
        let newerResult = await newer.svc.checkForUpdate()
        try expectEqual(newerResult, .ok(expected))
        let state = await newer.svc.state()
        try expectEqual(state.update, expected)

        let missing = try await AppUpdateRig.make(replies: [.json(status: 404, body: "")])
        let missingResult = await missing.svc.checkForUpdate()
        try expectEqual(missingResult.errorMessage, "Unter der Update-Adresse liegt keine Lumi-Version.")
      },
      CheckCase("Update-Prüfung: Entwickler-Build ohne Build-Nummer fragt nicht nach") {
        let rig = try await AppUpdateRig.make(build: 0, replies: [])
        let result = await rig.svc.checkForUpdate()
        try expectEqual(result, .ok(nil))
        try expectEqual(rig.stub.requests.count, 0)
      },
      CheckCase("Update-Benachrichtigung kommt pro Version nur einmal, auch nach dem Neustart") {
        let defaults = UserDefaults(suiteName: "taby-update-check-\(UUID().uuidString)")!
        let reply = StubReply.json(status: 200, body: #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00"}"#)
        let rig = try await AppUpdateRig.make(replies: [reply, reply], defaults: defaults)
        await rig.svc.quietUpdateCheck()
        await rig.svc.quietUpdateCheck()
        try expectEqual(rig.sink.sent.map(\.title), ["Lumi-Update verfügbar"])
        let restarted = try await AppUpdateRig.make(replies: [reply], defaults: defaults)
        await restarted.svc.quietUpdateCheck()
        try expectEqual(restarted.sink.sent.map(\.title), [])
      },
      CheckCase("Update-Signatur: gültig nur mit Schlüssel, SHA und Signatur; sonst abgelehnt") {
        let owner = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let pub = owner.publicKey.rawRepresentation.base64EncodedString()
        let dmg = Data("fake dmg".utf8)
        let sha = UpdateSignature.sha256Hex(dmg)
        func signed(build: Int, sha: String, key: Curve25519.Signing.PrivateKey) throws -> UpdateVersion {
          let msg = UpdateSignature.message(build: build, commit: "def5678", sha256: sha)
          let sig = try key.signature(for: msg).base64EncodedString()
          let json = #"{"commit":"def5678","build":\#(build),"date":"2026-10-14T10:00","sha256":"\#(sha)","signature":"\#(sig)"}"#
          return try JSONDecoder().decode(UpdateVersion.self, from: Data(json.utf8))
        }
        /// true, wenn die Prüfung das Update ablehnt (mit dem Standardtext).
        func refused(_ info: UpdateVersion, _ data: Data = dmg, current: Int = 5, key: String = pub) -> Bool {
          do { try UpdateSignature.check(info, dmg: data, currentBuild: current, publicKey: key); return false } catch let f as UpdateFailure {
            return f.message == UpdateSignature.refusal || f.message.hasPrefix("Das Update ist nicht neuer")
          } catch { return false }
        }
        let good = try signed(build: 6, sha: sha, key: owner)
        try expect(!refused(good), "gültig signiertes Update wird angenommen")
        try expect(refused(good, Data("other dmg".utf8)), "veränderte DMG wird abgelehnt")
        try expect(refused(try signed(build: 6, sha: sha, key: other)), "fremder Schlüssel wird abgelehnt")
        try expect(refused(try signed(build: 6, sha: UpdateSignature.sha256Hex(Data("x".utf8)), key: owner)), "falsche SHA wird abgelehnt")
        let unsigned = try JSONDecoder().decode(UpdateVersion.self, from: Data(#"{"commit":"def5678","build":6,"date":"x"}"#.utf8))
        try expect(refused(unsigned), "fehlende Signatur wird abgelehnt")
        try expect(refused(good, current: 6), "Replay einer gleichen oder älteren Version wird abgelehnt")
        try expect(refused(good, key: CoreServices.updatePublicKey), "Platzhalter-Schlüssel lehnt alles ab")
        var message = ""
        do { try UpdateSignature.check(unsigned, dmg: dmg, currentBuild: 5, publicKey: pub) } catch let f as UpdateFailure { message = f.message }
        try expectEqual(message, "Das Update ist nicht von Lumi signiert und wird nicht installiert.")
      },
      CheckCase("Update-Download: zu große Antwort (Content-Length oder während des Ladens) wird abgebrochen") {
        let url = URL(string: "https://example.test/Taby.dmg")!
        let big = Data(repeating: 1, count: 2_000)
        let declared = CalendarStubURLProtocol.session { _, _ in (200, big) }
        var refusedDeclared = false
        do { _ = try await CoreServices.fetchLimited(declared, url, limit: 1_000) } catch let f as UpdateFailure {
          refusedDeclared = f.message.contains("wird nicht geladen")
        }
        try expect(refusedDeclared, "Antwort über dem Limit wird nicht geladen")
        let fits = try await CoreServices.fetchLimited(CalendarStubURLProtocol.session { _, _ in (200, big) }, url, limit: 2_000)
        try expectEqual(fits.count, 2_000)
        let unknown = CalendarStubURLProtocol.session { _, _ in (200, big) }
        var refusedStreamed = false
        do { _ = try await CoreServices.fetchLimited(unknown, url, limit: 1_999) } catch { refusedStreamed = true }
        try expect(refusedStreamed, "Antwort über dem Limit wird auch ohne Länge abgebrochen")
        try expectEqual(CoreServices.maxDMGBytes, 300_000_000)
        try expectEqual(CoreServices.maxVersionBytes, 64 * 1024)
        // Ohne angekündigte Länge zählt die geladene Menge.
        try expect(DownloadState.exceeds(total: -1, completed: 2_000, limit: 1_999), "ohne Länge: geladene Menge zählt")
        try expect(!DownloadState.exceeds(total: 0, completed: 1_000, limit: 1_999), "ohne Länge, unter Grenze: weiter")
        try expect(DownloadState.exceeds(total: 5_000, completed: 0, limit: 1_000), "angekündigte Länge über Grenze")
        try expect(!DownloadState.exceeds(total: 900, completed: 900, limit: 1_000), "angekündigte Länge darunter")
      },
      CheckCase("Update-Merkdatei: liegt sie beim Start noch da und ist der Build älter, wird der Fehler gemeldet") {
        let marker = FileManager.default.temporaryDirectory
          .appendingPathComponent("taby-update-marker-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        try CoreServices.writeUpdateMarker(marker, build: 9)
        let notice = CoreServices.checkUpdateMarker(marker, currentBuild: 5)
        try expectEqual(notice?.body, "Update konnte nicht eingespielt werden – Protokoll: ~/Library/Logs/Taby-Update.log")
        try expect(!FileManager.default.fileExists(atPath: marker.path), "Merkdatei wird beim Lesen entfernt")
        try expectEqual(CoreServices.checkUpdateMarker(marker, currentBuild: 5), nil, "ohne Merkdatei still")
        try CoreServices.writeUpdateMarker(marker, build: 9)
        try expectEqual(CoreServices.checkUpdateMarker(marker, currentBuild: 9), nil, "neuer Build: Tausch ist gelungen")
      },
      CheckCase("Update-Download: Fortschritt in 10er-Schritten, steigt nur") {
        var steps: [Int] = []
        let lock = NSLock()
        let big = Data(repeating: 2, count: 5_000)
        let session = CalendarStubURLProtocol.session { _, _ in (200, big) }
        _ = try await CoreServices.fetchLimited(session, URL(string: "https://example.test/Taby.dmg")!, limit: 10_000) { pct in
          lock.lock(); steps.append(pct); lock.unlock()
        }
        lock.lock(); let seen = steps; lock.unlock()
        try expect(seen == seen.sorted(), "Fortschritt steigt nur")
        try expect(seen.allSatisfy { $0 % 10 == 0 && $0 >= 0 && $0 <= 100 }, "nur Zehnerschritte: \(seen)")
      },
      CheckCase("Austausch-Skript: Prüfung vor dem Tausch, Papierkorb, Einrichtung, Log und Aufräumen") {
        let script = CoreServices.updateScript
        try expect(script.contains("$APP.new"), "Neue App wird neben die alte kopiert")
        try expect(script.contains("shasum -a 256"), "Das Skript prüft die DMG selbst per SHA-256")
        try expect(script.contains("hdiutil attach -readonly -nobrowse"), "DMG wird schreibgeschützt gemountet")
        try expect(script.contains("ditto \"$SRC\" \"$NEW\""), "App wird aus dem Mount kopiert, nicht aus TMPDIR")
        try expect(script.contains("codesign --verify --deep -R='identifier \"de.felix.taby\"'"),
                   "Signatur und Bundle-ID werden vor dem Tausch geprüft")
        try expect(!script.contains("Update.app"), "Kein ausgepackter Update.app in TMPDIR")
        try expect(script.contains("kill -0"), "Wartet auf das Ende von Lumi")
        try expect(script.contains("Library/Logs/Taby-Update.log"), "Ausgabe landet im Log")
        try expect(script.contains("trap "), "Aufräumen beim Beenden")
        try expect(script.contains("$HOME/.Trash"), "Alte App wird in den Papierkorb verschoben")
        try expect(script.contains("friend-setup.command"), "Einrichtung wird aufgerufen")
        try expect(script.contains("\nopen \"$APP\"\n"), "Neue App wird gestartet")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("taby-update-check-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try CoreServices.runTool("/bin/sh", ["-n", file.path])
      },
    ]
  }
}

/// Eigener CoreServices mit Stub-Netz und festem App-Commit.
@MainActor
final class AppUpdateRig {
  let stub: StubServer
  let sink: SinkNotifier
  let svc: CoreServices

  private init(stub: StubServer, sink: SinkNotifier, svc: CoreServices) {
    self.stub = stub
    self.sink = sink
    self.svc = svc
  }

  /// Update-Adresse zeigt auf den Stub-Host (Ordner `/taby/`).
  static func make(commit: String = "abc1234", build: Int = 5, replies: [StubReply],
                   defaults: UserDefaults = UserDefaults(suiteName: "taby-update-check-\(UUID().uuidString)")!) async throws -> AppUpdateRig {
    let stub = StubServer(replies)
    let sink = SinkNotifier()
    var options = CoreServices.Options(keyStore: InMemoryApiKeyStore(), systemNotifier: sink,
                                       session: stub.session, plannerInterval: nil)
    options.appCommit = { commit }
    options.appBuild = { build }
    options.updateDefaults = defaults
    let svc = try CoreServices(options: options)
    _ = await svc.updateSettings(SettingsPatch(updateSource: "https://\(stub.host)/taby/"), apiKey: nil)
    return AppUpdateRig(stub: stub, sink: sink, svc: svc)
  }
}

/// Speichern der Einstellungen: fehlgeschlagener Schlüsselbund wird gemeldet, nichts wird still als gespeichert gezeigt.
enum SettingsSaveChecks {
  /// Schlüsselbund, der immer scheitert (wie ein gesperrter Schlüsselbund).
  final class FailingKeyStore: ApiKeyStore, @unchecked Sendable {
    struct Denied: Error {}
    func get() throws -> String? { nil }
    func set(_ key: String) throws { throw Denied() }
    func delete() throws { throw Denied() }
    func hasKey() -> Bool { false }
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Einstellungen: fehlgeschlagener Schlüsselbund meldet „Nicht gespeichert“ und sagt: kein Schlüssel") {
        let clock = ControllableClock("2026-10-16T09:00")
        let svc = try CoreServices(options: .init(
          databasePath: nil, socketPath: nil, clock: clock, keyStore: FailingKeyStore(),
          systemNotifier: SinkNotifier(), plannerInterval: nil,
          llmHostKeyStore: { _ in FailingKeyStore() }))
        var flashes: [TabyNotification] = []
        svc.subscribe { if case .flash(let n) = $0 { flashes.append(n) } }
        let updated = await svc.updateSettings(SettingsPatch(), apiKey: "sk-test")
        try expectEqual(updated.hasApiKey, false, "Schlüssel nicht als gesetzt melden")
        try expectEqual(flashes.map(\.title), ["Nicht gespeichert"])
      },
      CheckCase("Einstellungen: gelungenes Speichern meldet nichts") {
        let clock = ControllableClock("2026-10-16T09:00")
        let svc = try CoreServices(options: .init(
          databasePath: nil, socketPath: nil, clock: clock, keyStore: InMemoryApiKeyStore(),
          systemNotifier: SinkNotifier(), plannerInterval: nil,
          llmHostKeyStore: { _ in InMemoryApiKeyStore() }))
        var flashes: [TabyNotification] = []
        svc.subscribe { if case .flash(let n) = $0 { flashes.append(n) } }
        let updated = await svc.updateSettings(SettingsPatch(), apiKey: "sk-test")
        try expectEqual(updated.hasApiKey, true)
        try expectEqual(flashes.count, 0)
      },
    ]
  }
}
