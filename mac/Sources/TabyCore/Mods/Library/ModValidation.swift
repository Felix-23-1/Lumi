// Prüfung eines Mod-Manifests (Paket 3). Keine Dateizugriffe, keine Uhr.
import Foundation

public enum ModValidation {
  /// Liefert deutsche Problembeschreibungen; leer = gültig.
  public static func validate(_ m: ModManifest) -> [String] {
    var problems: [String] = []

    if !isValidID(m.id) {
      problems.append("Die ID muss 3 bis 40 Zeichen aus Kleinbuchstaben, Ziffern und „-“ haben.")
    }
    if m.name.trimmedText.isEmpty { problems.append("Der Name fehlt.") }
    if m.description.trimmedText.isEmpty { problems.append("Die Beschreibung fehlt.") }
    if m.version.trimmedText.isEmpty { problems.append("Die Version fehlt.") }

    switch m.kind {
    case .shortcut:
      if (m.shortcutName ?? "").trimmedText.isEmpty {
        problems.append("Für einen Kurzbefehl-Mod ist der Name des Kurzbefehls nötig.")
      }
    case .script:
      let entry = m.entry ?? "main.js"
      if !isValidEntry(entry) {
        problems.append("Die Skriptdatei muss ein Dateiname mit der Endung „.js“ sein, ohne Ordner.")
      }
    case .skill:
      if (m.prompt ?? "").trimmedText.isEmpty { problems.append("Ein Skill braucht eine Anleitung (prompt).") }
    }

    for p in m.permissions {
      if ModPermission.known.contains(p) { continue }
      if p.hasPrefix("http:") {
        if !isValidDomain(String(p.dropFirst(5))) {
          problems.append("Ungültige Internet-Freigabe „\(p)“: nur ein Domainname ohne https://, Pfad oder Stern, z. B. „http:api.example.com“.")
        }
      } else {
        problems.append("Unbekanntes Recht „\(p)“.")
      }
    }

    if let tool = m.tool {
      if tool.description.trimmedText.isEmpty {
        problems.append("Die Beschreibung des Werkzeugs fehlt.")
      }
      var isObjectSchema = false
      if case .object(let schema) = tool.parameters, schema["type"]?.stringValue == "object" {
        isObjectSchema = true
      }
      if !isObjectSchema {
        problems.append("Die Parameter des Werkzeugs müssen ein JSON-Schema vom Typ „object“ sein.")
      }
    }

    return problems
  }

  /// Kleinbuchstaben, Ziffern, "-", 3 bis 40 Zeichen.
  static func isValidID(_ id: String) -> Bool {
    guard (3...40).contains(id.count) else { return false }
    return id.unicodeScalars.allSatisfy { c in
      (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-"
    }
  }

  private static func isValidEntry(_ entry: String) -> Bool {
    guard entry.hasSuffix(".js"), entry.count > 3, !entry.hasPrefix("."), entry != "mod.json" else { return false }
    return !entry.contains("/") && !entry.contains("\\") && !entry.contains("\0")
  }

  /// Domain ohne Schema, Pfad, Port, Stern. Nur a–z, 0–9, "-" und "." in Labels.
  static func isValidDomain(_ domain: String) -> Bool {
    guard !domain.isEmpty, domain.count <= 253, !ScriptHTTP.isLocalOrIPHost(domain) else { return false }
    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for label in labels {
      guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
      guard label.unicodeScalars.allSatisfy({ c in
        (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-"
      }) else { return false }
    }
    return true
  }
}

extension String {
  var trimmedText: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
