// Unix-Socket-Brücke zwischen taby-mcp und der laufenden App (Muster wie
// Agents/AgentHookServer.swift und TabyHookRelay).
//
// Protokoll: pro Verbindung EINE Anfrage als JSON-Zeile + "\n", EINE Antwort
// als JSON-Zeile + "\n", dann schließen.
//   Anfrage:  {"op":"tools/list"}
//             {"op":"tools/call","name":"…","arguments":{…}}
//   Antwort:  {"ok":true,"tools":[…]}  |  {"ok":true,"text":"…","isError":false}
//             {"ok":false,"error":"…"}
// Socket-Datei 0600, Pfad max. 104 Byte (sun_path).
import Darwin
import Foundation

/// Zählt laufende Verbindungen (Arbeitsthreads), damit ein Prozess die Brücke nicht fluten kann.
final class ConnectionGate: @unchecked Sendable {
  private let limit: Int
  private let lock = NSLock()
  private var active = 0

  init(limit: Int) { self.limit = limit }

  func enter() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard active < limit else { return false }
    active += 1
    return true
  }

  func leave() {
    lock.lock(); defer { lock.unlock() }
    active -= 1
  }
}

public final class MCPBridgeServer {
  public let socketPath: String
  private let host: MCPToolHost
  private let queue = DispatchQueue(label: "taby.mcp-bridge")
  private let workers = DispatchQueue(label: "taby.mcp-bridge.workers", attributes: .concurrent)
  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  /// Höchstens so viele Verbindungen gleichzeitig; weitere werden sofort geschlossen.
  static let maxConcurrentConnections = 8
  private let gate = ConnectionGate(limit: MCPBridgeServer.maxConcurrentConnections)

  public init(socketPath: String, host: MCPToolHost) {
    self.socketPath = socketPath
    self.host = host
  }

  deinit { stop() }

  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard listenFD < 0 else { return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw MCPBridgeServerError.socketPathTooLong(socketPath)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: pathBytes)
      buf[pathBytes.count] = 0
    }
    try? FileManager.default.createDirectory(
      atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    unlink(socketPath)  // veralteter Socket eines früheren Laufs

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MCPBridgeServerError.socketFailed("socket: \(errno)") }
    // Die Datei entsteht schon privat (0600 statt 0644), kein Fenster für andere Nutzer.
    let bound = PrivateSocket.bindPrivate(fd, &addr)
    guard bound == 0 else {
      let e = errno
      close(fd)
      throw MCPBridgeServerError.socketFailed("bind: \(e)")
    }
    chmod(socketPath, 0o600)  // nur der eigene Nutzer
    guard listen(fd, 8) == 0 else {
      let e = errno
      close(fd)
      unlink(socketPath)
      throw MCPBridgeServerError.socketFailed("listen: \(e)")
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    listenFD = fd
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    src.setEventHandler { [weak self] in self?.acceptPending() }
    src.resume()
    acceptSource = src
  }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard listenFD >= 0 else { return }
    acceptSource?.cancel()
    acceptSource = nil
    close(listenFD)
    listenFD = -1
    unlink(socketPath)
  }

  // MARK: Intern

  private func acceptPending() {
    let lfd = listenFD
    guard lfd >= 0 else { return }
    let host = self.host
    while true {
      let fd = accept(lfd, nil, nil)
      if fd < 0 { return }
      guard gate.enter() else { close(fd); continue }
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      let slot = gate
      workers.async {
        MCPBridgeServer.serve(fd: fd, host: host)
        slot.leave()
      }
    }
  }

  /// Läuft auf einem Arbeitsthread: blockierendes I/O ist hier erlaubt.
  private static func serve(fd: Int32, host: MCPToolHost) {
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)  // vom Listener geerbt
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard let line = readBridgeLine(fd: fd, limit: 4 * 1024 * 1024) else { return }
    let response = respond(to: line, host: host)
    writeAll(fd: fd, Data((response + "\n").utf8))
  }

  static func respond(to line: Data, host: MCPToolHost) -> String {
    guard let req = JSONValue.parse(String(decoding: line, as: UTF8.self))?.objectValue else {
      return bridgeFailure("Ungültige Anfrage")
    }
    switch req["op"]?.stringValue {
    case "tools/list":
      let tools = host.tools()
      return JSONValue.object(["ok": .bool(true), "tools": .array(tools.map(\.bridgeJSON))]).jsonString()
    case "tools/call":
      let name = req["name"]?.stringValue ?? ""
      let arguments = req["arguments"] ?? .object([:])
      let result = callHost(host, name: name, arguments: arguments)
      return JSONValue.object([
        "ok": .bool(true), "text": .string(result.text), "isError": .bool(result.isError),
      ]).jsonString()
    default:
      return bridgeFailure("Unbekannte Anfrage")
    }
  }

  /// Brückt den async Host-Aufruf auf den blockierenden Arbeitsthread.
  private static func callHost(_ host: MCPToolHost, name: String, arguments: JSONValue) -> MCPToolResult {
    final class Box: @unchecked Sendable { var value: MCPToolResult? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      box.value = await host.call(name: name, arguments: arguments)
      done.signal()
    }
    done.wait()
    return box.value ?? MCPToolResult(text: "Lumi hat kein Ergebnis geliefert.", isError: true)
  }

  private static func bridgeFailure(_ message: String) -> String {
    JSONValue.object(["ok": .bool(false), "error": .string(message)]).jsonString()
  }

  fileprivate static func readBridgeLine(fd: Int32, limit: Int) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let n = read(fd, &buf, buf.count)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { return data.isEmpty ? nil : data }  // EOF, Fehler oder Zeitüberschreitung
      data.append(contentsOf: buf[0..<n])
      if let nl = data.firstIndex(of: 0x0A) { return data[data.startIndex..<nl] }
      if data.count > limit { return nil }
    }
  }

  fileprivate static func writeAll(fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      guard var p = raw.baseAddress else { return }
      var left = raw.count
      while left > 0 {
        let n = write(fd, p, left)
        if n > 0 { p += n; left -= n; continue }
        if n < 0 && errno == EINTR { continue }
        return
      }
    }
  }
}

