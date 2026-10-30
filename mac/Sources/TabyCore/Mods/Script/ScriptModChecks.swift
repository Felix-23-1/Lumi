// Prüfungen für Mods/Script (JavaScript-Sandbox). Kein echtes Netz: http läuft
// über einen URLProtocol-Stub, der Speicher ist ein Fake.
import Foundation

enum ScriptModChecks {
  static let cases: [CheckCase] = [
    CheckCase("Mod-Hosts: IP-Adressen und lokale Namen werden abgelehnt") {
      for host in ["192.168.1.1", "10.0.0.1", "127.0.0.1", "2130706433", "0x7f000001", "[::1]", "::1",
                   "localhost", "printer.local", "fe80::1"] {
        try expect(ScriptHTTP.isLocalOrIPHost(host), "\(host) sollte abgelehnt werden")
      }
      for host in ["example.com", "api.example.co.uk", "a1.b2.de"] {
        try expect(!ScriptHTTP.isLocalOrIPHost(host), "\(host) sollte erlaubt bleiben")
      }
      try expect(!ModValidation.isValidDomain("192.168.1.1"), "Mod-Recht http:192.168.1.1 darf nicht gültig sein")
      try expect(ModValidation.isValidDomain("example.com"), "Domain example.com muss gültig bleiben")
      var blocked = false
      do { _ = try ScriptHTTP.authorize("https://192.168.1.1/x", permissions: ["http:192.168.1.1"]) } catch { blocked = true }
      try expect(blocked, "https-Abruf an eine IP-Adresse muss scheitern")
    },
    CheckCase("Rückgabe als Text, Zahl und Objekt") {
      let text = try await scriptRun(#"function run(){ return "hallo" }"#)
      try expectEqual(text.output, "hallo")
      let number = try await scriptRun("function run(){ return 42 }")
      try expectEqual(number.output, "42")
      let object = try await scriptRun(#"function run(){ return {a:1, b:"x"} }"#)
      try expectEqual(object.output, #"{"a":1,"b":"x"}"#)
    },
    CheckCase("Asynchrone run-Funktion mit Eingabe") {
      let r = try await scriptRun(
        #"async function run(input){ const x = await Promise.resolve(5); return "v" + (x + input.n) }"#,
        input: .object(["n": 2]))
      try expectEqual(r.output, "v7")
    },
    CheckCase("console.log wird gesammelt") {
      let r = try await scriptRun(#"function run(){ console.log("eins", {x:1}); console.log("zwei"); return "ok" }"#)
      try expectEqual(r.output, "ok")
      try expectEqual(r.logs, [#"eins {"x":1}"#, "zwei"])
    },
    CheckCase("Logs sind auf 100 Zeilen und 500 Zeichen begrenzt") {
      let r = try await scriptRun(
        #"function run(){ for (let i = 0; i < 150; i++) console.log("z" + i); console.log("x".repeat(600)); return "ok" }"#)
      try expectEqual(r.logs.count, 100)
      try expectEqual(r.logs[99], "z99")
      let long = try await scriptRun(#"function run(){ console.log("x".repeat(600)); return "ok" }"#)
      try expectEqual(long.logs.first?.count ?? 0, 500)
    },
    CheckCase("Aufgaben lesen nur mit tasks.read") {
      let host = ScriptFakeHost()
      let r = try await scriptRun(
        #"async function run(){ const t = await taby.tasks.list(); return String(t.length) + t[0].title }"#,
        perms: ["tasks.read"], host: host)
      try expectEqual(r.output, "1Steuer")
      try expectEqual(host.calls, ["tasks.list"])
      let denied = ScriptFakeHost()
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.tasks.list() }"#, host: denied)
      try expectEqual(denied.calls.isEmpty, true, "ohne Recht darf der Host nicht aufgerufen werden")
    },
    CheckCase("Aufgaben anlegen und abhaken nur mit tasks.write") {
      let host = ScriptFakeHost()
      let r = try await scriptRun(
        #"async function run(){ const t = await taby.tasks.add({title:"Milch", due:"2026-10-13"}); await taby.tasks.complete(t.id); return t.title }"#,
        perms: ["tasks.write"], host: host)
      try expectEqual(r.output, "Milch")
      try expectEqual(host.calls, ["tasks.add:Milch", "tasks.complete:t2"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.tasks.add({title:"X"}) }"#, perms: ["tasks.read"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.tasks.complete("t1") }"#, perms: ["tasks.read"])
    },
    CheckCase("Notizen lesen und anlegen mit eigenem Recht") {
      let r = try await scriptRun(
        #"async function run(){ const n = await taby.notes.list(); return n[0].title }"#,
        perms: ["notes.read"])
      try expectEqual(r.output, "Idee")
      let w = try await scriptRun(
        #"async function run(){ const n = await taby.notes.add({title:"Neu", content:"Text"}); return n.title }"#,
        perms: ["notes.write"])
      try expectEqual(w.output, "Neu")
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.notes.add({title:"X", content:""}) }"#, perms: ["notes.read"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.notes.list() }"#, perms: ["notes.write"])
    },
    CheckCase("Termine lesen nur mit calendar.read") {
      let host = ScriptFakeHost()
      let r = try await scriptRun(
        #"async function run(){ const e = await taby.calendar.events("2026-10-13", "2026-10-14"); return e[0].title }"#,
        perms: ["calendar.read"], host: host)
      try expectEqual(r.output, "Zahnarzt")
      try expectEqual(host.calls, ["calendar.events:2026-10-13-2026-10-14"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.calendar.events("2026-10-13", "2026-10-14") }"#, perms: ["tasks.read"])
    },
    CheckCase("Insel-Text nur mit island.text; clamp auf 40 Zeichen beim Vertrag") {
      let host = ScriptFakeHost()
      let r = try await scriptRun(
        #"async function run(){ await taby.island.set("Noch 3 Tage", 3600); return "ok" }"#,
        perms: ["island.text"], host: host)
      try expectEqual(r.output, "ok")
      try expectEqual(host.islandTexts.count, 1)
      try expectEqual(host.islandTexts.first?.0, "Noch 3 Tage")
      try expectEqual(host.islandTexts.first?.1, 3600)
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.island.set("x", 60) }"#, host: ScriptFakeHost())
      // Vertrag kürzt auf 40 Zeichen.
      try expectEqual(IslandMessage(text: String(repeating: "a", count: 60), until: "2026-01-01T00:00", modId: "m").text.count, 40)
    },
    CheckCase("Benachrichtigung nur mit notify") {
      let host = ScriptFakeHost()
      let r = try await scriptRun(
        #"async function run(){ await taby.notify("Titel", "Text"); return "ok" }"#,
        perms: ["notify"], host: host)
      try expectEqual(r.output, "ok")
      try expectEqual(host.notifications, [TabyNotification(title: "Titel", body: "Text")])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.notify("Titel", "Text") }"#, host: ScriptFakeHost())
    },
    CheckCase("Internet für freigegebene Domain und Subdomain") {
      let direct = try await scriptRun(
        #"async function run(){ const r = await taby.http.get("https://example.com/wetter"); return r.status + ":" + r.json.temp }"#,
        perms: ["http:example.com"])
      try expectEqual(direct.output, "200:12")
      let sub = try await scriptRun(
        #"async function run(){ const r = await taby.http.get("https://api.example.com/text"); return r.text }"#,
        perms: ["http:example.com"])
      try expectEqual(sub.output, "hallo")
      let serverError = try await scriptRun(
        #"async function run(){ const r = await taby.http.get("https://example.com/fehler"); return String(r.status) }"#,
        perms: ["http:example.com"])
      try expectEqual(serverError.output, "500")
    },
    CheckCase("Internet verboten: fremde Domain, http, Namensendung, ohne Recht") {
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.http.get("https://evil.example.org/") }"#,
        perms: ["http:example.com"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.http.get("http://example.com/wetter") }"#,
        perms: ["http:example.com"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.http.get("https://notexample.com/") }"#,
        perms: ["http:example.com"])
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.http.get("https://example.com/wetter") }"#)
    },
    CheckCase("Weiterleitung auf fremde Domain wird blockiert") {
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ return await taby.http.get("https://example.com/redirect") }"#,
        perms: ["http:example.com"])
    },
    CheckCase("Antwort über 1 MB wird als Fehler gemeldet") {
      let r = try await scriptRun(
        #"async function run(){ try { await taby.http.get("https://example.com/gross"); return "ok" } catch (e) { return "fehler: " + e.message } }"#,
        perms: ["http:example.com"])
      try expect(r.output.hasPrefix("fehler:"), "war \(r.output)")
    },
    CheckCase("Ausnahme im Skript wird zu scriptError") {
      try await scriptExpectFailure("scriptError", #"function run(){ throw new Error("kaputt") }"#, contains: "kaputt")
      try await scriptExpectFailure("scriptError", #"async function run(){ throw new Error("async kaputt") }"#, contains: "async kaputt")
      try await scriptExpectFailure("scriptError", "function run( {", contains: "")
    },
    CheckCase("Fehlendes run() ist ein scriptError") {
      try await scriptExpectFailure("scriptError", "function nichtRun(){ return 1 }", contains: "run(input)")
    },
    CheckCase("Ohne Rückgabe ist das Ergebnis ungültig") {
      try await scriptExpectFailure("invalidResult", "function run(){}")
    },
    CheckCase("Zeitüberschreitung bei nie erfüllten Promise") {
      try await scriptExpectFailure("timeout", "function run(){ return new Promise(function(){}) }", timeout: 0.5)
    },
    CheckCase("Endlosschleife: Fehler innerhalb der Zeit; mit harter Grenze ist der Mod danach wieder frei") {
      try await scriptExpectFailure("timeout", "function run(){ while(true){} }", timeout: 0.5)
      guard ScriptTimeLimit.setLimit != nil else {
        // Ohne das private Symbol hängt der Lauf weiter: der Mod bleibt gesperrt (Begrenzung der Läufe).
        try await scriptExpectFailure("scriptError", "function run(){ return 1 }", contains: "läuft noch")
        return
      }
      var free = false
      for _ in 0..<300 where !free {
        if ScriptRunLimits.acquire("pruefung-skript") { ScriptRunLimits.release("pruefung-skript"); free = true }
        else { try await Task.sleep(nanoseconds: 10_000_000) }
      }
      try expect(free, "Die harte Grenze beendet die Schleife nicht")
      let r = try await scriptRun("function run(){ return 2 }")
      try expectEqual(r.output, "2")
    },
    CheckCase("Läufe: höchstens einer je Mod und vier insgesamt") {
      // Läufe aus früheren Prüfungen (z. B. Mods mit offenem Versprechen bis zur Frist) belegen Plätze:
      // erst warten, bis keiner mehr läuft, sonst hängt die Zählung vom Zufall ab.
      for _ in 0..<600 where ScriptRunLimits.activeCount > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
      let ids = ["cap-a", "cap-b", "cap-c", "cap-d", "cap-e"]
      defer { for id in ids { ScriptRunLimits.release(id) } }
      try expect(ScriptRunLimits.acquire(ids[0]))
      try expect(!ScriptRunLimits.acquire(ids[0]), "zweiter Lauf desselben Mods wird abgelehnt")
      try expect(ScriptRunLimits.acquire(ids[1]))
      try expect(ScriptRunLimits.acquire(ids[2]))
      try expect(ScriptRunLimits.acquire(ids[3]))
      try expect(!ScriptRunLimits.acquire(ids[4]), "fünfter Lauf insgesamt wird abgelehnt")
      ScriptRunLimits.release(ids[1])
      try expect(ScriptRunLimits.acquire(ids[4]), "nach einem Ende ist wieder Platz")
    },
    CheckCase("Zeitgrenze: nur Meldungen von JavaScriptCore zählen als Zeitüberschreitung") {
      try expect(ScriptRun.isTimeLimit("JavaScript execution terminated."))
      try expect(ScriptRun.isTimeLimit("JavaScript execution time limit"))
      try expect(!ScriptRun.isTimeLimit("Der Mod wurde terminated von Hand"), "eigener Text bleibt Skriptfehler")
      try expect(!ScriptRun.isTimeLimit("Verbindung terminated"), "eigener Text bleibt Skriptfehler")
    },
    CheckCase("Freigabe: Lesen plus http: warnt vor dem Ins-Internet-Schicken, nur Lesen oder nur Internet nicht") {
      try expectEqual(ModPermission.exfiltrationWarning(["tasks.read", "http:api.example.com"]),
                      "Kann gelesene Daten ins Internet schicken")
      try expectEqual(ModPermission.exfiltrationWarning(["notify", "http:api.example.com"]), nil)
      try expectEqual(ModPermission.exfiltrationWarning(["calendar.read"]), nil)
    },
    CheckCase("Rate-Limit: zehn Benachrichtigungen je Stunde und Mod, danach wieder nach einer Stunde") {
      let t0 = Date(timeIntervalSince1970: 1_000_000)
      for i in 0..<10 {
        try expect(ScriptRateLimit.allow("rate-mod", op: "notify", now: t0.addingTimeInterval(Double(i))), "Aufruf \(i + 1)")
      }
      try expect(!ScriptRateLimit.allow("rate-mod", op: "notify", now: t0.addingTimeInterval(20)), "elfter Aufruf abgelehnt")
      try expect(ScriptRateLimit.allow("rate-mod", op: "island.set", now: t0.addingTimeInterval(20)), "eigene Zählung je Art")
      try expect(ScriptRateLimit.allow("rate-mod", op: "notify", now: t0.addingTimeInterval(3_601)), "nach einer Stunde wieder frei")
    },
    CheckCase("create_mod: die Beschreibung nennt alle bekannten Rechte") {
      let text = ModRuntime.createModTool.parameters.jsonString()
      for permission in ModPermission.known.sorted() {
        try expect(text.contains(permission), "\(permission) fehlt in create_mod")
      }
    },
    CheckCase("Kein require, process oder module verfügbar") {
      let r = try await scriptRun(#"function run(){ return typeof require + "," + typeof process + "," + typeof module }"#)
      try expectEqual(r.output, "undefined,undefined,undefined")
    },
    CheckCase("Verweigertes Recht beendet den Lauf, auch wenn das Skript fängt") {
      try await scriptExpectFailure("permissionDenied",
        #"async function run(){ try { await taby.notes.list() } catch (e) { return "gefangen" } return "ok" }"#)
    },
  ]
}

// MARK: - Hilfen

/// Fake-Speicher: zeichnet Aufrufe auf, liefert feste Daten.
private final class ScriptFakeHost: ModHostAPI, @unchecked Sendable {
  var calls: [String] = []
  var notifications: [TabyNotification] = []
  var tasks: [TabyTask] = [TabyTask(id: "t1", title: "Steuer", createdAt: "2026-10-01T09:00")]
  var notes: [Note] = [Note(id: "n1", title: "Idee", content: "Text", createdAt: "2026-10-01T09:00", updatedAt: "2026-10-01T09:00")]
  var events: [CalendarEvent] = [CalendarEvent(id: "e1", sourceId: "local", title: "Zahnarzt", start: "2026-10-13T09:00")]

  func listTasks() async throws -> [TabyTask] {
    calls.append("tasks.list")
    return tasks
  }

  func addTask(title: String, due: String?) async throws -> TabyTask {
    calls.append("tasks.add:\(title)")
    return TabyTask(id: "t2", title: title, due: due, createdAt: "2026-10-12T10:00")
  }

  func completeTask(id: String) async throws {
    calls.append("tasks.complete:\(id)")
  }

  func listNotes() async throws -> [Note] {
    calls.append("notes.list")
    return notes
  }

  func addNote(title: String, content: String) async throws -> Note {
    calls.append("notes.add:\(title)")
    return Note(id: "n2", title: title, content: content, createdAt: "2026-10-12T10:00", updatedAt: "2026-10-12T10:00")
  }

  func listEvents(from: String, to: String) async throws -> [CalendarEvent] {
    calls.append("calendar.events:\(from)-\(to)")
    return events
  }

  var islandTexts: [(String, Double)] = []
  func setIslandText(_ text: String, seconds: Double) { islandTexts.append((text, seconds)) }
  func notify(_ n: TabyNotification) {
    notifications.append(n)
  }
}

/// URLProtocol-Stub: antwortet nur mit festen Routen, nie mit echtem Netz.
private final class ScriptStubProtocol: URLProtocol {
  struct Route {
    let status: Int
    let body: Data
    let headers: [String: String]
  }

  nonisolated(unsafe) static var routes: [String: Route] = [:]

  static func install() {
    routes = [
      "https://example.com/wetter": Route(status: 200, body: Data(#"{"temp": 12}"#.utf8),
                                          headers: ["Content-Type": "application/json"]),
      "https://api.example.com/text": Route(status: 200, body: Data("hallo".utf8), headers: [:]),
      "https://example.com/fehler": Route(status: 500, body: Data("kaputt".utf8), headers: [:]),
      "https://example.com/redirect": Route(status: 302, body: Data(),
                                            headers: ["Location": "https://evil.example.org/"]),
      "https://example.com/gross": Route(status: 200, body: Data(count: ScriptHTTP.maxBytes + 1), headers: [:]),
    ]
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.scheme == "https" || request.url?.scheme == "http"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let route = ScriptStubProtocol.routes[url.absoluteString]
      ?? Route(status: 404, body: Data("nicht gefunden".utf8), headers: [:])
    let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                   headerFields: route.headers)
    if let response, (300..<400).contains(route.status), let location = route.headers["Location"],
       let target = URL(string: location) {
      // Weiterleitungen meldet ein echter Server über wasRedirectedTo; so läuft der Redirect-Delegat.
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    }
    // Wird die Weiterleitung abgelehnt, kommt die 3xx-Antwort selbst an; sonst
    // läuft die Anfrage an der neuen Adresse weiter.
    if let response {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: route.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func scriptStubSession() -> URLSession {
  ScriptStubProtocol.install()
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [ScriptStubProtocol.self]
  return URLSession(configuration: config)
}

private func scriptManifest(_ permissions: [String]) -> ModManifest {
  ModManifest(id: "pruefung-skript", name: "Prüfung", description: "Prüfung", kind: .script,
              entry: "main.js", permissions: permissions)
}

private func scriptRun(_ code: String, perms: [String] = [], host: ScriptFakeHost = ScriptFakeHost(),
                       input: JSONValue = .null, timeout: TimeInterval = 5) async throws -> ScriptRunResult {
  try await ScriptModRunner(host: host, session: scriptStubSession(), timeout: timeout)
    .run(code: code, manifest: scriptManifest(perms), input: input)
}

/// Erwartet einen Fehler der Art `kind` ("permissionDenied", "timeout",
/// "scriptError", "invalidResult"); `contains` prüft die Meldung, wenn gesetzt.
private func scriptExpectFailure(_ kind: String, _ code: String, perms: [String] = [],
                                 host: ScriptFakeHost = ScriptFakeHost(), timeout: TimeInterval = 5,
                                 contains: String = "", file: StaticString = #fileID, line: UInt = #line) async throws {
  var got: ScriptModError?
  var outcome = "kein Fehler"
  do {
    let r = try await scriptRun(code, perms: perms, host: host, timeout: timeout)
    outcome = "Ergebnis „\(r.output)“"
  } catch let e as ScriptModError {
    got = e
  }
  guard let error = got else {
    throw fail("erwartet \(kind), war \(outcome)", file: file, line: line)
  }
  let actual: String
  let message: String
  switch error {
  case .permissionDenied(let m): actual = "permissionDenied"; message = m
  case .timeout: actual = "timeout"; message = ""
  case .scriptError(let m): actual = "scriptError"; message = m
  case .invalidResult: actual = "invalidResult"; message = ""
  }
  try expectEqual(actual, kind, "", file: file, line: line)
  if !contains.isEmpty {
    try expect(message.contains(contains), "Meldung enthält nicht „\(contains)“: \(message)", file: file, line: line)
  }
}
