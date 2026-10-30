// Apple Kalender über EventKit direkt (ersetzt Spike/Mock aus
// src/main/calendar/apple.ts, docs/decisions/0002 + 0006). Enthält auch in
// macOS eingetragene Google-/iCloud-Konten.
//
// Freigabe: macOS 14 `requestFullAccessToEvents`. Ohne
// `NSCalendarsFullAccessUsageDescription` im Info.plist des App-Bundles
// beendet macOS den Prozess bei der Anfrage — darum wird vorher geprüft und
// stattdessen „keine Freigabe“ gemeldet (z. B. bei `swift run` ohne Bundle).
//
// Konfiguration (optional): calendarIds: [String] (nur diese Kalender lesen),
// writeCalendarId: String (Zielkalender, sonst Standardkalender des Systems).
import EventKit
import Foundation

public final class AppleCalendarProvider: CalendarProvider {
  public static let usageDescriptionKey = "NSCalendarsFullAccessUsageDescription"

  public let id: String
  public let kind: CalendarSourceKind = .apple
  public var canWrite: Bool { true }

  private let calendarIds: [String]?
  private let writeCalendarId: String?
  private let bundle: Bundle
  private let store: SerialAccess<EKEventStore>

  public init(id: String = "apple", config: [String: JSONValue] = [:], bundle: Bundle = .main,
              store: SerialAccess<EKEventStore> = EventKitStore.shared) {
    self.id = id
    self.store = store
    self.calendarIds = config["calendarIds"]?.arrayValue?.compactMap(\.stringValue)
    self.writeCalendarId = config["writeCalendarId"]?.stringValue
    self.bundle = bundle
  }

  // MARK: Freigabe

  public static func hasUsageDescription(_ bundle: Bundle) -> Bool {
    bundle.object(forInfoDictionaryKey: usageDescriptionKey) != nil
  }

  enum Access: Equatable { case granted, notDetermined, denied, restricted, writeOnly }

  static func access(_ status: EKAuthorizationStatus) -> Access {
    switch status {
    case .fullAccess: return .granted
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    case .writeOnly: return .writeOnly
    case .authorized: return .granted  // vor macOS 14
    @unknown default: return .denied
    }
  }

  /// Deutscher Hinweis je Freigabe-Zustand (nil = alles gut).
  static func accessMessage(_ a: Access, hasUsageDescription: Bool) -> String? {
    switch a {
    case .granted: return nil
    case .notDetermined:
      return hasUsageDescription
        ? "Kalenderzugriff noch nicht erteilt. Lumi fragt beim nächsten Zugriff nach."
        : "Kalenderzugriff nicht möglich: Lumi läuft nicht als App-Bundle mit Kalender-Begründung (Info.plist)."
    case .denied:
      return "Kein Zugriff auf Apple Kalender. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Kalender für Lumi erlauben."
    case .restricted:
      return "Kalenderzugriff ist auf diesem Mac eingeschränkt (z. B. durch eine Verwaltung)."
    case .writeOnly:
      return "Lumi darf Termine nur hinzufügen, nicht lesen. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Kalender „Voller Zugriff“ wählen."
    }
  }

  private var currentAccess: Access { Self.access(EKEventStore.authorizationStatus(for: .event)) }

  /// Fragt (einmalig) nach Vollzugriff. Ohne Info.plist-Begründung: false, kein Dialog.
  @discardableResult
  public func requestAccess() async -> Bool {
    switch currentAccess {
    case .granted: return true
    case .notDetermined:
      guard Self.hasUsageDescription(bundle) else { return false }
      return (try? await store.run { s in
        // Blockiert nur die EventKit-Queue, bis macOS die Freigabe-Antwort liefert (anderer Thread).
        let done = DispatchSemaphore(value: 0)
        var granted = false
        s.requestFullAccessToEvents { ok, _ in granted = ok; done.signal() }
        done.wait()
        return granted
      }) ?? false
    default: return false
    }
  }

