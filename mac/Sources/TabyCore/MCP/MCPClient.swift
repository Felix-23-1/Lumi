// MCP-Client für fremde Server (stdio, JSON-RPC 2.0, zeilenweise). Ein Server ist
// nur ein lokaler Prozess: Befehl als absoluter Pfad, ohne Shell, Argumente als Liste.
// Start, Cache und Leerlauf-Ende regelt `MCPManager` (MCPManager.swift).
import Foundation

public enum MCPClientError: Error, Equatable, LocalizedError {
  case launchFailed
  case timeout
  case closed
  case protocolError(String)
  case serverError(String)

  public var errorDescription: String? {
    switch self {
    case .launchFailed: "Der MCP-Server konnte nicht gestartet werden. Befehl und Pfad prüfen."
    case .timeout: "Der MCP-Server hat nicht rechtzeitig geantwortet."
    case .closed: "Die Verbindung zum MCP-Server ist beendet."
    case .protocolError(let m): "Ungültige Antwort des MCP-Servers: \(m)"
    case .serverError(let m): "Der MCP-Server meldet einen Fehler: \(m)"
    }
  }
}

public struct MCPToolInfo: Equatable, Sendable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue
  public var readOnlyHint: Bool
  public var destructiveHint: Bool

  public init(name: String, description: String, inputSchema: JSONValue,
              readOnlyHint: Bool = false, destructiveHint: Bool = false) {
    self.name = name; self.description = description; self.inputSchema = inputSchema
    self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
  }
}

public struct MCPCallResult: Equatable, Sendable {
  public var text: String
  public var isError: Bool
  public init(text: String, isError: Bool) { self.text = text; self.isError = isError }
}

/// Zeilen-Framing ohne Ein-/Ausgabe, damit es prüfbar ist.
public enum MCPFraming {
  public static func encode(_ message: JSONValue) -> Data {
    Data((message.jsonString() + "\n").utf8)
  }

  /// Schneidet vollständige Zeilen vom Puffer; ein unvollständiger Rest bleibt drin.
  public static func lines(_ buffer: inout Data) -> [Data] {
    var out: [Data] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      out.append(Data(buffer[buffer.startIndex..<nl]))
      buffer.removeSubrange(buffer.startIndex...nl)
    }
    return out
  }
}

/// Byte-Kanal zu einem Server. Im Betrieb ein Prozess, in Prüfungen ein Stub.
public protocol MCPTransport: AnyObject {
  /// Die Sitzung meldet hier an, wann Bytes ankommen und wann die Verbindung endet.
  func connect(receive: @escaping (Data) -> Void, closed: @escaping () -> Void)
  func start() throws
  func send(_ data: Data) throws
  func terminate()
}

/// Startet den Server als Prozess. stderr wird verworfen (kann Inhalte enthalten).
public final class MCPProcessTransport: MCPTransport, @unchecked Sendable {
  private let command: String
  private let args: [String]
  private let process = Process()
  private let stdin = Pipe()
  private let stdout = Pipe()
  private var onReceive: ((Data) -> Void)?
  private var onClosed: (() -> Void)?

  public init(command: String, args: [String]) {
    self.command = command
    self.args = args
  }

  public func connect(receive: @escaping (Data) -> Void, closed: @escaping () -> Void) {
    onReceive = receive
    onClosed = closed
  }

  /// Nur diese Umgebungsvariablen erben Server-Prozesse; keine anderen Geheimnisse der App.
  static var environment: [String: String] {
    let env = ProcessInfo.processInfo.environment
    return [
      "HOME": env["HOME"] ?? NSHomeDirectory(),
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "LANG": env["LANG"] ?? "en_US.UTF-8",
    ]
  }

  public func start() throws {
    guard command.hasPrefix("/") else { throw MCPClientError.launchFailed }
    // Ein sterbender Server darf Lumi nicht per SIGPIPE beenden; Schreibfehler kommen als Fehler an.
    signal(SIGPIPE, SIG_IGN)
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    process.environment = Self.environment
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        self?.onClosed?()
      } else {
        self?.onReceive?(data)
      }
    }
    process.terminationHandler = { [weak self] _ in self?.onClosed?() }
    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      throw MCPClientError.launchFailed
    }
  }

  public func send(_ data: Data) throws {
    try stdin.fileHandleForWriting.write(contentsOf: data)
  }

  /// SIGTERM, nach 2 s SIGKILL, falls der Server nicht beendet.
  public func terminate() {
    stdout.fileHandleForReading.readabilityHandler = nil
    guard process.isRunning else { return }
    let p = process
    let pid = p.processIdentifier
    p.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if p.isRunning { kill(pid, SIGKILL) }
    }
  }
}

/// Eine Verbindung zu einem Server: Anfragen mit Zeitlimit, Antworten per id.
public final class MCPSession: @unchecked Sendable {
  public static let initTimeout: TimeInterval = 10
  public static let callTimeout: TimeInterval = 60
  public static let protocolVersion = "2025-11-25"
  /// Obergrenze für eine Zeile ohne Zeilenende; darüber gilt der Server als kaputt.
  static let maxBuffer = 8 * 1024 * 1024
  static let maxToolPages = 20

  private let lock = NSLock()
  private let transport: MCPTransport
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var buffer = Data()
  private var nextId = 1
  private var open = true

  public init(transport: MCPTransport) {
    self.transport = transport
    transport.connect(receive: { [weak self] data in self?.deliver(data) },
                      closed: { [weak self] in self?.close() })
  }

