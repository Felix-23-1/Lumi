// Prüfungen für die Leerlauf-Arbeit: Erinnerungs-Takt, Regex-Cache und
// die Dauerschätzung für "Was jetzt?". Reine Funktionen, ohne Netz und ohne Systemdienste.
import Foundation

enum LoadChecks {
  static var cases: [CheckCase] {
    [
      CheckCase("Erinnerungs-Takt: Sicherheitsabgleich alle 15 Minuten") {
        try expectEqual(CoreServices.remindersInterval, 900)
      },
      CheckCase("Regex-Cache: gleiches Muster liefert dieselbe Instanz, ungültiges nil") {
        let a = RegexCache.compile(#"(\d+)\s*min"#)
        let b = RegexCache.compile(#"(\d+)\s*min"#)
        try expect(a != nil && a === b, "einmal kompiliert")
        try expect(RegexCache.compile("(") == nil, "ungültiges Muster ist nil")
      },
      CheckCase("Dauerschätzung aus dem Titel gleich wie vorher (min, Stunden, Standard)") {
        try expectEqual(AutoPlanner.estimateMinutes("Bericht 45 min", default: 30), 45)
        try expectEqual(AutoPlanner.estimateMinutes("Bericht 1,5 h", default: 30), 90)
        try expectEqual(AutoPlanner.estimateMinutes("Bericht", default: 30), 30)
      },
    ]
  }
}