  private func ensureAccess() async throws {
    if await requestAccess() { return }
    let msg = Self.accessMessage(currentAccess, hasUsageDescription: Self.hasUsageDescription(bundle))
      ?? "Kein Zugriff auf Apple Kalender."
    throw CalendarError.unreachable(msg)
  }

  // MARK: Abbildung (ohne EventKit-Freigabe prüfbar)

  static func makeEvent(identifier: String, sourceId: String, title: String?, start: Date, end: Date?,
                        allDay: Bool, notes: String?, writable: Bool) -> CalendarEvent {
    let s = allDay ? LocalTime.formatDate(start) : LocalTime.format(start)
    var e: String?
    if let end {
      e = allDay ? LocalTime.formatDate(end) : LocalTime.format(end)
      if allDay, e == s { e = nil }
    }
    let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return CalendarEvent(
      // Wiederholungen teilen sich die eventIdentifier → Start anhängen, damit ids eindeutig sind.
      id: "\(identifier)|\(s)", sourceId: sourceId, title: t.isEmpty ? "(ohne Titel)" : t,
      start: s, end: e, allDay: allDay, notes: notes.flatMap { $0.isEmpty ? nil : $0 }, readOnly: !writable)
  }

  /// NewEvent → Zeitpunkte für EventKit. Ohne Ende: 1 Stunde (Uhrzeit) bzw. derselbe Tag (ganztägig).
  static func dates(for e: NewEvent) throws -> (start: Date, end: Date, allDay: Bool) {
    guard let start = LocalTime.parse(e.start) else { throw CalendarError.invalid("Ungültige Startzeit: \(e.start)") }
    let allDay = LocalTime.isDateOnly(e.start)
    var end: Date
    if let raw = e.end {
      guard let parsed = LocalTime.parse(raw) else { throw CalendarError.invalid("Ungültige Endzeit: \(raw)") }
      end = parsed
    } else {
      end = allDay ? start : start.addingTimeInterval(3600)
    }
    if end < start { throw CalendarError.invalid("Ende liegt vor dem Beginn") }
    if !allDay, end == start { end = start.addingTimeInterval(3600) }
    return (start, end, allDay)
  }

  // MARK: CalendarProvider

