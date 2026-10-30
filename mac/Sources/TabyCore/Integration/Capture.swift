// Merk dir das: Kontext der vordersten App (Safari-Tab, Mail-Nachricht, Finder-Auswahl)
// per AppleScript holen und als Notiz, Aufgabe oder „Später lesen“ speichern.
// Skripte laufen über die injizierte Skriptausführung; eine App wird nie gestartet.
import AppKit
import Foundation

/// Die App, aus der der Kontext kommt.
public struct CaptureFrontApp: Equatable, Sendable {
  public var bundleId: String?
  public var name: String
  public init(bundleId: String?, name: String) { self.bundleId = bundleId; self.name = name }
}

/// Apps mit eigenem Auszug; alle anderen liefern nur ihren Namen.
enum CaptureApp: String {
  case safari = "Safari", mail = "Mail", finder = "Finder"
}

/// Reine Auswertung der Skriptausgabe (ohne App und ohne Skript).
enum CaptureParser {
  /// Erste Zeile der Ausgabe, getrennt nach Tabs (leer, wenn nichts da ist).
  static func fields(_ stdout: String) -> [String] {
    let line = stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
  }

  /// Safari: "URL<TAB>Seitentitel". Leere Seite oder keine URL → nil.
  static func safari(_ stdout: String) -> CapturedContext? {
    let f = fields(stdout)
    guard f.count >= 2, !f[0].isEmpty else { return nil }
    let title = f[1].isEmpty ? f[0] : f[1]
    return CapturedContext(app: CaptureApp.safari.rawValue, title: title, url: f[0])
  }

  /// Mail: "Betreff<TAB>Absender<TAB>Message-ID". Ohne Betreff und Absender → nil.
  static func mail(_ stdout: String) -> CapturedContext? {
    let f = fields(stdout)
    guard f.count >= 3, !(f[0].isEmpty && f[1].isEmpty) else { return nil }
    let title = f[0].isEmpty ? "(ohne Betreff)" : f[0]
    let sender = f[1].isEmpty ? nil : "Von: \(f[1])"
    return CapturedContext(app: CaptureApp.mail.rawValue, title: title,
                           url: mailLink(messageId: f[2]), text: sender)
  }

  /// Mail-Link `message://%3C…%3E` zur Nachricht; nil ohne Message-ID.
  static func mailLink(messageId: String) -> String? {
    var id = messageId.trimmingCharacters(in: .whitespaces)
    if id.hasPrefix("<") { id.removeFirst() }
    if id.hasSuffix(">") { id.removeLast() }
    guard !id.isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return "message://%3C\(encoded)%3E"
  }

  /// Finder: ein POSIX-Pfad je Zeile. Erster Pfad gibt Titel und Link; mehrere werden aufgelistet.
  static func finder(_ stdout: String) -> CapturedContext? {
    let paths = stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    guard let first = paths.first else { return nil }
    let name = (first as NSString).lastPathComponent
    let title = paths.count > 1 ? "\(name) und \(paths.count - 1) weitere" : name
    let text = paths.count > 1 ? paths.map(fileURL).joined(separator: "\n") : nil
    return CapturedContext(app: CaptureApp.finder.rawValue, title: title, url: fileURL(first), text: text)
  }

  static func fileURL(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }

  /// Automation fehlt (AppleEvent -1743).
  static func denied(_ stderr: String) -> Bool {
    stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("Not authorized")
  }

