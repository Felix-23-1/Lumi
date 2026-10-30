// Reine Netzwerk-Hilfen (ohne Systemaufrufe): private Adressen, Teilnetze,
// MAC-Form. Alles hier ist deterministisch und wird in den Prüfungen direkt
// getestet.
import Foundation

public enum NetworkAddress {
  // MARK: Bytes und Zahlen

  static func ipv4Bytes(_ s: String) -> [UInt8]? {
    var addr = in_addr()
    guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: addr.s_addr) { Array($0) }
  }

  static func ipv6Bytes(_ s: String) -> [UInt8]? {
    var addr = in6_addr()
    guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: addr) { Array($0) }
  }

  /// Entfernt eine IPv6-Zone ("fe80::1%en0" → "fe80::1").
  static func stripZone(_ s: String) -> String {
    String(s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
  }

  /// IPv4 als 32-Bit-Zahl (Netzreihenfolge egal, nur Vergleich/Rechnen).
  public static func ipv4Value(_ s: String) -> UInt32? {
    guard let b = ipv4Bytes(s) else { return nil }
    return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
  }

  static func dotted(_ v: UInt32) -> String {
    "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
  }

  // MARK: IP-Adressen

  public static func isIPv4(_ s: String) -> Bool { ipv4Bytes(s) != nil }

  public static func isIPv6(_ s: String) -> Bool { ipv6Bytes(stripZone(s)) != nil }

  public static func isIP(_ s: String) -> Bool { isIPv4(s) || isIPv6(s) }

  private static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
    switch (b[0], b[1]) {
    case (10, _): return true
    case (172, 16...31): return true
    case (192, 168): return true
    case (169, 254): return true
    case (127, _): return true
    default: return false
    }
  }

  /// Privat im Sinne der Netz-Werkzeuge: 10/8, 172.16/12, 192.168/16, 169.254/16,
  /// 127/8, IPv6 fe80::/10, ::1, fc00::/7, sowie Namen auf ".local" und "localhost".
  /// Öffentliche Namen (z. B. "example.com") ergeben false; ihre Auflösung prüft der Aufrufer.
  public static func isPrivate(_ host: String) -> Bool {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if h.hasSuffix(".") { h.removeLast() }
    guard !h.isEmpty else { return false }
    if let v4 = ipv4Bytes(h) { return isPrivateIPv4(v4) }
    if let v6 = ipv6Bytes(stripZone(h)) {
      if v6.prefix(15).allSatisfy({ $0 == 0 }) && v6[15] == 1 { return true }          // ::1
      if v6[0] == 0xfe && (v6[1] & 0xc0) == 0x80 { return true }                       // fe80::/10
      if (v6[0] & 0xfe) == 0xfc { return true }                                        // fc00::/7
      if v6.prefix(10).allSatisfy({ $0 == 0 }) && v6[10] == 0xff && v6[11] == 0xff {   // ::ffff:a.b.c.d
        return isPrivateIPv4(Array(v6[12...15]))
      }
      return false
    }
    return h == "localhost" || h.hasSuffix(".local")
  }

  // MARK: Teilnetze

  /// Prefixlänge aus einer Netzmaske ("255.255.255.0" → 24); nil bei ungültiger (nicht zusammenhängender) Maske.
  public static func prefixLength(mask: String) -> Int? {
    guard let m = ipv4Value(mask) else { return nil }
    let inverted = ~m
    guard (inverted & (inverted &+ 1)) == 0 else { return nil }
    return m.nonzeroBitCount
  }

  /// Netzmaske zur Prefixlänge (24 → "255.255.255.0").
  public static func mask(forPrefix prefix: Int) -> String? {
    guard (0...32).contains(prefix) else { return nil }
    return dotted(UInt32.max << UInt32(32 - prefix))
  }

  /// "192.168.178.45" + "255.255.255.0" → "192.168.178.0/24".
  public static func cidr(ip: String, mask: String) -> String? {
    guard let v = ipv4Value(ip), let p = prefixLength(mask: mask) else { return nil }
    let net = v & (UInt32.max << UInt32(32 - p))
    return "\(dotted(net))/\(p)"
  }

  /// Host-Adressen des Teilnetzes der IP. Bei /24 oder kleiner alle Hosts (ohne Netz- und
  /// Broadcast-Adresse, höchstens 254). Größere Netze: nur das /24 um die IP.
  public static func subnetHosts(ip: String, mask: String) -> [String] {
    guard let v = ipv4Value(ip), var prefix = prefixLength(mask: mask), prefix <= 32 else { return [] }
    if prefix < 24 { prefix = 24 }
    let net = v & (UInt32.max << UInt32(32 - prefix))
    let size = UInt32(1) << UInt32(32 - prefix)
    guard size >= 4 else { return [] }
    let first = net + 1
    let last = net + size - 2
    return (first...last).prefix(254).map(dotted)
  }

  // MARK: MAC-Adressen

  /// Normalisiert eine MAC ("0:1b:2c:3d:4e:5f" → "00:1b:2c:3d:4e:5f"); nil bei ungültiger Form.
  public static func normalizeMAC(_ mac: String) -> String? {
    let parts = mac.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .split(whereSeparator: { $0 == ":" || $0 == "-" }).map(String.init)
    guard parts.count == 6 else { return nil }
    var out: [String] = []
    for p in parts {
      guard (1...2).contains(p.count), p.allSatisfy(\.isHexDigit) else { return nil }
      out.append(p.count == 1 ? "0" + p : p)
    }
    return out.joined(separator: ":")
  }

  /// Bytes einer normalisierbaren MAC.
  static func macBytes(_ mac: String) -> [UInt8]? {
    guard let n = normalizeMAC(mac) else { return nil }
    return n.split(separator: ":").compactMap { UInt8($0, radix: 16) }
  }

  // MARK: Namen

  /// Prüft einen DNS-Namen strikt (Buchstaben, Ziffern, Punkte, Bindestriche). Verhindert alles,
  /// was als Befehlsteil missverstanden werden könnte.
  public static func isValidDNSName(_ name: String) -> Bool {
    var n = name
    if n.hasSuffix(".") { n.removeLast() }
    guard !n.isEmpty, n.count <= 253 else { return false }
    for label in n.split(separator: ".", omittingEmptySubsequences: false) {
      guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
      guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
    }
    return true
  }

  /// Ziel für Ping/Port-Check: IP-Adresse oder DNS-Name.
  public static func isValidHost(_ host: String) -> Bool {
    isIP(host) || isValidDNSName(host)
  }
}
