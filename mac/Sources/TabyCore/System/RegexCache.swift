import Foundation

/// Reguläre Ausdrücke einmal übersetzen statt bei jedem Aufruf (Sortieren, Planen, Parser).
/// Feste Tabelle statt NSCache: NSCache darf jederzeit verwerfen, die Muster sind wenige feste Texte.
enum RegexCache {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var table: [String: NSRegularExpression] = [:]

  static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
    let key = "\(options.rawValue)|\(pattern)"
    lock.lock(); defer { lock.unlock() }
    if let hit = table[key] { return hit }
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    if table.count < 256 { table[key] = re }  // shortcut: feste Obergrenze, Muster sind Code-Konstanten
    return re
  }
}
