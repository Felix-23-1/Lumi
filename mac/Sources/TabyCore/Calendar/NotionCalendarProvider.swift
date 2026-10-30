// Notion-Datenbank als Kalender (Port von src/main/calendar/notion.ts).
//
// Notion-API-Version **2026-03-11** (live geprüft am 2026-10-11 auf
// developers.notion.com: neueste Version; gegenüber 2025-09-03 nur
// `archived`→`in_trash`, Block-`position` und `transcription`→`meeting_notes`
// geändert — nichts davon betrifft diese Endpunkte). Seiten hängen an einer
// „Data Source“, nicht direkt an der Database, darum zweistufig:
//   1) GET  /v1/databases/{database_id}       → data_sources[0].id
//   2) POST /v1/data_sources/{id}/query       → Seiten (paginiert, Datumsfilter)
//   Schreiben: POST /v1/pages mit parent {type: data_source_id}.
// Fehlerform: {"object":"error","status":401,"code":"…","message":"…"}.
//
// Konfiguration: databaseId, titleField (Standard "Name"), startField
// (Standard "Datum"), optional endField. Der Token wird separat übergeben
// (Schlüsselbund, nie in Konfiguration/Logs); `config["token"]` wird nur als
// Rückfall gelesen. Getestet nur gegen gestubbtes HTTP (URLProtocol).
import Foundation

public final class NotionCalendarProvider: CalendarProvider {
  public static let apiVersion = "2026-03-11"
  static let baseURL = "https://api.notion.com/v1"

  public let id: String
  public let kind: CalendarSourceKind = .notion
  public var canWrite: Bool { true }

  let databaseId: String
  private let token: String
  let titleField: String
  let startField: String
  let endField: String?
  private let session: URLSession

