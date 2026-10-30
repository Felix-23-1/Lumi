import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  static func makeCalendarAccess(store: Store, session: URLSession,
                                 secrets: @escaping (String) -> ApiKeyStore, clock: Clock,
                                 microsoft: MicrosoftAuth? = nil) -> ToolCalendarAccess {
    let sources = (try? store.calendarSources.list()) ?? []
    let registry = CalendarRegistry(
      sources: sources,
      deps: CalendarRegistryDeps(localStore: StoreLocalEventStore(store.events), session: session,
                                 notionToken: { cfg in (try? secrets(cfg.id).get()) ?? nil }, clock: clock,
                                 caldavPassword: { cfg in (try? secrets(cfg.id).get()) ?? nil },
                                 microsoft: microsoft)
    )
    let defaultWrite = sources.first(where: { $0.enabled && $0.isDefaultWrite })?.id
    return ProviderCalendarAccess(providers: registry.providers, defaultWriteId: defaultWrite)
  }

  func rebuildCalendar() {
    calendarAccess = Self.makeCalendarAccess(store: store, session: options.session, secrets: options.calendarSecrets,
                                             clock: clock, microsoft: microsoft)
  }

  /// Für die Oberfläche: nie das Token, nur ob eines gesetzt ist.
  func publicSource(_ src: CalendarSourceConfig) -> CalendarSourceConfig {
    var out = src
    out.config[Self.tokenKey] = nil
    if src.kind == .notion {
      out.config["hasToken"] = .bool(((try? options.calendarSecrets(src.id).hasKey()) ?? false) == true)
    }
    return out
  }

  public func upsertCalendarSource(_ draft: CalendarSourceDraft) async -> ToolResult<CalendarSourceConfig> {
    var draft = draft
    let token = draft.config?[Self.tokenKey]?.stringValue
    draft.config?[Self.tokenKey] = nil
    do {
      guard let source = try store.calendarSources.upsert(draft) else {
        return .failure(code: "NOT_FOUND", error: "Kalenderquelle nicht gefunden.")
      }
      if let token, !token.isEmpty {
        do {
          try options.calendarSecrets(source.id).set(token)
        } catch {
          return .failure(code: "KEYCHAIN", error: "Token konnte nicht im Schlüsselbund gespeichert werden.")
        }
      }
      rebuildCalendar()
      changed()
      return .ok(publicSource(source))
    } catch {
      return .failure(code: "ERROR", error: "Kalenderquelle konnte nicht gespeichert werden.")
    }
  }

  public func appleCalendars() async -> [AppleCalendarInfo] {
    await AppleCalendarProvider(id: "apple").availableCalendars()
  }

  public func calendarHealthCheck(_ id: String) async -> HealthResult {
    guard let provider = calendarAccess.activeProviders().first(where: { $0.id == id }) else {
      return HealthResult(ok: false, message: "Kalenderquelle nicht aktiv oder nicht gefunden.")
    }
    return await provider.healthCheck()
  }

  public func addEvent(_ req: AddEventRequest) async -> AddEventResult {
    p4.eventsCache.clear()
    let previous = addEventTail
    let ctx = toolContext(actor: .user)
    let work = Task { @MainActor () -> AddEventResult in
      await previous?.value
      return await ToolRegistry.addEvent(req, ctx: ctx)
    }
    addEventTail = Task { _ = await work.value }
    let result = await work.value
    if case .ok = result { changed() }
    return result
  }

  public func listEvents(from: String, to: String) async -> [CalendarEvent] {
    let r: ToolResult<[CalendarEvent]> = ToolRegistry.typed(
      await tool("list_events", ["from": .string(from), "to": .string(to)]), key: "events")
    return r.value ?? []
  }

  public func deleteEvent(id: String, sourceId: String) async -> ToolResult<Empty> {
    p4.eventsCache.clear()
    do {
      try await calendarAccess.deleteEvent(id: id, sourceId: sourceId)
      changed()
      return .ok(Empty())
    } catch {
      return .failure(code: "CALENDAR", error: calendarErrorMessage(error))
    }
  }
}
