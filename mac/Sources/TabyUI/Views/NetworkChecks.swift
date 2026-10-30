// Prüfungen und Snapshots für Paket 6 (Netzwerk-Reiter, Geburtstag, Netzwerk-
// Einstellungen). Logik ohne Fenster, Ansichten als PNG (ImageRenderer).
import SwiftUI
import TabyCore

enum NetworkChecks {
  static let today = "2026-10-11"

  @MainActor static var cases: [CheckCase] {
    logicCases + birthdayCases + actionCases
  }

  // MARK: - Reine Logik

  @MainActor static var logicCases: [CheckCase] {
    [
      CheckCase("Netzwerk: Signal in Balken und Qualitätswort") {
        try expectEqual(NetworkLogic.signalBars(-40), 4)
        try expectEqual(NetworkLogic.signalBars(-54), 3)
        try expectEqual(NetworkLogic.signalBars(-65), 2)
        try expectEqual(NetworkLogic.signalBars(-80), 1)
        try expectEqual(NetworkLogic.signalBars(nil), 0)
        try expectEqual(NetworkLogic.signalQuality(-40), "sehr gut")
        try expectEqual(NetworkLogic.signalQuality(-54), "gut")
        try expectEqual(NetworkLogic.signalQuality(-65), "mäßig")
        try expectEqual(NetworkLogic.signalQuality(-80), "schwach")
        try expectEqual(NetworkLogic.signalQuality(nil), nil)
      },
      CheckCase("Netzwerk: Zahlen mit Komma (243,5 Mbit/s, Ping 3,4 ms)") {
        try expectEqual(NetworkLogic.mbit(243.5), "243,5")
        try expectEqual(NetworkLogic.mbit(41.2), "41,2")
        try expectEqual(NetworkLogic.mbit(0), "0,0")
        let ok = PingResult(host: "fritz.box", ip: "192.168.178.1", sent: 3, received: 3, minMs: 2.1, avgMs: 3.4,
                            maxMs: 5.0)
        try expectEqual(NetworkLogic.pingSummary(ok), "3/3 · Ø 3,4 ms")
        let lost = PingResult(host: "192.168.178.99", sent: 3, received: 0)
        try expectEqual(NetworkLogic.pingSummary(lost), "0/3 · keine Antwort")
        try expectEqual(NetworkLogic.portLine(PortResult(port: 22, open: true, service: "SSH")), "22 · SSH · offen")
        try expectEqual(NetworkLogic.portLine(PortResult(port: 445, open: false, service: "SMB")),
                        "445 · SMB · geschlossen")
      },
      CheckCase("Netzwerk: WLAN-Titel, Kanal und Online-Anzeige") {
        let named = NetworkInfo(ssid: "FRITZ!Box 7590", rssi: -54, channel: 44, band: "5 GHz", interfaceName: "WLAN",
                                online: true)
        try expectEqual(NetworkLogic.wlanTitle(named), "FRITZ!Box 7590")
        try expectEqual(NetworkLogic.channelLine(named), "Kanal 44 · 5 GHz")
        let hidden = NetworkInfo(ssidHint: "Ortungsdienste erlauben", interfaceName: "WLAN")
        try expectEqual(NetworkLogic.wlanTitle(hidden), "WLAN-Name unbekannt")
        let cable = NetworkInfo(interfaceName: "Ethernet")
        try expectEqual(NetworkLogic.wlanTitle(cable), "Kabelverbindung")
        try expectEqual(NetworkLogic.channelLine(cable), nil)
        try expectEqual(NetworkLogic.onlineChip(named)?.text, "Online")
        try expectEqual(NetworkLogic.onlineChip(NetworkInfo(interfaceName: "WLAN"))?.text, "Offline")
        try expectEqual(NetworkLogic.onlineChip(nil)?.text, nil)
      },
      CheckCase("Netzwerk: Gerätesymbol nach Art und Name") {
        let seen = "\(today)T08:55"
        func dev(_ name: String?, _ vendor: String?, router: Bool = false) -> NetworkDevice {
          NetworkDevice(id: name ?? vendor ?? "x", ip: "192.168.178.2", name: name, vendor: vendor, isRouter: router,
                        firstSeen: seen, lastSeen: seen)
        }
        try expectEqual(NetworkLogic.deviceSymbol(dev("fritz.box", "AVM", router: true)), "wifi.router")
        try expectEqual(NetworkLogic.deviceSymbol(dev(nil, "Raspberry Pi")), "cpu")
        try expectEqual(NetworkLogic.deviceSymbol(dev("iPhone", "Apple")), "iphone")
        try expectEqual(NetworkLogic.deviceSymbol(dev("Felix MacBook Pro", "Apple")), "laptopcomputer")
        try expectEqual(NetworkLogic.deviceSymbol(dev("Drucker Büro", nil)), "printer")
        try expectEqual(NetworkLogic.deviceSymbol(dev("Smart-TV", "Samsung")), "desktopcomputer")
        try expectEqual(NetworkLogic.deviceSymbol(dev(nil, nil)), "questionmark.circle")
        try expectEqual(NetworkLogic.deviceTitle(dev(nil, nil)), "Unbekanntes Gerät")
        try expectEqual(NetworkLogic.deviceSubtitle(dev(nil, "AVM")), "AVM · 192.168.178.2")
        try expectEqual(NetworkLogic.deviceSubtitle(dev(nil, nil)), "192.168.178.2")
      },
      CheckCase("Netzwerk: Abzeichen Neu/Unbekannt, bekannte ohne Abzeichen") {
        var fresh = NetworkDevice(id: "a", ip: "192.168.178.9", firstSeen: "\(today)T08:00", lastSeen: "")
        try expectEqual(NetworkLogic.badge(fresh, today: today), "Neu")
        fresh.firstSeen = "2026-10-01T08:00"
        try expectEqual(NetworkLogic.badge(fresh, today: today), "Unbekannt")
        fresh.known = true
        try expectEqual(NetworkLogic.badge(fresh, today: today), nil)
      },
      CheckCase("Netzwerk: Reihenfolge Router, dieser Mac, dann IP zahlenweise") {
        let seen = "\(today)T08:00"
        let devices = [
          NetworkDevice(id: "c", ip: "192.168.178.40", firstSeen: seen, lastSeen: seen),
          NetworkDevice(id: "d", ip: "192.168.178.10", firstSeen: seen, lastSeen: seen),
          NetworkDevice(id: "e", ip: "192.168.178.9", firstSeen: seen, lastSeen: seen),
          NetworkDevice(id: "m", ip: "192.168.178.24", isThisMac: true, firstSeen: seen, lastSeen: seen),
          NetworkDevice(id: "r", ip: "192.168.178.1", isRouter: true, firstSeen: seen, lastSeen: seen),
        ]
        try expectEqual(NetworkLogic.sorted(devices).map(\.id), ["r", "m", "e", "d", "c"])
      },
      CheckCase("Netzwerk: DNS-Zeilen ohne leere Gruppen, Host-Eingabe getrimmt") {
        let r = DnsResult(name: "apple.com", a: ["17.1.1.1"], aaaa: [], mx: ["10 mx.example.com"])
        try expectEqual(NetworkLogic.dnsRows(r).map(\.label), ["A", "MX"])
        try expectEqual(NetworkLogic.host("   "), nil)
        try expectEqual(NetworkLogic.host(" 192.168.178.1 "), "192.168.178.1")
      },
    ]
  }

