// Grenze zu macOS: alle Systemaufrufe der Netz-Werkzeuge laufen über dieses
// Protokoll. Die echte Umsetzung (`SystemNetwork`) nutzt Prozesse, getifaddrs,
// CoreWLAN, NWPathMonitor/NWConnection/NWBrowser und Sockets. Prüfungen setzen
// eine Attrappe ein.
import Foundation
import CoreWLAN
import Network

public struct ProcessOutput: Equatable, Sendable {
  public var status: Int32
  public var timedOut: Bool
  public var stdout: String
  public var stderr: String
  public init(status: Int32, timedOut: Bool = false, stdout: String = "", stderr: String = "") {
    self.status = status; self.timedOut = timedOut; self.stdout = stdout; self.stderr = stderr
  }
}

/// Eine IPv4-Adresse einer Schnittstelle.
public struct LocalAddress: Equatable, Sendable {
  public var interface: String
  public var ip: String
  public var netmask: String?
  public init(interface: String, ip: String, netmask: String?) {
    self.interface = interface; self.ip = ip; self.netmask = netmask
  }
}

/// Rohdaten des WLAN-Adapters (CoreWLAN).
public struct WifiReading: Equatable, Sendable {
  public var interfaceName: String?
  public var ssid: String?
  public var rssi: Int?
  public var noise: Int?
  public var channel: Int?
  public var band: String?
  public var txRate: Double?
  public init(interfaceName: String? = nil, ssid: String? = nil, rssi: Int? = nil, noise: Int? = nil,
              channel: Int? = nil, band: String? = nil, txRate: Double? = nil) {
    self.interfaceName = interfaceName; self.ssid = ssid; self.rssi = rssi; self.noise = noise
    self.channel = channel; self.band = band; self.txRate = txRate
  }
}

/// Ein per Bonjour gefundener Dienst; `ip` nur, wenn er sich auflösen ließ.
public struct BonjourHit: Equatable, Sendable {
  public var name: String
  public var ip: String?
  public init(name: String, ip: String?) { self.name = name; self.ip = ip }
}

public protocol NetworkSystem: Sendable {
  /// Startet ein Hilfsprogramm mit Zeitlimit (feste Argumentliste, keine Shell).
  func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput
  /// WLAN-Daten; nil ohne WLAN-Adapter.
  func wifi() -> WifiReading?
  /// IPv4-Adressen aller Schnittstellen.
  func localAddresses() -> [LocalAddress]
  /// Ein einzelner Blick auf den Netzpfad (true = erreichbar); nach `timeout` false.
  func onlineOnce(timeout: TimeInterval) async -> Bool
  /// Numerische Adressen zu einem Namen (leer, wenn nichts auflösbar).
  func resolve(_ host: String) async -> [String]
  /// Ein UDP-Paket an ip:port (Broadcast erlaubt). true, wenn vollständig gesendet.
  func sendUDP(to ip: String, port: UInt16, payload: [UInt8]) -> Bool
  /// TCP-Verbindungsaufbau mit Zeitlimit.
  func tcpOpen(_ host: String, port: Int, timeout: TimeInterval) async -> Bool
  /// Bonjour-Suche für die Diensttypen (z. B. "_smb._tcp") über `seconds`.
  func bonjourHits(types: [String], seconds: TimeInterval) async -> [BonjourHit]
  /// Rechnername zu einer IPv4-Adresse, sonst nil (nach `timeout`).
  func reverseName(_ ip: String, timeout: TimeInterval) async -> String?
}

/// Echte macOS-Umsetzung.
public struct SystemNetwork: NetworkSystem {
  public init() {}

  public func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput {
    await Blocking.run {
      do {
        let r = try ModProcess.run(path, args, timeout: timeout)
        return ProcessOutput(status: r.status, timedOut: r.timedOut, stdout: r.stdout, stderr: r.stderr)
      } catch {
        return ProcessOutput(status: -1, stderr: "Das Hilfsprogramm konnte nicht gestartet werden.")
      }
    }
  }

  public func wifi() -> WifiReading? {
    guard let iface = CWWiFiClient.shared().interface() else { return nil }
    let channel = iface.wlanChannel()
    let band: String?
    switch channel?.channelBand {
    case .band2GHz: band = "2,4 GHz"
    case .band5GHz: band = "5 GHz"
    case .band6GHz: band = "6 GHz"
    default: band = nil
    }
    let rssi = iface.rssiValue()
    let noise = iface.noiseMeasurement()
    return WifiReading(
      interfaceName: iface.interfaceName,
      ssid: iface.ssid(),
      rssi: rssi == 0 ? nil : rssi,
      noise: noise == 0 ? nil : noise,
      channel: channel.map { $0.channelNumber },
      band: band,
      txRate: iface.transmitRate() > 0 ? iface.transmitRate() : nil)
  }

