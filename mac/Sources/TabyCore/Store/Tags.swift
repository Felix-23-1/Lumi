// Kennzeichen (Tags) für Aufgaben und Notizen: Bereinigung und Ablage als JSON-Text.
import Foundation

public enum TagRules {
  public static let maxTags = 12
  public static let maxLength = 30

  /// Ohne führendes „#“, Leerraum → „-“, ohne Kommas, ohne Duplikate (Groß/Klein egal), gekürzt.
  public static func normalize(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for item in raw {
      var t = item.trimmingCharacters(in: .whitespacesAndNewlines)
      while t.hasPrefix("#") { t.removeFirst() }
      t = t.replacingOccurrences(of: ",", with: "")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "-")
      if t.count > maxLength { t = String(t.prefix(maxLength)) }
      guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
      out.append(t)
      if out.count == maxTags { break }
    }
    return out
  }

  static func encode(_ tags: [String]) -> String? {
    guard !tags.isEmpty, let data = try? JSONEncoder().encode(tags) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func decode(_ text: String?) -> [String] {
    guard let text, let data = text.data(using: .utf8),
          let tags = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return tags
  }
}
