// Aufgeräumte Heute-Seite: was in der Hauptzeile steht und was hinter dem „…“-Menü liegt.
// Rein (keine Ansicht, keine Uhr), damit die Aufteilung prüfbar ist.
import Foundation
import TabyCore

enum TodayLayoutLogic {
  /// Einträge des „…“-Menüs in der Kopfzeile, in dieser Reihenfolge.
  enum MenuEntry: Equatable {
    case timer          // feste Minuten + „Eigene Dauer…“
    case readAloud      // Vorlesen oder Stopp
    case pause          // Pause mit Dauer
    case focusStats     // „Heute fokussiert: …“ (nur Anzeige)
  }

  static func menuEntries(focusMinutesToday: Int) -> [MenuEntry] {
    var e: [MenuEntry] = [.timer, .readAloud, .pause]
    if FocusLogic.todayLine(focusMinutesToday) != nil { e.append(.focusStats) }
    return e
  }

  static func readAloudTitle(speaking: Bool) -> String { speaking ? "Vorlesen beenden" : "Vorlesen" }

  /// Briefing: ungelesen 3 Zeilen, aufgeklappt alles, als gelesen markiert 1 Zeile.
  static func briefingLineLimit(readToday: Bool, expanded: Bool) -> Int? {
    if expanded { return nil }
    return readToday ? 1 : 3
  }

  /// Der Meeting-Abschnitt hat nur dann eine Überschrift, wenn es einen Termin oder eine offene Karte gibt.
  static func showsMeetingSection(hasTarget: Bool, hasOpenCard: Bool) -> Bool { hasTarget || hasOpenCard }
}
