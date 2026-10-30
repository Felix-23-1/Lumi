// Reine Regeln über Kontakte: Suche, Geburtstage, Auswahl bei Mehrdeutigkeit, Telefon-Links.
// Ohne System und ohne Modell.
import Foundation

public enum ContactSearch {
  /// Höchstens so viele Treffer, damit die Ausgabe kurz bleibt.
  public static let limit = 10

  /// Schreibweise für den Vergleich: ohne Groß/Kleinschreibung und Akzente.
  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
  }

  /// Name, Firma oder E-Mail enthält den Suchtext.
  public static func search(_ all: [ContactCard], query: String) -> [ContactCard] {
    let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !q.isEmpty else { return [] }
    let hits = all.filter { c in
      fold(c.name).contains(q) || fold(c.organization ?? "").contains(q) || c.emails.contains { fold($0).contains(q) }
    }
    return Array(hits.prefix(limit))
  }

  /// Kontakte, deren Geburtstag am Tag `day` ("JJJJ-MM-TT") liegt.
  public static func birthdays(_ all: [ContactCard], day: String) -> [ContactCard] {
    let mmdd = String(day.suffix(5))
    return all.filter { c in c.birthday.map { String($0.suffix(5)) == mmdd } ?? false }
  }

  public enum Choice: Equatable {
    case one(ContactCard)
    case many([ContactCard])
    case none
  }

  /// Wählt aus Treffern: genau einer → der; genau einer mit exakt diesem Namen → der; sonst mehrere/keiner.
  public static func choose(_ hits: [ContactCard], query: String) -> Choice {
    let exact = hits.filter { fold($0.name) == fold(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if exact.count == 1 { return .one(exact[0]) }
    switch hits.count {
    case 0: return .none
    case 1: return .one(hits[0])
    default: return .many(hits)
    }
  }

  /// Unterhaltungstitel, die genau so heißen wie der Name (ohne Groß/Kleinschreibung und Akzente).
  public static func sameName(_ a: String, _ b: String) -> Bool { fold(a) == fold(b) }

  /// tel:- oder facetime:-Link mit den Ziffern der Nummer (führendes + bleibt). nil ohne Ziffern.
  public static func link(scheme: String, phone: String) -> URL? {
    let digits = phone.filter { ("0"..."9").contains($0) }
    guard !digits.isEmpty else { return nil }
    let plus = phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
    return URL(string: "\(scheme):\(plus)\(digits)")
  }
}
