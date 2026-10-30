// Kalender-Zugang der Werkzeuge (Port von src/main/tools/calendarRegistry.ts
// und der Integrator-Brücke src/main/calendarAdapter.ts). Bewusst klein: die
// echten Module (Apple/Notion/ICS) baut der Kalender-Bereich als
// `CalendarProvider`; der Integrator reicht sie an `ProviderCalendarAccess`
// weiter. Ein ausgefallenes Modul kippt weder Überblick noch Konfliktprüfung,
// es erscheint nur in `unreachable`.
import Foundation

/// Ergebnis einer Abfrage über alle aktiven Module.
public struct CalendarListing: Equatable, Sendable {
  public var events: [CalendarEvent]
  public var unreachable: [SourceProblem]

  public init(events: [CalendarEvent] = [], unreachable: [SourceProblem] = []) {
    self.events = events; self.unreachable = unreachable
  }
}

/// Was die Werkzeuge vom Kalender brauchen.
public protocol ToolCalendarAccess: AnyObject {
  func activeProviders() -> [CalendarProvider]
  /// Aggregiert `listEvents` über alle aktiven Module (`from` inklusiv, `to`
  /// exklusiv); Fehler einzelner Module landen in `unreachable`.
  func listAllEvents(from: String, to: String) async -> CalendarListing
  /// "Standard zum Schreiben"-Modul, Rückfall "local"; nil = keines beschreibbar.
  func defaultWriteProvider() -> CalendarProvider?
  /// Löscht einen Termin im Modul `sourceId`.
  func deleteEvent(id: String, sourceId: String) async throws
  /// Leert die Zwischenspeicher der Fernquellen, bevor eine Konfliktprüfung liest.
  func refreshRemoteCaches()
}

extension ToolCalendarAccess {
  public func refreshRemoteCaches() {}
}

/// Deutsche Meldung für Fehler eines Kalendermoduls.
public func calendarErrorMessage(_ error: Error) -> String {
  switch error {
  case CalendarError.notWritable(let id): return "Kalendermodul \"\(id)\" ist nicht beschreibbar."
  case CalendarError.unreachable(let msg): return msg
  case CalendarError.invalid(let msg): return msg
  case let e as LocalizedError where e.errorDescription != nil: return e.errorDescription!
  default: return String(describing: error)
  }
}

/// Das lokale Modul ("local") auf der SQLite-Tabelle local_events.
public final class StoreLocalCalendarProvider: CalendarProvider {
  public let id = EventsRepository.localSourceId
  public let kind = CalendarSourceKind.local
  public let canWrite = true
  private let events: EventsRepository

  public init(events: EventsRepository) { self.events = events }

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    try events.list(from: from, to: to)
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    try events.add(e)
  }

  public func healthCheck() async -> HealthResult { HealthResult(ok: true) }
}

private struct ProviderBox: @unchecked Sendable {
  let provider: CalendarProvider
}

/// Kalender-Zugang über eine feste Liste aktiver Module.
public final class ProviderCalendarAccess: ToolCalendarAccess {
  private let providers: [CalendarProvider]
  private let defaultWriteId: String?

  /// `defaultWriteId`: ID des als "Standard zum Schreiben" markierten Moduls.
  public init(providers: [CalendarProvider], defaultWriteId: String? = nil) {
    self.providers = providers
    self.defaultWriteId = defaultWriteId
  }

  /// Nur das lokale Modul (Rückfall, Prüfungen).
  public static func localOnly(_ store: Store) -> ProviderCalendarAccess {
    ProviderCalendarAccess(providers: [StoreLocalCalendarProvider(events: store.events)],
                           defaultWriteId: EventsRepository.localSourceId)
  }

  public func activeProviders() -> [CalendarProvider] { providers }

  public func refreshRemoteCaches() {
    for p in providers { (p as? CachingCalendarProvider)?.refresh() }
  }

  public func deleteEvent(id: String, sourceId: String) async throws {
    guard let p = providers.first(where: { $0.id == sourceId }) else {
      throw CalendarError.unreachable("Kalendermodul „\(sourceId)“ ist nicht aktiv.")
    }
    try await p.deleteEvent(id: id)
  }

  public func listAllEvents(from: String, to: String) async -> CalendarListing {
    let boxes = providers.map(ProviderBox.init)
    let results = await withTaskGroup(of: (Int, Result<CalendarRead, Error>).self) { group in
      for (i, box) in boxes.enumerated() {
        group.addTask {
          do { return (i, .success(try await CalendarReads.read(box.provider, from: from, to: to))) }
          catch { return (i, .failure(error)) }
        }
      }
      var out: [(Int, Result<CalendarRead, Error>)] = []
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }
    }
    var listing = CalendarListing()
    for (i, r) in results {
      switch r {
      case .success(let r):
        listing.events += r.events
        if let problem = r.problem { listing.unreachable.append(SourceProblem(id: providers[i].id, message: problem)) }
      case .failure(let err):
        listing.unreachable.append(SourceProblem(id: providers[i].id, message: calendarErrorMessage(err)))
      }
    }
    // Stabile Sortierung nach Beginn (Reihenfolge der Module bleibt bei Gleichstand).
    listing.events = listing.events.enumerated().sorted {
      ($0.element.start, $0.offset) < ($1.element.start, $1.offset)
    }.map(\.element)
    return listing
  }

  /// Gleiche Regel wie `CalendarRegistry.defaultWriteProvider`: markiert → Apple → lokal → irgendein beschreibbares.
  public func defaultWriteProvider() -> CalendarProvider? {
    CalendarRegistry.pickDefaultWrite(providers, markedId: defaultWriteId)
  }
}