  /// Startet einen Prozess für `command args`. Der Aufrufer ruft danach `initialize()`.
  public static func launch(command: String, args: [String]) throws -> MCPSession {
    let transport = MCPProcessTransport(command: command, args: args)
    let session = MCPSession(transport: transport)
    try transport.start()
    return session
  }

  public var isOpen: Bool { lock.withLock { open } }

  // MARK: Protokoll

  public func initialize() async throws {
    _ = try await request("initialize", .object([
      "protocolVersion": .string(Self.protocolVersion),
      "capabilities": .object([:]),
      "clientInfo": .object(["name": .string("Lumi"), "version": .string("2.0.0")]),
    ]), timeout: Self.initTimeout)
    try send(MCPFraming.encode(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])))
  }

  public func listTools() async throws -> [MCPToolInfo] {
    var tools: [MCPToolInfo] = []
    var cursor: String?
    for _ in 0..<Self.maxToolPages {
      var params: [String: JSONValue] = [:]
      if let cursor { params["cursor"] = .string(cursor) }
      let r = try await request("tools/list", .object(params), timeout: Self.initTimeout)
      tools += (r["tools"]?.arrayValue ?? []).compactMap(Self.toolInfo)
      cursor = r["nextCursor"]?.stringValue
      if cursor == nil { break }
    }
    return tools
  }

  public func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
    let r = try await request("tools/call", .object(["name": .string(name), "arguments": arguments]),
                              timeout: Self.callTimeout)
    let text = (r["content"]?.arrayValue ?? []).compactMap { part -> String? in
      part["type"]?.stringValue == "text" ? part["text"]?.stringValue : nil
    }.joined(separator: "\n")
    return MCPCallResult(text: text, isError: r["isError"]?.boolValue == true)
  }

  static func toolInfo(_ t: JSONValue) -> MCPToolInfo? {
    guard let name = t["name"]?.stringValue, !name.isEmpty else { return nil }
    let ann = t["annotations"]
    return MCPToolInfo(name: name, description: t["description"]?.stringValue ?? "",
                       inputSchema: t["inputSchema"] ?? .object(["type": .string("object")]),
                       readOnlyHint: ann?["readOnlyHint"]?.boolValue == true,
                       destructiveHint: ann?["destructiveHint"]?.boolValue == true)
  }

  /// Sendet eine Anfrage und wartet auf die Antwort. Bei Zeitüberschreitung wird der Server beendet.
  public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
    let id = lock.withLock { () -> Int in
      nextId += 1
      return nextId - 1
    }
    let timer = Task {
      try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      self.expire(id)
    }
    defer { timer.cancel() }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
      let registered = lock.withLock { () -> Bool in
        guard open else { return false }
        pending[id] = continuation
        return true
      }
      guard registered else {
        continuation.resume(throwing: MCPClientError.closed)
        return
      }
      do {
        try send(MCPFraming.encode(.object([
          "jsonrpc": .string("2.0"), "id": .number(Double(id)),
          "method": .string(method), "params": params,
        ])))
      } catch {
        fail(id, MCPClientError.closed)
      }
    }
  }

  // MARK: Eingang

  /// Vom Transport gerufen, wenn Bytes von stdout kommen.
  func deliver(_ data: Data) {
    var lines: [Data] = []
    var overflow = false
    lock.withLock {
      buffer.append(data)
      lines = MCPFraming.lines(&buffer)
      if buffer.count > Self.maxBuffer { overflow = true; buffer = Data() }
    }
    if overflow { close(); return }
    for line in lines { handle(line) }
  }

  private func handle(_ line: Data) {
    guard let text = String(data: line, encoding: .utf8), let msg = JSONValue.parse(text) else { return }
    if msg["method"] == nil, let id = msg["id"]?.numberValue {
      let continuation = lock.withLock { pending.removeValue(forKey: Int(id)) }
      guard let continuation else { return }
      if let err = msg["error"] {
        continuation.resume(throwing: MCPClientError.serverError(err["message"]?.stringValue ?? "Fehler"))
      } else {
        continuation.resume(returning: msg["result"] ?? .null)
      }
    } else if msg["method"] != nil, let id = msg["id"] {
      // Anfragen des Servers an uns (z. B. Sampling) werden abgelehnt, statt ihn hängen zu lassen.
      try? send(MCPFraming.encode(.object([
        "jsonrpc": .string("2.0"), "id": id,
        "error": .object(["code": .number(-32601), "message": .string("Nicht unterstützt")]),
      ])))
    }
  }

  // MARK: Ende

  private func expire(_ id: Int) {
    fail(id, MCPClientError.timeout)
    close()
  }

  private func fail(_ id: Int, _ error: Error) {
    let continuation = lock.withLock { pending.removeValue(forKey: id) }
    continuation?.resume(throwing: error)
  }

  /// Beendet die Verbindung und den Prozess; offene Anfragen scheitern mit `closed`.
  public func close() {
    let (wasOpen, waiting) = lock.withLock { () -> (Bool, [CheckedContinuation<JSONValue, Error>]) in
      guard open else { return (false, []) }
      open = false
      let all = Array(pending.values)
      pending.removeAll()
      return (true, all)
    }
    guard wasOpen else { return }
    for c in waiting { c.resume(throwing: MCPClientError.closed) }
    transport.terminate()
  }

  private func send(_ data: Data) throws {
    try transport.send(data)
  }
}
