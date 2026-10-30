// Dünne Hülle über die SQLite-C-API (`import SQLite3`, keine Fremdpakete).
// Port von src/main/store/db.ts: Öffnen, Migrationen genau einmal
// (schema_migrations), Fremdschlüssel an.
import Foundation
import SQLite3

/// Ein SQLite-Wert (Parameter oder Spalte).
public enum SQLValue: Equatable, Sendable {
  case null
  case int(Int64)
  case double(Double)
  case text(String)

  public static func of(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
  public static func of(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
  public static func of(_ i: Int) -> SQLValue { .int(Int64(i)) }
  public static func minutesValue(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
}

/// Eine Ergebniszeile, Zugriff über Spaltennamen.
public struct SQLRow: Sendable {
  public let values: [String: SQLValue]

  public func string(_ key: String) -> String? {
    switch values[key] {
    case .text(let s): return s
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    default: return nil
    }
  }

  /// Pflichtfeld als Text (leer, falls NULL – sollte bei NOT NULL nie passieren).
  public func text(_ key: String) -> String { string(key) ?? "" }

  public func int(_ key: String) -> Int64? {
    switch values[key] {
    case .int(let i): return i
    case .double(let d): return Int64(d)
    case .text(let s): return Int64(s)
    default: return nil
    }
  }

  public func bool(_ key: String) -> Bool { int(key) == 1 }
}

public struct StoreError: Error, CustomStringConvertible, LocalizedError {
  public let message: String
  public let code: Int32
  public var description: String { "Datenbankfehler (\(code)): \(message)" }
  public var errorDescription: String? { description }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-Verbindung. Alle Zugriffe sind über eine Sperre serialisiert, die
/// Verbindung darf also von mehreren Tasks aus benutzt werden.
public final class Database: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let lock = NSRecursiveLock()
  public let path: String

  private init(handle: OpaquePointer?, path: String) {
    self.handle = handle
    self.path = path
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  /// Öffnet (und legt bei Bedarf an) die Datenbankdatei und migriert sie.
  /// `":memory:"` öffnet eine flüchtige Datenbank.
  public static func open(path: String, clock: Clock = SystemClock()) throws -> Database {
    if path != ":memory:" {
      let dir = (path as NSString).deletingLastPathComponent
      if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      }
    }
    if path != ":memory:" { RestorePlan.applyIfPending(dbPath: path, clock: clock) }  // vor dem Öffnen, MediaAndBackups.swift
    var h: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(path, &h, flags, nil)
    guard rc == SQLITE_OK else {
      let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "kann nicht geöffnet werden"
      if let h { sqlite3_close_v2(h) }
      throw StoreError(message: "\(path): \(msg)", code: rc)
    }
    let db = Database(handle: h, path: path)
    sqlite3_busy_timeout(h, 5000)
    if path != ":memory:" { DatabaseBackup.beforeMigrate(db, clock: clock) }
    try db.execute("PRAGMA foreign_keys = ON;")
    if path != ":memory:" { try db.execute("PRAGMA journal_mode = WAL;") }
    try Migrations.migrate(db, clock: clock)
    return db
  }

  /// Flüchtige, migrierte Datenbank (Prüfungen, Testmodus).
  public static func openInMemory(clock: Clock = SystemClock()) throws -> Database {
    try open(path: ":memory:", clock: clock)
  }

  private func error(_ rc: Int32, _ context: String) -> StoreError {
    let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
    return StoreError(message: "\(msg) [\(context)]", code: rc)
  }

  /// Führt ein oder mehrere Anweisungen ohne Parameter aus (Migrationen, PRAGMA).
  public func execute(_ sql: String) throws {
    lock.lock(); defer { lock.unlock() }
    var errmsg: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
    if rc != SQLITE_OK {
      let msg = errmsg.map { String(cString: $0) } ?? "?"
      sqlite3_free(errmsg)
      throw StoreError(message: msg, code: rc)
    }
  }

  private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
    var stmt: OpaquePointer?
    let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
    guard rc == SQLITE_OK else { throw error(rc, sql) }
    for (i, p) in params.enumerated() {
      let idx = Int32(i + 1)
      let brc: Int32
      switch p {
      case .null: brc = sqlite3_bind_null(stmt, idx)
      case .int(let v): brc = sqlite3_bind_int64(stmt, idx, v)
      case .double(let v): brc = sqlite3_bind_double(stmt, idx, v)
      case .text(let v): brc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
      }
      if brc != SQLITE_OK {
        sqlite3_finalize(stmt)
        throw error(brc, sql)
      }
    }
    return stmt
  }

  /// Führt eine Anweisung aus und liefert die Zahl geänderter Zeilen.
  @discardableResult
  public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
    lock.lock(); defer { lock.unlock() }
    let stmt = try prepare(sql, params)
    defer { sqlite3_finalize(stmt) }
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
    guard rc == SQLITE_DONE else { throw error(rc, sql) }
    return Int(sqlite3_changes(handle))
  }

  /// Liest alle Ergebniszeilen.
  public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
    lock.lock(); defer { lock.unlock() }
    let stmt = try prepare(sql, params)
    defer { sqlite3_finalize(stmt) }
    var rows: [SQLRow] = []
    while true {
      let rc = sqlite3_step(stmt)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw error(rc, sql) }
      var values: [String: SQLValue] = [:]
      for c in 0..<sqlite3_column_count(stmt) {
        let name = String(cString: sqlite3_column_name(stmt, c))
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
        case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
        case SQLITE_NULL: values[name] = .null
        default:
          if let p = sqlite3_column_text(stmt, c) {
            values[name] = .text(String(cString: p))
          } else {
            values[name] = .null
          }
        }
      }
      rows.append(SQLRow(values: values))
    }
    return rows
  }

  /// Führt `body` in einer Transaktion aus; Fehler rollen zurück.
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE;")
    do {
      let result = try body()
      try execute("COMMIT;")
      return result
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  /// Angewandte Migrationsversionen (aufsteigend).
  public func appliedMigrations() throws -> [Int] {
    try query("SELECT version FROM schema_migrations ORDER BY version").compactMap { $0.int("version").map(Int.init) }
  }

  /// Namen aller Tabellen.
  public func tableNames() throws -> [String] {
    try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { $0.text("name") }
  }
}

/// Neue IDs für Datensätze (UUID, klein geschrieben).
public enum StoreIds {
  public static func make() -> String { UUID().uuidString.lowercased() }
}