public final class MCPBridgeClient: MCPToolBackend {
  public let socketPath: String
  /// Obergrenze für eine Antwort (Werkzeuge dürfen etwas dauern).
  private let responseTimeoutSeconds = 120

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  public func listTools() throws -> [MCPTool] {
    let r = try request(["op": .string("tools/list")])
    guard let items = r["tools"]?.arrayValue else {
      throw MCPBridgeError.failed("Antwort von Lumi ohne Werkzeugliste")
    }
    return items.compactMap { MCPTool(bridgeJSON: $0) }
  }

  public func call(name: String, arguments: JSONValue) throws -> MCPToolResult {
    let r = try request(["op": .string("tools/call"), "name": .string(name), "arguments": arguments])
    return MCPToolResult(text: r["text"]?.stringValue ?? "", isError: r["isError"]?.boolValue ?? false)
  }

  private func request(_ message: [String: JSONValue]) throws -> [String: JSONValue] {
    let fd = try connect()
    defer { close(fd) }
    var tv = timeval(tv_sec: responseTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    MCPBridgeServer.writeAll(fd: fd, Data((JSONValue.object(message).jsonString() + "\n").utf8))
    guard let line = MCPBridgeServer.readBridgeLine(fd: fd, limit: 16 * 1024 * 1024),
      let resp = JSONValue.parse(String(decoding: line, as: UTF8.self))?.objectValue
    else {
      throw MCPBridgeError.failed("Keine Antwort von Lumi (Zeitüberschreitung oder Verbindungsabbruch)")
    }
    if resp["ok"]?.boolValue == true { return resp }
    throw MCPBridgeError.failed(resp["error"]?.stringValue ?? "Unbekannter Fehler in Lumi")
  }

  private func connect() throws -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw MCPBridgeError.failed("Socket-Pfad zu lang")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      buf.copyBytes(from: pathBytes)
      buf[pathBytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MCPBridgeError.failed("Socket konnte nicht erstellt werden") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0 else {
      let e = errno
      close(fd)
      if e == ENOENT || e == ECONNREFUSED { throw MCPBridgeError.appNotRunning }
      throw MCPBridgeError.failed("Verbindung zu Lumi fehlgeschlagen (errno \(e))")
    }
    return fd
  }
}

/// Bindet einen Unix-Socket so, dass die Datei nur dem Nutzer gehört (0600 statt 0644).
/// umask gilt für den ganzen Prozess: deshalb läuft jeder Aufruf unter einer gemeinsamen
/// Sperre, und die alte umask kommt in jedem Fall zurück. Zwei Server können sich so nicht
/// gegenseitig die umask dauerhaft auf 077 stellen.
enum PrivateSocket {
  private static let lock = NSLock()

  static func bindPrivate(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    let old = umask(0o077)
    defer { _ = umask(old) }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
  }
}
