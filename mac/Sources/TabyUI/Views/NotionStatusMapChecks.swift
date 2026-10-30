// Prüfungen der Karte „Notion-Stände zuordnen“ (Einstellungen): Zeilen, Auswahl ↔ Wert, und ein Snapshot der Seite.
import Foundation
import SwiftUI
import TabyCore

enum NotionStatusMapChecks {
  static func meta(_ status: String?) -> NotionTaskMeta {
    NotionTaskMeta(createdAt: "2026-10-01T08:00", createdBy: nil, status: status)
  }

  static var sampleMeta: [String: NotionTaskMeta] {
    [
      "n1": meta("In Bearbeitung"),
      "n2": meta("  not started "),
      "n3": meta("in bearbeitung"),
      "n4": meta("Warten auf Antwort"),
      "n5": meta("Archiv"),
      "n6": meta(""),
      "n7": meta(nil),
    ]
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Stände: je Schlüssel einmal, leer und fehlend entfallen, alphabetisch nach Schlüssel") {
        let rows = NotionStatusMapLogic.rows(meta: sampleMeta, map: [:])
        try expectEqual(rows.map(\.text), ["Archiv", "In Bearbeitung", "not started", "Warten auf Antwort"])
        try expectEqual(rows.map(\.choice), [.automatic, .automatic, .automatic, .automatic])
      },
      CheckCase("Stände: höchstens 20 Zeilen") {
        let many = Dictionary(uniqueKeysWithValues: (0..<30).map { ("n\($0)", meta("Stand \($0)")) })
        try expectEqual(NotionStatusMapLogic.rows(meta: many, map: [:]).count, NotionStatusMapLogic.maxRows)
        try expectEqual(NotionStatusMapLogic.maxRows, 20)
      },
      CheckCase("Zeile: Auswahl kommt aus der Karte, Vorschlag aus NotionStatusRules") {
        let rows = NotionStatusMapLogic.rows(meta: sampleMeta, map: ["in bearbeitung": "", "archiv": "needsInfo"])
        let byText = Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0) })
        try expectEqual(byText["In Bearbeitung"]?.choice, .keep)
        try expectEqual(byText["Archiv"]?.choice, .needsInfo)
        try expectEqual(byText["not started"]?.choice, .automatic)
        try expectEqual(byText["not started"]?.suggestion, NotionStatusRules.suggested(forNotion: "not started"),
                        "Vorschlag kommt aus den Regeln, nicht aus der Karte")
        try expectEqual(NotionStatusRules.suggested(forNotion: "to do"), .open)
        try expectEqual(byText["Warten auf Antwort"]?.suggestion, .needsInfo)
        try expectEqual(byText["Archiv"]?.suggestion, nil)
      },
      CheckCase("Auswahl ↔ Wert: Automatisch entfällt, Nicht ändern ist leer, die anderen sind der rawValue") {
        try expectEqual(NotionStatusMapLogic.mapValue(.automatic), nil)
        try expectEqual(NotionStatusMapLogic.mapValue(.keep), "")
        try expectEqual(NotionStatusMapLogic.mapValue(.open), "open")
        try expectEqual(NotionStatusMapLogic.mapValue(.inProgress), "inProgress")
        try expectEqual(NotionStatusMapLogic.mapValue(.needsInfo), "needsInfo")
        try expectEqual(NotionStatusMapLogic.choice(forMapValue: nil), .automatic)
        try expectEqual(NotionStatusMapLogic.choice(forMapValue: ""), .keep)
        try expectEqual(NotionStatusMapLogic.choice(forMapValue: "inProgress"), .inProgress)
        try expectEqual(NotionStatusMapLogic.choice(forMapValue: "kaputt"), .automatic, "unbekannter Wert fällt auf Automatisch")
        for c in NotionStatusChoice.allCases where c != .automatic {
          try expectEqual(NotionStatusMapLogic.choice(forMapValue: NotionStatusMapLogic.mapValue(c)), c)
        }
      },
      CheckCase("Karte schreiben: Schlüssel ist klein, Automatisch entfernt ihn, Nicht ändern speichert leer") {
        var map = NotionStatusMapLogic.setting([:], text: "  In Bearbeitung ", to: .inProgress)
        try expectEqual(map, ["in bearbeitung": "inProgress"])
        map = NotionStatusMapLogic.setting(map, text: "IN BEARBEITUNG", to: .keep)
        try expectEqual(map, ["in bearbeitung": ""])
        map = NotionStatusMapLogic.setting(map, text: "in Bearbeitung", to: .automatic)
        try expectEqual(map, [:])
        try expectEqual(NotionStatusMapLogic.setting(["a": "open"], text: "   ", to: .needsInfo), ["a": "open"],
                        "leerer Stand ändert nichts")
      },
      CheckCase("Sichtbarkeit: nur bei eingeschaltetem Notion und mindestens einem Stand") {
        let rows = NotionStatusMapLogic.rows(meta: sampleMeta, map: [:])
        try expectEqual(NotionStatusMapLogic.showsSection(notionEnabled: true, rows: rows), true)
        try expectEqual(NotionStatusMapLogic.showsSection(notionEnabled: false, rows: rows), false)
        try expectEqual(NotionStatusMapLogic.showsSection(notionEnabled: true, rows: []), false)
        try expectEqual(NotionStatusMapLogic.rows(meta: [:], map: [:]).isEmpty, true)
      },
      CheckCase("Hinweis unter dem Stand: nur bei Automatisch, Vorschlag oder „unverändert“") {
        let rows = NotionStatusMapLogic.rows(meta: sampleMeta, map: ["archiv": "open"])
        let byText = Dictionary(uniqueKeysWithValues: rows.map { ($0.text, $0) })
        try expectEqual(NotionStatusMapLogic.caption(byText["In Bearbeitung"]!), "→ In Bearbeitung")
        try expectEqual(NotionStatusMapLogic.caption(byText["Warten auf Antwort"]!), "→ Info fehlt")
        try expectEqual(NotionStatusMapLogic.caption(byText["Archiv"]!), nil, "eigene Wahl: kein Hinweis")
        let unknown = NotionStatusRow(text: "Archiv", choice: .automatic, suggestion: nil)
        try expectEqual(NotionStatusMapLogic.caption(unknown), "→ unverändert")
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-notion-status-map", size: CGSize(width: TabLayout.contentWidth, height: 1500)) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTaskMeta = sampleMeta
        fake.current.notionSourceLinks = ["n1": "s1"]
        let model = NotionAccountViewChecks.loaded(fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .accounts)
        view.pageHeight = 2600
        return NotionAccountViewChecks.wrap(view.tabyPage(), model)
      },
    ]
  }
}
