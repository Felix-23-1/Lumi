// Reine Logik für Notizen nach Kategorie (Arbeit/Privat) und für die Aufgaben-Auswahl beim Zuordnen:
// Kategorie einer Notiz, Kennzeichen setzen, Suche und Sortierung der Aufgaben. Ohne Ansicht, damit prüfbar.
import Foundation
import TabyCore

enum NoteCategoryLogic {
  /// Kennungen der Filter-Auswahl (ohne „Alle“): Arbeit und Privat.
  static let categories: [TaskCategory] = [.arbeit, .privat]

  /// Kategorie einer Notiz (Kennung wie „arbeit“). Ist sie einer vorhandenen Aufgabe zugeordnet,
  /// gilt deren Kategorie (auch nil); sonst ein Kennzeichen, das so heißt wie die Kategorie.
  static func category(of note: Note, tasks: [TabyTask]) -> String? {
    if let id = note.taskId, let task = tasks.first(where: { $0.id == id }) {
      return task.category?.rawValue
    }
    return categories.first { cat in note.tags.contains { TagLogic.key($0) == cat.rawValue } }?.rawValue
  }

  /// Passt die Notiz zum Filter? nil = Alle.
  static func matches(_ note: Note, filter: String?, tasks: [TabyTask]) -> Bool {
    filter == nil || category(of: note, tasks: tasks) == filter
  }

  /// Kennzeichen der Notiz setzen (`on`) oder entfernen. Arbeit und Privat schließen sich aus:
  /// Setzen entfernt das andere Kennzeichen, damit eine Notiz nie in beiden Filtern landet.
  static func setMark(_ tags: [String], category: String, on: Bool) -> [String] {
    guard on else { return TagLogic.removing(category, from: tags) }
    let others = categories.map(\.rawValue).filter { $0 != category }
    var out = tags.filter { !others.contains(TagLogic.key($0)) }
    if !TagLogic.contains(out, name: category) {
      out.append(TaskCategory(rawValue: category).title)
    }
    return out
  }
}

enum NoteTaskPickLogic {
  /// Aufgaben für die Auswahl: Suche über Titel und Kennzeichen, Kategorie (nil = alle), erledigte nur mit Schalter.
  /// Die aktuelle Zuordnung (`keep`) bleibt immer sichtbar. Reihenfolge: offene zuerst, dann nach Fälligkeit
  /// (ohne Fälligkeit zuletzt), dann nach Titel.
  static func rows(_ tasks: [TabyTask], query: String, category: String?, showDone: Bool, keep: String?) -> [TabyTask] {
    tasks
      .filter { t in
        t.id == keep
          || ((showDone || !t.done)
            && (category == nil || t.category?.rawValue == category)
            && MeetingPrepLogic.matches(query, title: t.title, tags: t.tags))
      }
      .sorted { a, b in
        if a.done != b.done { return !a.done }
        let da = a.due ?? "", db = b.due ?? ""
        if (a.due == nil) != (b.due == nil) { return a.due != nil }
        if da != db { return da < db }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
      }
  }
}
