// Prüfungen für Sources/TabyCore/Network. Reine Auswertungen mit echten
// Beispielausgaben, Adress- und Portregeln, Wake-on-LAN, Repository (echte
// SQLite-Datenbank im Speicher) und der Wächter. Systemaufrufe laufen über eine
// Attrappe; nur der Wi-Fi-Smoke-Test nutzt das echte System (mit 5 s Obergrenze).
import Foundation

/// Attrappe für alle Systemaufrufe. Antworten werden über Felder vorgegeben.
final class FakeNetworkSystem: NetworkSystem, @unchecked Sendable {
  /// Schlüssel: "<pfad> <argumente, durch Leerzeichen>".
  var runs: [String: ProcessOutput] = [:]
  var runCalls: [String] = []
  var resolveMap: [String: [String]] = [:]
  var openPorts: Set<Int> = []
  var tcpCalls: [Int] = []
  var udpSent: [(ip: String, port: UInt16, count: Int)] = []
  var wifiReading: WifiReading?
  var addresses: [LocalAddress] = []
  var online = true
  var bonjour: [BonjourHit] = []
  var reverse: [String: String] = [:]
  /// Werkzeuge rufen das System nebenläufig auf (z. B. DNS: A/AAAA/MX parallel) – Listen sperren.
  private let lock = NSLock()

  func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ProcessOutput {
    let key = ([path] + args).joined(separator: " ")
    return lock.withLock {
      runCalls.append(key)
      return runs[key] ?? ProcessOutput(status: 1)
    }
  }

  func wifi() -> WifiReading? { wifiReading }

  func localAddresses() -> [LocalAddress] { addresses }

  func onlineOnce(timeout: TimeInterval) async -> Bool { online }

  func resolve(_ host: String) async -> [String] { resolveMap[host] ?? [] }

  func sendUDP(to ip: String, port: UInt16, payload: [UInt8]) -> Bool {
    lock.withLock { udpSent.append((ip, port, payload.count)) }
    return true
  }

  func tcpOpen(_ host: String, port: Int, timeout: TimeInterval) async -> Bool {
    lock.withLock { tcpCalls.append(port) }
    return openPorts.contains(port)
  }

  func bonjourHits(types: [String], seconds: TimeInterval) async -> [BonjourHit] { bonjour }

  func reverseName(_ ip: String, timeout: TimeInterval) async -> String? { reverse[ip] }
}

// Echte Ausgaben (gekürzt auf das Nötige) aus macOS.
private let arpSample = """
? (192.168.178.1) at 0:1b:2f:11:22:33 on en0 ifscope [ethernet]
? (192.168.178.20) at (incomplete) on en0 ifscope [ethernet]
nas.fritz.box (192.168.178.30) at 0:11:32:aa:bb:cc on en0 [ethernet]
? (192.168.178.40) at b8:27:eb:12:34:56 on en0 ifscope [ethernet]
? (192.168.178.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]

"""

private let pingOKSample = """
PING 192.168.178.1 (192.168.178.1): 56 data bytes
64 bytes from 192.168.178.1: icmp_seq=0 ttl=64 time=2.345 ms
64 bytes from 192.168.178.1: icmp_seq=1 ttl=64 time=2.110 ms
64 bytes from 192.168.178.1: icmp_seq=2 ttl=64 time=2.871 ms

--- 192.168.178.1 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 2.110/2.442/2.871/0.317 ms

"""

private let pingLossSample = """
PING 10.0.0.99 (10.0.0.99): 56 data bytes

--- 10.0.0.99 ping statistics ---
3 packets transmitted, 0 packets received, 100.0% packet loss

"""

private let routeSample = """
   route to: default
destination: default
       mask: default
    gateway: 192.168.178.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
 recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
       0         0         0         0         0         0      1500         0

"""

private let scutilSample = """
DNS configuration

resolver #1
  search domain[0] : fritz.box
  nameserver[0] : 192.168.178.1
  nameserver[1] : fd00::1
  if_index : 6 (en0)
  flags    : Request A records
  reach    : 0x00020002 (Reachable)

resolver #2
  domain   : local
  options  : mdns
  timeout  : 5
  nameserver[0] : 192.168.178.1
  nameserver[1] : 8.8.8.8
  nameserver[2] : 1.1.1.1
  nameserver[3] : 9.9.9.9
  nameserver[4] : 4.4.4.4

"""

private let networkQualitySample = """
{
  "base_rtt" : 12.5,
  "dl_flows" : 16,
  "dl_responsiveness" : 1480,
  "dl_throughput" : 245678901,
  "interface_name" : "en0",
  "responsiveness" : 1480,
  "ul_responsiveness" : 1210,
  "ul_throughput" : 23456789
}
"""

