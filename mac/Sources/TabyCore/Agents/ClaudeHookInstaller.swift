// Trägt Lumi idempotent als PermissionRequest-Hook in die Claude-Code-
// Einstellungen ein bzw. entfernt es (Port von src/main/agents/installHooks.ts).
// Fremde Schlüssel und Hook-Gruppen bleiben unberührt; eigene Einträge werden
// am Namen `taby-hook-relay` erkannt (auch der alte Node-Eintrag
// `taby-hook-relay.cjs` aus der Electron-App, der dabei ersetzt wird).
// Nur auf expliziten Klick im Agenten-Reiter, nie automatisch.
//
// Der Pfad der Einstellungsdatei ist immer ein Parameter (Standard für den
// Integrator: `defaultSettingsURL`); Prüfungen nutzen nur Temp-Dateien.
//
// Abweichung von TS: Ist die vorhandene settings.json kein gültiges JSON,
// wird sie NICHT überschrieben (TS hätte sie durch {} ersetzt), sondern ein
// Fehler geworfen.
import Foundation

public enum ClaudeHookInstallerError: Error, Equatable {
  /// settings.json existiert, ist aber kein JSON-Objekt.
  case unreadableSettings(String)
  case writeFailed(String)
}

public enum ClaudeHookInstaller {
  public static let relayMarker = "taby-hook-relay"
  /// Hook-Timeout in Sekunden (Server-Timeout liegt mit 110 s darunter).
  public static let timeoutSeconds = 120

