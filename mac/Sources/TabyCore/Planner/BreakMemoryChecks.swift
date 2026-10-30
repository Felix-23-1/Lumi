// Prüfungen für BreakMemoryParser: Formulierungen aus dem Gedächtnis und der
// Tagesplan gegen den echten Kern. Ohne Modell.
import Foundation

enum BreakMemoryChecks {
  static func memory(_ text: String, _ createdAt: String = "2026-10-01T09:00") -> Memory {
    Memory(id: UUID().uuidString, text: text, createdAt: createdAt)
  }

  static func first(_ text: String) -> String {
    guard let b = BreakMemoryParser.breaks(from: [memory(text)]).first else { return "keine" }
    return "\(b.start)-\(b.end) \(b.label)"
  }

  static let pure: [CheckCase] = [
    CheckCase("Pause aus dem Gedächtnis: Uhrzeiten, Dauer und Standardwert") {
      try expectEqual(first("Ich mache Mittagspause von 12 bis 13 Uhr"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause 12:30-13:15"), "12:30-13:15 Mittagspause")
      try expectEqual(first("Mittag zwischen 12 und 13 Uhr"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause um 12 Uhr, eine Stunde"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause um 12 Uhr, 30 Minuten"), "12:00-12:30 Mittagspause")
      try expectEqual(first("Mittagspause um 12 Uhr, halbe Stunde"), "12:00-12:30 Mittagspause")
      try expectEqual(first("Mittagspause um 12 Uhr, 45 min"), "12:00-12:45 Mittagspause")
      try expectEqual(first("Mittagspause um 12"), "12:00-13:00 Mittagspause")
      try expectEqual(first("MITTAGESSEN um 12:30"), "12:30-13:30 Mittagspause")
      try expectEqual(first("Pause um 15 Uhr, 10 Minuten"), "15:00-15:10 Pause")
    },
    CheckCase("Pause aus dem Gedächtnis: riesige Zahlen stürzen nicht ab") {
      _ = BreakMemoryParser.breaks(from: [memory("Pause um 12 Uhr 9223372036854775807 Minuten")])
      _ = BreakMemoryParser.breaks(from: [memory("Pause um 12 Uhr 99999999999999999999999 Stunden")])
    },
    CheckCase("Pause aus dem Gedächtnis: ohne Uhrzeit keine Pause, Ende bleibt im Tag") {
      try expectEqual(first("Ich mag Mittagessen mit Sushi"), "keine")
      try expectEqual(first("Zahnarzt um 12 Uhr"), "keine")
      try expectEqual(first("Mittagspause um 23 Uhr, 3 Stunden"), "23:00-23:59 Mittagspause")
    },
    CheckCase("Pause aus dem Gedächtnis: neuester passender Eintrag gewinnt") {
      let old = memory("Mittagspause um 12 Uhr, 30 Minuten", "2026-10-01T09:00")
      let new = memory("Mittagspause von 13 bis 14 Uhr", "2026-10-05T09:00")
      let noTime = memory("Mittagspause ist meist voll", "2026-10-09T09:00")
      let b = BreakMemoryParser.breaks(from: [old, noTime, new])
      try expectEqual(b.count, 1)
      try expectEqual(b.first?.start, "13:00")
      try expectEqual(b.first?.end, "14:00")
      try expectEqual(BreakMemoryParser.breaks(from: []).count, 0)
    },
    CheckCase("Pause aus dem Gedächtnis: Zeit gehört nur zum Stichwort derselben Klausel") {
      try expectEqual(first("von 9 bis 17 Uhr, Mittagspause 30 Minuten"), "keine")
      try expectEqual(first("Zahnarzt um 9 Uhr, Mittagspause von 12 bis 13 Uhr"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagsschlaf um 13 Uhr, 30 Minuten"), "keine")
      try expectEqual(first("Mittagspause am 12.10. 2026"), "keine")
      try expectEqual(first("Mittagspause am 12.10. von 12 bis 13 Uhr"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause ab 12.10.2026 um 12 Uhr, 45 Minuten"), "12:00-12:45 Mittagspause")
    },
    CheckCase("Pause aus dem Gedächtnis: negierte neueste Angabe hebt Pausen auf") {
      let old = memory("Mittagspause von 12 bis 13 Uhr", "2026-10-01T09:00")
      let new = memory("Keine Mittagspause mehr", "2026-10-05T09:00")
      try expectEqual(BreakMemoryParser.breaks(from: [old, new]).count, 0)
      let newer = memory("Mittagspause entfällt heute, Pause von 14 bis 15 Uhr", "2026-10-06T09:00")
      try expectEqual(BreakMemoryParser.breaks(from: [old, newer]).count, 0)
    },
    CheckCase("Pause aus dem Gedächtnis: 'nicht länger' ist keine Verneinung, echte Verneinungen schon") {
      try expectEqual(first("Mittagspause von 12 bis 13 Uhr, nicht länger"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause von 12 bis 13 Uhr, nicht mehr als 30 Minuten"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause von 12 bis 13 Uhr, ohne Ausnahme"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Keine Mittagspause heute"), "keine")
      try expectEqual(first("Kein Mittagessen um 12 Uhr"), "keine")
      try expectEqual(first("Ohne Mittagspause, Pause um 12 Uhr"), "keine")
      try expectEqual(first("Mittagspause fällt weg"), "keine")
      let old = memory("Mittagspause von 12 bis 13 Uhr", "2026-10-01T09:00")
      let newer = memory("Mittagspause von 12 bis 13 Uhr, nicht länger", "2026-10-05T09:00")
      try expectEqual(BreakMemoryParser.breaks(from: [old, newer]).first?.start, "12:00")
    },
    CheckCase("Pause aus dem Gedächtnis: gestrichen, ausgefallen und keine Pause verneinen") {
      try expectEqual(first("Mittagspause gestrichen"), "keine")
      try expectEqual(first("Mittagspause fällt heute aus"), "keine")
      try expectEqual(first("Mittagspause fällt aus"), "keine")
      try expectEqual(first("Mittagspause ist gestrichen, Pause um 12 Uhr"), "keine")
      try expectEqual(first("Heute keine Pause"), "keine")
      try expectEqual(first("Mittagspause von 12 bis 13 Uhr, nicht länger"), "12:00-13:00 Mittagspause")
    },
    CheckCase("Pause aus dem Gedächtnis: 12.30 Uhr ist Uhrzeit, Datum nur mit Schlusspunkt") {
      try expectEqual(first("Mittagspause um 12.30 Uhr, 45 Minuten"), "12:30-13:15 Mittagspause")
      try expectEqual(first("Mittagspause 12.30 bis 13.15 Uhr"), "12:30-13:15 Mittagspause")
      try expectEqual(first("Mittagspause am 12.10.2026 um 12.30 Uhr, 30 Minuten"), "12:30-13:00 Mittagspause")
    },
    CheckCase("Pause aus dem Gedächtnis: ISO-Datum ergibt keine Uhrzeit") {
      try expectEqual(first("Mittagspause 2026-10-15 von 12 bis 13 Uhr"), "12:00-13:00 Mittagspause")
      try expectEqual(first("Mittagspause am 2026-10-15"), "keine")
    },
  ]
}

extension BreakMemoryChecks {
  @MainActor static var integration: [CheckCase] {
    [
      CheckCase("Plan: Mittagspause aus dem Gedächtnis bleibt frei, festgesetzte Aufgabe bleibt stehen") {
        let rig = try IntegrationRig()  // Montag 08:00
        let svc = rig.svc
        _ = await svc.addMemory("Mittagspause von 12 bis 13 Uhr")
        var ids: [String] = []
        for title in ["Bericht (3 h)", "Mails (2 h)", "Ablage (2 h)"] {
          if case .ok(let t) = await svc.addTask(title: title, notes: nil, due: nil) { ids.append(t.id) }
        }
        try expectEqual(ids.count, 3)
        guard case .ok(let plan) = await svc.planDay() else { throw CheckFailure(message: "kein Plan", location: "") }
        try expect(!plan.blocks.isEmpty, "keine Blöcke")
        for b in plan.blocks {
          let overlaps = b.start < "2026-10-12T13:00" && b.end > "2026-10-12T12:00"
          try expect(!overlaps, "Block \(b.start)-\(b.end) liegt in der Mittagspause")
        }
        // Festgesetzte Aufgabe in der Pause bleibt, wo der Nutzer sie hingelegt hat.
        guard case .ok(let fixed) = await svc.planTasks([PlanItem(taskId: ids[0], start: "12:30", minutes: 30)]) else {
          throw CheckFailure(message: "planTasks fehlgeschlagen", location: "")
        }
        try expectEqual(fixed.blocks.first?.start, "2026-10-12T12:30")
      },
    ]
  }
}
