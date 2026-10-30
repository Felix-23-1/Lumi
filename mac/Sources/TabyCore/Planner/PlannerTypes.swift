// Kleine Abhängigkeits-Schnittstellen des Planers (Port von src/main/planner/types.ts).
// Der Speicher (Agent A) implementiert die Tabellen separat; der Integrator passt
// sie über diese Protokolle an. Namen tragen das Präfix `Planner`, damit sie im
// gemeinsamen Modul TabyCore nicht mit Store-Typen kollidieren.
import Foundation

/// Erinnerungen (`reminders`). Synchron, weil SQLite synchron ist; Fehler werden geworfen
/// und vom Planer pro Schritt abgefangen (ein Tick stürzt nie ab).
public protocol PlannerReminderStore: AnyObject {
  func findBySource(_ source: ReminderSource, _ sourceRef: String) throws -> Reminder?
  /// Legt an oder ersetzt (Schlüssel: `reminder.id`).
  func upsert(_ reminder: Reminder) throws
  func listAll() throws -> [Reminder]
  func markFired(_ id: String, firedAt: String) throws
  /// Setzt `acknowledgedAt` nur, wo es noch nil ist.
  func acknowledge(_ ids: [String], acknowledgedAt: String) throws
}

/// Auftrags-Läufe (`job_runs`).
public protocol PlannerJobRunStore: AnyObject {
  func add(_ run: JobRun) throws
  func listByJob(_ jobId: String) throws -> [JobRun]
  /// Jüngster Lauf (nach `scheduledFor`); nil ohne Läufe.
  func latestRun(jobId: String) throws -> JobRun?
}

/// Aufgaben-Quelle (Store).
public typealias PlannerTaskSource = () async throws -> [TabyTask]
/// Auftrags-Quelle (Store).
public typealias PlannerJobSource = () async throws -> [Job]
/// Termine aller aktiven Kalendermodule im Bereich `from`…`to` ("YYYY-MM-DD") und die Quellen,
/// die dabei nicht antworteten (dann fehlen Termine vielleicht nur scheinbar).
public typealias PlannerEventSource = (_ from: String, _ to: String) async throws -> PlannerEventRead

public struct PlannerEventRead: Sendable {
  public var events: [CalendarEvent]
  /// Kennungen der nicht erreichbaren Kalenderquellen; leer = alle haben geantwortet.
  public var unreachableSources: [String]
  public init(events: [CalendarEvent], unreachableSources: [String] = []) {
    self.events = events; self.unreachableSources = unreachableSources
  }
}

/// Ergebnis eines Auftrags-Laufs.
public struct JobRunResult: Equatable, Sendable {
  public var ok: Bool
  public var output: String?
  public init(ok: Bool, output: String? = nil) {
    self.ok = ok; self.output = output
  }
}

/// Führt einen Auftrag aus (Integrator: Agent-Schleife im Modus read-only, Ausgabe in den Chat).
public typealias PlannerJobRunner = (Job) async throws -> JobRunResult

/// In-Memory-Speicher für Erinnerungen (Prüfungen und Testmodus, wie TS `stubs.ts`).
public final class InMemoryPlannerReminderStore: PlannerReminderStore {
  private var byId: [String: Reminder] = [:]
  private var order: [String] = []
  private let lock = NSLock()

  public init() {}

  public func findBySource(_ source: ReminderSource, _ sourceRef: String) throws -> Reminder? {
    lock.lock(); defer { lock.unlock() }
    return order.compactMap { byId[$0] }.first { $0.source == source && $0.sourceRef == sourceRef }
  }

  public func upsert(_ reminder: Reminder) throws {
    lock.lock(); defer { lock.unlock() }
    if byId[reminder.id] == nil { order.append(reminder.id) }
    byId[reminder.id] = reminder
  }

  public func listAll() throws -> [Reminder] {
    lock.lock(); defer { lock.unlock() }
    return order.compactMap { byId[$0] }
  }

  public func markFired(_ id: String, firedAt: String) throws {
    lock.lock(); defer { lock.unlock() }
    byId[id]?.firedAt = firedAt
  }

  public func acknowledge(_ ids: [String], acknowledgedAt: String) throws {
    lock.lock(); defer { lock.unlock() }
    for id in ids where byId[id] != nil {
      if byId[id]?.acknowledgedAt == nil { byId[id]?.acknowledgedAt = acknowledgedAt }
    }
  }
}

/// In-Memory-Speicher für Auftrags-Läufe (Prüfungen und Testmodus).
public final class InMemoryPlannerJobRunStore: PlannerJobRunStore {
  private var runs: [JobRun] = []
  private let lock = NSLock()

  public init() {}

  public func add(_ run: JobRun) throws {
    lock.lock(); runs.append(run); lock.unlock()
  }

  public func listByJob(_ jobId: String) throws -> [JobRun] {
    lock.lock(); defer { lock.unlock() }
    return runs.filter { $0.jobId == jobId }
  }

  public func latestRun(jobId: String) throws -> JobRun? {
    lock.lock(); defer { lock.unlock() }
    return runs.filter { $0.jobId == jobId }.max { $0.scheduledFor < $1.scheduledFor }
  }
}
