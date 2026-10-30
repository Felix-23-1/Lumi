// Werkzeug postpone_tasks (Paket 2): schiebt offene Aufgaben auf morgen.
// Die Datumsrechnung steht in `DueShift` (rein, ohne Uhr: "today" wird übergeben).
import Foundation

public enum DueShift {
  /// Neue Fälligkeit nach dem Verschieben auf morgen.
  /// - Kein Datum oder nur ein Datum ("JJJJ-MM-TT") → morgen, ganztägig.
  /// - Datum mit Uhrzeit ("JJJJ-MM-TTTHH:mm") → morgen zur selben Uhrzeit.
  public static func toTomorrow(_ due: String?, today: String) -> String {
    let tomorrow = StoreDates.shiftDateOnly(today, 1)
    guard let d = due, d.count >= 16, d.dropFirst(10).first == "T" else { return tomorrow }
    let time = String(d.dropFirst(11).prefix(5))
    guard SettingsRepository.isValidTimeOfDay(time) else { return tomorrow }
    return "\(tomorrow)T\(time)"
  }
}

enum PostponeTools {
  static let defs: [ToolDef] = [
    ToolDef(name: "postpone_tasks",
            description: "Schiebt offene Aufgaben auf morgen. Ohne Uhrzeit wird das Datum auf morgen gesetzt, eine Uhrzeit bleibt erhalten. Erledigte Aufgaben werden übersprungen.",
            parameters: ToolSchema.object([
              "ids": ["type": "array", "items": ["type": "string"], "description": "IDs der Aufgaben"],
            ], required: ["ids"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "postpone_tasks": { ctx, args in
      guard case .array(let items)? = args.raw["ids"] else {
        throw ToolValidationError("\"ids\" muss eine Liste von Aufgaben-IDs sein")
      }
      var ids = Set<String>()
      for item in items {
        guard case .string(let s) = item, !s.isEmpty else {
          throw ToolValidationError("\"ids\" darf nur Texte mit IDs enthalten")
        }
        ids.insert(s)
      }
      let today = StoreDates.today(ctx.clock)
      var moved = 0
      for id in ids {
        guard let task = try ctx.store.tasks.get(id), !task.done else { continue }
        _ = try ctx.store.tasks.update(id, due: .set(DueShift.toTomorrow(task.due, today: today)))
        moved += 1
      }
      return ToolJSON.ok(["moved": .number(Double(moved))])
    },
  ]
}