  // MARK: - Geburtstag

  @MainActor static var birthdayCases: [CheckCase] {
    [
      CheckCase("Geburtstag: TT.MM. wird MM-DD gespeichert, leer = keiner, Unsinn = nil") {
        try expectEqual(BirthdayLogic.storedValue("24.12."), "12-24")
        try expectEqual(BirthdayLogic.storedValue("2.2."), "02-02")
        try expectEqual(BirthdayLogic.storedValue("24.12"), "12-24")
        try expectEqual(BirthdayLogic.storedValue("29.02."), "02-29")
        try expectEqual(BirthdayLogic.storedValue("  "), "")
        try expectEqual(BirthdayLogic.storedValue("31.02."), nil)
        try expectEqual(BirthdayLogic.storedValue("24.13."), nil)
        try expectEqual(BirthdayLogic.storedValue("0.5."), nil)
        try expectEqual(BirthdayLogic.storedValue("abc"), nil)
      },
      CheckCase("Geburtstag: Anzeige MM-DD → TT.MM. und Hinweis nur bei Fehlern") {
        try expectEqual(BirthdayLogic.displayValue("12-24"), "24.12.")
        try expectEqual(BirthdayLogic.displayValue("02-02"), "02.02.")
        try expectEqual(BirthdayLogic.displayValue(""), "")
        try expectEqual(BirthdayLogic.displayValue("13-01"), "")
        try expectEqual(BirthdayLogic.validationMessage("24.12."), nil)
        try expectEqual(BirthdayLogic.validationMessage(""), nil)
        try expectEqual(BirthdayLogic.validationMessage("24.00."), BirthdayLogic.invalidMessage)
      },
      CheckCase("Einstellungen: Feiertags-Deko, Geburtstag und Netzwerk-Schalter werden gepatcht") {
        var changed = TabySettings.defaults
        changed.seasonalDecor = false
        changed.birthday = "12-24"
        changed.networkToolsEnabled = true
        changed.networkWatch = true
        let patch = SettingsLogic.patch(from: TabySettings.defaults, to: changed)
        try expectEqual(patch.seasonalDecor, false)
        try expectEqual(patch.birthday, "12-24")
        try expectEqual(patch.networkToolsEnabled, true)
        try expectEqual(patch.networkWatch, true)
        try expectEqual(SettingsLogic.patch(from: TabySettings.defaults, to: TabySettings.defaults).networkToolsEnabled, nil)
        try expectEqual(TabySettings.defaults.networkToolsEnabled, false, "Netzwerk ist standardmäßig aus")
      },
    ]
  }

