// Prüfungen für die eingebaute Mod-Bibliothek: gültige Einträge, Installation
// ohne Freigabe und ein echter Lauf jedes Skripts mit Fake-Daten. Kein echtes Netz:
// der Wetter-Abruf läuft über einen URLProtocol-Stub.
import Foundation

enum CatalogModChecks {
  static let cases: [CheckCase] = [
    CheckCase("Bibliothek: Einträge sind gültig, eindeutig und haben Code") {
      let entries = ModCatalog.entries
      try expectEqual(entries.count, 13, "Anzahl der Bibliothekseinträge (10 Skripte, 3 Skills)")
      let ids = entries.map(\.id)
      try expectEqual(Set(ids).count, ids.count, "IDs sind eindeutig")
      for entry in entries {
        try expectEqual(ModValidation.validate(entry.manifest), [], "Manifest „\(entry.id)“")
        try expectEqual(entry.manifest.author, "Lumi", "Autor von „\(entry.id)“")
        if entry.manifest.kind == .skill {
          try expectEqual(entry.code, nil, "Skill „\(entry.id)“ hat keinen Code")
        } else {
          try expectEqual(entry.manifest.kind, .script, "Art von „\(entry.id)“")
          try expect(!(entry.code ?? "").trimmedText.isEmpty, "Code fehlt bei „\(entry.id)“")
        }
      }
    },
    CheckCase("Bibliothek: Installieren schaltet nicht ein und gibt nicht frei") {
      let base = try catalogTempDir("installieren")
      defer { try? FileManager.default.removeItem(at: base) }
      let lib = ModLibrary(root: base.appendingPathComponent("Mods"))
      for entry in ModCatalog.entries {
        let info = try lib.install(entry.manifest, code: entry.code)
        try expect(!info.enabled && !info.approved, "„\(entry.id)“ darf nach dem Installieren nicht laufen")
        try expect(!(try lib.isRunnable(entry.id)), "„\(entry.id)“ ist vor der Freigabe nicht lauffähig")
      }
      try expectEqual(try lib.all().count, ModCatalog.entries.count, "alle Einträge installiert")
    },
    CheckCase("Bibliothek: Aufgaben-Friedhof meldet nur alte Aufgaben") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("aufgaben-friedhof", input: catalogInput(weekday: 1), host: host)
      try expectEqual(r.output, "1 alte Aufgaben")
      try expectEqual(host.notifications.first?.title, "Aufgaben-Friedhof")
    },
    CheckCase("Bibliothek: Feierabend-Check zählt offene Aufgaben von heute und überfällige") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("feierabend-check", input: catalogInput(trigger: "dayEnded", now: "2026-10-12T18:00"),
                                   host: host)
      try expectEqual(r.output, "Noch 2 Aufgaben von heute offen")
      try expectEqual(host.notifications.first?.body, "Noch 2 Aufgaben von heute offen")
      try expectEqual(host.tasks.count, 5, "Aufgaben bleiben unverändert")
    },
    CheckCase("Bibliothek: Pause nach Fokus sendet einen Hinweis") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("pause-nach-fokus", input: catalogInput(trigger: "focusFinished", now: "2026-10-12T10:25"),
                                   host: host)
      try expectEqual(r.output, "Pausen-Hinweis gesendet")
      try expectEqual(host.notifications.first?.title, "Pause nach Fokus")
    },
    CheckCase("Bibliothek: Wetter setzt die Notch-Anzeige für den Wohnort") {
      let host = CatalogFakeHost()
      var input = catalogInput(trigger: "hourly", now: "2026-10-12T10:00")
      input = CoreServices.withCity(input, "Köln")
      let r = try await catalogRun("wetter-notch", input: input, host: host)
      try expectEqual(r.output, "⛅️ Köln 14 °C")
      try expectEqual(host.islandTexts.count, 1)
      try expectEqual(host.islandTexts.first?.0, "⛅️ Köln 14 °C")
      try expectEqual(host.islandTexts.first?.1, 3600)
    },
    CheckCase("Bibliothek: Wetter ohne Wohnort sagt, wo er einzustellen ist") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("wetter-notch", input: catalogInput(trigger: "hourly"), host: host)
      try expect(r.output.contains("Wohnort"), r.output)
      try expect(host.islandTexts.isEmpty, "nichts in der Notch")
    },
    CheckCase("Bibliothek: Wetter meldet unbekannten Ort") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("wetter-notch", input: CoreServices.withCity(catalogInput(), "Nirgendwo"), host: host)
      try expectEqual(r.output, "Ort „Nirgendwo“ nicht gefunden.")
    },
    CheckCase("Bibliothek: Pomodoro zählt Sitzungen von heute und zeigt sie in der Notch") {
      let host = CatalogFakeHost()
      let input = catalogInput(trigger: "focusFinished", now: "2026-10-12T10:25")
      _ = try await catalogRun("pomodoro-zaehler", input: input, host: host)
      let r = try await catalogRun("pomodoro-zaehler", input: input, host: host)
      try expectEqual(r.output, "🍅 2 heute")
      try expectEqual(host.notes.map(\.title), ["Pomodoro 2026-10-12", "Pomodoro 2026-10-12"])
      try expectEqual(host.islandTexts.last?.0, "🍅 2 heute")
      try expectEqual(host.islandTexts.last?.1, 3600)
    },
    CheckCase("Bibliothek: Pausen-Erinnerung meldet werktags tagsüber, sonst nicht") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("pausen-erinnerung",
                                   input: catalogInput(trigger: "hourly", now: "2026-10-12T10:00", weekday: 1), host: host)
      try expectEqual(r.output, "Pausen-Erinnerung gesendet")
      try expectEqual(host.notifications.first?.body, "Kurz aufstehen und trinken.")
      let weekend = CatalogFakeHost()
      let w = try await catalogRun("pausen-erinnerung",
                                   input: catalogInput(trigger: "hourly", now: "2026-10-17T10:00", weekday: 6), host: weekend)
      try expectEqual(w.output, "Außerhalb der Erinnerungszeit.")
      try expect(weekend.notifications.isEmpty, "am Wochenende still")
      let abends = CatalogFakeHost()
      _ = try await catalogRun("pausen-erinnerung",
                               input: catalogInput(trigger: "hourly", now: "2026-10-12T18:00", weekday: 1), host: abends)
      try expect(abends.notifications.isEmpty, "abends still")
    },
    CheckCase("Bibliothek: Tagesstatistik zählt heute erledigte und überfällige Aufgaben") {
      let host = CatalogFakeHost()
      let r = try await catalogRun("tagesstatistik", input: catalogInput(trigger: "dayEnded", now: "2026-10-12T18:00"),
                                   host: host)
      try expectEqual(r.output, "Heute erledigt: 1 · überfällig offen: 1")
      try expectEqual(host.notifications.first?.title, "Tagesstatistik")
    },
    CheckCase("Bibliothek: Feiertage zeigt Heute, Nahes und nichts Fernes") {
      let heute = CatalogFakeHost()
      let h = try await catalogRun("feiertage", input: catalogInput(now: "2026-10-03T08:00"), host: heute)
      try expectEqual(h.output, "Heute: Tag der Deutschen Einheit")
      try expectEqual(heute.islandTexts.first?.0, "Heute: Tag der Deutschen Einheit")
      let bald = CatalogFakeHost()
      let b = try await catalogRun("feiertage", input: catalogInput(now: "2026-04-01T08:00"), host: bald)
      try expectEqual(b.output, "In 2 Tagen: Karfreitag")
      let fern = CatalogFakeHost()
      let f = try await catalogRun("feiertage", input: catalogInput(now: "2026-10-10T08:00"), host: fern)
      try expectEqual(f.output, "Kein Feiertag in den nächsten 7 Tagen.")
      try expect(fern.islandTexts.isEmpty, "nichts in der Notch")
    },
    CheckCase("Bibliothek: ÖPNV zeigt die nächste Abfahrt, ohne Haltestelle mit Hinweis") {
      let host = CatalogFakeHost()
      // Die Haltestelle kommt wie in der App über die gespeicherten Einstellungen (ModInfo), nicht über die Eingabe.
      let r = try await catalogRun("oepnv-abfahrt", input: catalogInput(trigger: "hourly", now: "2026-10-12T10:00"),
                                   host: host, settingValues: ["stopId": "8000105"])
      try expectEqual(r.output, "🚆 S1 Blankenese in 12 Min")
      try expectEqual(host.islandTexts.first?.0, "🚆 S1 Blankenese in 12 Min")
      let ohne = CatalogFakeHost()
      let o = try await catalogRun("oepnv-abfahrt", input: catalogInput(trigger: "hourly", now: "2026-10-12T10:00"),
                                   host: ohne)
      try expect(o.output.contains("Haltestelle"), o.output)
      try expect(ohne.islandTexts.isEmpty, "nichts in der Notch")
    },
    CheckCase("Bibliothek: Geburtstag-Vorlauf meldet nur Geburtstage der nächsten 3 Tage") {
      let host = CatalogFakeHost()
      host.events = [
        CalendarEvent(id: "g1", sourceId: "cal", title: "Geburtstag von Anna", start: "2026-10-15", allDay: true),
        CalendarEvent(id: "g2", sourceId: "cal", title: "Geburtstag von Ben", start: "2026-10-20", allDay: true),
        CalendarEvent(id: "u1", sourceId: "cal", title: "Urlaub", start: "2026-10-13", allDay: true),
      ]
      let r = try await catalogRun("geburtstag-vorlauf", input: catalogInput(now: "2026-10-12T08:00"), host: host)
      try expectEqual(r.output, "In 3 Tagen: Geburtstag von Anna")
      try expectEqual(host.notifications.first?.body, "In 3 Tagen: Geburtstag von Anna")
    },
  ]
}

