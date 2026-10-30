// Notion-Stand („In progress“, „Warten“ …) → Lumi-Stand (Offen, In Bearbeitung, Info fehlt).
// Reine Regeln: der Nutzer überschreibt Vorschläge in `TabySettings.notionStatusMap`.
import Foundation

public enum NotionStatusRules {
  /// Schlüssel für die Zuordnung: klein, ohne Rand-Leerraum.
  public static func key(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Vorschlag ohne Nutzerwahl; nil = unbekannt (Stand bleibt, wie er ist).
  public static func suggested(forNotion text: String) -> TaskStatus? {
    let k = key(text)
    guard !k.isEmpty else { return nil }
    let progress = ["progress", "bearbeitung", "doing", "started", "läuft", "laeuft", "active", "review", "in arbeit"]
    let needsInfo = ["wait", "warte", "block", "info", "feedback", "rückfrage", "rueckfrage", "on hold", "pausiert", "klären", "klaeren"]
    let open = ["not started", "nicht begonnen", "to do", "todo", "to-do", "offen", "open", "backlog", "neu", "new", "idee"]
    if k.contains("not started") || k.contains("nicht begonnen") || k.contains("nicht gestartet") { return .open }
    if needsInfo.contains(where: k.contains) { return .needsInfo }
    if progress.contains(where: k.contains) { return .inProgress }
    if open.contains(where: k.contains) { return .open }
    return nil
  }

  /// Gewählter Lumi-Stand: Nutzerzuordnung zuerst ("" = nicht ändern), sonst der Vorschlag.
  public static func lumiStatus(forNotion text: String, map: [String: String]) -> TaskStatus? {
    if let chosen = map[key(text)] { return TaskStatus(rawValue: chosen) }
    return suggested(forNotion: text)
  }

  /// Nur gültige Werte behalten (Schutz vor beschädigten Einstellungen), höchstens 64 Einträge.
  public static func cleaned(_ map: [String: String]) -> [String: String] {
    let valid = Set(TaskStatus.allCases.map(\.rawValue) + [""])
    var out: [String: String] = [:]
    for (k, v) in map where valid.contains(v) && !key(k).isEmpty && out.count < 64 { out[key(k)] = v }
    return out
  }
}
