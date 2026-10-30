// Profi-Bereich im Netzwerk-Reiter (Paket 7): Scan, Verbindungen, Mitschnitt,
// eigene Server. Jeder Teil lädt über `model.services` und liest danach den
// Stand neu. Vorbelegung für Snapshots über `NetworkProPreview`.
import SwiftUI
import TabyCore

/// Vorbelegung des Profi-Bereichs für Snapshots und Prüfungen.
struct NetworkProPreview {
  var tool: ProTool?
  var scanHost: String?
  var scanDepth: ScanDepth?
  var captureFilter: String?
  var interfaces: [String] = ["en0", "en1", "utun0", "lo0"]
  var serverFormOpen = false
}

extension StatusTone {
  var color: Color {
    switch self {
    case .good: Theme.green
    case .neutral: Theme.tertiary
    case .warn: Theme.amber
    }
  }
}

/// Der Profi-Kasten: Hinweis, Auswahl und ein Werkzeug.
struct NetworkProSection: View {
  let network: NetworkState
  let preview: NetworkProPreview
  @State private var tool: ProTool

  init(network: NetworkState, preview: NetworkProPreview = NetworkProPreview()) {
    self.network = network
    self.preview = preview
    _tool = State(initialValue: preview.tool ?? .scan)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "scope", title: "Profi")
      Banner(symbol: "macwindow", text: "Diese Werkzeuge laufen direkt in diesem Reiter.", tint: Theme.blue)
      WrapLayout(spacing: 4) {
        ForEach(ProTool.allCases) { t in
          ChoiceChip(text: t.title, selected: tool == t) {
            withAnimation(Theme.spring) { tool = t }
          }
        }
      }
      switch tool {
      case .scan: ScanPane(network: network, preview: preview)
      case .connections: ConnectionsPane(network: network)
      case .capture: CapturePane(network: network, preview: preview)
      case .servers: ServersPane(network: network, preview: preview)
      }
    }
    .tabyCard()
  }
}

// MARK: - Scan

private struct ScanPane: View {
  let network: NetworkState
  @EnvironmentObject private var model: AppModel
  @State private var host: String
  @State private var depth: ScanDepth
  @State private var scanning = false
  @State private var error: String?
  @State private var refused = false

  init(network: NetworkState, preview: NetworkProPreview) {
    self.network = network
    _host = State(initialValue: preview.scanHost ?? NetworkProLogic.scanPrefill(network.info))
    _depth = State(initialValue: preview.scanDepth ?? .services)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      InputCapsule(placeholder: "Gerät im Netz, z. B. 192.168.178.40", text: $host, mono: true)
        .onSubmit { scan() }
      WrapLayout(spacing: 4) {
        ForEach(ScanDepth.allCases, id: \.self) { d in
          ChoiceChip(text: NetworkProLogic.depthLabel(d), selected: depth == d) {
            withAnimation(Theme.snappy) { depth = d }
          }
        }
      }
      if let hint = NetworkProLogic.depthHint(depth) {
        Text(hint).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button { scan() } label: { Label("Scannen", systemImage: "magnifyingglass") }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(scanning || NetworkLogic.host(host) == nil)
        if scanning {
          ProgressView().controlSize(.small).scaleEffect(0.7)
          Text(NetworkProLogic.scanRunning).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        Spacer(minLength: 0)
      }
      if let error {
        Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red)
        if refused {
          Text(NetworkProLogic.refusalHint).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let r = network.lastScan2 { result(r) }
    }
  }

  private func result(_ r: ScanReport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Chip(text: r.up ? "Host aktiv" : "Host antwortet nicht", tint: r.up ? Theme.green : Theme.red)
        Text(r.ip.map { "\(r.host) · \($0)" } ?? r.host)
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.9))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      if let os = r.os {
        Text("System: \(os)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      if r.ports.isEmpty {
        Text("Keine Ports geprüft.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
      } else {
        HStack(spacing: 6) {
          Text("Port").frame(width: 70, alignment: .leading)
          Text("Dienst").frame(width: 80, alignment: .leading)
          Text("Version").frame(maxWidth: .infinity, alignment: .leading)
          Text("Status").frame(width: 84, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
        ForEach(Array(r.ports.enumerated()), id: \.offset) { _, p in
          portRow(p)
        }
      }
      Text("\(NetworkProLogic.scanSummary(r)) · \(r.tool) · \(r.durationMs) ms")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  private func portRow(_ p: ScanPort) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: "\(p.port)/\(p.proto)").frame(width: 70, alignment: .leading)
        .font(.system(size: 12, design: .monospaced))
      Text(p.service).frame(width: 80, alignment: .leading).lineLimit(1)
      Text(p.version ?? "–").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        .foregroundStyle(Theme.secondary)
      Chip(text: NetworkProLogic.portWord(p.state), tint: NetworkProLogic.portTone(p.state).color)
        .frame(width: 84, alignment: .leading)
    }
    .font(.system(size: 12))
    .foregroundStyle(Theme.text.opacity(0.9))
  }

  private func scan() {
    guard let target = NetworkLogic.host(host) else { return }
    scanning = true
    error = nil
    refused = false
    Task {
      let r = await model.services.deepScan(target, depth: depth)
      scanning = false
      if case .failure(let code, let message) = r {
        error = message
        refused = NetworkProLogic.isRefusal(code)
      }
      await model.refresh()
    }
  }
}

// MARK: - Verbindungen

private struct ConnectionsPane: View {
  let network: NetworkState
  @EnvironmentObject private var model: AppModel
  @State private var busy = false
  @State private var error: String?
  @State private var collapsed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Text(NetworkProLogic.privacyConnections).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button { load() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(busy)
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      CollapsibleSection(symbol: "arrow.left.arrow.right", title: "Offene Verbindungen",
                         count: network.connections.isEmpty ? nil : network.connections.count,
                         collapsed: $collapsed) {
        if network.connections.isEmpty {
          Text("Noch nicht geladen. „Aktualisieren“ holt die Liste.")
            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        } else {
          CappedScroll(maxHeight: 230) {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(NetworkProLogic.sortConnections(network.connections)) { c in
                connectionRow(c)
              }
            }
          }
        }
      }
    }
  }

  private func connectionRow(_ c: Connection) -> some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(c.app).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
          Chip(text: NetworkProLogic.connectionTag(c), tint: c.isLocal ? Theme.blue : Theme.amber)
        }
        Text("→ \(NetworkProLogic.connectionTarget(c))")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 2) {
        Chip(text: NetworkProLogic.connectionStateWord(c.state),
             tint: NetworkProLogic.connectionStateTone(c.state).color)
        Text("Port \(NetworkProLogic.localPort(c.localAddress))")
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private func load() {
    busy = true
    error = nil
    Task {
      let r = await model.services.listConnections()
      busy = false
      error = r.errorMessage
      await model.refresh()
    }
  }
}

