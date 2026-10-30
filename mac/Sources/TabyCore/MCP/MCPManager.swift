// Verwaltung fremder MCP-Server: startet einen Server nur, wenn ein Chat-Zug oder
// ein Test ihn braucht, merkt sich seine Werkzeugliste und beendet ihn nach 5 Minuten
// Leerlauf. Keine Starts beim App-Start oder im Hintergrund.
import Foundation

/// Ein Werkzeug eines fremden Servers, so wie das Modell es sieht.
public struct MCPRoute: Equatable, Sendable {
  /// Name im Chat, z. B. `mcp_docs_search_pages`.
  public var offeredName: String
  public var server: MCPServerConfig
  public var tool: MCPToolInfo
  public var isWrite: Bool
}

public enum MCPToolPolicy {
  public static let prefix = "mcp_"
  /// Erstes Wort des Namens, das ein Werkzeug als lesend ausweist (ohne Schreibwort im Namen).
  public static let readWords: Set<String> = ["list", "get", "search", "read", "find", "query", "show"]
  /// Parameter, die eine Adresse entgegennehmen: ein Werkzeug damit kann Fremdes ansteuern, also schreibend.
  static let urlPropertyNames: Set<String> = ["url", "uri", "href"]
  /// Wörter, die einen Namen schreibend machen, auch wenn er mit einem Lesewort beginnt.
  public static let writeWords: Set<String> = [
    "create", "add", "update", "delete", "remove", "set", "write", "send", "post", "put", "move", "rename",
    "archive", "insert", "upsert", "patch", "run", "exec", "execute",
  ]
  static let maxNameLength = 64
  static let maxResultChars = 20_000
  static let maxArgumentChars = 300

  /// Lesend nur, wenn der Name mit einem Lesewort beginnt, kein Schreibwort enthält, kein
  /// destructiveHint gesetzt ist und kein Parameter eine Adresse (url/uri/href) verlangt.
  /// Ein readOnlyHint des Servers allein genügt nicht (er gibt sich sonst selbst frei).
  public static func isWrite(_ tool: MCPToolInfo) -> Bool {
    if tool.destructiveHint { return true }
    if let props = tool.inputSchema["properties"]?.objectValue,
       props.keys.contains(where: { urlPropertyNames.contains($0.lowercased()) }) { return true }
    let words = nameWords(tool.name)
    guard let first = words.first, readWords.contains(first) else { return true }
    return words.contains { writeWords.contains($0) }
  }

  /// Wörter eines Namens: getrennt an `_`, `-`, `.` und an Großbuchstaben (`listUsers` → list, users).
  static func nameWords(_ name: String) -> [String] {
    var words: [String] = []
    var current = ""
    var previous: Character?
    for c in name {
      guard c.isLetter || c.isNumber else {
        if !current.isEmpty { words.append(current) }
        current = ""; previous = nil
        continue
      }
      if c.isUppercase, let p = previous, p.isLowercase || p.isNumber, !current.isEmpty {
        words.append(current)
        current = ""
      }
      current.append(c)
      previous = c
    }
    if !current.isEmpty { words.append(current) }
    return words.map { $0.lowercased() }
  }

  /// Muster für Geheimnisse in Text: `api_key=…`, `"token": "…"`, `sk-…`, lange Zeichenfolgen mit Ziffern.
  private static let secretPatterns: [(NSRegularExpression, String)] = [
    #"(?i)([\w-]*(?:key|token|secret|passwd|password)[\w-]*"?\s*[:=]\s*"?)[^\s"',}&]+"#,
    #"\b(?:sk|ghp|xox[abp])[-_][A-Za-z0-9_-]{8,}"#,
    #"(?=[A-Za-z0-9_+=]*\d)[A-Za-z0-9_+=]{32,}"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }.enumerated().map { i, re in
    (re, i == 0 ? "$1[verborgen]" : "[verborgen]")
  }

  /// Schwärzt Geheimnisse in einem Text (Bestätigungskarte, Diagnose). Heuristisch, bewusst großzügig.
  public static func redactText(_ text: String) -> String {
    secretPatterns.reduce(text) { acc, p in
      p.0.stringByReplacingMatches(in: acc, range: NSRange(acc.startIndex..., in: acc), withTemplate: p.1)
    }
  }