  // MARK: - Aktionen gegen Fakes

  @MainActor static var actionCases: [CheckCase] {
    [
      CheckCase("Netzwerk: aus → Werkzeuge melden NETWORK_OFF; bekannt markieren ändert nur das Gerät") {
        let fake = FakeServices(sample: false)
        fake.current.settings.networkToolsEnabled = false
        let off = await fake.ping("192.168.178.1")
        try expectEqual(off.errorMessage, "Netzwerk-Werkzeuge sind aus.")
        fake.current.settings.networkToolsEnabled = true
        fake.current.network = fake.sampleNetwork()
        let r = await fake.updateNetworkDevice("b8:27:eb:00:00:04", name: "Pi im Keller", known: true)
        try expect(r.isOk, "Aktualisieren muss gelingen")
        let devices = fake.current.network?.devices ?? []
        try expectEqual(devices.count, 4)
        try expectEqual(devices.first { $0.id == "b8:27:eb:00:00:04" }?.name, "Pi im Keller")
        try expectEqual(devices.first { $0.id == "b8:27:eb:00:00:04" }?.known, true)
        try expectEqual(devices.first { $0.id == "3c:a6:2f:00:00:01" }?.name, "fritz.box")
      },
    ]
  }

  // MARK: - Snapshots

  @MainActor static func networkFake(enabled: Bool = true, withNetwork: Bool = true) -> FakeServices {
    let fake = FakeServices()
    fake.current.settings.networkToolsEnabled = enabled
    fake.current.network = withNetwork ? fake.sampleNetwork() : nil
    return fake
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-network", size: ViewSnapshots.size) {
        let fake = networkFake()
        return wrap(TabContentView(tab: .network, preview: fake.current), AppModel(services: fake))
      },
      SnapshotSpec("view-network-off", size: ViewSnapshots.size) {
        let fake = networkFake(enabled: false, withNetwork: false)
        return wrap(TabContentView(tab: .network, preview: fake.current), AppModel(services: fake))
      },
      // Werkzeuge und aufgeklappte Geräte liegen unter dem Falz: Snapshot mit größerer Grenze.
      SnapshotSpec("view-network-tools-speed", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let fake = networkFake()
        let view = NetworkView(network: fake.current.network, preview: NetworkPreview(tool: .speed))
        return wrap(view.tabyPage(), AppModel(services: fake), cap: 1000)
      },
      SnapshotSpec("view-network-device-open", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let fake = networkFake()
        let view = NetworkView(network: fake.current.network,
                               preview: NetworkPreview(expandedId: "b8:27:eb:00:00:04"))
        return wrap(view.tabyPage(), AppModel(services: fake), cap: 1000)
      },
      SnapshotSpec("view-settings-network", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let fake = networkFake()
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .network)
        view.pageHeight = 360
        return wrap(view.tabyPage(), AppModel(services: fake))
      },
      SnapshotSpec("view-settings-personal", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let fake = networkFake()
        fake.current.settings.birthday = "12-24"
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .assistant)
        view.pageHeight = 360
        return wrap(view.tabyPage(), AppModel(services: fake))
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel,
                                               cap: CGFloat = TabLayout.maxContentHeight) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow("2026-10-11T09:00").environment(\.tabySnapshot, true)
      .environment(\.tabyContentCap, cap))
  }
}
