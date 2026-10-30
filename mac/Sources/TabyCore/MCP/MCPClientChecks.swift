// Prüfungen für den MCP-Client (fremde Server). Stub-Transport für Protokoll und Zeiten,
// ein kleines Shell-Skript als echter Server, ControllableClock für den Leerlauf.
// Wird über MCPChecks.suite eingebunden.
import Foundation

/// Stub: beantwortet jede Anfrage über `respond`, merkt sich gesendete Nachrichten.
private final class StubTransport: MCPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var receiveHandler: ((Data) -> Void)?
  private var closedHandler: (() -> Void)?
  private(set) var sent: [JSONValue] = []
  private(set) var terminated = false
  let respond: (JSONValue) -> [JSONValue]

  init(respond: @escaping (JSONValue) -> [JSONValue]) { self.respond = respond }

  func connect(receive: @escaping (Data) -> Void, closed: @escaping () -> Void) {
    lock.withLock { receiveHandler = receive; closedHandler = closed }
  }
  func start() throws {}
  func send(_ data: Data) throws {
    let text = String(decoding: data.dropLast(), as: UTF8.self)
    guard let msg = JSONValue.parse(text) else { return }
    lock.withLock { sent.append(msg) }
    let replies = respond(msg)
    let handler = lock.withLock { receiveHandler }
    for r in replies { handler?(MCPFraming.encode(r)) }
  }
  func terminate() { lock.withLock { terminated = true } }
}

private final class MCPCheckBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}

private func reply(_ req: JSONValue, _ result: JSONValue) -> JSONValue {
  .object(["jsonrpc": .string("2.0"), "id": req["id"] ?? .null, "result": result])
}

/// Antwortet auf initialize, tools/list und tools/call wie ein kleiner Server.
private func goodServer(_ req: JSONValue) -> [JSONValue] {
  switch req["method"]?.stringValue {
  case "initialize": return [reply(req, .object(["protocolVersion": .string("2025-11-25")]))]
  case "tools/list":
    return [reply(req, .object(["tools": .array([
      .object(["name": .string("search_docs"), "description": .string("Sucht"),
               "inputSchema": .object(["type": .string("object")])]),
      .object(["name": .string("delete_item"), "description": .string("Löscht"),
               "inputSchema": .object(["type": .string("object")])]),
    ])]))]
  case "tools/call":
    return [reply(req, .object(["content": .array([.object(["type": .string("text"), "text": .string("Treffer")])]),
                                "isError": .bool(false)]))]
  default: return []
  }
}

private func serverConfig(_ id: String = "docs", allowWrite: Bool = false, enabled: Bool = true) -> MCPServerConfig {
  MCPServerConfig(id: id, name: "Docs", command: "/bin/echo", args: ["x"], enabled: enabled, allowWrite: allowWrite)
}

