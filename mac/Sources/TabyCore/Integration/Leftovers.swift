// Aufräumen alter Reste: Papierkorb der Mods, Export-Kopien (.vorher) und Mitschnitt-Ordner.
// Best effort: was sich nicht löschen lässt, bleibt stehen.
import Foundation

public enum Leftovers {
  /// Reste werden nach einem Tag entfernt.
  public static let maxAge: TimeInterval = 24 * 3600

  /// Entfernt Einträge in `dir` (Name beginnt mit `prefix`), deren Änderungsdatum mindestens `maxAge` zurückliegt.
  /// Symbolische Links werden nie verfolgt. Liefert die Zahl gelöschter Einträge.
  @discardableResult
  public static func removeOlder(than maxAge: TimeInterval = Leftovers.maxAge, in dir: URL, now: Date,
                                 prefix: String = "") -> Int {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isSymbolicLinkKey]
    let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
    var removed = 0
    for url in entries where url.lastPathComponent.hasPrefix(prefix) {
      let values = try? url.resourceValues(forKeys: keys)
      guard values?.isSymbolicLink != true, let date = values?.contentModificationDate,
            now.timeIntervalSince(date) >= maxAge else { continue }
      if (try? fm.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }
}
