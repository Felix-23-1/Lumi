// CalDAV-Kalender (Nextcloud, iCloud, Google mit App-Passwort).
//
// Discovery: PROPFIND (Depth 0) auf die Adresse. Ist sie selbst ein Kalender,
// wird sie genutzt; sonst current-user-principal → calendar-home-set → Kalender
// auflisten (Depth 1). `config["calendar"]` wählt einen Kalender nach Name.
// Lesen: REPORT calendar-query mit time-range, VEVENTs über ICSParser.
// Schreiben: PUT <uid>.ics (If-None-Match: *), Löschen: DELETE (If-Match mit ETag).
// Basic-Auth mit App-Passwort. Nur HTTPS, http nur für localhost. Das Passwort
// kommt aus dem Schlüsselbund und wird nie in Logs oder Fehlertexte übernommen.
//
// shortcut: wiederkehrende Termine erscheinen nur mit dem ersten Vorkommen
// (kein calendar-query expand), upgrade: <C:expand> mit eigener Id je Vorkommen.
import Foundation

/// Folgt Weiterleitungen nur zur selben Adresse. Andere Ziele werden nicht aufgerufen (die Weiterleitung
/// bleibt das Ergebnis und wird als Fehler gemeldet), damit Basic-Auth nie an einen fremden Host geht.
final class SameOriginRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let base: URL

  init(base: URL) { self.base = base }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(CalDAVProvider.sameOrigin(request.url, base) ? request : nil)
  }
}

public final class CalDAVProvider: CalendarProvider {
  public let id: String
  public let kind: CalendarSourceKind = .caldav
  public var canWrite: Bool { true }

  private let base: URL
  private let auth: String
  private let calendarName: String?
  private let session: URLSession
  private let clock: Clock
  private let newUID: () -> String
  private let lock = NSLock()
  private var collection: URL?
  /// UID → Adresse und ETag aus der letzten Lesung oder dem Anlegen, für DELETE.
  private var resources: [String: (href: URL, etag: String?)] = [:]

