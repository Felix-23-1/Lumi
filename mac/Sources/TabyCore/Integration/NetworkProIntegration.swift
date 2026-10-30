// Paket 7 im Integrator: gründlicher Scan, Verbindungen, Paket-Mitschnitt,
// eigene Server (docs/decisions/0008-network-pro.md). Teil des optionalen
// Netzwerk-Moduls; nichts läuft, solange `networkToolsEnabled` aus ist.
import Foundation

extension CoreServices {
  private func net7Off<T>() -> ToolResult<T> {
    .failure(code: "NETWORK_OFF", error: "Netzwerk-Werkzeuge sind ausgeschaltet (Einstellungen → Netzwerk, mit „Erweitert anzeigen“).")
  }

  // MARK: Gründlicher Scan

  public func deepScan(_ host: String, depth: ScanDepth) async -> ToolResult<ScanReport> {
    guard settings.networkToolsEnabled else { return net7Off() }
    let own = (try? store.ownServers.list()) ?? []
    let scanner = ProScanner(net: network.system, system: SystemPortScan())
    let result = await scanner.scan(host: host, depth: depth, ownServers: own, clock: clock)
    if case .ok(let report) = result {
      network.lastScan2 = report
      emit(.stateChanged)
    }
    return result
  }

  // MARK: Verbindungen

  public func listConnections() async -> ToolResult<[Connection]> {
    guard settings.networkToolsEnabled else { return net7Off() }
    let lister = ConnectionsLister(system: SystemConnections(), net: network.system)
    let result = await lister.list()
    if case .ok(let conns) = result {
      network.connections = conns
      emit(.stateChanged)
    }
    return result
  }

  // MARK: Eigene Server

  public func addOwnServer(host: String, label: String) async -> ToolResult<OwnServer> {
    guard settings.networkToolsEnabled else { return net7Off() }
    do {
      let server = try store.ownServers.add(host: host, label: label, now: LocalTime.format(clock.now()))
      emit(.stateChanged)
      return .ok(server)
    } catch let e as OwnServerError {
      return .failure(code: "OWN_SERVER", error: e.errorDescription ?? "Server konnte nicht hinzugefügt werden.")
    } catch {
      return .failure(code: "OWN_SERVER", error: "Server konnte nicht hinzugefügt werden.")
    }
  }

  public func removeOwnServer(_ id: String) async -> ToolResult<Empty> {
    guard settings.networkToolsEnabled else { return net7Off() }
    try? store.ownServers.remove(id)
    emit(.stateChanged)
    return .ok(Empty())
  }

  // MARK: Paket-Mitschnitt

  public func captureInterfaces() async -> [String] {
    await PacketCapture(system: TcpdumpCaptureSystem(), net: network.system).interfaces()
  }

  public func startCapture(interface: String?, filter: String) async -> ToolResult<CaptureState> {
    guard settings.networkToolsEnabled else { return net7Off() }
    if network.captureState?.running == true { return .failure(code: "BUSY", error: "Es läuft schon ein Mitschnitt.") }
    let capture = PacketCapture(system: TcpdumpCaptureSystem(), net: network.system)
    let ifaces = await capture.interfaces()
    let iface = interface ?? ifaces.first ?? "en0"
    let result = await capture.start(interface: iface, filter: filter)
    guard case .ok(let running) = result else {
      if case .failure(let code, let error) = result { return .failure(code: code, error: error) }
      return .failure(code: "CAPTURE", error: "Mitschnitt fehlgeschlagen.")
    }
    network.runningCapture = running
    network.capturePcapPath = running.pcapPath
    var state = CaptureState(running: true, interface: iface, filter: filter,
                             startedAt: LocalTime.format(clock.now()), packetCount: 0, byHost: [])
    network.captureState = state
    network.recentPackets = []
    emit(.stateChanged)
    // Pakete im Hintergrund einsammeln, gebündelt an die Oberfläche melden.
    network.captureTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var batch: [CapturePacket] = []
      var lastFlush = self.clock.now()
      for await packet in running.packets {
        state = CaptureStats.merge(existing: state, packet: packet)
        self.network.captureState = state
        self.network.recentPackets.append(packet)
        if self.network.recentPackets.count > 300 { self.network.recentPackets.removeFirst(self.network.recentPackets.count - 300) }
        batch.append(packet)
        let now = self.clock.now()
        if batch.count >= 20 || now.timeIntervalSince(lastFlush) >= 0.4 {
          self.emit(.capturePackets(batch))
          batch.removeAll(keepingCapacity: true)
          lastFlush = now
        }
      }
      // tcpdump zu Ende (Paketgrenze/Zeitlimit) → Mitschnitt als beendet markieren.
      if !batch.isEmpty { self.emit(.capturePackets(batch)) }
      state.running = false
      self.network.captureState = state
      self.network.runningCapture = nil
      self.emit(.stateChanged)
    }
    return .ok(state)
  }

  public func stopCapture() async -> ToolResult<CaptureState> {
    guard var state = network.captureState else {
      return .failure(code: "NONE", error: "Es läuft kein Mitschnitt.")
    }
    network.runningCapture?.stop()
    network.runningCapture = nil
    state.running = false
    network.captureState = state
    emit(.stateChanged)
    return .ok(state)
  }

  /// Speichert den Mitschnitt als echte .pcap (für Wireshark). Fällt auf eine
  /// Text-Zusammenfassung zurück, wenn keine .pcap vorliegt (z. B. Attrappe/Prüfung).
  public func saveCapture(to folder: String?) async -> ToolResult<String> {
    guard let state = network.captureState else {
      return .failure(code: "EMPTY", error: "Kein Mitschnitt zum Speichern.")
    }
    let chosen = folder.flatMap { $0.isEmpty ? nil : $0 }
      ?? (settings.exportFolder.isEmpty ? "~/Documents/Lumi" : settings.exportFolder)
    let base = NSString(string: chosen).expandingTildeInPath
    let stamp = LocalTime.format(clock.now()).replacingOccurrences(of: ":", with: "-")
    let fm = FileManager.default
    do {
      try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
      let path: String
      if let pcap = network.capturePcapPath, fm.fileExists(atPath: pcap) {
        path = base + "/mitschnitt-\(stamp).pcap"
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        try fm.copyItem(atPath: pcap, toPath: path)
      } else {
        guard !network.recentPackets.isEmpty else {
          return .failure(code: "EMPTY", error: "Kein Mitschnitt zum Speichern.")
        }
        path = base + "/mitschnitt-\(stamp).txt"
        var text = "Lumi Mitschnitt \(state.startedAt ?? "")\nSchnittstelle: \(state.interface)  Filter: \(state.filter.isEmpty ? "(alles)" : state.filter)\nPakete: \(state.packetCount)\n\nGegenstellen:\n"
        for h in state.byHost { text += "  \(h.id): \(h.packets) Pakete, \(h.bytes) Bytes\n" }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
      }
      if var s = network.captureState { s.savedPath = path; network.captureState = s; emit(.stateChanged) }
      return .ok(path)
    } catch {
      return .failure(code: "SAVE", error: "Konnte nicht speichern: \(error.localizedDescription)")
    }
  }
}
