// Skript-Mods (Paket 3): JavaScript in einer JavaScriptCore-Sandbox.
//
// Jeder Lauf hat einen eigenen JSContext auf einer eigenen seriellen
// Warteschlange. Das Skript sieht nur das globale `taby`-Objekt und
// `console.log`. Jeder Aufruf prüft zuerst die Rechte aus dem Manifest; erst
// danach wird etwas getan. Eine verweigerte Berechtigung beendet den Lauf.
//
// Zeitgrenze: Der Lauf meldet bei Überschreitung `.timeout`. Zusätzlich setzt
// die App über `JSContextGroupSetExecutionTimeLimit` (privat, per dlsym) eine
// harte Grenze, damit auch `while (true) {}` abbricht. Fehlt das Symbol, zählt
// `ScriptRunLimits` die hängenden Läufe: je Mod höchstens einer, insgesamt vier.
import Foundation
import JavaScriptCore

/// Schnittstelle zum echten Speicher (vom Orchestrator gegen den Store gebaut).
public protocol ModHostAPI: AnyObject {
  func listTasks() async throws -> [TabyTask]
  func addTask(title: String, due: String?) async throws -> TabyTask
  func completeTask(id: String) async throws
  func listNotes() async throws -> [Note]
  func addNote(title: String, content: String) async throws -> Note
  func listEvents(from: String, to: String) async throws -> [CalendarEvent]
  func notify(_ n: TabyNotification)
  /// Paket 8: Kurztext in der Insel setzen (Recht „island.text“). `seconds` = Gültigkeit.
  func setIslandText(_ text: String, seconds: Double)
  // Welle C: neue Schnittstellen. Standard: nicht verfügbar (Host ohne Anbindung).
  func listHabits() async throws -> [Habit]
  func checkHabit(id: String) async throws -> Habit
  func startFocus(minutes: Int?) async throws
  func stopFocus() async throws
  func focusIsRunning() async throws -> Bool
  func startTimer(minutes: Int, label: String) async throws
  /// Letzte Nachrichten aus dem Nachrichten-Zwischenspeicher, Text bereits als fremder Inhalt verpackt.
  func recentMessages(limit: Int) async throws -> [JSONValue]
  func openMailDraft(_ draft: MailDraft) async throws
  func storageGet(key: String) async throws -> JSONValue
  func storageSet(key: String, value: JSONValue) async throws
}

extension ModHostAPI {
  func listHabits() async throws -> [Habit] { throw ScriptBridgeError.unavailable }
  func checkHabit(id: String) async throws -> Habit { throw ScriptBridgeError.unavailable }
  func startFocus(minutes: Int?) async throws { throw ScriptBridgeError.unavailable }
  func stopFocus() async throws { throw ScriptBridgeError.unavailable }
  func focusIsRunning() async throws -> Bool { throw ScriptBridgeError.unavailable }
  func startTimer(minutes: Int, label: String) async throws { throw ScriptBridgeError.unavailable }
  func recentMessages(limit: Int) async throws -> [JSONValue] { throw ScriptBridgeError.unavailable }
  func openMailDraft(_ draft: MailDraft) async throws { throw ScriptBridgeError.unavailable }
  func storageGet(key: String) async throws -> JSONValue { throw ScriptBridgeError.unavailable }
  func storageSet(key: String, value: JSONValue) async throws { throw ScriptBridgeError.unavailable }
}

public struct ScriptRunResult: Equatable, Sendable {
  public var output: String
  public var logs: [String]

  public init(output: String, logs: [String] = []) {
    self.output = output
    self.logs = logs
  }
}

public enum ScriptModError: Error, Equatable, LocalizedError {
  case permissionDenied(String), timeout, scriptError(String), invalidResult

  public var errorDescription: String? {
    switch self {
    case .permissionDenied(let m): return m
    case .timeout: return "Das Skript hat zu lange gebraucht und wurde abgebrochen."
    case .scriptError(let m): return "Fehler im Skript: \(m)"
    case .invalidResult: return "Das Skript hat kein verwertbares Ergebnis geliefert."
    }
  }
}

/// Harte Laufzeitgrenze von JavaScriptCore. Das Symbol ist privat; fehlt es, bleibt nur die Begrenzung der Läufe.
enum ScriptTimeLimit {
  typealias Callback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
  typealias SetLimit = @convention(c) (OpaquePointer?, Double, Callback, UnsafeMutableRawPointer?) -> Void

