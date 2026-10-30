// VERTRAG (nur Orchestrator ändert). Port von src/shared/entities.ts
// (BAUPLAN.md Abschnitt 6). Alle Zeitfelder sind lokale, zonenlose
// ISO-Strings (siehe Time.swift).
//
// Namen mit Präfix, wo Swift/Foundation/SwiftUI schon Typen gleichen Namens
// haben: `TabyTask` (Swift `Task`), `TabySettings` (SwiftUI `Settings`),
// `TabyNotification` (Foundation `Notification`).
import Foundation

/// Kategorie einer Aufgabe oder eines Ordners ("arbeit", "privat" oder eigene wie "sport").
/// nil = keine Kategorie (erscheint nur in „Alle“). Namen und Symbole stehen in
/// `TabySettings.taskCategories`; `allCases` sind nur die beiden eingebauten.
public struct TaskCategory: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init?(_ raw: String) {
    let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !v.isEmpty else { return nil }
    self.rawValue = v
  }
  public static let arbeit = TaskCategory(rawValue: "arbeit")
  public static let privat = TaskCategory(rawValue: "privat")
  public static let allCases: [TaskCategory] = [.arbeit, .privat]

  /// Anzeigename ohne Einstellungen: eingebaute Namen, sonst der Rohwert mit großem Anfang.
  public var title: String {
    switch rawValue {
    case "arbeit": "Arbeit"
    case "privat": "Privat"
    default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
  }
}

/// Eine Kategorie, wie der Nutzer sie angelegt hat (Einstellungen → Aufgaben). Eingebaut: Arbeit, Privat.
public struct TaskCategoryDef: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  /// SF-Symbol, z. B. "briefcase.fill".
  public var symbol: String
  public init(id: String, name: String, symbol: String) { self.id = id; self.name = name; self.symbol = symbol }
  public static let builtIn: [TaskCategoryDef] = [
    TaskCategoryDef(id: "arbeit", name: "Arbeit", symbol: "briefcase.fill"),
    TaskCategoryDef(id: "privat", name: "Privat", symbol: "house.fill"),
  ]
}

public struct TabyTask: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var notes: String?
  /// Datum ("YYYY-MM-DD") oder lokale Zeit ("YYYY-MM-DDTHH:mm"), optional.
  public var due: String?
  public var done: Bool
  public var doneAt: String?
  public var createdAt: String
  public var category: TaskCategory?
  /// Ordner (`TaskFolder.id`), nil = in keinem Ordner.
  public var folderId: String?
  /// Wiederholung; beim Erledigen legt der Kern die nächste Aufgabe mit neuer Fälligkeit an.
  public var recurrence: TaskRecurrence?
  /// Geschätzte Dauer in Minuten, nil = Standard-Fokuszeit.
  public var minutes: Int?
  /// Bearbeitungsstand offener Aufgaben; erledigt ist weiterhin `done`.
  public var status: TaskStatus
  /// Kennzeichen (ohne „#“), gleiche Schreibweise wie bei Notizen.
  public var tags: [String]

  public init(id: String, title: String, notes: String? = nil, due: String? = nil, done: Bool = false,
              doneAt: String? = nil, createdAt: String, category: TaskCategory? = nil, folderId: String? = nil,
              recurrence: TaskRecurrence? = nil, minutes: Int? = nil, status: TaskStatus = .open,
              tags: [String] = []) {
    self.id = id; self.title = title; self.notes = notes; self.due = due
    self.done = done; self.doneAt = doneAt; self.createdAt = createdAt; self.category = category
    self.folderId = folderId; self.recurrence = recurrence; self.minutes = minutes; self.status = status; self.tags = tags
  }
}

/// Stand einer offenen Aufgabe (Notizen zur Aufgabe zeigen denselben Stand).
public enum TaskStatus: String, Codable, Equatable, Sendable, CaseIterable {
  case open, inProgress, needsInfo

  public var title: String {
    switch self {
    case .open: "Offen"
    case .inProgress: "In Bearbeitung"
    case .needsInfo: "Info fehlt"
    }
  }

  public var symbol: String {
    switch self {
    case .open: "circle"
    case .inProgress: "play.circle.fill"
    case .needsInfo: "questionmark.circle.fill"
    }
  }
}

public enum TaskRecurrence: String, Codable, Equatable, Sendable, CaseIterable {
  case daily, weekdays, weekly, monthly

  public var title: String {
    switch self {
    case .daily: "Täglich"
    case .weekdays: "Werktags"
    case .weekly: "Wöchentlich"
    case .monthly: "Monatlich"
    }
  }
}

