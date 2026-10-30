// VERTRAG (nur Orchestrator ändert). Port von src/shared/calendar.ts
// (BAUPLAN.md Abschnitt 10).
import Foundation

public struct CalendarEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sourceId: String
  public var title: String
  /// "YYYY-MM-DDTHH:mm" oder bei ganztägig "YYYY-MM-DD".
  public var start: String
  public var end: String?
  public var allDay: Bool
  public var notes: String?
  public var readOnly: Bool

  public init(id: String, sourceId: String, title: String, start: String, end: String? = nil, allDay: Bool = false,
              notes: String? = nil, readOnly: Bool = false) {
    self.id = id; self.sourceId = sourceId; self.title = title; self.start = start; self.end = end
    self.allDay = allDay; self.notes = notes; self.readOnly = readOnly
  }
}

public struct NewEvent: Codable, Equatable, Sendable {
  public var title: String
  public var start: String
  public var end: String?
  public var notes: String?

  public init(title: String, start: String, end: String? = nil, notes: String? = nil) {
    self.title = title; self.start = start; self.end = end; self.notes = notes
  }
}

public enum ConflictKind: String, Codable, Sendable {
  case overlap
  case sameStart = "same-start"
  /// Kein Überlappen, aber weniger Abstand als `TabySettings.bufferMinutes`.
  case tooClose = "too-close"
}

public struct Conflict: Codable, Equatable, Sendable {
  public var with: CalendarEvent
  public var kind: ConflictKind

  public init(with: CalendarEvent, kind: ConflictKind) {
    self.with = with; self.kind = kind
  }
}

public struct HealthResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var message: String?

  public init(ok: Bool, message: String? = nil) {
    self.ok = ok; self.message = message
  }
}

/// Kalenderquelle, die nicht erreichbar war (Termine fehlen dann im Überblick).
public struct SourceProblem: Codable, Equatable, Sendable {
  public var id: String
  public var message: String

  public init(id: String, message: String) {
    self.id = id; self.message = message
  }
}

public enum CalendarError: Error, Equatable {
  case notWritable(String)
  case unreachable(String)
  case invalid(String)
}

public protocol CalendarProvider: AnyObject {
  /// Stabil, z. B. "apple", "notion:abc", "local".
  var id: String { get }
  var kind: CalendarSourceKind { get }
  var canWrite: Bool { get }
  /// `from` inklusiv, `to` exklusiv (Datum "YYYY-MM-DD").
  func listEvents(from: String, to: String) async throws -> [CalendarEvent]
  func createEvent(_ e: NewEvent) async throws -> CalendarEvent
  /// Löscht einen Termin dieses Moduls. Standard: nicht erlaubt (nur lesbare Module).
  func deleteEvent(id: String) async throws
  func healthCheck() async -> HealthResult
}

extension CalendarProvider {
  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    throw CalendarError.notWritable(id)
  }
  public func deleteEvent(id: String) async throws {
    throw CalendarError.notWritable(self.id)
  }
}
