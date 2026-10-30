// Audit-Protokoll: was Lumi ausgeführt hat (Nutzer, Modell, Auftrag, Mod, Skill, MCP).
// Nur Werkzeugname, deutsche Kurzbeschreibung und Kennzeichen; nie Inhalte.
import Foundation

enum AuditActor {
  static let user = "Nutzer"
  static let model = "Modell"
  static let job = "Auftrag"
  static let mod = "Mod"
  static let skill = "Skill"
  static let mcp = "MCP"

  static func of(_ actor: ActionActor) -> String {
    switch actor {
    case .user: user
    case .assistant: model
    case .job: job
    }
  }
}

/// Deutsche Kurzbeschreibung je Werkzeug. Unbekannte Werkzeuge bekommen eine neutrale Zeile.
enum AuditSummary {
  static let table: [String: String] = [
    "add_task": "Aufgabe angelegt", "update_task": "Aufgabe geändert", "complete_task": "Aufgabe erledigt",
    "reopen_task": "Aufgabe wieder geöffnet", "delete_task": "Aufgabe gelöscht",
    "postpone_tasks": "Aufgaben verschoben", "plan_day": "Tagesplan erstellt",
    "add_note": "Notiz angelegt", "update_note": "Notiz geändert", "delete_note": "Notiz gelöscht",
    "add_habit": "Gewohnheit angelegt", "check_habit": "Gewohnheit abgehakt", "delete_habit": "Gewohnheit gelöscht",
    "add_event": "Termin angelegt", "start_timer": "Timer gestellt", "cancel_timer": "Timer abgebrochen",
    "start_focus": "Fokus gestartet", "stop_focus": "Fokus beendet",
    "remember_fact": "Fakt gemerkt", "forget_fact": "Fakt vergessen",
    "send_message": "Nachricht gesendet", "send_mail": "Mail gesendet", "draft_reply": "Mail-Entwurf geöffnet",
    "mark_inbox_done": "Eingang erledigt", "cancel_job": "Auftrag abgebrochen",
  ]

  static func of(_ tool: String) -> String { table[tool] ?? "Aktion ausgeführt" }
}

extension CoreServices {
  /// Ein Protokolleintrag für eine ausgeführte Aktion (ein INSERT, kein Lesen).
  func audit(actor: String, tool: String, confirmed: Bool, ok: Bool, summary: String? = nil) {
    store.audit.add(actor: actor, tool: tool, summary: summary ?? AuditSummary.of(tool),
                    confirmed: confirmed, ok: ok)
  }

  /// Neueste zuerst, höchstens `limit` (und nie mehr als das Speicherlimit).
  public func listAudit(limit: Int) async -> [AuditEntry] {
    (try? store.audit.list(limit: max(1, min(limit, AuditRepository.maxRows)))) ?? []
  }
}

extension CoreServices {
  /// Protokoll vollständig leeren (nur auf Wunsch des Nutzers).
  public func clearAudit() async -> ToolResult<Empty> {
    do {
      try store.audit.clear()
      return .ok(Empty())
    } catch {
      return .failure(code: "AUDIT", error: "Protokoll konnte nicht gelöscht werden.")
    }
  }
}

/// CSV-Export des Protokolls (Semikolon, alle Felder in Anführungszeichen, für Excel mit BOM).
public enum AuditExport {
  public static func csv(_ entries: [AuditEntry]) -> String {
    var lines = ["Zeit;Akteur;Werkzeug;Aktion;Bestätigt;Erfolgreich"]
    for e in entries {
      lines.append([e.at, e.actor, e.tool, e.summary, e.confirmed ? "ja" : "nein", e.ok ? "ja" : "nein"]
        .map(field).joined(separator: ";"))
    }
    return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
  }

  static func field(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Schreibt die CSV in `folder` unter „Lumi-Protokoll.csv“ (mit Zähler, falls vorhanden); liefert den Pfad.
  public static func write(_ entries: [AuditEntry], to folder: URL) throws -> URL {
    let fm = FileManager.default
    var url = folder.appendingPathComponent("Lumi-Protokoll.csv")
    var n = 2
    while fm.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("Lumi-Protokoll \(n).csv")
      n += 1
    }
    try csv(entries).write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
