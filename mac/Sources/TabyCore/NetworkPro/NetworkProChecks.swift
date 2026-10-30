// Prüfungen für Sources/TabyCore/NetworkPro. Reine Auswertungen mit echten
// Beispielausgaben (nmap, lsof, tcpdump, ifconfig), Sicherheitsregeln, Scan-Rückfall,
// Repository (SQLite im Speicher) und Mitschnitt über Attrappen. Es läuft kein
// echtes nmap, tcpdump oder lsof; nur der Smoke-Test fragt nach nmap (ohne Start).
import Foundation

/// Attrappe für Netzaufrufe (TCP, Namensauflösung, Hilfsprogramme).
private final class ProFakeNetwork: NetworkSystem, @unchecked Sendable {
  var resolveMap: [String: [String]] = [:]
  var openPorts: Set<Int> = []
  var reverse: [String: String] = [:]
  var runs: [String: ProcessOutput] = [:]
  private var tcpCallsStore: [Int] = []
  private let lock = NSLock()

  var tcpCalls: [Int] { lock.withLock { tcpCallsStore } }

  func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput {
    let key = ([path] + args).joined(separator: " ")
    return lock.withLock { () -> ProcessOutput in runs[key] ?? ProcessOutput(status: 1) }
  }

  func wifi() -> WifiReading? { nil }
  func localAddresses() -> [LocalAddress] { [] }
  func onlineOnce(timeout: TimeInterval) async -> Bool { true }
  func resolve(_ host: String) async -> [String] { resolveMap[host] ?? [] }
  func sendUDP(to ip: String, port: UInt16, payload: [UInt8]) -> Bool { false }

  func tcpOpen(_ host: String, port: Int, timeout: TimeInterval) async -> Bool {
    lock.withLock { tcpCallsStore.append(port) }
    return openPorts.contains(port)
  }

  func bonjourHits(types: [String], seconds: TimeInterval) async -> [BonjourHit] { [] }
  func reverseName(_ ip: String, timeout: TimeInterval) async -> String? { reverse[ip] }
}

/// Attrappe für nmap: meldet einen Pfad oder keinen und liefert Ausgaben je Befehlszeile.
private final class ProFakePortScan: PortScanSystem, @unchecked Sendable {
  var nmap: String?
  var runs: [String: ProcessOutput] = [:]
  private var callsStore: [String] = []
  private let lock = NSLock()

  var calls: [String] { lock.withLock { callsStore } }

  func whichNmap() -> String? { nmap }

  func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput {
    let key = ([path] + args).joined(separator: " ")
    return lock.withLock { () -> ProcessOutput in
      callsStore.append(key)
      return runs[key] ?? ProcessOutput(status: 1)
    }
  }
}

private struct ProFakeConn: ConnSystem {
  let text: String
  func lsof() async -> String { text }
}

/// Attrappe für den Mitschnitt: liefert feste Zeilen und merkt sich die Argumente.
private final class ProFakeCapture: CaptureSystem, @unchecked Sendable {
  var lines: [String] = []
  var accept = true
  private var argsStore: [[String]] = []
  private let lock = NSLock()

  var argsSeen: [[String]] { lock.withLock { argsStore } }
  var promptsSeen: [String] = []

  func runAdmin(_ args: [String], prompt: String) async -> CaptureFeed? {
    lock.withLock { argsStore.append(args) }
    promptsSeen.append(prompt)
    guard accept else { return nil }
    let (stream, continuation) = AsyncStream<String>.makeStream()
    for line in lines { continuation.yield(line) }
    continuation.finish()
    return CaptureFeed(lines: stream, stop: {})
  }
}

// Echte Beispielausgaben (gekürzt auf das Nötige).

private let nmapUpSample = """
Starting Nmap 7.94 ( https://nmap.org ) at 2026-10-12 10:00 CEST
Nmap scan report for fritz.box (192.168.178.1)
Host is up (0.0031s latency).
Not shown: 997 closed tcp ports (reset)
PORT     STATE SERVICE    VERSION
22/tcp   open  ssh        OpenSSH 8.9p1 Ubuntu 3ubuntu0.6 (Ubuntu Linux; protocol 2.0)
80/tcp   open  http       nginx 1.18.0
443/tcp  open  ssl/https?
MAC Address: 00:1B:2F:11:22:33 (Netgear)
Device type: general purpose
Running: Linux 5.X
OS CPE: cpe:/o:linux:linux_kernel:5
OS details: Linux 5.4 - 5.10
Network Distance: 1 hop
Service Info: OS: Linux; CPE: cpe:/o:linux:linux_kernel

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) scanned in 12.34 seconds
"""