/// Selbst angelegter Aufgaben-Ordner (unabhängig von Kategorie Arbeit/Privat).
public struct TaskFolder: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var createdAt: String
  /// Kategorie, zu der der Ordner gehört (`TaskCategory.rawValue`); nil = nur unter „Alle“.
  public var categoryId: String?
  public init(id: String, name: String, createdAt: String, categoryId: String? = nil) {
    self.id = id; self.name = name; self.createdAt = createdAt; self.categoryId = categoryId
  }
}

public struct Note: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var content: String
  public var createdAt: String
  public var updatedAt: String
  /// Zugeordnete Aufgabe (`TabyTask.id`), nil = keine. Die Aufgabe zeigt ihre Notizen an.
  public var taskId: String?
  /// Kennzeichen (ohne „#“); Aufgaben zeigen die ihrer Notizen mit an.
  public var tags: [String]
  /// Schlüssel des Termins (`MeetingCompanion.key`), wenn die Notiz die Agenda/Mitschrift zu einem Termin ist.
  public var meetingKey: String?

  public init(id: String, title: String, content: String, createdAt: String, updatedAt: String,
              taskId: String? = nil, tags: [String] = [], meetingKey: String? = nil) {
    self.id = id; self.title = title; self.content = content
    self.createdAt = createdAt; self.updatedAt = updatedAt; self.taskId = taskId
    self.tags = tags; self.meetingKey = meetingKey
  }
}

public struct Habit: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var archived: Bool
  public var createdAt: String
  /// Im Code berechnet.
  public var streak: Int
  public var checkedToday: Bool

  public init(id: String, name: String, description: String? = nil, archived: Bool = false, createdAt: String,
              streak: Int = 0, checkedToday: Bool = false) {
    self.id = id; self.name = name; self.description = description; self.archived = archived
    self.createdAt = createdAt; self.streak = streak; self.checkedToday = checkedToday
  }
}

public enum ReminderSource: String, Codable, Sendable {
  case task, event, job
}

public struct Reminder: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var source: ReminderSource
  public var sourceRef: String
  public var dueAt: String
  /// nil = offen
  public var firedAt: String?
  public var acknowledgedAt: String?

  public init(id: String, source: ReminderSource, sourceRef: String, dueAt: String, firedAt: String? = nil,
              acknowledgedAt: String? = nil) {
    self.id = id; self.source = source; self.sourceRef = sourceRef; self.dueAt = dueAt
    self.firedAt = firedAt; self.acknowledgedAt = acknowledgedAt
  }
}

/// JSON-Form wie in TS: {"type":"daily","time":"08:00"} usw.
public enum JobRule: Codable, Equatable, Sendable {
  case daily(time: String)
  /// days: ISO-Wochentage, Montag = 1 … Sonntag = 7 (wie TS/BAUPLAN 9).
  /// Der Planer akzeptiert 0 zusätzlich als Sonntag (Altdaten).
  case weekly(days: [Int], time: String)
  case once(at: String)

  private enum CodingKeys: String, CodingKey { case type, time, days, at }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "daily": self = .daily(time: try c.decode(String.self, forKey: .time))
    case "weekly":
      self = .weekly(days: try c.decode([Int].self, forKey: .days), time: try c.decode(String.self, forKey: .time))
    case "once": self = .once(at: try c.decode(String.self, forKey: .at))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unbekannte Regel \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .daily(let time):
      try c.encode("daily", forKey: .type); try c.encode(time, forKey: .time)
    case .weekly(let days, let time):
      try c.encode("weekly", forKey: .type); try c.encode(days, forKey: .days); try c.encode(time, forKey: .time)
    case .once(let at):
      try c.encode("once", forKey: .type); try c.encode(at, forKey: .at)
    }
  }
}

public enum JobMode: String, Codable, Sendable {
  case readOnly = "read-only"
  case standard
}

public struct Job: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var prompt: String
  public var rule: JobRule
  public var mode: JobMode
  public var enabled: Bool
  public var lastRunAt: String?
  public var createdAt: String

  public init(id: String, name: String, prompt: String, rule: JobRule, mode: JobMode = .standard,
              enabled: Bool = true, lastRunAt: String? = nil, createdAt: String) {
    self.id = id; self.name = name; self.prompt = prompt; self.rule = rule; self.mode = mode
    self.enabled = enabled; self.lastRunAt = lastRunAt; self.createdAt = createdAt
  }
}

public enum JobRunStatus: String, Codable, Sendable {
  case ok, error
  case skippedStale = "skipped-stale"
}

public struct JobRun: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var jobId: String
  public var scheduledFor: String
  public var startedAt: String
  public var status: JobRunStatus
  public var output: String?

  public init(id: String, jobId: String, scheduledFor: String, startedAt: String, status: JobRunStatus,
              output: String? = nil) {
    self.id = id; self.jobId = jobId; self.scheduledFor = scheduledFor; self.startedAt = startedAt
    self.status = status; self.output = output
  }
}

