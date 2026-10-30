// Notion-Bereich der Aufgabenansicht: Zuklapp-Zustand (gemerkt), Suche im Titel und Auswahl der Quellen.
// Reine Logik ohne Ansicht, damit die Prüfungen ohne Oberfläche laufen.
import Foundation
import TabyCore

enum NotionSectionLogic {
  static let collapsedKey = "tasks.notion.collapsed"

  /// Kennung eines Abschnitts: Quelle und Titel (Wochen-Quellen haben je Woche einen Abschnitt).
  static func sectionId(title: String, sourceId: String?) -> String { "\(sourceId ?? "")|\(title)" }

  /// Gemerkte Zuklappungen. Kaputter Wert = nichts zugeklappt.
  static func parse(_ text: String?) -> Set<String> {
    guard let text, let data = text.data(using: .utf8),
          let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(ids)
  }

  static func stored(_ defaults: UserDefaults = .standard) -> Set<String> {
    parse(defaults.string(forKey: collapsedKey))
  }

  static func store(_ ids: Set<String>, _ defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(ids.sorted()),
          let text = String(data: data, encoding: .utf8) else { return }
    defaults.set(text, forKey: collapsedKey)
  }

  /// Aktiver Filter (Suche oder Quelle) klappt alles auf, damit kein Treffer hinter einem zugeklappten Kopf liegt.
  static func isFolded(_ id: String, collapsed: Set<String>, filterActive: Bool) -> Bool {
    !filterActive && collapsed.contains(id)
  }

  /// Ob ein Filter den Bereich einschränkt: Suchtext oder gewählte Quellen.
  static func filterActive(search: String, sourceIds: Set<String>) -> Bool {
    !trimmed(search).isEmpty || !sourceIds.isEmpty
  }

  /// „Alle zuklappen“, oder wenn alle schon zu sind, „Alle aufklappen“ (nur die sichtbaren Abschnitte).
  static func toggledAll(_ ids: [String], collapsed: Set<String>) -> Set<String> {
    let all = Set(ids)
    if allFolded(ids, collapsed: collapsed) { return collapsed.subtracting(all) }
    return collapsed.union(all)
  }

  static func allFolded(_ ids: [String], collapsed: Set<String>) -> Bool {
    !ids.isEmpty && Set(ids).isSubset(of: collapsed)
  }

  /// Suche im Titel, ohne Groß/Klein und Akzente. Leere Suche findet alles.
  static func matches(_ task: TabyTask, search: String) -> Bool {
    let query = trimmed(search)
    return query.isEmpty || task.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  /// Suche und gewählte Quellen zusammen (UND); leere Quellenauswahl heißt alle Quellen.
  static func filter(_ tasks: [TabyTask], search: String, sourceIds: Set<String>,
                     sourceLinks: [String: String]) -> [TabyTask] {
    tasks.filter { task in
      let sourceOk = sourceIds.isEmpty || sourceIds.contains(sourceLinks[task.id] ?? "")
      return sourceOk && matches(task, search: search)
    }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
