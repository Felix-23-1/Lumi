// Prüfungen für Sources/TabyCore/Calendar (Port von test/unit/calendar/*.test.ts).
// HTTP wird über ein eigenes URLProtocol gestubbt — kein echtes Netz.
// EventKit nur über die Abbildungsfunktionen (Freigabe am echten Mac nötig).
import Foundation

/// Gestubbtes HTTP: Handler je Prüfung, mitgeschnittene Anfragen.
final class CalendarStubURLProtocol: URLProtocol {
  struct Recorded {
    var method: String
    var url: String
    var headers: [String: String]
    var body: JSONValue?
  }

  typealias Handler = (URLRequest, JSONValue?) -> (Int, Data)
  private static let lock = NSLock()
  private static var handler: Handler?
  private static var recorded: [Recorded] = []
  private static var rawBody: Data?
  /// Roher Körper der letzten Anfrage (Formulare, z. B. Microsoft-Anmeldung), nur in der Handler-Phase gültig.
  static var lastRawBody: Data? { lock.withLock { rawBody } }

  static func session(_ handler: @escaping Handler) -> URLSession {
    lock.withLock {
      self.handler = handler
      recorded = []
    }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [CalendarStubURLProtocol.self]
    return URLSession(configuration: cfg)
  }

  static var requests: [Recorded] { lock.withLock { recorded } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var bodyData = request.httpBody
    if bodyData == nil, let stream = request.httpBodyStream {
      stream.open()
      var d = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        d.append(contentsOf: buf[0..<n])
      }
      stream.close()
      bodyData = d
    }
    let body = bodyData.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    let (h, rec): (Handler?, Recorded) = Self.lock.withLock {
      Self.rawBody = bodyData
      let r = Recorded(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
                       headers: request.allHTTPHeaderFields ?? [:], body: body)
      Self.recorded.append(r)
      return (Self.handler, r)
    }
    _ = rec
    let (status, data) = h?(request, body) ?? (500, Data())
    let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                               headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Provider mit festen Terminen oder festem Fehler (Registry-Prüfungen).
private final class FakeProvider: CalendarProvider {
  let id: String
  let kind: CalendarSourceKind
  let canWrite: Bool
  let events: [CalendarEvent]
  let error: Error?
  init(id: String, kind: CalendarSourceKind = .local, canWrite: Bool = true, events: [CalendarEvent] = [],
       error: Error? = nil) {
    self.id = id; self.kind = kind; self.canWrite = canWrite; self.events = events; self.error = error
  }
  func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    if let error { throw error }
    return events
  }
  func healthCheck() async -> HealthResult { HealthResult(ok: error == nil) }
}

private func json(_ v: JSONValue) -> Data { Data(v.jsonString().utf8) }

/// UTC-Zeitpunkt → erwarteter lokaler ISO-String (unabhängig von der Zone des Prüf-Macs).
private func localOf(_ iso: String) -> String {
  let f = ISO8601DateFormatter()
  return LocalTime.format(f.date(from: iso)!)
}

private let sampleICS = """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:ev-1\r
  SUMMARY:Zahnarzt\\, Kontrolle\r
  DTSTART:20261012T090000\r
  DTEND:20261012T100000\r
  DESCRIPTION:Zeile 1\\nZeile 2\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:ev-2\r
  SUMMARY:Sehr langer Titel, der in der\r
   nächsten Zeile weitergeht\r
  DTSTART;VALUE=DATE:20261013\r
  DTEND;VALUE=DATE:20261014\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:ev-3\r
  SUMMARY:Utc-Termin\r
  DTSTART:20261012T070000Z\r
  DTEND:20261012T073000Z\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:ev-4\r
  SUMMARY:New York\r
  DTSTART;TZID=America/New_York:20261012T090000\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:ev-5\r
  SUMMARY:Nächste Woche\r
  DTSTART:20261020T090000\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  SUMMARY:Ohne Start\r
  END:VEVENT\r
  END:VCALENDAR\r

  """

private let notionConfig: [String: JSONValue] = [
  "databaseId": "db-123", "titleField": "Name", "startField": "Datum",
]
/// Platzhalter, kein echtes Geheimnis.
private let fakeToken = "test-token-placeholder"

