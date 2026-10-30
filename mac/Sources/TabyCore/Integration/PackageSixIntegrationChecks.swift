// Paket 6 gegen den echten Kern mit einem Test-Netzwerk (FakeNetworkSystem).
import Foundation

enum PackageSixIntegrationChecks {
  @MainActor static func rig() throws -> (CoreServices, FakeNetworkSystem, IntegrationEventLog, ControllableClock) {
    let fake = FakeNetworkSystem()
    let clock = ControllableClock("2026-10-12T08:00")
    var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: clock,
                                    keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
                                    plannerInterval: nil)
    opts.networkSystem = fake
    let svc = try CoreServices(options: opts)
    let log = IntegrationEventLog()
    svc.subscribe { log.record($0) }
    return (svc, fake, log, clock)
  }

  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration Paket 6", [
      CheckCase("Netzwerk aus: alles verweigert, kein Systemaufruf, kein Zustand") {
        let (svc, fake, _, _) = try rig()
        let ping = await svc.ping("192.168.1.1")
        let scan = await svc.scanNetwork()
        try expect(!ping.isOk && !scan.isOk, "verweigert")
        try expect(fake.runCalls.isEmpty, "kein Aufruf: \(fake.runCalls)")
        let state = await svc.state()
        try expect(state.network == nil, "kein Netzwerk-Zustand")
      },

      CheckCase("Netzwerk an: Zustand da, Port-Check gegen fremde Adresse verweigert") {
        let (svc, fake, _, _) = try rig()
        _ = await svc.updateSettings(SettingsPatch(networkToolsEnabled: true), apiKey: nil)
        _ = await svc.refreshNetworkInfo()
        let state = await svc.state()
        try expect(state.network != nil, "Zustand")
        let ports = await svc.checkPorts("8.8.8.8", ports: [22])
        try expect(ports.errorMessage?.contains("eigenen Netz") == true, ports.errorMessage ?? "ok?")
        try expect(fake.tcpCalls.isEmpty, "keine Verbindung zu fremdem Rechner")
      },

      CheckCase("Wächter: erst ab Einschalten, meldet Internet weg und wieder da") {
        let (svc, fake, log, clock) = try rig()
        _ = await svc.updateSettings(SettingsPatch(networkToolsEnabled: true), apiKey: nil)
        await svc.networkWatchTick()
        try expect(log.flashes.isEmpty, "Wächter aus → nichts")
        _ = await svc.updateSettings(SettingsPatch(networkWatch: true), apiKey: nil)
        await svc.networkWatchTick()  // erster Stand: keine Meldung
        fake.online = false
        clock.set(clock.now().addingTimeInterval(61))
        await svc.networkWatchTick()
        fake.online = true
        clock.set(clock.now().addingTimeInterval(61))
        await svc.networkWatchTick()
        let titles = log.flashes.map(\.title)
        try expectEqual(titles.count, 2, "\(titles)")
      },

      CheckCase("Wächter: UI-Neuladen nur bei Neuigkeit oder Scan, ruhiger Takt lädt nicht neu") {
        let (svc, fake, log, clock) = try rig()
        _ = await svc.updateSettings(SettingsPatch(networkToolsEnabled: true, networkWatch: true), apiKey: nil)
        @MainActor func reloads() -> Int { log.events.filter { if case .stateChanged = $0 { return true }; return false }.count }
        let base = reloads()  // Einschalten selbst darf zählen; gezählt wird ab hier
        await svc.networkWatchTick()  // erster Takt: Scan läuft, also ein Neuladen
        let afterFirst = reloads() - base
        try expectEqual(afterFirst, 1)
        clock.set(clock.now().addingTimeInterval(61))
        await svc.networkWatchTick()  // ruhig: kein Scan (10 min), keine Meldung
        try expectEqual(reloads() - base, afterFirst, "ruhiger Takt darf nicht neu laden")
        fake.online = false
        clock.set(clock.now().addingTimeInterval(61))
        await svc.networkWatchTick()  // Internet weg: Meldung und Neuladen
        try expectEqual(reloads() - base, afterFirst + 1, "Internetverlust muss neu laden")
        try expectEqual(log.flashes.map(\.title), ["Internet weg"])
      },
    ])
  }
}
