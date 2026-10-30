// Reine Logik der Profi-Werkzeuge im Netzwerk-Reiter (Paket 7): Port- und
// Verbindungszustände, Mitschnitt-Zeilen, Formate, Freigabe des Server-Formulars.
// Ohne Ansicht, ohne Kern. Prüfungen in NetworkProUIChecks.swift.
import Foundation
import TabyCore

/// Farbton eines Zustands (die Ansicht setzt die Farbe): gut, neutral, Vorsicht.
enum StatusTone: Equatable {
  case good, neutral, warn
}

/// Profi-Werkzeuge im Netzwerk-Reiter (Auswahl über Chips).
enum ProTool: String, CaseIterable, Identifiable {
  case scan, connections, capture, servers

  var id: String { rawValue }

  var title: String {
    switch self {
    case .scan: "Scan"
    case .connections: "Verbindungen"
    case .capture: "Mitschnitt"
    case .servers: "Meine Server"
    }
  }
}

enum NetworkProLogic {
  static let proHint = "Diese Werkzeuge öffnen sich in einem eigenen Fenster (Fenster-Knopf in der Notch)."
  static let scanRunning = "Scan läuft… (kann dauern)"
  static let scanDeepNote = "Tief erkennt das Betriebssystem und fragt nach dem Admin-Passwort."
  static let refusalHint = "Füge den Host unter „Meine Server“ hinzu, um ihn zu prüfen."
  static let privacyConnections = "Zeigt nur, womit dein Mac gerade spricht — es wird nichts gescannt."
  static let captureWarning = "Paket-Mitschnitt braucht dein Admin-Passwort (wird pro Mitschnitt gefragt)."
  static let filterPlaceholder = "z. B. port 80 oder host 192.168.178.1"
  static let filterHint = "leer = alles"
  static let serverHint = "Nur eigene Server. Fremde Rechner zu scannen ist nicht erlaubt."
  static let confirmTitle = "Ich betreibe diesen Server oder darf ihn prüfen."

  // MARK: Scan

  static func depthLabel(_ d: ScanDepth) -> String {
    switch d {
    case .quick: "Schnell"
    case .services: "Dienste"
    case .deep: "Tief"
    }
  }

  /// Hinweis nur bei „Tief“ (Betriebssystem braucht Admin-Rechte).
  static func depthHint(_ d: ScanDepth) -> String? {
    d == .deep ? scanDeepNote : nil
  }

  /// Port-Zustand als Farbton.
  static func portTone(_ state: String) -> StatusTone {
    switch state.lowercased() {
    case "open": .good
    case "filtered": .warn
    default: .neutral
    }
  }

  /// Port-Zustand als deutsches Wort.
  static func portWord(_ state: String) -> String {
    switch state.lowercased() {
    case "open": "offen"
    case "filtered": "gefiltert"
    case "closed": "geschlossen"
    default: state
    }
  }

  static func openCount(_ ports: [ScanPort]) -> Int {
    ports.filter { $0.state.lowercased() == "open" }.count
  }

  /// „2 offen · 3 geprüft“.
  static func scanSummary(_ r: ScanReport) -> String {
    "\(openCount(r.ports)) offen · \(r.ports.count) geprüft"
  }

  /// Ein abgelehntes Ziel (nicht erlaubter Host) erkennt man am Fehlercode.
  static func isRefusal(_ code: String) -> Bool {
    let c = code.uppercased()
    return ["NOT_ALLOWED", "REFUSED", "FORBIDDEN", "NOT_OWN", "NOT_PERMITTED", "TARGET"].contains { c.contains($0) }
  }

  /// Vorbelegung des Ziels: der Router, sonst leer.
  static func scanPrefill(_ info: NetworkInfo?) -> String {
    info?.router ?? ""
  }

  // MARK: Verbindungen

  /// Gegenstellen außerhalb des Netzes zuerst, dann nach App-Name.
  static func sortConnections(_ list: [Connection]) -> [Connection] {
    list.enumerated().sorted { a, b in
      if a.element.isLocal != b.element.isLocal { return !a.element.isLocal }
      let x = a.element.app.lowercased(), y = b.element.app.lowercased()
      if x != y { return x < y }
      return a.offset < b.offset
    }
    .map(\.element)
  }

