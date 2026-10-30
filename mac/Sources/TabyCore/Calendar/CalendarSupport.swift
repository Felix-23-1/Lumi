// Gemeinsame Helfer der Kalendermodule: Fehlertexte, Zeitbereich-Filter,
// HTTP-Grenze (URLSession, in Prüfungen per URLProtocol gestubbt) und
// Umrechnung zonenbehafteter Zeiten in lokale, zonenlose ISO-Strings.
import Foundation

enum CalendarSupport {
  /// Lesbarer (deutscher) Text für Fehler aus Providern, ohne Geheimnisse.
  static func message(for error: Error) -> String {
    if let e = error as? CalendarError {
      switch e {
      case .notWritable(let id): return "Kalender \(id) ist nicht beschreibbar"
      case .unreachable(let m): return m
      case .invalid(let m): return m
      }
    }
    if let e = error as? URLError {
      return "Netzwerkfehler (\(e.code.rawValue))"
    }
    return error.localizedDescription
  }

  /// `from` inklusiv, `to` exklusiv — Vergleich der lokalen ISO-Strings (wie TS).
  /// Ein Termin, der vor `from` begann und danach noch läuft (mehrtägig, ganztägig), zählt auch.
  /// Ein Ende genau um 00:00 am Tag `from` zählt nicht.
  static func inRange(_ e: CalendarEvent, from: String, to: String) -> Bool {
    guard e.start < to else { return false }
    if e.start >= from { return true }
    let end = e.end ?? e.start
    let endsAtMidnightOfFrom = end.count > 10 && end.hasSuffix("T00:00") && end.hasPrefix(from)
    return end > from && !endsAtMidnightOfFrom
  }

  /// HTTP-Aufruf; Transportfehler werden zu `CalendarError.unreachable`.
  static func send(_ session: URLSession, _ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw CalendarError.unreachable("\(label): keine HTTP-Antwort")
      }
      return (data, http)
    } catch let e as CalendarError {
      throw e
    } catch {
      throw CalendarError.unreachable("\(label): \(message(for: error))")
    }
  }

  /// Wandelt einen absoluten Zeitpunkt in "YYYY-MM-DDTHH:mm" (lokale Zone).
  static func local(_ date: Date) -> String { LocalTime.format(date) }

  /// Komponenten in einer bestimmten Zeitzone → Date.
  static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, in zone: TimeZone) -> Date? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
  }

  /// ISO 8601 mit Versatz ("…+02:00", "…Z", optional Sekundenbruchteile) → lokal.
  /// Ohne Versatz (zonenlos) wird die Uhrzeit 1:1 übernommen. Reine Daten bleiben Daten.
  static func localFromISO(_ value: String) -> String {
    if value.count <= 10 { return value }
    let timePart = value.dropFirst(11)
    let hasOffset = timePart.hasSuffix("Z") || timePart.contains("+") || timePart.contains("-")
    if hasOffset {
      for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
        let f = ISO8601DateFormatter()
        f.formatOptions = opts
        if let d = f.date(from: value) { return local(d) }
      }
    }
    return String(value.prefix(16))
  }
}

/// Platzhalter für eine Quelle, deren Konfiguration ungültig ist: sie
/// erscheint als „nicht erreichbar“, statt die ganze Registry zu kippen.
final class UnavailableCalendarProvider: CalendarProvider {
  let id: String
  let kind: CalendarSourceKind
  let reason: String
  var canWrite: Bool { false }

  init(id: String, kind: CalendarSourceKind, reason: String) {
    self.id = id; self.kind = kind; self.reason = reason
  }

  func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    throw CalendarError.invalid(reason)
  }

  func healthCheck() async -> HealthResult { HealthResult(ok: false, message: reason) }
}
