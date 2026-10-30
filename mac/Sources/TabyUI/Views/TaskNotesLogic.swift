// Notizen einer Aufgabe: Zuordnung, Titel der zugeordneten Aufgabe und Vorschau.
// Reine Logik ohne Ansicht, damit die Prüfungen sie ohne Oberfläche testen können.
import Foundation
import TabyCore

enum TaskNotesLogic {
  /// Notizen mit dieser Aufgabe, in der Reihenfolge der Liste (zuletzt geändert zuerst).
  static func notes(of taskId: String, in notes: [Note]) -> [Note] {
    notes.filter { $0.taskId == taskId }
  }

  /// Titel der zugeordneten Aufgabe; nil, wenn keine Zuordnung besteht oder die Aufgabe fehlt.
  static func taskTitle(for note: Note, in tasks: [TabyTask]) -> String? {
    guard let id = note.taskId else { return nil }
    return tasks.first { $0.id == id }?.title
  }

  /// Aufgaben, die im Zuordnen-Menü angeboten werden (offene).
  static func assignable(_ tasks: [TabyTask]) -> [TabyTask] {
    tasks.filter { !$0.done }
  }

  /// Anzeigetitel einer Notiz; ohne Titel ein Platzhalter.
  static func displayTitle(_ note: Note) -> String {
    let t = note.title.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? "Ohne Titel" : t
  }

  /// Die ersten `lines` Zeilen des Inhalts, Checkboxen als ☐/☑ (wie in der Notizliste).
  static func preview(_ content: String, lines: Int = 2) -> String {
    NoteCheckboxes.lines(content)
      .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.kind == .checkbox }
      .prefix(lines)
      .map { line in line.kind == .checkbox ? (line.checked ? "☑ " : "☐ ") + line.text : line.text }
      .joined(separator: "\n")
  }
}
