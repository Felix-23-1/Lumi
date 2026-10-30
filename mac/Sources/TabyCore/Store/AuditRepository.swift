// Audit-Protokoll: eine kleine Zeile je Werkzeug-Ausführung, ohne Inhalte (keine Texte, Titel, Adressen).
// Schreiben ist ein einzelnes INSERT ohne Lesen; alle `pruneEvery` Schreibvorgänge wird auf `maxRows` gekürzt.
import Foundation

public final class AuditRepository: @unchecked Sendable {
  /// Höchstens so viele Zeilen; die ältesten fallen weg.
  public static let maxRows = 5000
  static let pruneEvery = 100

  let db: Database
  let clock: Clock
  private let lock = NSLock()
  private var writes = 0

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  /// Ein Eintrag. Fehler werden geschluckt: eine Protokollzeile darf nie eine Aktion stoppen.
  public func add(actor: String, tool: String, summary: String, confirmed: Bool, ok: Bool) {
    try? db.run("INSERT INTO audit_log (id, at, actor, tool, summary, confirmed, ok) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(StoreIds.make()), .text(StoreDates.now(clock)), .text(actor), .text(tool),
                 .text(summary), .of(confirmed), .of(ok)])
    let shouldPrune = lock.withLock { () -> Bool in
      writes += 1
      guard writes >= Self.pruneEvery else { return false }
      writes = 0
      return true
    }
    if shouldPrune { prune() }
  }

  /// Löscht alles über `maxRows` (älteste zuerst; Einfügereihenfolge über rowid).
  func prune() {
    try? db.run("DELETE FROM audit_log WHERE rowid <= (SELECT rowid FROM audit_log ORDER BY rowid DESC LIMIT 1 OFFSET ?)",
                [.of(Self.maxRows)])
  }

  /// Löscht Einträge, die älter als `days` Tage sind (Zeiten sind lokale ISO-Strings, Vergleich als Text).
  public func pruneOlderThan(days: Int, now: Date) throws {
    let cutoff = LocalTime.format(now.addingTimeInterval(-Double(days) * 86_400))
    try db.run("DELETE FROM audit_log WHERE at < ?", [.text(cutoff)])
  }

  /// Leert das ganze Protokoll.
  public func clear() throws {
    try db.run("DELETE FROM audit_log", [])
  }

  /// Neueste zuerst.
  public func list(limit: Int) throws -> [AuditEntry] {
    try db.query("SELECT * FROM audit_log ORDER BY rowid DESC LIMIT ?", [.of(limit)]).map {
      AuditEntry(id: $0.text("id"), at: $0.text("at"), actor: $0.text("actor"), tool: $0.text("tool"),
                 summary: $0.text("summary"), confirmed: $0.bool("confirmed"), ok: $0.bool("ok"))
    }
  }
}