  static let setLimit: SetLimit? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(sym, to: SetLimit.self)
  }()

  /// Jede Überschreitung beendet den Lauf (jede Gruppe gehört nur zu einem Lauf).
  static let terminate: Callback = { _, _ in true }

  /// Setzt die Grenze auf `seconds`. Gibt false zurück, wenn das Symbol fehlt.
  static func apply(to ctx: JSContext, seconds: Double) -> Bool {
    guard let setLimit else { return false }
    setLimit(JSContextGetGroup(ctx.jsGlobalContextRef), seconds, terminate, nil)
    return true
  }
}

/// Höchstens ein Lauf je Mod und vier insgesamt. Ein hängender Lauf bleibt gezählt, bis er wirklich endet.
enum ScriptRunLimits {
  static let perMod = 1
  static let overall = 4
  private static let lock = NSLock()
  private static var active: [String: Int] = [:]
  private static var total = 0

  static func acquire(_ modId: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard total < overall, active[modId, default: 0] < perMod else { return false }
    active[modId, default: 0] += 1
    total += 1
    return true
  }

  static func release(_ modId: String) {
    lock.lock(); defer { lock.unlock() }
    guard active[modId, default: 0] > 0 else { return }
    active[modId, default: 0] -= 1
    total -= 1
  }

  /// Laufende Läufe insgesamt (für Prüfungen, die auf freie Plätze warten).
  static var activeCount: Int {
    lock.lock(); defer { lock.unlock() }
    return total
  }
}

/// Höchstens zehn Benachrichtigungen und zehn Insel-Texte je Mod und Stunde (je Aufruf-Art gezählt).
enum ScriptRateLimit {
  static let perHour = 10
  static let window: TimeInterval = 3600
  private static let lock = NSLock()
  private static var stamps: [String: [Date]] = [:]

  static func allow(_ modId: String, op: String, now: Date) -> Bool {
    lock.lock(); defer { lock.unlock() }
    let key = modId + "|" + op
    let recent = (stamps[key] ?? []).filter { now.timeIntervalSince($0) < window }
    guard recent.count < perHour else {
      stamps[key] = recent
      return false
    }
    stamps[key] = recent + [now]
    return true
  }
}

public final class ScriptModRunner {
  private let host: ModHostAPI
  private let session: URLSession
  private let timeout: TimeInterval
  private let localOnly: Bool
  private let now: @Sendable () -> Date

  /// `now` ist die Zeitquelle für die Begrenzung (Prüfungen setzen sie fest).
  public init(host: ModHostAPI, session: URLSession = .shared, timeout: TimeInterval = 10, localOnly: Bool = false,
              now: @escaping @Sendable () -> Date = { Date() }) {
    self.host = host
    self.session = session
    self.timeout = timeout
    self.localOnly = localOnly
    self.now = now
  }

  /// Führt `function run(input)` aus. Die Rechte kommen aus `manifest.permissions`.
  /// `settingValues` sind die gespeicherten Einstellungen; das Skript sieht sie als `input.settings`.
  public func run(code: String, manifest: ModManifest, input: JSONValue,
                  settingValues: [String: String] = [:]) async throws -> ScriptRunResult {
    guard ScriptRunLimits.acquire(manifest.id) else {
      throw ScriptModError.scriptError("Der Mod läuft noch (ein früherer Lauf hängt). Bitte warten.")
    }
    let execution = ScriptRun(host: host, session: session, permissions: Set(manifest.permissions),
                              localOnly: localOnly, modId: manifest.id, now: now)
    let settings = ModSettingRules.input(manifest: manifest, stored: settingValues)
    let inputJSON = ModSettingRules.withSettings(input, settings: settings).jsonString()
    return try await withCheckedThrowingContinuation { continuation in
      execution.start(code: code, inputJSON: inputJSON, timeout: timeout, continuation: continuation)
    }
  }
}

/// Ein einzelner Lauf. Die Felder unter „nur auf queue“ werden ausschließlich
/// auf der Warteschlange gelesen und geschrieben; die übrigen sind durch
/// `lock` oder Unveränderlichkeit geschützt.
final class ScriptRun: @unchecked Sendable {
  private let host: ModHostAPI
  private let session: URLSession
  private let permissions: Set<String>
  private let localOnly: Bool
  private let modId: String
  private let now: @Sendable () -> Date
  private let queue = DispatchQueue(label: "de.taby.mods.script")
  private let lock = NSLock()
  private var finished = false
  /// true, solange die Skript-Warteschlange den Lauf noch ausführt (auch nach einer Zeitüberschreitung).
  private var executing = false
  private var slotReleased = false
  private var continuation: CheckedContinuation<ScriptRunResult, Error>?

