// Prüfungen für den CalDAV-Anbieter. HTTP über CalendarStubURLProtocol (kein echtes Netz).
// Das Passwort hier ist ein Testwert ohne Bezug zu einem Konto.
import Foundation

private final class TextBox: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  func set(_ s: String) { lock.withLock { text = s } }
  var value: String { lock.withLock { text } }
}

enum CalDAVChecks {
  static let user = "felix@example.test"
  static let password = "test-app-passwort-123"
  static let basic = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
  static let root = "https://cal.example.test/"
  static let principal = "https://cal.example.test/principal/"
  static let home = "https://cal.example.test/cal/home/"
  static let work = "https://cal.example.test/cal/home/work/"

  static var cfgRoot: [String: JSONValue] { ["url": .string(root), "user": .string(user)] }
  static var cfgCollection: [String: JSONValue] { ["url": .string(work), "user": .string(user)] }

  /// Anfragetext: URLSession reicht ihn an URLProtocol oft als Stream weiter.
  static func bodyText(_ req: URLRequest) -> String {
    if let d = req.httpBody { return String(decoding: d, as: UTF8.self) }
    guard let stream = req.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var d = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let n = stream.read(&buf, maxLength: buf.count)
      if n <= 0 { break }
      d.append(contentsOf: buf[0..<n])
    }
    return String(decoding: d, as: UTF8.self)
  }

  static func xml(_ body: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?>" + body).utf8) }

  static let rootXML = xml(#"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal></d:prop></d:propstat></d:response></d:multistatus>"#)

  static let principalXML = xml(#"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/principal/</d:href><d:propstat><d:prop><d:resourcetype/><c:calendar-home-set><d:href>/cal/home/</d:href></c:calendar-home-set></d:prop></d:propstat></d:response></d:multistatus>"#)

  static let homeXML = xml(#"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/cal/home/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response><d:response><d:href>/cal/home/work/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Arbeit</d:displayname></d:prop></d:propstat></d:response><d:response><d:href>/cal/home/private/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Privat</d:displayname></d:prop></d:propstat></d:response></d:multistatus>"#)

  static let selfXML = xml(#"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/cal/home/work/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Arbeit</d:displayname></d:prop></d:propstat></d:response></d:multistatus>"#)

  static let reportXML = xml(#"""
    <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/cal/home/work/uid-1.ics</d:href><d:propstat><d:prop><d:getetag>"etag-1"</d:getetag><c:calendar-data><![CDATA[BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:uid-1
    DTSTART:20261016T090000Z
    DTEND:20261016T100000Z
    SUMMARY:Arbeit\, Planung
    END:VEVENT
    END:VCALENDAR
    ]]></c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
    """#)

  static var cases: [CheckCase] { [
    CheckCase("CalDAV: Discovery (Principal → Kalender-Home → erster Kalender), dann REPORT mit Zeitraum") {
      let session = CalendarStubURLProtocol.session { req, _ in
        let url = req.url!.absoluteString
        let method = req.httpMethod ?? ""
        if method == "PROPFIND" && url == root { return (207, rootXML) }
        if method == "PROPFIND" && url == principal { return (207, principalXML) }
        if method == "PROPFIND" && url == home { return (207, homeXML) }
        if method == "REPORT" && url == work { return (207, reportXML) }
        return (404, Data())
      }
      let p = try CalDAVProvider(id: "caldav:1", config: cfgRoot, password: password, session: session)
      let events = try await p.listEvents(from: "2026-10-01", to: "2026-11-01")
      try expectEqual(events.map(\.id), ["uid-1"])
      try expectEqual(events[0].title, "Arbeit, Planung")
      try expectEqual(events[0].sourceId, "caldav:1")
      try expect(!events[0].readOnly, "CalDAV-Termine sind beschreibbar")
      let reqs = CalendarStubURLProtocol.requests
      try expectEqual(reqs.map(\.method), ["PROPFIND", "PROPFIND", "PROPFIND", "REPORT"])
      try expectEqual(reqs.map(\.url), [root, principal, home, work])
      try expect(reqs.allSatisfy { $0.headers["Authorization"] == basic }, "Basic-Auth auf jeder Anfrage")
      try expectEqual(reqs[0].headers["Depth"], "0")
      try expectEqual(reqs[2].headers["Depth"], "1")
      try expectEqual(reqs[3].headers["Depth"], "1")
    },

    CheckCase("CalDAV: Antwort wird nach Zeitraum gefiltert und Discovery bleibt zwischengespeichert") {
      let session = CalendarStubURLProtocol.session { req, _ in
        let url = req.url!.absoluteString
        if req.httpMethod == "PROPFIND" && url == work { return (207, selfXML) }
        if req.httpMethod == "REPORT" && url == work { return (207, reportXML) }
        return (404, Data())
      }
      let p = try CalDAVProvider(id: "caldav:1", config: cfgCollection, password: password, session: session)
      let late = try await p.listEvents(from: "2027-01-01", to: "2027-02-01")
      try expect(late.isEmpty, "Termin liegt außerhalb des Zeitraums")
      _ = try await p.listEvents(from: "2026-10-01", to: "2026-11-01")
      let methods = CalendarStubURLProtocol.requests.map(\.method)
      try expectEqual(methods, ["PROPFIND", "REPORT", "REPORT"], "Kalenderadresse nur einmal gesucht")
    },

    CheckCase("CalDAV: Anlegen per PUT (UID, Zeiten in UTC, Escapes) und Löschen per DELETE") {
      let put = TextBox()
      let session = CalendarStubURLProtocol.session { req, _ in
        let url = req.url!.absoluteString
        if req.httpMethod == "PROPFIND" && url == work { return (207, selfXML) }
        if req.httpMethod == "PUT" {
          put.set(bodyText(req))
          return (201, Data())
        }
        if req.httpMethod == "DELETE" { return (204, Data()) }
        return (404, Data())
      }
      let p = try CalDAVProvider(id: "caldav:1", config: cfgCollection, password: password, session: session,
                                 newUID: { "uid-new" })
      let created = try await p.createEvent(NewEvent(title: "Teststunde", start: "2026-10-16T09:00",
                                                     end: "2026-10-16T10:00", notes: "Zeile; eins"))
      try expectEqual(created.id, "uid-new")
      try expectEqual(created.start, "2026-10-16T09:00")
      let body = put.value
      try expect(body.contains("UID:uid-new"), "UID im Termin")
      try expect(body.contains("SUMMARY:Teststunde"))
      try expect(body.contains("DESCRIPTION:Zeile\\; eins"), "Semikolon wird escaped")
      let back = ICSParser.parseEvents(body, sourceId: "x")
      try expectEqual(back.first?.start, "2026-10-16T09:00", "Zeiten kommen beim Zurücklesen unverändert an")
      try expectEqual(back.first?.end, "2026-10-16T10:00")
      let reqs = CalendarStubURLProtocol.requests
      let putReq = try expectNotNil(reqs.first { $0.method == "PUT" })
      try expectEqual(putReq.url, work + "uid-new.ics")
      try expectEqual(putReq.headers["If-None-Match"], "*")
      try expectEqual(putReq.headers["Content-Type"], "text/calendar; charset=utf-8")
      try expect(body.range(of: #"DTSTART:\d{8}T\d{6}Z"#, options: .regularExpression) != nil, "DTSTART in UTC")
      try await p.deleteEvent(id: "uid-new")
      let del = try expectNotNil(CalendarStubURLProtocol.requests.last)
      try expectEqual(del.method, "DELETE")
      try expectEqual(del.url, work + "uid-new.ics")
    },

    CheckCase("CalDAV: 401 wird als „Benutzername oder App-Passwort falsch“ gemeldet, ohne Passwort im Text") {
      let session = CalendarStubURLProtocol.session { _, _ in (401, Data()) }
      let p = try CalDAVProvider(id: "caldav:1", config: cfgRoot, password: password, session: session)
      let h = await p.healthCheck()
      try expect(!h.ok)
      try expectEqual(h.message, "Benutzername oder App-Passwort falsch")
      try expect(!(h.message ?? "").contains(password), "Passwort taucht nie im Fehlertext auf")
    },

    CheckCase("CalDAV: Statuscodes werden auf deutsche Fehlertexte abgebildet") {
      try expect(CalDAVProvider.statusError(207) == nil && CalDAVProvider.statusError(201) == nil)
      try expectEqual(CalDAVProvider.statusError(403), CalendarError.unreachable("Zugriff verweigert (403): Das Konto darf diesen Kalender nicht nutzen"))
      let m404 = CalDAVProvider.statusError(404).map { CalendarSupport.message(for: $0) } ?? ""
      try expect(m404.contains("404") && m404.contains("Adresse"))
      let m500 = CalDAVProvider.statusError(500).map { CalendarSupport.message(for: $0) } ?? ""
      try expect(m500.contains("500"))
    },

    CheckCase("CalDAV: http wird abgelehnt, localhost bleibt erlaubt, nichts geht ins Netz") {
      try expect(CalDAVProvider.addressProblem("http://cal.example.test/") != nil)
      try expect(CalDAVProvider.addressProblem("https://cal.example.test/") == nil)
      try expect(CalDAVProvider.addressProblem("http://localhost:8080/dav/") == nil)
      try expect(CalDAVProvider.addressProblem("kein url") != nil)
      let p = try? CalDAVProvider(id: "c", config: ["url": .string("http://cal.example.test/"), "user": .string(user)],
                                  password: password)
      try expect(p == nil, "http-Adresse wird nicht gebaut")
      let h = await CalDAVProvider.testConnection(url: "http://cal.example.test/", user: user, password: password)
      try expect(!h.ok && (h.message ?? "").contains("https://"))
      let local = try? CalDAVProvider(id: "c", config: ["url": .string("http://localhost:8080/"), "user": .string(user)],
                                      password: password)
      try expect(local != nil, "localhost über http ist erlaubt")
    },

    CheckCase("CalDAV: Passwort geht nie an einen fremden Host (Discovery-Adresse in der Antwort)") {
      let evilRoot = xml(#"<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:current-user-principal><d:href>https://evil.example.test/principal/</d:href></d:current-user-principal></d:prop></d:propstat></d:response></d:multistatus>"#)
      let session = CalendarStubURLProtocol.session { req, _ in
        if req.httpMethod == "PROPFIND" && req.url?.absoluteString == root { return (207, evilRoot) }
        return (404, Data())
      }
      let p = try CalDAVProvider(id: "caldav:1", config: cfgRoot, password: password, session: session)
      var succeeded = false
      do {
        _ = try await p.listEvents(from: "2026-10-01", to: "2026-11-01")
        succeeded = true
      } catch {
        // erwartet: Abbruch vor der Anfrage an die fremde Adresse
      }
      try expect(!succeeded, "fremde Adresse hätte abgebrochen werden müssen")
      let hosts = CalendarStubURLProtocol.requests.compactMap { URL(string: $0.url)?.host }
      try expect(!hosts.contains("evil.example.test"), "keine Anfrage an den fremden Host")
      try expect(CalendarStubURLProtocol.requests.allSatisfy { $0.headers["Authorization"] == basic },
                 "Basic-Auth nur auf dem konfigurierten Host")
    },
    CheckCase("CalDAV: Gleiche Adresse heißt gleiches Schema, Host und Port") {
      let base = try CalDAVProvider.checkedURL("https://cal.example.test/dav/")
      try expect(CalDAVProvider.sameOrigin(URL(string: "https://cal.example.test/other/x.ics"), base))
      try expect(CalDAVProvider.sameOrigin(URL(string: "https://CAL.example.test:443/x"), base), "Standardport 443")
      try expect(!CalDAVProvider.sameOrigin(URL(string: "https://evil.example.test/"), base))
      try expect(!CalDAVProvider.sameOrigin(URL(string: "https://cal.example.test:8443/"), base), "anderer Port")
      try expect(!CalDAVProvider.sameOrigin(URL(string: "http://cal.example.test/"), base), "anderes Schema")
      try expect(!CalDAVProvider.sameOrigin(nil, base))
    },
    CheckCase("CalDAV: Registry baut Cache-Provider mit Passwort aus dem Schlüsselbund, sonst „nicht erreichbar“") {
      let cfg = CalendarSourceConfig(id: "caldav:1", kind: .caldav, config: cfgRoot)
      let ok = CalendarRegistry.makeProvider(cfg, deps: CalendarRegistryDeps(caldavPassword: { _ in password }))
      try expect(ok is CachingCalendarProvider, "CalDAV läuft über den Cache")
      try expectEqual(ok.kind, .caldav)
      let missing = CalendarRegistry.makeProvider(cfg, deps: CalendarRegistryDeps())
      let h = await missing.healthCheck()
      try expect(!h.ok && (h.message ?? "").contains("App-Passwort"))
    },
  ] }
}
