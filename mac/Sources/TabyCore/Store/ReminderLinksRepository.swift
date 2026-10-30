// Verknüpfungen Lumi-Aufgabe ↔ Apple-Erinnerung (Paket 1). Je Aufgabe ein
// Eintrag mit dem Stand des letzten Abgleichs (snap_*), gegen den der
// Zwei-Wege-Abgleich Änderungen erkennt.
import Foundation

/// Eine Verknüpfung mit dem Abgleichstand der Erinnerung.
public struct StoredReminderLink: Codable, Equatable, Sendable {
  public var taskId: String
  /// Kennung der Erinnerung in Apple Erinnerungen (eindeutig).
  public var externalId: String
  public var snapTitle: String
  public var snapDue: String?
  public var snapDone: Bool
  public var syncedAt: String
  /// Liste der Erinnerung beim letzten Abgleich (nil = unbekannt).
  public var listId: String?

  public init(taskId: String, externalId: String, snapTitle: String, snapDue: String? = nil, snapDone: Bool,
              syncedAt: String, listId: String? = nil) {
    self.taskId = taskId; self.externalId = externalId; self.snapTitle = snapTitle
    self.snapDue = snapDue; self.snapDone = snapDone; self.syncedAt = syncedAt; self.listId = listId
  }
}

public final class ReminderLinksRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toLink(_ r: SQLRow) -> StoredReminderLink {
    StoredReminderLink(taskId: r.text("task_id"), externalId: r.text("external_id"),
                       snapTitle: r.text("snap_title"), snapDue: r.string("snap_due"),
                       snapDone: r.bool("snap_done"), syncedAt: r.text("synced_at"), listId: r.string("list_id"))
  }

  public func all() throws -> [StoredReminderLink] {
    try db.query("SELECT * FROM reminder_links ORDER BY rowid").map(toLink)
  }

  /// Legt die Verknüpfung an oder aktualisiert sie (Schlüssel: taskId).
  public func upsert(_ link: StoredReminderLink) throws {
    try db.run(
      "INSERT INTO reminder_links (task_id, external_id, snap_title, snap_due, snap_done, synced_at, list_id) "
        + "VALUES (?, ?, ?, ?, ?, ?, ?) "
        + "ON CONFLICT(task_id) DO UPDATE SET external_id = excluded.external_id, snap_title = excluded.snap_title, "
        + "snap_due = excluded.snap_due, snap_done = excluded.snap_done, synced_at = excluded.synced_at, "
        + "list_id = excluded.list_id",
      [.text(link.taskId), .text(link.externalId), .text(link.snapTitle), .of(link.snapDue), .of(link.snapDone),
       .text(link.syncedAt), .of(link.listId)])
  }

  /// false, wenn es für diese Aufgabe keine Verknüpfung gibt.
  @discardableResult
  public func delete(taskId: String) throws -> Bool {
    try db.run("DELETE FROM reminder_links WHERE task_id = ?", [.text(taskId)]) > 0
  }
}
