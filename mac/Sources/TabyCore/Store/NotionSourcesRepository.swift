// Paket 11: benannte Notion-Quellen (Tickets/To-dos/Weekly), lösen die alten
// Einzelfelder notionTasksDatabaseId/notionTasksPageId ab. `sort_order` ist
// die Anlage-Reihenfolge (neue Quellen ans Ende). `account_id` ist der Notion-Zugang
// (`NotionAccount.id`); Altbestand gehört zum Standard-Zugang "notion".
import Foundation

public final class NotionSourcesRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  private func toSource(_ r: SQLRow) -> NotionSource? {
    guard let category = NotionSourceCategory(rawValue: r.text("category")) else { return nil }
    let account = r.text("account_id")
    return NotionSource(id: r.text("id"), name: r.text("name"), category: category, link: r.text("link"),
                        accountId: account.isEmpty ? NotionAccount.legacyId : account)
  }

  public func list() throws -> [NotionSource] {
    try db.query("SELECT * FROM notion_source ORDER BY sort_order, rowid").compactMap(toSource)
  }

  public func get(_ id: String) throws -> NotionSource? {
    try db.query("SELECT * FROM notion_source WHERE id = ?", [.text(id)]).first.flatMap(toSource)
  }

  @discardableResult
  public func add(name: String, category: NotionSourceCategory, link: String,
                  accountId: String = NotionAccount.legacyId) throws -> NotionSource {
    let source = NotionSource(id: StoreIds.make(), name: name, category: category, link: link, accountId: accountId)
    try insert(source)
    return source
  }

  /// Eine zuvor entfernte Quelle mit ihrer Kennung und ihrem Zugang wieder anlegen (Rückgängig).
  public func restore(_ source: NotionSource) throws {
    try insert(source)
  }

  private func insert(_ source: NotionSource) throws {
    let nextOrder = Int(try db.query("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM notion_source").first?.int("n") ?? 0)
    try db.run("INSERT OR REPLACE INTO notion_source (id, name, category, link, sort_order, account_id) VALUES (?, ?, ?, ?, ?, ?)",
               [.text(source.id), .text(source.name), .text(source.category.rawValue), .text(source.link),
                .of(nextOrder), .text(source.accountId)])
  }

  public func update(_ id: String, name: String? = nil, category: NotionSourceCategory? = nil,
                     link: String? = nil) throws -> NotionSource? {
    guard var s = try get(id) else { return nil }
    if let name { s.name = name }
    if let category { s.category = category }
    if let link { s.link = link }
    try db.run("UPDATE notion_source SET name = ?, category = ?, link = ? WHERE id = ?",
               [.text(s.name), .text(s.category.rawValue), .text(s.link), .text(id)])
    return s
  }

  public func delete(_ id: String) throws {
    try db.run("DELETE FROM notion_source WHERE id = ?", [.text(id)])
  }
}
