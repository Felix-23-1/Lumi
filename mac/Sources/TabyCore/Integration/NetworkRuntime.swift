// Paket 6 im Integrator: Netzwerk-Werkzeuge (optional). Regeln in
// Contracts/Network.swift: nichts läuft, solange `networkToolsEnabled` aus ist;
// Port-Check nur im eigenen Netz; ins Internet nur auf Knopfdruck.
import Foundation

@MainActor
final class NetworkRuntime {
  let system: NetworkSystem
  var info: NetworkInfo?
  var lastScan: String?
  var scanning = false
  var lastSpeed: SpeedResult?
  var watch = NetworkWatch()
  var lastWatch: Date?
  var lastWatchScan: Date?
  // Paket 7:
  var lastScan2: ScanReport?
  var connections: [Connection] = []
  var runningCapture: RunningCapture?
  var capturePcapPath: String?
  var captureState: CaptureState?
  var recentPackets: [CapturePacket] = []
  var captureTask: Task<Void, Never>?
  init(system: NetworkSystem) { self.system = system }
}

extension CoreServices {
  /// Wächter: Online-Prüfung jede Minute, Geräte-Scan alle 10 Minuten.
  static let networkWatchInterval: TimeInterval = 60
  static let networkWatchScanInterval: TimeInterval = 10 * 60

  private var networkOn: Bool { settings.networkToolsEnabled }
  private func networkOff<T>() -> ToolResult<T> {
    .failure(code: "NETWORK_OFF", error: "Netzwerk-Werkzeuge sind ausgeschaltet (Einstellungen → Netzwerk, mit „Erweitert anzeigen“).")
  }
  private var nowString: String { LocalTime.format(clock.now()) }

  func networkState() -> NetworkState? {
    guard networkOn else { return nil }
    let devices = (try? store.networkDevices.list(info: network.info)) ?? []
    return NetworkState(info: network.info, devices: devices, lastScan: network.lastScan,
                        scanning: network.scanning, lastSpeed: network.lastSpeed,
                        capturing: network.captureState?.running == true, capture: network.captureState,
                        recentPackets: network.recentPackets, connections: network.connections,
                        ownServers: (try? store.ownServers.list()) ?? [], lastScan2: network.lastScan2)
  }

  public func refreshNetworkInfo() async -> ToolResult<NetworkInfo> {
    guard networkOn else { return networkOff() }
    let info = await WifiInfoProvider(system: network.system).current()
    network.info = info
    emit(.stateChanged)
    return .ok(info)
  }

  public func scanNetwork() async -> ToolResult<[NetworkDevice]> {
    guard networkOn else { return networkOff() }
    guard !network.scanning else { return .failure(code: "BUSY", error: "Es läuft schon eine Suche.") }
    network.scanning = true
    emit(.stateChanged)
    defer { network.scanning = false; emit(.stateChanged) }
    let info = await WifiInfoProvider(system: network.system).current()
    network.info = info
    guard let ip = info.localIP, NetworkAddress.isPrivate(ip) else {
      return .failure(code: "NETWORK_NO_LAN", error: "Kein eigenes Netz gefunden (keine private IP-Adresse).")
    }
    let hosts = await NetworkScanner(system: network.system).scan(info: info)
    do {
      let merged = try store.networkDevices.merge(scanned: hosts, info: info, now: nowString)
      network.lastScan = nowString
      return .ok(merged.all)
    } catch {
      return .failure(code: "ERROR", error: "Geräte konnten nicht gespeichert werden.")
    }
  }

  public func updateNetworkDevice(_ id: String, name: String?, known: Bool?) async -> ToolResult<NetworkDevice> {
    guard networkOn else { return networkOff() }
    guard let d = try? store.networkDevices.update(id: id, name: name, known: known, info: network.info) else {
      return .failure(code: "NOT_FOUND", error: "Gerät nicht gefunden.")
    }
    emit(.stateChanged)
    return .ok(d)
  }

  public func ping(_ host: String) async -> ToolResult<PingResult> {
    guard networkOn else { return networkOff() }
    return await Pinger.ping(host: host, system: network.system)
  }

  public func checkPorts(_ host: String, ports: [Int]?) async -> ToolResult<[PortResult]> {
    guard networkOn else { return networkOff() }
    return await PortChecker.check(host: host, ports: ports, system: network.system)
  }

  public func speedTest() async -> ToolResult<SpeedResult> {
    guard networkOn else { return networkOff() }
    let r = await SpeedTester.run(clock: clock, system: network.system)
    if case .ok(let speed) = r { network.lastSpeed = speed; emit(.stateChanged) }
    return r
  }

  public func wakeOnLan(mac: String) async -> ToolResult<Empty> {
    guard networkOn else { return networkOff() }
    return WakeOnLan.send(mac: mac, broadcast: Self.broadcast(network.info) ?? "255.255.255.255",
                          system: network.system)
  }

  public func dnsLookup(_ name: String) async -> ToolResult<DnsResult> {
    guard networkOn else { return networkOff() }
    return await DnsLookup.lookup(name: name, system: network.system)
  }

  public func publicIP() async -> ToolResult<String> {
    guard networkOn else { return networkOff() }
    return await PublicIP.fetch(session: urlSession)
  }

  /// Broadcast-Adresse des eigenen /24 (z. B. 192.168.178.255), sonst nil.
  static func broadcast(_ info: NetworkInfo?) -> String? {
    guard let ip = info?.localIP, NetworkAddress.isIPv4(ip), NetworkAddress.isPrivate(ip) else { return nil }
    let parts = ip.split(separator: ".")
    return parts.count == 4 ? parts.prefix(3).joined(separator: ".") + ".255" : nil
  }

  // MARK: Wächter

  func networkWatchTick() async {
    let s = settings
    guard s.networkToolsEnabled, s.networkWatch else { return }
    let now = clock.now()
    if let last = network.lastWatch, now.timeIntervalSince(last) < Self.networkWatchInterval { return }
    network.lastWatch = now
    let online = await network.system.onlineOnce(timeout: 2)
    var newUnknown: [NetworkDevice] = []
    var scanned = false
    if online, network.lastWatchScan.map({ now.timeIntervalSince($0) >= Self.networkWatchScanInterval }) ?? true {
      network.lastWatchScan = now
      scanned = true
      let info = await WifiInfoProvider(system: network.system).current()
      network.info = info
      if let ip = info.localIP, NetworkAddress.isPrivate(ip) {
        let hosts = await NetworkScanner(system: network.system).scan(info: info)
        if let merged = try? store.networkDevices.merge(scanned: hosts, info: info, now: nowString) {
          newUnknown = merged.new
          network.lastScan = nowString
        }
      }
    }
    let notes = network.watch.evaluate(online: online, newUnknown: newUnknown)
    for n in notes { emit(.flash(n)) }
    // Sonst baute jede Minute ohne Neuigkeit den ganzen Zustand neu (Kalender, SQLite, UI).
    if scanned || !notes.isEmpty { emit(.stateChanged) }
  }
}
