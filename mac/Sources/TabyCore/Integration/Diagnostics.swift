// Diagnose-Export (Einstellungen → Allgemein): Zip mit Protokoll, Version, Einstellungen ohne
// Geheimnisse und Datenbank-Statistik. Nie Schlüssel, Tokens oder Nachrichtentexte.
import Foundation

public enum DiagnosticsExport {
  /// Startet ein Hilfsprogramm; true = Erfolg.
  public typealias ProcessRunner = @Sendable (_ path: String, _ args: [String]) async -> Bool

  public static let fileNames = ["log.txt", "version.txt", "settings.json", "stats.txt"]
  // Auch persönliche Freitexte (eigene Vorgaben, Notch-Text, Wohnort) und Geburtstage/Kontaktdaten gehören nicht in eine Diagnose.
  private static let secretMarkers = ["token", "key", "secret", "password", "passwd", "instructions", "prompt",
                                      "notchtext", "homecity", "birthday", "contact"]

  public static let processRunner: ProcessRunner = { path, args in
    let result = try? await Blocking.run { () throws -> ModProcessResult in try ModProcess.run(path, args, timeout: 120) }
    return result?.status == 0
  }

  /// Einstellungen als JSON. Schlüssel mit Geheimnis-Namen fallen weg; URLs verlieren Zugangsdaten, Query und Fragment.
  public static func settingsJSON(_ settings: TabySettings) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    return try JSONSerialization.data(withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  static func sanitize(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
      var out: [String: Any] = [:]
      for (key, inner) in dict where !isSecretKey(key) { out[key] = sanitize(inner) }
      return out
    }
    if let list = value as? [Any] { return list.map(sanitize) }
    if let text = value as? String { return sanitizeString(text) }
    return value
  }

  static func isSecretKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    // „args“: Startargumente von MCP-Servern enthalten oft Schlüssel (`--token X`).
    return lower == "args" || secretMarkers.contains { lower.contains($0) }
  }

  static func sanitizeString(_ text: String) -> String {
    // Jede URL mit Schema (auch smb://, ftp://, afp://): Zugangsdaten, Query und Fragment entfernen.
    guard text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil else { return text }
    guard var parts = URLComponents(string: text) else { return "" }
    parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
    return parts.string ?? ""
  }

  /// Zeilen je Tabelle plus Dateigröße der Datenbank (inklusive WAL-Datei).
  public static func statsText(db: Database, databaseBytes: Int64) -> String {
    var lines = ["Datenbank-Bytes: \(databaseBytes)"]
    let names = ((try? db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) ?? [])
      .compactMap { $0.string("name") }
    for name in names {
      let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
      let count = (try? db.query("SELECT COUNT(*) AS n FROM \"\(quoted)\""))?.first?.int("n")
      lines.append("\(name): \(count.map(String.init) ?? "unbekannt")")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Größe der Datenbankdatei plus WAL; 0 ohne Datei (z. B. flüchtige Datenbank).
  public static func databaseBytes(path: String?) -> Int64 {
    guard let path else { return 0 }
    return [path, path + "-wal"].reduce(Int64(0)) { sum, p in
      sum + Int64(((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  /// Schreibt den Zip in `folder` (nil = Schreibtisch) und liefert dessen Pfad.
  public static func export(folder: String?, clock: Clock, settings: Data, logText: String, versionText: String,
                            statsText: String, runner: ProcessRunner) async -> ToolResult<String> {
    let fm = FileManager.default
    let base: URL
    if let folder {
      base = URL(fileURLWithPath: folder, isDirectory: true)
    } else if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
      base = desktop
    } else {
      return .failure(code: "NO_FOLDER", error: "Kein Zielordner gefunden.")
    }
    let staging = fm.temporaryDirectory.appendingPathComponent("taby-diag-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: staging) }
    do {
      try fm.createDirectory(at: staging, withIntermediateDirectories: true)
      try fm.createDirectory(at: base, withIntermediateDirectories: true)
      try logText.write(to: staging.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
      try versionText.write(to: staging.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
      try settings.write(to: staging.appendingPathComponent("settings.json"))
      try statsText.write(to: staging.appendingPathComponent("stats.txt"), atomically: true, encoding: .utf8)
    } catch {
      TabyLog.error(.core, "Diagnose: Dateien nicht geschrieben (\(TabyLog.code(error)))")
      return .failure(code: "WRITE", error: "Diagnose konnte nicht vorbereitet werden.")
    }
    let target = uniqueZip(in: base, stamp: DatabaseBackup.stamp(clock))
    guard await runner("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, target.path]) else {
      TabyLog.error(.core, "Diagnose: Zip nicht erstellt")
      return .failure(code: "ZIP", error: "Diagnose-Zip konnte nicht erstellt werden.")
    }
    TabyLog.info(.core, "Diagnose exportiert")
    return .ok(target.path)
  }

  /// "Lumi-Diagnose-<stamp>.zip"; gleiche Minute → "-2", "-3", … (nie überschreiben).
  static func uniqueZip(in dir: URL, stamp: String) -> URL {
    var url = dir.appendingPathComponent("Lumi-Diagnose-\(stamp).zip")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = dir.appendingPathComponent("Lumi-Diagnose-\(stamp)-\(n).zip")
      n += 1
    }
    return url
  }
}

extension CoreServices {
  public func exportDiagnostics(to folder: String?) async -> ToolResult<String> {
    guard let settingsData = try? DiagnosticsExport.settingsJSON(settings) else {
      return .failure(code: "SETTINGS", error: "Einstellungen konnten nicht gelesen werden.")
    }
    let version = "Lumi \(Self.bundleCommit().isEmpty ? "Entwickler-Build" : Self.bundleCommit())\n"
      + "Build \(Self.bundleBuild())\n"
      + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
    let stats = DiagnosticsExport.statsText(
      db: store.db, databaseBytes: DiagnosticsExport.databaseBytes(path: options.databasePath))
    return await DiagnosticsExport.export(
      folder: folder, clock: clock, settings: settingsData,
      logText: TabyLog.buffer.snapshot().joined(separator: "\n") + "\n",
      versionText: version, statsText: stats, runner: DiagnosticsExport.processRunner)
  }
}
