// Einstellungen „Notion-Stände zuordnen“: reine Logik. Zeilen je Notion-Stand und die Umrechnung
// zwischen Auswahl in der Karte und dem Wert in `TabySettings.notionStatusMap`.
import Foundation
import TabyCore

/// Auswahl je Notion-Stand. „Automatisch“ entfernt den Eintrag, „Nicht ändern“ speichert "".
enum NotionStatusChoice: String, CaseIterable, Hashable {
  case automatic, open, inProgress, needsInfo, keep

  var title: String {
    switch self {
    case .automatic: "Automatisch"
    case .open: "Offen"
    case .inProgress: "In Bearbeitung"
    case .needsInfo: "Info fehlt"
    case .keep: "Nicht ändern"
    }
  }
}

/// Eine Zeile der Karte: Notion-Stand (wie angezeigt), Auswahl und der Vorschlag von Lumi.
struct NotionStatusRow: Equatable, Identifiable {
  let text: String
  let choice: NotionStatusChoice
  let suggestion: TaskStatus?

  var id: String { NotionStatusRules.key(text) }
}

enum NotionStatusMapLogic {
  /// Höchstens so viele Stände in der Karte; mehr sind in der Praxis kaum sinnvoll.
  static let maxRows = 20

  static let helper = "Lumi übernimmt diesen Stand bei jedem Abgleich, wenn er sich in Notion ändert. "
    + "Eigene Änderungen in Lumi bleiben, bis sich der Stand in Notion ändert."

  /// Karte nur bei eingeschaltetem Notion und mindestens einem Stand.
  static func showsSection(notionEnabled: Bool, rows: [NotionStatusRow]) -> Bool {
    notionEnabled && !rows.isEmpty
  }

  /// Verschiedene Notion-Stände (je Schlüssel einmal), alphabetisch nach Schlüssel, höchstens `maxRows`.
  /// Angezeigt wird die kleinste Schreibweise je Schlüssel, damit die Reihenfolge stabil ist.
  static func rows(meta: [String: NotionTaskMeta], map: [String: String]) -> [NotionStatusRow] {
    var shown: [String: String] = [:]
    for m in meta.values {
      let text = (m.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let key = NotionStatusRules.key(text)
      guard !key.isEmpty else { continue }
      if let old = shown[key], old <= text { continue }
      shown[key] = text
    }
    return shown.sorted { $0.key < $1.key }.prefix(maxRows).map { entry in
      NotionStatusRow(text: entry.value, choice: choice(forMapValue: map[entry.key]),
                      suggestion: NotionStatusRules.suggested(forNotion: entry.value))
    }
  }

  /// Auswahl zu einem Eintrag der Karte: fehlt er, gilt „Automatisch“; "" heißt „Nicht ändern“.
  static func choice(forMapValue value: String?) -> NotionStatusChoice {
    guard let value else { return .automatic }
    if value.isEmpty { return .keep }
    return TaskStatus(rawValue: value).map(choice(for:)) ?? .automatic
  }

  static func choice(for status: TaskStatus) -> NotionStatusChoice {
    switch status {
    case .open: .open
    case .inProgress: .inProgress
    case .needsInfo: .needsInfo
    }
  }

  /// Wert für die Karte. nil entfernt den Eintrag („Automatisch“), "" heißt „Nicht ändern“.
  static func mapValue(_ choice: NotionStatusChoice) -> String? {
    switch choice {
    case .automatic: nil
    case .keep: ""
    case .open: TaskStatus.open.rawValue
    case .inProgress: TaskStatus.inProgress.rawValue
    case .needsInfo: TaskStatus.needsInfo.rawValue
    }
  }

  /// Karte nach einer Auswahl für einen Notion-Stand. Ein leerer Schlüssel ändert nichts.
  static func setting(_ map: [String: String], text: String, to choice: NotionStatusChoice) -> [String: String] {
    let key = NotionStatusRules.key(text)
    guard !key.isEmpty else { return map }
    var out = map
    out[key] = mapValue(choice)
    return out
  }

  /// Hilfstext unter dem Stand bei „Automatisch“: der Vorschlag oder „unverändert“, wenn Lumi den Stand nicht kennt.
  static func caption(_ row: NotionStatusRow) -> String? {
    guard row.choice == .automatic else { return nil }
    guard let suggestion = row.suggestion else { return "→ unverändert" }
    return "→ \(suggestion.title)"
  }
}
