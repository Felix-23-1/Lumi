// Gerätedaten aus dem Netz-Scan (lokal in SQLite). Geräte werden per MAC
// wiedererkannt, ohne MAC per IP. Eigene Namen bleiben erhalten. Router und
// dieser Mac gelten automatisch als bekannt. Router und dieser Mac werden nicht
// gespeichert; sie ergeben sich bei jedem Lesen aus der aktuellen NetworkInfo.
import Foundation

public final class NetworkDevicesRepository: @unchecked Sendable {
  let db: Database

  public init(db: Database) {
    self.db = db
  }

  private func toDevice(_ r: SQLRow, info: NetworkInfo?, latestSeen: String?) -> NetworkDevice {
    let ip = r.text("ip")
    let lastSeen = r.text("last_seen")
    return NetworkDevice(
      id: r.text("id"),
      ip: ip,
      mac: r.string("mac"),
      name: r.string("name"),
      vendor: r.string("vendor"),
      isRouter: info?.router == ip,
      isThisMac: info?.localIP == ip,
      known: r.bool("known"),
      firstSeen: r.text("first_seen"),
      lastSeen: lastSeen,
      online: latestSeen != nil && lastSeen == latestSeen)
  }

  /// Zeitpunkt des letzten Scans: der jüngste `last_seen`-Wert aller Geräte.
  /// Geräte mit genau diesem Stand haben im letzten Scan geantwortet.
  private func latestSeen() throws -> String? {
    try db.query("SELECT MAX(last_seen) AS m FROM network_devices").first?.string("m")
  }

  /// Sortierung: Router, dieser Mac, dann nach IP (numerisch).
  static func sorted(_ devices: [NetworkDevice]) -> [NetworkDevice] {
    devices.sorted { a, b in
      let ra = a.isRouter ? 0 : (a.isThisMac ? 1 : 2)
      let rb = b.isRouter ? 0 : (b.isThisMac ? 1 : 2)
      if ra != rb { return ra < rb }
      let va = NetworkAddress.ipv4Value(a.ip) ?? UInt32.max
      let vb = NetworkAddress.ipv4Value(b.ip) ?? UInt32.max
      if va != vb { return va < vb }
      return a.ip < b.ip
    }
  }

  /// Kennung des aktuellen Netzes: Router-MAC aus dem Scan, sonst das beim letzten Scan
  /// gespeicherte Netz des Routers (stabil, auch wenn ARP die MAC gerade nicht liefert),
  /// zuletzt das Teilnetz. nil, wenn nichts davon bekannt ist.
  private func networkID(scanned: [ScannedHost], info: NetworkInfo) throws -> String? {
    let routerMAC = info.router.flatMap { router in
      scanned.first { $0.ip == router }?.mac.flatMap { NetworkAddress.normalizeMAC($0) }
    }
    if let routerMAC { return "mac:" + routerMAC }
    if let router = info.router,
       let stored = try db.query(
         "SELECT network FROM network_devices WHERE ip = ? AND network IS NOT NULL ORDER BY last_seen DESC LIMIT 1",
         [.text(router)]).first?.string("network") {
      return stored
    }
    return info.subnet.map { "subnet:" + $0 }
  }

  /// Geräte eines Netzes; ohne Netz (nil) alle.
  private func rows(network: String?) throws -> [SQLRow] {
    guard let network else { return try db.query("SELECT * FROM network_devices") }
    return try db.query("SELECT * FROM network_devices WHERE network = ?", [.text(network)])
  }

  /// Geräte des aktuellen Netzes. Router und dieser Mac werden mit `info` markiert.
  /// Geräte anderer Netze bleiben gespeichert, erscheinen aber nicht.
  public func list(info: NetworkInfo? = nil) throws -> [NetworkDevice] {
    let current = try info.flatMap { try networkID(scanned: [], info: $0) }
    let latest = try latestSeen()
    return Self.sorted(try rows(network: current).map { toDevice($0, info: info, latestSeen: latest) })
  }

