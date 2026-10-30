// Werkzeuge auf Knopfdruck: Ping, Port-Check, Speedtest, Wake-on-LAN, DNS-Abfrage
// und öffentliche IP. Eingaben werden vor jedem Systemaufruf geprüft; Prozesse
// laufen mit fester Argumentliste (keine Shell).
import Foundation

// MARK: - Ping

public enum Pinger {
  public static func ping(host: String, system: NetworkSystem = SystemNetwork()) async -> ToolResult<PingResult> {
    let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
    // Nur IPv4 oder DNS-Name (kein IPv6, keine Optionen).
    guard NetworkAddress.isIPv4(target) || NetworkAddress.isValidDNSName(target) else {
      return .failure(code: "NETWORK_BAD_HOST", error: "Ungültiger Rechnername oder ungültige IP-Adresse.")
    }
    let out = await system.run("/sbin/ping", ["-c", "3", "-t", "6", target], timeout: 10)
    if out.timedOut {
      return .failure(code: "NETWORK_TIMEOUT", error: "Der Ping hat zu lange gedauert.")
    }
    let result = NetworkParsers.ping(host: target, output: out.stdout)
    if result.sent == 0 {
      return .failure(code: "NETWORK_UNKNOWN_HOST", error: "„\(target)“ wurde nicht gefunden.")
    }
    return .ok(result)
  }
}

// MARK: - Port-Check

public enum PortChecker {
  public static let defaultPorts: [(port: Int, service: String)] = [
    (22, "SSH"), (53, "DNS"), (80, "HTTP"), (139, "NetBIOS"), (443, "HTTPS"), (445, "SMB"),
    (548, "AFP"), (631, "Drucker (IPP)"), (3389, "RDP"), (5000, "Synology/UPnP"), (5900, "VNC"),
    (8080, "HTTP-Alt"), (9100, "Drucker"),
  ]
  public static let maxPorts = 20
  public static let refusal = "Port-Check nur für Geräte im eigenen Netz."

  static func serviceName(_ port: Int) -> String {
    defaultPorts.first { $0.port == port }?.service ?? "unbekannt"
  }

  /// Nur eigenes Netz: IP oder Name, der privat ist oder auf eine private Adresse zeigt.
  public static func isAllowed(host: String, system: NetworkSystem) async -> Bool {
    if NetworkAddress.isIP(host) { return NetworkAddress.isPrivate(host) }
    if NetworkAddress.isPrivate(host) { return true }   // "*.local", "localhost"
    let resolved = await system.resolve(host)
    return !resolved.isEmpty && resolved.allSatisfy { NetworkAddress.isPrivate($0) }
  }

  public static func check(host: String, ports: [Int]? = nil,
                           system: NetworkSystem = SystemNetwork()) async -> ToolResult<[PortResult]> {
    let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard NetworkAddress.isValidHost(target) else {
      return .failure(code: "NETWORK_BAD_HOST", error: "Ungültiger Rechnername oder ungültige IP-Adresse.")
    }
    guard await isAllowed(host: target, system: system) else {
      return .failure(code: "PORT_PUBLIC_HOST", error: refusal)
    }
    let list = ports ?? defaultPorts.map(\.port)
    guard !list.isEmpty, list.count <= maxPorts else {
      return .failure(code: "NETWORK_BAD_PORTS", error: "Höchstens \(maxPorts) Ports pro Prüfung.")
    }
    guard list.allSatisfy({ (1...65535).contains($0) }) else {
      return .failure(code: "NETWORK_BAD_PORTS", error: "Ports müssen zwischen 1 und 65535 liegen.")
    }
    let results = await withTaskGroup(of: (Int, Bool).self) { group -> [Int: Bool] in
      for port in list {
        group.addTask { (port, await system.tcpOpen(target, port: port, timeout: 1.5)) }
      }
      var out: [Int: Bool] = [:]
      for await (port, open) in group { out[port] = open }
      return out
    }
    // Reihenfolge wie angefragt, ohne Doppelte.
    var seen = Set<Int>()
    let ordered = list.filter { seen.insert($0).inserted }
    return .ok(ordered.map { PortResult(port: $0, open: results[$0] ?? false, service: serviceName($0)) })
  }
}

// MARK: - Speedtest

public enum SpeedTester {
  public static let timeout: TimeInterval = 60

