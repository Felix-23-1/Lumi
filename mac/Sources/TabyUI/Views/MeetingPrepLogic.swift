// Reine Auswahl-Logik für „Notizen mitnehmen“ (ohne SwiftUI): Vorauswahl aus den
// Vorschlägen des Termins, Umschalten, Suche über Titel und Kennzeichen und die
// Zeilen der Liste. Alles hier ist in MeetingPrepChecks prüfbar.
import Foundation
import TabyCore

enum MeetingPrepLogic {
  /// Gewählte Notizen und Aufgaben (Ids).
  struct Selection: Equatable {
    var noteIds: Set<String> = []
    var taskIds: Set<String> = []
  }

  /// Eine Zeile der Auswahl; `ref` ist die Id der Notiz bzw. Aufgabe.
  struct Row: Identifiable, Equatable {
    let ref: String
    let title: String
    let tags: [String]
    let isTask: Bool
    var id: String { (isTask ? "task|" : "note|") + ref }
  }

  /// Vorschläge des Termins sind von Anfang an gewählt.
  static func preselected(_ m: MeetingBrief) -> Selection {
    Selection(noteIds: Set(m.notes.map(\.id)), taskIds: Set(m.tasks.map(\.id)))
  }

  static func isOn(_ s: Selection, _ r: Row) -> Bool {
    r.isTask ? s.taskIds.contains(r.ref) : s.noteIds.contains(r.ref)
  }

  /// Wählt eine Zeile ab bzw. wieder zu.
  static func toggled(_ s: Selection, _ r: Row) -> Selection {
    var out = s
    if r.isTask {
      if out.taskIds.contains(r.ref) { out.taskIds.remove(r.ref) } else { out.taskIds.insert(r.ref) }
    } else {
      if out.noteIds.contains(r.ref) { out.noteIds.remove(r.ref) } else { out.noteIds.insert(r.ref) }
    }
    return out
  }

  /// Gewählte Ids in Listenreihenfolge (die Agenda folgt dieser Reihenfolge).
  static func chosen(_ rows: [Row], _ s: Selection) -> (noteIds: [String], taskIds: [String]) {
    let on = rows.filter { isOn(s, $0) }
    return (on.filter { !$0.isTask }.map(\.ref), on.filter(\.isTask).map(\.ref))
  }

  /// Suche ohne Groß/Klein-Unterschied über Titel und Kennzeichen; führendes „#“ und Leerzeichen zählen nicht.
  static func matches(_ query: String, title: String, tags: [String]) -> Bool {
    let q = String(query.trimmingCharacters(in: .whitespaces).lowercased().drop { $0 == "#" })
    guard !q.isEmpty else { return true }
    return title.lowercased().contains(q) || tags.contains { $0.lowercased().contains(q) }
  }

  /// Vorschläge zuerst (Reihenfolge des Termins); bei „Weitere…“ danach alle übrigen Notizen und offenen Aufgaben.
  /// Ohne Doppelte, gefiltert nach der Suche.
  static func rows(meeting m: MeetingBrief, notes: [Note], tasks: [TabyTask], query: String, more: Bool) -> [Row] {
    let noteTags = Dictionary(notes.map { ($0.id, $0.tags) }, uniquingKeysWith: { a, _ in a })
    let taskTags = Dictionary(tasks.map { ($0.id, $0.tags) }, uniquingKeysWith: { a, _ in a })
    let suggestedNotes = Set(m.notes.map(\.id))
    let suggestedTasks = Set(m.tasks.map(\.id))
    var out = m.notes.map { Row(ref: $0.id, title: $0.title, tags: noteTags[$0.id] ?? [], isTask: false) }
    out += m.tasks.map { Row(ref: $0.id, title: $0.title, tags: taskTags[$0.id] ?? [], isTask: true) }
    if more {
      out += notes.filter { !suggestedNotes.contains($0.id) }
        .map { Row(ref: $0.id, title: $0.title, tags: $0.tags, isTask: false) }
      out += tasks.filter { !$0.done && !suggestedTasks.contains($0.id) }
        .map { Row(ref: $0.id, title: $0.title, tags: $0.tags, isTask: true) }
    }
    return out.filter { matches(query, title: $0.title, tags: $0.tags) }
  }

  /// Rückmeldung nach „Zusammenfassung erstellen“.
  static func summaryText(taskCount n: Int) -> String {
    switch n {
    case 0: "Zusammenfassung gespeichert"
    case 1: "Zusammenfassung + 1 Aufgabe angelegt"
    default: "Zusammenfassung + \(n) Aufgaben angelegt"
    }
  }
}
