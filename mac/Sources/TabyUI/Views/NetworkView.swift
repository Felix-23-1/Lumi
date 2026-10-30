// Reiter "Netzwerk" (optional, Paket 6): WLAN-Karte, Geräte im eigenen Netz
// (Scan, umbenennen, als bekannt markieren, Ping/Ports/Aufwecken) und
// Werkzeuge (Ping, Ports, Speedtest, DNS, öffentliche IP). Alle Aufrufe gehen
// über `model.services`; danach wird der Stand neu geladen.
import SwiftUI
import TabyCore

/// Vorbelegung für Snapshots und Prüfungen (ohne Kern).
struct NetworkPreview {
  var tool: NetworkTool?
  var expandedId: String?
  var host: String?
  var pingResult: PingResult?
  var portResults: [PortResult]?
  var dns: DnsResult?
  var publicIP: String?
  /// Profi-Bereich (Paket 7).
  var pro = NetworkProPreview()
}

struct NetworkView: View {
  let network: NetworkState?
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var tool: NetworkTool
  @State private var expandedId: String?
  @State private var nameDraft = ""
  @State private var pingHost: String
  @State private var portHost: String
  @State private var dnsName = ""
  @State private var pingResult: PingResult?
  @State private var portResults: [PortResult]?
  @State private var dns: DnsResult?
  @State private var publicIP: String?
  @State private var devicesCollapsed = true
  @State private var speed: SpeedResult?
  @State private var busy = false
  @State private var scanning = false
  @State private var error: String?
  @State private var note: String?
  private let proPreview: NetworkProPreview

  /// Höhe des scrollbaren Bereichs im eingeklappten Zustand (Kopf + Polster = 380).
  static let scrollHeight: CGFloat = 320

  init(network: NetworkState?, preview: NetworkPreview = NetworkPreview()) {
    self.network = network
    self.proPreview = preview.pro
    _tool = State(initialValue: preview.tool ?? .ping)
    _expandedId = State(initialValue: preview.expandedId)
    _pingHost = State(initialValue: preview.host ?? "")
    _portHost = State(initialValue: preview.host ?? "")
    _pingResult = State(initialValue: preview.pingResult)
    _portResults = State(initialValue: preview.portResults)
    _dns = State(initialValue: preview.dns)
    _publicIP = State(initialValue: preview.publicIP)
  }

  private var today: String { LocalTime.datePart(NowResolver.now(nowEnv)) }

  private func enable() {
    Task {
      _ = await model.services.updateSettings(SettingsPatch(networkToolsEnabled: true), apiKey: nil)
      await model.refresh()
    }
  }

