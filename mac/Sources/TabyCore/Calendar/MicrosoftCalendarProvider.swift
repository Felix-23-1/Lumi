// Outlook-Kalender über Microsoft Graph (Kalenderansicht, Anlegen, Löschen, Verschieben).
//
// Lesen: GET /me/calendarView mit UTC-Zeitraum und `Prefer: outlook.timezone=<Systemzone>`.
// Die Zeiten kommen in der Systemzone; falls Graph eine andere Zone meldet, wird umgerechnet.
// Seitenweise über `@odata.nextLink` (höchstens 5 Seiten = 500 Termine); nur auf graph.microsoft.com.
// Mehr als 500 Termine: es kommt, was gelesen wurde, und die Quelle meldet „Zeitraum verkleinern“.
// Abgesagte Termine fehlen. Wiederkehrende Termine kommt expandiert aus der Kalenderansicht.
// Schreiben: POST /me/events, PATCH /me/events/{id}, DELETE /me/events/{id}.
// Die Anmeldung und die Erneuerung liegen in MicrosoftAuth; hier nur die Termine.
//
// shortcut: Teilnahme-Antworten, Erinnerungen und Anhänge fehlen, Upgrade bei Bedarf.
import Foundation

public final class MicrosoftCalendarProvider: CalendarProvider {
  public let id: String
  public let kind: CalendarSourceKind = .microsoft
  public var canWrite: Bool { true }

  static let maxPages = 5
  static let pageSize = 100
  static let truncatedText = "mehr als 500 Termine, Zeitraum verkleinern"
  /// Windows-Zonennamen, wie Graph sie ohne Prefer-Kopf liefert.
  static let windowsZones: [String: String] = [
    "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
    "Romance Standard Time": "Europe/Paris", "GMT Standard Time": "Europe/London", "UTC": "UTC",
    "Pacific Standard Time": "America/Los_Angeles", "Eastern Standard Time": "America/New_York",
  ]

  private let auth: MicrosoftAuth
  private let clock: Clock
  private let zone: TimeZone
  private let lock = NSLock()
  /// Ob die letzte Abfrage bei der Seitengrenze abbrach (nur im Speicher; zeigt die Quelle an).
  private var truncated = false

  public init(id: String, auth: MicrosoftAuth, clock: Clock = SystemClock(), zone: TimeZone = .current) {
    self.id = id
    self.auth = auth
    self.clock = clock
    self.zone = zone
  }