  /// Übernimmt einen Scan. Ergebnis: `all` = Geräte dieses Scans zuerst (sortiert), danach die
  /// übrigen gespeicherten; `new` = in diesem Scan neu entdeckte, unbekannte Geräte.
  @discardableResult
  public func merge(scanned: [ScannedHost], info: NetworkInfo, now: String)
    throws -> (all: [NetworkDevice], new: [NetworkDevice])
  {
    var seenIDs: [String] = []
    var newIDs: [String] = []
    let network = try networkID(scanned: scanned, info: info)
    try db.transaction {
      for host in scanned {
        let mac = host.mac.flatMap { NetworkAddress.normalizeMAC($0) }
        let isRouter = info.router == host.ip
        let isThisMac = info.localIP == host.ip
        let vendor = mac.flatMap { OUIVendors.vendor(forMAC: $0) }

        var row: SQLRow?
        if let mac {
          row = try db.query("SELECT * FROM network_devices WHERE id = ?", [.text(mac)]).first
        }
        if row == nil {
          // Fallback über die IP: Gerät, das bisher nur per IP (ohne MAC) gespeichert ist.
          row = try db.query(
            "SELECT * FROM network_devices WHERE ip = ? AND (mac IS NULL OR mac = id) ORDER BY last_seen DESC LIMIT 1",
            [.text(host.ip)]).first
        }

        let autoKnown = isRouter || isThisMac
        if let existing = row {
          let oldID = existing.text("id")
          let finalMAC = mac ?? existing.string("mac")
          // Eigener Name bleibt; sonst der aktuelle Hostname.
          let name = existing.bool("custom_name") ? existing.string("name") : (host.hostname ?? existing.string("name"))
          let known = existing.bool("known") || autoKnown
          // Kennung auf die MAC umstellen, sobald sie bekannt ist und frei ist.
          var newID = oldID
          if let finalMAC, oldID != finalMAC {
            let taken = try db.query("SELECT id FROM network_devices WHERE id = ?", [.text(finalMAC)]).first != nil
            if !taken { newID = finalMAC }
          }
          try db.run(
            """
            UPDATE network_devices SET id = ?, ip = ?, mac = ?, name = ?, vendor = ?, known = ?, last_seen = ?, network = COALESCE(?, network)
            WHERE id = ?
            """,
            [.text(newID), .text(host.ip), .of(finalMAC), .of(name), .of(finalMAC.flatMap { OUIVendors.vendor(forMAC: $0) } ?? existing.string("vendor")),
             .of(known), .text(now), .of(network), .text(oldID)])
          seenIDs.append(newID)
        } else {
          let id = mac ?? host.ip
          try db.run(
            """
            INSERT INTO network_devices (id, ip, mac, name, custom_name, vendor, known, first_seen, last_seen, network)
            VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
            """,
            [.text(id), .text(host.ip), .of(mac), .of(host.hostname), .of(vendor), .of(autoKnown),
             .text(now), .text(now), .of(network)])
          seenIDs.append(id)
          if !autoKnown { newIDs.append(id) }
        }
      }

      // Ohne Scan-Ergebnis oder ohne erkennbares Netz nichts löschen (sonst ginge alles verloren).
      if let network, !scanned.isEmpty {
        // Geräte anderer Netze (und altes Netz = NULL) weg; bekannte und benannte bleiben, erscheinen aber nicht.
        try db.run(
          "DELETE FROM network_devices WHERE known = 0 AND custom_name = 0 AND (network IS NULL OR network <> ?)",
          [.text(network)])
        // Länger als 30 Tage nicht gesehen: weg, außer bekannt oder benannt.
        if let cutoff = LocalTime.parse(now).map({ LocalTime.format($0.addingTimeInterval(-30 * 86400)) }) {
          try db.run("DELETE FROM network_devices WHERE known = 0 AND custom_name = 0 AND last_seen < ?", [.text(cutoff)])
        }
      }
    }

    let latest = try latestSeen()
    let all = Self.sorted(try rows(network: network).map { toDevice($0, info: info, latestSeen: latest) })
    let seen = Set(seenIDs)
    let thisScan = all.filter { seen.contains($0.id) }
    let others = all.filter { !seen.contains($0.id) }
    let newSet = Set(newIDs)
    let newDevices = all.filter { newSet.contains($0.id) && !$0.known }
    return (Self.sorted(thisScan) + Self.sorted(others), Self.sorted(newDevices))
  }

  /// Ändert Name und/oder Bekannt-Status. Ein leerer Name entfernt den eigenen Namen.
  /// nil, wenn es das Gerät nicht gibt.
  public func update(id: String, name: String? = nil, known: Bool? = nil,
                     info: NetworkInfo? = nil) throws -> NetworkDevice? {
    guard try db.query("SELECT id FROM network_devices WHERE id = ?", [.text(id)]).first != nil else {
      return nil
    }
    if let name {
      let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleaned.isEmpty {
        try db.run("UPDATE network_devices SET custom_name = 0, name = NULL WHERE id = ?", [.text(id)])
      } else {
        try db.run("UPDATE network_devices SET name = ?, custom_name = 1 WHERE id = ?", [.text(cleaned), .text(id)])
      }
    }
    if let known {
      try db.run("UPDATE network_devices SET known = ? WHERE id = ?", [.of(known), .text(id)])
    }
    let latest = try latestSeen()
    return try db.query("SELECT * FROM network_devices WHERE id = ?", [.text(id)]).first
      .map { toDevice($0, info: info, latestSeen: latest) }
  }
}