/// Fake-Speicher für die Bibliotheks-Läufe; schreibt nichts Echtes.
private final class CatalogFakeHost: ModHostAPI, @unchecked Sendable {
  var tasks: [TabyTask] = {
    var alt = TabyTask(id: "alt", title: "Steuer", createdAt: "2026-09-01T09:00")
    var heute = TabyTask(id: "heute", title: "Angebot", createdAt: "2026-10-12T08:00")
    heute.due = "2026-10-12T10:00"
    var ueberfaellig = TabyTask(id: "spaet", title: "Rechnung", createdAt: "2026-10-01T09:00")
    ueberfaellig.due = "2026-10-11"
    var morgen = TabyTask(id: "morgen", title: "Termin", createdAt: "2026-10-01T09:00")
    morgen.due = "2026-10-13"
    var erledigt = TabyTask(id: "fertig", title: "Erledigt", createdAt: "2026-09-01T09:00")
    erledigt.due = "2026-10-12"
    erledigt.done = true
    erledigt.doneAt = "2026-10-12T14:00"
    return [alt, heute, ueberfaellig, morgen, erledigt]
  }()
  var notifications: [TabyNotification] = []
  var islandTexts: [(String, Double)] = []
  var notes: [Note] = []
  var events: [CalendarEvent] = []