private func notionPage(_ id: String, title: String, start: String?, end: String? = nil) -> JSONValue {
  var props: [String: JSONValue] = [
    "Name": ["type": "title", "title": [["plain_text": .string(title)]]],
  ]
  if let start {
    props["Datum"] = ["type": "date", "date": ["start": .string(start), "end": end.map { .string($0) } ?? .null]]
  }
  return ["object": "page", "id": .string(id), "properties": .object(props)]
}

enum CalendarChecks {
  static let suite = CheckSuite("Calendar", [
    // MARK: ICS
    CheckCase("Bereich: mehrtägige und ganztägige Termine von davor zählen, Ende um 00:00 nicht") {
      func ev(_ start: String, _ end: String?) -> CalendarEvent {
        CalendarEvent(id: "x", sourceId: "s", title: "t", start: start, end: end)
      }
      try expect(CalendarSupport.inRange(ev("2026-10-10T09:00", "2026-10-12T17:00"), from: "2026-10-11", to: "2026-10-12"),
                 "läuft in den Tag hinein")
      try expect(CalendarSupport.inRange(ev("2026-10-10", "2026-10-12"), from: "2026-10-11", to: "2026-10-12"),
                 "ganztägig, läuft noch")
      try expect(!CalendarSupport.inRange(ev("2026-10-09T09:00", "2026-10-11T00:00"), from: "2026-10-11", to: "2026-10-12"),
                 "endet um 00:00 am from")
      try expect(!CalendarSupport.inRange(ev("2026-10-01T09:00", "2026-10-02T10:00"), from: "2026-10-11", to: "2026-10-12"),
                 "längst vorbei")
      try expect(!CalendarSupport.inRange(ev("2026-10-12T09:00", nil), from: "2026-10-11", to: "2026-10-12"),
                 "beginnt erst am to-Tag (exklusiv)")
      try expect(CalendarSupport.inRange(ev("2026-10-11T08:00", nil), from: "2026-10-11", to: "2026-10-12"),
                 "beginnt am from")
    },
    CheckCase("ICS: parst SUMMARY/DTSTART/DTEND/UID inkl. Faltung und Escapes") {
      let events = ICSParser.parseEvents(sampleICS, sourceId: "ics")
      try expectEqual(events.count, 5, "VEVENT ohne DTSTART wird übersprungen")
      let e1 = events[0]
      try expectEqual(e1.id, "ev-1")
      try expectEqual(e1.title, "Zahnarzt, Kontrolle")
      try expectEqual(e1.start, "2026-10-12T09:00")
      try expectEqual(e1.end, "2026-10-12T10:00")
      try expectEqual(e1.notes, "Zeile 1\nZeile 2")
      try expect(e1.readOnly && !e1.allDay && e1.sourceId == "ics")
      try expectEqual(events[1].title, "Sehr langer Titel, der in dernächsten Zeile weitergeht")
    },
    CheckCase("ICS: Ganztägig an VALUE=DATE (keine Uhrzeit)") {
      let e = ICSParser.parseEvents(sampleICS)[1]
      try expect(e.allDay)
      try expectEqual(e.start, "2026-10-13")
      try expectEqual(e.end, "2026-10-14")
    },
    CheckCase("ICS: UTC (Z) und TZID werden in lokale Zeit umgerechnet, floating bleibt") {
      let events = ICSParser.parseEvents(sampleICS)
      try expectEqual(events[2].start, localOf("2026-10-12T07:00:00Z"))
      try expectEqual(events[2].end, localOf("2026-10-12T07:30:00Z"))
      try expectEqual(events[3].start, localOf("2026-10-12T13:00:00Z"), "09:00 New York (EDT) = 13:00 UTC")
      try expectEqual(ICSParser.parseDate("20261012T090000", tzid: "Unbekannt/Zone").value, "2026-10-12T09:00")
    },
    CheckCase("ICS-Provider: lädt per HTTP, filtert Zeitraum, nicht beschreibbar") {
      let session = CalendarStubURLProtocol.session { req, _ in
        (req.url?.host == "example.test" ? 200 : 404, Data(sampleICS.utf8))
      }
      let p = ICSCalendarProvider(id: "ics:abo", config: ["url": "webcal://example.test/cal.ics"], session: session)
      try expect(!p.canWrite)
      let events = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expect(events.allSatisfy { $0.sourceId == "ics:abo" })
      try expect(!events.contains { $0.id == "ev-5" }, "nächste Woche liegt außerhalb")
      try expect(events.contains { $0.id == "ev-2" }, "to exklusiv, from inklusiv")
      try expectEqual(CalendarStubURLProtocol.requests.first?.url, "https://example.test/cal.ics")
      do {
        _ = try await p.createEvent(NewEvent(title: "x", start: "2026-10-12"))
        throw fail("ICS darf nicht schreiben")
      } catch let e as CalendarError {
        try expectEqual(e, .notWritable("ics:abo"))
      }
    },
    CheckCase("ICS-Provider: healthCheck meldet ok:false bei HTTP-Fehler") {
      let session = CalendarStubURLProtocol.session { _, _ in (500, Data()) }
      let p = ICSCalendarProvider(id: "ics", config: ["url": "https://example.test/x.ics"], session: session)
      let h = await p.healthCheck()
      try expect(!h.ok)
      try expectEqual(h.message, "ICS-Abruf fehlgeschlagen: 500")
      let missing = await ICSCalendarProvider(id: "ics", config: [:], session: session).healthCheck()
      try expect(!missing.ok && (missing.message ?? "").contains("Adresse"))
    },

    // MARK: Notion
    CheckCase("Notion: Data-Sources-Workflow (Discovery, dann paginierte Query mit Datumsfilter)") {
      let session = CalendarStubURLProtocol.session { req, body in
        let url = req.url!.absoluteString
        if url.hasSuffix("/v1/databases/db-123") {
          return (200, json(["object": "database", "data_sources": [["id": "ds-1", "name": "Termine"]]]))
        }
        if url.hasSuffix("/v1/data_sources/ds-1/query") {
          if body?["start_cursor"] == nil {
            return (200, json(["object": "list", "has_more": true, "next_cursor": "c2", "results": [
              notionPage("p1", title: "Planung", start: "2026-10-12T09:00:00.000+00:00", end: "2026-10-12T10:00:00.000+00:00"),
              notionPage("p2", title: "Ohne Datum", start: nil),
            ]]))
          }
          return (200, json(["object": "list", "has_more": false, "next_cursor": .null, "results": [
            notionPage("p3", title: "", start: "2026-10-13"),
            notionPage("p4", title: "Zonenlos", start: "2026-10-12T15:30"),
          ]]))
        }
        return (404, json(["object": "error", "message": "unbekannt"]))
      }
      let p = try NotionCalendarProvider(id: "notion:db-123", config: notionConfig, token: fakeToken, session: session)
      let events = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(events.map(\.id), ["p1", "p3", "p4"])
      try expectEqual(events[0].start, localOf("2026-10-12T09:00:00Z"))
      try expectEqual(events[0].end, localOf("2026-10-12T10:00:00Z"))
      try expectEqual(events[1].title, "(ohne Titel)")
      try expect(events[1].allDay && !events[0].allDay)
      try expectEqual(events[2].start, "2026-10-12T15:30")
      let reqs = CalendarStubURLProtocol.requests
      try expectEqual(reqs.map(\.method), ["GET", "POST", "POST"])
      try expect(reqs.allSatisfy { $0.headers["Notion-Version"] == NotionCalendarProvider.apiVersion })
      try expect(reqs.allSatisfy { $0.headers["Authorization"] == "Bearer \(fakeToken)" })
      try expectEqual(reqs[2].body?["start_cursor"], "c2")
      let filter = reqs[1].body?["filter"]?["and"]?.arrayValue
      try expectEqual(filter?.first?["date"]?["on_or_after"], "2026-10-12")
      try expectEqual(filter?.last?["date"]?["before"], "2026-10-14")
      try expectEqual(filter?.first?["property"], "Datum")
    },
    CheckCase("Notion: createEvent legt Seite unter der Data Source an (POST /v1/pages)") {
      let session = CalendarStubURLProtocol.session { req, _ in
        let url = req.url!.absoluteString
        if url.hasSuffix("/v1/databases/db-123") {
          return (200, json(["object": "database", "data_sources": [["id": "ds-1", "name": "T"]]]))
        }
        if url.hasSuffix("/v1/pages") { return (200, json(["object": "page", "id": "new-page"])) }
        return (404, Data())
      }
      let p = try NotionCalendarProvider(id: "notion:db-123", config: notionConfig, token: fakeToken, session: session)
      try expect(p.canWrite)
      let created = try await p.createEvent(NewEvent(title: "Meeting", start: "2026-10-12T14:00", end: "2026-10-12T15:00"))
      try expectEqual(created.id, "new-page")
      try expectEqual(created.sourceId, "notion:db-123")
      try expect(!created.allDay && !created.readOnly)
      let post = try expectNotNil(CalendarStubURLProtocol.requests.last)
      try expectEqual(post.method, "POST")
      try expect(post.url.hasSuffix("/v1/pages"))
      try expectEqual(post.body?["parent"]?["type"], "data_source_id")
      try expectEqual(post.body?["parent"]?["data_source_id"], "ds-1")
      try expectEqual(post.body?["properties"]?["Name"]?["title"]?.arrayValue?.first?["text"]?["content"], "Meeting")
      let date = post.body?["properties"]?["Datum"]?["date"]
      try expectEqual(date?["start"], "2026-10-12T14:00")
      try expectEqual(date?["end"], "2026-10-12T15:00")
      try expectEqual(date?["time_zone"]?.stringValue, TimeZone.current.identifier)
    },
    CheckCase("Notion: getrenntes Endfeld wird als eigene Datumseigenschaft geschrieben") {
      var cfg = notionConfig
      cfg["endField"] = "Ende"
      let p = try NotionCalendarProvider(id: "n", config: cfg, token: fakeToken, session: .shared)
      let body = p.createBody(NewEvent(title: "Ganztag", start: "2026-10-12", end: "2026-10-13"), dataSourceId: "ds")
      try expectEqual(body["properties"]?["Datum"]?["date"]?["end"], .null)
      try expectEqual(body["properties"]?["Datum"]?["date"]?["time_zone"], nil, "ganztägig ohne Zeitzone")
      try expectEqual(body["properties"]?["Ende"]?["date"]?["start"], "2026-10-13")
    },
    CheckCase("Notion: healthCheck meldet ok:false bei Fehlerform (401), Token nicht im Text") {
      let session = CalendarStubURLProtocol.session { _, _ in
        (401, json(["object": "error", "status": 401, "code": "unauthorized", "message": "API token is invalid."]))
      }
      let p = try NotionCalendarProvider(id: "n", config: notionConfig, token: fakeToken, session: session)
      let h = await p.healthCheck()
      try expect(!h.ok)
      try expectEqual(h.message, "Notion-Discovery fehlgeschlagen: API token is invalid.")
      try expect(!(h.message ?? "").contains(fakeToken))
    },
    CheckCase("Notion: wirft ohne databaseId oder Token") {
      try await expectThrows { _ = try NotionCalendarProvider(id: "n", config: ["databaseId": "x"]) }
      try await expectThrows { _ = try NotionCalendarProvider(id: "n", config: [:], token: fakeToken) }
      _ = try NotionCalendarProvider(id: "n", config: ["databaseId": "x", "token": "fallback-placeholder"])
    },

    // MARK: Lokal
    CheckCase("Lokal: deleteEvent entfernt den Termin; ICS (nur lesbar) lehnt ab") {
      let store = InMemoryLocalEventStore(sourceId: "local")
      let p = LocalCalendarProvider(store: store)
      let e = try await p.createEvent(NewEvent(title: "Weg damit", start: "2026-10-12T09:00"))
      try await p.deleteEvent(id: e.id)
      let left = try await p.listEvents(from: "2026-10-01", to: "2026-11-01")
      try expect(left.isEmpty, "Termin ist gelöscht")
      // Nur lesbares Modul: Standard-Implementierung wirft notWritable.
      let ics = ICSCalendarProvider(id: "ics", config: ["url": "https://example.test/x.ics"], session: .shared)
      var refused = false
      do { try await ics.deleteEvent(id: "x") } catch { refused = true }
      try expect(refused, "ICS lehnt Löschen ab")
    },
    CheckCase("Lokal: create() stempelt sourceId und erkennt Ganztägig an fehlendem T") {
      let store = InMemoryLocalEventStore(sourceId: "local")
      let p = LocalCalendarProvider(store: store)
      let timed = try await p.createEvent(NewEvent(title: "A", start: "2026-10-12T09:00"))
      let day = try await p.createEvent(NewEvent(title: "B", start: "2026-10-12", notes: "n"))
      try expect(timed.sourceId == "local" && !timed.allDay && !timed.readOnly)
      try expect(day.allDay)
      try expectEqual(day.notes, "n")
      try expect(p.canWrite)
      let health = await p.healthCheck()
      try expect(health.ok)
    },
    CheckCase("Lokal: list() filtert from inklusiv / to exklusiv") {
      let seed = [
        CalendarEvent(id: "1", sourceId: "local", title: "x", start: "2026-10-11T23:00"),
        CalendarEvent(id: "2", sourceId: "local", title: "x", start: "2026-10-12"),
        CalendarEvent(id: "3", sourceId: "local", title: "x", start: "2026-10-12T08:00"),
        CalendarEvent(id: "4", sourceId: "local", title: "x", start: "2026-10-13T00:00"),
      ]
      let store = InMemoryLocalEventStore(seed: seed)
      let listed = try await store.list(from: "2026-10-12", to: "2026-10-13")
      try expectEqual(listed.map(\.id), ["2", "3"])
    },

    // MARK: Registry
    CheckCase("Registry: aggregiert über alle aktiven Quellen, ignoriert deaktivierte") {
      let local = InMemoryLocalEventStore(seed: [CalendarEvent(id: "l1", sourceId: "local", title: "L", start: "2026-10-12T08:00")])
      let session = CalendarStubURLProtocol.session { _, _ in (200, Data(sampleICS.utf8)) }
      let reg = CalendarRegistry(sources: [
        CalendarSourceConfig(id: "local", kind: .local, isDefaultWrite: true),
        CalendarSourceConfig(id: "ics:a", kind: .ics, config: ["url": "https://example.test/a.ics"]),
        CalendarSourceConfig(id: "ics:aus", kind: .ics, config: ["url": "https://example.test/b.ics"], enabled: false),
      ], deps: CalendarRegistryDeps(localStore: local, session: session))
      try expectEqual(reg.providers.map(\.id), ["local", "ics:a"])
      let r = await reg.listAllEvents(from: "2026-10-12", to: "2026-10-13")
      try expect(r.unreachable.isEmpty)
      try expectEqual(r.events.first?.id, "l1", "Reihenfolge nach Provider")
      try expect(r.events.contains { $0.sourceId == "ics:a" })
      try expect(reg.provider(id: "ics:a") != nil && reg.provider(id: "ics:aus") == nil)
    },
    CheckCase("Registry: Fehler je Quelle → unreachable, andere Quellen bleiben") {
      let ok = FakeProvider(id: "ok", events: [CalendarEvent(id: "e", sourceId: "ok", title: "t", start: "2026-10-12T09:00")])
      let bad = FakeProvider(id: "notion:kaputt", kind: .notion, error: CalendarError.unreachable("Notion-Abfrage fehlgeschlagen: 503"))
      let reg = CalendarRegistry(providers: [bad, ok])
      let r = await reg.listAllEvents(from: "2026-10-12", to: "2026-10-13")
      try expectEqual(r.events.map(\.id), ["e"])
      try expectEqual(r.unreachable, [SourceProblem(id: "notion:kaputt", message: "Notion-Abfrage fehlgeschlagen: 503")])
    },
    CheckCase("Registry: ungültige Notion-Konfiguration erscheint als nicht erreichbar") {
      let reg = CalendarRegistry(sources: [CalendarSourceConfig(id: "notion:x", kind: .notion, config: [:])],
                                 deps: CalendarRegistryDeps(notionToken: { _ in nil }))
      try expectEqual(reg.providers.map(\.id), ["local", "notion:x"], "lokal wird immer ergänzt")
      let r = await reg.listAllEvents(from: "2026-10-12", to: "2026-10-13")
      try expectEqual(r.unreachable.map(\.id), ["notion:x"])
      try expect(r.unreachable[0].message.contains("Token"))
      let health = await reg.healthCheck(id: "notion:x")
      try expect(!health.ok)
    },
    CheckCase("Registry: Token kommt über Abhängigkeit (Schlüsselbund), nicht aus der Konfiguration") {
      var seen: [String] = []
      let reg = CalendarRegistry(sources: [CalendarSourceConfig(id: "notion:db", kind: .notion, config: ["databaseId": "db"])],
                                 deps: CalendarRegistryDeps(notionToken: { seen.append($0.id); return fakeToken }))
      try expectEqual(seen, ["notion:db"])
      try expect((reg.provider(id: "notion:db") as? CachingCalendarProvider)?.inner is NotionCalendarProvider)
    },
    CheckCase("Registry: appleFactory ersetzt den EventKit-Provider") {
      let reg = CalendarRegistry(sources: [CalendarSourceConfig(id: "apple", kind: .apple)],
                                 deps: CalendarRegistryDeps(appleFactory: { FakeProvider(id: $0.id, kind: .apple) }))
      try expect(reg.provider(id: "apple") is FakeProvider)
      let real = CalendarRegistry(sources: [CalendarSourceConfig(id: "apple", kind: .apple)])
      try expect(real.provider(id: "apple") is AppleCalendarProvider)
    },
    CheckCase("Registry: Standard zum Schreiben, Rückfall auf lokal") {
      let reg = CalendarRegistry(sources: [
        CalendarSourceConfig(id: "notion:db", kind: .notion, config: ["databaseId": "db"], isDefaultWrite: true),
        CalendarSourceConfig(id: "ics:a", kind: .ics, config: ["url": "https://example.test/a.ics"]),
      ], deps: CalendarRegistryDeps(notionToken: { _ in fakeToken }))
      try expectEqual(reg.defaultWriteProvider()?.id, "notion:db")
      let ro = CalendarRegistry(sources: [
        CalendarSourceConfig(id: "ics:a", kind: .ics, config: ["url": "https://example.test/a.ics"], isDefaultWrite: true),
      ])
      try expectEqual(ro.defaultWriteProvider()?.id, "local", "ICS ist nicht beschreibbar")
      let none = CalendarRegistry(providers: [FakeProvider(id: "ro", kind: .ics, canWrite: false)])
      try expect(none.defaultWriteProvider() == nil)
    },
    CheckCase("Registry: ohne Markierung gewinnt beschreibbarer Apple-Kalender vor lokal; Markierung gewinnt") {
      let apple = FakeProvider(id: "apple", kind: .apple)
      try expectEqual(CalendarRegistry(providers: [FakeProvider(id: "local", kind: .local), apple]).defaultWriteProvider()?.id,
                      "apple")
      let roApple = FakeProvider(id: "apple", kind: .apple, canWrite: false)
      try expectEqual(CalendarRegistry(providers: [FakeProvider(id: "local", kind: .local), roApple]).defaultWriteProvider()?.id,
                      "local")
      let marked = CalendarRegistry(providers: [FakeProvider(id: "local", kind: .local), apple,
                                                FakeProvider(id: "notion:x", kind: .notion)], defaultWriteId: "notion:x")
      try expectEqual(marked.defaultWriteProvider()?.id, "notion:x")
    },

    // MARK: Cache der Fernquellen
    CheckCase("Cache: zwei Lesungen innerhalb 5 Min → 1 Abruf; nach 5 Min → 2") {
      let clock = ControllableClock("2026-10-12T09:00")
      let session = CalendarStubURLProtocol.session { _, _ in (200, Data(sampleICS.utf8)) }
      let p = CachingCalendarProvider(inner: ICSCalendarProvider(id: "ics:c", config: ["url": "https://example.test/c.ics"],
                                                                  session: session), clock: clock)
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 1)
      clock.advance(seconds: 299)
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 1, "knapp unter 5 Min noch aus dem Cache")
      clock.advance(seconds: 2)
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 2)
      _ = try await p.listEvents(from: "2026-10-13", to: "2026-10-15")
      try expectEqual(CalendarStubURLProtocol.requests.count, 3, "anderer Zeitraum ist ein eigener Schlüssel")
    },
    CheckCase("Cache: gleichzeitige Lesungen teilen sich einen Abruf") {
      let clock = ControllableClock("2026-10-12T09:00")
      let session = CalendarStubURLProtocol.session { _, _ in (200, Data(sampleICS.utf8)) }
      let p = CachingCalendarProvider(inner: ICSCalendarProvider(id: "ics:k", config: ["url": "https://example.test/k.ics"],
                                                                  session: session), clock: clock)
      let ok = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
          group.addTask { (try? await p.listEvents(from: "2026-10-12", to: "2026-10-14"))?.isEmpty == false }
        }
        var n = 0
        for await good in group where good { n += 1 }
        return n
      }
      try expectEqual(ok, 8)
      try expectEqual(CalendarStubURLProtocol.requests.count, 1)
    },
    CheckCase("Cache: Schreiben über Lumi und refresh leeren den Cache der Quelle") {
      let clock = ControllableClock("2026-10-12T09:00")
      let session = CalendarStubURLProtocol.session { req, _ in
        let url = req.url!.absoluteString
        if url.hasSuffix("/v1/databases/db-123") {
          return (200, json(["object": "database", "data_sources": [["id": "ds-1"]]]))
        }
        if url.hasSuffix("/v1/pages") { return (200, json(["object": "page", "id": "new-page"])) }
        if url.contains("/v1/data_sources/ds-1/query") { return (200, json(["object": "list", "results": [], "has_more": false])) }
        return (404, Data())
      }
      let p = CachingCalendarProvider(inner: try NotionCalendarProvider(id: "notion:db-123", config: notionConfig,
                                                                         token: fakeToken, session: session), clock: clock)
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 2, "Data-Source-Suche + Abfrage")
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 2, "zweite Lesung aus dem Cache")
      _ = try await p.createEvent(NewEvent(title: "Neu", start: "2026-10-12T14:00"))
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 6, "Schreiben (2 Anfragen) leert, nächste Lesung holt neu (2)")
      p.refresh()
      _ = try await p.listEvents(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(CalendarStubURLProtocol.requests.count, 8, "ausdrückliches Aktualisieren leert")
    },
    CheckCase("Cache: Fehler liefert bis 30 Min den letzten guten Stand, Fehler bleibt gemeldet") {
      final class Flag: @unchecked Sendable { var fail = false }
      let flag = Flag()
      let clock = ControllableClock("2026-10-12T09:00")
      let session = CalendarStubURLProtocol.session { _, _ in
        flag.fail ? (500, Data()) : (200, Data(sampleICS.utf8))
      }
      let p = CachingCalendarProvider(inner: ICSCalendarProvider(id: "ics:f", config: ["url": "https://example.test/f.ics"],
                                                                  session: session), clock: clock)
      let first = try await p.load(from: "2026-10-12", to: "2026-10-14")
      try expect(first.problem == nil && !first.events.isEmpty)
      flag.fail = true
      clock.advance(seconds: 301)
      let stale = try await p.load(from: "2026-10-12", to: "2026-10-14")
      try expectEqual(stale.events, first.events)
      try expect(stale.problem?.contains("500") == true, "Fehler wird weiterhin gemeldet")
      let reg = CalendarRegistry(providers: [p])
      let listing = await reg.listAllEvents(from: "2026-10-12", to: "2026-10-14")
      try expect(!listing.events.isEmpty)
      try expectEqual(listing.unreachable.map(\.id), ["ics:f"])
      clock.advance(seconds: 1600)
      do {
        _ = try await p.load(from: "2026-10-12", to: "2026-10-14")
        throw fail("nach 30 Min ohne gutes Ergebnis darf nichts mehr kommen")
      } catch let e as CalendarError {
        try expectEqual(e, .unreachable("ICS-Abruf fehlgeschlagen: 500"))
      }
    },
    CheckCase("Cache: lokales und Apple-Modul bleiben ungecached") {
      let reg = CalendarRegistry(sources: [CalendarSourceConfig(id: "local", kind: .local)])
      try expect(reg.providers.allSatisfy { !($0 is CachingCalendarProvider) })
    },

    // MARK: Apple (nur Abbildung; Freigabe nicht prüfbar)
    CheckCase("Apple: Abbildung EKEvent-Werte → CalendarEvent") {
      let start = LocalTime.parse("2026-10-12T09:00")!
      let end = LocalTime.parse("2026-10-12T10:30")!
      let e = AppleCalendarProvider.makeEvent(identifier: "EK1", sourceId: "apple", title: " Arzt ", start: start, end: end,
                                              allDay: false, notes: "", writable: false)
      try expectEqual(e, CalendarEvent(id: "EK1|2026-10-12T09:00", sourceId: "apple", title: "Arzt",
                                       start: "2026-10-12T09:00", end: "2026-10-12T10:30", allDay: false, notes: nil, readOnly: true))
      let dayEnd = LocalTime.parse("2026-10-12T23:59:59")!
      let d = AppleCalendarProvider.makeEvent(identifier: "EK2", sourceId: "apple", title: nil, start: LocalTime.parse("2026-10-12")!,
                                              end: dayEnd, allDay: true, notes: "x", writable: true)
      try expect(d.allDay && d.start == "2026-10-12" && d.end == nil && d.title == "(ohne Titel)" && !d.readOnly)
    },
    CheckCase("Apple: Löschen zerlegt die angezeigte id wieder in EventKit-Kennung und Start") {
      let e = AppleCalendarProvider.makeEvent(identifier: "AB:CD-1", sourceId: "apple", title: "x",
                                              start: LocalTime.parse("2026-10-12T09:00")!, end: nil,
                                              allDay: false, notes: nil, writable: true)
      let split = AppleCalendarProvider.splitId(e.id)
      try expectEqual(split.identifier, "AB:CD-1")
      try expectEqual(split.start, "2026-10-12T09:00")
      try expect(AppleCalendarProvider.splitId("EK9").start == nil, "alte id ohne Start bleibt nutzbar")
    },
    CheckCase("Apple: NewEvent → Zeitpunkte (Standarddauer, Ganztägig, ungültig)") {
      let a = try AppleCalendarProvider.dates(for: NewEvent(title: "x", start: "2026-10-12T09:00"))
      try expectEqual(a.end.timeIntervalSince(a.start), 3600)
      try expect(!a.allDay)
      let b = try AppleCalendarProvider.dates(for: NewEvent(title: "x", start: "2026-10-12"))
      try expect(b.allDay && b.start == b.end)
      try await expectThrows { _ = try AppleCalendarProvider.dates(for: NewEvent(title: "x", start: "morgen")) }
      try await expectThrows {
        _ = try AppleCalendarProvider.dates(for: NewEvent(title: "x", start: "2026-10-12T10:00", end: "2026-10-12T09:00"))
      }
    },
    CheckCase("Apple: Freigabe-Hinweise auf Deutsch, ohne Info.plist kein Dialog") {
      try expect(AppleCalendarProvider.accessMessage(.granted, hasUsageDescription: true) == nil)
      try expect(AppleCalendarProvider.accessMessage(.denied, hasUsageDescription: true)?.contains("Systemeinstellungen") == true)
      try expect(AppleCalendarProvider.accessMessage(.notDetermined, hasUsageDescription: false)?.contains("Info.plist") == true)
      try expect(AppleCalendarProvider.accessMessage(.writeOnly, hasUsageDescription: true)?.contains("Voller Zugriff") == true)
      try expectEqual(AppleCalendarProvider.access(.fullAccess), .granted)
      try expectEqual(AppleCalendarProvider.access(.writeOnly), .writeOnly)
    },
    CheckCase("EventKit: SerialAccess lässt parallele Aufrufe nie überlappen") {
      // Fake statt EKEventStore: zählt, wie viele Aufrufe gleichzeitig im Rumpf stecken.
      final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var inside = 0, maxInside = 0, calls = 0
        func enter() { lock.withLock { inside += 1; calls += 1; maxInside = max(maxInside, inside) } }
        func leave() { lock.withLock { inside -= 1 } }
      }
      let access = SerialAccess(Probe(), label: "taby.checks.serial")
      let results = await withThrowingTaskGroup(of: Int.self) { group in
        for i in 0..<200 {
          group.addTask {
            try await access.run { p in
              p.enter()
              usleep(200)
              p.leave()
              if i % 50 == 0 { throw CalendarError.invalid("absichtlich") }
              return i
            }
          }
        }
        var sum = 0, errors = 0
        while let r = await group.nextResult() {
          switch r { case .success(let v): sum += v; case .failure: errors += 1 }
        }
        return (sum, errors)
      }
      let (maxInside, calls) = try await access.run { ($0.maxInside, $0.calls) }
      try expectEqual(calls, 200)
      try expectEqual(maxInside, 1, "Aufrufe dürfen sich nie überlappen")
      try expectEqual(results.1, 4, "Fehler werden durchgereicht")
      try expectEqual(results.0, (0..<200).filter { $0 % 50 != 0 }.reduce(0, +))
    },
  ] + CalDAVChecks.cases + MicrosoftChecks.cases + MicrosoftCalendarChecks.cases + SpotifyChecks.cases)

}
