// Ausgeklappte Insel: Merken je Reiter und Sichtbarkeit der Reiter. Rein
// (ohne Fenster); die Speicherung ist austauschbar, damit Prüfungen und
// Snapshots nichts in die Einstellungen des Nutzers schreiben.
import Foundation
import TabyCore

/// Merkt, welche Reiter ausgeklappt sind (Schlüssel "islandExpanded.<reiter>").
struct IslandExpansionStore {
  var read: (String) -> Bool
  var write: (String, Bool) -> Void

  /// Echte Einstellungen des Nutzers (UserDefaults).
  static let standard = IslandExpansionStore(
    read: { UserDefaults.standard.bool(forKey: $0) },
    write: { UserDefaults.standard.set($1, forKey: $0) })

  /// Nur im Arbeitsspeicher (Prüfungen, Snapshots).
  static func memory(_ initial: [String: Bool] = [:]) -> IslandExpansionStore {
    let box = MemoryBox(values: initial)
    return IslandExpansionStore(read: { box.values[$0] ?? false }, write: { box.values[$0] = $1 })
  }

  func isExpanded(_ tab: TabyTab) -> Bool { read(IslandExpansionRules.key(tab)) }

  func setExpanded(_ tab: TabyTab, _ on: Bool) { write(IslandExpansionRules.key(tab), on) }

  private final class MemoryBox {
    var values: [String: Bool]
    init(values: [String: Bool]) { self.values = values }
  }
}

enum IslandExpansionRules {
  static func key(_ tab: TabyTab) -> String { "islandExpanded.\(tab.rawValue)" }

  /// Reiter, die gerade sichtbar sind (Netzwerk nur mit eingeschalteten Werkzeugen).
  static func visible(_ tabs: [TabyTab], settings: TabySettings?) -> [TabyTab] {
    tabs.filter { $0.isVisible(settings) }
  }

  /// Aktueller Reiter, falls er ausgeblendet wurde, sonst Heute.
  static func fallbackTab(_ current: TabyTab, settings: TabySettings?) -> TabyTab {
    current.isVisible(settings) ? current : .today
  }
}
