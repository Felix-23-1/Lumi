// Brücke zwischen JavaScript und Swift für Skript-Mods: das JS-Präludium
// (globales `taby`, `console`), Rechte-Tabelle, HTTP-Regeln und Fehlerhilfen.
import Foundation

enum ScriptModBridge {
  /// Wird einmal je Lauf ausgeführt. Liefert `{ start, resolve }`; nur Swift
  /// hat diese Funktionen, das Skript nicht.
  static let prelude = #"""
  (function () {
    "use strict";
    var native = globalThis.__tabyNative;
    delete globalThis.__tabyNative;
    var nextId = 1;
    var pending = {};

    function str(v) {
      return v === undefined || v === null ? undefined : String(v);
    }

    function text(v) {
      if (typeof v === "string") return v;
      try {
        var s = JSON.stringify(v);
        return s === undefined ? String(v) : s;
      } catch (e) {
        return "[nicht darstellbar]";
      }
    }

    function call(op, args) {
      return new Promise(function (resolve, reject) {
        var id = nextId++;
        pending[id] = { resolve: resolve, reject: reject };
        native(op, JSON.stringify(args || {}), id);
      });
    }

    function resolveCall(id, ok, payload) {
      var p = pending[id];
      if (!p) return;
      delete pending[id];
      if (ok) {
        p.resolve(JSON.parse(payload));
      } else {
        p.reject(new Error(payload));
      }
    }

    var console = {
      log: function () {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) parts.push(text(arguments[i]));
        native("log", JSON.stringify({ line: parts.join(" ") }), 0);
      }
    };

    var taby = {
      tasks: {
        list: function () { return call("tasks.list"); },
        add: function (t) {
          return call("tasks.add", { title: str(t && t.title), due: str(t && t.due) });
        },
        complete: function (id) { return call("tasks.complete", { id: str(id) }); }
      },
      notes: {
        list: function () { return call("notes.list"); },
        add: function (n) {
          return call("notes.add", { title: str(n && n.title), content: str(n && n.content) });
        }
      },
      calendar: {
        events: function (from, to) {
          return call("calendar.events", { from: str(from), to: str(to) });
        }
      },
      notify: function (title, body) {
        return call("notify", { title: str(title), body: str(body) });
      },
      island: {
        set: function (text, seconds) {
          return call("island.set", { text: str(text), seconds: Number(seconds) || 0 });
        }
      },
      http: {
        get: function (url) { return call("http.get", { url: str(url) }); }
      },
      habits: {
        list: function () { return call("habits.list"); },
        check: function (id) { return call("habits.check", { id: str(id) }); }
      },
      focus: {
        start: function (minutes) {
          return call("focus.start", { minutes: minutes === undefined ? undefined : Number(minutes) });
        },
        stop: function () { return call("focus.stop"); },
        isRunning: function () { return call("focus.isRunning"); }
      },
      timer: {
        start: function (minutes, label) {
          return call("timer.start", { minutes: Number(minutes), label: str(label) });
        }
      },
      messages: {
        recent: function (limit) {
          return call("messages.recent", { limit: limit === undefined ? undefined : Number(limit) });
        }
      },
      mail: {
        draft: function (d) {
          return call("mail.draft", { to: d && d.to, subject: str(d && d.subject), body: str(d && d.body) });
        }
      },
      storage: {
        get: function (key) { return call("storage.get", { key: str(key) }); },
        set: function (key, value) { return call("storage.set", { key: str(key), value: value }); }
      }
    };

    globalThis.taby = taby;
    globalThis.console = console;

    function errorText(e) {
      try {
        return e && typeof e.message === "string" ? e.message : String(e);
      } catch (x) {
        return "Unbekannter Fehler";
      }
    }

    function report(kind, value) {
      native("done", JSON.stringify({ kind: kind, text: value }), 0);
    }

    function serialize(v) {
      if (typeof v === "string") return { kind: "ok", text: v };
      if (v === undefined || typeof v === "function" || typeof v === "symbol") {
        return { kind: "invalid", text: "" };
      }
      try {
        var s = JSON.stringify(v);
        if (typeof s !== "string") return { kind: "invalid", text: "" };
        return { kind: "ok", text: s };
      } catch (e) {
        return { kind: "invalid", text: "" };
      }
    }

    function start(inputJSON) {
      try {
        if (typeof globalThis.run !== "function") {
          report("error", "Das Skript definiert keine Funktion run(input).");
          return;
        }
        var input = JSON.parse(inputJSON);
        Promise.resolve(globalThis.run(input)).then(function (v) {
          var r = serialize(v);
          report(r.kind, r.text);
        }, function (e) {
          report("error", errorText(e));
        });
      } catch (e) {
        report("error", errorText(e));
      }
    }

    return { start: start, resolve: resolveCall };
  })()
  """#
}

enum ScriptPermissions {
  /// Recht, das eine API-Funktion braucht (http.get wird gesondert geprüft).
  static func required(_ op: String) -> String? {
    switch op {
    case "tasks.list": return "tasks.read"
    case "tasks.add", "tasks.complete": return "tasks.write"
    case "notes.list": return "notes.read"
    case "notes.add": return "notes.write"
    case "calendar.events": return "calendar.read"
    case "notify": return "notify"
    case "island.set": return "island.text"
    case "habits.list": return "habits.read"
    case "habits.check": return "habits.write"
    case "focus.start", "focus.stop", "focus.isRunning": return "focus"
    case "timer.start": return "timer"
    case "messages.recent": return "messages.read"
    case "mail.draft": return "mail.draft"
    case "storage.get", "storage.set": return "storage"
    default: return nil
    }
  }

  static func deniedMessage(_ permission: String) -> String {
    "Der Mod darf nicht „\(ModPermission.describe(permission))“ (Recht \(permission) fehlt)."
  }
}

extension ModPermission {
  /// Rechte, mit denen der Mod Daten liest.
  static let readRights: Set<String> = ["tasks.read", "notes.read", "calendar.read", "habits.read", "messages.read"]

  /// Lesen und Internet zusammen: der Mod kann gelesene Daten nach außen schicken (Freigabe-Warnung).
  public static func exfiltrationWarning(_ permissions: [String]) -> String? {
    let reads = permissions.contains { readRights.contains($0) }
    let internet = permissions.contains { $0.hasPrefix("http:") }
    return reads && internet ? "Kann gelesene Daten ins Internet schicken" : nil
  }
}

enum ScriptHTTP {
  static let maxBytes = 1_048_576

  /// IP-Adressen (v6, und v4 in Dezimal-, Hex- oder Einzahl-Form, z. B. 2130706433 oder
  /// 0x7f000001) sowie localhost und .local. Eine öffentliche Domain endet nie auf Ziffern.
  static func isLocalOrIPHost(_ host: String) -> Bool {
    let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if h.isEmpty || h.contains(":") { return true }
    let labels = h.split(separator: ".", omittingEmptySubsequences: false)
    guard let last = labels.last, !last.isEmpty else { return true }
    if h == "localhost" || last == "localhost" || last == "local" { return true }
    if last.allSatisfy(\.isNumber) { return true }
    return last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)
  }

  /// Prüft eine Adresse für `taby.http.get`: nur https, Host gleich oder
  /// Subdomain einer freigegebenen Domain `http:<domain>`.
  static func authorize(_ raw: String, permissions: Set<String>) throws -> URL {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          let host = url.host?.lowercased(), !host.isEmpty else {
      throw ScriptModError.permissionDenied("Ungültige Adresse für den Internetabruf.")
    }
    guard scheme == "https" else {
      throw ScriptModError.permissionDenied("Nur https-Adressen sind erlaubt (\(scheme)-Adresse abgelehnt).")
    }
    guard !isLocalOrIPHost(host) else {
      throw ScriptModError.permissionDenied("„\(host)“ ist eine IP-Adresse oder ein lokaler Name und ist nicht erlaubt.")
    }
    let domains = permissions
      .filter { $0.hasPrefix("http:") }
      .map { String($0.dropFirst(5)).lowercased() }
      .filter { !$0.isEmpty }
    let allowed = domains.contains { domain in host == domain || host.hasSuffix("." + domain) }
    guard allowed else {
      throw ScriptModError.permissionDenied("Keine Freigabe für „\(host)“. Der Mod braucht das Recht http:\(host).")
    }
    return url
  }
}

/// Lässt Weiterleitungen nur zu, wenn das Ziel ebenfalls freigegeben ist.
final class ScriptRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let permissions: Set<String>
  private let lock = NSLock()
  private var wasBlocked = false

  init(permissions: Set<String>) {
    self.permissions = permissions
  }

  var blocked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return wasBlocked
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    var allowed = false
    if let target = request.url {
      allowed = (try? ScriptHTTP.authorize(target.absoluteString, permissions: permissions)) != nil
    }
    if !allowed {
      lock.lock()
      wasBlocked = true
      lock.unlock()
    }
    completionHandler(allowed ? request : nil)
  }
}

/// Fehler, die als Ablehnung des Promise im Skript ankommen.
struct ScriptBridgeError: LocalizedError {
  let message: String

  static let unavailable = ScriptBridgeError("Diese Funktion ist hier nicht verfügbar.")

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }

  static func requiredString(_ args: JSONValue, _ key: String) throws -> String {
    guard let value = args[key]?.stringValue, !value.isEmpty else {
      throw ScriptBridgeError("„\(key)“ fehlt oder ist leer.")
    }
    return value
  }

  static func message(of error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
