// Reine Auswertung der Ausgaben von macOS-Hilfsprogrammen (route, scutil,
// arp, ping, networkQuality, dig). Keine Systemaufrufe; Prüfungen nutzen echte
// Beispielausgaben.
import Foundation

public enum NetworkParsers {
  // MARK: route -n get default

  public struct DefaultRoute: Equatable, Sendable {
    public var interface: String
    public var gateway: String?
  }

  /// Ausgabe von `route -n get default` (Zeilen "key: value").
  public static func defaultRoute(_ output: String) -> DefaultRoute? {
    var fields: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if !key.isEmpty && fields[key] == nil { fields[key] = value }
    }
    guard let iface = fields["interface"], !iface.isEmpty else { return nil }
    let gateway = fields["gateway"].flatMap { NetworkAddress.isIP($0) ? $0 : nil }
    return DefaultRoute(interface: iface, gateway: gateway)
  }

  // MARK: scutil --dns

  /// DNS-Server aus `scutil --dns` (Zeilen "nameserver[0] : 192.168.178.1"), ohne Doppelte,
  /// in Reihenfolge, höchstens vier.
  public static func dnsServers(_ output: String, max: Int = 4) -> [String] {
    var result: [String] = []
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("nameserver["), let sep = line.range(of: " : ") else { continue }
      let value = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
      guard NetworkAddress.isIP(value), !result.contains(value) else { continue }
      result.append(value)
      if result.count == max { break }
    }
    return result
  }

  // MARK: arp -an

  public struct ArpEntry: Equatable, Sendable {
    public var ip: String
    public var mac: String
    /// Name, falls arp ihn ausgibt ("nas.fritz.box (192.168.178.30) at …"); sonst nil.
    public var name: String?
    public var interface: String?
  }

  /// Ausgabe von `arp -an`. Unvollständige Einträge, Broadcast- und Multicast-MACs fallen weg.
  public static func arpEntries(_ output: String) -> [ArpEntry] {
    var out: [ArpEntry] = []
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      guard let open = line.firstIndex(of: "("),
            let close = line[open...].firstIndex(of: ")") else { continue }
      let ip = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
      guard NetworkAddress.isIPv4(ip) else { continue }
      let rest = line[line.index(after: close)...]
      guard let atRange = rest.range(of: " at ") else { continue }
      let macToken = rest[atRange.upperBound...].split(separator: " ").first.map(String.init) ?? ""
      guard let mac = NetworkAddress.normalizeMAC(macToken) else { continue }   // "(incomplete)" fällt hier weg
      if mac == "ff:ff:ff:ff:ff:ff" || mac.hasPrefix("01:00:5e") { continue }
      if let v = NetworkAddress.ipv4Value(ip), (v >> 28) == 0xE { continue }   // Multicast 224/4
      let namePart = line[..<open].trimmingCharacters(in: .whitespaces)
      let name = (namePart.isEmpty || namePart == "?") ? nil : namePart
      var iface: String?
      if let onRange = rest.range(of: " on ") {
        iface = rest[onRange.upperBound...].split(separator: " ").first.map(String.init)
      }
      out.append(ArpEntry(ip: ip, mac: mac, name: name, interface: iface))
    }
    return out
  }

  // MARK: ping

  /// Auswertung von `ping -c 3 -t 6 <host>` (macOS). Fehlt eine Zeile, bleibt der Wert nil.
  public static func ping(host: String, output: String) -> PingResult {
    var ip: String?
    var sent = 0
    var received = 0
    var minMs: Double?
    var avgMs: Double?
    var maxMs: Double?
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("PING "), let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") {
        let candidate = String(line[line.index(after: open)..<close])
        if NetworkAddress.isIP(candidate) { ip = candidate }
      } else if line.contains("packets transmitted") {
        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for p in parts {
          let words = p.split(separator: " ")
          guard let n = words.first.flatMap({ Int($0) }) else { continue }
          if p.contains("transmitted") { sent = n }
          if p.contains("received") { received = n }
        }
      } else if line.hasPrefix("round-trip") || line.hasPrefix("rtt ") {
        guard let eq = line.range(of: " = ") else { continue }
        let numbers = line[eq.upperBound...].split(separator: " ").first?.split(separator: "/") ?? []
        let values = numbers.compactMap { Double($0) }
        if values.count >= 3 {
          minMs = values[0]; avgMs = values[1]; maxMs = values[2]
        }
      }
    }
    return PingResult(host: host, ip: ip, sent: sent, received: received, minMs: minMs, avgMs: avgMs, maxMs: maxMs)
  }

  // MARK: networkQuality -c

  /// Auswertung der JSON-Ausgabe von `networkQuality -c` (Bit/s → Mbit/s).
  public static func speed(json: String, testedAt: String) -> SpeedResult? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let down = (obj["dl_throughput"] as? NSNumber)?.doubleValue,
          let up = (obj["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
    let responsiveness = ((obj["responsiveness"] ?? obj["dl_responsiveness"]) as? NSNumber)?.intValue
    return SpeedResult(downMbps: down / 1_000_000, upMbps: up / 1_000_000,
                       responsiveness: responsiveness, testedAt: testedAt)
  }

  // MARK: dig +short

  /// Adressen und ggf. CNAME aus `dig +short A|AAAA <name>`.
  public static func digAddresses(_ output: String) -> (addresses: [String], cname: String?) {
    var addresses: [String] = []
    var cname: String?
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if NetworkAddress.isIP(line) {
        addresses.append(line)
      } else if line.hasSuffix("."), cname == nil {
        cname = String(line.dropLast())
      }
    }
    return (addresses, cname)
  }

  /// Zeilen aus `dig +short MX <name>` ("10 mail.example.com." → "10 mail.example.com").
  public static func digRecords(_ output: String) -> [String] {
    output.split(whereSeparator: \.isNewline).compactMap { raw in
      var line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return nil }
      if line.hasSuffix(".") { line.removeLast() }
      return line
    }
  }
}
