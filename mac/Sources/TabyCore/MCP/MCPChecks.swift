// Prüfungen für Sources/TabyCore/MCP (MCP-Brücke zur App).
// Keine echten Netzwerkverbindungen; Sockets liegen in einem temporären Verzeichnis.
import Darwin
import Foundation

enum MCPChecks {
  static let suite = CheckSuite("MCP", MCPClientChecks.cases + [
    CheckCase("MCP-Brücke: höchstens 8 gleichzeitige Verbindungen, danach Platz nach Abschluss") {
      let gate = ConnectionGate(limit: MCPBridgeServer.maxConcurrentConnections)
      try expectEqual(MCPBridgeServer.maxConcurrentConnections, 8)
      for _ in 0..<8 { try expect(gate.enter()) }
      try expect(!gate.enter(), "neunte Verbindung wird abgewiesen")
      gate.leave()
      try expect(gate.enter(), "nach einem Abschluss wieder Platz")
    },
    // MARK: MCPProtocol (legacy)
    CheckCase("initialize übernimmt unterstützte Version") {
      let r = try result(send(rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])))
      try expectEqual(r["protocolVersion"]?.stringValue, "2025-06-18")
      try expectEqual(r["capabilities"]?["tools"]?["listChanged"]?.boolValue, false)
      try expectEqual(r["serverInfo"]?["name"]?.stringValue, "taby")
      try expectEqual(r["serverInfo"]?["title"]?.stringValue, "Lumi")
      try expectEqual(r["serverInfo"]?["version"]?.stringValue, "2.0.0")
      try expect((r["instructions"]?.stringValue ?? "").isEmpty == false, "instructions fehlt")
    },
    CheckCase("initialize mit unbekannter Version antwortet mit 2025-11-25") {
      let r = try result(send(rpc(1, "initialize", ["protocolVersion": "1999-01-01"])))
      try expectEqual(r["protocolVersion"]?.stringValue, "2025-11-25")
    },
    CheckCase("initialize ohne protocolVersion ist ungültig (-32602)") {
      let e = try errorObject(send(rpc(1, "initialize", ["capabilities": [:]])))
      try expectEqual(e["code"]?.numberValue, -32602)
    },
    CheckCase("notifications/initialized bekommt keine Antwort") {
      let out = try send(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))
      try expect(out == nil, "Notification darf keine Antwort erhalten")
      let other = try send(.object(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 3]]))
      try expect(other == nil, "notifications/cancelled darf keine Antwort erhalten")
    },
    CheckCase("Antworten des Clients bekommen keine Antwort") {
      let out = try send(.object(["jsonrpc": "2.0", "id": 5, "result": .object([:])]))
      try expect(out == nil, "Client-Antwort darf keine Antwort erhalten")
    },
    CheckCase("ping antwortet mit leerem Ergebnis") {
      let r = try result(send(rpc(2, "ping")))
      try expectEqual(r, .object([:]))
    },
    CheckCase("tools/list liefert Werkzeuge mit annotations (legacy ohne resultType)") {
      let r = try result(send(rpc(3, "tools/list"), backend: FakeMCPBackend()))
      let tools = try expectNotNil(r["tools"]?.arrayValue, "tools fehlt")
      try expectEqual(tools.count, 1)
      try expectEqual(tools[0]["name"]?.stringValue, FakeMCPBackend.sample.name)
      try expectEqual(tools[0]["title"]?.stringValue, FakeMCPBackend.sample.title)
      try expect(tools[0]["inputSchema"] != nil, "inputSchema fehlt")
      try expectEqual(tools[0]["annotations"]?["readOnlyHint"]?.boolValue, false)
      try expectEqual(tools[0]["annotations"]?["destructiveHint"]?.boolValue, false)
      try expect(r["resultType"] == nil, "legacy-Antwort darf kein resultType haben")
    },
    CheckCase("tools/call liefert content und isError und reicht Argumente durch") {
      let backend = FakeMCPBackend()
      let r = try result(send(
        rpc(4, "tools/call", ["name": "taby_add_task", "arguments": ["title": "Milch"]]), backend: backend))
      try expectEqual(r["content"]?.arrayValue?.first?["type"]?.stringValue, "text")
      try expectEqual(r["content"]?.arrayValue?.first?["text"]?.stringValue, "ok taby_add_task")
      try expectEqual(r["isError"]?.boolValue, false)
      try expectEqual(backend.lastArguments?["title"]?.stringValue, "Milch")
    },
    CheckCase("tools/call ohne laufende App: isError mit Hinweistext") {
      let backend = FakeMCPBackend(error: MCPBridgeError.appNotRunning)
      let r = try result(send(rpc(5, "tools/call", ["name": "taby_add_task"]), backend: backend))
      try expectEqual(r["isError"]?.boolValue, true)
      try expectEqual(r["content"]?.arrayValue?.first?["text"]?.stringValue, "Lumi läuft nicht. Bitte Lumi starten.")
    },
    CheckCase("tools/list ohne laufende App: leere Liste, kein Protokollfehler") {
      let backend = FakeMCPBackend(error: MCPBridgeError.appNotRunning)
      let resp = try expectNotNil(try send(rpc(6, "tools/list"), backend: backend), "keine Antwort")
      try expect(resp["error"] == nil, "tools/list darf keinen JSON-RPC-Fehler liefern")
      try expectEqual(resp["result"]?["tools"]?.arrayValue?.count, 0)
    },
    CheckCase("tools/call ohne name oder mit falschen arguments ist ungültig (-32602)") {
      let noName = try errorObject(send(rpc(7, "tools/call", ["arguments": [:]])))
      try expectEqual(noName["code"]?.numberValue, -32602)
      let badArgs = try errorObject(send(rpc(8, "tools/call", ["name": "x", "arguments": "kaputt"])))
      try expectEqual(badArgs["code"]?.numberValue, -32602)
    },

    // MARK: MCPProtocol (modern)
    CheckCase("server/discover liefert DiscoverResult") {
      let r = try result(send(rpc(9, "server/discover")))
      try expectEqual(r["resultType"]?.stringValue, "complete")
      try expectEqual(r["supportedVersions"]?.arrayValue?.first?.stringValue, "2026-07-28")
      try expectEqual(r["ttlMs"]?.numberValue, 3_600_000)
      try expectEqual(r["cacheScope"]?.stringValue, "public")
      try expectEqual(r["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue, "taby")
      try expectEqual(r["capabilities"]?["tools"]?["listChanged"]?.boolValue, false)
    },
    CheckCase("Modern tools/list mit _meta liefert resultType complete") {
      let r = try result(send(modernRPC(10, "tools/list"), backend: FakeMCPBackend()))
      try expectEqual(r["resultType"]?.stringValue, "complete")
      try expectEqual(r["tools"]?.arrayValue?.count, 1)
    },
    CheckCase("Modern tools/call mit _meta liefert resultType complete") {
      let backend = FakeMCPBackend()
      let r = try result(send(
        modernRPC(11, "tools/call", ["name": "taby_add_task", "arguments": ["title": "Brot"]]), backend: backend))
      try expectEqual(r["resultType"]?.stringValue, "complete")
      try expectEqual(r["isError"]?.boolValue, false)
      try expectEqual(backend.lastArguments?["title"]?.stringValue, "Brot")
    },
    CheckCase("Nicht unterstützte Protokollversion: -32022 mit supported und requested") {
      var msg = rpc(12, "tools/list")
      msg = withMeta(msg, version: "1900-01-01")
      let e = try errorObject(send(msg))
      try expectEqual(e["code"]?.numberValue, -32022)
      try expectEqual(e["data"]?["supported"]?.arrayValue?.first?.stringValue, "2026-07-28")
      try expectEqual(e["data"]?["requested"]?.stringValue, "1900-01-01")
    },

    // MARK: MCPProtocol (Fehler)
    CheckCase("unbekannte Methode: -32601") {
      let e = try errorObject(send(rpc(13, "foo/bar")))
      try expectEqual(e["code"]?.numberValue, -32601)
    },
    CheckCase("kaputtes JSON: -32700 mit id null") {
      let out = try expectNotNil(MCPProtocol.handle("{nicht json", backend: FakeMCPBackend(), log: { _ in }),
        "keine Antwort")
      let resp = try expectNotNil(JSONValue.parse(out), "Antwort kein JSON")
      try expectEqual(resp["error"]?["code"]?.numberValue, -32700)
      try expectEqual(resp["id"], .null)
    },
    CheckCase("Array statt Objekt: -32600") {
      let e = try errorObject(send(.array([.number(1)])))
      try expectEqual(e["code"]?.numberValue, -32600)
    },

    // MARK: Bridge (Socket)
    CheckCase("Socket-Bindung: umask bleibt nach parallelen Bindungen unverändert, Dateien ohne Gruppen-/Weltrechte") {
      let dir = try tempSocketDir()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let original = umask(0o022)
      _ = umask(original)
      DispatchQueue.concurrentPerform(iterations: 16) { i in
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array((dir + "/s\(i).sock").utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
          buf.copyBytes(from: bytes)
          buf[bytes.count] = 0
        }
        _ = PrivateSocket.bindPrivate(fd, &addr)
      }
      let after = umask(0o022)
      _ = umask(after)
      try expectEqual(after, original, "umask wurde nicht zurückgestellt")
      for i in 0..<16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/s\(i).sock")
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try expectEqual(mode & 0o077, 0, "Socket \(i) ist für andere lesbar")
      }
    },
    CheckCase("Bridge: Rundlauf list und call über den Socket") {
      let dir = try tempSocketDir()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let host = FakeMCPHost()
      let server = MCPBridgeServer(socketPath: dir + "/s.sock", host: host)
      try server.start()
      defer { server.stop() }
      let client = MCPBridgeClient(socketPath: dir + "/s.sock")
      try expectEqual(try client.listTools(), [FakeMCPHost.sample], "Werkzeugliste")
      let r = try client.call(name: "taby_add_task", arguments: ["title": "Milch"])
      try expectEqual(r, MCPToolResult(text: "Milch angelegt", isError: false))
      try expectEqual(host.lastTitle, "Milch")
    },
    CheckCase("Bridge: Host-Fehler kommt als isError zurück") {
      let dir = try tempSocketDir()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let host = FakeMCPHost()
      host.failing = true
      let server = MCPBridgeServer(socketPath: dir + "/s.sock", host: host)
      try server.start()
      defer { server.stop() }
      let r = try MCPBridgeClient(socketPath: dir + "/s.sock").call(name: "taby_add_task", arguments: [:])
      try expectEqual(r.isError, true)
    },
    CheckCase("Bridge: ohne laufende App -> appNotRunning") {
      let dir = try tempSocketDir()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let client = MCPBridgeClient(socketPath: dir + "/nichts.sock")
      do {
        _ = try client.listTools()
        throw fail("listTools sollte ohne App fehlschlagen")
      } catch let e as MCPBridgeError {
        try expectEqual(e, MCPBridgeError.appNotRunning)
      }
      do {
        _ = try client.call(name: "taby_add_task", arguments: [:])
        throw fail("call sollte ohne App fehlschlagen")
      } catch let e as MCPBridgeError {
        try expectEqual(e.userText, "Lumi läuft nicht. Bitte Lumi starten.")
      }
    },
    CheckCase("Bridge: zu langer Socket-Pfad wird abgelehnt") {
      let server = MCPBridgeServer(socketPath: "/" + String(repeating: "a", count: 120), host: FakeMCPHost())
      do {
        try server.start()
        throw fail("start sollte am langen Pfad scheitern")
      } catch MCPBridgeServerError.socketPathTooLong {
      }
    },

    // MARK: End-to-End (taby-mcp als Prozess)
    CheckCase("taby-mcp End-to-End über stdio") {
      guard let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("taby-mcp"),
        FileManager.default.isExecutableFile(atPath: binary.path)
      else {
        print("  (MCP End-to-End übersprungen: taby-mcp ist nicht gebaut; erst `swift build` ausführen)")
        return
      }
      let dir = try tempSocketDir()
      defer { try? FileManager.default.removeItem(atPath: dir) }
      let server = MCPBridgeServer(socketPath: dir + "/s.sock", host: FakeMCPHost())
      try server.start()
      defer { server.stop() }

      let process = Process()
      process.executableURL = binary
      process.arguments = ["--socket", dir + "/s.sock"]
      let stdin = Pipe()
      let stdout = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = FileHandle.nullDevice
      try process.run()
      let script = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"taby_add_task","arguments":{"title":"Milch"}}}"#,
      ].joined(separator: "\n") + "\n"
      stdin.fileHandleForWriting.write(Data(script.utf8))
      try? stdin.fileHandleForWriting.close()
      let out = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      try expectEqual(process.terminationStatus, 0, "taby-mcp soll bei EOF mit 0 beenden")

      let lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
      try expectEqual(lines.count, 3, "stdout nur Protokollzeilen (ohne Notification-Antwort)")
      let initResp = try expectNotNil(JSONValue.parse(lines[0]), "initialize-Antwort kein JSON")
      try expectEqual(initResp["result"]?["serverInfo"]?["name"]?.stringValue, "taby")
      let listResp = try expectNotNil(JSONValue.parse(lines[1]), "tools/list-Antwort kein JSON")
      try expectEqual(listResp["result"]?["tools"]?.arrayValue?.first?["name"]?.stringValue, "taby_add_task")
      let callResp = try expectNotNil(JSONValue.parse(lines[2]), "tools/call-Antwort kein JSON")
      try expectEqual(callResp["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "Milch angelegt")
      try expectEqual(callResp["result"]?["isError"]?.boolValue, false)
    },
  ])
}

