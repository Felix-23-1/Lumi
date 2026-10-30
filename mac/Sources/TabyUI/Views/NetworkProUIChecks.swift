// Prüfungen und Snapshots für die Profi-Werkzeuge im Netzwerk-Reiter (Paket 7):
// Logik ohne Fenster, Aktionen gegen Fakes, Ansichten als PNG (ImageRenderer).
import SwiftUI
import TabyCore

enum NetworkProUIChecks {
  @MainActor static var cases: [CheckCase] {
    logicCases + actionCases
  }

  // MARK: - Reine Logik

  @MainActor static var logicCases: [CheckCase] {
    [
      CheckCase("Profi: Port-Zustand als Wort und Farbton, Scan-Zusammenfassung") {
        try expectEqual(NetworkProLogic.portWord("open"), "offen")
        try expectEqual(NetworkProLogic.portWord("closed"), "geschlossen")
        try expectEqual(NetworkProLogic.portWord("filtered"), "gefiltert")
        try expectEqual(NetworkProLogic.portTone("open"), .good)
        try expectEqual(NetworkProLogic.portTone("filtered"), .warn)
        try expectEqual(NetworkProLogic.portTone("closed"), .neutral)
        let report = ScanReport(host: "192.168.178.40", up: true,
                                ports: [ScanPort(port: 22, state: "open", service: "ssh"),
                                        ScanPort(port: 23, state: "closed", service: "telnet"),
                                        ScanPort(port: 80, state: "open", service: "http")],
                                tool: "nmap", startedAt: "2026-10-11T09:00", durationMs: 1200)
        try expectEqual(NetworkProLogic.scanSummary(report), "2 offen · 3 geprüft")
      },
      CheckCase("Profi: Scan-Tiefe, Hinweis nur bei Tief, Ablehnung erkennen, Vorbelegung") {
        try expectEqual(NetworkProLogic.depthLabel(.quick), "Schnell")
        try expectEqual(NetworkProLogic.depthLabel(.services), "Dienste")
        try expectEqual(NetworkProLogic.depthLabel(.deep), "Tief")
        try expectEqual(NetworkProLogic.depthHint(.quick), nil)
        try expectEqual(NetworkProLogic.depthHint(.deep), NetworkProLogic.scanDeepNote)
        try expect(NetworkProLogic.isRefusal("SCAN_NOT_ALLOWED"), "nicht erlaubter Host ist eine Ablehnung")
        try expect(!NetworkProLogic.isRefusal("NETWORK_OFF"), "Netz aus ist keine Ablehnung des Ziels")
        let info = NetworkInfo(interfaceName: "WLAN", router: "192.168.178.1")
        try expectEqual(NetworkProLogic.scanPrefill(info), "192.168.178.1")
        try expectEqual(NetworkProLogic.scanPrefill(nil), "")
      },
      CheckCase("Profi: Verbindungen: extern zuerst, dann nach App; Tag, Ziel, Port, Zustand") {
        let taby = Connection(id: "a", app: "Lumi", pid: 1, proto: "tcp", localAddress: "192.168.178.24:52901",
                              remoteAddress: "192.168.178.1:53", remoteHost: "fritz.box", state: "ESTABLISHED",
                              isLocal: true)
        let safari = Connection(id: "b", app: "Safari", pid: 2, proto: "tcp", localAddress: "192.168.178.24:52344",
                                remoteAddress: "140.82.121.4:443", remoteHost: "github.com", state: "ESTABLISHED",
                                isLocal: false)
        let mail = Connection(id: "c", app: "Mail", pid: 3, proto: "tcp", localAddress: "192.168.178.24:52890",
                              remoteAddress: "17.57.144.22:993", state: "ESTABLISHED", isLocal: false)
        let sorted = NetworkProLogic.sortConnections([taby, safari, mail])
        try expectEqual(sorted.map(\.id), ["c", "b", "a"])
        try expectEqual(NetworkProLogic.connectionTag(taby), "lokal")
        try expectEqual(NetworkProLogic.connectionTag(safari), "extern")
        try expectEqual(NetworkProLogic.connectionTarget(safari), "github.com")
        try expectEqual(NetworkProLogic.connectionTarget(mail), "17.57.144.22:993")
        let listening = Connection(id: "d", app: "sshd", pid: 4, proto: "tcp", localAddress: "*:22", state: "LISTEN",
                                   isLocal: true)
        try expectEqual(NetworkProLogic.connectionTarget(listening), "nur lokal")
        try expectEqual(NetworkProLogic.localPort("192.168.178.24:52344"), "52344")
        try expectEqual(NetworkProLogic.connectionStateWord("ESTABLISHED"), "verbunden")
        try expectEqual(NetworkProLogic.connectionStateTone("ESTABLISHED"), .good)
        try expectEqual(NetworkProLogic.connectionStateTone("CLOSE_WAIT"), .warn)
      },
      CheckCase("Profi: Bytes mit Komma, Laufzeit, Plural der Pakete") {
        try expectEqual(NetworkProLogic.bytes(512), "512 B")
        try expectEqual(NetworkProLogic.bytes(0), "0 B")
        try expectEqual(NetworkProLogic.bytes(1840), "1,8 KB")
        try expectEqual(NetworkProLogic.bytes(2_400_000), "2,4 MB")
        try expectEqual(NetworkProLogic.captureDuration(seconds: 42), "42 s")
        try expectEqual(NetworkProLogic.captureDuration(seconds: 185), "3 min 05 s")
        try expectEqual(NetworkProLogic.captureDuration(seconds: 3720), "1 Std. 02 min")
        try expectEqual(NetworkProLogic.captureDuration(seconds: -5), "0 s")
        try expectEqual(NetworkProLogic.packetsText(1), "1 Paket")
        try expectEqual(NetworkProLogic.packetsText(3), "3 Pakete")
      },
      CheckCase("Profi: Paketzeile mit Komma-Zeit; Gegenstellen meiste Bytes zuerst") {
        let p = CapturePacket(id: 1, t: 0.01, proto: "TCP", source: "192.168.178.24", dest: "140.82.121.4",
                              length: 920, info: "443 ACK")
        try expectEqual(NetworkProLogic.packetLine(p),
                        "0,01 s  TCP  192.168.178.24 → 140.82.121.4  920 B  443 ACK")
        let stats = [CaptureHostStat(id: "fritz.box", packets: 1, bytes: 120),
                     CaptureHostStat(id: "github.com", packets: 2, bytes: 1840)]
        try expectEqual(NetworkProLogic.rankedHosts(stats).map(\.id), ["github.com", "fritz.box"])
        try expectEqual(NetworkProLogic.hostStatLine(stats[1]), "github.com · 2 Pakete · 1,8 KB")
      },
      CheckCase("Profi: Schnittstelle gewählt oder erste, eigene Server nur mit Host und Bestätigung") {
        try expectEqual(NetworkProLogic.effectiveInterface(chosen: "en1", available: ["en0", "en1"]), "en1")
        try expectEqual(NetworkProLogic.effectiveInterface(chosen: "xyz", available: ["en0", "en1"]), "en0")
        try expectEqual(NetworkProLogic.effectiveInterface(chosen: nil, available: []), nil)
        try expect(!NetworkProLogic.canAddServer(host: "203.0.113.10", confirmed: false), "ohne Bestätigung gesperrt")
        try expect(!NetworkProLogic.canAddServer(host: "", confirmed: true), "ohne Host gesperrt")
        try expect(!NetworkProLogic.canAddServer(host: "  ", confirmed: true), "Leerzeichen ist kein Host")
        try expect(NetworkProLogic.canAddServer(host: "203.0.113.10", confirmed: true), "mit Host und Bestätigung frei")
        let bare = OwnServer(id: "s1", host: "203.0.113.10", label: "", authorized: true, addedAt: "2026-10-11T09:00")
        try expectEqual(NetworkProLogic.serverTitle(bare), "203.0.113.10")
        let named = OwnServer(id: "s2", host: "203.0.113.11", label: "Heimserver", authorized: true,
                              addedAt: "2026-10-11T09:00")
        try expectEqual(NetworkProLogic.serverTitle(named), "Heimserver")
      },
    ]
  }

