// Paket 12: verbundene Chat-Konten (ohne Geheimnis; das liegt im Schlüsselbund)
// und Lese-Marker je Unterhaltung ("<accountId>|<roomId>" → letzte gelesene ROWID).
import Foundation

public final class MessengerAccountsRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db
    self.clock = clock
  }

  public func list() throws -> [MessengerAccount] {
    try db.query("SELECT * FROM messenger_accounts ORDER BY created_at, rowid").compactMap { r in
      guard let service = MessengerService(rawValue: r.text("service")) else { return nil }
      return MessengerAccount(id: r.text("id"), service: service, server: r.text("server"), user: r.text("user"))
    }
  }

  public func add(_ account: MessengerAccount) throws {
    try db.run("INSERT INTO messenger_accounts (id, service, server, user, created_at) VALUES (?, ?, ?, ?, ?)",
               [.text(account.id), .text(account.service.rawValue), .text(account.server), .text(account.user),
                .text(LocalTime.format(clock.now()))])
  }

  public func delete(_ id: String) throws {
    try db.run("DELETE FROM messenger_accounts WHERE id = ?", [.text(id)])
  }
}

public final class MessengerReadRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) { self.db = db }

  public func get(_ conversationId: String) throws -> Int? {
    try db.query("SELECT last_rowid FROM messenger_read WHERE conversation_id = ?", [.text(conversationId)])
      .first.flatMap { $0.int("last_rowid") }.map { Int($0) }
  }

  public func set(_ conversationId: String, lastRowId: Int) throws {
    try db.run("INSERT OR REPLACE INTO messenger_read (conversation_id, last_rowid) VALUES (?, ?)",
               [.text(conversationId), .of(lastRowId)])
  }
}