// MARK: - Hilfen

/// Fake-Werkzeugquelle für MCPProtocol-Prüfungen.
private final class FakeMCPBackend: MCPToolBackend {
  static let sample = MCPTool(
    name: "taby_add_task", title: "Aufgabe anlegen", description: "Legt eine Aufgabe an.",
    inputSchema: .object(["type": .string("object")]), readOnly: false)
  let error: Error?
  var lastArguments: JSONValue?

  init(error: Error? = nil) { self.error = error }

  func listTools() throws -> [MCPTool] {
    if let error { throw error }
    return [Self.sample]
  }

  func call(name: String, arguments: JSONValue) throws -> MCPToolResult {
    if let error { throw error }
    lastArguments = arguments
    return MCPToolResult(text: "ok \(name)", isError: false)
  }
}

/// Fake-App für Bridge-Prüfungen (Socket-Rundlauf).
private final class FakeMCPHost: MCPToolHost {
  static let sample = MCPTool(
    name: "taby_add_task", title: "Aufgabe anlegen", description: "Legt eine Aufgabe an.",
    inputSchema: .object(["type": .string("object")]), readOnly: false)
  var failing = false
  var lastTitle: String?

  func tools() -> [MCPTool] { [Self.sample] }

  func call(name: String, arguments: JSONValue) async -> MCPToolResult {
    if failing { return MCPToolResult(text: "Kaputt", isError: true) }
    lastTitle = arguments["title"]?.stringValue
    return MCPToolResult(text: "\(lastTitle ?? "?") angelegt", isError: false)
  }
}