  public static var defaultSettingsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }

  /// Für `sh -c`: Pfad in einfache Anführungszeichen.
  static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func command(relayPath: String, socketPath: String) -> String {
    "\(shellQuote(relayPath)) \(shellQuote(socketPath))"
  }

  static func isOurHandler(_ h: JSONValue) -> Bool {
    guard h["type"]?.stringValue == "command" else { return false }
    if h["command"]?.stringValue?.contains(relayMarker) == true { return true }
    return h["args"]?.arrayValue?.contains { $0.stringValue?.contains(relayMarker) == true } == true
  }

  static func withoutOurHandlers(_ groups: [JSONValue]) -> [JSONValue] {
    groups.compactMap { g -> JSONValue? in
      guard var obj = g.objectValue else { return g }
      guard let hooks = obj["hooks"]?.arrayValue else { return g }
      let kept = hooks.filter { !isOurHandler($0) }
      if kept.isEmpty { return nil }
      obj["hooks"] = .array(kept)
      return .object(obj)
    }
  }

  static func read(_ url: URL) throws -> [String: JSONValue]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw ClaudeHookInstallerError.unreadableSettings("\(url.path) ist nicht lesbar")
    }
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
    guard let obj = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
      throw ClaudeHookInstallerError.unreadableSettings(
        "\(url.path) enthält kein gültiges JSON — bitte von Hand prüfen, Lumi ändert die Datei nicht.")
    }
    return obj
  }

  static func write(_ obj: [String: JSONValue], to target: URL) throws {
    // Symlink (z. B. Dotfiles-Repo) erhalten: in das Ziel schreiben, nicht den Link ersetzen.
    let url = target.resolvingSymlinksInPath()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Vorher-Stand sichern: Lumi schreibt nur die Hook-Schlüssel, die Datei gehört dem Nutzer.
      // shortcut: Key-Reihenfolge wird nicht erhalten (sortiert), das .bak deckt das ab.
      if FileManager.default.fileExists(atPath: url.path) {
        let bak = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try FileManager.default.copyItem(at: url, to: bak)
      }
      var data = try enc.encode(JSONValue.object(obj))
      data.append(0x0A)
      try data.write(to: url, options: .atomic)
    } catch {
      throw ClaudeHookInstallerError.writeFailed("\(url.path): \(error.localizedDescription)")
    }
  }

  /// Hook-Ereignisse, für die Lumi das Relay eintragen kann.
  static let permissionEvent = "PermissionRequest"
  /// Meldungen (Notification, Stop): kein Matcher, damit Claude Code alle Fälle liefert.
  static let noticeEvents = ["Notification", "Stop"]

  static func hasOurHandler(_ groups: [JSONValue]) -> Bool {
    groups.contains { $0["hooks"]?.arrayValue?.contains(where: isOurHandler) == true }
  }

  public static func isInstalled(settingsURL: URL) -> Bool {
    guard let obj = try? read(settingsURL), let groups = obj["hooks"]?[permissionEvent]?.arrayValue else {
      return false
    }
    return hasOurHandler(groups)
  }

  /// true, wenn Notification und Stop je einen Lumi-Eintrag haben.
  public static func noticesInstalled(settingsURL: URL) -> Bool {
    guard let obj = try? read(settingsURL), let hooks = obj["hooks"]?.objectValue else { return false }
    return noticeEvents.allSatisfy { event in
      hooks[event]?.arrayValue.map(hasOurHandler) == true
    }
  }

  /// Ersetzt eigene Einträge durch genau einen neuen je Ereignis.
  /// PermissionRequest bekommt Matcher "*", Meldungen ohne Matcher.
  public static func install(settingsURL: URL, relayPath: String, socketPath: String) throws {
    var obj = try read(settingsURL) ?? [:]
    var hooks = obj["hooks"]?.objectValue ?? [:]
    let handler: JSONValue = [
      "type": "command",
      "command": .string(command(relayPath: relayPath, socketPath: socketPath)),
      "timeout": .number(Double(timeoutSeconds)),
    ]
    var groups = withoutOurHandlers(hooks[permissionEvent]?.arrayValue ?? [])
    groups.append(["matcher": "*", "hooks": [handler]])
    hooks[permissionEvent] = .array(groups)
    for event in noticeEvents {
      var noticeGroups = withoutOurHandlers(hooks[event]?.arrayValue ?? [])
      noticeGroups.append(["hooks": [handler]])
      hooks[event] = .array(noticeGroups)
    }
    obj["hooks"] = .object(hooks)
    try write(obj, to: settingsURL)
  }

  /// Zieht den Pfad bereits eingetragener Lumi-Hooks auf die aktuelle App nach (z. B. nach dem Umbenennen von Taby.app
  /// zu Lumi.app). Legt nichts Neues an: ohne eigenen Eintrag bleibt die Datei unberührt. true = geändert.
  @discardableResult
  public static func refreshPaths(settingsURL: URL, relayPath: String, socketPath: String) throws -> Bool {
    guard var obj = try read(settingsURL), var hooks = obj["hooks"]?.objectValue else { return false }
    let fresh = command(relayPath: relayPath, socketPath: socketPath)
    var changed = false
    for event in [permissionEvent] + noticeEvents {
      guard let groups = hooks[event]?.arrayValue else { continue }
      let updated = groups.map { g -> JSONValue in
        guard var group = g.objectValue, let handlers = group["hooks"]?.arrayValue else { return g }
        group["hooks"] = .array(handlers.map { h in
          guard isOurHandler(h), var handler = h.objectValue, handler["command"]?.stringValue != fresh else { return h }
          handler["command"] = .string(fresh)
          return .object(handler)
        })
        return .object(group)
      }
      guard updated != groups else { continue }
      hooks[event] = .array(updated)
      changed = true
    }
    guard changed else { return false }
    obj["hooks"] = .object(hooks)
    try write(obj, to: settingsURL)
    return true
  }

  /// Entfernt nur eigene Einträge aus allen Lumi-Ereignissen. Fehlende Datei/Abschnitt → nichts zu tun.
  public static func uninstall(settingsURL: URL) throws {
    guard var obj = try read(settingsURL), var hooks = obj["hooks"]?.objectValue else { return }
    var changed = false
    for event in [permissionEvent] + noticeEvents {
      guard let groups = hooks[event]?.arrayValue else { continue }
      let cleaned = withoutOurHandlers(groups)
      guard cleaned != groups else { continue }
      hooks[event] = .array(cleaned)
      changed = true
    }
    guard changed else { return }
    obj["hooks"] = .object(hooks)
    try write(obj, to: settingsURL)
  }
}
