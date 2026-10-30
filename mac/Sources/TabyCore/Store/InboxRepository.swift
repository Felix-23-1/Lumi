// Eingang: erledigte Punkte je Kennung, mit der Zeit der Nachricht, die erledigt wurde.
import Foundation

public final class InboxDismissedRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  /// Kennung → Zeit (lokal, "YYYY-MM-DDTHH:mm") der erledigten Nachricht.
  public func all() throws -> [String: String] {
    var out: [String: String] = [:]
    for row in try db.query("SELECT item_id, at FROM inbox_dismissed") { out[row.text("item_id")] = row.text("at") }
    return out
  }

  public func set(_ id: String, at: String) throws {
    try db.run("INSERT OR REPLACE INTO inbox_dismissed (item_id, at) VALUES (?, ?)", [.text(id), .text(at)])
  }
}
