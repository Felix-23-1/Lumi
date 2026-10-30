// Offene Verbindungen dieses Macs (lsof). Es wird nichts gescannt: lsof fragt nur
// die eigenen Sockets ab. Format: klassische lsof-Tabelle mit `-i -n -P` (keine
// DNS-Auflösung, keine Portnamen), damit die Zeilen stabil zerlegbar sind.
import Foundation

/// Grenze zu lsof (Prüfungen setzen eine Attrappe ein).
public protocol ConnSystem: Sendable {
  /// Ausgabe von `lsof -i -n -P`; leer, wenn lsof nicht lief.
  func lsof() async -> String
}

/// Echte Umsetzung: `/usr/sbin/lsof -i -n -P`. Ohne Administratorrechte sieht lsof nur
/// Verbindungen, die dem eigenen Benutzer gehören; Sockets anderer Benutzer fehlen.
public struct SystemConnections: ConnSystem {
  public init() {}

  public func lsof() async -> String {
    await Blocking.run {
      guard let r = try? ModProcess.run("/usr/sbin/lsof", ["-i", "-n", "-P"], timeout: 20) else { return "" }
      // lsof endet mit Status 1, wenn nichts gefunden wurde; die Tabelle ist dann trotzdem gültig.
      return r.stdout
    }
  }
}

/// Eine Zeile aus lsof, noch ohne Bewertung.
public struct RawConn: Equatable, Sendable {
  public var app: String
  public var pid: Int
  public var proto: String
  /// "192.168.1.5:54321", "*:22", "[::1]:7000"
  public var local: String
  /// Gegenstelle, nur bei verbundenen Sockets.
  public var remote: String?
  /// "ESTABLISHED", "LISTEN", … ; "-" wenn lsof keinen Zustand meldet.
  public var state: String
  public init(app: String, pid: Int, proto: String, local: String, remote: String?, state: String) {
    self.app = app; self.pid = pid; self.proto = proto; self.local = local; self.remote = remote; self.state = state
  }
}

public enum LsofParser {
  /// Zerlegt die Tabelle. Spalten: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME.
  /// Der Name beginnt nach dem Protokoll (TCP/UDP) und endet optional mit „(ZUSTAND)“.
  public static func parse(_ output: String) -> [RawConn] {
    var rows: [RawConn] = []
    for line in output.split(whereSeparator: \.isNewline) {
      let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard tokens.count >= 9, let pid = Int(tokens[1]),
            let nodeIndex = tokens.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }),
            nodeIndex >= 5, nodeIndex + 1 < tokens.count else { continue }

      var nameTokens = Array(tokens[(nodeIndex + 1)...])
      var state = "-"
      if let last = nameTokens.last, last.hasPrefix("("), last.hasSuffix(")"), last.count > 2 {
        state = String(last.dropFirst().dropLast())
        nameTokens.removeLast()
      }
      let name = nameTokens.joined(separator: " ")
      let parts = name.components(separatedBy: "->")
      guard let local = parts.first, !local.isEmpty else { continue }
      let remote = parts.count > 1 ? parts[1] : nil

      rows.append(RawConn(
        app: tokens[0].replacingOccurrences(of: "\\x20", with: " "),
        pid: pid,
        proto: tokens[nodeIndex],
        local: local,
        remote: remote,
        state: state))
    }
    return rows
  }

  /// "192.168.1.5:54321" → ("192.168.1.5", "54321"); "[fe80::1]:5353" → ("fe80::1", "5353"); "*:22" → ("*", "22").
  public static func splitHostPort(_ address: String) -> (host: String, port: String)? {
    if address.hasPrefix("[") {
      guard let close = address.firstIndex(of: "]") else { return nil }
      let host = String(address[address.index(after: address.startIndex)..<close])
      let rest = address[address.index(after: close)...]
      guard rest.hasPrefix(":") else { return nil }
      return (host, String(rest.dropFirst()))
    }
    guard let colon = address.lastIndex(of: ":") else { return nil }
    return (String(address[..<colon]), String(address[address.index(after: colon)...]))
  }

  /// Nur die Adresse ohne Port (für Ortsprüfung und Rechnernamen).
  public static func hostOnly(_ address: String) -> String? {
    splitHostPort(address)?.host
  }
}