  // MARK: - Termine

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    try await mapped {
      var url: URL? = try Self.calendarViewURL(from: from, to: to, zone: self.zone)
      var events: [CalendarEvent] = []
      for _ in 0..<Self.maxPages {
        guard let page = url else { break }
        let (data, _) = try await self.auth.graph("GET", page, headers: ["Prefer": "outlook.timezone=\"\(self.zone.identifier)\""])
        let json = MicrosoftHTTP.json(data)
        for raw in (json?["value"] as? [[String: Any]]) ?? [] {
          if let e = self.event(raw) { events.append(e) }
        }
        url = try Self.nextLink(json)
      }
      let more = url != nil
      self.lock.withLock { self.truncated = more }
      if more { TabyLog.info(.calendar, "Outlook: \(Self.truncatedText) (\(self.id))") }
      return events.filter { CalendarSupport.inRange($0, from: from, to: to) }
    }
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    try await mapped {
      let body = try Self.eventBody(e, zone: self.zone)
      let (data, _) = try await self.auth.graph("POST", MicrosoftAuth.graphURL("me/events"), body: body)
      guard let eid = MicrosoftHTTP.json(data)?["id"] as? String else {
        throw CalendarError.unreachable("Microsoft hat den Termin nicht bestätigt.")
      }
      return CalendarEvent(id: eid, sourceId: self.id, title: e.title, start: e.start, end: e.end,
                           allDay: !e.start.contains("T"), notes: e.notes, readOnly: false)
    }
  }

  /// Termin ändern (Zeit, Titel, Notiz) per PATCH. Nicht Teil des Protokolls; für spätere Oberfläche.
  public func moveEvent(id eventId: String, to e: NewEvent) async throws {
    try await mapped {
      let body = try Self.eventBody(e, zone: self.zone)
      _ = try await self.auth.graph("PATCH", MicrosoftAuth.graphURL("me/events/" + MicrosoftAuth.segment(eventId)), body: body)
    }
  }

  public func deleteEvent(id eventId: String) async throws {
    try await mapped {
      _ = try await self.auth.graph("DELETE", MicrosoftAuth.graphURL("me/events/" + MicrosoftAuth.segment(eventId)))
    }
  }

  public func healthCheck() async -> HealthResult {
    do {
      _ = try await auth.graph("GET", MicrosoftAuth.graphURL("me", query: [URLQueryItem(name: "$select", value: "id")]))
      return HealthResult(ok: true, message: lock.withLock { truncated } ? Self.truncatedText : nil)
    } catch {
      return HealthResult(ok: false, message: (error as? MicrosoftFailure)?.message ?? CalendarSupport.message(for: error))
    }
  }

  // MARK: - Abbildung

  /// Graph-Termin → Lumi-Termin; abgesagte und ungültige Einträge fallen weg.
  func event(_ raw: [String: Any]) -> CalendarEvent? {
    if raw["isCancelled"] as? Bool == true { return nil }
    guard let eid = raw["id"] as? String else { return nil }
    let allDay = raw["isAllDay"] as? Bool ?? false
    guard let start = localValue(raw["start"], allDay: allDay), let end = localValue(raw["end"], allDay: allDay) else {
      return nil
    }
    let subject = (raw["subject"] as? String) ?? ""
    let link = (raw["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String
    return CalendarEvent(id: eid, sourceId: id, title: subject.isEmpty ? "(ohne Titel)" : subject,
                         start: start, end: end, allDay: allDay, notes: link.map { "Teams: \($0)" }, readOnly: false)
  }

  /// `{dateTime, timeZone}` → lokale, zonenlose Zeit. Ganztägig bleibt das Datum.
  func localValue(_ raw: Any?, allDay: Bool) -> String? {
    guard let part = raw as? [String: Any], let text = part["dateTime"] as? String else { return nil }
    if allDay { return String(text.prefix(10)) }
    let source = Self.sourceZone(part["timeZone"] as? String, requested: zone)
    guard let date = Self.date(text, zone: source) else { return nil }
    return Self.formatter("yyyy-MM-dd'T'HH:mm", zone: zone).string(from: date)
  }

  /// Zone einer Graph-Zeit. Hat Graph die angefragte Zone geliefert, gilt sie; sonst umrechnen
  /// (Windows-Namen werden abgebildet). Unbekannt: UTC, mit Protokollzeile.
  static func sourceZone(_ name: String?, requested: TimeZone) -> TimeZone {
    guard let name, name != requested.identifier else { return requested }
    if let zone = TimeZone(identifier: windowsZones[name] ?? name) { return zone }
    TabyLog.info(.calendar, "Outlook: unbekannte Zone „\(name)“, Zeit wird als UTC gelesen")
    return TimeZone(identifier: "UTC")!
  }

  static func nextLink(_ json: [String: Any]?) throws -> URL? {
    guard let raw = json?["@odata.nextLink"] as? String, let url = URL(string: raw) else { return nil }
    guard url.scheme?.lowercased() == "https", url.host?.lowercased() == MicrosoftHTTP.graphHost else {
      throw CalendarError.unreachable("Microsoft: Der Server verweist auf eine fremde Adresse. Abgebrochen.")
    }
    return url
  }

  static func calendarViewURL(from: String, to: String, zone: TimeZone) throws -> URL {
    guard let start = date(from, zone: zone), let end = date(to, zone: zone) else {
      throw CalendarError.invalid("Ungültiger Zeitraum für Outlook")
    }
    let utc = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'", zone: TimeZone(identifier: "UTC")!)
    return MicrosoftAuth.graphURL("me/calendarView", query: [
      URLQueryItem(name: "startDateTime", value: utc.string(from: start)),
      URLQueryItem(name: "endDateTime", value: utc.string(from: end)),
      URLQueryItem(name: "$top", value: "\(pageSize)"),
      URLQueryItem(name: "$select", value: "id,subject,start,end,isAllDay,isCancelled,onlineMeeting"),
    ])
  }

  /// Lokaler Schreibwunsch → Graph-Körper. Ohne Ende: eine Stunde bzw. ein Tag.
  static func eventBody(_ e: NewEvent, zone: TimeZone) throws -> Data {
    let allDay = !e.start.contains("T")
    guard let start = date(e.start, zone: zone) else { throw CalendarError.invalid("Ungültiges Datum: \(e.start)") }
    var end = e.end.flatMap { date($0, zone: zone) } ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
    // Graph verlangt bei ganztägigen Terminen ein exklusives Ende: gleich dem Beginn wird ein Tag daraus.
    if allDay && end <= start { end = start.addingTimeInterval(86_400) }
    let out = formatter("yyyy-MM-dd'T'HH:mm:ss", zone: zone)
    var body: [String: Any] = [
      "subject": e.title,
      "isAllDay": allDay,
      "start": ["dateTime": out.string(from: start), "timeZone": zone.identifier],
      "end": ["dateTime": out.string(from: end), "timeZone": zone.identifier],
    ]
    if let notes = e.notes, !notes.isEmpty { body["body"] = ["contentType": "text", "content": notes] }
    return try JSONSerialization.data(withJSONObject: body)
  }

  /// "YYYY-MM-DD" oder "YYYY-MM-DDTHH:mm[:ss]" in `zone` → Date.
  static func date(_ local: String, zone: TimeZone) -> Date? {
    if local.count >= 16 {
      return formatter("yyyy-MM-dd'T'HH:mm", zone: zone).date(from: String(local.prefix(16)))
    }
    return formatter("yyyy-MM-dd", zone: zone).date(from: String(local.prefix(10)))
  }

  /// Je Aufruf ein Formatierer (kein geteilter DateFormatter, Nebenläufigkeit).
  static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.dateFormat = format
    return f
  }

  /// Fehler des Anmeldens und der Graph-Aufrufe werden zu Kalenderfehlern mit demselben Text.
  private func mapped<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let f as MicrosoftFailure {
      throw CalendarError.unreachable(f.message)
    }
  }
}
