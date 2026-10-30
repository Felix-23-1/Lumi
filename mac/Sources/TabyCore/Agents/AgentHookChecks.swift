// Prüfungen für Sources/TabyCore/Agents (Port der TS-Tests/Handprüfungen aus
// docs/decisions/0005). Nur Temp-Dateien und Temp-Sockets — nie das echte
// ~/.claude. Echter Socket-Rundlauf (Server + Client), optional auch mit dem
// gebauten `taby-hook-relay` (liegt nach `swift build` neben TabyChecks).
import Darwin
import Foundation

private func tempDir() throws -> URL {
  // Kurz halten: sun_path fasst nur 104 Bytes.
  let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("th-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}

private func readJSON(_ url: URL) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

/// Minimaler Relay-Ersatz im Prozess: sendet eine Zeile, liefert die Antwortzeile
/// (nil = Verbindung ohne Antwort geschlossen / nicht erreichbar).
private func roundTrip(_ socketPath: String, _ line: String, closeAfterSend: Bool = false) async -> String? {
  await Task.detached { () -> String? in
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: bytes); buf[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return nil }
    let out = Array((line + "\n").utf8)
    _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if closeAfterSend { return nil }
    var resp = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(fd, &buf, buf.count)
      if n <= 0 { break }
      resp.append(contentsOf: buf[0..<n])
      if resp.contains(0x0A) { break }
    }
    guard let nl = resp.firstIndex(of: 0x0A) else { return nil }
    return String(decoding: resp[..<nl], as: UTF8.self)
  }.value
}

/// Sammelt Rückrufe des Servers (kommen auf dessen Queue).
private final class Recorder {
  private let lock = NSLock()
  private var _requests: [AgentPermissionRequest] = []
  private var _closed: [(String, AgentRequestCloseReason)] = []
  private var _notices: [ClaudeNotice] = []
  var requests: [AgentPermissionRequest] { lock.withLock { _requests } }
  var closed: [(String, AgentRequestCloseReason)] { lock.withLock { _closed } }
  var notices: [ClaudeNotice] { lock.withLock { _notices } }
  func add(_ r: AgentPermissionRequest) { lock.withLock { _requests.append(r) } }
  func close(_ id: String, _ reason: AgentRequestCloseReason) { lock.withLock { _closed.append((id, reason)) } }
  func addNotice(_ n: ClaudeNotice) { lock.withLock { _notices.append(n) } }
}

private func waitFor(_ what: String, timeout: TimeInterval = 3, _ cond: () -> Bool) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !cond() {
    if Date() > deadline { throw fail("Zeitüberschreitung beim Warten auf: \(what)") }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

private let samplePayload = #"{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/tmp/projekt"}"#
private let waitingPayload = #"{"session_id":"s1","hook_event_name":"Notification","message":"Claude is waiting for your input","cwd":"/tmp/projekt"}"#
private let permissionNoticePayload = #"{"session_id":"s1","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/tmp/projekt"}"#
private let stopPayload = #"{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp/projekt"}"#

/// Hook-Einträge eines Ereignisses (Gruppen → Handler), leer wenn nicht vorhanden.
private func handlerCount(_ s: JSONValue, _ event: String) -> Int {
  (s["hooks"]?[event]?.arrayValue ?? []).reduce(0) { $0 + ($1["hooks"]?.arrayValue?.count ?? 0) }
}

private func withServer(timeout: TimeInterval = 5, autoDecision: AgentPermissionDecision? = nil,
                        _ body: (AgentHookServer, Recorder, String) async throws -> Void) async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("a.sock").path
  let rec = Recorder()
  var serverRef: AgentHookServer?
  let server = AgentHookServer(socketPath: path, requestTimeout: timeout, onRequest: { req in
    rec.add(req)
    // Synchron aus dem Rückruf antworten darf nicht verklemmen.
    if let d = autoDecision { serverRef?.resolve(id: req.id, decision: d) }
  }, onClosed: { id, reason in rec.close(id, reason) },
  onNotice: { rec.addNotice($0) })
  serverRef = server
  try server.start()
  defer { server.stop() }
  try await body(server, rec, path)
}

