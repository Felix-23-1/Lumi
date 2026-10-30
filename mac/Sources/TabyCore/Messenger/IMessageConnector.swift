// Paket 12: iMessage/SMS. Lesen: `~/Library/Messages/chat.db` nur lesend mit sqlite3
// (Festplattenvollzugriff nötig). Senden: AppleScript an die Messages-App
// (Automation-Freigabe nötig). Namen aus Kontakten werden nicht aufgelöst
// (bräuchte die Kontakte-Freigabe): Titel = Gruppenname bzw. Telefonnummer/E-Mail.
import Foundation
import SQLite3

/// Lese-Marker der Lumi-Seite (Store), Schlüssel = "<accountId>|<roomId>".
public struct MessengerReadMarkers: Sendable {
  public var get: @Sendable (String) -> Int?
  public var set: @Sendable (String, Int) -> Void

  public init(get: @escaping @Sendable (String) -> Int?, set: @escaping @Sendable (String, Int) -> Void) {
    self.get = get
    self.set = set
  }
}

public final class IMessageConnector: MessengerConnector, @unchecked Sendable {
  public let service: MessengerService = .imessage

  public static let defaultChatDbPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Messages/chat.db").path
  static let accessDeniedText =
    "Lumi braucht den Festplattenvollzugriff (Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff)"
  static let automationDeniedText =
    "Lumi darf Nachrichten noch nicht steuern (Systemeinstellungen → Datenschutz & Sicherheit → Automation)"

  /// Startet `osascript -e <script>` (Standard; Prüfungen setzen eine Attrappe).
  public static let osascript: @Sendable (String) throws -> ProcessOutput = { script in
    let r = try ModProcess.run("/usr/bin/osascript", ["-e", script], timeout: 20)
    return ProcessOutput(status: r.status, timedOut: r.timedOut, stdout: r.stdout, stderr: r.stderr)
  }

  private let chatDbPath: String
  /// Offene Verbindung (siehe `withDatabase`); der Schalter schützt sie vor parallelen Abfragen.
  private let dbLock = NSLock()
  private var dbHandle: OpaquePointer?
  private let readMarkers: MessengerReadMarkers
  private let runScript: @Sendable (String) throws -> ProcessOutput
  /// Kennung des Kontos; gesetzt durch `login` bzw. `restore` (der Hub ruft nur so auf).
  private var accountId = ""

  public init(chatDbPath: String = IMessageConnector.defaultChatDbPath, readMarkers: MessengerReadMarkers,
              runScript: @escaping @Sendable (String) throws -> ProcessOutput = IMessageConnector.osascript) {
    self.chatDbPath = chatDbPath
    self.readMarkers = readMarkers
    self.runScript = runScript
  }