  func listTasks() async throws -> [TabyTask] { tasks }
  func addTask(title: String, due: String?) async throws -> TabyTask { throw ScriptBridgeError("Im Test nicht erlaubt.") }
  func completeTask(id: String) async throws { throw ScriptBridgeError("Im Test nicht erlaubt.") }
  func listNotes() async throws -> [Note] { notes }
  func addNote(title: String, content: String) async throws -> Note {
    let note = Note(id: "n\(notes.count)", title: title, content: content, createdAt: "2026-10-12T10:25",
                    updatedAt: "2026-10-12T10:25")
    notes.append(note)
    return note
  }
  func listEvents(from: String, to: String) async throws -> [CalendarEvent] { events }
  func notify(_ n: TabyNotification) { notifications.append(n) }
  func setIslandText(_ text: String, seconds: Double) { islandTexts.append((text, seconds)) }
}

/// URLProtocol-Stub nur für die Wetter-Adresse; alles andere ist 404.
private final class CatalogStubProtocol: URLProtocol {
  nonisolated(unsafe) static var routes: [String: Data] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let body = CatalogStubProtocol.routes[url.absoluteString]
    let status = body == nil ? 404 : 200
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])
    if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
    client?.urlProtocol(self, didLoad: body ?? Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func catalogStubSession() -> URLSession {
  CatalogStubProtocol.routes = [
    "https://geocoding-api.open-meteo.com/v1/search?count=1&language=de&name=K%C3%B6ln":
      Data(#"{"results":[{"name":"Köln","latitude":50.94,"longitude":6.96}]}"#.utf8),
    "https://geocoding-api.open-meteo.com/v1/search?count=1&language=de&name=Nirgendwo": Data(#"{}"#.utf8),
    "https://api.open-meteo.com/v1/forecast?latitude=50.94&longitude=6.96&current=temperature_2m,weather_code":
      Data(#"{"current":{"temperature_2m":14.2,"weather_code":3}}"#.utf8),
    "https://v6.db.transport.rest/stops/8000105/departures?duration=30&results=3":
      Data(#"{"departures":[{"line":{"name":"S1"},"direction":"Blankenese","when":"2026-10-12T10:12:00"}]}"#.utf8),
  ]
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [CatalogStubProtocol.self]
  return URLSession(configuration: config)
}

private func catalogInput(trigger: String = "dayStarted", now: String = "2026-10-12T09:00", weekday: Double = 1) -> JSONValue {
  .object(["trigger": .string(trigger), "now": .string(now), "weekday": .number(weekday)])
}

private func catalogRun(_ id: String, input: JSONValue, host: CatalogFakeHost,
                        settingValues: [String: String] = [:]) async throws -> ScriptRunResult {
  guard let entry = ModCatalog.entries.first(where: { $0.id == id }) else { throw fail("„\(id)“ fehlt in der Bibliothek") }
  return try await ScriptModRunner(host: host, session: catalogStubSession(), timeout: 5)
    .run(code: entry.code ?? "", manifest: entry.manifest, input: input, settingValues: settingValues)
}

private func catalogTempDir(_ name: String) throws -> URL {
  let u = FileManager.default.temporaryDirectory
    .appendingPathComponent("taby-catalogcheck-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}