  public func localAddresses() -> [LocalAddress] {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    var out: [LocalAddress] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
      let ifa = current.pointee
      if let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
         let ip = Self.ipv4String(sa) {
        let mask = ifa.ifa_netmask.flatMap { Self.ipv4String($0) }
        out.append(LocalAddress(interface: String(cString: ifa.ifa_name), ip: ip, netmask: mask))
      }
      cursor = ifa.ifa_next
    }
    return out
  }

  static func ipv4String(_ sa: UnsafePointer<sockaddr>) -> String? {
    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String? in
      var addr = p.pointee.sin_addr
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
      return String(cString: buf)
    }
  }

  static func numericString(_ sa: UnsafePointer<sockaddr>) -> String? {
    switch Int32(sa.pointee.sa_family) {
    case AF_INET:
      return ipv4String(sa)
    case AF_INET6:
      return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p -> String? in
        var addr = p.pointee.sin6_addr
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
      }
    default:
      return nil
    }
  }

  public func onlineOnce(timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let monitor = NWPathMonitor()
      let once = OneShot(continuation)
      monitor.pathUpdateHandler = { path in
        monitor.cancel()
        once.finish(path.status == .satisfied)
      }
      monitor.start(queue: DispatchQueue(label: "taby.network.path"))
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        monitor.cancel()
        once.finish(false)
      }
    }
  }

  public func resolve(_ host: String) async -> [String] {
    await Blocking.run {
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var result: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [String]() }
      defer { freeaddrinfo(head) }
      var out: [String] = []
      var node: UnsafeMutablePointer<addrinfo>? = head
      while let n = node {
        if let sa = n.pointee.ai_addr, let s = Self.numericString(sa), !out.contains(s) {
          out.append(s)
        }
        node = n.pointee.ai_next
      }
      return out
    }
  }

  public func sendUDP(to ip: String, port: UInt16, payload: [UInt8]) -> Bool {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
    let sent = payload.withUnsafeBytes { buf -> Int in
      withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          sendto(fd, buf.baseAddress, buf.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    return sent == payload.count
  }

  public func tcpOpen(_ host: String, port: Int, timeout: TimeInterval) async -> Bool {
    guard (1...65535).contains(port), let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = OneShot(continuation)
      let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          connection.cancel(); once.finish(true)
        case .failed, .waiting:
          connection.cancel(); once.finish(false)
        default:
          break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        connection.cancel()
        once.finish(false)
      }
    }
  }

  public func bonjourHits(types: [String], seconds: TimeInterval) async -> [BonjourHit] {
    let collector = BonjourCollector()
    let browsers = types.map { type -> NWBrowser in
      let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
      browser.browseResultsChangedHandler = { results, _ in
        collector.update(key: type, results.map { $0.endpoint })
      }
      return browser
    }
    browsers.forEach { $0.start(queue: .global()) }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    browsers.forEach { $0.cancel() }

    let services = collector.services()
    return await withTaskGroup(of: BonjourHit.self) { group in
      for (name, endpoint) in services {
        group.addTask { BonjourHit(name: name, ip: await Self.resolveEndpoint(endpoint, timeout: 1)) }
      }
      var out: [BonjourHit] = []
      for await hit in group { out.append(hit) }
      return out.sorted { $0.name < $1.name }
    }
  }

  /// Ermittelt die IP eines Bonjour-Dienstes über eine kurze TCP-Verbindung.
  static func resolveEndpoint(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let once = OneShot(continuation)
      let connection = NWConnection(to: endpoint, using: .tcp)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          var ip: String?
          if let remote = connection.currentPath?.remoteEndpoint, case .hostPort(let host, _) = remote {
            ip = "\(host)".components(separatedBy: "%").first
          }
          connection.cancel()
          once.finish(ip.flatMap { NetworkAddress.isIPv4($0) ? $0 : nil })
        case .failed, .waiting:
          connection.cancel(); once.finish(nil)
        default:
          break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        connection.cancel()
        once.finish(nil)
      }
    }
  }

  public func reverseName(_ ip: String, timeout: TimeInterval) async -> String? {
    await Self.boundedLookup(timeout: timeout) { Self.blockingReverseName(ip) }
  }

  /// Liefert `lookup` oder nach `timeout` nil. Früher eine TaskGroup: die wartet beim Verlassen
  /// auf alle Kinder, das Zeitlimit griff nie. Hängt `lookup`, bleibt nur sein GCD-Thread hängen.
  static func boundedLookup(timeout: TimeInterval, _ lookup: @escaping () -> String?) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let once = OneShot(continuation)
      DispatchQueue.global(qos: .utility).async { once.finish(lookup()) }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
    }
  }

  static func blockingReverseName(_ ip: String) -> String? {
    guard NetworkAddress.isIPv4(ip) else { return nil }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rc = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        getnameinfo(sp, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0,
                    NI_NAMEREQD)
      }
    }
    guard rc == 0 else { return nil }
    var name = String(cString: host)
    if name.hasSuffix(".") { name.removeLast() }
    return name.isEmpty || name == ip ? nil : name
  }
}

/// Gibt ein Ergebnis genau einmal an eine Continuation zurück.
final class OneShot<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Never>?

  init(_ continuation: CheckedContinuation<T, Never>) {
    self.continuation = continuation
  }

  func finish(_ value: T) {
    lock.lock()
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(returning: value)
  }
}

/// Sammelt Bonjour-Ergebnisse aus mehreren Suchen (thread-sicher).
final class BonjourCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var endpointsByType: [String: [NWEndpoint]] = [:]

  func update(key: String, _ new: [NWEndpoint]) {
    lock.lock(); endpointsByType[key] = new; lock.unlock()
  }

  /// Dienstname und Endpunkt, je Name einmal.
  func services() -> [(String, NWEndpoint)] {
    lock.lock(); let current = endpointsByType.keys.sorted().flatMap { endpointsByType[$0] ?? [] }; lock.unlock()
    var seen = Set<String>()
    var out: [(String, NWEndpoint)] = []
    for ep in current {
      if case .service(let name, _, _, _) = ep, !seen.contains(name) {
        seen.insert(name)
        out.append((name, ep))
      }
    }
    return out
  }
}