private let nmapRunningOnlySample = """
Starting Nmap 7.94 ( https://nmap.org ) at 2026-10-12 10:02 CEST
Nmap scan report for 192.168.178.40
Host is up (0.0012s latency).
PORT     STATE SERVICE
5000/tcp open  upnp
Device type: general purpose
Running: Linux 4.X|5.X
Nmap done: 1 IP address (1 host up) scanned in 2.10 seconds
"""

private let nmapDownSample = """
Starting Nmap 7.94 ( https://nmap.org ) at 2026-10-12 10:05 CEST
Note: Host seems down. If it is really up, but blocking our ping probes, try -Pn
Nmap done: 1 IP address (0 hosts up) scanned in 3.02 seconds
"""

private let lsofSample = """
COMMAND     PID     USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
ControlCe   470 lienslex   10u  IPv4 0x1a2b3c4d5e6f7a8b      0t0  TCP *:7000 (LISTEN)
ControlCe   470 lienslex   11u  IPv6 0x1a2b3c4d5e6f7a8c      0t0  TCP [::1]:7000 (LISTEN)
Safari     1234 lienslex   50u  IPv4 0xabcdef0123456789      0t0  TCP 192.168.178.45:54321->17.253.144.10:443 (ESTABLISHED)
Safari     1234 lienslex   51u  IPv4 0xabcdef0123456790      0t0  TCP 192.168.178.45:54322->192.168.178.30:445 (ESTABLISHED)
Google\\x20Chrome 2222 lienslex 40u IPv4 0x5a6b7c8d 0t0 TCP 192.168.178.45:55000->142.250.74.14:443 (ESTABLISHED)
Spotify     888 lienslex   33u  IPv4 0x1111222233334444      0t0  UDP *:57621
"""

private let lsofSafariDuplicate = "Safari     1234 lienslex   50u  IPv4 0xabcdef0123456789      0t0  TCP 192.168.178.45:54321->17.253.144.10:443 (ESTABLISHED)"

private let tcpSample = "00:00:00.000123 IP 192.168.178.45.54321 > 17.253.144.10.443: Flags [P.], seq 1:518, ack 1, win 4096, length 517"
private let dnsSample = "00:00:00.004000 IP 192.168.178.45.51234 > 192.168.178.1.53: 12345+ A? example.com. (30)"
private let udpSample = "00:00:00.010000 IP6 fe80::1.5353 > ff02::fb.5353: UDP, length 40"
private let icmpSample = "00:00:00.020000 IP 192.168.178.1 > 192.168.178.45: ICMP echo reply, id 1, seq 1, length 64"
private let arpSample = "00:00:00.000100 ARP, Request who-has 192.168.178.1 tell 192.168.178.45, length 46"

private func failureCode<T>(_ result: ToolResult<T>) -> String? {
  if case .failure(let code, _) = result { return code }
  return nil
}

private let ownShop = OwnServer(id: "s1", host: "Shop.Example.de", label: "Shop", authorized: true,
                                addedAt: "2026-10-01T10:00")

public enum NetworkProChecks {
  @MainActor public static var suite: CheckSuite {
    CheckSuite("Netzwerk Pro", scanRuleChecks + filterChecks + nmapChecks + ownScanChecks + connectionChecks
                 + repositoryChecks + captureParsingChecks + captureChecks)
  }

  // MARK: Sicherheitsregeln für Ziele

