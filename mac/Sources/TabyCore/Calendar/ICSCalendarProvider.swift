// ICS-Abo als Lese-Rückfall (Port von src/main/calendar/ics.ts).
//
// Schlanker VEVENT-Parser für SUMMARY/DTSTART/DTEND/UID/DESCRIPTION, keine
// Wiederholungen (RRULE) — wie in TS bewusst nicht unterstützt.
//
// Zeitzonen (Abweichung von TS, das Zeiten 1:1 übernahm): "…Z" (UTC) und
// "TZID=Europe/…" werden in die lokale Zone des Systems umgerechnet, weil
// z. B. Google-Kalender-Abos alle Zeiten in UTC liefern. Zonenlose
// („floating“) Zeiten und unbekannte TZIDs bleiben 1:1. Ganztägig
// (VALUE=DATE, "YYYYMMDD") ergibt "YYYY-MM-DD"; DTEND bleibt wie geliefert
// (bei Ganztägig exklusiv, wie in TS).
import Foundation

public enum ICSParser {
  static func unfoldLines(_ text: String) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
      if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
        lines[lines.count - 1] += line.dropFirst()
      } else {
        lines.append(String(line))
      }
    }
    return lines
  }

  struct Property {
    var name: String
    var params: [String: String]
    var value: String
  }

  /// "DTSTART;TZID=Europe/Berlin:20261012T090000" → Name, Parameter, Wert.
  static func parseProperty(_ line: String) -> Property? {
    var inQuotes = false
    var colon: String.Index?
    for i in line.indices {
      let c = line[i]
      if c == "\"" { inQuotes.toggle() } else if c == ":" && !inQuotes { colon = i; break }
    }
    guard let colon else { return nil }
    let head = line[..<colon]
    let value = String(line[line.index(after: colon)...])
    let parts = head.split(separator: ";", omittingEmptySubsequences: false)
    guard let first = parts.first else { return nil }
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
      if let eq = p.firstIndex(of: "=") {
        let v = p[p.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        params[p[..<eq].uppercased()] = v
      }
    }
    return Property(name: first.uppercased(), params: params, value: value)
  }

  /// ICS-Datum/-Zeit → lokaler ISO-String + Ganztägig-Kennung.
  static func parseDate(_ raw: String, tzid: String?) -> (value: String, allDay: Bool) {
    let v = raw.trimmingCharacters(in: .whitespaces)
    let chars = Array(v)
    func num(_ a: Int, _ len: Int) -> Int? {
      guard a + len <= chars.count else { return nil }
      return Int(String(chars[a..<(a + len)]))
    }
    guard chars.count >= 8, let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2),
          chars[0..<8].allSatisfy(\.isNumber)
    else { return (v, false) }
    let ymd = String(format: "%04d-%02d-%02d", y, mo, d)
    if chars.count == 8 { return (ymd, true) }
    guard chars.count >= 13, chars[8] == "T", let h = num(9, 2), let mi = num(11, 2) else { return (v, false) }
    var rest = chars.count > 13 ? String(chars[13...]) : ""
    var sec = 0
    if rest.count >= 2, let s = Int(rest.prefix(2)) { sec = s; rest = String(rest.dropFirst(2)) }
    let isUTC = rest == "Z"
    guard rest.isEmpty || isUTC else { return (v, false) }
    let zone: TimeZone? = isUTC ? TimeZone(identifier: "UTC") : tzid.flatMap { TimeZone(identifier: $0) }
    if let zone, let date = CalendarSupport.date(year: y, month: mo, day: d, hour: h, minute: mi, second: sec, in: zone) {
      return (CalendarSupport.local(date), false)
    }
    return (String(format: "%@T%02d:%02d", ymd, h, mi), false)
  }

  static func unescape(_ s: String) -> String {
    var out = ""
    var esc = false
    for c in s {
      if esc {
        switch c {
        case "n", "N": out.append("\n")
        default: out.append(c)
        }
        esc = false
      } else if c == "\\" {
        esc = true
      } else {
        out.append(c)
      }
    }
    return out
  }

  /// Alle VEVENTs; `sourceId` wird vom Provider gesetzt.
  public static func parseEvents(_ text: String, sourceId: String = "") -> [CalendarEvent] {
    var events: [CalendarEvent] = []
    var cur: [String: Property]?
    for raw in unfoldLines(text) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line == "BEGIN:VEVENT" { cur = [:]; continue }
      if line == "END:VEVENT" {
        if let c = cur, let dtstart = c["DTSTART"] {
          let start = parseDate(dtstart.value, tzid: dtstart.params["TZID"])
          let end = c["DTEND"].map { parseDate($0.value, tzid: $0.params["TZID"]).value }
          let title = c["SUMMARY"].map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 } ?? "(ohne Titel)"
          events.append(CalendarEvent(
            id: c["UID"]?.value ?? UUID().uuidString, sourceId: sourceId, title: title,
            start: start.value, end: end, allDay: start.allDay,
            notes: c["DESCRIPTION"].map { unescape($0.value) }, readOnly: true))
        }
        cur = nil
        continue
      }
      guard cur != nil, let p = parseProperty(line) else { continue }
      if ["SUMMARY", "UID", "DTSTART", "DTEND", "DESCRIPTION"].contains(p.name) {
        cur?[p.name] = p
      }
    }
    return events
  }
}

public final class ICSCalendarProvider: CalendarProvider {
  public let id: String
  public let kind: CalendarSourceKind = .ics
  public var canWrite: Bool { false }
  private let url: String
  private let session: URLSession

  /// config["url"]: Abo-Adresse (https:// oder webcal://).
  public init(id: String, config: [String: JSONValue], session: URLSession = .shared) {
    self.id = id
    self.url = config["url"]?.stringValue ?? ""
    self.session = session
  }

  private func fetchEvents() async throws -> [CalendarEvent] {
    guard !url.isEmpty else { throw CalendarError.invalid("ICS-Quelle benötigt eine Adresse (config.url)") }
    var s = url
    if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
    guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else {
      throw CalendarError.invalid("ICS-Adresse ist ungültig")
    }
    var req = URLRequest(url: u)
    req.timeoutInterval = 20
    let (data, http) = try await CalendarSupport.send(session, req, label: "ICS-Abruf fehlgeschlagen")
    guard (200..<300).contains(http.statusCode) else {
      throw CalendarError.unreachable("ICS-Abruf fehlgeschlagen: \(http.statusCode)")
    }
    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    return ICSParser.parseEvents(text, sourceId: id)
  }

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    try await fetchEvents().filter { CalendarSupport.inRange($0, from: from, to: to) }
  }

  public func healthCheck() async -> HealthResult {
    do {
      _ = try await fetchEvents()
      return HealthResult(ok: true)
    } catch {
      return HealthResult(ok: false, message: CalendarSupport.message(for: error))
    }
  }
}