  public static func run(clock: Clock = SystemClock(), system: NetworkSystem = SystemNetwork()) async -> ToolResult<SpeedResult> {
    let out = await system.run("/usr/bin/networkQuality", ["-c"], timeout: timeout)
    if out.timedOut {
      return .failure(code: "NETWORK_TIMEOUT", error: "Der Speedtest hat zu lange gedauert und wurde abgebrochen.")
    }
    guard out.status == 0, let result = NetworkParsers.speed(json: out.stdout,
                                                             testedAt: LocalTime.format(clock.now())) else {
      return .failure(code: "NETWORK_FAILED", error: "Der Speedtest konnte nicht ausgewertet werden.")
    }
    return .ok(result)
  }
}

// MARK: - Wake-on-LAN

public enum WakeOnLan {
  /// Magic Packet: 6 × 0xFF, danach 16 × die MAC (zusammen 102 Byte).
  public static func magicPacket(mac: String) -> [UInt8]? {
    guard let bytes = NetworkAddress.macBytes(mac), bytes.count == 6,
          bytes.contains(where: { $0 != 0 }) else { return nil }
    return [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }
  }

  public static func send(mac: String, broadcast: String = "255.255.255.255",
                          system: NetworkSystem = SystemNetwork()) -> ToolResult<Empty> {
    guard let packet = magicPacket(mac: mac) else {
      return .failure(code: "NETWORK_INVALID_MAC", error: "Ungültige MAC-Adresse.")
    }
    guard NetworkAddress.isIPv4(broadcast) else {
      return .failure(code: "NETWORK_BAD_HOST", error: "Ungültige Broadcast-Adresse.")
    }
    var sent = false
    for target in Set(["255.255.255.255", broadcast]) {
      if system.sendUDP(to: target, port: 9, payload: packet) { sent = true }
    }
    return sent
      ? .ok(Empty())
      : .failure(code: "NETWORK_FAILED", error: "Das Aufweck-Paket konnte nicht gesendet werden.")
  }
}

// MARK: - DNS

public enum DnsLookup {
  public static func lookup(name: String, system: NetworkSystem = SystemNetwork()) async -> ToolResult<DnsResult> {
    let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // Strikt: nur Buchstaben, Ziffern, Punkte, Bindestriche. Nichts davon erreicht den Prozess ungeprüft.
    guard NetworkAddress.isValidDNSName(target) else {
      return .failure(code: "NETWORK_BAD_NAME", error: "Ungültiger Name. Erlaubt sind Buchstaben, Ziffern, Punkte und Bindestriche.")
    }
    async let a = system.run("/usr/bin/dig", ["+short", "A", target], timeout: 8)
    async let aaaa = system.run("/usr/bin/dig", ["+short", "AAAA", target], timeout: 8)
    async let mx = system.run("/usr/bin/dig", ["+short", "MX", target], timeout: 8)
    let aOut = await a, aaaaOut = await aaaa, mxOut = await mx
    if aOut.timedOut || aaaaOut.timedOut || mxOut.timedOut {
      return .failure(code: "NETWORK_TIMEOUT", error: "Die DNS-Abfrage hat zu lange gedauert.")
    }
    let v4 = NetworkParsers.digAddresses(aOut.stdout)
    let v6 = NetworkParsers.digAddresses(aaaaOut.stdout)
    let result = DnsResult(name: target, a: v4.addresses, aaaa: v6.addresses,
                           mx: NetworkParsers.digRecords(mxOut.stdout), cname: v4.cname ?? v6.cname)
    return .ok(result)
  }
}

// MARK: - Öffentliche IP

public enum PublicIP {
  public static let url = URL(string: "https://api.ipify.org")!

  /// Holt die öffentliche IP (5 s Zeitlimit). Nur gültige IP-Texte werden übernommen.
  public static func fetch(session: URLSession = .shared) async -> ToolResult<String> {
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "GET"
    do {
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        return .failure(code: "NETWORK_FAILED", error: "Die öffentliche IP konnte nicht abgefragt werden.")
      }
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      guard NetworkAddress.isIP(text), text.count <= 45 else {
        return .failure(code: "NETWORK_FAILED", error: "Die Antwort ist keine gültige IP-Adresse.")
      }
      return .ok(text)
    } catch {
      return .failure(code: "NETWORK_FAILED", error: "Die öffentliche IP konnte nicht abgefragt werden.")
    }
  }
}