  // MARK: - Aktionen gegen Fakes

  @MainActor static var actionCases: [CheckCase] {
    [
      CheckCase("Profi: Scan, Verbindungen, Mitschnitt und eigene Server laufen gegen die Fakes") {
        let fake = NetworkChecks.networkFake()
        let scan = await fake.deepScan("192.168.178.40", depth: .deep)
        try expect(scan.isOk, "Scan im Fake gelingt")
        try expectEqual(scan.value?.os, "Linux 5.x")
        try expectEqual(fake.current.network?.lastScan2?.ports.count, 3)
        let conns = await fake.listConnections()
        try expectEqual(conns.value?.count, 3)
        let added = await fake.addOwnServer(host: "203.0.113.10", label: "")
        try expect(added.isOk, "Server hinzufügen gelingt")
        try expectEqual(fake.current.network?.ownServers.count, 1)
        let started = await fake.startCapture(interface: nil, filter: "port 443")
        try expect(started.value?.running == true, "Mitschnitt läuft")
        try expectEqual(fake.current.network?.recentPackets.count, 3)
        _ = await fake.stopCapture()
        try expectEqual(fake.current.network?.capturing, false)
        if let id = fake.current.network?.ownServers.first?.id {
          _ = await fake.removeOwnServer(id)
        }
        try expectEqual(fake.current.network?.ownServers.count, 0)
      },
    ]
  }