  /// Wirft `CalendarError.invalid`, wenn databaseId oder Token fehlen.
  public init(id: String, config: [String: JSONValue], token: String? = nil, session: URLSession = .shared) throws {
    let db = config["databaseId"]?.stringValue ?? ""
    let tok = token ?? config["token"]?.stringValue ?? ""
    guard !db.isEmpty, !tok.isEmpty else {
      throw CalendarError.invalid("Notion-Quelle benötigt Datenbank-ID und Token")
    }
    self.id = id
    self.databaseId = db
    self.token = tok
    self.titleField = config["titleField"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Name"
    self.startField = config["startField"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Datum"
    self.endField = config["endField"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    self.session = session
  }

  private func request(_ path: String, method: String = "GET", body: JSONValue? = nil) -> URLRequest {
    var req = URLRequest(url: URL(string: Self.baseURL + path)!)
    req.httpMethod = method
    req.timeoutInterval = 20
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { req.httpBody = Data(body.jsonString().utf8) }
    return req
  }

  /// Führt den Aufruf aus und wirft bei HTTP-Fehler oder Notion-Fehlerform.
  private func call(_ req: URLRequest, label: String) async throws -> JSONValue {
    let (data, http) = try await CalendarSupport.send(session, req, label: label)
    let body = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    if !(200..<300).contains(http.statusCode) || body["object"]?.stringValue == "error" {
      let detail = body["message"]?.stringValue ?? "\(http.statusCode)"
      throw CalendarError.unreachable("\(label): \(detail)")
    }
    return body
  }

  private func pathComponent(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
  }

  func fetchDataSourceId() async throws -> String {
    let body = try await call(request("/databases/\(pathComponent(databaseId))"), label: "Notion-Discovery fehlgeschlagen")
    guard let ds = body["data_sources"]?.arrayValue?.first?["id"]?.stringValue else {
      throw CalendarError.unreachable("Notion-Datenbank hat keine Data Source")
    }
    return ds
  }

  static func plainText(_ prop: JSONValue?) -> String {
    guard let prop, let type = prop["type"]?.stringValue,
          type == "title" || type == "rich_text", let parts = prop[type]?.arrayValue
    else { return "" }
    return parts.compactMap { $0["plain_text"]?.stringValue }.joined()
  }

  /// Notion-Seite → Termin; nil, wenn das Startdatum fehlt.
  func toEvent(_ page: JSONValue) -> CalendarEvent? {
    guard let pageId = page["id"]?.stringValue, let props = page["properties"] else { return nil }
    let title = Self.plainText(props[titleField]).isEmpty ? "(ohne Titel)" : Self.plainText(props[titleField])
    guard let dateProp = props[startField], dateProp["type"]?.stringValue == "date",
          let startRaw = dateProp["date"]?["start"]?.stringValue
    else { return nil }
    let start = CalendarSupport.localFromISO(startRaw)
    var end: String?
    if let endField {
      if let p = props[endField], p["type"]?.stringValue == "date", let s = p["date"]?["start"]?.stringValue {
        end = CalendarSupport.localFromISO(s)
      }
    } else if let s = dateProp["date"]?["end"]?.stringValue {
      end = CalendarSupport.localFromISO(s)
    }
    return CalendarEvent(id: pageId, sourceId: id, title: title, start: start, end: end,
                         allDay: !startRaw.contains("T"), readOnly: false)
  }

  func queryBody(from: String, to: String, cursor: String?) -> JSONValue {
    var o: [String: JSONValue] = [
      "page_size": 100,
      "filter": ["and": [
        ["property": .string(startField), "date": ["on_or_after": .string(from)]],
        ["property": .string(startField), "date": ["before": .string(to)]],
      ]],
    ]
    if let cursor { o["start_cursor"] = .string(cursor) }
    return .object(o)
  }

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    let ds = try await fetchDataSourceId()
    var events: [CalendarEvent] = []
    var cursor: String?
    repeat {
      let body = try await call(
        request("/data_sources/\(pathComponent(ds))/query", method: "POST", body: queryBody(from: from, to: to, cursor: cursor)),
        label: "Notion-Abfrage fehlgeschlagen")
      for page in body["results"]?.arrayValue ?? [] {
        if let e = toEvent(page) { events.append(e) }
      }
      cursor = body["has_more"]?.boolValue == true ? body["next_cursor"]?.stringValue : nil
    } while cursor != nil
    // Server filtert bereits; lokal nochmals, weil Zeitzonen-Umrechnung den Start verschieben kann.
    return events.filter { CalendarSupport.inRange($0, from: from, to: to) }
  }

  func dateValue(_ start: String, end: String?) -> JSONValue {
    var d: [String: JSONValue] = ["start": .string(start), "end": end.map { .string($0) } ?? .null]
    // Zonenlose Uhrzeit: Notion braucht die Zeitzone, sonst gilt UTC.
    if !LocalTime.isDateOnly(start) { d["time_zone"] = .string(TimeZone.current.identifier) }
    return .object(d)
  }

  func createBody(_ e: NewEvent, dataSourceId: String) -> JSONValue {
    var props: [String: JSONValue] = [
      titleField: ["title": [["type": "text", "text": ["content": .string(e.title)]]]],
      startField: ["date": dateValue(e.start, end: endField == nil ? e.end : nil)],
    ]
    if let endField, let end = e.end {
      props[endField] = ["date": dateValue(end, end: nil)]
    }
    return [
      "parent": ["type": "data_source_id", "data_source_id": .string(dataSourceId)],
      "properties": .object(props),
    ]
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    let ds = try await fetchDataSourceId()
    let body = try await call(request("/pages", method: "POST", body: createBody(e, dataSourceId: ds)),
                              label: "Notion-Seite anlegen fehlgeschlagen")
    guard let pageId = body["id"]?.stringValue else {
      throw CalendarError.unreachable("Notion-Seite anlegen fehlgeschlagen: keine Seiten-ID")
    }
    return CalendarEvent(id: pageId, sourceId: id, title: e.title, start: e.start, end: e.end,
                         allDay: LocalTime.isDateOnly(e.start), notes: e.notes, readOnly: false)
  }

  public func deleteEvent(id: String) async throws {
    _ = try await call(request("/pages/\(id)", method: "PATCH", body: ["archived": .bool(true)]),
                       label: "Notion-Seite löschen fehlgeschlagen")
  }

  public func healthCheck() async -> HealthResult {
    do {
      _ = try await fetchDataSourceId()
      return HealthResult(ok: true)
    } catch {
      return HealthResult(ok: false, message: CalendarSupport.message(for: error))
    }
  }
}
