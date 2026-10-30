// Geräte-Scan im eigenen Teilnetz. Ablauf: UDP-Pakete an alle Hosts füllen die
// ARP-Tabelle, danach wird `arp -an` ausgewertet. Bonjour und Rückwärts-Namen
// liefern Namen (best effort). Insgesamt ca. 12 s; nur für private Netze.
import Foundation

public struct ScannedHost: Equatable, Sendable {
  public var ip: String
  public var mac: String?
  public var hostname: String?
  public init(ip: String, mac: String? = nil, hostname: String? = nil) {
    self.ip = ip; self.mac = mac; self.hostname = hostname
  }
}

public final class NetworkScanner: Sendable {
  /// Gesamtzeit des Scans in Sekunden (Obergrenze aus den Teilschritten: ~1,2 s Sammeln,
  /// ~5 s für Bonjour mit Auflösung, ~1 s für Namen, ~5 s ARP).
  public static let timeCap: TimeInterval = 12
  static let bonjourTypes = ["_device-info._tcp", "_airplay._tcp", "_smb._tcp", "_http._tcp"]

  let system: NetworkSystem

  public init(system: NetworkSystem = SystemNetwork()) {
    self.system = system
  }

  /// Hosts des eigenen Teilnetzes mit Namen und MAC. Leer, wenn das Netz nicht privat ist
  /// oder keine IP bekannt ist.
  public func scan(info: NetworkInfo) async -> [ScannedHost] {
    guard let localIP = info.localIP, NetworkAddress.isPrivate(localIP),
          let mask = Self.mask(fromSubnet: info.subnet) else { return [] }
    let hosts = NetworkAddress.subnetHosts(ip: localIP, mask: mask)
    guard !hosts.isEmpty else { return [] }

    // 1. ARP-Tabelle füllen: ein UDP-Paket an Port 9 je Host.
    for ip in hosts {
      _ = system.sendUDP(to: ip, port: 9, payload: [0])
    }
    // 2. Bonjour läuft parallel zur ARP-Antwortzeit.
    async let bonjour = system.bonjourHits(types: Self.bonjourTypes, seconds: 3)
    try? await Task.sleep(nanoseconds: 1_200_000_000)

    let arpOut = await system.run("/usr/sbin/arp", ["-an"], timeout: 5)
    let arp = NetworkParsers.arpEntries(arpOut.stdout)
    let bonjourHits = await bonjour

    let hostSet = Set(hosts)
    var byIP: [String: ScannedHost] = [:]
    for entry in arp where hostSet.contains(entry.ip) || entry.ip == localIP || entry.ip == info.router {
      byIP[entry.ip] = ScannedHost(ip: entry.ip, mac: entry.mac, hostname: entry.name)
    }
    if let router = info.router, byIP[router] == nil {
      byIP[router] = ScannedHost(ip: router)
    }
    if byIP[localIP] == nil {
      byIP[localIP] = ScannedHost(ip: localIP)
    }

    // Namen aus Bonjour (über die aufgelöste IP) ergänzen.
    for hit in bonjourHits {
      if let ip = hit.ip, var host = byIP[ip], host.hostname == nil {
        host.hostname = hit.name
        byIP[ip] = host
      }
    }

    // Rückwärts-Namen für Geräte ohne Namen (parallel, je höchstens 0,8 s).
    let missing = byIP.values.filter { $0.hostname == nil }.map(\.ip)
    let names = await withTaskGroup(of: (String, String?).self) { group -> [String: String] in
      for ip in missing {
        group.addTask { (ip, await self.system.reverseName(ip, timeout: 0.8)) }
      }
      var out: [String: String] = [:]
      for await (ip, name) in group { if let name { out[ip] = name } }
      return out
    }
    for (ip, name) in names {
      if var host = byIP[ip], host.hostname == nil {
        host.hostname = name
        byIP[ip] = host
      }
    }

    return byIP.values.sorted { (NetworkAddress.ipv4Value($0.ip) ?? 0) < (NetworkAddress.ipv4Value($1.ip) ?? 0) }
  }

  /// "192.168.178.0/24" → "255.255.255.0".
  static func mask(fromSubnet subnet: String?) -> String? {
    guard let subnet, let slash = subnet.firstIndex(of: "/"),
          let prefix = Int(subnet[subnet.index(after: slash)...]) else { return nil }
    return NetworkAddress.mask(forPrefix: prefix)
  }
}
