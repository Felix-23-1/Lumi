// Profi-Scan eines einzelnen Ziels: nmap, wenn installiert; sonst ein eigener
// TCP-Verbindungsaufbau gegen eine kleine Port-Liste. Argumente gehen als feste
// Liste an den Prozess (keine Shell); der Host wird vorher geprüft.
import Foundation

/// Grenze zu nmap und zum Dateisystem (Prüfungen setzen eine Attrappe ein).
public protocol PortScanSystem: Sendable {
  /// Pfad zu nmap, falls installiert; sonst nil.
  func whichNmap() -> String?
  /// Startet ein Programm mit Zeitlimit (feste Argumentliste, keine Shell).
  func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput
}

/// Echte Umsetzung: sucht nmap an den üblichen Orten und startet es über ModProcess.
public struct SystemPortScan: PortScanSystem {
  public static let nmapCandidates = ["/opt/homebrew/bin/nmap", "/usr/local/bin/nmap", "/usr/bin/nmap"]

  public init() {}

  public func whichNmap() -> String? {
    Self.nmapCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

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
}

/// Ergebnis einer nmap-Ausgabe (normales Format, ohne XML).
public struct NmapResult: Equatable, Sendable {
  public var up: Bool
  public var ip: String?
  public var os: String?
  public var ports: [ScanPort]
  public init(up: Bool, ip: String? = nil, os: String? = nil, ports: [ScanPort] = []) {
    self.up = up; self.ip = ip; self.os = os; self.ports = ports
  }
}

public enum NmapParser {
  static let reportPrefix = "Nmap scan report for "

  /// Liest die normale nmap-Ausgabe: Host oben/unten, Port-Zeilen „22/tcp open ssh VERSION“,
  /// Betriebssystem aus „OS details:“ oder ersatzweise „Running:“.
  public static func parse(_ output: String) -> NmapResult {
    var sawUp = false
    var sawDown = false
    var ip: String?
    var osDetails: String?
    var running: String?
    var ports: [ScanPort] = []

    for raw in output.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix(reportPrefix) {
        ip = reportIP(String(line.dropFirst(reportPrefix.count)))
      } else if line.hasPrefix("Host is up") {
        sawUp = true
      } else if line.contains("Host seems down") || line.contains("0 hosts up") {
        sawDown = true
      } else if line.hasPrefix("OS details: ") {
        osDetails = String(line.dropFirst("OS details: ".count))
      } else if line.hasPrefix("Running"), let colon = line.range(of: ": ") {
        running = String(line[colon.upperBound...])
      } else if let port = portLine(line) {
        ports.append(port)
      }
    }
    let up = sawUp && !sawDown
    let os = [osDetails, running].compactMap { $0 }.first { !$0.isEmpty }
    return NmapResult(up: up, ip: ip, os: os, ports: ports)
  }

  /// "router.fritz.box (192.168.178.1)" → "192.168.178.1"; reine IP bleibt.
  static func reportIP(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix(")"), let open = t.lastIndex(of: "(") {
      let inner = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
      return NetworkAddress.isIP(inner) ? inner : nil
    }
    return NetworkAddress.isIP(t) ? t : nil
  }

  /// "22/tcp   open  ssh   OpenSSH 8.9p1" → ScanPort. Nur Zeilen mit „Nummer/Protokoll“ am Anfang.
  static func portLine(_ line: String) -> ScanPort? {
    let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count >= 3 else { return nil }
    let pp = tokens[0].split(separator: "/", omittingEmptySubsequences: false)
    guard pp.count == 2, let port = Int(pp[0]), (1...65535).contains(port),
          pp[1] == "tcp" || pp[1] == "udp" else { return nil }
    let version = tokens.count > 3 ? tokens[3...].joined(separator: " ") : nil
    return ScanPort(port: port, proto: String(pp[1]), state: tokens[1], service: tokens[2],
                    version: version?.isEmpty == false ? version : nil)
  }
}

public final class ProScanner: @unchecked Sendable {
  /// Gängige Ports für den eigenen Scan (ohne nmap).
  public static let defaultPorts: [(port: Int, service: String)] = [
    (21, "FTP"), (22, "SSH"), (23, "Telnet"), (25, "SMTP"), (53, "DNS"), (80, "HTTP"), (110, "POP3"),
    (111, "RPC"), (135, "MS-RPC"), (139, "NetBIOS"), (143, "IMAP"), (443, "HTTPS"), (445, "SMB"),
    (548, "AFP"), (554, "RTSP"), (631, "Drucker (IPP)"), (993, "IMAPS"), (995, "POP3S"),
    (1433, "MS SQL"), (3306, "MySQL"), (3389, "RDP"), (5000, "Synology/UPnP"), (5432, "PostgreSQL"),
    (5900, "VNC"), (8080, "HTTP-Alt"), (8443, "HTTPS-Alt"), (9100, "Drucker"),
  ]
  public static let maxOwnConcurrency = 50
  public static let ownTimeout: TimeInterval = 1.5
  static let toolOwn = "eigener Scan"
  static let toolNmap = "nmap"

  let net: NetworkSystem
  let system: PortScanSystem

