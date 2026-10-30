// VERTRAG (nur Orchestrator ändert). Paket 4 (docs/ROADMAP.md):
// automatisch einplanen, Meeting-Begleiter, Dateien in die Notch, markierten
// Text übernehmen, Sprechen, Wochenplanung, Fokus mit macOS-Fokus.
// Zeiten wie überall als lokale zonenlose Strings.
import Foundation

// MARK: - 1. Automatisch einplanen

/// Ein Block im Tagesplan: Zeit für eine Aufgabe in einer freien Lücke.
public struct PlannedBlock: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var taskId: String
  public var title: String
  /// "YYYY-MM-DDTHH:mm"
  public var start: String
  public var end: String
  /// Vom Nutzer auf eine feste Uhrzeit gesetzt: automatisches Neu-Planen verschiebt den Block nicht.
  /// Optional, damit ältere gespeicherte Pläne ohne das Feld weiter lesbar sind (nil = automatisch).
  public var pinned: Bool?
  /// Warum der Block hier liegt („Fester Termin um 09:15“, „Lücke vor Standup“, „nach der Mittagspause“).
  public var reason: String?
  public init(id: String, taskId: String, title: String, start: String, end: String, pinned: Bool? = nil,
              reason: String? = nil) {
    self.id = id; self.taskId = taskId; self.title = title; self.start = start; self.end = end; self.pinned = pinned
    self.reason = reason
  }
  public var isPinned: Bool { pinned == true }
}

/// Wunsch des Nutzers für eine Aufgabe im heutigen Plan (Paket 13).
public struct PlanItem: Codable, Equatable, Sendable {
  public var taskId: String
  /// Feste Startzeit "HH:mm" (heute); nil = Lumi sucht eine freie Lücke.
  public var start: String?
  /// Dauer in Minuten (5–480).
  public var minutes: Int
  public init(taskId: String, start: String? = nil, minutes: Int = 30) {
    self.taskId = taskId; self.start = start; self.minutes = minutes
  }
}

/// Tagesplan (nur in Lumi gespeichert, nicht im Kalender).
public struct DayPlan: Codable, Equatable, Sendable {
  /// "YYYY-MM-DD"
  public var date: String
  public var blocks: [PlannedBlock]
  /// Aufgaben, die heute nicht mehr hineinpassen (IDs).
  public var unplanned: [String]
  public init(date: String, blocks: [PlannedBlock] = [], unplanned: [String] = []) {
    self.date = date; self.blocks = blocks; self.unplanned = unplanned
  }
}

// MARK: - 2. Meeting-Begleiter

public struct MeetingRef: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Karte vor (Vorbereitung) bzw. nach (Stichpunkte) einem Termin.
public struct MeetingBrief: Codable, Equatable, Identifiable, Sendable {
  public enum Phase: String, Codable, Sendable { case upcoming, ended }
  /// Stabiler Schlüssel des Termins: "<sourceId>|<eventId>|<start>".
  public var id: String
  public var phase: Phase
  public var title: String
  public var start: String
  public var end: String?
  /// Erster Video-/Web-Link aus den Termin-Notizen (Zoom, Meet, Teams, Webex, sonst erster https-Link).
  public var link: String?
  /// Passende Notizen (höchstens 3) und offene Aufgaben (höchstens 5).
  public var notes: [MeetingRef]
  public var tasks: [MeetingRef]
  /// Termin-Notiz (Agenda und Mitschrift), wenn schon vorbereitet; nil = noch keine.
  public var prepNoteId: String?
  public init(id: String, phase: Phase, title: String, start: String, end: String? = nil, link: String? = nil,
              notes: [MeetingRef] = [], tasks: [MeetingRef] = [], prepNoteId: String? = nil) {
    self.id = id; self.phase = phase; self.title = title; self.start = start; self.end = end
    self.link = link; self.notes = notes; self.tasks = tasks; self.prepNoteId = prepNoteId
  }
}

/// Ergebnis der Stichpunkte nach einem Termin.
public struct MeetingNotesResult: Equatable, Sendable {
  public var note: Note
  public var tasks: [TabyTask]
  public init(note: Note, tasks: [TabyTask]) { self.note = note; self.tasks = tasks }
}

// MARK: - 6. Wochenplanung

public struct WeeklyGoal: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// Montag der Woche, für die das Ziel gilt ("YYYY-MM-DD").
  public var week: String
  public var text: String
  public var done: Bool
  public init(id: String, week: String, text: String, done: Bool = false) {
    self.id = id; self.week = week; self.text = text; self.done = done
  }
}

