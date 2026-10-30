// VERTRAG (nur Orchestrator ändert). Paket 6: Netzwerk-Werkzeuge (optional,
// standardmäßig aus; erst eingeschaltet erscheint der Reiter).
//
// Regeln:
// - Nichts läuft, solange `networkToolsEnabled` aus ist.
// - Port-Check und Geräte-Scan nur im eigenen Netz (private Adressen:
//   10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, *.local). Kein Werkzeug
//   gegen fremde Rechner.
// - Ins Internet nur auf Knopfdruck: Speedtest (Apples networkQuality),
//   öffentliche IP (ipify), DNS-Abfrage. Der Wächter prüft nur „online?“.
// - Gerätedaten (MAC, Name, Hersteller) bleiben lokal in SQLite.
import Foundation

public struct NetworkInfo: Codable, Equatable, Sendable {
  /// WLAN-Name; nil, wenn macOS ihn ohne Ortungsdienste nicht verrät oder per Kabel.
  public var ssid: String?
  /// Erklärung, warum `ssid` fehlt (z. B. "Ortungsdienste für Lumi erlauben, um den WLAN-Namen zu sehen").
  public var ssidHint: String?
  /// Signal in dBm (z. B. -54) und Rauschen; nil ohne WLAN.
  public var rssi: Int?
  public var noise: Int?
  public var channel: Int?
  /// "2,4 GHz", "5 GHz", "6 GHz"
  public var band: String?
  /// Übertragungsrate in Mbit/s.
  public var txRate: Double?
  /// "en0" usw., "WLAN" oder "Ethernet".
  public var interfaceName: String
  public var localIP: String?
  /// z. B. "192.168.178.0/24"
  public var subnet: String?
  public var router: String?
  public var dns: [String]
  /// Internet erreichbar (laut System-Pfad).
  public var online: Bool
  public init(ssid: String? = nil, ssidHint: String? = nil, rssi: Int? = nil, noise: Int? = nil, channel: Int? = nil,
              band: String? = nil, txRate: Double? = nil, interfaceName: String = "", localIP: String? = nil,
              subnet: String? = nil, router: String? = nil, dns: [String] = [], online: Bool = false) {
    self.ssid = ssid; self.ssidHint = ssidHint; self.rssi = rssi; self.noise = noise; self.channel = channel
    self.band = band; self.txRate = txRate; self.interfaceName = interfaceName; self.localIP = localIP
    self.subnet = subnet; self.router = router; self.dns = dns; self.online = online
  }
}

public struct NetworkDevice: Codable, Equatable, Identifiable, Sendable {
  /// MAC-Adresse (klein, mit Doppelpunkten), sonst IP.
  public var id: String
  public var ip: String
  public var mac: String?
  /// Eigener Name (vom Nutzer) oder Bonjour-/Hostname.
  public var name: String?
  /// Hersteller aus der MAC (kleine eingebaute Liste), z. B. "Apple", "AVM".
  public var vendor: String?
  public var isRouter: Bool
  public var isThisMac: Bool
  /// Vom Nutzer als bekannt markiert (Wächter meldet nur unbekannte).
  public var known: Bool
  public var firstSeen: String
  public var lastSeen: String
  /// Im letzten Scan geantwortet (erreichbar) – sonst zuletzt gesehen, aber gerade nicht an/da.
  public var online: Bool
  public init(id: String, ip: String, mac: String? = nil, name: String? = nil, vendor: String? = nil,
              isRouter: Bool = false, isThisMac: Bool = false, known: Bool = false, firstSeen: String,
              lastSeen: String, online: Bool = true) {
    self.id = id; self.ip = ip; self.mac = mac; self.name = name; self.vendor = vendor; self.isRouter = isRouter
    self.isThisMac = isThisMac; self.known = known; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    self.online = online
  }
}

public struct PingResult: Codable, Equatable, Sendable {
  public var host: String
  public var ip: String?
  public var sent: Int
  public var received: Int
  public var minMs: Double?
  public var avgMs: Double?
  public var maxMs: Double?
  public init(host: String, ip: String? = nil, sent: Int, received: Int, minMs: Double? = nil, avgMs: Double? = nil,
              maxMs: Double? = nil) {
    self.host = host; self.ip = ip; self.sent = sent; self.received = received
    self.minMs = minMs; self.avgMs = avgMs; self.maxMs = maxMs
  }
}

public struct PortResult: Codable, Equatable, Sendable {
  public var port: Int
  public var open: Bool
  /// "SSH", "HTTP", "SMB", …
  public var service: String
  public init(port: Int, open: Bool, service: String) { self.port = port; self.open = open; self.service = service }
}

public struct SpeedResult: Codable, Equatable, Sendable {
  public var downMbps: Double
  public var upMbps: Double
  /// Reaktionsfähigkeit (RPM) laut networkQuality, falls geliefert.
  public var responsiveness: Int?
  public var testedAt: String
  public init(downMbps: Double, upMbps: Double, responsiveness: Int? = nil, testedAt: String) {
    self.downMbps = downMbps; self.upMbps = upMbps; self.responsiveness = responsiveness; self.testedAt = testedAt
  }
}

public struct DnsResult: Codable, Equatable, Sendable {
  public var name: String
  public var a: [String]
  public var aaaa: [String]
  public var mx: [String]
  public var cname: String?
  public init(name: String, a: [String] = [], aaaa: [String] = [], mx: [String] = [], cname: String? = nil) {
    self.name = name; self.a = a; self.aaaa = aaaa; self.mx = mx; self.cname = cname
  }
}

/// Netzwerk-Stand für die Oberfläche (nil im AppState = Werkzeuge aus).
public struct NetworkState: Codable, Equatable, Sendable {
  public var info: NetworkInfo?
  public var devices: [NetworkDevice]
  public var lastScan: String?
  public var scanning: Bool
  public var lastSpeed: SpeedResult?
  // Paket 7:
  public var capturing: Bool
  public var capture: CaptureState?
  public var recentPackets: [CapturePacket]
  public var connections: [Connection]
  public var ownServers: [OwnServer]
  public var lastScan2: ScanReport?
  public init(info: NetworkInfo? = nil, devices: [NetworkDevice] = [], lastScan: String? = nil, scanning: Bool = false,
              lastSpeed: SpeedResult? = nil, capturing: Bool = false, capture: CaptureState? = nil,
              recentPackets: [CapturePacket] = [], connections: [Connection] = [], ownServers: [OwnServer] = [],
              lastScan2: ScanReport? = nil) {
    self.info = info; self.devices = devices; self.lastScan = lastScan; self.scanning = scanning
    self.lastSpeed = lastSpeed
    self.capturing = capturing; self.capture = capture; self.recentPackets = recentPackets
    self.connections = connections; self.ownServers = ownServers; self.lastScan2 = lastScan2
  }
}
