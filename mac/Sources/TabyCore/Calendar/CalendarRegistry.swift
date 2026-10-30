// Kalender-Registry (Port von src/main/calendar/registry.ts und dem
// Integrator-Klebecode src/main/calendarAdapter.ts, BAUPLAN Abschnitt 10):
// hält pro aktiver Quelle einen Provider, aggregiert `listEvents` über alle
// und fängt Fehler PRO Quelle ab — eine ausgefallene Quelle wird als
// `SourceProblem` ausgewiesen und kippt Briefing/Konfliktprüfung nicht.
import Foundation

public struct CalendarListResult: Equatable, Sendable {
  public var events: [CalendarEvent]
  public var unreachable: [SourceProblem]
  public init(events: [CalendarEvent], unreachable: [SourceProblem]) {
    self.events = events; self.unreachable = unreachable
  }
}

public struct CalendarRegistryDeps {
  /// Backend des lokalen Moduls (Integrator: SQLite-Repository). Standard: In-Memory.
  public var localStore: LocalEventStore?
  /// Für ICS/Notion; Prüfungen setzen eine Sitzung mit gestubbtem URLProtocol.
  public var session: URLSession
  /// Notion-Token je Quelle (Schlüsselbund). Standard: `config["token"]`.
  public var notionToken: (CalendarSourceConfig) -> String?
  /// Ersetzt den EventKit-Provider (z. B. in Prüfungen/Testmodus).
  public var appleFactory: ((CalendarSourceConfig) -> CalendarProvider)?
  /// Uhr für den Cache der Fernquellen (TTL). Standard: Systemuhr.
  public var clock: Clock
  /// CalDAV-Passwort je Quelle (Schlüsselbund). Standard: keins.
  public var caldavPassword: (CalendarSourceConfig) -> String?
  /// Microsoft-Anmeldung für Outlook-Quellen (nil = Outlook nicht verbunden).
  public var microsoft: MicrosoftAuth?

  public init(localStore: LocalEventStore? = nil, session: URLSession = .shared,
              notionToken: @escaping (CalendarSourceConfig) -> String? = { $0.config["token"]?.stringValue },
              appleFactory: ((CalendarSourceConfig) -> CalendarProvider)? = nil, clock: Clock = SystemClock(),
              caldavPassword: @escaping (CalendarSourceConfig) -> String? = { _ in nil },
              microsoft: MicrosoftAuth? = nil) {
    self.localStore = localStore; self.session = session; self.notionToken = notionToken
    self.appleFactory = appleFactory; self.clock = clock; self.caldavPassword = caldavPassword
    self.microsoft = microsoft
  }
}

public final class CalendarRegistry {
  public static let localSourceId = "local"

  /// Aktive Provider in Konfigurationsreihenfolge.
  public let providers: [CalendarProvider]
  private let defaultWriteId: String?

  /// Baut die Registry aus den Quellen. Deaktivierte Quellen werden ignoriert.
  /// `alwaysIncludeLocal`: das lokale Modul ist immer vorhanden (Rückfall zum
  /// Schreiben, BAUPLAN 10) — es wird vorne ergänzt, falls nicht konfiguriert.
  /// Eine Quelle mit ungültiger Konfiguration erscheint als „nicht erreichbar“.
  public init(sources: [CalendarSourceConfig], deps: CalendarRegistryDeps = CalendarRegistryDeps(),
              alwaysIncludeLocal: Bool = true) {
    var active = sources.filter(\.enabled)
    if alwaysIncludeLocal, !active.contains(where: { $0.kind == .local }) {
      active.insert(CalendarSourceConfig(id: Self.localSourceId, kind: .local), at: 0)
    }
    providers = active.map { Self.makeProvider($0, deps: deps) }
    defaultWriteId = active.first(where: \.isDefaultWrite)?.id
  }

  /// Fertige Provider (Prüfungen, Sonderfälle).
  public init(providers: [CalendarProvider], defaultWriteId: String? = nil) {
    self.providers = providers; self.defaultWriteId = defaultWriteId
  }

