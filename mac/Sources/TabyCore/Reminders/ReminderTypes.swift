// Apple-Erinnerungen-Abgleich: öffentliche Typen und Protokolle.
//
// Die Seite „Apple“ hinter `RemindersBackend` (EventKit) und die Seite „Lumi“
// hinter `TaskSide` (Speicher, vom Orchestrator angebunden) sind austauschbar,
// damit der Abgleich ohne echte Freigabe geprüft werden kann.
import Foundation

/// Eine Erinnerung auf der Apple-Seite.
public struct ExternalReminder: Equatable, Sendable {
  public var id: String
  public var title: String
  public var notes: String?
  /// "YYYY-MM-DD" oder "YYYY-MM-DDTHH:mm", optional.
  public var due: String?
  public var done: Bool
  /// Liste (Kalender-Id) der Erinnerung. Nur zum Filtern beim Übernehmen neuer Erinnerungen.
  public var listId: String?

  public init(id: String, title: String, notes: String? = nil, due: String? = nil, done: Bool = false,
              listId: String? = nil) {
    self.id = id; self.title = title; self.notes = notes; self.due = due; self.done = done
    self.listId = listId
  }
}

/// Verknüpfung zwischen einer Lumi-Aufgabe und einer Apple-Erinnerung.
/// Die `snap*`-Felder sind der gemeinsame Stand beim letzten Abgleich
/// (Grundlage für die Drei-Wege-Zusammenführung).
public struct ReminderLink: Equatable, Sendable {
  public var taskId: String
  public var externalId: String
  public var snapTitle: String
  public var snapDue: String?
  public var snapDone: Bool
  public var syncedAt: String
  /// Liste der Erinnerung beim letzten Abgleich. nil = unbekannt (ältere Stände).
  public var listId: String?

  public init(taskId: String, externalId: String, snapTitle: String, snapDue: String?, snapDone: Bool,
              syncedAt: String, listId: String? = nil) {
    self.taskId = taskId; self.externalId = externalId; self.snapTitle = snapTitle
    self.snapDue = snapDue; self.snapDone = snapDone; self.syncedAt = syncedAt; self.listId = listId
  }
}

/// Apple-Seite (EventKit oder Test-Attrappe).
public protocol RemindersBackend: AnyObject {
  /// Fragt nach Zugriff, falls nötig. false = kein Zugriff (kein Absturz, kein Dialog ohne Begründung).
  func requestAccess() async -> Bool
  func lists() async throws -> [ReminderListInfo]
  /// listIds nil = alle Listen.
  func fetchAll(listIds: [String]?) async throws -> [ExternalReminder]
  /// listId nil = Standardliste. Liefert die neue id.
  func create(_ r: ExternalReminder, listId: String?) async throws -> String
  func update(_ r: ExternalReminder) async throws
  /// Löscht die Erinnerung. Eine bereits fehlende Erinnerung ist kein Fehler.
  func delete(id: String) async throws
}

/// Lumi-Seite (der Orchestrator passt den Speicher an).
public protocol TaskSide: AnyObject {
  func tasks() throws -> [TabyTask]
  func addTask(title: String, notes: String?, due: String?) throws -> TabyTask
  func updateTask(id: String, title: String, notes: String?, due: String?) throws
  func setDone(id: String, done: Bool) throws
  /// Löscht die Aufgabe. Eine bereits fehlende Aufgabe ist kein Fehler.
  func deleteTask(id: String) throws
  func links() throws -> [ReminderLink]
  func saveLink(_ l: ReminderLink) throws
  func deleteLink(taskId: String) throws
}

public enum SyncAction: Equatable {
  case createExternal(taskId: String)
  case createTask(externalId: String)
  case pushToExternal(taskId: String)
  case pullToTask(externalId: String)
  /// Erinnerung in Apple gelöscht, Aufgabe noch offen → Aufgabe bleibt, sie wird nicht neu nach Apple geschrieben.
  case deleteTask(taskId: String)
  /// Aufgabe in Lumi gelöscht → Erinnerung in Apple löschen.
  case deleteExternal(externalId: String)
  /// Nur die Verknüpfung lösen, nichts löschen. Gilt, wenn gegenüber schon erledigt ist
  /// oder beide Seiten fehlen.
  case unlink(taskId: String)
}

/// Ergebnis eines Abgleichs. Fehler je Aktion stehen in `errors` (deutsch).
public struct SyncReport: Equatable, Sendable {
  public var createdExternal: Int
  public var createdTask: Int
  public var pushed: Int
  public var pulled: Int
  public var deletedTask: Int
  public var deletedExternal: Int
  public var unlinked: Int
  /// Aufgaben, deren Erinnerung in Apple fehlte: sie bleiben in Lumi offen, nur die Verknüpfung fällt weg.
  public var removedFromApple: [String] = []
  /// Aufgaben, deren eigene Lumi-Änderung von Apples Wert überschrieben wurde (Apple gewinnt).
  public var overwrittenLumiEdits: [String] = []
  public var errors: [String]

  public init(createdExternal: Int = 0, createdTask: Int = 0, pushed: Int = 0, pulled: Int = 0,
              deletedTask: Int = 0, deletedExternal: Int = 0, unlinked: Int = 0, errors: [String] = []) {
    self.createdExternal = createdExternal; self.createdTask = createdTask; self.pushed = pushed
    self.pulled = pulled; self.deletedTask = deletedTask; self.deletedExternal = deletedExternal
    self.unlinked = unlinked; self.errors = errors
  }
}

/// Fehler des Abgleichs. Die Texte gehen unverändert in die Oberfläche.
public enum RemindersError: Error, LocalizedError, Equatable {
  case accessDenied
  case listUnavailable
  case notFound
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .accessDenied: return "Kein Zugriff auf Erinnerungen. Bitte in den Systemeinstellungen freigeben."
    case .listUnavailable: return "Die Erinnerungsliste ist nicht verfügbar."
    case .notFound: return "Die Erinnerung wurde in Apple Erinnerungen nicht gefunden."
    case .timedOut: return "Apple Erinnerungen antwortet nicht. Der Abgleich wird später erneut versucht."
    }
  }
}