  /// Text für Notiz und Aufgabe: Link und Auszug, je eine Zeile.
  static func body(_ c: CapturedContext) -> String {
    [c.url, c.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// Vorderste fremde App; ist Lumi selbst vorn, gilt die zuletzt aktive fremde App.
  static func pick(front: CaptureFrontApp?, previous: CaptureFrontApp?) -> CaptureFrontApp? {
    guard let front else { return previous }
    return isOwn(front) ? previous : front
  }

  static func isOwn(_ app: CaptureFrontApp) -> Bool {
    app.bundleId == Bundle.main.bundleIdentifier || app.name == "Lumi"
  }
}

/// AppleScript je App. Läuft nur, wenn die App schon läuft (kein Start).
enum CaptureScripts {
  static func script(_ app: CaptureApp) -> String {
    switch app {
    case .safari:
      return """
      if application "Safari" is running then
        tell application "Safari"
          if (count of windows) is 0 then return ""
          return (URL of current tab of front window) & tab & (name of current tab of front window)
        end tell
      end if
      return ""
      """
    case .mail:
      return """
      if application "Mail" is running then
        tell application "Mail"
          set sel to selection
          if (count of sel) is 0 then return ""
          set m to item 1 of sel
          return (subject of m) & tab & (sender of m) & tab & (message id of m)
        end tell
      end if
      return ""
      """
    case .finder:
      return """
      tell application "Finder"
        set out to ""
        repeat with f in (selection as list)
          set out to out & (POSIX path of (f as alias)) & linefeed
        end repeat
        return out
      end tell
      """
    }
  }

  static func parse(_ app: CaptureApp, _ stdout: String) -> CapturedContext? {
    switch app {
    case .safari: CaptureParser.safari(stdout)
    case .mail: CaptureParser.mail(stdout)
    case .finder: CaptureParser.finder(stdout)
    }
  }
}

/// Merkt sich die zuletzt aktive fremde App (Lumi selbst ist beim Kurzbefehl oft vorn).
@MainActor
public enum FrontAppTracker {
  private static var lastForeign: CaptureFrontApp?
  private static var observer: NSObjectProtocol?

  /// Einmal beim Start aufrufen.
  public static func start() {
    guard observer == nil else { return }
    lastForeign = resolveNow(previous: nil)
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        guard let app else { return }
        let entry = CaptureFrontApp(bundleId: app.bundleIdentifier, name: app.localizedName ?? "")
        if !CaptureParser.isOwn(entry) { FrontAppTracker.lastForeign = entry }
      }
    }
  }

  /// Vorderste fremde App, sonst die zuletzt aktive.
  public static func resolve() -> CaptureFrontApp? {
    resolveNow(previous: lastForeign)
  }

  private static func resolveNow(previous: CaptureFrontApp?) -> CaptureFrontApp? {
    let front = NSWorkspace.shared.frontmostApplication.map {
      CaptureFrontApp(bundleId: $0.bundleIdentifier, name: $0.localizedName ?? "")
    }
    return CaptureParser.pick(front: front, previous: previous)
  }
}

extension CoreServices {
  public func captureContext() async -> ToolResult<CapturedContext> {
    guard let front = options.captureFrontApp?() ?? FrontAppTracker.resolve() else {
      return .failure(code: "NO_APP", error: "Keine App gefunden, aus der Lumi etwas übernehmen kann.")
    }
    let fallback = CapturedContext(app: front.name, title: front.name)
    guard let app = CaptureApp(rawValue: front.name) else { return .ok(fallback) }

    let run = options.captureScriptRunner ?? IMessageConnector.osascript
    let script = CaptureScripts.script(app)
    guard let r = try? await Blocking.run({ try run(script) }) else { return .ok(fallback) }
    if CaptureParser.denied(r.stderr) {
      return .failure(code: "DENIED", error: "Lumi darf \(app.rawValue) nicht steuern – Systemeinstellungen → Datenschutz & Sicherheit → Automation → Lumi → \(app.rawValue).")
    }
    guard r.status == 0, let ctx = CaptureScripts.parse(app, r.stdout) else { return .ok(fallback) }
    return .ok(ctx)
  }

  public func saveCapture(_ context: CapturedContext, as target: CaptureTarget) async -> ToolResult<Empty> {
    let error: String?
    switch target {
    case .note:
      error = await addNote(title: context.title, content: CaptureParser.body(context)).errorMessage
    case .task:
      error = await addTask(title: context.title, notes: context.url, due: nil).errorMessage
    case .readLater:
      error = await addNote(title: "📖 Später lesen: \(context.title)", content: CaptureParser.body(context)).errorMessage
    }
    if let error { return .failure(code: "SAVE", error: error) }
    return .ok(Empty())
  }
}
