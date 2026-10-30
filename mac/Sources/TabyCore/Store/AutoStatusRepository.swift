import Foundation

/// Ein Status, den Lumi bei einem Konto gesetzt hat (bis `endsAt`).
public struct AutoStatusRecord: Equatable, Sendable {
  public let accountId: String
  /// "focus" oder "meeting".
  public let kind: String
  public let text: String
  public let emoji: String
  /// Lokaler ISO-Zeitpunkt, an dem der Status endet.
  public let endsAt: String

  public init(accountId: String, kind: String, text: String, emoji: String, endsAt: String) {
    self.accountId = accountId; self.kind = kind; self.text = text; self.emoji = emoji; self.endsAt = endsAt
  }
}

/// Tabelle `auto_status`: je Konto höchstens ein von Lumi gesetzter Status.
public final class AutoStatusRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  public func list() throws -> [AutoStatusRecord] {
    try db.query("SELECT * FROM auto_status ORDER BY account_id").map { r in
      AutoStatusRecord(accountId: r.text("account_id"), kind: r.text("kind"), text: r.text("text"),
                       emoji: r.text("emoji"), endsAt: r.text("ends_at"))
    }
  }

  public func set(_ record: AutoStatusRecord) throws {
    try db.run("INSERT OR REPLACE INTO auto_status (account_id, kind, text, emoji, ends_at) VALUES (?, ?, ?, ?, ?)",
               [.text(record.accountId), .text(record.kind), .text(record.text), .text(record.emoji), .text(record.endsAt)])
  }

  public func delete(_ accountId: String) throws {
    try db.run("DELETE FROM auto_status WHERE account_id = ?", [.text(accountId)])
  }
}
