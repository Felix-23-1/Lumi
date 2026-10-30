// Prüfungen für die Aufteilung der Heute-Seite.
import Foundation
import TabyCore

enum TodayLayoutChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Heute: Menü hat Timer, Vorlesen, Pause; Statistik nur mit Fokuszeit") {
        try expectEqual(TodayLayoutLogic.menuEntries(focusMinutesToday: 0), [.timer, .readAloud, .pause])
        try expectEqual(TodayLayoutLogic.menuEntries(focusMinutesToday: 50), [.timer, .readAloud, .pause, .focusStats])
      },
      CheckCase("Heute: Vorlesen-Eintrag wird beim Sprechen zum Stopp") {
        try expectEqual(TodayLayoutLogic.readAloudTitle(speaking: false), "Vorlesen")
        try expectEqual(TodayLayoutLogic.readAloudTitle(speaking: true), "Vorlesen beenden")
      },
      CheckCase("Heute: Briefing-Zeilen je Zustand") {
        try expect(TodayLayoutLogic.briefingLineLimit(readToday: false, expanded: false) == 3, "ungelesen 3")
        try expect(TodayLayoutLogic.briefingLineLimit(readToday: true, expanded: false) == 1, "gelesen 1")
        try expect(TodayLayoutLogic.briefingLineLimit(readToday: true, expanded: true) == nil, "aufgeklappt alles")
      },
      CheckCase("Heute: Meeting-Abschnitt nur bei Termin oder offener Karte") {
        try expect(!TodayLayoutLogic.showsMeetingSection(hasTarget: false, hasOpenCard: false), "leer")
        try expect(TodayLayoutLogic.showsMeetingSection(hasTarget: true, hasOpenCard: false), "Termin")
        try expect(TodayLayoutLogic.showsMeetingSection(hasTarget: false, hasOpenCard: true), "Karte")
      },
    ]
  }
}