public enum DayStartState: String, Codable, Sendable {
  case none, asked, snoozed, done, skipped
}

public struct DailyState: Codable, Equatable, Sendable {
  public var date: String
  public var state: DayStartState
  public var snoozeUntil: String?

  public init(date: String, state: DayStartState, snoozeUntil: String? = nil) {
    self.date = date; self.state = state; self.snoozeUntil = snoozeUntil
  }
}

/// Tagesabschluss-Zustand pro Tag (gleiche Werte wie der Tagesstart).
public typealias DayEndState = DayStartState

/// Gespeicherter Tagesabschluss eines Tages.
public struct DayEndRecord: Codable, Equatable, Sendable {
  public var date: String
  public var state: DayEndState
  public var snoozeUntil: String?
  public init(date: String, state: DayEndState, snoozeUntil: String? = nil) {
    self.date = date; self.state = state; self.snoozeUntil = snoozeUntil
  }
}

/// Fokus-Sitzung (Pomodoro), optional an eine Aufgabe gebunden.
public struct FocusSession: Codable, Equatable, Identifiable, Sendable {
  public enum Phase: String, Codable, Sendable { case work, rest }
  public var id: String
  public var taskId: String?
  /// Anzeigename: Aufgabentitel oder "Fokus".
  public var title: String
  public var phase: Phase
  public var startedAt: String
  /// Lokale Zeit "YYYY-MM-DDTHH:mm:ss" (Sekunden, damit der Countdown genau ist).
  public var endsAt: String
  public var minutes: Int
  /// Gesetzt, solange die Sitzung angehalten ist: der Countdown steht dann auf `endsAt − pausedAt`.
  public var pausedAt: String?
  public init(id: String, taskId: String? = nil, title: String, phase: Phase = .work, startedAt: String,
              endsAt: String, minutes: Int, pausedAt: String? = nil) {
    self.id = id; self.taskId = taskId; self.title = title; self.phase = phase
    self.startedAt = startedAt; self.endsAt = endsAt; self.minutes = minutes; self.pausedAt = pausedAt
  }
}

/// Fakt, den sich der Assistent merkt ("Zahnarzt ist Dr. X"), fließt in den Systemprompt.
public struct Memory: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var text: String
  public var createdAt: String
  public init(id: String, text: String, createdAt: String) {
    self.id = id; self.text = text; self.createdAt = createdAt
  }
}

public enum CalendarSourceKind: String, Codable, Sendable, CaseIterable {
  case local, apple, notion, ics
  /// CalDAV (Nextcloud, iCloud, Google mit App-Passwort); Passwort im Schlüsselbund.
  case caldav
  /// Outlook/Microsoft 365 über Microsoft Graph (Anmeldung per Gerätecode, Token im Schlüsselbund).
  case microsoft
}

public struct CalendarSourceConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: CalendarSourceKind
  public var config: [String: JSONValue]
  public var enabled: Bool
  public var isDefaultWrite: Bool

  public init(id: String, kind: CalendarSourceKind, config: [String: JSONValue] = [:], enabled: Bool = true,
              isDefaultWrite: Bool = false) {
    self.id = id; self.kind = kind; self.config = config; self.enabled = enabled; self.isDefaultWrite = isDefaultWrite
  }
}

/// Anlegen (id == nil) oder Aktualisieren (id gesetzt) einer Kalenderquelle.
public struct CalendarSourceDraft: Equatable, Sendable {
  public var id: String?
  public var kind: CalendarSourceKind
  public var config: [String: JSONValue]?
  public var enabled: Bool?
  public var isDefaultWrite: Bool?

  public init(id: String? = nil, kind: CalendarSourceKind, config: [String: JSONValue]? = nil, enabled: Bool? = nil,
              isDefaultWrite: Bool? = nil) {
    self.id = id; self.kind = kind; self.config = config; self.enabled = enabled; self.isDefaultWrite = isDefaultWrite
  }
}

/// Ein Kalender des Systems (Apple/iCloud, Google …), wählbar unter Kalenderquellen → Apple.
public struct AppleCalendarInfo: Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  /// Konto, zu dem der Kalender gehört („iCloud“, „Google“ …).
  public var account: String
  public init(id: String, title: String, account: String) { self.id = id; self.title = title; self.account = account }
}

public enum ActionActor: String, Codable, Sendable {
  case user, assistant, job
}

public struct ActionLogEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var at: String
  public var actor: ActionActor
  public var tool: String
  public var argsJson: String
  public var ok: Bool
  public var error: String?

  public init(id: String, at: String, actor: ActionActor, tool: String, argsJson: String, ok: Bool,
              error: String? = nil) {
    self.id = id; self.at = at; self.actor = actor; self.tool = tool; self.argsJson = argsJson
    self.ok = ok; self.error = error
  }
}