public final class ConnectionsLister: @unchecked Sendable {
  public static let maxReverseLookups = 10
  public static let reverseTimeout: TimeInterval = 0.5

  let system: ConnSystem
  let net: NetworkSystem

  public init(system: ConnSystem, net: NetworkSystem) {
    self.system = system
    self.net = net
  }

  /// Alle Verbindungen dieses Macs; Gegenstellen im eigenen Netz werden nicht aufgelöst.
  public func list() async -> ToolResult<[Connection]> {
    let text = await system.lsof()
    guard !text.isEmpty else {
      return .failure(code: "NETWORK_FAILED", error: "Die offenen Verbindungen konnten nicht gelesen werden.")
    }
    let rows = Self.dedupe(LsofParser.parse(text))
    let ips = Self.reverseCandidates(rows)
    let names = await reverseNames(ips)
    return .ok(Self.sorted(rows.map { Self.connection($0, names: names) }))
  }

  /// Gleiche Zeilen (App, PID, Protokoll, Adressen, Zustand) nur einmal, Reihenfolge bleibt.
  static func dedupe(_ rows: [RawConn]) -> [RawConn] {
    var seen = Set<String>()
    return rows.filter { seen.insert(key($0)).inserted }
  }

  static func key(_ row: RawConn) -> String {
    "\(row.app)|\(row.pid)|\(row.proto)|\(row.local)|\(row.remote ?? "")|\(row.state)"
  }

  /// Fremde (nicht private) IPv4-Gegenstellen, je Adresse einmal, höchstens `maxReverseLookups`.
  static func reverseCandidates(_ rows: [RawConn]) -> [String] {
    var out: [String] = []
    for row in rows where !isLocal(row) {
      guard let ip = row.remote.flatMap(LsofParser.hostOnly), NetworkAddress.isIPv4(ip), !out.contains(ip) else {
        continue
      }
      out.append(ip)
    }
    return Array(out.prefix(maxReverseLookups))
  }

  /// Ohne Gegenstelle (Listen, UDP) gilt die Verbindung als lokal; sonst zählt die Adresse der Gegenstelle.
  static func isLocal(_ row: RawConn) -> Bool {
    guard let remote = row.remote, let host = LsofParser.hostOnly(remote) else { return true }
    return NetworkAddress.isPrivate(host)
  }

  static func connection(_ row: RawConn, names: [String: String]) -> Connection {
    let host = row.remote.flatMap(LsofParser.hostOnly)
    return Connection(
      id: key(row),
      app: row.app,
      pid: row.pid,
      proto: row.proto,
      localAddress: row.local,
      remoteAddress: row.remote,
      remoteHost: host.flatMap { names[$0] },
      state: row.state,
      isLocal: isLocal(row))
  }

  /// Sortierung: fremde Gegenstellen zuerst, dann nach App (ohne Groß-/Kleinschreibung), dann Schlüssel.
  static func sorted(_ list: [Connection]) -> [Connection] {
    list.sorted { a, b in
      let ra = (a.remoteAddress != nil && !a.isLocal) ? 0 : 1
      let rb = (b.remoteAddress != nil && !b.isLocal) ? 0 : 1
      if ra != rb { return ra < rb }
      let appA = a.app.lowercased(), appB = b.app.lowercased()
      if appA != appB { return appA < appB }
      return a.id < b.id
    }
  }

  private func reverseNames(_ ips: [String]) async -> [String: String] {
    let net = self.net
    return await withTaskGroup(of: (String, String?).self) { group -> [String: String] in
      for ip in ips {
        group.addTask { (ip, await net.reverseName(ip, timeout: Self.reverseTimeout)) }
      }
      var out: [String: String] = [:]
      for await (ip, name) in group {
        if let name { out[ip] = name }
      }
      return out
    }
  }
}