// MARK: - Mitschnitt

private struct CapturePane: View {
  let network: NetworkState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var interfaces: [String]
  @State private var chosen: String?
  @State private var filter: String
  @State private var busy = false
  @State private var error: String?
  @State private var savedNote: String?
  @State private var packetsCollapsed = false

  init(network: NetworkState, preview: NetworkProPreview) {
    self.network = network
    _interfaces = State(initialValue: preview.interfaces)
    _filter = State(initialValue: preview.captureFilter ?? network.capture?.filter ?? "")
  }

  private var running: Bool { network.capturing }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !running {
        Banner(symbol: "lock.shield", text: NetworkProLogic.captureWarning, tint: Theme.amber)
        Text("Mitschnitt zeichnet den Datenverkehr deines Macs auf, um Verbindungen nachzuvollziehen.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        setup
      } else {
        live
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      Text("Nur die Kopfdaten werden angezeigt. Die .pcap enthält die vollständigen Pakete und bleibt lokal auf deinem Mac.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let savedNote {
        Text(savedNote).font(.system(size: 11)).foregroundStyle(Theme.green)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .task {
      let list = await model.services.captureInterfaces()
      if !list.isEmpty { interfaces = list }
    }
    .task(id: running) {
      // Solange der Mitschnitt läuft, alle zwei Sekunden neu laden (live-ähnlich).
      guard running else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { break }
        await model.refresh()
      }
    }
  }

  private var setup: some View {
    let effective = NetworkProLogic.effectiveInterface(chosen: chosen, available: interfaces)
    return VStack(alignment: .leading, spacing: 8) {
      Text("Schnittstelle").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
      WrapLayout(spacing: 4) {
        ForEach(interfaces, id: \.self) { iface in
          ChoiceChip(text: iface, selected: effective == iface) { chosen = iface }
        }
      }
      InputCapsule(placeholder: NetworkProLogic.filterPlaceholder, text: $filter, mono: true)
      Text(NetworkProLogic.filterHint).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
      HStack {
        Button { start(effective) } label: { Label("Mitschnitt starten", systemImage: "record.circle") }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || effective == nil)
        Spacer(minLength: 0)
      }
    }
  }