private func rpc(_ id: Int, _ method: String, _ params: [String: JSONValue]? = nil) -> JSONValue {
  var o: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]
  if let params { o["params"] = .object(params) }
  return .object(o)
}

/// Anfrage mit `_meta` für die moderne Protokoll-Ära.
private func modernRPC(_ id: Int, _ method: String, _ params: [String: JSONValue] = [:]) -> JSONValue {
  var p = params
  p["_meta"] = .object([
    "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
    "io.modelcontextprotocol/clientCapabilities": .object([:]),
  ])
  return rpc(id, method, p)
}

private func withMeta(_ message: JSONValue, version: String) -> JSONValue {
  guard case .object(var o) = message else { return message }
  var p = o["params"]?.objectValue ?? [:]
  p["_meta"] = .object(["io.modelcontextprotocol/protocolVersion": .string(version)])
  o["params"] = .object(p)
  return .object(o)
}

/// Sendet eine Nachricht an die Protokollschicht und liefert die geparste Antwort.
private func send(_ message: JSONValue, backend: MCPToolBackend = FakeMCPBackend()) throws -> JSONValue? {
  guard let out = MCPProtocol.handle(message.jsonString(), backend: backend, log: { _ in }) else { return nil }
  return try expectNotNil(JSONValue.parse(out), "Antwort ist kein JSON: \(out)")
}

/// Ergebnisfeld einer Antwort; schlägt fehl, wenn keine Antwort oder ein Fehler kam.
private func result(_ response: JSONValue?) throws -> JSONValue {
  let resp = try expectNotNil(response, "keine Antwort")
  if let e = resp["error"] { throw fail("unerwarteter Fehler: \(e.jsonString())") }
  return try expectNotNil(resp["result"], "result fehlt")
}

/// Fehlerfeld einer Antwort; schlägt fehl, wenn keine Antwort oder kein Fehler kam.
private func errorObject(_ response: JSONValue?) throws -> JSONValue {
  let resp = try expectNotNil(response, "keine Antwort")
  return try expectNotNil(resp["error"], "error fehlt")
}

/// Temporäres Verzeichnis für Sockets (kurzer Pfad, da sun_path nur 104 Byte fasst).
private func tempSocketDir() throws -> String {
  let dir = NSTemporaryDirectory() + "taby-mcp-" + String(UUID().uuidString.prefix(8)).lowercased()
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir
}