  public init(net: NetworkSystem, system: PortScanSystem) {
    self.net = net
    self.system = system
  }

  /// Argumentliste für nmap. Der Host steht immer zuletzt; er wurde vorher als IP/Name geprüft.
  static func nmapArgs(depth: ScanDepth, host: String) -> [String] {
    switch depth {
    case .quick: return ["-T4", "-F", host]
    case .services: return ["-T4", "-sV", "-F", host]
    case .deep: return ["-T4", "-sV", "-O", "-F", host]
    }
  }

  static func timeout(for depth: ScanDepth) -> TimeInterval {
    switch depth {
    case .quick: return 90
    case .services: return 150
    case .deep: return 240
    }
  }

  /// Ein Ziel scannen. Ziel muss im eigenen Netz liegen oder ein bestätigter eigener Server sein.
  public func scan(host: String, depth: ScanDepth, ownServers: [OwnServer], clock: Clock) async
    -> ToolResult<ScanReport>
  {
    let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard NetworkAddress.isValidHost(target) else {
      return .failure(code: "NETWORK_BAD_HOST", error: "Ungültiger Rechnername oder ungültige IP-Adresse.")
    }
    let start = clock.now()
    let startedAt = LocalTime.format(start)
    let resolved = await net.resolve(target)
    if !NetworkAddress.isIP(target) && resolved.isEmpty && !NetworkAddress.isPrivate(target) {
      return .failure(code: "NETWORK_UNKNOWN_HOST", error: "„\(target)“ wurde nicht gefunden.")
    }
    guard ScanTargets.isAllowed(host: target, ownServers: ownServers, resolvedIPs: resolved) else {
      return .failure(code: "SCAN_NOT_ALLOWED", error: ScanTargets.refusal)
    }
    let ip = ([target] + resolved).first { NetworkAddress.isIPv4($0) }

    if let nmap = system.whichNmap() {
      return await runNmap(nmap, host: target, ip: ip, depth: depth, startedAt: startedAt, start: start, clock: clock)
    }
    return await ownScan(host: target, ip: ip, startedAt: startedAt, start: start, clock: clock)
  }

  private func runNmap(_ nmap: String, host: String, ip: String?, depth: ScanDepth, startedAt: String,
                       start: Date, clock: Clock) async -> ToolResult<ScanReport> {
    var tool = Self.toolNmap
    var out = await system.run(nmap, Self.nmapArgs(depth: depth, host: host), timeout: Self.timeout(for: depth))
    // Betriebssystem-Erkennung braucht Root. Ohne Rechte: Dienste-Scan, Hinweis im Werkzeugnamen.
    if depth == .deep && Self.needsRoot(out) {
      tool = "nmap (ohne Betriebssystem-Erkennung: Admin-Rechte nötig)"
      out = await system.run(nmap, Self.nmapArgs(depth: .services, host: host),
                             timeout: Self.timeout(for: .services))
    }
    if out.timedOut {
      return .failure(code: "NETWORK_TIMEOUT", error: "Der Scan hat zu lange gedauert.")
    }
    guard out.status == 0, !out.stdout.isEmpty else {
      return .failure(code: "NETWORK_FAILED", error: "Der Scan konnte nicht ausgeführt werden.")
    }
    let parsed = NmapParser.parse(out.stdout)
    let report = ScanReport(host: host, ip: parsed.ip ?? ip, up: parsed.up, os: parsed.os, ports: parsed.ports,
                            tool: tool, startedAt: startedAt, durationMs: Self.elapsedMs(start, clock.now()))
    return .ok(report)
  }

  static func needsRoot(_ out: ProcessOutput) -> Bool {
    let text = out.stdout + out.stderr
    return out.status != 0
      && (text.localizedCaseInsensitiveContains("requires root") || text.localizedCaseInsensitiveContains("root privileges"))
  }

  private func ownScan(host: String, ip: String?, startedAt: String, start: Date, clock: Clock) async
    -> ToolResult<ScanReport>
  {
    let entries = Self.defaultPorts
    var open: [ScanPort] = []
    var index = 0
    while index < entries.count {
      let batch = Array(entries[index..<min(index + Self.maxOwnConcurrency, entries.count)])
      index += batch.count
      let hits = await withTaskGroup(of: (Int, Bool).self) { group -> [Int: Bool] in
        for entry in batch {
          group.addTask {
            (entry.port, await self.net.tcpOpen(host, port: entry.port, timeout: Self.ownTimeout))
          }
        }
        var out: [Int: Bool] = [:]
        for await (port, isOpen) in group { out[port] = isOpen }
        return out
      }
      for entry in batch where hits[entry.port] == true {
        open.append(ScanPort(port: entry.port, state: "open", service: entry.service))
      }
    }
    open.sort { $0.port < $1.port }
    let report = ScanReport(host: host, ip: ip, up: !open.isEmpty, os: nil, ports: open, tool: Self.toolOwn,
                            startedAt: startedAt, durationMs: Self.elapsedMs(start, clock.now()))
    return .ok(report)
  }

  static func elapsedMs(_ from: Date, _ to: Date) -> Int {
    max(0, Int((to.timeIntervalSince(from) * 1000).rounded()))
  }
}
