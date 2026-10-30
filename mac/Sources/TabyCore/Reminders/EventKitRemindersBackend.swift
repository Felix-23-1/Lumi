// Apple Erinnerungen über EventKit (EKEventStore, Entität .reminder).
//
// Freigabe: macOS 14 `requestFullAccessToReminders`. Ohne
// `NSRemindersFullAccessUsageDescription` im Info.plist des App-Bundles beendet
// macOS den Prozess bei der Anfrage. Darum wird vorher geprüft und stattdessen
// false geliefert (z. B. bei `swift run` ohne Bundle).
import EventKit
import Foundation

public final class EventKitRemindersBackend: RemindersBackend {
  public static let usageDescriptionKey = "NSRemindersFullAccessUsageDescription"

  private let store: SerialAccess<EKEventStore>

  public init(store: SerialAccess<EKEventStore> = EventKitStore.shared) { self.store = store }

  private var hasUsageDescription: Bool {
    Bundle.main.object(forInfoDictionaryKey: Self.usageDescriptionKey) != nil
  }

  static func isGranted(_ status: EKAuthorizationStatus) -> Bool {
    switch status {
    case .fullAccess, .authorized: return true
    default: return false
    }
  }

  private func requireAccess() throws {
    guard Self.isGranted(EKEventStore.authorizationStatus(for: .reminder)) else {
      throw RemindersError.accessDenied
    }
  }

  // MARK: RemindersBackend

  public func requestAccess() async -> Bool {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    if Self.isGranted(status) { return true }
    guard status == .notDetermined, hasUsageDescription else { return false }
    return (try? await store.run { s in
      let done = DispatchSemaphore(value: 0)
      var granted = false
      s.requestFullAccessToReminders { ok, _ in granted = ok; done.signal() }
      done.wait()
      return granted
    }) ?? false
  }

  public func lists() async throws -> [ReminderListInfo] {
    try requireAccess()
    return try await store.run { $0.calendars(for: .reminder).map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title) } }
  }

  public func fetchAll(listIds: [String]?) async throws -> [ExternalReminder] {
    try requireAccess()
    return try await store.run { store in
      var calendars: [EKCalendar]?
      if let ids = listIds {
        let matching = store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) }
        // Keine der gewünschten Listen vorhanden: nichts abrufen (nil würde alle Listen liefern).
        if matching.isEmpty { return [] }
        calendars = matching
      }
      let predicate = store.predicateForReminders(in: calendars)
      // Queue bleibt belegt, bis EventKit antwortet – aber nicht ewig. Nach Ablauf gibt die Queue frei;
      // ein später eintreffender Rückruf fasst dann den Store nicht mehr an (lock + abandoned).
      let done = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var mapped: [ExternalReminder] = []
      var abandoned = false
      store.fetchReminders(matching: predicate) { items in
        lock.lock(); defer { lock.unlock() }
        guard !abandoned else { return }
        mapped = (items ?? []).map(Self.mapReminder)
        done.signal()
      }
      let finished = done.wait(timeout: .now() + 30) == .success
      lock.lock(); abandoned = !finished; let result = mapped; lock.unlock()
      guard finished else { throw RemindersError.timedOut }
      return result
    }
  }

  public func create(_ r: ExternalReminder, listId: String?) async throws -> String {
    try requireAccess()
    return try await store.run { store in
      let calendar: EKCalendar?
      if let listId {
        calendar = store.calendar(withIdentifier: listId)
      } else {
        calendar = store.defaultCalendarForNewReminders()
      }
      guard let calendar else { throw RemindersError.listUnavailable }
      let ek = EKReminder(eventStore: store)
      Self.apply(r, to: ek)
      ek.calendar = calendar
      try store.save(ek, commit: true)
      return ek.calendarItemIdentifier
    }
  }

  public func update(_ r: ExternalReminder) async throws {
    try requireAccess()
    try await store.run { store in
      guard let ek = store.calendarItem(withIdentifier: r.id) as? EKReminder else { throw RemindersError.notFound }
      Self.apply(r, to: ek)
      try store.save(ek, commit: true)
    }
  }

  public func delete(id: String) async throws {
    try requireAccess()
    // Fehlt die Erinnerung schon, ist das Ziel erreicht.
    try await store.run { store in
      guard let ek = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
      try store.remove(ek, commit: true)
    }
  }

  // MARK: Abbildung (ohne EventKit-Freigabe prüfbar)

  static func mapReminder(_ r: EKReminder) -> ExternalReminder {
    let notes = r.notes.flatMap { $0.isEmpty ? nil : $0 }
    return ExternalReminder(
      id: r.calendarItemIdentifier, title: r.title ?? "", notes: notes,
      due: dueString(from: r.dueDateComponents), done: r.isCompleted,
      listId: r.calendar?.calendarIdentifier)
  }

  static func apply(_ r: ExternalReminder, to ek: EKReminder) {
    ek.title = r.title
    ek.notes = r.notes
    ek.dueDateComponents = dueComponents(from: r.due)
    ek.isCompleted = r.done
  }

  /// "YYYY-MM-DD" → nur Datum; "YYYY-MM-DDTHH:mm" → Datum und Uhrzeit. Sonst nil.
  static func dueComponents(from due: String?) -> DateComponents? {
    guard let due else { return nil }
    let datePart = LocalTime.datePart(due)
    let nums = datePart.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
    guard datePart.count == 10, nums.count == 3 else { return nil }
    var dc = DateComponents(calendar: Calendar(identifier: .gregorian),
                            year: nums[0], month: nums[1], day: nums[2])
    guard (1...12).contains(nums[1]), (1...31).contains(nums[2]) else { return nil }
    if due.count > 10 {
      let rest = due.dropFirst(10)
      guard rest.hasPrefix("T") else { return nil }
      let hm = rest.dropFirst().split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
      guard hm.count >= 2, (0...23).contains(hm[0]), (0...59).contains(hm[1]) else { return nil }
      dc.hour = hm[0]
      dc.minute = hm[1]
    }
    return dc
  }

  /// Gegenstück zu `dueComponents`. Ohne Uhrzeit nur das Datum.
  static func dueString(from dc: DateComponents?) -> String? {
    guard let dc, let y = dc.year, let m = dc.month, let d = dc.day else { return nil }
    let date = String(format: "%04ld-%02ld-%02ld", y, m, d)
    guard let h = dc.hour else { return date }
    return date + String(format: "T%02ld:%02ld", h, dc.minute ?? 0)
  }
}
