// Unix-Domain-Socket-Server für Claude Codes PermissionRequest-Hook (Port
// von src/main/agents/hookServer.ts, docs/decisions/0005-agents-hooks.md).
//
// Protokoll (unverändert gegenüber TS + Relay):
//   Relay → App: das Hook-Eingabe-JSON von Claude Code als EINE Zeile + "\n".
//   App → Relay: EINE Zeile
//     {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
//      "decision":{"behavior":"allow"|"deny","message"?:"…"}}}\n
//   oder Verbindung schließen ohne Daten → Claude Code fällt auf seinen
//   normalen Freigabe-Dialog zurück (Timeout, Verdrängung, App beendet).
//
// Immer nur EINE offene Anfrage: eine neue verdrängt die alte (die alte
// bekommt keine Antwort, Grund `.displaced`), wie in appContext.ts.
// Alle Rückrufe kommen auf einer privaten seriellen Queue — der Integrator
// springt selbst auf den MainActor.
import Darwin
import Foundation

public enum AgentRequestCloseReason: String, Sendable {
  /// Keine Entscheidung innerhalb der Frist.
  case timeout
  /// Von einer neueren Anfrage verdrängt.
  case displaced
  /// Relay/Claude Code hat die Verbindung beendet.
  case clientGone
  /// Server gestoppt.
  case stopped
}

public enum AgentHookServerError: Error, Equatable {
  case socketPathTooLong(String)
  case socketFailed(String)
}

public final class AgentHookServer {
  /// Klar unter dem in settings.json eingetragenen Hook-Timeout (120 s).
  public static let defaultRequestTimeout: TimeInterval = 110

  public let socketPath: String
  private let requestTimeout: TimeInterval
  private let onRequest: (AgentPermissionRequest) -> Void
  private let onClosed: (String, AgentRequestCloseReason) -> Void
  private let onNotice: ((ClaudeNotice) -> Void)?

  private let queue = DispatchQueue(label: "taby.agent-hook-server")
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: [Int32: Connection] = [:]
  private var current: (id: String, fd: Int32)?
  private var seq = 0

  private final class Connection {
    let fd: Int32
    var source: DispatchSourceRead?
    var buffer = Data()
    var requestId: String?
    var timer: DispatchSourceTimer?
    init(fd: Int32) { self.fd = fd }
  }

  /// - onRequest: neue Anfrage (verdrängte alte vorher über onClosed gemeldet).
  /// - onClosed: Anfrage ohne Entscheidung beendet (Timeout, Verdrängung, Abbruch, Stopp).
  /// - onNotice: Meldung aus Claude Code (Hooks Notification/Stop). Wird nie beantwortet
  ///   und verdrängt keine offene Freigabe-Anfrage.
  public init(socketPath: String, requestTimeout: TimeInterval = AgentHookServer.defaultRequestTimeout,
              onRequest: @escaping (AgentPermissionRequest) -> Void,
              onClosed: @escaping (String, AgentRequestCloseReason) -> Void = { _, _ in },
              onNotice: ((ClaudeNotice) -> Void)? = nil) {
    self.socketPath = socketPath
    self.requestTimeout = requestTimeout
    self.onRequest = onRequest
    self.onClosed = onClosed
    self.onNotice = onNotice
    queue.setSpecific(key: Self.queueKey, value: ())
  }

  deinit { onQueue { stopLocked() } }

  private static let queueKey = DispatchSpecificKey<Void>()

