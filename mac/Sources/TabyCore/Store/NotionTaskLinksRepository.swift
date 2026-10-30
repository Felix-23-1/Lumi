// Paket 9: Verknüpfung Notion-Eintrag → lokale Lumi-Aufgabe, damit ein
// erneuter Abgleich aktualisiert statt dupliziert. Paket 11: jede Verknüpfung
// merkt sich auch ihre Notion-Quelle (für Abhaken-synchron: Datenbank vs. To-do-Block)
// und optional ihre Gruppe (bei Weekly: die Woche).
import Foundation

public struct NotionTaskLink: Equatable, Sendable {
  public var notionId: String
  public var taskId: String
  public var sourceId: String
  /// Bei Weekly-Quellen der Titel der Woche (Unterseite/Zeile), aus der die Aufgabe stammt; sonst nil.
  public var group: String?
  public var meta: NotionTaskMeta
  /// Letzter gemeinsamer Stand (Titel, Fälligkeit) beim Abgleich; nil = noch keiner (Erstabgleich).
  public var syncedTitle: String?
  public var syncedDue: String?
  public init(notionId: String, taskId: String, sourceId: String, group: String? = nil,
              meta: NotionTaskMeta = NotionTaskMeta(), syncedTitle: String? = nil, syncedDue: String? = nil) {
    self.notionId = notionId; self.taskId = taskId; self.sourceId = sourceId; self.group = group; self.meta = meta
    self.syncedTitle = syncedTitle; self.syncedDue = syncedDue
  }
}

public final class NotionTaskLinksRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  /// Alle gemerkten Verknüpfungen.
  public func all() throws -> [NotionTaskLink] {
    try db.query("SELECT * FROM notion_task_links").map {
      NotionTaskLink(notionId: $0.text("notion_id"), taskId: $0.text("task_id"), sourceId: $0.text("source_id"),
                     group: $0.string("group_name"),
                     meta: NotionTaskMeta(createdAt: $0.string("created_at"), createdBy: $0.string("created_by_name"),
                                          status: $0.string("status")),
                     syncedTitle: $0.string("synced_title"), syncedDue: $0.string("synced_due"))
    }
  }

  /// Merkt den gemeinsamen Stand nach einem Abgleich oder Zurückschreiben. `upsert` lässt ihn unberührt.
  public func setSyncBaseline(notionId: String, title: String, due: String?) throws {
    try db.run("UPDATE notion_task_links SET synced_title = ?, synced_due = ? WHERE notion_id = ?",
               [.text(title), .of(due), .text(notionId)])
  }

  public func upsert(notionId: String, taskId: String, sourceId: String, group: String? = nil,
                     meta: NotionTaskMeta = NotionTaskMeta(), now: String) throws {
    try db.run(
      "INSERT INTO notion_task_links (notion_id, task_id, source_id, group_name, created_at, created_by_name, status, "
        + "updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
        + "ON CONFLICT(notion_id) DO UPDATE SET task_id = excluded.task_id, source_id = excluded.source_id, "
        + "group_name = excluded.group_name, created_at = excluded.created_at, "
        + "created_by_name = excluded.created_by_name, status = excluded.status, updated_at = excluded.updated_at",
      [.text(notionId), .text(taskId), .text(sourceId), .of(group), .of(meta.createdAt), .of(meta.createdBy),
       .of(meta.status), .text(now)])
  }

  public func delete(notionId: String) throws {
    try db.run("DELETE FROM notion_task_links WHERE notion_id = ?", [.text(notionId)])
  }

  /// Entfernt alle Verknüpfungen einer Quelle (beim Löschen der Quelle selbst).
  public func deleteBySource(_ sourceId: String) throws {
    try db.run("DELETE FROM notion_task_links WHERE source_id = ?", [.text(sourceId)])
  }
}
