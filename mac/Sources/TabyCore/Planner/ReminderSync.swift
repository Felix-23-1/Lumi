// Port von src/main/planner/reminder-sync.ts: gewünschte Erinnerungen aus Aufgaben/
// Terminen ableiten und idempotent gegen den Speicher abgleichen.
import Foundation

public struct WantedReminder: Equatable, Sendable {
  public var source: ReminderSource
  public var sourceRef: String
  public var dueAt: String
  public init(source: ReminderSource, sourceRef: String, dueAt: String) {
    self.source = source; self.sourceRef = sourceRef; self.dueAt = dueAt
  }
}

public enum ReminderSync {
  public static func reminderId(_ source: ReminderSource, _ sourceRef: String) -> String {
    "\(source.rawValue):\(sourceRef)"
  }

  /// Offene Aufgaben mit Uhrzeit in `due`. Ganztägige Angaben lösen nichts aus (nur Briefing).
  public static func taskReminders(_ tasks: [TabyTask]) -> [WantedReminder] {
    tasks.compactMap { t in
      guard !t.done, let due = t.due, due.contains("T") else { return nil }
      return WantedReminder(source: .task, sourceRef: t.id, dueAt: due)
    }
  }

  /// Termine mit Uhrzeit erzeugen eine Erinnerung `leadMinutes` vor Beginn; `<= 0` = aus.
  public static func eventReminders(_ events: [CalendarEvent], leadMinutes: Int) -> [WantedReminder] {
    guard leadMinutes > 0 else { return [] }
    return events.compactMap { e in
      guard !e.allDay, let start = LocalTime.parse(e.start),
            let due = LocalTime.calendar.date(byAdding: .minute, value: -leadMinutes, to: start)
      else { return nil }
      return WantedReminder(source: .event, sourceRef: e.id, dueAt: LocalTime.format(due))
    }
  }

  /// Legt Fehlendes an; bei geänderter Fälligkeit wird `dueAt` neu gesetzt und `firedAt`
  /// zurückgesetzt. Unverändertes bleibt unberührt — so wird nie doppelt ausgelöst.
  public static func sync(_ wanted: [WantedReminder], into store: PlannerReminderStore) throws {
    for w in wanted {
      if let existing = try store.findBySource(w.source, w.sourceRef) {
        if existing.dueAt != w.dueAt {
          var updated = existing
          updated.dueAt = w.dueAt
          updated.firedAt = nil
          try store.upsert(updated)
        }
      } else {
        try store.upsert(Reminder(id: reminderId(w.source, w.sourceRef), source: w.source, sourceRef: w.sourceRef,
                                  dueAt: w.dueAt))
      }
    }
  }

  /// Zieht offene Erinnerungen zurück, die nicht mehr gewünscht sind (Aufgabe erledigt oder
  /// gelöscht, Termin aus der Quelle entfernt). Zurückgezogene Erinnerungen werden auf
  /// "bestätigt" gesetzt: sie lösen nie aus und erscheinen nicht als "verpasst".
  ///
  /// Geltungsbereich:
  /// - Aufgaben: die Quelle liefert alle Aufgaben, daher gilt jede nicht gewünschte
  ///   Aufgaben-Erinnerung, unabhängig von ihrer Fälligkeit.
  /// - Termine: nur, wenn der Beginn (Fälligkeit + Vorlauf) im abgerufenen Bereich
  ///   `eventsFrom`…`eventsTo` ("YYYY-MM-DD") liegt. Außerhalb davon ist unbekannt, ob der
  ///   Termin noch existiert, also bleibt die Erinnerung unberührt.
  /// Aufträge ("job") werden hier nicht berührt.
  /// Ist eine Kalenderquelle nicht erreichbar (`eventSourcesReachable` false), fehlt ein Termin nur
  /// scheinbar: dann bleiben alle Termin-Erinnerungen offen.
  public static func retireStale(
    _ wanted: [WantedReminder],
    eventsFrom: String,
    eventsTo: String,
    eventLeadMinutes: Int,
    acknowledgedAt: String,
    eventSourcesReachable: Bool = true,
    in store: PlannerReminderStore
  ) throws {
    let wantedKeys = Set(wanted.map { reminderId($0.source, $0.sourceRef) })
    let lead = max(0, eventLeadMinutes)
    var ids: [String] = []
    for r in try store.listAll() where r.firedAt == nil && r.acknowledgedAt == nil {
      guard r.source == .task || r.source == .event else { continue }
      if wantedKeys.contains(reminderId(r.source, r.sourceRef)) { continue }
      if r.source == .event {
        guard eventSourcesReachable else { continue }
        guard let due = LocalTime.parse(r.dueAt),
              let start = LocalTime.calendar.date(byAdding: .minute, value: lead, to: due)
        else { continue }
        let day = LocalTime.datePart(LocalTime.format(start))
        guard day >= eventsFrom && day <= eventsTo else { continue }
      }
      ids.append(r.id)
    }
    if !ids.isEmpty { try store.acknowledge(ids, acknowledgedAt: acknowledgedAt) }
  }

  /// Teilt offene Erinnerungen in "fällig" (höchstens `grace` Sekunden überfällig → sofort
  /// benachrichtigen) und "verpasst" (länger überfällig, z. B. Mac aus/Ruhezustand → Liste
  /// "Verpasst", Szenario E). Ausgelöste oder bestätigte Erinnerungen werden ignoriert.
  public static func partitionDue(_ reminders: [Reminder], now: Date, grace: TimeInterval)
    -> (due: [Reminder], missed: [Reminder])
  {
    var due: [Reminder] = []
    var missed: [Reminder] = []
    for r in reminders {
      if r.firedAt != nil || r.acknowledgedAt != nil { continue }
      guard let dueAt = LocalTime.parse(r.dueAt) else { continue }
      if dueAt > now { continue }
      if now.timeIntervalSince(dueAt) > grace { missed.append(r) } else { due.append(r) }
    }
    return (due, missed)
  }
}