  /// Läuft direkt, wenn schon auf der Queue (z. B. `resolve` aus `onRequest`), sonst synchron.
  private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return try body() }
    return try queue.sync(execute: body)
  }

  public var isRunning: Bool { onQueue { listenFD >= 0 } }

  /// Id der aktuell offenen Anfrage (nil = keine).
  public var currentRequestId: String? { onQueue { current?.id } }

  // MARK: Start/Stopp

  public func start() throws {
    try onQueue {
      guard listenFD < 0 else { return }
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let pathBytes = Array(socketPath.utf8)
      let capacity = MemoryLayout.size(ofValue: addr.sun_path)
      guard pathBytes.count < capacity else { throw AgentHookServerError.socketPathTooLong(socketPath) }
      withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: pathBytes)
        buf[pathBytes.count] = 0
      }
      try? FileManager.default.createDirectory(
        atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      unlink(socketPath)  // veralteter Socket eines früheren Laufs

      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw AgentHookServerError.socketFailed("socket: \(errno)") }
      // Die Datei entsteht schon privat (0600 statt 0644), kein Fenster für andere Nutzer.
      let bound = PrivateSocket.bindPrivate(fd, &addr)
      guard bound == 0 else {
        let e = errno; close(fd)
        throw AgentHookServerError.socketFailed("bind: \(e)")
      }
      chmod(socketPath, 0o600)  // nur der eigene Nutzer
      guard listen(fd, 8) == 0 else {
        let e = errno; close(fd); unlink(socketPath)
        throw AgentHookServerError.socketFailed("listen: \(e)")
      }
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      listenFD = fd
      let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      src.setEventHandler { [weak self] in self?.acceptPending() }
      src.resume()
      acceptSource = src
    }
  }

  public func stop() { onQueue { stopLocked() } }

  private func stopLocked() {
    guard listenFD >= 0 else { return }
    acceptSource?.cancel()
    acceptSource = nil
    close(listenFD)
    listenFD = -1
    unlink(socketPath)
    for fd in Array(connections.keys) { closeConnection(fd, reason: .stopped) }
  }

  // MARK: Entscheidungen

  /// Antwortet auf die Anfrage und schließt die Verbindung. Unbekannte/
  /// abgelaufene Ids werden ignoriert.
  public func resolve(id: String, decision: AgentPermissionDecision) {
    onQueue {
      guard let conn = connections.values.first(where: { $0.requestId == id }) else { return }
      var line = Self.encodeResponse(decision)
      line.append(0x0A)
      Self.writeAll(conn.fd, line)
      closeConnection(conn.fd, reason: nil)
    }
  }

  /// Schließt die Verbindung ohne Antwort (Claude Code fragt normal im Terminal).
  public func dismiss(id: String) {
    onQueue {
      guard let conn = connections.values.first(where: { $0.requestId == id }) else { return }
      closeConnection(conn.fd, reason: nil)
    }
  }

  /// Antwortzeile (ohne "\n") im Format der Claude-Code-Hooks-Referenz.
  public static func encodeResponse(_ decision: AgentPermissionDecision) -> Data {
    var d: [String: JSONValue] = ["behavior": .string(decision.behavior.rawValue)]
    if decision.behavior == .deny, let m = decision.message { d["message"] = .string(m) }
    let out: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": .object(d)]]
    return Data(out.jsonString().utf8)
  }

  /// Hook-Eingabe (Claude Code) → Anfrage.
  static func parseRequest(_ line: Data, id: String) -> AgentPermissionRequest? {
    guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), v.objectValue != nil else { return nil }
    return AgentPermissionRequest(
      id: id, toolName: v["tool_name"]?.stringValue ?? "unbekannt", toolInput: v["tool_input"] ?? .null,
      cwd: v["cwd"]?.stringValue)
  }

  /// Meldung aus Claude Code (Hook-Eingabe-JSON) → ClaudeNotice. nil für alles,
  /// was keine Meldung ist: andere Ereignisse, Stop mit stop_hook_active, ungültiges JSON.
  public static func parseNotice(_ line: Data) -> ClaudeNotice? {
    guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), v.objectValue != nil else { return nil }
    let project = v["cwd"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
    switch v["hook_event_name"]?.stringValue {
    case "Notification":
      return ClaudeNotice(kind: .needsInput, message: v["message"]?.stringValue ?? "", project: project)
    case "Stop":
      guard v["stop_hook_active"]?.boolValue != true else { return nil }
      return ClaudeNotice(kind: .finished, message: "", project: project)
    default:
      return nil
    }
  }

  /// hook_event_name der Eingabe, nil wenn nicht vorhanden (dann wie PermissionRequest behandelt).
  static func hookEventName(_ line: Data) -> String? {
    (try? JSONDecoder().decode(JSONValue.self, from: line))?["hook_event_name"]?.stringValue
  }

  static let maxConnections = 16

  // MARK: Intern (nur auf `queue`)

  private func acceptPending() {
    while true {
      let fd = accept(listenFD, nil, nil)
      if fd < 0 { return }
      // Höchstens so viele gleichzeitige Verbindungen: ein Prozess darf die Dateideskriptoren nicht aufbrauchen.
      if connections.count >= Self.maxConnections { close(fd); continue }
      var on: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      let conn = Connection(fd: fd)
      connections[fd] = conn
      let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      src.setEventHandler { [weak self] in self?.readAvailable(fd) }
      conn.source = src
      src.resume()
    }
  }

  private func readAvailable(_ fd: Int32) {
    guard let conn = connections[fd] else { return }
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    let n = read(fd, &buf, buf.count)
    if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
      closeConnection(fd, reason: conn.requestId == nil ? nil : .clientGone)
      return
    }
    guard n > 0, conn.requestId == nil else { return }  // nach der ersten Zeile nur noch auf EOF achten
    conn.buffer.append(contentsOf: buf[0..<n])
    if conn.buffer.count > 4 * 1024 * 1024 { closeConnection(fd, reason: nil); return }
    guard let nl = conn.buffer.firstIndex(of: 0x0A) else { return }
    let lineData = conn.buffer[conn.buffer.startIndex..<nl]
    if let event = Self.hookEventName(lineData), event != "PermissionRequest" {
      // Meldungen werden nie beantwortet: Verbindung sofort schließen, Relay endet still.
      // Sie verdrängen keine offene Freigabe-Anfrage.
      handleNotice(lineData)
      closeConnection(fd, reason: nil)
      return
    }
    seq += 1
    let id = "req-\(seq)-\(UUID().uuidString.prefix(8).lowercased())"
    guard let req = Self.parseRequest(lineData, id: id) else {
      closeConnection(fd, reason: nil)
      return
    }
    if let old = current { closeConnection(old.fd, reason: .displaced) }
    conn.requestId = id
    current = (id, fd)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + requestTimeout)
    timer.setEventHandler { [weak self] in self?.closeConnection(fd, reason: .timeout) }
    timer.resume()
    conn.timer = timer
    onRequest(req)
  }

  private func handleNotice(_ line: Data) {
    guard let notice = Self.parseNotice(line) else { return }
    // Lumi zeigt bei offener Freigabe schon die Karte; Claudes Hinweis dazu ist doppelt.
    if current != nil, notice.kind == .needsInput, notice.message.lowercased().contains("permission") { return }
    onNotice?(notice)
  }

  /// reason != nil → onClosed melden (nur bei offener Anfrage).
  private func closeConnection(_ fd: Int32, reason: AgentRequestCloseReason?) {
    guard let conn = connections.removeValue(forKey: fd) else { return }
    conn.timer?.cancel()
    conn.source?.cancel()
    close(fd)
    if let id = conn.requestId {
      if current?.id == id { current = nil }
      if let reason { onClosed(id, reason) }
    }
  }

  private static func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      guard var p = raw.baseAddress else { return }
      var left = raw.count
      var spins = 0
      while left > 0 {
        let n = write(fd, p, left)
        if n > 0 { p += n; left -= n; continue }
        if n < 0, errno == EAGAIN || errno == EINTR, spins < 1000 { spins += 1; usleep(1000); continue }
        return
      }
    }
  }
}
