// Paket 10: Prioritätsliste offener Aufgaben. Die Reihenfolge (rank) bestimmt,
// welche Aufgaben der Tagesplan zuerst einplant.
import Foundation

public final class TaskPriorityRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  /// Aufgaben-IDs in Prioritätsreihenfolge (aufsteigend nach rank).
  public func list() throws -> [String] {
    try db.query("SELECT task_id FROM task_priority ORDER BY rank ASC").map { $0.text("task_id") }
  }

  /// Ersetzt die ganze Liste durch `taskIds` (Reihenfolge = Index).
  public func set(_ taskIds: [String]) throws {
    try db.transaction {
      _ = try db.run("DELETE FROM task_priority")
      for (index, id) in taskIds.enumerated() {
        _ = try db.run("INSERT INTO task_priority (task_id, rank) VALUES (?, ?)", [.text(id), .of(index)])
      }
    }
  }
}
