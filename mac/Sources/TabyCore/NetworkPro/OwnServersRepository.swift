// Eigene Server, die der Nutzer selbst prüfen darf (Tabelle own_servers, Migration 10).
// Nur wer hier einen Eintrag hat, darf außerhalb des eigenen Netzes gescannt werden.
import Foundation

public enum OwnServerError: Error, Equatable, LocalizedError {
  case invalidHost

  public var errorDescription: String? {
    "Ungültiger Rechnername oder ungültige IP-Adresse."
  }
}

public final class OwnServersRepository: @unchecked Sendable {
  public static let maxLabel = 60
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  /// "https://Test.Example.de:8443/pfad " → "test.example.de". nil, wenn kein gültiger Name/keine IP bleibt.
  public static func normalize(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    // Ein einzelner Doppelpunkt ist „host:port“; IPv6 (mehrere Doppelpunkte) bleibt unverändert.
    if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
      let port = s[s.index(after: colon)...]
      if port.allSatisfy(\.isNumber) { s = String(s[..<colon]) }
    }
    if s.hasSuffix(".") { s.removeLast() }
    guard !s.isEmpty, NetworkAddress.isValidHost(s) else { return nil }
    return s
  }

  /// Trägt einen Server ein. Gleicher Host = gleicher Eintrag (nichts doppelt).
  /// Das Hinzufügen gilt als Bestätigung, dass der Nutzer den Server prüfen darf.
  public func add(host: String, label: String, now: String) throws -> OwnServer {
    guard let normalized = Self.normalize(host) else { throw OwnServerError.invalidHost }
    if let existing = try list().first(where: { $0.host == normalized }) { return existing }
    let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabel))
    let server = OwnServer(id: StoreIds.make(), host: normalized,
                           label: trimmed.isEmpty ? normalized : trimmed, authorized: true, addedAt: now)
    try db.run(
      "INSERT INTO own_servers (id, host, label, authorized, added_at) VALUES (?, ?, ?, ?, ?)",
      [.text(server.id), .text(server.host), .text(server.label), .of(server.authorized), .text(server.addedAt)])
    return server
  }

  /// Alle eigenen Server in Eintrags-Reihenfolge.
  public func list() throws -> [OwnServer] {
    try db.query("SELECT * FROM own_servers ORDER BY added_at, rowid").map { r in
      OwnServer(id: r.text("id"), host: r.text("host"), label: r.text("label"),
                authorized: r.bool("authorized"), addedAt: r.text("added_at"))
    }
  }

  public func remove(_ id: String) throws {
    try db.run("DELETE FROM own_servers WHERE id = ?", [.text(id)])
  }
}