  /// Startargumente für Anzeige und Diagnose: der Wert nach einem Schlüsselwort-Flag (`--api-key x`) wird ersetzt.
  public static func redactArgs(_ args: [String]) -> [String] {
    var out: [String] = []
    var hideNext = false
    for a in args {
      if hideNext { out.append("[verborgen]"); hideNext = false; continue }
      let name = a.drop { $0 == "-" }.lowercased()
      if a.hasPrefix("-"), !a.contains("="), secretKeyWords.contains(where: { name.contains($0) }) {
        hideNext = true
        out.append(a)
        continue
      }
      out.append(redactText(a))
    }
    return out
  }

  private static let secretKeyWords = ["key", "token", "secret", "passwd", "password"]

  /// Name für das Modell: nur ASCII-Buchstaben, Ziffern, `_` und `-`, höchstens 64 Zeichen.
  public static func offeredName(serverId: String, tool: String) -> String {
    func clean(_ s: String) -> String {
      String(s.map { c -> Character in
        (c.isASCII && (c.isLetter || c.isNumber)) || c == "_" || c == "-" ? c : "_"
      })
    }
    return String((prefix + clean(serverId) + "_" + clean(tool)).prefix(maxNameLength))
  }

  /// Vollständige Argumente (ungekürzt), für die Anzeige geschwärzt. Ausgeführt wird der Originaltext, nicht diese Fassung.
  public static func fullArgumentsText(_ args: JSONValue) -> String {
    redactText(args.jsonString())
  }

  /// Eindeutiger Name: hängt `_2`, `_3` … an, wenn er schon vergeben ist (höchstens 64 Zeichen).
  public static func uniqueName(_ name: String, taken: Set<String>) -> String {
    var candidate = name
    var n = 2
    while taken.contains(candidate) {
      let suffix = "_\(n)"
      candidate = String(name.prefix(maxNameLength - suffix.count)) + suffix
      n += 1
    }
    return candidate
  }

  /// Kompakte Form der Argumente für die Bestätigungskarte (gekürzt).
  public static func argumentsSummary(_ args: JSONValue) -> String {
    let text = redactText(args.jsonString())
    return text.count <= maxArgumentChars ? text : String(text.prefix(maxArgumentChars)) + "…"
  }

  /// Ergebnis für das Modell: Text fremder Herkunft, nur als Material verpackt.
  public static func resultJSON(_ r: MCPCallResult) -> JSONValue {
    let text = r.text.isEmpty ? "(kein Text)" : String(r.text.prefix(maxResultChars))
    let body = JSONValue.string(ForeignContent.wrap(text))
    if r.isError {
      return ToolJSON.failure(code: "MCP", error: "Der Werkzeug-Aufruf ist im MCP-Server fehlgeschlagen.",
                              ["untrusted_content": body])
    }
    return ToolJSON.ok(["untrusted_content": body])
  }
}

/// Sammelt die Ergebnisse paralleler Server-Abrufe, Zugriff unter Sperre.
private final class RouteCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var slots: [[MCPRoute]?]
  private var left: Int

  init(count: Int) {
    slots = Array(repeating: nil, count: count)
    left = count
  }

  /// Legt das Ergebnis eines Servers ab; true, wenn jetzt alle da sind.
  func put(_ index: Int, _ routes: [MCPRoute]) -> Bool {
    lock.withLock {
      slots[index] = routes
      left -= 1
      return left == 0
    }
  }

  var routes: [MCPRoute] { lock.withLock { slots.compactMap { $0 }.flatMap { $0 } } }
}

/// Sitzungen, Werkzeug-Cache und Leerlauf. `shared` für die App, eigene Instanzen in Prüfungen.
public final class MCPManager: @unchecked Sendable {
  public static let shared = MCPManager(clock: SystemClock())
  public static let idleLimit: TimeInterval = 5 * 60
  /// Nach einem Fehler wird ein Server für so lange nicht erneut gestartet.
  public static let failureBackoff: TimeInterval = 5 * 60