/// Pfad zum gebauten Relay (neben dem laufenden Prüfprogramm), falls vorhanden.
private func builtRelayPath() -> String? {
  guard let exe = Bundle.main.executableURL else { return nil }
  let p = exe.deletingLastPathComponent().appendingPathComponent("taby-hook-relay").path
  return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}

private func runRelay(_ relay: String, socketPath: String, stdin: String) async throws -> (String, Int32) {
  try await Task.detached { () throws -> (String, Int32) in
    let p = Process()
    p.executableURL = URL(fileURLWithPath: relay)
    p.arguments = [socketPath]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    try p.run()
    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try inPipe.fileHandleForWriting.close()
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: out, as: UTF8.self), p.terminationStatus)
  }.value
}

enum AgentHookChecks {
  static let suite = CheckSuite("AgentHooks", [
    // MARK: settings.json
    CheckCase("Install: sichert den Vorher-Stand als settings.json.bak") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let original: JSONValue = ["model": "opus"]
      try Data(original.jsonString().utf8).write(to: url)
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: "/r/taby-hook-relay", socketPath: "/s.sock")
      let bak = try readJSON(url.appendingPathExtension("bak"))
      try expectEqual(bak["model"], "opus", "Backup hat den alten Inhalt")
      try expect(bak["hooks"] == nil, "Backup ohne Lumi-Hooks")
    },
    CheckCase("Pfad nachziehen: alter Taby.app-Pfad wird zur Lumi.app, ohne eigenen Eintrag bleibt die Datei unberührt") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let sock = "/s.sock"
      try Data(#"{"model":"opus"}"#.utf8).write(to: url)
      let before = try Data(contentsOf: url)
      try expect(try !ClaudeHookInstaller.refreshPaths(settingsURL: url, relayPath: "/n/taby-hook-relay", socketPath: sock))
      try expectEqual(try Data(contentsOf: url), before, "ohne Eintrag unverändert")
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: "/Applications/Taby.app/Contents/MacOS/taby-hook-relay", socketPath: sock)
      let fresh = "/Applications/Lumi.app/Contents/MacOS/taby-hook-relay"
      try expect(try ClaudeHookInstaller.refreshPaths(settingsURL: url, relayPath: fresh, socketPath: sock))
      try expect(try !ClaudeHookInstaller.refreshPaths(settingsURL: url, relayPath: fresh, socketPath: sock), "zweites Mal nichts mehr")
      let text = try String(contentsOf: url, encoding: .utf8)
      try expect(text.contains("Lumi.app") && !text.contains("Taby.app"), text)
      try expect(ClaudeHookInstaller.isInstalled(settingsURL: url))
    },
    CheckCase("Install: trägt Hook ein, erhält fremde Schlüssel und Hooks, idempotent") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let original: JSONValue = [
        "model": "opus", "permissions": ["allow": ["Bash(ls:*)"]],
        "hooks": [
          "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/mein-skript.sh"]]]],
          "PermissionRequest": [["matcher": "Edit", "hooks": [["type": "command", "command": "/usr/local/bin/fremd"]]]],
        ],
      ]
      try Data(original.jsonString().utf8).write(to: url)
      try expect(!ClaudeHookInstaller.isInstalled(settingsURL: url))
      let relay = "/Applications/Lumi.app/Contents/MacOS/taby-hook-relay"
      let sock = "/Users/x/Library/Application Support/Taby/taby-agent.sock"
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: relay, socketPath: sock)
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: relay, socketPath: sock)
      try expect(ClaudeHookInstaller.isInstalled(settingsURL: url))
      let s = try readJSON(url)
      try expectEqual(s["model"], "opus")
      try expectEqual(s["permissions"], original["permissions"])
      try expectEqual(s["hooks"]?["PreToolUse"], original["hooks"]?["PreToolUse"])
      let groups = try expectNotNil(s["hooks"]?["PermissionRequest"]?.arrayValue)
      try expectEqual(groups.count, 2, "fremde Gruppe + genau eine eigene (keine Duplikate)")
      try expectEqual(groups[0], original["hooks"]?["PermissionRequest"]?.arrayValue?[0])
      let ours = groups[1]
      try expectEqual(ours["matcher"], "*")
      let h = try expectNotNil(ours["hooks"]?.arrayValue?.first)
      try expectEqual(h["type"], "command")
      try expectEqual(h["timeout"], 120)
      try expectEqual(h["command"]?.stringValue,
                      "'/Applications/Lumi.app/Contents/MacOS/taby-hook-relay' '/Users/x/Library/Application Support/Taby/taby-agent.sock'")
    },
    CheckCase("Install: ersetzt alten Node-Relay-Eintrag, legt fehlende Datei an") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("sub/settings.json")
      try expect(!ClaudeHookInstaller.isInstalled(settingsURL: url))
      try ClaudeHookInstaller.uninstall(settingsURL: url)  // fehlende Datei: nichts zu tun
      try expect(!FileManager.default.fileExists(atPath: url.path))
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let legacy: JSONValue = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [
        ["type": "command", "command": "node", "args": ["/old/resources/taby-hook-relay.cjs", "/old/sock"], "timeout": 120],
      ]]]]]
      try Data(legacy.jsonString().utf8).write(to: url)
      try expect(ClaudeHookInstaller.isInstalled(settingsURL: url), "alter Eintrag wird erkannt")
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: "/r/taby-hook-relay", socketPath: "/s.sock")
      let groups = try readJSON(url)["hooks"]?["PermissionRequest"]?.arrayValue ?? []
      try expectEqual(groups.count, 1)
      try expectEqual(groups[0]["hooks"]?.arrayValue?.first?["args"], nil)
    },
    CheckCase("Uninstall: entfernt nur eigene Einträge") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let foreign: JSONValue = ["matcher": "Edit", "hooks": [["type": "command", "command": "/usr/local/bin/fremd"]]]
      let mixed: JSONValue = ["matcher": "*", "hooks": [
        ["type": "command", "command": "/usr/local/bin/anderes"],
        ["type": "command", "command": "'/x/taby-hook-relay' '/s'"],
      ]]
      let settings: JSONValue = ["theme": "dark", "hooks": ["PermissionRequest": [foreign, mixed]]]
      try Data(settings.jsonString().utf8).write(to: url)
      try ClaudeHookInstaller.uninstall(settingsURL: url)
      try expect(!ClaudeHookInstaller.isInstalled(settingsURL: url))
      let s = try readJSON(url)
      try expectEqual(s["theme"], "dark")
      let groups = s["hooks"]?["PermissionRequest"]?.arrayValue ?? []
      try expectEqual(groups.count, 2)
      try expectEqual(groups[0], foreign)
      try expectEqual(groups[1]["hooks"]?.arrayValue?.count, 1, "fremder Handler in gemischter Gruppe bleibt")
    },
    CheckCase("Install: ungültiges JSON wird nicht überschrieben") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let broken = Data("{ \"model\": \"opus\", // Kommentar\n".utf8)
      try broken.write(to: url)
      try await expectThrows {
        try ClaudeHookInstaller.install(settingsURL: url, relayPath: "/r/taby-hook-relay", socketPath: "/s")
      }
      try expectEqual(try Data(contentsOf: url), broken)
    },
    CheckCase("Install: Symlink bleibt erhalten, Ziel wird geändert") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let target = dir.appendingPathComponent("real.json")
      let link = dir.appendingPathComponent("settings.json")
      try Data("{}".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      try ClaudeHookInstaller.install(settingsURL: link, relayPath: "/r/taby-hook-relay", socketPath: "/s")
      let attrs = try FileManager.default.attributesOfItem(atPath: link.path)
      try expectEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
      try expect(ClaudeHookInstaller.isInstalled(settingsURL: target))
    },

    CheckCase("Meldungen: Notification und Stop eingetragen, idempotent, fremde bleiben, Uninstall entfernt alle") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let foreignNotify: JSONValue = ["hooks": ["Notification": [["hooks": [["type": "command", "command": "/usr/local/bin/notify"]]]],
                                                 "Stop": [["hooks": [["type": "command", "command": "/usr/local/bin/stopfremd"]]]]]]
      try Data(foreignNotify.jsonString().utf8).write(to: url)
      try expect(!ClaudeHookInstaller.noticesInstalled(settingsURL: url))
      let relay = "/r/taby-hook-relay", sock = "/s.sock"
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: relay, socketPath: sock)
      try ClaudeHookInstaller.install(settingsURL: url, relayPath: relay, socketPath: sock)
      try expect(ClaudeHookInstaller.isInstalled(settingsURL: url))
      try expect(ClaudeHookInstaller.noticesInstalled(settingsURL: url))
      var s = try readJSON(url)
      try expectEqual(handlerCount(s, "PermissionRequest"), 1)
      try expectEqual(handlerCount(s, "Notification"), 2, "fremd + genau einer eigener")
      try expectEqual(handlerCount(s, "Stop"), 2, "fremd + genau einer eigener")
      let ours = try expectNotNil(s["hooks"]?["Notification"]?.arrayValue?.last)
      try expectEqual(ours["matcher"], nil, "Meldungen ohne Matcher")
      try expectEqual(ours["hooks"]?.arrayValue?.first?["timeout"], 120)
      try expectEqual(s["hooks"]?["Stop"]?.arrayValue?.first, foreignNotify["hooks"]?["Stop"]?.arrayValue?.first)
      try ClaudeHookInstaller.uninstall(settingsURL: url)
      s = try readJSON(url)
      try expect(!ClaudeHookInstaller.isInstalled(settingsURL: url))
      try expect(!ClaudeHookInstaller.noticesInstalled(settingsURL: url))
      try expectEqual(handlerCount(s, "Notification"), 1, "fremder Notification-Hook bleibt")
      try expectEqual(handlerCount(s, "Stop"), 1, "fremder Stop-Hook bleibt")
      try expectEqual(handlerCount(s, "PermissionRequest"), 0)
    },
    CheckCase("Meldungen: noticesInstalled ist nur mit Notification UND Stop wahr") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let url = dir.appendingPathComponent("settings.json")
      let onlyStop: JSONValue = ["hooks": ["Stop": [["hooks": [["type": "command",
        "command": "'/r/taby-hook-relay' '/s'"]]]]]]
      try Data(onlyStop.jsonString().utf8).write(to: url)
      try expect(!ClaudeHookInstaller.noticesInstalled(settingsURL: url), "nur Stop reicht nicht")
      try expect(!ClaudeHookInstaller.noticesInstalled(settingsURL: dir.appendingPathComponent("fehlt.json")))
    },

    // MARK: Protokoll
    CheckCase("Antwortformat: hookSpecificOutput mit decision (message nur bei deny)") {
      let allow = String(decoding: AgentHookServer.encodeResponse(.init(behavior: .allow, message: "egal")), as: UTF8.self)
      try expectEqual(allow, #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
      let deny = JSONValue.parse(String(decoding: AgentHookServer.encodeResponse(.init(behavior: .deny, message: "Nein")), as: UTF8.self))
      try expectEqual(deny?["hookSpecificOutput"]?["decision"], ["behavior": "deny", "message": "Nein"])
    },

    // MARK: Socket-Rundlauf
    CheckCase("Socket: Notification → onNotice, Client sieht schnell EOF ohne Daten, keine Anfrage") {
      try await withServer { _, rec, path in
        let started = Date()
        let reply = await roundTrip(path, waitingPayload)
        try expect(reply == nil, "Meldungen bekommen keine Antwort")
        try expect(Date().timeIntervalSince(started) < 1, "EOF muss sofort kommen")
        try await waitFor("Meldung") { rec.notices.count == 1 }
        try expectEqual(rec.notices[0], ClaudeNotice(kind: .needsInput, message: "Claude is waiting for your input", project: "projekt"))
        try expectEqual(rec.requests.count, 0)
        try expectEqual(rec.closed.count, 0)
      }
    },
    CheckCase("Socket: Stop-Meldung lässt offene Freigabe unberührt") {
      try await withServer { server, rec, path in
        async let first = roundTrip(path, samplePayload)
        try await waitFor("Anfrage") { rec.requests.count == 1 }
        let id = rec.requests[0].id
        let stopReply = await roundTrip(path, stopPayload)
        try expect(stopReply == nil)
        try await waitFor("Stop-Meldung") { rec.notices.count == 1 }
        try expectEqual(rec.notices[0].kind, .finished)
        try expectEqual(server.currentRequestId, id, "Anfrage bleibt offen")
        try expect(rec.closed.isEmpty, "nichts verdrängt oder geschlossen")
        server.resolve(id: id, decision: .init(behavior: .allow))
        let firstReply = await first
        let line = try expectNotNil(firstReply, "Freigabe kommt trotz Meldung an")
        try expectEqual(JSONValue.parse(line)?["hookSpecificOutput"]?["decision"]?["behavior"], "allow")
      }
    },
    CheckCase("Socket: Stop mit stop_hook_active=true wird nicht gemeldet, Freigabe-Meldung bei offener Anfrage verworfen") {
      try await withServer { server, rec, path in
        async let first = roundTrip(path, samplePayload)
        try await waitFor("Anfrage") { rec.requests.count == 1 }
        let loop = await roundTrip(path, #"{"hook_event_name":"Stop","stop_hook_active":true,"cwd":"/x"}"#)
        try expect(loop == nil)
        let dup = await roundTrip(path, permissionNoticePayload)
        try expect(dup == nil)
        try expect(rec.notices.isEmpty, "weder Schleifen-Stop noch Freigabe-Dublette werden gemeldet")
        try expectEqual(server.currentRequestId, rec.requests[0].id)
        server.resolve(id: rec.requests[0].id, decision: .init(behavior: .deny, message: "nein"))
        _ = await first
      }
    },
    CheckCase("Socket: Anfrage → Rückruf → allow kommt beim Client an") {
      try await withServer { server, rec, path in
        async let reply = roundTrip(path, samplePayload)
        try await waitFor("Anfrage") { rec.requests.count == 1 }
        let req = rec.requests[0]
        try expectEqual(req.toolName, "Bash")
        try expectEqual(req.toolInput, ["command": "ls -la"])
        try expectEqual(req.cwd, "/tmp/projekt")
        try expectEqual(server.currentRequestId, req.id)
        server.resolve(id: req.id, decision: .init(behavior: .allow))
        let replied = await reply
        let line = try expectNotNil(replied, "keine Antwort")
        try expectEqual(JSONValue.parse(line)?["hookSpecificOutput"]?["decision"]?["behavior"], "allow")
        try expectEqual(JSONValue.parse(line)?["hookSpecificOutput"]?["hookEventName"], "PermissionRequest")
        try expect(server.currentRequestId == nil)
        try expect(rec.closed.isEmpty, "entschiedene Anfrage meldet kein onClosed")
      }
    },
    CheckCase("Socket: deny mit Begründung; resolve direkt im Rückruf verklemmt nicht") {
      try await withServer(autoDecision: .init(behavior: .deny, message: "Nicht jetzt")) { _, rec, path in
        let replied = await roundTrip(path, samplePayload)
        let line = try expectNotNil(replied, "keine Antwort")
        try expectEqual(JSONValue.parse(line)?["hookSpecificOutput"]?["decision"], ["behavior": "deny", "message": "Nicht jetzt"])
        try expectEqual(rec.requests.count, 1)
      }
    },
    CheckCase("Socket: Timeout schließt ohne Antwort (Rückfall auf Claude-Code-Dialog)") {
      try await withServer(timeout: 0.3) { server, rec, path in
        let reply = await roundTrip(path, samplePayload)
        try expect(reply == nil, "keine Antwortzeile erwartet")
        try await waitFor("onClosed") { rec.closed.count == 1 }
        try expectEqual(rec.closed[0].1, .timeout)
        server.resolve(id: rec.closed[0].0, decision: .init(behavior: .allow))  // zu spät: ignoriert
      }
    },
    CheckCase("Socket: neue Anfrage verdrängt die offene (nur eine gleichzeitig)") {
      try await withServer { server, rec, path in
        async let first = roundTrip(path, samplePayload)
        try await waitFor("erste Anfrage") { rec.requests.count == 1 }
        async let second = roundTrip(path, #"{"tool_name":"Edit","tool_input":{}}"#)
        try await waitFor("zweite Anfrage") { rec.requests.count == 2 }
        let firstReply = await first
        try expect(firstReply == nil, "verdrängte Anfrage bekommt keine Antwort")
        try expectEqual(rec.closed.map(\.0), [rec.requests[0].id])
        try expectEqual(rec.closed.map(\.1), [.displaced])
        try expectEqual(server.currentRequestId, rec.requests[1].id)
        server.resolve(id: rec.requests[1].id, decision: .init(behavior: .allow))
        let secondReply = await second
        try expect(secondReply != nil)
      }
    },
    CheckCase("Socket: Abbruch durch Relay meldet clientGone; ungültiges JSON wird verworfen") {
      try await withServer { _, rec, path in
        _ = await roundTrip(path, samplePayload, closeAfterSend: true)
        try await waitFor("clientGone") { rec.closed.count == 1 }
        try expectEqual(rec.closed[0].1, .clientGone)
        let bad = await roundTrip(path, "kein json")
        try expect(bad == nil)
        try expectEqual(rec.requests.count, 1, "ungültige Eingabe erzeugt keine Anfrage")
      }
    },
    CheckCase("Socket: Start räumt veralteten Socket weg, Stopp entfernt ihn") {
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let path = dir.appendingPathComponent("a.sock").path
      try Data("alt".utf8).write(to: URL(fileURLWithPath: path))
      let server = AgentHookServer(socketPath: path, onRequest: { _ in })
      try server.start()
      try expect(server.isRunning)
      server.stop()
      try expect(!server.isRunning && !FileManager.default.fileExists(atPath: path))
      let gone = await roundTrip(path, samplePayload)
      try expect(gone == nil, "gestoppt: nicht erreichbar")
      let long = "/tmp/" + String(repeating: "x", count: 120)
      try await expectThrows { try AgentHookServer(socketPath: long, onRequest: { _ in }).start() }
    },

    CheckCase("Meldungen: parseNotice für Notification, Stop, stop_hook_active und unbekannte Ereignisse") {
      func parse(_ s: String) -> ClaudeNotice? { AgentHookServer.parseNotice(Data(s.utf8)) }
      try expectEqual(parse(waitingPayload), ClaudeNotice(kind: .needsInput, message: "Claude is waiting for your input", project: "projekt"))
      try expectEqual(parse(stopPayload), ClaudeNotice(kind: .finished, message: "", project: "projekt"))
      try expect(parse(#"{"hook_event_name":"Stop","stop_hook_active":true,"cwd":"/x"}"#) == nil, "Stop-Schleife wird ignoriert")
      try expectEqual(parse(#"{"hook_event_name":"Notification"}"#), ClaudeNotice(kind: .needsInput, message: "", project: ""))
      try expect(parse(samplePayload) == nil, "PermissionRequest ist keine Meldung")
      try expect(parse(#"{"hook_event_name":"SessionStart"}"#) == nil, "unbekanntes Ereignis")
      try expect(parse("kein json") == nil)
    },

    // MARK: Relay-Binary
    CheckCase("Relay: echter Prozess gegen echten Socket (allow) und ohne Lumi (leer, Exit 0)") {
      guard let relay = builtRelayPath() else {
        print("      (Relay-Teil übersprungen: taby-hook-relay nicht gebaut — vorher `swift build`)")
        return
      }
      try await withServer(autoDecision: .init(behavior: .allow)) { _, rec, path in
        let (out, code) = try await runRelay(relay, socketPath: path, stdin: samplePayload + "\n")
        try expectEqual(code, 0)
        try expectEqual(JSONValue.parse(out)?["hookSpecificOutput"]?["decision"]?["behavior"], "allow")
        try expect(!out.hasSuffix("\n"), "eine Zeile ohne Umbruch wie das Node-Relay")
        try expectEqual(rec.requests.first?.toolName, "Bash")
      }
      let dir = try tempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let (out, code) = try await runRelay(relay, socketPath: dir.appendingPathComponent("weg.sock").path, stdin: samplePayload)
      try expectEqual(code, 0)
      try expectEqual(out, "")
    },
    CheckCase("Relay: Meldung wird ohne Antwort und schnell beendet (Exit 0, leer)") {
      guard let relay = builtRelayPath() else {
        print("      (Relay-Teil übersprungen: taby-hook-relay nicht gebaut — vorher `swift build`)")
        return
      }
      try await withServer { _, rec, path in
        let started = Date()
        let (out, code) = try await runRelay(relay, socketPath: path, stdin: waitingPayload + "\n")
        try expect(Date().timeIntervalSince(started) < 1, "Relay wartet nicht auf Meldungen")
        try expectEqual(code, 0)
        try expectEqual(out, "")
        try await waitFor("Meldung") { rec.notices.count == 1 }
        try expectEqual(rec.requests.count, 0)
      }
    },
  ])
}
