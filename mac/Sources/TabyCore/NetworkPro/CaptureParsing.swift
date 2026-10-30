// Reine Auswertung des Mitschnitts (ohne Systemaufrufe): tcpdump-Zeilen, Zähler je
// Gegenstelle und die Liste der Schnittstellen.
import Foundation

public enum TcpdumpParser {
  /// Eine Zeile von `tcpdump -nttt -l`, z. B.
  /// `00:00:00.000123 IP 192.168.178.45.54321 > 17.253.144.10.443: Flags [P.], … length 517`.
  /// `t` ist hier der Abstand zum Vorpaket in Sekunden; die Summe bildet der Mitschnitt.
  /// Zeilen ohne IP-Paket (z. B. ARP) ergeben nil.
  public static func parseLine(_ line: String) -> CapturePacket? {
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count == 3, let delta = seconds(String(parts[0])) else { return nil }
    let family = parts[1]
    guard family == "IP" || family == "IP6" else { return nil }

    let rest = String(parts[2])
    guard let arrow = rest.range(of: " > ") else { return nil }
    let afterArrow = rest[arrow.upperBound...]
    guard let colon = afterArrow.range(of: ": ") else { return nil }
    guard let src = endpoint(String(rest[..<arrow.lowerBound])),
          let dst = endpoint(String(afterArrow[..<colon.lowerBound])) else { return nil }
    let info = String(afterArrow[colon.upperBound...]).trimmingCharacters(in: .whitespaces)

    let length = lengthOf(info) ?? 0
    let proto: String
    let shownInfo: String
    if let flags = flagsOf(info) {
      proto = "TCP"
      shownInfo = "Flags [\(flags)], \(portText(src.port)) → \(portText(dst.port))"
    } else if info.hasPrefix("ICMP") {
      proto = "ICMP"
      shownInfo = String(info.prefix(120))
    } else if src.port == 53 || dst.port == 53 {
      proto = "DNS"
      shownInfo = String(info.prefix(120))
    } else if src.port != nil || dst.port != nil || info.hasPrefix("UDP") {
      proto = "UDP"
      shownInfo = "\(portText(src.port)) → \(portText(dst.port))"
    } else {
      proto = family == "IP6" ? "IPv6" : "IP"
      shownInfo = String(info.prefix(120))
    }
    return CapturePacket(id: 0, t: delta, proto: proto, source: src.host, dest: dst.host,
                         length: length, info: shownInfo)
  }

  /// "HH:MM:SS.ffffff" → Sekunden.
  static func seconds(_ text: String) -> Double? {
    let p = text.split(separator: ":", omittingEmptySubsequences: false)
    guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let s = Double(p[2]),
          h >= 0, m >= 0, s >= 0 else { return nil }
    return h * 3600 + m * 60 + s
  }

  /// "192.168.178.45.54321" → (192.168.178.45, 54321); "17.253.144.10" → (…, nil);
  /// "fe80::1.5353" → (fe80::1, 5353); "ff02::fb" → (ff02::fb, nil).
  static func endpoint(_ text: String) -> (host: String, port: Int?)? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.contains(" ") else { return nil }
    if NetworkAddress.isIP(t) { return (t, nil) }
    if let dot = t.lastIndex(of: "."), let port = Int(t[t.index(after: dot)...]), (0...65535).contains(port) {
      let host = String(t[..<dot])
      if NetworkAddress.isIP(host) { return (host, port) }
    }
    return NetworkAddress.isValidDNSName(t) ? (t, nil) : nil
  }

  /// Inhalt von "Flags [P.]" → "P.".
  static func flagsOf(_ info: String) -> String? {
    guard info.hasPrefix("Flags ["), let close = info.firstIndex(of: "]") else { return nil }
    return String(info[info.index(info.startIndex, offsetBy: 7)..<close])
  }

  /// "length 517" am Ende der Info, sonst „(44)“ am Ende (UDP-Nutzlänge bei DNS).
  static func lengthOf(_ info: String) -> Int? {
    if let range = info.range(of: "length ", options: .backwards) {
      let digits = info[range.upperBound...].prefix { $0.isNumber }
      if let n = Int(digits) { return n }
    }
    if info.hasSuffix(")"), let open = info.lastIndex(of: "(") {
      let inner = info[info.index(after: open)..<info.index(before: info.endIndex)]
      return Int(inner)
    }
    return nil
  }

  static func portText(_ port: Int?) -> String {
    port.map(String.init) ?? "-"
  }
}

public enum CaptureStats {
  /// Höchstens so viele Gegenstellen werden gezählt (die mit den meisten Bytes bleiben).
  public static let maxHosts = 30

  /// Zählt ein Paket: Anzahl, Pakete und Bytes je Endpunkt (Quelle und Ziel), sortiert nach Bytes.
  public static func merge(existing: CaptureState, packet: CapturePacket) -> CaptureState {
    var state = existing
    state.packetCount += 1
    var byHost = Dictionary(existing.byHost.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for host in Set([packet.source, packet.dest]) where !host.isEmpty {
      var stat = byHost[host] ?? CaptureHostStat(id: host, packets: 0, bytes: 0)
      stat.packets += 1
      stat.bytes += packet.length
      byHost[host] = stat
    }
    state.byHost = Array(byHost.values.sorted { a, b in
      if a.bytes != b.bytes { return a.bytes > b.bytes }
      return a.id < b.id
    }.prefix(maxHosts))
    return state
  }
}

public enum InterfaceParser {
  /// Ausgabe von `ifconfig -l` (Namen durch Leerraum getrennt) → en*, utun*, bridge*, lo*, in Reihenfolge.
  public static func parse(_ output: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for name in output.split(whereSeparator: \.isWhitespace).map(String.init) where isUseful(name) {
      if seen.insert(name).inserted { out.append(name) }
    }
    return out
  }

  static func isUseful(_ name: String) -> Bool {
    ["en", "utun", "bridge", "lo"].contains { prefix in
      let suffix = name.dropFirst(prefix.count)
      return name.hasPrefix(prefix) && !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
  }
}