  static var scanRuleChecks: [CheckCase] {
    [
      CheckCase("Mitschnitt: Vorbereitung legt out.txt, err.txt, pcap nur mit 0600 an") {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", TcpdumpCaptureSystem.setupScript(uid: String(getuid()))]
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let dir = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try expect(p.terminationStatus == 0 && dir.hasPrefix("/private/var/tmp/taby-capture."), "Vorbereitung fehlgeschlagen")
        for f in ["out.txt", "err.txt", "mitschnitt.pcap"] {
          let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/" + f)
          try expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o600)
        }
      },
      CheckCase("Ziel: private IPv4 im eigenen Netz ist erlaubt") {
        try expect(ScanTargets.isAllowed(host: "192.168.1.10", ownServers: [], resolvedIPs: []))
      },
      CheckCase("Ziel: öffentliche IP ist verboten") {
        try expect(!ScanTargets.isAllowed(host: "8.8.8.8", ownServers: [], resolvedIPs: []))
      },
      CheckCase("Ziel: eigener bestätigter Server ist erlaubt (ohne Groß-/Kleinschreibung)") {
        try expect(ScanTargets.isAllowed(host: "  SHOP.example.de ", ownServers: [ownShop], resolvedIPs: ["203.0.113.5"]))
      },
      CheckCase("Ziel: eigener nicht bestätigter Server ist verboten") {
        let unconfirmed = OwnServer(id: "s2", host: "shop.example.de", label: "Shop", authorized: false,
                                    addedAt: "2026-10-01T10:00")
        try expect(!ScanTargets.isAllowed(host: "shop.example.de", ownServers: [unconfirmed], resolvedIPs: ["203.0.113.5"]))
      },
      CheckCase("Ziel: öffentlicher Name mit öffentlicher Adresse ist verboten") {
        try expect(!ScanTargets.isAllowed(host: "example.com", ownServers: [], resolvedIPs: ["93.184.216.34"]))
      },
      CheckCase("Ziel: Name mit gemischten Adressen (eine öffentlich) ist verboten") {
        try expect(!ScanTargets.isAllowed(host: "example.com", ownServers: [], resolvedIPs: ["192.168.1.5", "93.184.216.34"]))
      },
      CheckCase("Ziel: Name, der nur auf private Adressen zeigt, ist erlaubt") {
        try expect(ScanTargets.isAllowed(host: "printer.example.com", ownServers: [], resolvedIPs: ["10.0.0.7"]))
      },
      CheckCase("Ziel: .local-Name ist erlaubt; Ablehnungstext stimmt") {
        try expect(ScanTargets.isAllowed(host: "drucker.local", ownServers: [], resolvedIPs: []))
        try expectEqual(ScanTargets.refusal, "Scannen nur im eigenen Netz oder gegen deine eingetragenen Server.")
      },
    ]
  }

  // MARK: Mitschnitt-Filter

  static var filterChecks: [CheckCase] {
    [
      CheckCase("Filter: leer ist erlaubt (alle Pakete)") {
        try expect(ScanTargets.isValidTcpdumpFilter(""))
        try expect(ScanTargets.isValidTcpdumpFilter("   "))
      },
      CheckCase("Filter: „port 80“ und „host 192.168.1.1 and tcp“ sind erlaubt") {
        try expect(ScanTargets.isValidTcpdumpFilter("port 80"))
        try expect(ScanTargets.isValidTcpdumpFilter("host 192.168.1.1 and tcp"))
      },
      CheckCase("Filter: Bereich, Netz, Klammern und && sind erlaubt") {
        try expect(ScanTargets.isValidTcpdumpFilter("portrange 80-443 and not arp"))
        try expect(ScanTargets.isValidTcpdumpFilter("src net 10.0.0.0/8 && (port 443 or port 80)"))
        try expect(ScanTargets.isValidTcpdumpFilter("tcp && udp"))
      },
      CheckCase("Filter: Semikolon, Befehlsersetzung und Pipe sind verboten") {
        try expect(!ScanTargets.isValidTcpdumpFilter("80; rm -rf"))
        try expect(!ScanTargets.isValidTcpdumpFilter("$(x)"))
        try expect(!ScanTargets.isValidTcpdumpFilter("a | b"))
        try expect(!ScanTargets.isValidTcpdumpFilter("`id`"))
      },
      CheckCase("Filter: einzelnes & , Anführungszeichen und Backslash sind verboten") {
        try expect(!ScanTargets.isValidTcpdumpFilter("tcp & rm"))
        try expect(!ScanTargets.isValidTcpdumpFilter("host 'x'"))
        try expect(!ScanTargets.isValidTcpdumpFilter("host a\\b"))
        try expect(!ScanTargets.isValidTcpdumpFilter("port 80 > /tmp/x"))
      },
      CheckCase("Filter: zu lange Filter werden abgelehnt (Längengrenze)") {
        try expect(ScanTargets.isValidTcpdumpFilter(String(repeating: "port 80 or ", count: 18)))   // 198 Zeichen
        try expect(!ScanTargets.isValidTcpdumpFilter(String(repeating: "port 80 or ", count: 19)))  // 209 Zeichen
      },
      CheckCase("Filter: unbekannte Wörter (z. B. „exec“) sind verboten") {
        try expect(!ScanTargets.isValidTcpdumpFilter("exec whoami"))
      },
    ]
  }

  // MARK: nmap-Auswertung und Argumente

  static var nmapChecks: [CheckCase] {
    [
      CheckCase("nmap: laufender Host mit Ports, Versionen, IP und Betriebssystem") {
        let r = NmapParser.parse(nmapUpSample)
        try expect(r.up, "Host sollte oben sein")
        try expectEqual(r.ip, "192.168.178.1")
        try expectEqual(r.os, "Linux 5.4 - 5.10")
        try expectEqual(r.ports.map(\.port), [22, 80, 443])
        try expectEqual(r.ports[0].version, "OpenSSH 8.9p1 Ubuntu 3ubuntu0.6 (Ubuntu Linux; protocol 2.0)")
        try expectEqual(r.ports[1].service, "http")
        try expectEqual(r.ports[1].version, "nginx 1.18.0")
        try expectEqual(r.ports[2].version, nil)
        try expectEqual(r.ports[2].state, "open")
      },
      CheckCase("nmap: nicht erreichbarer Host ist unten und ohne Ports") {
        let r = NmapParser.parse(nmapDownSample)
        try expect(!r.up)
        try expect(r.ports.isEmpty)
        try expectEqual(r.os, nil)
      },
      CheckCase("nmap: ohne „OS details“ wird „Running:“ als Betriebssystem genommen; IP ohne Name") {
        let r = NmapParser.parse(nmapRunningOnlySample)
        try expect(r.up)
        try expectEqual(r.ip, "192.168.178.40")
        try expectEqual(r.os, "Linux 4.X|5.X")
        try expectEqual(r.ports.map(\.service), ["upnp"])
      },
      CheckCase("nmap: Argumente je Tiefe, Ziel immer zuletzt") {
        try expectEqual(ProScanner.nmapArgs(depth: .quick, host: "10.0.0.5"), ["-T4", "-F", "10.0.0.5"])
        try expectEqual(ProScanner.nmapArgs(depth: .services, host: "10.0.0.5"), ["-T4", "-sV", "-F", "10.0.0.5"])
        try expectEqual(ProScanner.nmapArgs(depth: .deep, host: "10.0.0.5"), ["-T4", "-sV", "-O", "-F", "10.0.0.5"])
      },
    ]
  }

  // MARK: Scanner (eigener Scan, Rückfall, Ablehnung)

  static var ownScanChecks: [CheckCase] {
    [
      CheckCase("Scan ohne nmap: eigener TCP-Scan findet offene Ports mit Dienstnamen") {
        let net = ProFakeNetwork()
        net.openPorts = [22, 80, 443, 8080]
        let scanner = ProScanner(net: net, system: ProFakePortScan())
        let r = await scanner.scan(host: "192.168.178.30", depth: .services, ownServers: [],
                                   clock: ControllableClock("2026-10-12T10:00"))
        let report = try expectNotNil(r.value, "Scan ohne Ergebnis")
        try expectEqual(report.tool, "eigener Scan")
        try expectEqual(report.ports.map(\.port), [22, 80, 443, 8080])
        try expectEqual(report.ports.map(\.service), ["SSH", "HTTP", "HTTPS", "HTTP-Alt"])
        try expectEqual(report.ports.map(\.version), [nil, nil, nil, nil])
        try expect(report.up)
        try expectEqual(report.ip, "192.168.178.30")
        try expectEqual(report.os, nil)
        try expectEqual(report.startedAt, "2026-10-12T10:00")
        try expectEqual(net.tcpCalls.count, ProScanner.defaultPorts.count)
      },
      CheckCase("Scan: öffentliche Adresse ohne Eintrag wird abgelehnt, ohne Verbindungsversuch") {
        let net = ProFakeNetwork()
        let scanner = ProScanner(net: net, system: ProFakePortScan())
        let r = await scanner.scan(host: "8.8.8.8", depth: .quick, ownServers: [],
                                   clock: ControllableClock("2026-10-12T10:00"))
        try expectEqual(failureCode(r), "SCAN_NOT_ALLOWED")
        try expect(net.tcpCalls.isEmpty, "keine Verbindung zu fremden Hosts")
      },
      CheckCase("Scan: bestätigter eigener Server mit öffentlicher IP darf geprüft werden") {
        let net = ProFakeNetwork()
        net.openPorts = [22]
        let own = OwnServer(id: "s3", host: "203.0.113.9", label: "VPS", authorized: true, addedAt: "2026-10-01T10:00")
        let r = await ProScanner(net: net, system: ProFakePortScan()).scan(
          host: "203.0.113.9", depth: .quick, ownServers: [own], clock: ControllableClock("2026-10-12T10:00"))
        let report = try expectNotNil(r.value, "eigener Server sollte scanbar sein")
        try expectEqual(report.ports.map(\.port), [22])
      },
      CheckCase("Scan: ungültiger Host wird vor jedem Aufruf abgewiesen") {
        let net = ProFakeNetwork()
        let r = await ProScanner(net: net, system: ProFakePortScan()).scan(
          host: "-x; rm -rf", depth: .quick, ownServers: [], clock: ControllableClock("2026-10-12T10:00"))
        try expectEqual(failureCode(r), "NETWORK_BAD_HOST")
        try expect(net.tcpCalls.isEmpty)
      },
      CheckCase("Scan mit nmap: Ausgabe wird ausgewertet, Werkzeug heißt nmap") {
        let ps = ProFakePortScan()
        ps.nmap = "/usr/bin/nmap"
        ps.runs["/usr/bin/nmap -T4 -F 192.168.178.1"] = ProcessOutput(status: 0, stdout: nmapUpSample)
        let r = await ProScanner(net: ProFakeNetwork(), system: ps).scan(
          host: "192.168.178.1", depth: .quick, ownServers: [], clock: ControllableClock("2026-10-12T10:00"))
        let report = try expectNotNil(r.value, "nmap-Scan ohne Ergebnis")
        try expectEqual(report.tool, "nmap")
        try expectEqual(report.ports.count, 3)
        try expectEqual(report.os, "Linux 5.4 - 5.10")
        try expectEqual(ps.calls, ["/usr/bin/nmap -T4 -F 192.168.178.1"])
      },
      CheckCase("Scan mit nmap, Tiefe „deep“ ohne Root: fällt auf Dienste zurück und sagt es im Werkzeugnamen") {
        let ps = ProFakePortScan()
        ps.nmap = "/usr/bin/nmap"
        ps.runs["/usr/bin/nmap -T4 -sV -O -F 192.168.178.1"] = ProcessOutput(
          status: 1, stderr: "You requested a scan type which requires root privileges.\nQUITTING!\n")
        ps.runs["/usr/bin/nmap -T4 -sV -F 192.168.178.1"] = ProcessOutput(status: 0, stdout: nmapUpSample)
        let r = await ProScanner(net: ProFakeNetwork(), system: ps).scan(
          host: "192.168.178.1", depth: .deep, ownServers: [], clock: ControllableClock("2026-10-12T10:00"))
        let report = try expectNotNil(r.value, "Rückfall ohne Ergebnis")
        try expect(report.tool.contains("Admin-Rechte"), "Hinweis fehlt: \(report.tool)")
        try expectEqual(ps.calls.count, 2)
        try expectEqual(ps.calls.last, "/usr/bin/nmap -T4 -sV -F 192.168.178.1")
      },
      CheckCase("Scan mit nmap: Ziel ohne Antwort meldet „nicht oben“ ohne Fehler") {
        let ps = ProFakePortScan()
        ps.nmap = "/usr/bin/nmap"
        ps.runs["/usr/bin/nmap -T4 -F 192.168.178.99"] = ProcessOutput(status: 0, stdout: nmapDownSample)
        let r = await ProScanner(net: ProFakeNetwork(), system: ps).scan(
          host: "192.168.178.99", depth: .quick, ownServers: [], clock: ControllableClock("2026-10-12T10:00"))
        let report = try expectNotNil(r.value)
        try expect(!report.up)
        try expect(report.ports.isEmpty)
      },
    ]
  }

  // MARK: Verbindungen (lsof)

  static var connectionChecks: [CheckCase] {
    [
      CheckCase("lsof: Tabelle wird in Zeilen zerlegt (Listen, Verbindung, UDP, Leerzeichen im Namen)") {
        let rows = LsofParser.parse(lsofSample)
        try expectEqual(rows.count, 6)
        try expectEqual(rows[0].app, "ControlCe")
        try expectEqual(rows[0].state, "LISTEN")
        try expectEqual(rows[0].remote, nil)
        try expectEqual(rows[2].remote, "17.253.144.10:443")
        try expectEqual(rows[2].state, "ESTABLISHED")
        try expectEqual(rows[4].app, "Google Chrome")
        try expectEqual(rows[5].proto, "UDP")
        try expectEqual(rows[5].state, "-")
      },
      CheckCase("lsof: Adressen mit und ohne eckige Klammern (IPv6) werden getrennt") {
        let v6 = try expectNotNil(LsofParser.splitHostPort("[fe80::1]:5353"))
        try expectEqual(v6.host, "fe80::1")
        try expectEqual(v6.port, "5353")
        let v4 = try expectNotNil(LsofParser.splitHostPort("192.168.1.5:54321"))
        try expectEqual(v4.host, "192.168.1.5")
        try expectEqual(LsofParser.hostOnly("*:22"), "*")
      },
      CheckCase("Verbindungen: fremde Gegenstellen zuerst, Dubletten entfallen, eigene Netze lokal") {
        let net = ProFakeNetwork()
        net.reverse = ["142.250.74.14": "lhr.example", "17.253.144.10": "edge.example"]
        let lister = ConnectionsLister(system: ProFakeConn(text: lsofSample + "\n" + lsofSafariDuplicate), net: net)
        let listed = await lister.list()
        let list = try expectNotNil(listed.value, "Liste ohne Ergebnis")
        try expectEqual(list.count, 6)
        try expectEqual(list[0].app, "Google Chrome")
        try expectEqual(list[0].remoteHost, "lhr.example")
        try expect(!list[0].isLocal)
        try expectEqual(list[1].app, "Safari")
        try expectEqual(list[1].remoteHost, "edge.example")
        let inside = list.first { $0.localAddress == "192.168.178.45:54322" }
        try expect(inside?.isLocal == true, "Verbindung ins eigene Netz ist lokal")
        try expectEqual(list.filter { $0.app == "Safari" }.count, 2)
      },
      CheckCase("Verbindungen: leere lsof-Ausgabe ist ein Fehler") {
        let r = await ConnectionsLister(system: ProFakeConn(text: ""), net: ProFakeNetwork()).list()
        try expectEqual(failureCode(r), "NETWORK_FAILED")
      },
    ]
  }

  // MARK: Eigene Server (Repository)

  static var repositoryChecks: [CheckCase] {
    [
      CheckCase("Eigene Server: Eingabe wird normalisiert (Schema, Pfad, Port)") {
        try expectEqual(OwnServersRepository.normalize("  HTTPS://Test.Example.de:8443/pfad "), "test.example.de")
        try expectEqual(OwnServersRepository.normalize("x.de:8080"), "x.de")
        try expectEqual(OwnServersRepository.normalize("192.168.1.5"), "192.168.1.5")
      },
      CheckCase("Eigene Server: ungültige Eingaben werden abgelehnt") {
        try expectEqual(OwnServersRepository.normalize("a b"), nil)
        try expectEqual(OwnServersRepository.normalize("   "), nil)
        let store = try Store.inMemory(clock: ControllableClock("2026-10-12T10:00"))
        do {
          _ = try store.ownServers.add(host: "bad host!", label: "", now: "2026-10-12T10:00")
          throw fail("ungültiger Host wurde angenommen")
        } catch let error as OwnServerError {
          try expectEqual(error, OwnServerError.invalidHost)
        }
      },
      CheckCase("Eigene Server: hinzufügen, doppelt, Liste, entfernen") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-12T10:00"))
        let first = try store.ownServers.add(host: "  HTTPS://Test.Example.de:8443/pfad ", label: "Testserver",
                                             now: "2026-10-12T10:00")
        try expectEqual(first.host, "test.example.de")
        try expect(first.authorized)
        let again = try store.ownServers.add(host: "test.example.de", label: "egal", now: "2026-10-12T10:05")
        try expectEqual(again.id, first.id)
        let nas = try store.ownServers.add(host: "192.168.178.30", label: "   ", now: "2026-10-12T10:06")
        try expectEqual(nas.label, "192.168.178.30")
        try expectEqual(try store.ownServers.list().map(\.host), ["test.example.de", "192.168.178.30"])
        try store.ownServers.remove(first.id)
        try expectEqual(try store.ownServers.list().map(\.id), [nas.id])
      },
    ]
  }

  // MARK: Auswertung des Mitschnitts

  static var captureParsingChecks: [CheckCase] {
    [
      CheckCase("tcpdump: TCP-Zeile mit Zeitabstand, Adressen, Flags und Länge") {
        let p = try expectNotNil(TcpdumpParser.parseLine(tcpSample))
        try expectEqual(p.proto, "TCP")
        try expectEqual(p.source, "192.168.178.45")
        try expectEqual(p.dest, "17.253.144.10")
        try expectEqual(p.length, 517)
        try expect(abs(p.t - 0.000123) < 1e-9, "Abstand falsch: \(p.t)")
        try expect(p.info.contains("Flags [P.]"), p.info)
      },
      CheckCase("tcpdump: DNS-Anfrage über Port 53 und UDP-Zeile mit IPv6") {
        let dns = try expectNotNil(TcpdumpParser.parseLine(dnsSample))
        try expectEqual(dns.proto, "DNS")
        try expectEqual(dns.length, 30)
        try expectEqual(dns.dest, "192.168.178.1")
        let udp = try expectNotNil(TcpdumpParser.parseLine(udpSample))
        try expectEqual(udp.proto, "UDP")
        try expectEqual(udp.source, "fe80::1")
        try expectEqual(udp.dest, "ff02::fb")
        try expectEqual(udp.length, 40)
      },
      CheckCase("tcpdump: ICMP-Zeile; ARP und Müll ergeben nichts") {
        let icmp = try expectNotNil(TcpdumpParser.parseLine(icmpSample))
        try expectEqual(icmp.proto, "ICMP")
        try expectEqual(icmp.length, 64)
        try expectEqual(icmp.source, "192.168.178.1")
        try expect(TcpdumpParser.parseLine(arpSample) == nil, "ARP ist kein IP-Paket")
        try expect(TcpdumpParser.parseLine("hallo welt") == nil)
      },
      CheckCase("Zähler: Pakete und Bytes je Gegenstelle, nach Bytes sortiert") {
        let tcp = try expectNotNil(TcpdumpParser.parseLine(tcpSample))
        let dns = try expectNotNil(TcpdumpParser.parseLine(dnsSample))
        var state = CaptureState(running: true, interface: "en0", filter: "")
        state = CaptureStats.merge(existing: state, packet: tcp)
        state = CaptureStats.merge(existing: state, packet: dns)
        try expectEqual(state.packetCount, 2)
        try expectEqual(state.byHost.map(\.id), ["192.168.178.45", "17.253.144.10", "192.168.178.1"])
        try expectEqual(state.byHost.first?.bytes, 547)
        try expectEqual(state.byHost.first?.packets, 2)
        try expect(state.running, "Laufzustand bleibt erhalten")
      },
      CheckCase("Zähler: höchstens 30 Gegenstellen, die mit den meisten Bytes") {
        var state = CaptureState()
        for i in 0..<40 {
          let packet = CapturePacket(id: i, t: 0, proto: "TCP", source: "10.0.0.\(i + 1)", dest: "10.0.1.1",
                                     length: 100 + i, info: "")
          state = CaptureStats.merge(existing: state, packet: packet)
        }
        try expectEqual(state.byHost.count, 30)
        try expectEqual(state.byHost.first?.id, "10.0.1.1")
        try expectEqual(state.packetCount, 40)
      },
      CheckCase("ifconfig -l: nur en*, utun*, bridge*, lo* in Reihenfolge, ohne Dubletten") {
        let names = InterfaceParser.parse("lo0 gif0 stf0 anpi0 anpi1 en0 en1 en2 en3 en4 awdl0 llw0 utun0 utun1 ap1 bridge0 bridge100 en0\n")
        try expectEqual(names, ["lo0", "en0", "en1", "en2", "en3", "en4", "utun0", "utun1", "bridge0", "bridge100"])
      },
    ]
  }

  // MARK: Mitschnitt-Ablauf (über Attrappe)

  static var captureChecks: [CheckCase] {
    [
      CheckCase("Mitschnitt: unbekannte Schnittstelle und unerlaubter Filter werden abgewiesen") {
        let net = ProFakeNetwork()
        net.runs["/sbin/ifconfig -l"] = ProcessOutput(status: 0, stdout: "lo0 en0 utun0\n")
        let pc = PacketCapture(system: ProFakeCapture(), net: net)
        let badInterface = await pc.start(interface: "en9", filter: "", maxPackets: 10)
        try expectEqual(failureCode(badInterface), "CAPTURE_BAD_INTERFACE")
        let badFilter = await pc.start(interface: "en0", filter: "80; rm -rf /", maxPackets: 10)
        try expectEqual(failureCode(badFilter), "CAPTURE_BAD_FILTER")
      },
      CheckCase("Mitschnitt: der Admin-Dialog nennt Schnittstelle und Filter") {
        let net = ProFakeNetwork()
        net.runs["/sbin/ifconfig -l"] = ProcessOutput(status: 0, stdout: "en0\n")
        let system = ProFakeCapture()
        _ = await PacketCapture(system: system, net: net).start(interface: "en0", filter: "port 443", maxPackets: 10)
        try expect(system.promptsSeen.last?.contains("„en0“") == true, "Schnittstelle fehlt im Dialog")
        try expect(system.promptsSeen.last?.contains("port 443") == true, "Filter fehlt im Dialog")
      },
      CheckCase("Mitschnitt: der Arbeitsordner des alten Mitschnitts wird beim nächsten Start gelöscht") {
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("taby-capture-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let new = FileManager.default.temporaryDirectory.appendingPathComponent("taby-capture-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: new) }
        CaptureWorkDirs.replace(with: old.path)
        CaptureWorkDirs.replace(with: new.path)
        try expect(!FileManager.default.fileExists(atPath: old.path), "alter Ordner bleibt liegen")
        try expect(FileManager.default.fileExists(atPath: new.path), "aktueller Ordner wird nicht gelöscht")
      },
      CheckCase("Mitschnitt: abgelehnter Admin-Dialog ergibt CAPTURE_DENIED") {
        let net = ProFakeNetwork()
        net.runs["/sbin/ifconfig -l"] = ProcessOutput(status: 0, stdout: "en0\n")
        let system = ProFakeCapture()
        system.accept = false
        let r = await PacketCapture(system: system, net: net).start(interface: "en0", filter: "", maxPackets: 10)
        try expectEqual(failureCode(r), "CAPTURE_DENIED")
      },
      CheckCase("Mitschnitt: Zeilen werden zu Paketen mit laufender Zeit und Zählung; Argumente stimmen") {
        let net = ProFakeNetwork()
        net.runs["/sbin/ifconfig -l"] = ProcessOutput(status: 0, stdout: "lo0 en0 utun0\n")
        let system = ProFakeCapture()
        system.lines = [tcpSample, "00:00:00.250000 IP 192.168.178.1 > 192.168.178.45: ICMP echo reply, length 64", "Kaputte Zeile"]
        let r = await PacketCapture(system: system, net: net).start(interface: "en0", filter: "port 443", maxPackets: 5000)
        let running = try expectNotNil(r.value, "Mitschnitt ohne Ergebnis")
        var got: [CapturePacket] = []
        for await packet in running.packets { got.append(packet) }
        try expectEqual(got.map(\.id), [1, 2])
        try expect(abs(got[0].t - 0.000123) < 1e-9)
        try expect(abs(got[1].t - 0.250123) < 1e-9, "laufende Zeit falsch: \(got[1].t)")
        try expectEqual(got[1].proto, "ICMP")
        try expectEqual(system.argsSeen.last, ["-i", "en0", "-nttt", "-l", "-c", "2000", "port 443"])
      },
      CheckCase("nmap-Suche: liefert nil oder einen absoluten Pfad, ohne etwas zu starten") {
        let path = SystemPortScan().whichNmap()
        try expect(path == nil || path?.hasPrefix("/") == true, "unerwarteter Pfad: \(path ?? "")")
      },
    ]
  }
}