  public func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
    self.accountId = accountId
    try await Blocking.run { try self.withDatabase { _ in } }
    return (MessengerAccount(id: accountId, service: .imessage, user: "Dieser Mac"), "")
  }

  public func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount {
    accountId = account.id
    try await Blocking.run { try self.withDatabase { _ in } }
    return account
  }

  /// Ohne Verschlüsselungs-Schlüssel: nichts zu entsperren.
  public func unlock(recoveryKey: String) async throws {}

  public func conversations() async throws -> [MessengerConversation] {
    let account = accountId, reads = readMarkers
    return try await Blocking.run {
      try self.withDatabase { db in try Self.loadConversations(db, accountId: account, reads: reads) }
    }
  }

  public func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] {
    let account = accountId, count = max(1, min(limit, 200))
    return try await Blocking.run {
      try self.withDatabase { db in
        let rows = try chatQuery(db, """
          SELECT m.ROWID AS mid, m.text AS text, m.attributedBody AS body, m.date AS date,
                 m.is_from_me AS fromme, h.id AS handle
          FROM chat c
          JOIN chat_message_join j ON j.chat_id = c.ROWID
          JOIN message m ON m.ROWID = j.message_id
          LEFT JOIN handle h ON h.ROWID = m.handle_id
          WHERE c.guid = ?
          ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
          """, [.text(roomId), .int(Int64(count))])
        return rows.reversed().map { r in
          let mine = (r.int("fromme") ?? 0) == 1
          return MessengerMessage(
            id: String(r.int("mid") ?? 0), conversationId: "\(account)|\(roomId)",
            sender: mine ? "Ich" : (r.text("handle") ?? "Unbekannt"),
            text: Self.messageText(r.text("text"), r.blob("body")), at: Self.localDate(r.int("date") ?? 0), mine: mine)
        }
      }
    }
  }

  public func send(roomId: String, text: String) async throws {
    let script = Self.sendScript(text: text, chatGuid: roomId)
    let output = try await Blocking.run { try self.runScript(script) }
    if output.timedOut || output.status != 0 {
      let denied = output.stderr.contains("-1743") || output.stderr.localizedCaseInsensitiveContains("Not authorized")
      throw MessengerFailure(message: denied ? Self.automationDeniedText : "Die Nachricht konnte nicht gesendet werden.")
    }
  }

  public func markRead(roomId: String) async throws {
    let account = accountId, reads = readMarkers
    let latest: Int64? = try await Blocking.run {
      try self.withDatabase { db in
        try chatQuery(db, """
          SELECT MAX(m.ROWID) AS mx FROM chat c
          JOIN chat_message_join j ON j.chat_id = c.ROWID
          JOIN message m ON m.ROWID = j.message_id WHERE c.guid = ?
          """, [.text(roomId)]).first?.int("mx")
      }
    }
    if let latest { reads.set("\(account)|\(roomId)", Int(latest)) }
  }

  public func logout() async {
    accountId = ""
  }

  // MARK: - Lesen

  static func loadConversations(_ db: OpaquePointer, accountId: String, reads: MessengerReadMarkers) throws
    -> [MessengerConversation]
  {
    // Neueste Nachricht je Chat (ROWID-Vergleich nur für die Auswahl der letzten Zeile).
    let chats = try chatQuery(db, """
      SELECT c.ROWID AS cid, c.guid AS guid, c.chat_identifier AS ident, c.display_name AS dname,
             m.text AS text, m.attributedBody AS body, m.date AS date
      FROM chat c
      JOIN chat_message_join j ON j.chat_id = c.ROWID
      JOIN message m ON m.ROWID = j.message_id
      WHERE m.ROWID = (
        SELECT m2.ROWID FROM message m2 JOIN chat_message_join j2 ON j2.message_id = m2.ROWID
        WHERE j2.chat_id = c.ROWID ORDER BY m2.date DESC, m2.ROWID DESC LIMIT 1)
      ORDER BY m.date DESC, m.ROWID DESC LIMIT 50
      """)
    var handles: [Int64: [String]] = [:]
    for r in try chatQuery(db, """
      SELECT cj.chat_id AS cid, h.id AS hid FROM chat_handle_join cj
      JOIN handle h ON h.ROWID = cj.handle_id ORDER BY h.id
      """) {
      if let cid = r.int("cid"), let hid = r.text("hid") { handles[cid, default: []].append(hid) }
    }
    let keyed = chats.compactMap { r -> (row: ChatRow, cid: Int64, guid: String)? in
      guard let cid = r.int("cid"), let guid = r.text("guid") else { return nil }
      return (r, cid, guid)
    }
    let unread = try unreadCounts(db, keyed.map { k in
      (chatId: k.cid, marker: reads.get("\(accountId)|\(k.guid)"))
    })
    return keyed.map { k in
      let r = k.row, cid = k.cid
      let roomHandles = handles[cid] ?? []
      let title = nonEmpty(r.text("dname")) ?? (roomHandles.isEmpty ? nil : roomHandles.joined(separator: ", "))
        ?? nonEmpty(r.text("ident")) ?? "Unbekannt"
      let convId = "\(accountId)|\(k.guid)"
      return MessengerConversation(
        id: convId, accountId: accountId, title: title,
        unread: unread[cid] ?? 0,
        lastText: messageText(r.text("text"), r.blob("body")),
        lastAt: localDate(r.int("date") ?? 0), isDirect: roomHandles.count <= 1)
    }
  }

  /// Ungelesene Zähler aller Chats in EINER Abfrage (UNION ALL statt eine Abfrage je Chat).
  /// Je Chat wie `unreadCount`; die Chat-Kennung ist eine Ganzzahl aus der Datenbank, kein Text.
  static func unreadCounts(_ db: OpaquePointer, _ chats: [(chatId: Int64, marker: Int?)]) throws -> [Int64: Int] {
    guard !chats.isEmpty else { return [:] }
    var binds: [ChatCell] = []
    let parts = chats.map { c -> String in
      let cond: String
      if let marker = c.marker {
        cond = "m.ROWID > ?"
        binds.append(.int(Int64(marker)))
      } else {
        cond = "m.is_read = 0"
      }
      return """
        SELECT \(c.chatId) AS cid, COUNT(*) AS n FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
        WHERE j.chat_id = \(c.chatId) AND m.is_from_me = 0 AND \(cond)
        """
    }
    var out: [Int64: Int] = [:]
    for r in try chatQuery(db, parts.joined(separator: " UNION ALL "), binds) {
      if let cid = r.int("cid") { out[cid] = Int(r.int("n") ?? 0) }
    }
    return out
  }

  /// Eingehende Nachrichten nach Lumi-Marker; ohne Marker zählt Messages' eigenes "gelesen"-Flag.
  static func unreadCount(_ db: OpaquePointer, chatId: Int64, after marker: Int?) throws -> Int {
    let sql = """
      SELECT COUNT(*) AS n FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
      WHERE j.chat_id = ? AND m.is_from_me = 0 AND
      """
    let rows: [ChatRow]
    if let marker {
      rows = try chatQuery(db, sql + " m.ROWID > ?", [.int(chatId), .int(Int64(marker))])
    } else {
      rows = try chatQuery(db, sql + " m.is_read = 0", [.int(chatId)])
    }
    return Int(rows.first?.int("n") ?? 0)
  }

  /// Text; sonst aus `attributedBody` (typedstream) oder "(Anhang)".
  static func messageText(_ text: String?, _ body: Data?) -> String {
    if let clean = nonEmpty(text) { return clean }
    if let body, let clean = nonEmpty(typedStreamText(body)) { return clean }
    return "(Anhang)"
  }

  /// Text aus einem `attributedBody` (NSArchiver-typedstream) ohne NSUnarchiver: der wirft bei
  /// kaputten Daten ObjC-Ausnahmen, die Swift nicht fangen kann. Nach der Klasse "NSString"
  /// folgt '+' (0x2B), dann die Länge (< 0x80 direkt; 0x81 = UInt16 LE; 0x82 = UInt32 LE) und UTF-8.
  static func typedStreamText(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    let marker = Array("NSString".utf8)
    guard bytes.count > marker.count,
          let at = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker })
    else { return nil }
    var i = at + marker.count
    let searchEnd = min(bytes.count, i + 16)
    while i < searchEnd, bytes[i] != 0x2B { i += 1 }
    guard i < searchEnd else { return nil }
    i += 1
    guard i < bytes.count else { return nil }
    var length = Int(bytes[i]); i += 1
    if length == 0x81 || length == 0x82 {
      let width = length == 0x81 ? 2 : 4
      guard i + width <= bytes.count else { return nil }
      length = bytes[i..<i + width].reversed().reduce(0) { $0 << 8 | Int($1) }
      i += width
    } else if length >= 0x80 {
      return nil
    }
    guard length > 0, length <= bytes.count - i else { return nil }
    return String(bytes: bytes[i..<i + length], encoding: .utf8)
  }

  /// Apple-Zeit: Nanosekunden seit 2001-01-01 (ältere Datenbanken: Sekunden).
  static func localDate(_ raw: Int64) -> String {
    let seconds = raw >= 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
    return LocalTime.format(Date(timeIntervalSinceReferenceDate: seconds))
  }

  /// Ersetzt Anhangszeichen (U+FFFC) und trimmt; leer → nil.
  static func nonEmpty(_ s: String?) -> String? {
    let t = s?.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty ?? true) ? nil : t
  }

  // MARK: - Senden

  /// AppleScript-Zeile; Text und Chat-Kennung als escapte Literale.
  static func sendScript(text: String, chatGuid: String) -> String {
    "tell application \"Messages\" to send \"\(appleScriptLiteral(text))\" to chat id \"\(appleScriptLiteral(chatGuid))\""
  }

  static func appleScriptLiteral(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }

  // MARK: - Datenbank (nur lesend, ohne Lumi-Migrationen)

  /// Führt `body` auf einer schreibgeschützten Verbindung zu `chat.db` aus. Die Verbindung bleibt
  /// zwischen den Abfragen offen (kein Neuöffnen je Takt); nach einem Fehler wird sie geschlossen
  /// und beim nächsten Mal neu geöffnet. Ohne Festplattenvollzugriff schlägt das Öffnen oder Lesen fehl.
  /// URI mit `mode=ro` (nicht `immutable=1`): so liest SQLite die WAL-Datei mit und sieht neue Nachrichten.
  func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    dbLock.lock()
    defer { dbLock.unlock() }
    if dbHandle == nil { dbHandle = try Self.openReadOnly(chatDbPath) }
    guard let db = dbHandle else { throw MessengerFailure(message: "Nachrichten sind nicht lesbar.") }
    do {
      return try body(db)
    } catch {
      sqlite3_close(db)
      dbHandle = nil
      throw error
    }
  }

  private static func openReadOnly(_ path: String) throws -> OpaquePointer {
    var handle: OpaquePointer?
    let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
    let opened = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    guard opened == SQLITE_OK, let db = handle else {
      let failure = chatFailure(opened, handle)
      sqlite3_close(handle)
      throw failure
    }
    sqlite3_busy_timeout(db, 2000)
    return db
  }

  deinit {
    if let dbHandle { sqlite3_close(dbHandle) }
  }
}