  static func connectionTag(_ c: Connection) -> String {
    c.isLocal ? "lokal" : "extern"
  }

  /// Gegenstelle: Name, sonst Adresse, sonst „nur lokal“ (z. B. Lauschen).
  static func connectionTarget(_ c: Connection) -> String {
    c.remoteHost ?? c.remoteAddress ?? "nur lokal"
  }

  /// Port hinter dem letzten Doppelpunkt („192.168.1.2:52344“ → „52344“).
  static func localPort(_ address: String) -> String {
    guard let last = address.split(separator: ":").last else { return "–" }
    return String(last)
  }

  static func connectionStateWord(_ state: String) -> String {
    switch state.uppercased() {
    case "ESTABLISHED": "verbunden"
    case "LISTEN": "lauscht"
    case "CLOSE_WAIT": "schließt"
    case "SYN_SENT": "verbindet"
    case "TIME_WAIT": "beendet"
    default: state.lowercased()
    }
  }

  static func connectionStateTone(_ state: String) -> StatusTone {
    switch state.uppercased() {
    case "ESTABLISHED": .good
    case "LISTEN", "TIME_WAIT": .neutral
    default: .warn
    }
  }

  // MARK: Mitschnitt

  /// Bytes in Einheiten mit einer Nachkommastelle: 512 → „512 B“, 1840 → „1,8 KB“.
  static func bytes(_ n: Int) -> String {
    let v = max(0, n)
    if v < 1000 { return "\(v) B" }
    if v < 1_000_000 { return NetworkLogic.decimal(Double(v) / 1000) + " KB" }
    if v < 1_000_000_000 { return NetworkLogic.decimal(Double(v) / 1_000_000) + " MB" }
    return NetworkLogic.decimal(Double(v) / 1_000_000_000) + " GB"
  }

  /// Laufzeit: „42 s“, „3 min 05 s“, „1 Std. 02 min“.
  static func captureDuration(seconds: Int) -> String {
    let s = max(0, seconds)
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min \(twoDigits(s % 60)) s" }
    return "\(s / 3600) Std. \(twoDigits((s % 3600) / 60)) min"
  }

  private static func twoDigits(_ n: Int) -> String {
    n < 10 ? "0\(n)" : "\(n)"
  }

  static func packetsText(_ n: Int) -> String {
    n == 1 ? "1 Paket" : "\(n) Pakete"
  }

  /// Zeit seit Start in Sekunden mit Komma („0,01“).
  static func packetTime(_ t: Double) -> String {
    String(format: "%.2f", max(0, t)).replacingOccurrences(of: ".", with: ",")
  }

  /// Eine Paketzeile: „0,01 s  TCP  192.168.178.24 → 140.82.121.4  920 B  443 ACK“.
  static func packetLine(_ p: CapturePacket) -> String {
    "\(packetTime(p.t)) s  \(p.proto)  \(p.source) → \(p.dest)  \(p.length) B  \(p.info)"
  }

  /// Gegenstellen: meiste Bytes zuerst, bei Gleichstand meiste Pakete.
  static func rankedHosts(_ stats: [CaptureHostStat]) -> [CaptureHostStat] {
    stats.sorted { a, b in
      if a.bytes != b.bytes { return a.bytes > b.bytes }
      if a.packets != b.packets { return a.packets > b.packets }
      return a.id < b.id
    }
  }

  /// „github.com · 2 Pakete · 1,8 KB“.
  static func hostStatLine(_ s: CaptureHostStat) -> String {
    "\(s.id) · \(packetsText(s.packets)) · \(bytes(s.bytes))"
  }

  /// Gewählte Schnittstelle, sonst die erste der Liste (nil ohne Liste).
  static func effectiveInterface(chosen: String?, available: [String]) -> String? {
    if let chosen, available.contains(chosen) { return chosen }
    return available.first
  }

  // MARK: Eigene Server

  /// Hinzufügen nur mit Host und bestätigtem Hinweis.
  static func canAddServer(host: String, confirmed: Bool) -> Bool {
    confirmed && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Anzeigename: Bezeichnung, sonst Host.
  static func serverTitle(_ s: OwnServer) -> String {
    s.label.trimmingCharacters(in: .whitespaces).isEmpty ? s.host : s.label
  }
}