  var body: some View {
    if let network {
      let info = network.info
      VStack(alignment: .leading, spacing: 10) {
        PageHeader(title: "Netzwerk") {
          if let chip = NetworkLogic.onlineChip(info) {
            Chip(text: chip.text, tint: chip.online ? Theme.green : Theme.red)
          }
          refreshButton
        }
        if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
        if let note { Banner(symbol: "checkmark.circle.fill", text: note, tint: Theme.green) }
        CappedScroll(maxHeight: Self.scrollHeight) {
          VStack(alignment: .leading, spacing: 10) {
            wlanCard(info)
            devicesCard(network)
            toolsCard(network)
            NetworkProSection(network: network, preview: proPreview)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 10) {
        PageHeader(title: "Netzwerk")
        EmptyState(symbol: "network", title: NetworkLogic.offTitle, subtitle: "Zeigt dein WLAN, Geräte im Heimnetz, Geschwindigkeit und mehr.")
        Button("Netzwerk einschalten") { enable() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: WLAN

  private func wlanCard(_ info: NetworkInfo?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let info {
        HStack(alignment: .center, spacing: 10) {
          signalBars(info.rssi)
          VStack(alignment: .leading, spacing: 2) {
            Text(NetworkLogic.wlanTitle(info))
              .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if info.ssid == nil, let hint = info.ssidHint {
              Text(hint).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let quality = NetworkLogic.signalQuality(info.rssi), let rssi = info.rssi {
              Text("Signal: \(quality) (\(rssi) dBm)")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .help("dBm misst die Signalstärke; je näher an 0, desto besser")
            }
          }
          Spacer(minLength: 0)
        }
        KeyValueRow(label: "Kanal", value: NetworkLogic.channelLine(info))
        KeyValueRow(label: "Tempo", value: info.txRate.map { "\(NetworkLogic.mbit($0)) Mbit/s" })
        KeyValueRow(label: "Gerät", value: info.localIP.map { "\(info.interfaceName) · \($0)" })
        KeyValueRow(label: "Router", value: info.router)
        KeyValueRow(label: "DNS", value: info.dns.isEmpty ? nil : info.dns.joined(separator: ", "))
          .help("DNS übersetzt Webadressen in Zahlen (IP-Adressen)")
      } else {
        Text("Keine Angaben zum Netz.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
      }
    }
    .tabyCard()
  }

  /// Vier Balken, Höhe und Farbe nach Signalstärke.
  private func signalBars(_ rssi: Int?) -> some View {
    let bars = NetworkLogic.signalBars(rssi)
    let tint: Color = bars >= 3 ? Theme.green : (bars == 2 ? Theme.amber : Theme.red)
    return HStack(alignment: .bottom, spacing: 2) {
      ForEach(0..<4, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(i < bars ? tint : Theme.capsule)
          .frame(width: 4, height: CGFloat(5 + i * 3))
      }
    }
    .frame(width: 22, height: 17, alignment: .bottom)
  }

  // MARK: Geräte

  private func devicesCard(_ state: NetworkState) -> some View {
    let busyScan = scanning || state.scanning
    return VStack(alignment: .leading, spacing: 8) {
      // Ganze Kopfzeile klickbar (bis zum Scannen-Knopf); Scannen bleibt eigener Knopf.
      HStack(spacing: 6) {
        Button { withAnimation(Theme.spring) { devicesCollapsed.toggle() } } label: {
          HStack(spacing: 6) {
            Image(systemName: devicesCollapsed ? "chevron.right" : "chevron.down")
              .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
              .frame(width: 12)
            SectionHeader(symbol: "desktopcomputer", title: "Geräte",
                          count: state.devices.isEmpty ? nil : state.devices.count)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Button(action: scan) {
          HStack(spacing: 5) {
            if busyScan { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Text("Scannen")
          }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(busyScan)
      }
      if !devicesCollapsed {
        if busyScan {
          Text(NetworkLogic.scanRunning).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        if state.devices.isEmpty {
          Text("Noch nichts gefunden. „Scannen“ sucht Geräte in deinem Netz.")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        ForEach(NetworkLogic.sorted(state.devices)) { d in
          deviceRow(d)
        }
      }
    }
    .tabyCard()
  }

  private func deviceRow(_ d: NetworkDevice) -> some View {
    let open = expandedId == d.id
    return VStack(alignment: .leading, spacing: 8) {
      Button { toggleDevice(d) } label: {
        HStack(spacing: 10) {
          StatusDot(color: d.online ? Theme.green : Theme.tertiary, size: 7)
          Image(systemName: NetworkLogic.deviceSymbol(d))
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: 20)
          VStack(alignment: .leading, spacing: 1) {
            Text(NetworkLogic.deviceTitle(d))
              .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text(NetworkLogic.deviceSubtitle(d))
              .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
          }
          Spacer(minLength: 0)
          if d.isThisMac { Chip(text: "Dieser Mac", tint: Theme.blue) }
          if let badge = NetworkLogic.badge(d, today: today) {
            Chip(text: badge, tint: badge == "Neu" ? Theme.amber : Theme.secondary)
          }
          Image(systemName: open ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if open { deviceActions(d) }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private func deviceActions(_ d: NetworkDevice) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        InputCapsule(placeholder: "Eigener Name", text: $nameDraft)
        Button("Speichern") { rename(d) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      WrapLayout(spacing: 6) {
        if !d.known {
          Button { markKnown(d) } label: { Label("Als bekannt markieren", systemImage: "checkmark.seal") }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        Button { runPing(d.ip) } label: { Label("Ping", systemImage: "waveform.path") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button { runPorts(d.ip) } label: { Label("Ports prüfen", systemImage: "point.3.connected.trianglepath.dotted") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        if offersSMB(d) {
          Button { suggestShare(d) } label: { Label("Als Netzlaufwerk verbinden", systemImage: "externaldrive.connected.to.line") }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        if let mac = d.mac {
          Button { wake(mac) } label: { Label("Aufwecken (WoL)", systemImage: "power") }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      }
    }
  }

  // MARK: Werkzeuge

  private func toolsCard(_ state: NetworkState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "wrench.and.screwdriver", title: "Werkzeuge")
      WrapLayout(spacing: 4) {
        ForEach(NetworkTool.allCases) { t in
          ChoiceChip(text: t.title, selected: tool == t) {
            withAnimation(Theme.spring) { tool = t }
          }
        }
      }
      switch tool {
      case .ping: pingTool
      case .ports: portsTool
      case .speed: speedTool(state.lastSpeed)
      case .dns: dnsTool
      case .publicIP: publicIPTool
      }
    }
    .tabyCard()
  }

  private var pingTool: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        InputCapsule(placeholder: "Host oder IP, z. B. 192.168.178.1", text: $pingHost, mono: true)
          .onSubmit { runPing(pingHost) }
        Button("Ping") { runPing(pingHost) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || NetworkLogic.host(pingHost) == nil)
      }
      if busy { TypingDots() }
      if let r = pingResult {
        resultLine(NetworkLogic.pingSummary(r), detail: r.ip.map { "\(r.host) · \($0)" } ?? r.host)
      }
    }
  }

  private var portsTool: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Ports sind die Türen eines Geräts, über die Dienste laufen (z. B. 22 für SSH).")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        InputCapsule(placeholder: "Gerät im eigenen Netz, z. B. 192.168.178.40", text: $portHost, mono: true)
          .onSubmit { runPorts(portHost) }
        Button("Prüfen") { runPorts(portHost) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || NetworkLogic.host(portHost) == nil)
      }
      if busy { TypingDots() }
      ForEach(Array((portResults ?? []).enumerated()), id: \.offset) { _, p in
        HStack(spacing: 6) {
          Circle().fill(p.open ? Theme.green : Theme.tertiary).frame(width: 6, height: 6)
          Text(NetworkLogic.portLine(p)).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func speedTool(_ last: SpeedResult?) -> some View {
    let shown = speed ?? last
    return VStack(alignment: .leading, spacing: 8) {
      Button { runSpeed() } label: { Label(NetworkLogic.speedButton, systemImage: "speedometer") }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(busy)
      if busy { TypingDots() }
      if let s = shown {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
          bigNumber(NetworkLogic.mbit(s.downMbps), unit: "Mbit/s ↓")
          bigNumber(NetworkLogic.mbit(s.upMbps), unit: "Mbit/s ↑")
        }
        if let rpm = s.responsiveness {
          Text("Reaktion \(rpm) RPM").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
      }
    }
  }

  private var dnsTool: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("DNS übersetzt Webadressen in Zahlen (IP-Adressen).")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        InputCapsule(placeholder: "Name, z. B. apple.com", text: $dnsName, mono: true)
          .onSubmit { runDNS(dnsName) }
        Button("Auflösen") { runDNS(dnsName) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || NetworkLogic.host(dnsName) == nil)
      }
      if busy { TypingDots() }
      if let r = dns {
        ForEach(Array(NetworkLogic.dnsRows(r).enumerated()), id: \.offset) { _, row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
              .frame(width: 50, alignment: .leading)
            Text(row.values.joined(separator: ", ")).font(.system(size: 12, design: .monospaced))
              .foregroundStyle(Theme.text.opacity(0.9)).textSelection(.enabled)
          }
        }
      }
    }
  }

  private var publicIPTool: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { runPublicIP() } label: { Label(NetworkLogic.publicIPButton, systemImage: "globe") }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(busy)
      if busy { TypingDots() }
      if let ip = publicIP {
        Text(ip).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: Bausteine

  private var refreshButton: some View {
    Button(action: refresh) {
      Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(RoundIconButtonStyle(size: 26))
    .help("Netzwerk neu prüfen")
    .accessibilityLabel("Aktualisieren")
  }

  private func resultLine(_ text: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
      Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  private func bigNumber(_ value: String, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
        .monospacedDigit()
      Text(unit).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  // MARK: Aktionen

  /// SMB (Port 445 offen) aus dem letzten Scan oder der letzten Portprüfung dieses Geräts.
  private func offersSMB(_ d: NetworkDevice) -> Bool {
    let scanned = network?.lastScan2.map { report in
      (report.ip == d.ip || report.host == d.ip) && report.ports.contains { $0.port == 445 && $0.state == "open" }
    } ?? false
    let checked = portHost == d.ip && (portResults ?? []).contains { $0.port == 445 && $0.open }
    return scanned || checked
  }

  /// Schlägt die Adresse für das Formular unter Einstellungen → Verbindungen vor.
  private func suggestShare(_ d: NetworkDevice) {
    ShareDraft.suggest(host: d.ip)
    note = "Gemerkt: Unter Einstellungen → Verbindungen → + Netzlaufwerk steht smb://\(d.ip)/ schon im Formular."
  }

  private func toggleDevice(_ d: NetworkDevice) {
    withAnimation(Theme.spring) {
      if expandedId == d.id {
        expandedId = nil
      } else {
        expandedId = d.id
        nameDraft = d.name ?? ""
      }
    }
  }

  /// Nach jedem Aufruf: Fehler zeigen, Stand neu laden.
  private func finish(_ failure: String?) async {
    busy = false
    error = failure
    await model.refresh()
  }

  private func refresh() {
    error = nil
    note = nil
    Task {
      let r = await model.services.refreshNetworkInfo()
      await finish(r.errorMessage)
    }
  }

  private func scan() {
    scanning = true
    error = nil
    Task {
      let r = await model.services.scanNetwork()
      scanning = false
      await finish(r.errorMessage)
    }
  }

  private func rename(_ d: NetworkDevice) {
    let name = nameDraft.trimmingCharacters(in: .whitespaces)
    Task {
      let r = await model.services.updateNetworkDevice(d.id, name: name, known: nil)
      await finish(r.errorMessage)
    }
  }

  private func markKnown(_ d: NetworkDevice) {
    Task {
      let r = await model.services.updateNetworkDevice(d.id, name: nil, known: true)
      await finish(r.errorMessage)
    }
  }

  private func runPing(_ input: String) {
    guard let host = NetworkLogic.host(input) else { return }
    pingHost = host
    tool = .ping
    busy = true
    Task {
      let r = await model.services.ping(host)
      pingResult = r.value
      await finish(r.errorMessage)
    }
  }

  private func runPorts(_ input: String) {
    guard let host = NetworkLogic.host(input) else { return }
    portHost = host
    tool = .ports
    busy = true
    Task {
      let r = await model.services.checkPorts(host, ports: nil)
      portResults = r.value
      await finish(r.errorMessage)
    }
  }

  private func runSpeed() {
    busy = true
    note = nil
    Task {
      let r = await model.services.speedTest()
      if let v = r.value { speed = v }
      await finish(r.errorMessage)
    }
  }

  private func runDNS(_ input: String) {
    guard let name = NetworkLogic.host(input) else { return }
    busy = true
    Task {
      let r = await model.services.dnsLookup(name)
      dns = r.value
      await finish(r.errorMessage)
    }
  }

  private func runPublicIP() {
    busy = true
    Task {
      let r = await model.services.publicIP()
      publicIP = r.value
      await finish(r.errorMessage)
    }
  }

  private func wake(_ mac: String) {
    Task {
      let r = await model.services.wakeOnLan(mac: mac)
      if r.isOk { note = "Aufwecken gesendet." }
      await finish(r.errorMessage)
    }
  }
}

/// Zeile „Beschriftung · Wert“ in der WLAN-Karte (ohne Wert: ausgeblendet).
private struct KeyValueRow: View {
  let label: String
  let value: String?

  var body: some View {
    if let value {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label).font(.system(size: 11)).foregroundStyle(Theme.tertiary).frame(width: 64, alignment: .leading)
        Text(value).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1)
          .textSelection(.enabled)
        Spacer(minLength: 0)
      }
    }
  }
}