  // MARK: - Snapshots

  /// Netzwerk mit Scan-Ergebnis, Verbindungen, laufendem Mitschnitt und eigenen Servern.
  @MainActor static func proNetwork(capturing: Bool = false, servers: Bool = false) -> NetworkState {
    let fake = NetworkChecks.networkFake()
    var n = fake.current.network ?? fake.sampleNetwork()
    let seen = "2026-10-11T08:59"
    n.lastScan2 = ScanReport(host: "192.168.178.40", ip: "192.168.178.40", up: true, os: "Linux 5.x",
                             ports: [ScanPort(port: 22, state: "open", service: "ssh", version: "OpenSSH 9.6"),
                                     ScanPort(port: 80, state: "open", service: "http", version: "nginx 1.24"),
                                     ScanPort(port: 443, state: "closed", service: "https"),
                                     ScanPort(port: 8080, state: "filtered", service: "http-alt")],
                             tool: "nmap", startedAt: seen, durationMs: 2400)
    n.connections = [
      Connection(id: "c1", app: "Safari", pid: 501, proto: "tcp", localAddress: "192.168.178.24:52344",
                 remoteAddress: "140.82.121.4:443", remoteHost: "github.com", state: "ESTABLISHED", isLocal: false),
      Connection(id: "c2", app: "Mail", pid: 502, proto: "tcp", localAddress: "192.168.178.24:52890",
                 remoteAddress: "17.57.144.22:993", remoteHost: "imap.mail.me.com", state: "ESTABLISHED", isLocal: false),
      Connection(id: "c3", app: "Lumi", pid: 777, proto: "tcp", localAddress: "192.168.178.24:52901",
                 remoteAddress: "192.168.178.1:53", remoteHost: "fritz.box", state: "ESTABLISHED", isLocal: true),
      Connection(id: "c4", app: "sshd", pid: 90, proto: "tcp", localAddress: "*:22", state: "LISTEN", isLocal: true),
    ]
    if capturing {
      n.capturing = true
      n.capture = CaptureState(running: true, interface: "en0", filter: "port 443", startedAt: "2026-10-11T08:59",
                               packetCount: 9,
                               byHost: [CaptureHostStat(id: "github.com", packets: 6, bytes: 5400),
                                        CaptureHostStat(id: "fritz.box", packets: 2, bytes: 240),
                                        CaptureHostStat(id: "imap.mail.me.com", packets: 1, bytes: 1840)])
      n.recentPackets = [
        CapturePacket(id: 1, t: 0.01, proto: "TCP", source: "192.168.178.24", dest: "140.82.121.4", length: 74, info: "443 SYN"),
        CapturePacket(id: 2, t: 0.04, proto: "TCP", source: "140.82.121.4", dest: "192.168.178.24", length: 74, info: "443 SYN, ACK"),
        CapturePacket(id: 3, t: 0.04, proto: "TCP", source: "192.168.178.24", dest: "140.82.121.4", length: 66, info: "443 ACK"),
        CapturePacket(id: 4, t: 0.09, proto: "TLS", source: "192.168.178.24", dest: "140.82.121.4", length: 1840, info: "Client Hello"),
        CapturePacket(id: 5, t: 0.21, proto: "TCP", source: "140.82.121.4", dest: "192.168.178.24", length: 1400, info: "443 PSH"),
        CapturePacket(id: 6, t: 0.22, proto: "UDP", source: "192.168.178.24", dest: "192.168.178.1", length: 120, info: "53 DNS"),
        CapturePacket(id: 7, t: 0.35, proto: "UDP", source: "192.168.178.1", dest: "192.168.178.24", length: 210, info: "53 DNS-Antwort"),
        CapturePacket(id: 8, t: 0.40, proto: "TCP", source: "192.168.178.24", dest: "17.57.144.22", length: 66, info: "993 ACK"),
        CapturePacket(id: 9, t: 0.52, proto: "TCP", source: "17.57.144.22", dest: "192.168.178.24", length: 1420, info: "993 PSH"),
      ]
    }
    if servers {
      n.ownServers = [
        OwnServer(id: "s1", host: "203.0.113.10", label: "Heimserver", authorized: true, addedAt: seen),
        OwnServer(id: "s2", host: "homelab.example.net", label: "", authorized: true, addedAt: seen),
      ]
    }
    return n
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-network-scan", size: CGSize(width: TabLayout.contentWidth, height: 640)) {
        let view = NetworkProSection(network: proNetwork(),
                                     preview: NetworkProPreview(tool: .scan, scanHost: "192.168.178.40",
                                                                scanDepth: .deep))
        return wrap(view.tabyPage(), cap: 1000)
      },
      SnapshotSpec("view-network-connections", size: CGSize(width: TabLayout.contentWidth, height: 520)) {
        let view = NetworkProSection(network: proNetwork(), preview: NetworkProPreview(tool: .connections))
        return wrap(view.tabyPage(), cap: 1000)
      },
      SnapshotSpec("view-network-capture", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let view = NetworkProSection(network: proNetwork(capturing: true), preview: NetworkProPreview(tool: .capture))
        return wrap(view.tabyPage(), cap: 1000)
      },
      SnapshotSpec("view-network-capture-island", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let view = NetworkProSection(network: proNetwork(capturing: true), preview: NetworkProPreview(tool: .capture))
        return wrap(view.tabyPage())
      },
      SnapshotSpec("view-network-servers", size: CGSize(width: TabLayout.contentWidth, height: 520)) {
        let view = NetworkProSection(network: proNetwork(servers: true), preview: NetworkProPreview(tool: .servers))
        return wrap(view.tabyPage(), cap: 1000)
      },
      SnapshotSpec("view-network-servers-form", size: CGSize(width: TabLayout.contentWidth, height: 640)) {
        let view = NetworkProSection(network: proNetwork(servers: true),
                                     preview: NetworkProPreview(tool: .servers, serverFormOpen: true))
        return wrap(view.tabyPage(), cap: 1000)
      },
      SnapshotSpec("view-network-pro-tall", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let view = NetworkView(network: proNetwork(capturing: true, servers: true),
                               preview: NetworkPreview(pro: NetworkProPreview(tool: .capture)))
        let fake = NetworkChecks.networkFake()
        return wrap(view.tabyPage(), AppModel(services: fake), cap: 1000)
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, cap: CGFloat = TabLayout.maxContentHeight) -> AnyView {
    wrap(v, AppModel(services: NetworkChecks.networkFake()), cap: cap)
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel,
                                               cap: CGFloat = TabLayout.maxContentHeight) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow("2026-10-11T09:00").environment(\.tabySnapshot, true)
      .environment(\.tabyContentCap, cap))
  }
}
