// Kurzzeit-Cache für Fernquellen (ICS, Notion). Lokale Module und EventKit
// bleiben ungecached (lokal, und Änderungsbenachrichtigungen gibt es dort).
//
// Regeln: Ergebnis je (von, bis) bleibt 5 Min gültig; gleichzeitige Anfragen
// teilen sich einen Abruf; Schreiben über Lumi und `refresh` leeren den Cache.
// Schlägt ein Abruf fehl, wird der letzte gute Stand bis 30 Min weiter geliefert,
// der Fehler wird aber weiterhin als „nicht erreichbar“ gemeldet.
import Foundation

/// Ergebnis einer Lesung: Termine plus Fehlertext, wenn nur ein älterer Stand kam.
public struct CalendarRead: Sendable {
  public var events: [CalendarEvent]
  public var problem: String?
}

public final class CachingCalendarProvider: CalendarProvider {
  public static let freshFor: TimeInterval = 300
  public static let staleFor: TimeInterval = 1800
  /// Höchstens so viele Zeitbereiche je Quelle im Speicher.
  static let maxEntries = 50

  private struct Entry {
    var events: [CalendarEvent]
    var at: Date
  }

  let inner: CalendarProvider
  private let clock: Clock
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var inFlight: [String: Task<[CalendarEvent], Error>] = [:]
  /// Erhöht sich bei jedem Leeren; späte Abrufe von davor schreiben dann nichts mehr.
  private var generation = 0

  public init(inner: CalendarProvider, clock: Clock) {
    self.inner = inner
    self.clock = clock
  }

  public var id: String { inner.id }
  public var kind: CalendarSourceKind { inner.kind }
  public var canWrite: Bool { inner.canWrite }

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    try await load(from: from, to: to).events
  }

  public func load(from: String, to: String) async throws -> CalendarRead {
    let key = "\(from)|\(to)"
    enum Step {
      case cached([CalendarEvent])
      case wait(Task<[CalendarEvent], Error>)
    }
    let step: Step = lock.withLock {
      if let e = entries[key], clock.now().timeIntervalSince(e.at) < Self.freshFor { return .cached(e.events) }
      if let t = inFlight[key] { return .wait(t) }
      let gen = generation
      let t = Task<[CalendarEvent], Error> { [self] in
        do {
          let events = try await inner.listEvents(from: from, to: to)
          finish(key, gen, events)
          return events
        } catch {
          finish(key, gen, nil)
          throw error
        }
      }
      inFlight[key] = t
      return .wait(t)
    }
    switch step {
    case .cached(let events):
      return CalendarRead(events: events, problem: nil)
    case .wait(let task):
      do {
        return CalendarRead(events: try await task.value, problem: nil)
      } catch {
        let stale: [CalendarEvent]? = lock.withLock {
          guard let e = entries[key], clock.now().timeIntervalSince(e.at) < Self.staleFor else { return nil }
          return e.events
        }
        guard let stale else { throw error }
        return CalendarRead(events: stale, problem: CalendarSupport.message(for: error))
      }
    }
  }

  private func finish(_ key: String, _ gen: Int, _ events: [CalendarEvent]?) {
    lock.withLock {
      guard gen == generation else { return }
      inFlight[key] = nil
      if let events { entries[key] = Entry(events: events, at: clock.now()) }
      // Begrenzung je Quelle: die ältesten Bereiche fallen zuerst heraus.
      while entries.count > Self.maxEntries,
            let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
        entries[oldest] = nil
      }
    }
  }

  /// Leert den Cache (ausdrückliches „Aktualisieren“).
  public func refresh() { invalidate() }

  private func invalidate() {
    lock.withLock {
      entries = [:]
      inFlight = [:]
      generation += 1
    }
  }

  // Schreiben über Lumi leert den Cache der Quelle, auch bei Fehler (Teilerfolg möglich).
  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    defer { invalidate() }
    return try await inner.createEvent(e)
  }

  public func deleteEvent(id: String) async throws {
    defer { invalidate() }
    try await inner.deleteEvent(id: id)
  }

  public func healthCheck() async -> HealthResult { await inner.healthCheck() }
}

/// Liest Termine über den Cache, wenn der Provider einen hat; sonst direkt.
enum CalendarReads {
  static func read(_ p: CalendarProvider, from: String, to: String) async throws -> CalendarRead {
    if let c = p as? CachingCalendarProvider { return try await c.load(from: from, to: to) }
    return CalendarRead(events: try await p.listEvents(from: from, to: to), problem: nil)
  }
}