  public static func makeProvider(_ cfg: CalendarSourceConfig, deps: CalendarRegistryDeps = CalendarRegistryDeps())
    -> CalendarProvider
  {
    switch cfg.kind {
    case .local:
      return LocalCalendarProvider(id: cfg.id, store: deps.localStore ?? InMemoryLocalEventStore(sourceId: cfg.id))
    case .ics:
      return CachingCalendarProvider(inner: ICSCalendarProvider(id: cfg.id, config: cfg.config, session: deps.session),
                                     clock: deps.clock)
    case .notion:
      do {
        let inner = try NotionCalendarProvider(id: cfg.id, config: cfg.config, token: deps.notionToken(cfg), session: deps.session)
        return CachingCalendarProvider(inner: inner, clock: deps.clock)
      } catch {
        return UnavailableCalendarProvider(id: cfg.id, kind: .notion, reason: CalendarSupport.message(for: error))
      }
    case .apple:
      return deps.appleFactory?(cfg) ?? AppleCalendarProvider(id: cfg.id, config: cfg.config)
    case .caldav:
      do {
        let inner = try CalDAVProvider(id: cfg.id, config: cfg.config, password: deps.caldavPassword(cfg), session: deps.session)
        return CachingCalendarProvider(inner: inner, clock: deps.clock)
      } catch {
        return UnavailableCalendarProvider(id: cfg.id, kind: .caldav, reason: CalendarSupport.message(for: error))
      }
    case .microsoft:
      guard let auth = deps.microsoft else {
        return UnavailableCalendarProvider(id: cfg.id, kind: .microsoft, reason: "Outlook ist noch nicht verbunden.")
      }
      return CachingCalendarProvider(inner: MicrosoftCalendarProvider(id: cfg.id, auth: auth, clock: deps.clock),
                                     clock: deps.clock)
    }
  }

  public func provider(id: String) -> CalendarProvider? {
    providers.first { $0.id == id }
  }

  /// „Standard zum Schreiben“ (Regel: `pickDefaultWrite`).
  public func defaultWriteProvider() -> CalendarProvider? {
    Self.pickDefaultWrite(providers, markedId: defaultWriteId)
  }

  /// Standard zum Schreiben: das ausdrücklich markierte Modul, wenn beschreibbar;
  /// sonst der erste beschreibbare Apple-Kalender (ohne Markierung kam bisher
  /// immer das lokale Modul zum Zug); sonst lokal; sonst der erste beschreibbare.
  static func pickDefaultWrite(_ providers: [CalendarProvider], markedId: String?) -> CalendarProvider? {
    if let id = markedId, let p = providers.first(where: { $0.id == id && $0.canWrite }) { return p }
    return providers.first(where: { $0.kind == .apple && $0.canWrite })
      ?? providers.first(where: { $0.kind == .local && $0.canWrite })
      ?? providers.first(where: \.canWrite)
  }

  /// Termine aller aktiven Quellen (parallel). Fehler je Quelle → `unreachable`.
  /// Reihenfolge: nach Provider, innerhalb wie geliefert.
  public func listAllEvents(from: String, to: String) async -> CalendarListResult {
    let list = providers
    let results = await withTaskGroup(of: (Int, Result<CalendarRead, Error>).self) { group in
      for (i, p) in list.enumerated() {
        group.addTask {
          do { return (i, .success(try await CalendarReads.read(p, from: from, to: to))) } catch { return (i, .failure(error)) }
        }
      }
      var out = [Result<CalendarRead, Error>?](repeating: nil, count: list.count)
      for await (i, r) in group { out[i] = r }
      return out
    }
    var events: [CalendarEvent] = []
    var unreachable: [SourceProblem] = []
    for (i, r) in results.enumerated() {
      switch r {
      case .success(let r)?:
        events.append(contentsOf: r.events)
        if let problem = r.problem { unreachable.append(SourceProblem(id: list[i].id, message: problem)) }
      case .failure(let err)?: unreachable.append(SourceProblem(id: list[i].id, message: CalendarSupport.message(for: err)))
      case nil: unreachable.append(SourceProblem(id: list[i].id, message: "keine Antwort"))
      }
    }
    return CalendarListResult(events: events, unreachable: unreachable)
  }

  /// Leert den Cache einer Fernquelle (ausdrückliches „Aktualisieren“); sonst ohne Wirkung.
  public func refresh(id: String) {
    (provider(id: id) as? CachingCalendarProvider)?.refresh()
  }

  public func healthCheck(id: String) async -> HealthResult {
    guard let p = provider(id: id) else { return HealthResult(ok: false, message: "Kalenderquelle \(id) ist nicht aktiv") }
    return await p.healthCheck()
  }
}
