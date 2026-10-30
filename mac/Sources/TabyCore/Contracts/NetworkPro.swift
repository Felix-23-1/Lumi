// VERTRAG (nur Orchestrator ändert). Paket 7: Profi-Netzwerkwerkzeuge
// (nmap-artiger Scan, Paket-Mitschnitt, offene Verbindungen). Teil des
// optionalen Netzwerk-Moduls (`networkToolsEnabled`).
//
// Regeln (docs/decisions/0008-network-pro.md):
// - Scan und Port-Dienste nur gegen das eigene Netz (private Adressen) ODER
//   gegen Ziele, die der Nutzer ausdrücklich als „eigene Server“ einträgt und
//   dabei bestätigt, dass er sie prüfen darf. Nie gegen beliebige Hosts.
// - Paket-Mitschnitt braucht Admin-Rechte: Lumi fragt pro Mitschnitt mit dem
//   normalen macOS-Dialog (AppleScript „with administrator privileges“); keine
//   dauerhafte Rechte-Erweiterung.
// - „Verbindungen“ listet nur, womit DIESER Mac gerade spricht (lsof), es wird
//   nichts gescannt.
import Foundation

/// Server, den der Nutzer selbst betreibt/prüfen darf (erlaubt Scan außerhalb des Heimnetzes).
public struct OwnServer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// Hostname oder IP.
  public var host: String
  public var label: String
  /// Nutzer hat bestätigt, dass er den Server prüfen darf.
  public var authorized: Bool
  public var addedAt: String
  public init(id: String, host: String, label: String, authorized: Bool, addedAt: String) {
    self.id = id; self.host = host; self.label = label; self.authorized = authorized; self.addedAt = addedAt
  }
}

/// Ein Treffer des gründlichen Scans (nmap, sonst eigener TCP-Scan als Rückfall).
public struct ScanPort: Codable, Equatable, Sendable {
  public var port: Int
  public var proto: String  // "tcp"/"udp"
  public var state: String  // "open"/"closed"/"filtered"
  public var service: String
  public var version: String?
  public init(port: Int, proto: String = "tcp", state: String, service: String, version: String? = nil) {
    self.port = port; self.proto = proto; self.state = state; self.service = service; self.version = version
  }
}

public struct ScanReport: Codable, Equatable, Sendable {
  public var host: String
  public var ip: String?
  public var up: Bool
  /// Geschätztes Betriebssystem (nur bei nmap mit -O, oft leer).
  public var os: String?
  public var ports: [ScanPort]
  /// Verwendetes Werkzeug ("nmap" oder "eigener Scan").
  public var tool: String
  public var startedAt: String
  public var durationMs: Int
  public init(host: String, ip: String? = nil, up: Bool, os: String? = nil, ports: [ScanPort] = [],
              tool: String, startedAt: String, durationMs: Int) {
    self.host = host; self.ip = ip; self.up = up; self.os = os; self.ports = ports
    self.tool = tool; self.startedAt = startedAt; self.durationMs = durationMs
  }
}

public enum ScanDepth: String, Codable, Sendable, CaseIterable {
  /// Schnell: gängige Ports, kein Dienst-/OS-Erkennung.
  case quick
  /// Dienste und Versionen der offenen Ports.
  case services
  /// Zusätzlich Betriebssystem-Erkennung (nmap, braucht Admin → fragt nach).
  case deep
}

/// Eine offene Verbindung dieses Macs (lsof -i).
public struct Connection: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var app: String
  public var pid: Int
  public var proto: String
  public var localAddress: String
  public var remoteAddress: String?
  public var remoteHost: String?
  public var state: String
  /// Gegenstelle liegt im eigenen Netz.
  public var isLocal: Bool
  public init(id: String, app: String, pid: Int, proto: String, localAddress: String, remoteAddress: String? = nil,
              remoteHost: String? = nil, state: String, isLocal: Bool) {
    self.id = id; self.app = app; self.pid = pid; self.proto = proto; self.localAddress = localAddress
    self.remoteAddress = remoteAddress; self.remoteHost = remoteHost; self.state = state; self.isLocal = isLocal
  }
}

/// Eine mitgeschnittene Zeile (eine Zusammenfassung je Paket, kein Rohinhalt).
public struct CapturePacket: Codable, Equatable, Identifiable, Sendable {
  public var id: Int
  /// Sekunden seit Start des Mitschnitts.
  public var t: Double
  public var proto: String
  public var source: String
  public var dest: String
  public var length: Int
  /// Kurzinfo (Flags, Ports, Dienst), aus tcpdump.
  public var info: String
  public init(id: Int, t: Double, proto: String, source: String, dest: String, length: Int, info: String) {
    self.id = id; self.t = t; self.proto = proto; self.source = source; self.dest = dest
    self.length = length; self.info = info
  }
}

public struct CaptureState: Codable, Equatable, Sendable {
  public var running: Bool
  public var interface: String
  public var filter: String
  public var startedAt: String?
  public var packetCount: Int
  /// Zusammenfassung je Gegenstelle (host → Pakete/Bytes), im Code gezählt.
  public var byHost: [CaptureHostStat]
  /// Pfad einer gespeicherten .pcap (für Wireshark), falls exportiert.
  public var savedPath: String?
  public init(running: Bool = false, interface: String = "", filter: String = "", startedAt: String? = nil,
              packetCount: Int = 0, byHost: [CaptureHostStat] = [], savedPath: String? = nil) {
    self.running = running; self.interface = interface; self.filter = filter; self.startedAt = startedAt
    self.packetCount = packetCount; self.byHost = byHost; self.savedPath = savedPath
  }
}

public struct CaptureHostStat: Codable, Equatable, Identifiable, Sendable {
  public var id: String  // host/ip
  public var packets: Int
  public var bytes: Int
  public init(id: String, packets: Int, bytes: Int) { self.id = id; self.packets = packets; self.bytes = bytes }
}