private let digASample = """
www.example.com.
93.184.216.34

"""

private let digMXSample = """
10 mail.example.com.
20 mail2.example.com.

"""

private let wifiInfo = NetworkInfo(localIP: "192.168.178.20", subnet: "192.168.178.0/24", router: "192.168.178.1")

private func fakeWithLan() -> FakeNetworkSystem {
  let f = FakeNetworkSystem()
  f.addresses = [LocalAddress(interface: "en0", ip: "192.168.178.20", netmask: "255.255.255.0")]
  f.runs["/sbin/route -n get default"] = ProcessOutput(status: 0, stdout: routeSample)
  f.runs["/usr/sbin/scutil --dns"] = ProcessOutput(status: 0, stdout: scutilSample)
  return f
}

enum NetworkChecksImpl {
  static let addressChecks: [CheckCase] = [
    CheckCase("Netz: private IPv4-Bereiche (10/8, 172.16/12, 192.168/16, 169.254/16, 127/8)") {
      for ip in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.178.1", "169.254.10.10", "127.0.0.1"] {
        try expect(NetworkAddress.isPrivate(ip), "\(ip) sollte privat sein")
      }
    },
    CheckCase("Netz: Grenzfälle 172.15, 172.32 und öffentliche IPs sind nicht privat") {
      try expect(!NetworkAddress.isPrivate("172.15.255.255"), "172.15 ist öffentlich")
      try expect(!NetworkAddress.isPrivate("172.32.0.1"), "172.32 ist öffentlich")
      try expect(!NetworkAddress.isPrivate("8.8.8.8"), "8.8.8.8 ist öffentlich")
      try expect(!NetworkAddress.isPrivate("1.1.1.1"), "1.1.1.1 ist öffentlich")
    },
    CheckCase("Netz: IPv6 fe80::/10, ::1, fc00::/7 privat; globale Adresse nicht") {
      try expect(NetworkAddress.isPrivate("fe80::1%en0"), "Link-lokal")
      try expect(NetworkAddress.isPrivate("::1"), "Loopback")
      try expect(NetworkAddress.isPrivate("fd00::1"), "ULA")
      try expect(!NetworkAddress.isPrivate("2001:4860:4860::8888"), "globale Adresse")
    },
    CheckCase("Netz: Namen auf .local und localhost sind privat, fremde Namen nicht") {
      try expect(NetworkAddress.isPrivate("nas.local"), "nas.local")
      try expect(NetworkAddress.isPrivate("localhost"), "localhost")
      try expect(!NetworkAddress.isPrivate("example.com"), "example.com")
      try expect(!NetworkAddress.isPrivate("nas.local.evil.com"), "Suffix-Täuschung")
    },
    CheckCase("Netz: Teilnetz /24 liefert 254 Hosts ohne Netz- und Broadcast-Adresse") {
      let hosts = NetworkAddress.subnetHosts(ip: "192.168.178.20", mask: "255.255.255.0")
      try expectEqual(hosts.count, 254)
      try expectEqual(hosts.first, "192.168.178.1")
      try expectEqual(hosts.last, "192.168.178.254")
    },
    CheckCase("Netz: größeres Netz (/16) wird auf das /24 um die IP begrenzt") {
      let hosts = NetworkAddress.subnetHosts(ip: "10.0.5.7", mask: "255.255.0.0")
      try expectEqual(hosts.count, 254)
      try expectEqual(hosts.first, "10.0.5.1")
      try expectEqual(hosts.last, "10.0.5.254")
    },
    CheckCase("Netz: kleines Teilnetz (/26) und /32 ohne Hosts") {
      let hosts = NetworkAddress.subnetHosts(ip: "192.168.1.70", mask: "255.255.255.192")
      try expectEqual(hosts.count, 62)
      try expectEqual(hosts.first, "192.168.1.65")
      try expectEqual(hosts.last, "192.168.1.126")
      try expectEqual(NetworkAddress.subnetHosts(ip: "192.168.1.70", mask: "255.255.255.255").count, 0)
    },
    CheckCase("Netz: CIDR-Schreibweise und ungültige Netzmaske") {
      try expectEqual(NetworkAddress.cidr(ip: "192.168.178.45", mask: "255.255.255.0"), "192.168.178.0/24")
      try expect(NetworkAddress.cidr(ip: "192.168.178.45", mask: "255.0.255.0") == nil, "Maske nicht zusammenhängend")
    },
    CheckCase("Netz: MAC-Normalisierung (führende Nullen, Trennzeichen, ungültige Form)") {
      try expectEqual(NetworkAddress.normalizeMAC("0:1b:2c:3d:4e:5f"), "00:1b:2c:3d:4e:5f")
      try expectEqual(NetworkAddress.normalizeMAC("00-1B-2C-3D-4E-5F"), "00:1b:2c:3d:4e:5f")
      try expect(NetworkAddress.normalizeMAC("00:1b:2c") == nil, "zu kurz")
      try expect(NetworkAddress.normalizeMAC("zz:1b:2c:3d:4e:5f") == nil, "keine Hex-Ziffern")
    },
    CheckCase("Netz: DNS-Namen strikt geprüft; Injektion wird abgelehnt") {
      try expect(NetworkAddress.isValidDNSName("example.com"), "gültiger Name")
      try expect(NetworkAddress.isValidDNSName("nas-01.fritz.box"), "Bindestrich in der Mitte")
      try expect(!NetworkAddress.isValidDNSName("; rm -rf /"), "Semikolon und Leerzeichen")
      try expect(!NetworkAddress.isValidDNSName("-x.com"), "führender Bindestrich (Option)")
      try expect(!NetworkAddress.isValidDNSName("$(whoami).com"), "Befehlsersetzung")
      try expect(!NetworkAddress.isValidDNSName("a b"), "Leerzeichen")
      try expect(!NetworkAddress.isValidDNSName(""), "leer")
    },
  ]

  static let vendorChecks: [CheckCase] = [
    CheckCase("Hersteller: Apple, Raspberry Pi (Großschreibung egal), unbekannt bleibt leer") {
      try expectEqual(OUIVendors.vendor(forMAC: "a4:5e:60:00:00:01"), "Apple")
      try expectEqual(OUIVendors.vendor(forMAC: "B8:27:EB:12:34:56"), "Raspberry Pi")
      try expect(OUIVendors.vendor(forMAC: "00:00:01:02:03:04") == nil, "unbekannter Präfix")
      try expect(OUIVendors.vendor(forMAC: "nicht-eine-mac") == nil, "ungültige MAC")
    },
    CheckCase("Hersteller: zufällige (lokal verwaltete) MACs werden erkannt") {
      try expectEqual(OUIVendors.vendor(forMAC: "da:a1:19:00:00:02"), OUIVendors.randomizedLabel)
      try expectEqual(OUIVendors.vendor(forMAC: "fe:ff:ff:00:00:01"), OUIVendors.randomizedLabel)
      try expectEqual(OUIVendors.vendor(forMAC: "d6:00:00:00:00:01"), OUIVendors.randomizedLabel)
    },
    CheckCase("Hersteller: Tabelle hat mindestens 80 Präfixe") {
      try expect(OUIVendors.table.count >= 80, "nur \(OUIVendors.table.count) Präfixe")
    },
  ]

  static let parserChecks: [CheckCase] = [
    CheckCase("Parser arp -an: gültige Einträge, Namen; unvollständig, Broadcast, Multicast fallen weg") {
      let entries = NetworkParsers.arpEntries(arpSample)
      try expectEqual(entries.map(\.ip), ["192.168.178.1", "192.168.178.30", "192.168.178.40"])
      try expectEqual(entries[0].mac, "00:1b:2f:11:22:33")
      try expectEqual(entries[0].interface, "en0")
      try expect(entries[0].name == nil, "ohne Namen")
      try expectEqual(entries[1].name, "nas.fritz.box")
      try expectEqual(entries[2].mac, "b8:27:eb:12:34:56")
    },
    CheckCase("Parser ping: Erfolg mit Zeiten und IP aus der Kopfzeile") {
      let r = NetworkParsers.ping(host: "192.168.178.1", output: pingOKSample)
      try expectEqual(r.ip, "192.168.178.1")
      try expectEqual(r.sent, 3)
      try expectEqual(r.received, 3)
      try expectEqual(r.minMs, 2.110)
      try expectEqual(r.avgMs, 2.442)
      try expectEqual(r.maxMs, 2.871)
    },
    CheckCase("Parser ping: 100 % Verlust ohne Zeiten") {
      let r = NetworkParsers.ping(host: "10.0.0.99", output: pingLossSample)
      try expectEqual(r.sent, 3)
      try expectEqual(r.received, 0)
      try expect(r.minMs == nil && r.avgMs == nil && r.maxMs == nil, "keine Zeiten bei Verlust")
    },
    CheckCase("Parser route -n get default: Schnittstelle und Router") {
      let route = NetworkParsers.defaultRoute(routeSample)
      try expectEqual(route, NetworkParsers.DefaultRoute(interface: "en0", gateway: "192.168.178.1"))
      try expect(NetworkParsers.defaultRoute("route: not in table") == nil, "ohne Schnittstelle nil")
    },
    CheckCase("Parser scutil --dns: DNS-Server ohne Doppelte, höchstens vier") {
      try expectEqual(NetworkParsers.dnsServers(scutilSample), ["192.168.178.1", "fd00::1", "8.8.8.8", "1.1.1.1"])
    },
    CheckCase("Parser networkQuality -c: Bit/s in Mbit/s, Reaktionsfähigkeit") {
      let s = try expectNotNil(NetworkParsers.speed(json: networkQualitySample, testedAt: "2024-03-04T08:00"))
      try expect(abs(s.downMbps - 245.678901) < 0.0001, "Download \(s.downMbps)")
      try expect(abs(s.upMbps - 23.456789) < 0.0001, "Upload \(s.upMbps)")
      try expectEqual(s.responsiveness, 1480)
      try expectEqual(s.testedAt, "2024-03-04T08:00")
    },
    CheckCase("Parser networkQuality: kaputtes JSON ergibt nil") {
      try expect(NetworkParsers.speed(json: "{ kaputt", testedAt: "t") == nil, "ungültiges JSON")
      try expect(NetworkParsers.speed(json: "{\"foo\": 1}", testedAt: "t") == nil, "ohne Durchsatz")
    },
    CheckCase("Parser dig +short: Adressen und CNAME; MX-Zeilen ohne Schlusspunkt") {
      let a = NetworkParsers.digAddresses(digASample)
      try expectEqual(a.addresses, ["93.184.216.34"])
      try expectEqual(a.cname, "www.example.com")
      try expectEqual(NetworkParsers.digRecords(digMXSample), ["10 mail.example.com", "20 mail2.example.com"])
    },
  ]

  static let toolChecks: [CheckCase] = [
    CheckCase("Ping: Eingabe mit Leerzeichen oder Befehlszeichen wird abgelehnt, ohne Prozess") {
      let fake = FakeNetworkSystem()
      let r = await Pinger.ping(host: "8.8.8.8; rm -rf /", system: fake)
      try expectEqual(r.errorMessage != nil, true, "muss abgelehnt werden")
      try expectEqual(fake.runCalls.count, 0, "kein Prozess darf starten")
    },
    CheckCase("DNS-Abfrage: ungültiger Name startet keinen Prozess") {
      let fake = FakeNetworkSystem()
      let r = await DnsLookup.lookup(name: "-x $(id)", system: fake)
      try expect(r.errorMessage != nil, "muss abgelehnt werden")
      try expectEqual(fake.runCalls.count, 0, "kein Prozess")
    },
    CheckCase("DNS-Abfrage: gültiger Name ruft dig mit getrennten Argumenten auf") {
      let fake = FakeNetworkSystem()
      fake.runs["/usr/bin/dig +short A example.com"] = ProcessOutput(status: 0, stdout: digASample)
      fake.runs["/usr/bin/dig +short MX example.com"] = ProcessOutput(status: 0, stdout: digMXSample)
      let looked = await DnsLookup.lookup(name: "example.com", system: fake)
      let r = try expectNotNil(looked.value)
      try expectEqual(r.a, ["93.184.216.34"])
      try expectEqual(r.cname, "www.example.com")
      try expectEqual(r.mx.count, 2)
    },
    CheckCase("Port-Check: öffentliche IP wird mit der Meldung abgelehnt, ohne Verbindungsversuch") {
      let fake = FakeNetworkSystem()
      let r = await PortChecker.check(host: "8.8.8.8", ports: [22, 80], system: fake)
      try expectEqual(r.errorMessage, PortChecker.refusal)
      try expectEqual(fake.tcpCalls.count, 0, "keine Verbindung")
    },
    CheckCase("Port-Check: Name, der auf eine öffentliche Adresse zeigt, wird abgelehnt") {
      let fake = FakeNetworkSystem()
      fake.resolveMap["example.com"] = ["93.184.216.34"]
      let r = await PortChecker.check(host: "example.com", ports: [443], system: fake)
      try expectEqual(r.errorMessage, PortChecker.refusal)
      try expectEqual(fake.tcpCalls.count, 0, "keine Verbindung")
    },
    CheckCase("Port-Check: .local-Name und Name mit privater Auflösung sind erlaubt") {
      let fake = FakeNetworkSystem()
      fake.openPorts = [22]
      fake.resolveMap["printer.lan"] = ["192.168.1.50"]
      let localCheck = await PortChecker.check(host: "nas.local", ports: [22, 80], system: fake)
      let local = try expectNotNil(localCheck.value)
      try expectEqual(local.map(\.open), [true, false])
      try expectEqual(local[0].service, "SSH")
      let lanCheck = await PortChecker.check(host: "printer.lan", ports: [22], system: fake)
      let lan = try expectNotNil(lanCheck.value)
      try expectEqual(lan.count, 1)
    },
    CheckCase("Port-Check: Grenzen (höchstens 20 Ports, Bereich 1 bis 65535)") {
      let fake = FakeNetworkSystem()
      let tooMany = await PortChecker.check(host: "192.168.1.5", ports: Array(1...21), system: fake)
      try expectEqual(tooMany.errorMessage, "Höchstens 20 Ports pro Prüfung.")
      let zero = await PortChecker.check(host: "192.168.1.5", ports: [0], system: fake)
      try expect(zero.errorMessage != nil, "Port 0 ist ungültig")
      try expectEqual(fake.tcpCalls.count, 0, "keine Verbindung bei ungültigen Eingaben")
    },
    CheckCase("Wake-on-LAN: Magic Packet hat 102 Byte: 6 × FF, dann 16 × MAC") {
      let packet = try expectNotNil(WakeOnLan.magicPacket(mac: "00:1b:2f:11:22:33"))
      try expectEqual(packet.count, 102)
      try expectEqual(Array(packet[0..<6]), [UInt8](repeating: 0xFF, count: 6))
      let mac: [UInt8] = [0x00, 0x1b, 0x2f, 0x11, 0x22, 0x33]
      for block in 0..<16 {
        let start = 6 + block * 6
        try expectEqual(Array(packet[start..<start + 6]), mac, "Block \(block)")
      }
    },
    CheckCase("Wake-on-LAN: ungültige MAC wird abgelehnt, gültige sendet Broadcast auf Port 9") {
      try expect(WakeOnLan.magicPacket(mac: "00:1b:2f") == nil, "zu kurz")
      try expect(WakeOnLan.magicPacket(mac: "00:00:00:00:00:00") == nil, "Null-MAC")
      let fake = FakeNetworkSystem()
      let bad = WakeOnLan.send(mac: "xx", system: fake)
      try expectEqual(bad.errorMessage != nil, true, "muss abgelehnt werden")
      try expectEqual(fake.udpSent.count, 0, "nichts gesendet")
      let ok = WakeOnLan.send(mac: "00:1b:2f:11:22:33", system: fake)
      try expect(ok.isOk, "gültige MAC")
      try expect(fake.udpSent.contains { $0.ip == "255.255.255.255" && $0.port == 9 && $0.count == 102 }, "Broadcast 102 Byte")
    },
    CheckCase("Geschwindigkeit: Auswertung über Attrappe, Fehlerstatus wird gemeldet") {
      let fake = FakeNetworkSystem()
      fake.runs["/usr/bin/networkQuality -c"] = ProcessOutput(status: 0, stdout: networkQualitySample)
      let speedCheck = await SpeedTester.run(clock: ControllableClock("2024-03-04T08:00"), system: fake)
      let ok = try expectNotNil(speedCheck.value)
      try expectEqual(ok.testedAt, "2024-03-04T08:00")
      let bad = await SpeedTester.run(system: FakeNetworkSystem())
      try expect(bad.errorMessage != nil, "Fehlerstatus")
    },
  ]

  static let repositoryChecks: [CheckCase] = [
    CheckCase("Geräte: erster Scan trennt neue unbekannte Geräte; Router und dieser Mac sind automatisch bekannt") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let scan = [
        ScannedHost(ip: "192.168.178.1", mac: "00:1b:2f:11:22:33"),
        ScannedHost(ip: "192.168.178.20", mac: "a4:5e:60:00:00:01", hostname: "Felix-MBP"),
        ScannedHost(ip: "192.168.178.40", mac: "b8:27:eb:12:34:56", hostname: "raspberrypi"),
        ScannedHost(ip: "192.168.178.50", mac: "da:a1:19:00:00:02"),
      ]
      let result = try store.networkDevices.merge(scanned: scan, info: wifiInfo, now: "2024-03-04T08:00")
      try expectEqual(result.all.count, 4)
      try expect(result.all[0].isRouter, "Router zuerst")
      try expect(result.all[1].isThisMac, "dieser Mac an zweiter Stelle")
      try expectEqual(result.new.map(\.ip), ["192.168.178.40", "192.168.178.50"])
      try expectEqual(result.new[0].vendor, "Raspberry Pi")
      try expectEqual(result.new[1].vendor, OUIVendors.randomizedLabel)
    },
    CheckCase("Geräte: eigener Name bleibt beim nächsten Scan; IP-Wechsel wird übernommen; nichts wird erneut neu") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.40", mac: "b8:27:eb:12:34:56", hostname: "raspberrypi")],
        info: wifiInfo, now: "2024-03-04T08:00")
      _ = try expectNotNil(try store.networkDevices.update(id: "b8:27:eb:12:34:56", name: "Pi im Keller"))
      let second = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.41", mac: "B8:27:EB:12:34:56", hostname: "pi-neu")],
        info: wifiInfo, now: "2024-03-05T09:00")
      try expectEqual(second.all.count, 1)
      try expectEqual(second.all[0].name, "Pi im Keller")
      try expectEqual(second.all[0].ip, "192.168.178.41")
      try expectEqual(second.all[0].firstSeen, "2024-03-04T08:00")
      try expectEqual(second.all[0].lastSeen, "2024-03-05T09:00")
      try expect(second.new.isEmpty, "bekanntes Gerät ist nicht neu")
    },
    CheckCase("Geräte: im letzten Scan gesehen = online, fehlt es = offline") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.50", mac: "aa:bb:cc:00:00:01", hostname: "laptop"),
                  ScannedHost(ip: "192.168.178.51", mac: "aa:bb:cc:00:00:02", hostname: "drucker")],
        info: wifiInfo, now: "2024-03-04T08:00")
      let second = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.50", mac: "aa:bb:cc:00:00:01", hostname: "laptop")],
        info: wifiInfo, now: "2024-03-04T09:00")
      let laptop = try expectNotNil(second.all.first { $0.id == "aa:bb:cc:00:00:01" })
      let drucker = try expectNotNil(second.all.first { $0.id == "aa:bb:cc:00:00:02" })
      try expect(laptop.online, "im Scan gesehen → online")
      try expect(!drucker.online, "nicht geantwortet → offline")
      let listed = try expectNotNil(try store.networkDevices.list(info: wifiInfo).first { $0.id == "aa:bb:cc:00:00:02" })
      try expect(!listed.online, "gilt auch für list(), nicht nur direkt nach merge()")
    },
    CheckCase("Geräte: ohne MAC wird über die IP wiedererkannt, danach mit MAC gespeichert") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let first = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.60")], info: wifiInfo, now: "2024-03-04T08:00")
      try expectEqual(first.new.map(\.id), ["192.168.178.60"])
      let second = try store.networkDevices.merge(
        scanned: [ScannedHost(ip: "192.168.178.60", mac: "3c:5a:b4:00:00:09")],
        info: wifiInfo, now: "2024-03-04T09:00")
      try expectEqual(second.all.count, 1, "kein Doppelgänger")
      try expectEqual(second.all[0].id, "3c:5a:b4:00:00:09")
      try expect(second.new.isEmpty, "nicht erneut neu")
    },
    CheckCase("Geräte: Reihenfolge Router, dieser Mac, dann IP numerisch; update setzt bekannt") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.networkDevices.merge(scanned: [
        ScannedHost(ip: "192.168.178.100", mac: "00:1b:2f:00:00:01"),
        ScannedHost(ip: "192.168.178.9", mac: "00:1b:2f:00:00:02"),
        ScannedHost(ip: "192.168.178.1", mac: "00:1b:2f:00:00:03"),
        ScannedHost(ip: "192.168.178.20", mac: "a4:5e:60:00:00:01"),
      ], info: wifiInfo, now: "2024-03-04T08:00")
      let ips = try store.networkDevices.list(info: wifiInfo).map(\.ip)
      try expectEqual(ips, ["192.168.178.1", "192.168.178.20", "192.168.178.9", "192.168.178.100"])
      let updated = try expectNotNil(try store.networkDevices.update(id: "00:1b:2f:00:00:02", known: true, info: wifiInfo))
      try expect(updated.known, "als bekannt markiert")
      try expect(try store.networkDevices.update(id: "gibt-es-nicht", name: "x") == nil, "unbekannte ID")
    },
    CheckCase("Netz: Wechsel A→B zeigt nur B; bekanntes Gerät von A bleibt verborgen; zurück in A ist es wieder da") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      let infoB = NetworkInfo(localIP: "192.168.2.20", subnet: "192.168.2.0/24", router: "192.168.2.1")
      let routerA = ScannedHost(ip: "192.168.178.1", mac: "00:1b:2f:11:22:33")
      _ = try store.networkDevices.merge(scanned: [
        routerA,
        ScannedHost(ip: "192.168.178.10", mac: "aa:00:00:00:00:01"),
        ScannedHost(ip: "192.168.178.11", mac: "aa:00:00:00:00:02"),
        ScannedHost(ip: "192.168.178.12", mac: "aa:00:00:00:00:03"),
      ], info: wifiInfo, now: "2024-03-04T08:00")
      _ = try expectNotNil(try store.networkDevices.update(id: "aa:00:00:00:00:01", known: true))

      let inB = try store.networkDevices.merge(scanned: [
        ScannedHost(ip: "192.168.2.1", mac: "00:1b:2f:99:00:01"),
        ScannedHost(ip: "192.168.2.10", mac: "bb:00:00:00:00:01"),
        ScannedHost(ip: "192.168.2.11", mac: "bb:00:00:00:00:02"),
      ], info: infoB, now: "2024-03-04T09:00")
      // Router B und die zwei Geräte von B; Router B gilt automatisch als bekannt.
      try expectEqual(Set(inB.all.map(\.id)), Set(["00:1b:2f:99:00:01", "bb:00:00:00:00:01", "bb:00:00:00:00:02"]))
      try expectEqual(Set(try store.networkDevices.list(info: infoB).map(\.id)),
                      Set(["00:1b:2f:99:00:01", "bb:00:00:00:00:01", "bb:00:00:00:00:02"]))

      // Zurück in A: das bekannte Gerät ist wieder da; die Geräte von B sind weg.
      let backInA = try store.networkDevices.merge(scanned: [
        routerA,
        ScannedHost(ip: "192.168.178.10", mac: "aa:00:00:00:00:01"),
      ], info: wifiInfo, now: "2024-03-04T10:00")
      try expectEqual(Set(backInA.all.map(\.id)), Set(["00:1b:2f:11:22:33", "aa:00:00:00:00:01"]))
      try expectEqual(Set(try store.networkDevices.list(info: wifiInfo).map(\.id)),
                      Set(["00:1b:2f:11:22:33", "aa:00:00:00:00:01"]))
    },
    CheckCase("Netz: 30 Tage nicht gesehen wird gelöscht, bekannt bleibt; im Netz gesehen bleibt") {
      let store = try Store.inMemory(clock: ControllableClock("2024-03-04T08:00"))
      _ = try store.networkDevices.merge(scanned: [
        ScannedHost(ip: "192.168.178.1", mac: "00:1b:2f:11:22:33"),
        ScannedHost(ip: "192.168.178.30", mac: "cc:00:00:00:00:01", hostname: "alt"),
        ScannedHost(ip: "192.168.178.31", mac: "cc:00:00:00:00:02"),
      ], info: wifiInfo, now: "2024-03-04T08:00")
      _ = try expectNotNil(try store.networkDevices.update(id: "cc:00:00:00:00:02", known: true))
      // 37 Tage später: nur Router und ein neues Gerät gesehen.
      let later = try store.networkDevices.merge(scanned: [
        ScannedHost(ip: "192.168.178.1", mac: "00:1b:2f:11:22:33"),
        ScannedHost(ip: "192.168.178.32", mac: "cc:00:00:00:00:03"),
      ], info: wifiInfo, now: "2024-04-10T08:00")
      try expectEqual(Set(later.all.map(\.id)),
                      Set(["00:1b:2f:11:22:33", "cc:00:00:00:00:02", "cc:00:00:00:00:03"]),
                      "alt und unbekannt gelöscht; bekannt bleibt")
    },
  ]

  static let watchChecks: [CheckCase] = [
    CheckCase("Wächter: erste Momentaufnahme meldet nichts; Abbruch und Rückkehr; neues Gerät") {
      var watch = NetworkWatch()
      try expect(watch.evaluate(online: false, newUnknown: []).isEmpty, "Ausgangspunkt ohne Meldung")
      try expect(watch.evaluate(online: true, newUnknown: []).isEmpty, "erste Verbindung nach Start: keine Meldung")
      let drop = watch.evaluate(online: false, newUnknown: [])
      try expectEqual(drop.map(\.title), ["Internet weg"])
      let back = watch.evaluate(online: true, newUnknown: [])
      try expectEqual(back.map(\.title), ["Internet wieder da"])
      var fresh = NetworkWatch()
      _ = fresh.evaluate(online: true, newUnknown: [])
      let pi = NetworkDevice(id: "b8:27:eb:12:34:56", ip: "192.168.178.40", vendor: "Raspberry Pi",
                             firstSeen: "x", lastSeen: "x")
      let note = fresh.evaluate(online: true, newUnknown: [pi])
      try expectEqual(note.count, 1)
      try expectEqual(note[0].body, "Raspberry Pi (192.168.178.40)")
      try expectEqual(note[0].title, "Neues Gerät im WLAN")
    },
    CheckCase("Wächter: ohne vorherigen Abbruch keine Rückkehr-Meldung") {
      var watch = NetworkWatch()
      _ = watch.evaluate(online: false, newUnknown: [])
      try expect(watch.evaluate(online: true, newUnknown: []).isEmpty, "nie abgebrochen")
    },
  ]

  static let lookupChecks: [CheckCase] = [
    CheckCase("Netz: hängende Namensauflösung liefert nach dem Zeitlimit nil, schnelle bleibt erhalten") {
      let started = Date()
      let slow = await SystemNetwork.boundedLookup(timeout: 0.3) { Thread.sleep(forTimeInterval: 3); return "spaet.local" }
      let took = Date().timeIntervalSince(started)
      try expect(slow == nil, "nach Zeitlimit kein Ergebnis")
      try expect(took < 1.5, "kehrt nach \(took) s zurück, nicht erst nach 3 s")
      let fast = await SystemNetwork.boundedLookup(timeout: 2) { "pi.local" }
      try expectEqual(fast, "pi.local")
    },
  ]

  static let systemChecks: [CheckCase] = [
    CheckCase("Netz-Stand (Attrappe): Schnittstelle, Teilnetz, Router, DNS und Online-Zustand") {
      let fake = fakeWithLan()
      fake.wifiReading = nil
      let info = await WifiInfoProvider(system: fake).current()
      try expectEqual(info.localIP, "192.168.178.20")
      try expectEqual(info.subnet, "192.168.178.0/24")
      try expectEqual(info.router, "192.168.178.1")
      try expectEqual(info.dns, ["192.168.178.1", "fd00::1", "8.8.8.8", "1.1.1.1"])
      try expectEqual(info.interfaceName, "Ethernet")
      try expect(info.ssid == nil && info.ssidHint == nil, "ohne WLAN keine SSID-Hinweise")
      try expect(info.online, "online laut Attrappe")
    },
    CheckCase("Netz-Stand (Attrappe): WLAN ohne SSID-Recht zeigt den Hinweis") {
      let fake = fakeWithLan()
      fake.wifiReading = WifiReading(interfaceName: "en0", ssid: nil, rssi: -54, noise: -90, channel: 36,
                                     band: "5 GHz", txRate: 866)
      let info = await WifiInfoProvider(system: fake).current()
      try expectEqual(info.interfaceName, "WLAN")
      try expectEqual(info.ssidHint, WifiInfoProvider.ssidHint)
      try expectEqual(info.rssi, -54)
      try expectEqual(info.band, "5 GHz")
    },
    CheckCase("Scan (Attrappe): Hosts aus ARP, Router und dieser Mac ergänzt, Bonjour-Name übernommen") {
      let fake = fakeWithLan()
      fake.runs["/usr/sbin/arp -an"] = ProcessOutput(status: 0, stdout: arpSample)
      fake.bonjour = [BonjourHit(name: "Wohnzimmer TV", ip: "192.168.178.40")]
      fake.reverse = ["192.168.178.40": "pi.local"]
      let info = NetworkInfo(localIP: "192.168.178.20", subnet: "192.168.178.0/24", router: "192.168.178.1")
      let hosts = await NetworkScanner(system: fake).scan(info: info)
      try expectEqual(hosts.map(\.ip), ["192.168.178.1", "192.168.178.20", "192.168.178.30", "192.168.178.40"])
      try expectEqual(hosts[3].hostname, "Wohnzimmer TV")
      try expect(hosts[1].mac == nil, "dieser Mac ohne ARP-Eintrag")
      try expectEqual(fake.udpSent.count, 254)
    },
    CheckCase("Scan: öffentliches Netz wird nicht gescannt") {
      let fake = FakeNetworkSystem()
      let info = NetworkInfo(localIP: "8.8.8.8", subnet: "8.8.8.0/24")
      let hosts = await NetworkScanner(system: fake).scan(info: info)
      try expect(hosts.isEmpty, "kein Scan")
      try expectEqual(fake.udpSent.count, 0, "keine Pakete")
    },
    CheckCase("Smoke: WifiInfoProvider liefert innerhalb von 5 s (echtes System, ohne Prüfung der Werte)") {
      let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
        group.addTask {
          _ = await WifiInfoProvider().current()
          return true
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: 5_000_000_000)
          return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
      }
      try expect(finished, "Netz-Stand kam nicht innerhalb von 5 s")
    },
  ]
}

public enum NetworkChecks {
  @MainActor public static var suite: CheckSuite {
    CheckSuite("Netzwerk",
               NetworkChecksImpl.addressChecks + NetworkChecksImpl.vendorChecks + NetworkChecksImpl.parserChecks
                 + NetworkChecksImpl.toolChecks + NetworkChecksImpl.repositoryChecks + NetworkChecksImpl.watchChecks + NetworkChecksImpl.lookupChecks
                 + NetworkChecksImpl.systemChecks)
  }
}