  public typealias Launcher = @Sendable (MCPServerConfig) throws -> MCPSession

  private struct Live {
    var session: MCPSession
    var fingerprint: String
    var lastUsed: Date
  }
  private struct Cached {
    var fingerprint: String
    var tools: [MCPToolInfo]
  }

  private let clock: Clock
  private let launcher: Launcher
  private let lock = NSLock()
  private var sessions: [String: Live] = [:]
  private var cache: [String: Cached] = [:]
  private var failures: [String: Date] = [:]
  private var routes: [String: MCPRoute] = [:]
  private var launches = 0

  public init(clock: Clock, launcher: @escaping Launcher = { c in
    try MCPSession.launch(command: c.command, args: c.args)
  }) {
    self.clock = clock
    self.launcher = launcher
  }

  /// Anzahl der Serverstarts seit Erstellung (für Prüfungen).
  public var launchCount: Int { lock.withLock { launches } }

  /// Route zu einem Chat-Werkzeugnamen aus dem letzten Zug.
  public func route(named name: String) -> MCPRoute? {
    lock.withLock { routes[name] }
  }

  /// Gesamtzeit für alle Server eines Zuges. Server, die bis dahin nicht antworten, fehlen in diesem Zug
  /// (ihr Start läuft weiter und füllt den Cache für den nächsten Zug).
  public var turnDeadline: TimeInterval = 5