  public func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    guard let start = LocalTime.parse(from), let end = LocalTime.parse(to) else {
      throw CalendarError.invalid("Ungültiger Zeitraum \(from)–\(to)")
    }
    try await ensureAccess()
    let ids = calendarIds, sourceId = id
    return try await store.run { store in
      var calendars: [EKCalendar]?
      if let ids, !ids.isEmpty {
        calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
      }
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
      return store.events(matching: predicate).map { ev in
        Self.makeEvent(
          identifier: ev.eventIdentifier ?? ev.calendarItemIdentifier, sourceId: sourceId, title: ev.title,
          start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay, notes: ev.notes,
          writable: ev.calendar?.allowsContentModifications ?? false)
      }
    }
      .filter { CalendarSupport.inRange($0, from: from, to: to) }
      .sorted { $0.start < $1.start }
  }

  public func createEvent(_ e: NewEvent) async throws -> CalendarEvent {
    let d = try Self.dates(for: e)
    try await ensureAccess()
    let writeCalendarId = writeCalendarId, sourceId = id
    let identifier: String = try await store.run { store in
      let calendar = writeCalendarId.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
      guard let calendar, calendar.allowsContentModifications else {
        throw CalendarError.notWritable(sourceId)
      }
      let ev = EKEvent(eventStore: store)
      ev.title = e.title
      ev.startDate = d.start
      ev.endDate = d.end
      ev.isAllDay = d.allDay
      ev.notes = e.notes
      ev.calendar = calendar
      do {
        try store.save(ev, span: .thisEvent, commit: true)
      } catch {
        throw CalendarError.unreachable("Apple Kalender: Termin konnte nicht gespeichert werden (\(error.localizedDescription))")
      }
      return ev.eventIdentifier ?? ev.calendarItemIdentifier
    }
    return Self.makeEvent(
      identifier: identifier, sourceId: id, title: e.title,
      start: d.start, end: e.end == nil ? nil : d.end, allDay: d.allDay, notes: e.notes, writable: true)
  }

  /// Kehrt `makeEvent`s zusammengesetzte id ("eventIdentifier|Start") um.
  static func splitId(_ id: String) -> (identifier: String, start: String?) {
    guard let bar = id.lastIndex(of: "|") else { return (id, nil) }
    return (String(id[..<bar]), String(id[id.index(after: bar)...]))
  }

  /// Bei Wiederholungen liefert `event(withIdentifier:)` nur das erste Vorkommen –
  /// deshalb das Vorkommen mit genau diesem Start suchen.
  static func occurrence(_ id: String, in store: EKEventStore) -> EKEvent? {
    let (identifier, startText) = Self.splitId(id)
    if let startText, let start = LocalTime.parse(startText) {
      let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-1),
                                               end: start.addingTimeInterval(86_400), calendars: nil)
      // Kein Rückfall aufs erste Vorkommen: sonst würde ein anderer Termin verschoben oder gelöscht.
      return store.events(matching: predicate).first(where: {
        ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier && $0.startDate == start
      })
    }
    return store.event(withIdentifier: identifier)
  }

  /// Verschiebt den Termin in place (Notizen, Ort, Erinnerungen, Teilnehmer bleiben). Die id ändert sich
  /// nicht; nur der Start (und das Ende) wandern. Nicht gefunden → Fehler, nichts wird angefasst.
  public func moveEvent(id: String, start: String, end: String?) async throws -> CalendarEvent {
    let d = try Self.dates(for: NewEvent(title: "", start: start, end: end))
    try await ensureAccess()
    let sourceId = self.id
    return try await store.run { store in
      guard let ev = Self.occurrence(id, in: store) else {
        throw CalendarError.unreachable("Apple Kalender: Termin nicht gefunden (evtl. schon gelöscht).")
      }
      guard ev.calendar?.allowsContentModifications == true else { throw CalendarError.notWritable(sourceId) }
      ev.startDate = d.start
      ev.endDate = d.end
      do {
        try store.save(ev, span: .thisEvent, commit: true)
      } catch {
        throw CalendarError.unreachable("Apple Kalender: Verschieben fehlgeschlagen (\(error.localizedDescription))")
      }
      return Self.makeEvent(identifier: ev.eventIdentifier ?? ev.calendarItemIdentifier, sourceId: sourceId,
                            title: ev.title, start: ev.startDate, end: ev.endDate, allDay: ev.isAllDay,
                            notes: ev.notes, writable: true)
    }
  }

  public func deleteEvent(id: String) async throws {
    try await ensureAccess()
    let sourceId = self.id
    try await store.run { store in
      guard let ev = Self.occurrence(id, in: store) else {
        throw CalendarError.unreachable("Apple Kalender: Termin nicht gefunden (evtl. schon gelöscht).")
      }
      guard ev.calendar?.allowsContentModifications == true else { throw CalendarError.notWritable(sourceId) }
      do {
        try store.remove(ev, span: .thisEvent, commit: true)
      } catch {
        throw CalendarError.unreachable("Apple Kalender: Löschen fehlgeschlagen (\(error.localizedDescription))")
      }
    }
  }

  /// Alle Ereignis-Kalender des Systems; ohne Freigabe leer.
  public func availableCalendars() async -> [AppleCalendarInfo] {
    guard (try? await ensureAccess()) != nil else { return [] }
    return (try? await store.run { store in
      store.calendars(for: .event).map {
        AppleCalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "")
      }
    }) ?? []
  }

  public func healthCheck() async -> HealthResult {
    let has = Self.hasUsageDescription(bundle)
    if let msg = Self.accessMessage(currentAccess, hasUsageDescription: has) {
      return HealthResult(ok: false, message: msg)
    }
    return HealthResult(ok: true)
  }
}