  private var live: some View {
    let cap = network.capture
    let count = cap?.packetCount ?? network.recentPackets.count
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        StatusDot(color: Theme.red)
        Text("läuft · \(NetworkProLogic.packetsText(count)) · \(duration(cap))")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        Spacer(minLength: 0)
        Button { stop() } label: { Label("Stopp", systemImage: "stop.fill") }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
          .disabled(busy)
        if !network.recentPackets.isEmpty {
          Button { save() } label: { Label("Speichern", systemImage: "square.and.arrow.down") }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(busy)
            .help("Mitschnitt als .pcap für Wireshark speichern")
        }
      }
      Text(cap.map { "\($0.interface) · Filter: \($0.filter.isEmpty ? "alles" : $0.filter)" } ?? "")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
      CollapsibleSection(symbol: "list.bullet", title: "Pakete",
                         count: network.recentPackets.isEmpty ? nil : network.recentPackets.count,
                         collapsed: $packetsCollapsed) {
        if network.recentPackets.isEmpty {
          Text("Warte auf Pakete…").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        } else {
          // Neueste Zeile unten; die Liste wächst mit dem Fenster (Grenze kommt aus dem Umfeld).
          CappedScroll(maxHeight: 170) {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(network.recentPackets) { p in
                Text(NetworkProLogic.packetLine(p))
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(Theme.text.opacity(0.85))
                  .lineLimit(1)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      if let stats = cap?.byHost, !stats.isEmpty {
        SectionHeader(symbol: "globe", title: "Nach Gegenstelle")
        ForEach(NetworkProLogic.rankedHosts(stats)) { s in
          Text(NetworkProLogic.hostStatLine(s))
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1)
        }
      }
    }
  }

  private func duration(_ cap: CaptureState?) -> String {
    guard let start = cap?.startedAt,
          let s = LocalTime.parse(start), let n = LocalTime.parse(NowResolver.now(nowEnv)) else {
      return NetworkProLogic.captureDuration(seconds: 0)
    }
    return NetworkProLogic.captureDuration(seconds: Int(n.timeIntervalSince(s)))
  }

  private func start(_ iface: String?) {
    guard let iface else { return }
    busy = true
    error = nil
    savedNote = nil
    let f = filter.trimmingCharacters(in: .whitespaces)
    Task {
      let r = await model.services.startCapture(interface: iface, filter: f)
      busy = false
      error = r.errorMessage
      await model.refresh()
    }
  }

  private func stop() {
    busy = true
    Task {
      let r = await model.services.stopCapture()
      busy = false
      error = r.errorMessage
      await model.refresh()
    }
  }

  private func save() {
    busy = true
    error = nil
    Task {
      let r = await model.services.saveCapture(to: nil)
      busy = false
      if let path = r.value { savedNote = "Gespeichert unter \(path)" }
      error = r.errorMessage
      await model.refresh()
    }
  }
}

// MARK: - Eigene Server

private struct ServersPane: View {
  let network: NetworkState
  @EnvironmentObject private var model: AppModel
  @State private var formOpen: Bool
  @State private var newHost = ""
  @State private var newLabel = ""
  @State private var confirmed = false
  @State private var busy = false
  @State private var error: String?

  init(network: NetworkState, preview: NetworkProPreview) {
    self.network = network
    _formOpen = State(initialValue: preview.serverFormOpen)
  }

  private var canAdd: Bool {
    NetworkProLogic.canAddServer(host: newHost, confirmed: confirmed)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Banner(symbol: "exclamationmark.shield", text: NetworkProLogic.serverHint, tint: Theme.amber)
      SectionHeader(symbol: "server.rack", title: "Meine Server",
                    count: network.ownServers.isEmpty ? nil : network.ownServers.count)
      if network.ownServers.isEmpty {
        Text("Noch keine eigenen Server eingetragen.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
      }
      ForEach(network.ownServers) { s in serverRow(s) }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if formOpen {
        form
      } else {
        Button { withAnimation(Theme.spring) { formOpen = true } } label: {
          Label("Server hinzufügen", systemImage: "plus")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
    }
  }

  private func serverRow(_ s: OwnServer) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "server.rack").font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.secondary).frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(NetworkProLogic.serverTitle(s)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
          .lineLimit(1)
        Text(s.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button { remove(s) } label: { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.tertiary)
        .disabled(busy)
        .help("Server entfernen")
        .accessibilityLabel("Server entfernen")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("+ Server hinzufügen").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
      InputCapsule(placeholder: "Host oder IP, z. B. 203.0.113.10", text: $newHost, mono: true)
      InputCapsule(placeholder: "Bezeichnung, z. B. Heimserver", text: $newLabel)
      PillToggle(title: NetworkProLogic.confirmTitle, isOn: $confirmed)
      HStack(spacing: 6) {
        Button("Abbrechen") { withAnimation(Theme.spring) { formOpen = false } }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        Button("Hinzufügen") { add() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(!canAdd || busy)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private func add() {
    guard canAdd else { return }
    let host = newHost.trimmingCharacters(in: .whitespaces)
    let label = newLabel.trimmingCharacters(in: .whitespaces)
    busy = true
    error = nil
    Task {
      let r = await model.services.addOwnServer(host: host, label: label)
      busy = false
      error = r.errorMessage
      if r.isOk {
        newHost = ""
        newLabel = ""
        confirmed = false
        formOpen = false
      }
      await model.refresh()
    }
  }

  private func remove(_ s: OwnServer) {
    busy = true
    error = nil
    Task {
      let r = await model.services.removeOwnServer(s.id)
      busy = false
      error = r.errorMessage
      await model.refresh()
    }
  }
}