  /// Werkzeuge der aktivierten Server für einen Chat-Zug. Schreibende nur mit `allowWrite`.
  /// Die Server starten parallel; ein Server, der fehlschlägt, wird für eine Weile übersprungen.
  public func offeredTools(for servers: [MCPServerConfig]) async -> [MCPRoute] {
    let active = servers.filter(\.enabled)
    let deadline = turnDeadline
    let collector = RouteCollector(count: active.count)
    let out: [MCPRoute] = await withCheckedContinuation { (cont: CheckedContinuation<[MCPRoute], Never>) in
      guard !active.isEmpty else { cont.resume(returning: []); return }
      let gate = OnceGate()
      for (i, server) in active.enumerated() {
        Task {
          if collector.put(i, await self.serverRoutes(for: server)), gate.open() { cont.resume(returning: collector.routes) }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
        if gate.open() { cont.resume(returning: collector.routes) }
      }
    }
    // Keine doppelten Werkzeugnamen an das Modell: Kollisionen bekommen _2, _3 …
    // Nach Server-ID sortiert (Reihenfolge der Antworten bleibt innerhalb eines Servers), damit die Suffixe stabil sind.
    let ordered = out.enumerated()
      .sorted { ($0.element.server.id, $0.offset) < ($1.element.server.id, $1.offset) }
      .map(\.element)
    var taken = Set<String>()
    var unique: [MCPRoute] = []
    for var r in ordered {
      r.offeredName = MCPToolPolicy.uniqueName(r.offeredName, taken: taken)
      taken.insert(r.offeredName)
      unique.append(r)
    }
    var table: [String: MCPRoute] = [:]
    for r in unique { table[r.offeredName] = r }
    lock.withLock { routes = table }
    return unique
  }

  /// Routen eines Servers; Fehler und Sperrzeit ergeben keine Routen.
  private func serverRoutes(for server: MCPServerConfig) async -> [MCPRoute] {
    if let failed = lock.withLock({ failures[server.id] }),
       clock.now().timeIntervalSince(failed) < Self.failureBackoff { return [] }
    do {
      let list = try await tools(for: server)
      lock.withLock { failures[server.id] = nil }
      return list.compactMap { tool -> MCPRoute? in
        let write = MCPToolPolicy.isWrite(tool)
        if write && !server.allowWrite { return nil }
        return MCPRoute(offeredName: MCPToolPolicy.offeredName(serverId: server.id, tool: tool.name),
                        server: server, tool: tool, isWrite: write)
      }
    } catch {
      lock.withLock { failures[server.id] = clock.now() }
      return []
    }
  }

  /// Werkzeugliste eines Servers: aus dem Cache, sonst über eine (kurzlebige) Sitzung.
  public func tools(for config: MCPServerConfig) async throws -> [MCPToolInfo] {
    let fingerprint = Self.fingerprint(config)
    if let c = lock.withLock({ cache[config.id] }), c.fingerprint == fingerprint { return c.tools }
    return try await refresh(config)
  }

  /// „Testen“ in den Einstellungen: Liste neu laden, Namen zurückgeben.
  public func test(_ config: MCPServerConfig) async throws -> [String] {
    try await refresh(config).map(\.name)
  }

  /// Führt ein Werkzeug aus. Startet den Server bei Bedarf neu.
  public func call(_ route: MCPRoute, arguments: JSONValue) async throws -> MCPCallResult {
    let session = try await session(for: route.server)
    do {
      let result = try await session.callTool(name: route.tool.name, arguments: arguments)
      touch(route.server.id)
      return result
    } catch {
      dropIfClosed(route.server.id, session)
      throw error
    }
  }

  /// Beendet alle laufenden Server (z. B. beim Beenden der App oder bei Konfigurationsänderungen).
  public func terminateAll() {
    let all = lock.withLock { () -> [MCPSession] in
      let s = sessions.values.map(\.session)
      sessions.removeAll()
      return s
    }
    all.forEach { $0.close() }
  }

  /// Beendet Sitzungen, die länger als `idleLimit` ungenutzt sind.
  public func sweep() {
    let now = clock.now()
    let stale = lock.withLock { () -> [MCPSession] in
      let ids = sessions.filter { now.timeIntervalSince($0.value.lastUsed) >= Self.idleLimit }.map(\.key)
      return ids.compactMap { sessions.removeValue(forKey: $0)?.session }
    }
    stale.forEach { $0.close() }
  }

  // MARK: Intern

  private func refresh(_ config: MCPServerConfig) async throws -> [MCPToolInfo] {
    let session = try await session(for: config)
    do {
      let tools = try await session.listTools()
      lock.withLock { cache[config.id] = Cached(fingerprint: Self.fingerprint(config), tools: tools) }
      touch(config.id)
      return tools
    } catch {
      dropIfClosed(config.id, session)
      throw error
    }
  }

  /// Laufende Sitzung oder neuer Start (mit Initialisierung). Ein Startfehler gilt als Sitzung ohne Werkzeuge.
  private func session(for config: MCPServerConfig) async throws -> MCPSession {
    let fingerprint = Self.fingerprint(config)
    let existing = lock.withLock { () -> MCPSession? in
      guard let live = sessions[config.id], live.fingerprint == fingerprint, live.session.isOpen else {
        return nil
      }
      return live.session
    }
    if let existing {
      touch(config.id)
      return existing
    }
    closeSession(config.id)
    let fresh = try launcher(config)
    lock.withLock { launches += 1 }
    do {
      try await fresh.initialize()
    } catch {
      fresh.close()
      throw error
    }
    let winner = lock.withLock { () -> MCPSession in
      if let other = sessions[config.id], other.fingerprint == fingerprint, other.session.isOpen {
        return other.session  // parallel gestartet: den ersten behalten
      }
      sessions[config.id] = Live(session: fresh, fingerprint: fingerprint, lastUsed: clock.now())
      return fresh
    }
    if winner !== fresh { fresh.close() }
    scheduleIdleCheck()
    return winner
  }

  private func touch(_ id: String) {
    let now = clock.now()
    lock.withLock { sessions[id]?.lastUsed = now }
    scheduleIdleCheck()
  }

  private func closeSession(_ id: String) {
    let old = lock.withLock { sessions.removeValue(forKey: id)?.session }
    old?.close()
  }

  private func dropIfClosed(_ id: String, _ session: MCPSession) {
    guard !session.isOpen else { return }
    lock.withLock {
      if sessions[id]?.session === session { sessions[id] = nil }
      failures[id] = clock.now()
    }
  }

  /// Prüft nach `idleLimit` erneut. Mehrere geplante Prüfungen sind harmlos.
  private func scheduleIdleCheck() {
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.idleLimit * 1_000_000_000) + 1_000_000_000)
      self?.sweep()
    }
  }

  static func fingerprint(_ config: MCPServerConfig) -> String {
    ([config.command] + config.args).joined(separator: "\u{1}")
  }
}