public struct HabitWeek: Codable, Equatable, Sendable {
  public var name: String
  /// Abgehakte Tage in der Woche (0–7).
  public var days: Int
  public var streak: Int
  public init(name: String, days: Int, streak: Int) { self.name = name; self.days = days; self.streak = streak }
}

/// Rückblick auf die laufende Woche (Montag bis heute).
public struct WeeklyReview: Codable, Equatable, Sendable {
  /// Montag der zurückblickenden Woche.
  public var weekStart: String
  public var focusMinutes: Int
  public var tasksDone: Int
  /// Bis zu 5 Titel erledigter Aufgaben (neueste zuerst).
  public var doneTitles: [String]
  public var habits: [HabitWeek]
  public var events: Int
  /// Ziele dieser Woche (vom letzten Mal) mit Erledigt-Stand.
  public var goals: [WeeklyGoal]
  public init(weekStart: String, focusMinutes: Int = 0, tasksDone: Int = 0, doneTitles: [String] = [],
              habits: [HabitWeek] = [], events: Int = 0, goals: [WeeklyGoal] = []) {
    self.weekStart = weekStart; self.focusMinutes = focusMinutes; self.tasksDone = tasksDone
    self.doneTitles = doneTitles; self.habits = habits; self.events = events; self.goals = goals
  }
}

public enum WeeklyReviewAnswer: Equatable, Sendable {
  /// Bis zu 3 Ziele für die nächste Woche speichern (leere werden ignoriert).
  case save([String])
  /// In 30 Minuten noch mal.
  case later
  /// Diese Woche nicht mehr fragen.
  case skip
}

// MARK: - 7. Fokus mit macOS-Fokus

/// Eine installierte App (für die Auswahl „während Fokus ausblenden“).
public struct AppInfo: Codable, Equatable, Identifiable, Sendable {
  /// Bundle-ID
  public var id: String
  public var name: String
  public init(id: String, name: String) { self.id = id; self.name = name }
}

// MARK: - Mithören im Meeting (lokal)

/// Wer mitgeschrieben wird: nur die eigene Stimme (Mikrofon) oder auch die anderen (Systemton, Einwilligung nötig).
public enum MeetingListenMode: String, Codable, Sendable, CaseIterable {
  case onlyMe, everyone
}

/// Läuft gerade eine Mitschrift? (Zustand für Notch und Karte.)
public struct MeetingListening: Codable, Equatable, Sendable {
  public var meetingId: String
  public var title: String
  public var mode: MeetingListenMode
  public var startedAt: String
  /// Zeitpunkt der bestätigten Einwilligung (nur bei `.everyone`), landet auch in der Termin-Notiz.
  public var consentAt: String?
  /// Anzahl mitgeschriebener Zeilen und von dir gesetzter Merker.
  public var lines: Int
  public var markers: Int
  public init(meetingId: String, title: String, mode: MeetingListenMode, startedAt: String, consentAt: String? = nil,
              lines: Int = 0, markers: Int = 0) {
    self.meetingId = meetingId; self.title = title; self.mode = mode; self.startedAt = startedAt
    self.consentAt = consentAt; self.lines = lines; self.markers = markers
  }
}

/// Mögliche Aufgabe aus der Mitschrift. `evidence` ist ein wörtliches Zitat aus dem Text (vom Code geprüft).
public struct ActionCandidate: Codable, Equatable, Identifiable, Sendable {
  public enum Confidence: String, Codable, Sendable {
    /// Klare Zusage („Ich mache X bis Freitag“): vorausgewählt.
    case clear
    /// Vermutet („wir sollten …“, kein Zuständiger oder kein Datum): nicht vorausgewählt, du entscheidest.
    case guess
    /// Von dir mit dem Merker gesetzt („Das ist eine Aufgabe“): vorausgewählt.
    case marked
  }
  public var id: String
  public var text: String
  /// "ich", ein Name oder nil = unklar.
  public var owner: String?
  /// Lokales Datum "YYYY-MM-DD" (vom Code berechnet) oder nil.
  public var due: String?
  public var confidence: Confidence
  public var evidence: String
  /// Sekunden seit Beginn der Mitschrift (für „Stelle ansehen“).
  public var atSeconds: Int
  public init(id: String, text: String, owner: String? = nil, due: String? = nil, confidence: Confidence,
              evidence: String, atSeconds: Int = 0) {
    self.id = id; self.text = text; self.owner = owner; self.due = due; self.confidence = confidence
    self.evidence = evidence; self.atSeconds = atSeconds
  }
}
