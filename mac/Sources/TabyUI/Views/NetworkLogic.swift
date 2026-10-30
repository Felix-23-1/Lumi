// Reine Logik des Netzwerk-Reiters (ohne Ansicht, ohne Kern): Signalstärke,
// Gerätesymbol, Sortierung, Textformate. Prüfungen in NetworkChecks.swift.
import Foundation
import TabyCore

/// Werkzeuge im Netzwerk-Reiter (Auswahl über Chips).
enum NetworkTool: String, CaseIterable, Identifiable {
  case ping, ports, speed, dns, publicIP

  var id: String { rawValue }

  var title: String {
    switch self {
    case .ping: "Ping"
    case .ports: "Ports"
    case .speed: "Speedtest"
    case .dns: "DNS"
    case .publicIP: "Öffentliche IP"
    }
  }
}

enum NetworkLogic {
  static let speedButton = "Test starten (ca. 20 s, geht ins Internet)"
  static let scanRunning = "Suche Geräte… (ca. 10 s)"
  static let publicIPButton = "Anzeigen (fragt ipify.org)"
  static let offTitle = "Netzwerk-Werkzeuge sind aus"
  static let offHint = "Einschalten unter Einstellungen → Netzwerk (mit „Erweitert anzeigen“)."

  // MARK: Signal

  /// Balken 0…4 aus dBm (0 ohne WLAN-Messung).
  static func signalBars(_ rssi: Int?) -> Int {
    guard let r = rssi else { return 0 }
    if r >= -50 { return 4 }
    if r >= -60 { return 3 }
    if r >= -70 { return 2 }
    return 1
  }

  /// Qualitätswort zum Signal; nil ohne Messung (z. B. Kabel).
  static func signalQuality(_ rssi: Int?) -> String? {
    guard rssi != nil else { return nil }
    switch signalBars(rssi) {
    case 4: return "sehr gut"
    case 3: return "gut"
    case 2: return "mäßig"
    default: return "schwach"
    }
  }

  /// Titel der WLAN-Karte: Name, sonst ehrlicher Hinweis.
  static func wlanTitle(_ info: NetworkInfo) -> String {
    if let ssid = info.ssid, !ssid.trimmingCharacters(in: .whitespaces).isEmpty { return ssid }
    return info.interfaceName.lowercased().contains("ethernet") ? "Kabelverbindung" : "WLAN-Name unbekannt"
  }

  /// „Kanal 44 · 5 GHz“ (nur vorhandene Teile).
  static func channelLine(_ info: NetworkInfo) -> String? {
    var parts: [String] = []
    if let c = info.channel { parts.append("Kanal \(c)") }
    if let b = info.band { parts.append(b) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Anzeige der Verbindung oben rechts: nil, solange der Stand fehlt.
  static func onlineChip(_ info: NetworkInfo?) -> (text: String, online: Bool)? {
    guard let info else { return nil }
    return info.online ? ("Online", true) : ("Offline", false)
  }

  // MARK: Zahlen

  /// Eine Nachkommastelle mit Komma: 243.5 → "243,5".
  static func decimal(_ value: Double) -> String {
    String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
  }

  static func mbit(_ value: Double) -> String { decimal(value) }

  /// „3/3 · Ø 3,4 ms“ bzw. „0/3 · keine Antwort“.
  static func pingSummary(_ r: PingResult) -> String {
    let head = "\(r.received)/\(r.sent)"
    guard let avg = r.avgMs else { return head + " · keine Antwort" }
    return head + " · Ø \(decimal(avg)) ms"
  }

  static func portLine(_ p: PortResult) -> String {
    "\(p.port) · \(p.service) · " + (p.open ? "offen" : "geschlossen")
  }

  /// Zeilen der DNS-Antwort (leere Gruppen fallen weg).
  static func dnsRows(_ r: DnsResult) -> [(label: String, values: [String])] {
    var rows: [(label: String, values: [String])] = []
    if let cname = r.cname, !cname.isEmpty { rows.append((label: "CNAME", values: [cname])) }
    if !r.a.isEmpty { rows.append((label: "A", values: r.a)) }
    if !r.aaaa.isEmpty { rows.append((label: "AAAA", values: r.aaaa)) }
    if !r.mx.isEmpty { rows.append((label: "MX", values: r.mx)) }
    return rows
  }

  // MARK: Geräte

  /// Symbol je Gerät: Router, Raspberry Pi, Drucker, Apple (iPhone nach Name), sonst Fragezeichen.
  static func deviceSymbol(_ d: NetworkDevice) -> String {
    if d.isRouter { return "wifi.router" }
    let name = (d.name ?? "").lowercased()
    let vendor = (d.vendor ?? "").lowercased()
    if vendor.contains("raspberry") { return "cpu" }
    if name.contains("drucker") || name.contains("printer") || vendor.contains("printer")
      || vendor.contains("epson") || vendor.contains("canon") || vendor.contains("brother") {
      return "printer"
    }
    if vendor.contains("apple") || name.contains("iphone") || name.contains("macbook") || name.contains("ipad") {
      return name.contains("iphone") ? "iphone" : "laptopcomputer"
    }
    if d.name == nil && d.vendor == nil { return "questionmark.circle" }
    return "desktopcomputer"
  }

  /// Eigener Name, sonst Platzhalter.
  static func deviceTitle(_ d: NetworkDevice) -> String {
    if let n = d.name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
    return "Unbekanntes Gerät"
  }

  /// „Hersteller · IP“ (ohne Hersteller nur die IP).
  static func deviceSubtitle(_ d: NetworkDevice) -> String {
    if let v = d.vendor, !v.isEmpty { return "\(v) · \(d.ip)" }
    return d.ip
  }

  /// „Neu“ für heute zum ersten Mal gesehene unbekannte Geräte, sonst „Unbekannt“; bekannte ohne Abzeichen.
  static func badge(_ d: NetworkDevice, today: String) -> String? {
    guard !d.known else { return nil }
    return LocalTime.datePart(d.firstSeen) == today ? "Neu" : "Unbekannt"
  }

  /// Reihenfolge: Router, dieser Mac, dann nach IP-Adresse (zahlenweise).
  static func sorted(_ devices: [NetworkDevice]) -> [NetworkDevice] {
    devices.enumerated().sorted { a, b in
      let ra = rank(a.element), rb = rank(b.element)
      if ra != rb { return ra < rb }
      let ia = ipKey(a.element.ip), ib = ipKey(b.element.ip)
      if ia != ib { return ia.lexicographicallyPrecedes(ib) }
      return a.offset < b.offset
    }
    .map(\.element)
  }

  static func rank(_ d: NetworkDevice) -> Int {
    if d.isRouter { return 0 }
    return d.isThisMac ? 1 : 2
  }

  /// Vierteilige IPv4 als Zahlen; alles andere ans Ende.
  static func ipKey(_ ip: String) -> [Int] {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
    return parts.count == 4 ? parts : [Int.max, Int.max, Int.max, Int.max]
  }

  /// Ein Host für Ping/Ports/DNS aus dem Eingabefeld (nil = leer).
  static func host(_ input: String) -> String? {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}
