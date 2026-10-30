// Lokales Kalendermodul (Port von src/main/calendar/local.ts). Das echte
// SQLite-Backend (`local_events`, Store-Agent) wird vom Integrator über
// `LocalEventStore` angeschlossen; hier nur Protokoll + In-Memory-Platzhalter.
import Foundation

/// Speicher für lokale Termine. Der Integrator passt das Store-Repository daran an.
public protocol LocalEventStore: AnyObject {
  /// `from` inklusiv, `to` exklusiv (Datum "YYYY-MM-DD").
  func list(from: String, to: String) async throws -> [CalendarEvent]
  func create(_ e: NewEvent) async throws -> CalendarEvent
  func delete(id: String) async throws
}

/// PLATZHALTER für Prüfungen/Entwicklung — kein echtes Backend.
public final class InMemoryLocalEventStore: LocalEventStore {
  private let sourceId: String
  private var events: [CalendarEvent]
  private let lock = NSLock()

  public init(sourceId: String = "local", seed: [CalendarEvent] = []) {
    self.sourceId = sourceId
    self.events = seed
  }

  public func list(from: String, to: String) async throws -> [CalendarEvent] {
    lock.withLock { events.filter { CalendarSupport.inRange($0, from: from, to: to) } }
  }

  public func create(_ e: NewEvent) async throws -> CalendarEvent {
    let created = CalendarEvent(
      id: UUID().uuidString, sourceId: sourceId, title: e.title, start: e.start, end: e.end,
      allDay: LocalTime.isDateOnly(e.start), notes: e.notes, readOnly: false)
    lock.withLock { events.append(created) }
    return created
  }

  public func delete(id: String) async throws {
    lock.withLock { events.removeAll { $0.id == id } }
  }
}

public final class LocalCalendarProvider: CalendarProvider {
  public let id: String
  public let kind: CalendarSourceKind = .local
  public var canWrite: Bool { true }
  private let store: LocalEventStore

  public init(id: String = "local", store: LocalEventStore) {
    self.id = id; self.store = store
  }

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    try await store.list(from: from, to: to)
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    try await store.create(e)
  }

  public func deleteEvent(id: String) async throws {
    try await store.delete(id: id)
  }

  public func healthCheck() async -> HealthResult { HealthResult(ok: true) }
}