/// Fehler mit fertigem deutschen Text für die Oberfläche.
public struct MessengerFailure: Error, LocalizedError {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Werte aus der Messages-Datenbank (nur was Lumi braucht).
enum ChatCell {
  case int(Int64)
  case text(String)
  case blob(Data)
  case null
}

/// Zeile als Spalten-Name → Wert.
struct ChatRow {
  let cells: [String: ChatCell]
  func text(_ key: String) -> String? { if case .text(let s) = cells[key] { return s }; return nil }
  func int(_ key: String) -> Int64? { if case .int(let v) = cells[key] { return v }; return nil }
  func blob(_ key: String) -> Data? { if case .blob(let d) = cells[key] { return d }; return nil }
}

/// Führt eine Abfrage mit Positions-Parametern aus (Text oder Ganzzahl).
func chatQuery(_ db: OpaquePointer, _ sql: String, _ binds: [ChatCell] = []) throws -> [ChatRow] {
  var stmt: OpaquePointer?
  let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
  guard prepared == SQLITE_OK, let stmt else {
    sqlite3_finalize(stmt)
    throw chatFailure(prepared, db)
  }
  defer { sqlite3_finalize(stmt) }
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT
  for (i, bind) in binds.enumerated() {
    let index = Int32(i + 1)
    switch bind {
    case .int(let v): sqlite3_bind_int64(stmt, index, v)
    case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
    case .blob, .null: sqlite3_bind_null(stmt, index)
    }
  }
  var rows: [ChatRow] = []
  while true {
    let step = sqlite3_step(stmt)
    if step == SQLITE_DONE { break }
    guard step == SQLITE_ROW else { throw chatFailure(step, db) }
    var cells: [String: ChatCell] = [:]
    for col in 0..<sqlite3_column_count(stmt) {
      let name = String(cString: sqlite3_column_name(stmt, col))
      switch sqlite3_column_type(stmt, col) {
      case SQLITE_INTEGER:
        cells[name] = .int(sqlite3_column_int64(stmt, col))
      case SQLITE_TEXT:
        if let p = sqlite3_column_text(stmt, col) { cells[name] = .text(String(cString: p)) }
      case SQLITE_BLOB:
        let n = Int(sqlite3_column_bytes(stmt, col))
        if n > 0, let p = sqlite3_column_blob(stmt, col) { cells[name] = .blob(Data(bytes: p, count: n)) }
      default:
        cells[name] = .null
      }
    }
    rows.append(ChatRow(cells: cells))
  }
  return rows
}

/// Rechte-Fehler (fehlender Festplattenvollzugriff: CANTOPEN/PERM/AUTH bzw. EPERM/EACCES) bekommen
/// den Freigabe-Hinweis; alles andere (auch "Datei fehlt") den echten SQLite-Fehler.
func chatFailure(_ code: Int32, _ db: OpaquePointer?) -> MessengerFailure {
  let errno = db.map { sqlite3_system_errno($0) } ?? 0
  let primary = code & 0xFF
  let denied = errno == EPERM || errno == EACCES
    || (errno != ENOENT && [SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH].contains(primary))
  if denied { return MessengerFailure(message: IMessageConnector.accessDeniedText) }
  let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
  return MessengerFailure(message: "Nachrichten konnten nicht gelesen werden (\(detail)).")
}