  /// Wirft `CalendarError.invalid`, wenn Adresse, Benutzer oder Passwort fehlen oder die Adresse nicht HTTPS ist.
  public init(id: String, config: [String: JSONValue], password: String?, session: URLSession = .shared,
              clock: Clock = SystemClock(), newUID: @escaping () -> String = { UUID().uuidString }) throws {
    let raw = config["url"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !raw.isEmpty else { throw CalendarError.invalid("CalDAV-Quelle benötigt eine Adresse (config.url)") }
    base = try Self.checkedURL(raw)
    let user = config["user"]?.stringValue ?? ""
    guard !user.isEmpty, let password, !password.isEmpty else {
      throw CalendarError.invalid("CalDAV-Quelle benötigt Benutzername und App-Passwort")
    }
    auth = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    calendarName = config["calendar"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    self.id = id
    self.session = session
    self.clock = clock
    self.newUID = newUID
  }

  /// „Verbindung testen“ im Formular, bevor eine Quelle gespeichert wird.
  public static func testConnection(url: String, user: String, password: String,
                                    session: URLSession = .shared) async -> HealthResult {
    do {
      let p = try CalDAVProvider(id: "caldav-test", config: ["url": .string(url), "user": .string(user)],
                                 password: password, session: session)
      return await p.healthCheck()
    } catch {
      return HealthResult(ok: false, message: CalendarSupport.message(for: error))
    }
  }

  /// Fehlertext für die Oberfläche ohne Netzwerk (nil = Adresse passt).
  public static func addressProblem(_ raw: String) -> String? {
    do { _ = try checkedURL(raw.trimmingCharacters(in: .whitespaces)); return nil }
    catch { return CalendarSupport.message(for: error) }
  }

  static func checkedURL(_ raw: String) throws -> URL {
    guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty
    else { throw CalendarError.invalid("CalDAV-Adresse ist ungültig") }
    let isLocal = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    guard scheme == "https" || (scheme == "http" && isLocal) else {
      throw CalendarError.invalid("CalDAV-Adresse muss mit https:// beginnen (http nur für localhost)")
    }
    return u
  }

  // MARK: HTTP

  private func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) async throws
    -> (Data, HTTPURLResponse)
  {
    _ = try Self.checkedURL(url.absoluteString)  // auch Serveradressen aus Antworten nur über HTTPS
    // Das Passwort (Basic-Auth) geht nur an den konfigurierten Server, nie an Adressen aus Antworten.
    guard Self.sameOrigin(url, base) else {
      throw CalendarError.invalid("CalDAV: Der Server verweist auf eine andere Adresse. Abgebrochen.")
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 20
    req.setValue(auth, forHTTPHeaderField: "Authorization")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    do {
      let (data, resp) = try await session.data(for: req, delegate: SameOriginRedirectGuard(base: base))
      guard let http = resp as? HTTPURLResponse else { throw CalendarError.unreachable("CalDAV: keine HTTP-Antwort") }
      if let err = Self.statusError(http.statusCode) { throw err }
      return (data, http)
    } catch let e as URLError {
      if e.code == .timedOut { throw CalendarError.unreachable("CalDAV-Server antwortet nicht (Zeitüberschreitung)") }
      throw CalendarError.unreachable("CalDAV-Server nicht erreichbar (\(e.code.rawValue))")
    }
  }

  /// Gleiche Adresse: Schema, Host und Port. Nur dorthin darf das Passwort.
  static func sameOrigin(_ url: URL?, _ base: URL) -> Bool {
    guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
          scheme == base.scheme?.lowercased(), host == base.host?.lowercased() else { return false }
    return port(url) == port(base)
  }

  private static func port(_ u: URL) -> Int {
    u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
  }

  static func statusError(_ code: Int) -> CalendarError? {
    switch code {
    case 200..<300: return nil
    case 401: return .unreachable("Benutzername oder App-Passwort falsch")
    case 403: return .unreachable("Zugriff verweigert (403): Das Konto darf diesen Kalender nicht nutzen")
    case 404: return .unreachable("CalDAV-Adresse nicht gefunden (404). Bitte die Adresse prüfen.")
    case 412: return .unreachable("Der Server hat die Änderung abgelehnt (412). Bitte aktualisieren.")
    default: return .unreachable("CalDAV-Server meldet Fehler (\(code))")
    }
  }

  // MARK: Discovery

  private static let propBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop><D:resourcetype/><D:displayname/><D:current-user-principal/><C:calendar-home-set/></D:prop>
    </D:propfind>
    """

  private func propfind(_ url: URL, depth: Int) async throws -> [DavResponse] {
    let (data, _) = try await send("PROPFIND", url,
                                   headers: ["Depth": "\(depth)", "Content-Type": "application/xml; charset=utf-8"],
                                   body: Data(Self.propBody.utf8))
    return try DavParser.parse(data, base: url)
  }

  private func collectionURL() async throws -> URL {
    if let c = lock.withLock({ collection }) { return c }
    let found = try await discover()
    lock.withLock { collection = found }
    return found
  }

  private func discover() async throws -> URL {
    guard let me = try await propfind(base, depth: 0).first else {
      throw CalendarError.unreachable("CalDAV: leere Antwort beim Suchen des Kalenders")
    }
    if me.isCalendar { return base }
    var home = me.homeSet
    if home == nil, let principal = me.principal {
      home = try await propfind(principal, depth: 0).first?.homeSet
    }
    guard let home else { throw CalendarError.invalid("Unter dieser Adresse wurde kein Kalender gefunden") }
    let calendars = try await propfind(home, depth: 1).filter(\.isCalendar)
    if let name = calendarName {
      guard let c = calendars.first(where: { $0.displayName == name }), let href = c.href else {
        throw CalendarError.invalid("Kalender „\(name)“ nicht gefunden")
      }
      return href
    }
    guard let href = calendars.first?.href else { throw CalendarError.invalid("Im Konto gibt es keinen Kalender") }
    return href
  }

  // MARK: Termine

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    let col = try await collectionURL()
    let body = Self.reportBody(from: from, to: to)
    let (data, _) = try await send("REPORT", col, headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
                                   body: Data(body.utf8))
    var events: [CalendarEvent] = []
    for r in try DavParser.parse(data, base: col) {
      guard let ics = r.calendarData, let href = r.href else { continue }
      for var e in ICSParser.parseEvents(ics, sourceId: id) {
        e.readOnly = false
        lock.withLock { resources[e.id] = (href, r.etag) }
        events.append(e)
      }
    }
    return events.filter { CalendarSupport.inRange($0, from: from, to: to) }
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    let col = try await collectionURL()
    let uid = newUID()
    let ics = try Self.icsBody(uid: uid, e, now: clock.now())
    let href = col.appendingPathComponent(uid + ".ics")
    let (_, resp) = try await send("PUT", href,
                                   headers: ["Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"],
                                   body: Data(ics.utf8))
    lock.withLock { resources[uid] = (href, resp.value(forHTTPHeaderField: "ETag")) }
    return CalendarEvent(id: uid, sourceId: id, title: e.title, start: e.start, end: e.end,
                         allDay: !e.start.contains("T"), notes: e.notes, readOnly: false)
  }

  public func deleteEvent(id uid: String) async throws {
    let known = lock.withLock { resources[uid] }
    let href: URL
    if let known { href = known.href } else { href = try await collectionURL().appendingPathComponent(uid + ".ics") }
    var headers: [String: String] = [:]
    if let etag = known?.etag { headers["If-Match"] = etag }
    _ = try await send("DELETE", href, headers: headers)
    lock.withLock { resources[uid] = nil }
  }

  public func healthCheck() async -> HealthResult {
    do {
      _ = try await collectionURL()
      return HealthResult(ok: true)
    } catch {
      return HealthResult(ok: false, message: CalendarSupport.message(for: error))
    }
  }

  // MARK: Zeit und Formate

  /// Lokales Datum oder Zeit („YYYY-MM-DD“ bzw. „YYYY-MM-DDTHH:mm“) → Date in der Systemzone.
  static func localDate(_ s: String) -> Date? {
    let day = s.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard day.count == 3 else { return nil }
    let time = s.count >= 16 ? s.dropFirst(11).prefix(5).split(separator: ":").compactMap { Int($0) } : [0, 0]
    guard time.count == 2 else { return nil }
    return CalendarSupport.date(year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1], second: 0,
                                in: TimeZone.current)
  }

  static func utcStamp(_ d: Date) -> String {
    let f = DateFormatter()  // je Aufruf: kein geteilter DateFormatter (Nebenläufigkeit)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: d)
  }

  static func reportBody(from: String, to: String) -> String {
    let start = localDate(from).map(utcStamp) ?? ""
    let end = localDate(to).map(utcStamp) ?? ""
    return """
      <?xml version="1.0" encoding="utf-8"?>
      <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:prop><D:getetag/><C:calendar-data/></D:prop>
        <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
          <C:time-range start="\(start)" end="\(end)"/>
        </C:comp-filter></C:comp-filter></C:filter>
      </C:calendar-query>
      """
  }

  static func icsBody(uid: String, _ e: NewEvent, now: Date) throws -> String {
    var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Lumi//CalDAV//DE", "BEGIN:VEVENT",
                 "UID:\(uid)", "DTSTAMP:\(utcStamp(now))", "SUMMARY:\(escape(e.title))"]
    lines.append(try dateLine("DTSTART", e.start))
    if let end = e.end, !end.isEmpty { lines.append(try dateLine("DTEND", end)) }
    if let notes = e.notes, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  /// Ganztägig als VALUE=DATE, sonst UTC (damit jeder CalDAV-Server die Zeit richtig liest).
  static func dateLine(_ name: String, _ local: String) throws -> String {
    guard let date = localDate(local) else { throw CalendarError.invalid("Ungültiges Datum: \(local)") }
    if !local.contains("T") {
      return "\(name);VALUE=DATE:" + local.prefix(10).replacingOccurrences(of: "-", with: "")
    }
    return "\(name):\(utcStamp(date))"
  }

  static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "\\n")
  }
}

/// Eine Antwort eines Multistatus (PROPFIND/REPORT), nur die gebrauchten Felder.
struct DavResponse {
  var href: URL?
  var isCalendar = false
  var displayName: String?
  var etag: String?
  var principal: URL?
  var homeSet: URL?
  var calendarData: String?
}

/// Minimaler Multistatus-Leser (XMLParser mit Namensräumen; nur Lokalnamen zählen).
private final class DavParser: NSObject, XMLParserDelegate {
  private let base: URL
  private var responses: [DavResponse] = []
  private var current: DavResponse?
  private var stack: [String] = []
  private var text = ""

  private init(base: URL) { self.base = base }

  static func parse(_ data: Data, base: URL) throws -> [DavResponse] {
    let d = DavParser(base: base)
    let p = XMLParser(data: data)
    p.shouldProcessNamespaces = true
    p.delegate = d
    guard p.parse() else { throw CalendarError.unreachable("CalDAV: Antwort ist kein gültiges XML") }
    return d.responses
  }

  private func resolve(_ raw: String) -> URL? { URL(string: raw, relativeTo: base)?.absoluteURL }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
    let parent = stack.last ?? ""
    stack.append(elementName)
    text = ""
    if elementName == "response" { current = DavResponse() }
    if elementName == "calendar" && parent == "resourcetype" { current?.isCalendar = true }
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
    stack.removeLast()
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "href":
      if parent == "current-user-principal" { current?.principal = resolve(value) }
      else if parent == "calendar-home-set" { current?.homeSet = resolve(value) }
      else if parent == "response" { current?.href = resolve(value) }
    case "displayname": current?.displayName = value
    case "getetag": current?.etag = value
    case "calendar-data": current?.calendarData = text
    case "response":
      if let c = current { responses.append(c) }
      current = nil
    default: break
    }
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    text += String(decoding: CDATABlock, as: UTF8.self)
  }
}