  // nur auf queue
  private var context: JSContext?
  private var resolveFunction: JSValue?
  private var logs: [String] = []

  init(host: ModHostAPI, session: URLSession, permissions: Set<String>, localOnly: Bool, modId: String,
       now: @escaping @Sendable () -> Date) {
    self.host = host
    self.session = session
    self.permissions = permissions
    self.localOnly = localOnly
    self.modId = modId
    self.now = now
  }

  func start(code: String, inputJSON: String, timeout: TimeInterval,
             continuation: CheckedContinuation<ScriptRunResult, Error>) {
    lock.lock()
    self.continuation = continuation
    executing = true
    lock.unlock()
    // Der Zeitgeber läuft auf einer eigenen Warteschlange, damit er auch
    // feuert, wenn die Skript-Warteschlange beschäftigt ist.
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
      finish(.failure(.timeout))
    }
    queue.async { [self] in
      execute(code: code, inputJSON: inputJSON, timeout: timeout)
    }
  }

  /// Setzt das Ergebnis genau einmal (Zeitüberschreitung, Skriptende oder Fehler).
  func finish(_ result: Result<ScriptRunResult, ScriptModError>) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let pending = continuation
    continuation = nil
    lock.unlock()
    releaseSlotIfDone()
    switch result {
    case .success(let value): pending?.resume(returning: value)
    case .failure(let error): pending?.resume(throwing: error)
    }
  }

  /// Der Platz im Limit ist frei, sobald der Lauf wirklich endet: Ergebnis gesetzt (auch ein async
  /// Versprechen wird erst hier fertig) und die Skript-Warteschlange kehrt zurück. Ein hängender Lauf
  /// bleibt also gezählt, bis die harte Grenze ihn beendet.
  private func releaseSlotIfDone() {
    lock.lock()
    guard finished, !executing, !slotReleased else {
      lock.unlock()
      return
    }
    slotReleased = true
    lock.unlock()
    ScriptRunLimits.release(modId)
  }

  private func executionEnded() {
    lock.lock()
    executing = false
    lock.unlock()
    releaseSlotIfDone()
  }

  private var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  private func execute(code: String, inputJSON: String, timeout: TimeInterval) {
    defer { executionEnded() }
    if isFinished { return }
    guard let ctx = JSContext() else {
      finish(.failure(.scriptError("JavaScript ist nicht verfügbar.")))
      return
    }
    context = ctx
    _ = ScriptTimeLimit.apply(to: ctx, seconds: timeout)
    // Einziger Weg aus dem Skript heraus. Das Präludium übernimmt die Funktion
    // und löscht sie aus dem globalen Raum, das Skript kommt also nicht heran.
    let native: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] op, args, callId in
      self?.handleCall(op: op.toString() ?? "", argsJSON: args.toString() ?? "", callId: Int(callId.toInt32()))
    }
    ctx.setObject(native, forKeyedSubscript: "__tabyNative" as NSString)
    let api = ctx.evaluateScript(ScriptModBridge.prelude)
    if let message = takeException(ctx) {
      finish(.failure(.scriptError(message)))
      return
    }
    guard let api, let startJS = api.objectForKeyedSubscript("start"),
          let resolveJS = api.objectForKeyedSubscript("resolve") else {
      finish(.failure(.scriptError("Die Laufzeit konnte nicht gestartet werden.")))
      return
    }
    resolveFunction = resolveJS

    _ = ctx.evaluateScript(code)
    if let message = takeException(ctx) {
      finish(.failure(.scriptError(message)))
      return
    }
    _ = startJS.call(withArguments: [inputJSON])
    if let message = takeException(ctx) {
      // Die harte Grenze von JavaScriptCore meldet sich als eigene Ausnahme (siehe isTimeLimit).
      finish(.failure(Self.isTimeLimit(message) ? .timeout : .scriptError(message)))
    }
  }

  /// Nur die Meldungen von JavaScriptCore selbst gelten als Zeitüberschreitung. Eine Ausnahme, die das
  /// Skript selbst wirft (z. B. mit dem Wort „terminated“), bleibt ein Skriptfehler.
  static func isTimeLimit(_ message: String) -> Bool {
    message.localizedCaseInsensitiveContains("JavaScript execution terminated")
      || message.localizedCaseInsensitiveContains("time limit")
  }

  private func takeException(_ ctx: JSContext) -> String? {
    guard let exception = ctx.exception else { return nil }
    ctx.exception = nil
    return exception.toString() ?? "Unbekannter Fehler"
  }

  /// Aufruf aus dem Skript (läuft auf queue).
  private func handleCall(op: String, argsJSON: String, callId: Int) {
    if isFinished { return }
    let args = JSONValue.parse(argsJSON) ?? .object([:])
    switch op {
    case "log":
      appendLog(args["line"]?.stringValue ?? "")
      return
    case "done":
      finishFromScript(args)
      return
    default:
      break
    }

    // Rechte zuerst: ohne Freigabe passiert nichts.
    var target: URL?
    if op == "http.get" {
      // Nur-lokal-Modus: kein Internet für Mods, noch vor der Domain-Prüfung.
      if localOnly {
        finish(.failure(.permissionDenied("Nur-lokal-Modus: Internet für Mods ist aus.")))
        return
      }
      do {
        target = try ScriptHTTP.authorize(args["url"]?.stringValue ?? "", permissions: permissions)
      } catch {
        finish(.failure(error as? ScriptModError ?? .permissionDenied("Der Internetabruf wurde abgelehnt.")))
        return
      }
    } else {
      guard let permission = ScriptPermissions.required(op) else {
        settle(callId, ok: false, payload: "Unbekannte Funktion \(op).")
        return
      }
      guard permissions.contains(permission) else {
        finish(.failure(.permissionDenied(ScriptPermissions.deniedMessage(permission))))
        return
      }
      if op == "notify" || op == "island.set" {
        guard ScriptRateLimit.allow(modId, op: op, now: now()) else {
          settle(callId, ok: false, payload: "Zu viele Aufrufe: höchstens \(ScriptRateLimit.perHour) pro Stunde.")
          return
        }
      }
      if op == "notify" {
        // Benachrichtigung ist synchron; der Host darf von diesem Thread aus aufrufen.
        host.notify(TabyNotification(title: args["title"]?.stringValue ?? "", body: args["body"]?.stringValue ?? ""))
        settle(callId, ok: true, payload: "null")
        return
      }
      if op == "island.set" {
        let text = args["text"]?.stringValue ?? ""
        let seconds = args["seconds"]?.numberValue ?? 0
        host.setIslandText(text, seconds: seconds)
        settle(callId, ok: true, payload: "null")
        return
      }
    }

    let url = target
    Task { [self] in
      do {
        let payload = try await perform(op: op, args: args, url: url)
        settle(callId, ok: true, payload: payload)
      } catch {
        if case ScriptModError.permissionDenied(let message) = error {
          finish(.failure(.permissionDenied(message)))
        } else {
          settle(callId, ok: false, payload: ScriptBridgeError.message(of: error))
        }
      }
    }
  }

  private func perform(op: String, args: JSONValue, url: URL?) async throws -> String {
    switch op {
    case "tasks.list":
      return try encode(await host.listTasks())
    case "tasks.add":
      let title = try ScriptBridgeError.requiredString(args, "title")
      return try encode(await host.addTask(title: title, due: args["due"]?.stringValue))
    case "tasks.complete":
      let id = try ScriptBridgeError.requiredString(args, "id")
      try await host.completeTask(id: id)
      return "null"
    case "notes.list":
      return try encode(await host.listNotes())
    case "notes.add":
      let title = try ScriptBridgeError.requiredString(args, "title")
      return try encode(await host.addNote(title: title, content: args["content"]?.stringValue ?? ""))
    case "calendar.events":
      let from = try ScriptBridgeError.requiredString(args, "from")
      let to = try ScriptBridgeError.requiredString(args, "to")
      return try encode(await host.listEvents(from: from, to: to))
    case "http.get":
      guard let url else { throw ScriptBridgeError("Ungültige Adresse.") }
      return try await fetch(url)
    case "habits.list":
      return try encode(try await host.listHabits())
    case "habits.check":
      let id = try ScriptBridgeError.requiredString(args, "id")
      return try encode(try await host.checkHabit(id: id))
    case "focus.start":
      let minutes = try scriptInt(args["minutes"])
      if let minutes, !(1...240).contains(minutes) { throw ScriptBridgeError("Fokus geht von 1 bis 240 Minuten.") }
      try await host.startFocus(minutes: minutes)
      return "null"
    case "focus.stop":
      try await host.stopFocus()
      return "null"
    case "focus.isRunning":
      return try encode(try await host.focusIsRunning())
    case "timer.start":
      guard let minutes = try scriptInt(args["minutes"]) else {
        throw ScriptBridgeError("„minutes“ fehlt.")
      }
      guard (1...720).contains(minutes) else { throw ScriptBridgeError("Wecker gehen von 1 bis 720 Minuten.") }
      try await host.startTimer(minutes: minutes, label: args["label"]?.stringValue ?? "")
      return "null"
    case "messages.recent":
      let raw = try scriptInt(args["limit"]) ?? 10
      return try encode(try await host.recentMessages(limit: min(max(raw, 1), 20)))
    case "mail.draft":
      let items = args["to"]?.arrayValue ?? args["to"]?.stringValue.map { [JSONValue.string($0)] } ?? []
      let to = items.compactMap(\.stringValue)
      guard !to.isEmpty else { throw ScriptBridgeError("„to“ fehlt (mindestens eine Adresse).") }
      // Dieselbe Prüfung wie bei send_mail: nur reine Adressen, höchstens 20, keine Anzeigenamen.
      guard to.count == items.count, to.count <= 20, to.allSatisfy(MailTools.isPlausibleAddress) else {
        throw ScriptBridgeError("„to“ enthält keine gültige Adresse (nur reine Adressen wie name@beispiel.de).")
      }
      let draft = MailDraft(to: to, subject: args["subject"]?.stringValue ?? "", body: args["body"]?.stringValue ?? "")
      try await host.openMailDraft(draft)
      return "null"
    case "storage.get":
      let key = try ScriptBridgeError.requiredString(args, "key")
      return try encode(try await host.storageGet(key: key))
    case "storage.set":
      let key = try ScriptBridgeError.requiredString(args, "key")
      guard let value = args["value"] else { throw ScriptBridgeError("„value“ fehlt.") }
      try await host.storageSet(key: key, value: value)
      return "null"
    default:
      throw ScriptBridgeError("Unbekannte Funktion \(op).")
    }
  }

  /// GET ohne Cookies; Weiterleitungen nur auf freigegebene Adressen.
  /// Die Antwort wird während des Ladens gezählt; über 1 MB bricht der Abruf ab.
  private func fetch(_ url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    let redirectGuard = ScriptRedirectGuard(permissions: permissions)
    let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
    if redirectGuard.blocked {
      throw ScriptModError.permissionDenied("Eine Weiterleitung führt zu einer nicht freigegebenen Adresse und wurde blockiert.")
    }
    let tooLarge = ScriptBridgeError("Die Antwort ist größer als 1 MB.")
    if response.expectedContentLength > Int64(ScriptHTTP.maxBytes) { throw tooLarge }
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count > ScriptHTTP.maxBytes { throw tooLarge }
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let text = String(decoding: data, as: UTF8.self)
    let json = JSONValue.parse(text) ?? .null
    return JSONValue.object([
      "status": .number(Double(status)),
      "text": .string(text),
      "json": json,
    ]).jsonString()
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  /// Löst einen wartenden Promise-Aufruf im Skript auf (jeder Aufruf über queue).
  private func settle(_ callId: Int, ok: Bool, payload: String) {
    queue.async { [self] in
      guard !isFinished, let resolve = resolveFunction else { return }
      _ = resolve.call(withArguments: [callId, ok, payload])
    }
  }

  private func appendLog(_ line: String) {
    guard logs.count < 100 else { return }
    logs.append(String(line.prefix(500)))
  }

  /// Ergebnis der `run`-Funktion (läuft auf queue).
  private func finishFromScript(_ args: JSONValue) {
    let text = args["text"]?.stringValue ?? ""
    switch args["kind"]?.stringValue ?? "" {
    case "ok":
      finish(.success(ScriptRunResult(output: text, logs: logs)))
    case "invalid":
      finish(.failure(.invalidResult))
    default:
      finish(.failure(.scriptError(text.isEmpty ? "Unbekannter Fehler" : text)))
    }
  }
}

/// Ganze Zahl aus einem Skriptwert. Nicht endliche oder zu große Werte werden abgelehnt,
/// bevor sie in Int umgewandelt werden (Int(Double) würde sonst abstürzen).
func scriptInt(_ v: JSONValue?) throws -> Int? {
  guard let d = v?.numberValue else { return nil }
  guard d.isFinite, abs(d) < 1e15 else { throw ScriptBridgeError("Ungültige Zahl.") }
  return Int(d)
}