enum MCPClientChecks {
  static var cases: [CheckCase] {
    [
      // MARK: Framing
      CheckCase("MCP-Client: Framing – eine Nachricht ist genau eine Zeile, Zeilenumbruch im Text bleibt escaped") {
        let data = MCPFraming.encode(.object(["s": .string("a\nb")]))
        try expectEqual(data.filter { $0 == 0x0A }.count, 1, "nur das abschließende Zeilenende")
        try expectEqual(data.last, 0x0A)
      },
      CheckCase("MCP-Client: Framing – vollständige Zeilen werden geschnitten, Rest bleibt im Puffer") {
        var buffer = Data("a\nbb\nccc".utf8)
        let lines = MCPFraming.lines(&buffer)
        try expectEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["a", "bb"])
        try expectEqual(String(decoding: buffer, as: UTF8.self), "ccc")
      },
      // MARK: Namen und Richtlinie
      CheckCase("MCP-Client: Werkzeugname – mcp_<Server>_<Tool>, nur erlaubte Zeichen, höchstens 64") {
        try expectEqual(MCPToolPolicy.offeredName(serverId: "my server", tool: "Search.Pages"),
                        "mcp_my_server_Search_Pages")
        let long = MCPToolPolicy.offeredName(serverId: "s", tool: String(repeating: "x", count: 200))
        try expectEqual(long.count, 64)
        try expect(long.hasPrefix("mcp_s_"))
      },
      CheckCase("MCP-Client: Lesen/Schreiben – Lesewörter lesen, sonst schreiben; readOnlyHint allein reicht nicht") {
        try expect(!MCPToolPolicy.isWrite(MCPToolInfo(name: "search_docs", description: "", inputSchema: .null)))
        try expect(!MCPToolPolicy.isWrite(MCPToolInfo(name: "list_pages", description: "", inputSchema: .null)))
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "fetch_page", description: "", inputSchema: .null)),
                   "fetch ist kein Lesewort mehr")
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "list_pages", description: "",
                                                     inputSchema: .object(["properties": .object(["URL": .object([:])])]))),
                   "Parameter url/uri/href macht schreibend, auch ohne Schreibwort")
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "search_x", description: "",
                                                     inputSchema: .object(["properties": .object(["href": .object([:])])]))))
        try expect(!MCPToolPolicy.isWrite(MCPToolInfo(name: "search_x", description: "",
                                                      inputSchema: .object(["properties": .object(["query": .object([:])])]))))
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "delete_item", description: "", inputSchema: .null)))
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "create_note", description: "", inputSchema: .null)))
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "run", description: "", inputSchema: .null, readOnlyHint: true)),
                   "readOnlyHint allein macht nichts lesend")
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "search_x", description: "", inputSchema: .null, readOnlyHint: true,
                                                     destructiveHint: true)))
        try expect(MCPToolPolicy.isWrite(MCPToolInfo(name: "get_x", description: "", inputSchema: .null, destructiveHint: true)),
                   "destructiveHint gewinnt über den Namen")
      },
      CheckCase("MCP-Client: Ergebnis wird als fremder Inhalt verpackt") {
        let ok = MCPToolPolicy.resultJSON(MCPCallResult(text: "Seite A", isError: false))
        try expectEqual(ok["ok"]?.boolValue, true)
        let wrapped = ok["untrusted_content"]?.stringValue ?? ""
        try expect(wrapped.hasPrefix(ForeignContent.open), "Marker fehlt")
        try expect(wrapped.contains("Seite A"))
        let bad = MCPToolPolicy.resultJSON(MCPCallResult(text: "x", isError: true))
        try expectEqual(bad["ok"]?.boolValue, false)
        try expectEqual(bad["code"]?.stringValue, "MCP")
      },
      CheckCase("MCP-Client: Argumente in der Karte werden gekürzt, die volle Fassung bleibt vollständig") {
        let big = JSONValue.object(["t": .string(String(repeating: "a", count: 1000))])
        try expect(MCPToolPolicy.argumentsSummary(big).count <= 302)
        try expect(MCPToolPolicy.fullArgumentsText(big).count > 1000, "volle Fassung ungekürzt")
        try expect(!MCPToolPolicy.fullArgumentsText(.object(["api_key": .string("sk-abcdefgh12345")])).contains("sk-abcdefgh12345"),
                   "volle Fassung ist geschwärzt")
      },
      CheckCase("MCP-Client: Namenskollision – a_b+c und a+b_c bekommen eindeutige Namen") {
        let first = MCPToolPolicy.offeredName(serverId: "a_b", tool: "c")
        let second = MCPToolPolicy.offeredName(serverId: "a", tool: "b_c")
        try expectEqual(first, second, "gleicher Rohname")
        let u1 = MCPToolPolicy.uniqueName(first, taken: [])
        let u2 = MCPToolPolicy.uniqueName(second, taken: [u1])
        let u3 = MCPToolPolicy.uniqueName(second, taken: [u1, u2])
        try expectEqual([u1, u2, u3], ["mcp_a_b_c", "mcp_a_b_c_2", "mcp_a_b_c_3"])
        let long = String(repeating: "x", count: 64)
        try expectEqual(MCPToolPolicy.uniqueName(long, taken: [long]).count, 64, "auch mit Suffix höchstens 64")
      },
      CheckCase("MCP-Client: Bestätigung – nach Umbau der Route zeigt der Name auf ein anderes Werkzeug, der Pin passt nicht") {
        func oneTool(_ name: String) -> (JSONValue) -> [JSONValue] {
          { req in
            switch req["method"]?.stringValue {
            case "initialize": return [reply(req, .object(["protocolVersion": .string("2025-11-25")]))]
            case "tools/list":
              return [reply(req, .object(["tools": .array([.object(["name": .string(name), "description": .string("x"),
                                                                    "inputSchema": .object(["type": .string("object")])])])]))]
            default: return []
            }
          }
        }
        let manager = MCPManager(clock: ControllableClock("2026-10-16T10:00"), launcher: { c in
          MCPSession(transport: StubTransport(respond: oneTool(c.id == "a_b" ? "c" : "b_c")))
        })
        let before = await manager.offeredTools(for: [serverConfig("a_b", allowWrite: true)])
        try expectEqual(before.map(\.offeredName), ["mcp_a_b_c"])
        let pin = MCPPin(try expectNotNil(manager.route(named: "mcp_a_b_c")))
        // Ein zweiter Server kommt hinzu; der Name „mcp_a_b_c“ gehört jetzt dem Server „a“.
        let after = await manager.offeredTools(for: [serverConfig("a_b", allowWrite: true), serverConfig("a", allowWrite: true)])
        try expectEqual(after.map(\.offeredName), ["mcp_a_b_c", "mcp_a_b_c_2"])
        let now = try expectNotNil(manager.route(named: "mcp_a_b_c"))
        try expectEqual(now.server.id, "a", "sortiert nach Server-ID, nicht nach Antwortzeit")
        try expect(MCPPin(now) != pin, "Pin verlangt Server a_b, Route zeigt auf a: Bestätigung wird abgelehnt")
        try expectEqual(MCPPin(try expectNotNil(manager.route(named: "mcp_a_b_c_2"))).serverId, "a_b")
      },
      // MARK: Sitzung mit Stub
      CheckCase("MCP-Client: Sitzung – initialize, tools/list und tools/call über Stub") {
        let stub = StubTransport(respond: goodServer)
        let session = MCPSession(transport: stub)
        try await session.initialize()
        let tools = try await session.listTools()
        try expectEqual(tools.map(\.name), ["search_docs", "delete_item"])
        try expect(MCPToolPolicy.isWrite(tools[1]))
        let r = try await session.callTool(name: "search_docs", arguments: .object([:]))
        try expectEqual(r, MCPCallResult(text: "Treffer", isError: false))
        try expectEqual(stub.sent.first?["method"]?.stringValue, "initialize")
        session.close()
        try expect(stub.terminated, "Transport beendet")
      },
      CheckCase("MCP-Client: Zeitlimit – ohne Antwort kommt timeout, der Server wird beendet") {
        let stub = StubTransport(respond: { _ in [] })
        let session = MCPSession(transport: stub)
        do {
          _ = try await session.request("tools/list", .object([:]), timeout: 0.05)
          throw CheckFailure(message: "Zeitlimit hätte greifen müssen", location: "MCPClientChecks")
        } catch let e as MCPClientError {
          try expectEqual(e, .timeout)
        }
        try expect(!session.isOpen)
        try expect(stub.terminated, "Prozess wird bei Zeitüberschreitung beendet")
      },
      CheckCase("MCP-Client: Fehlerantwort des Servers wird als Fehler gemeldet") {
        let stub = StubTransport(respond: { req in
          [.object(["jsonrpc": .string("2.0"), "id": req["id"] ?? .null,
                    "error": .object(["code": .number(-1), "message": .string("kaputt")])])]
        })
        let session = MCPSession(transport: stub)
        do {
          _ = try await session.request("x", .object([:]), timeout: 1)
          throw CheckFailure(message: "Fehler erwartet", location: "MCPClientChecks")
        } catch let e as MCPClientError {
          try expectEqual(e, .serverError("kaputt"))
        }
        try expect(session.isOpen, "ein Fehler des Servers beendet die Sitzung nicht")
      },
      CheckCase("MCP-Client: relativer Befehl wird nicht gestartet (kein Shell-Umweg)") {
        do {
          _ = try MCPSession.launch(command: "fake-server", args: [])
          throw CheckFailure(message: "Start hätte scheitern müssen", location: "MCPClientChecks")
        } catch let e as MCPClientError {
          try expectEqual(e, .launchFailed)
        }
      },
      // MARK: Manager
      CheckCase("MCP-Client: Manager – Werkzeuge werden gecacht, ohne Schreibrecht kein schreibendes Werkzeug") {
        let clock = ControllableClock("2026-10-16T10:00")
        let starts = MCPCheckBox(0)
        let manager = MCPManager(clock: clock, launcher: { _ in
          starts.value += 1
          return MCPSession(transport: StubTransport(respond: goodServer))
        })
        let first = await manager.offeredTools(for: [serverConfig()])
        try expectEqual(first.map(\.offeredName), ["mcp_docs_search_docs"])
        try expectEqual(starts.value, 1)
        let second = await manager.offeredTools(for: [serverConfig()])
        try expectEqual(second.count, 1)
        try expectEqual(starts.value, 1, "zweiter Zug nutzt den Cache")
        let writing = await manager.offeredTools(for: [serverConfig(allowWrite: true)])
        try expectEqual(writing.map(\.offeredName), ["mcp_docs_search_docs", "mcp_docs_delete_item"])
        try expect(writing.first(where: { $0.tool.name == "delete_item" })?.isWrite == true)
        try expect(manager.route(named: "mcp_docs_delete_item") != nil)
      },
      CheckCase("MCP-Client: Manager – deaktivierter Server wird nicht angeboten und nicht gestartet") {
        let starts = MCPCheckBox(0)
        let manager = MCPManager(clock: ControllableClock("2026-10-16T10:00"), launcher: { _ in
          starts.value += 1
          return MCPSession(transport: StubTransport(respond: goodServer))
        })
        let offered = await manager.offeredTools(for: [serverConfig(enabled: false)])
        try expect(offered.isEmpty)
        try expectEqual(starts.value, 0)
      },
      CheckCase("MCP-Client: Leerlauf – nach 5 Minuten ohne Nutzung wird der Server beendet") {
        let clock = ControllableClock("2026-10-16T10:00")
        let stubs = MCPCheckBox<[StubTransport]>([])
        let manager = MCPManager(clock: clock, launcher: { _ in
          let s = StubTransport(respond: goodServer)
          stubs.value.append(s)
          return MCPSession(transport: s)
        })
        _ = await manager.offeredTools(for: [serverConfig()])
        clock.advance(seconds: 4 * 60)
        manager.sweep()
        try expect(!(stubs.value.first?.terminated ?? true), "nach 4 Minuten läuft er noch")
        clock.advance(seconds: 61)
        manager.sweep()
        try expect(stubs.value.first?.terminated == true, "nach mehr als 5 Minuten beendet")
        // Der Werkzeug-Cache bleibt: der nächste Zug startet den Server nicht neu.
        _ = await manager.offeredTools(for: [serverConfig()])
        try expectEqual(stubs.value.count, 1)
      },
      CheckCase("MCP-Client: Fehlender Server – Zug bricht nicht ab, Server wird kurz übersprungen") {
        let starts = MCPCheckBox(0)
        let manager = MCPManager(clock: ControllableClock("2026-10-16T10:00"), launcher: { _ in
          starts.value += 1
          throw MCPClientError.launchFailed
        })
        let first = await manager.offeredTools(for: [serverConfig()])
        try expect(first.isEmpty)
        _ = await manager.offeredTools(for: [serverConfig()])
        try expectEqual(starts.value, 1, "innerhalb der Sperrzeit kein neuer Start")
      },
      CheckCase("MCP-Client: Klassifikation – Namenswörter, Schreibwörter und Hinweise") {
        func w(_ name: String, read: Bool = false, destructive: Bool = false) -> Bool {
          MCPToolPolicy.isWrite(MCPToolInfo(name: name, description: "", inputSchema: .null,
                                            readOnlyHint: read, destructiveHint: destructive))
        }
        try expect(w("get_and_delete"), "Lesewort am Anfang, aber Schreibwort darin")
        try expect(w("get_or_create_x"))
        try expect(!w("listUsers"), "camelCase wird in Wörter getrennt")
        try expect(!w("readFile"))
        try expect(w("run_query"), "run ist Schreibwort, query allein liest nicht")
        try expect(!w("list-users"))
        try expect(w("fetch.page"), "fetch ist kein Lesewort mehr")
        try expect(!w("show_items"))
        try expect(w("updateList"), "Schreibwort im camelCase-Namen")
        try expect(w("docs_search"), "Lesewort nicht am Anfang")
        try expect(w("delete_me", read: true), "readOnlyHint allein reicht nicht, Name bleibt maßgeblich")
        try expect(!w("list_me", read: true), "Lesewort und kein Schreibwort: lesend")
        try expect(w("list_x", read: true, destructive: true), "destructiveHint gewinnt")
        try expect(!w("search"), "ein Lesewort allein liest")
      },
      CheckCase("MCP-Client: Schwärzen – Schlüssel, Tokens und Flags werden verborgen, Pfade bleiben") {
        try expectEqual(MCPToolPolicy.redactArgs(["--api-key", "abc", "--port", "80"]),
                        ["--api-key", "[verborgen]", "--port", "80"])
        try expectEqual(MCPToolPolicy.redactArgs(["--token=xyz123"]).first, "--token=[verborgen]")
        try expect(!MCPToolPolicy.redactText("sk-abcdefgh12345678").contains("abcdefgh"), "sk-Schlüssel")
        try expect(!MCPToolPolicy.redactText(#"{"password": "hunter2"}"#).contains("hunter2"), "JSON-Passwort")
        try expect(!MCPToolPolicy.redactText("token=secretvalue").contains("secretvalue"), "token=")
        try expect(!MCPToolPolicy.redactText("0123456789abcdef0123456789abcdef").contains("0123"), "langer Hex-Wert")
        try expectEqual(MCPToolPolicy.redactText("/usr/local/bin/server --verbose"), "/usr/local/bin/server --verbose")
        try expectEqual(MCPToolPolicy.redactText("Rechnung vom 16.10."), "Rechnung vom 16.10.")
      },
      CheckCase("MCP-Client: Umgebung – nur HOME, PATH und LANG werden an den Server gereicht") {
        let env = MCPProcessTransport.environment
        try expectEqual(Set(env.keys), ["HOME", "PATH", "LANG"])
        try expectEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
      },
      CheckCase("MCP-Client: Server parallel – ein hängender Server verzögert den Zug nur bis zur Frist") {
        let manager = MCPManager(clock: ControllableClock("2026-10-16T10:00"), launcher: { _ in
          MCPSession(transport: StubTransport(respond: { _ in [] }))  // antwortet nie
        })
        manager.turnDeadline = 0.2
        let started = DispatchTime.now().uptimeNanoseconds
        let routes = await manager.offeredTools(for: [serverConfig("a"), serverConfig("b")])
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        try expect(routes.isEmpty)
        try expect(seconds < 2, "zwei Server nacheinander wären 20 s; Frist greift (\(seconds) s)")
      },
      // MARK: Echter Prozess
      CheckCase("MCP-Client: echter Prozess – Skript spricht JSON-RPC über stdio") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-mcp.sh")
        try fakeServerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let session = try MCPSession.launch(command: script.path, args: [])
        defer { session.close() }
        try await session.initialize()
        let tools = try await session.listTools()
        try expectEqual(tools.map(\.name), ["search_docs", "delete_item"])
        let r = try await session.callTool(name: "search_docs", arguments: .object(["q": .string("x")]))
        try expectEqual(r.text, "Ergebnis mit Zeilenumbruch\nzweiter Teil")
        try expect(!r.isError)
      },
    ]
  }

  /// Minimaler Server: liest JSON-Zeilen von stdin und antwortet mit festen Ergebnissen.
  static let fakeServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    case "$line" in
      *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}}\n' "$id" ;;
      *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"search_docs","description":"Sucht","inputSchema":{"type":"object"}},{"name":"delete_item","description":"Löscht","inputSchema":{"type":"object"},"annotations":{"destructiveHint":true}}]}}\n' "$id" ;;
      *'"method":"tools/call"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Ergebnis mit Zeilenumbruch\\nzweiter Teil"}],"isError":false}}\n' "$id" ;;
    esac
  done
  """#
}
