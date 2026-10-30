// Kurzbefehl-Mods (Paket 3): Aufruf der Apple-App „Kurzbefehle“ über /usr/bin/shortcuts.
import Foundation

public protocol ShortcutsRunning: AnyObject {
  func list() throws -> [String]
  func run(_ name: String, input: String?, timeout: TimeInterval) throws -> String
}

public final class ShortcutsCLI: ShortcutsRunning {
  private let executable: String

  public init() {
    executable = "/usr/bin/shortcuts"
  }

  /// Für Prüfungen mit einem Ersatzprogramm; die App nutzt `init()`.
  init(executablePath: String) {
    executable = executablePath
  }

  public func list() throws -> [String] {
    let r = try ModProcess.run(executable, ["list"], timeout: 30)
    if r.timedOut { throw ModError.process("Die Liste der Kurzbefehle konnte nicht geladen werden (Zeitüberschreitung).") }
    guard r.status == 0 else {
      throw ModError.process("Die Kurzbefehle konnten nicht gelesen werden. \(r.stderr.trimmedText)")
    }
    return r.stdout.split(whereSeparator: \.isNewline)
      .map { String($0).trimmedText }
      .filter { !$0.isEmpty }
  }

  public func run(_ name: String, input: String?, timeout: TimeInterval) throws -> String {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("taby-shortcut-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    let outURL = work.appendingPathComponent("output.txt")
    var args = ["run", name]
    if let input {
      let inURL = work.appendingPathComponent("input.txt")
      try Data(input.utf8).write(to: inURL)
      args += ["--input-path", inURL.path]
    }
    args += ["--output-path", outURL.path]

    let r = try ModProcess.run(executable, args, timeout: timeout)
    if r.timedOut {
      throw ModError.process("Der Kurzbefehl „\(name)“ hat zu lange gebraucht und wurde abgebrochen.")
    }
    guard r.status == 0 else {
      let detail = r.stderr.trimmedText
      throw ModError.process(detail.isEmpty
        ? "Der Kurzbefehl „\(name)“ ist fehlgeschlagen."
        : "Der Kurzbefehl „\(name)“ ist fehlgeschlagen: \(detail)")
    }
    guard let data = try? Data(contentsOf: outURL), !data.isEmpty else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
}

public enum ShortcutModFactory {
  /// Baut ein Manifest für einen Kurzbefehl. Die ID ist der Name als Slug; Eindeutigkeit prüft der Aufrufer.
  public static func manifest(shortcutName: String, description: String, asTool: Bool, triggers: [ModTrigger]) -> ModManifest {
    let tool: ModTool? = asTool
      ? ModTool(description: description, parameters: ["type": "object", "properties": [:]])
      : nil
    return ModManifest(id: slug(shortcutName), name: shortcutName, description: description,
                       kind: .shortcut, shortcutName: shortcutName, tool: tool,
                       triggers: triggers, permissions: [])
  }

  /// Kleinbuchstaben, Umlaute als ae/oe/ue/ss, sonst "-"; 3 bis 40 Zeichen.
  static func slug(_ text: String) -> String {
    var s = text.lowercased()
    for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
      s = s.replacingOccurrences(of: from, with: to)
    }
    s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s

    var out = ""
    for c in s.unicodeScalars {
      if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
        out.unicodeScalars.append(c)
      } else if !out.hasSuffix("-") {
        out.append("-")
      }
    }
    var base = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "mod" }
    if base.count < 3 { base = "mod-" + base }
    if base.count > 40 {
      base = String(base.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    return base
  }
}

/// Startet ein Programm mit Zeitlimit. Ausgaben gehen in Dateien (kein Pipe-Stau).
struct ModProcessResult {
  let status: Int32
  let timedOut: Bool
  let stdout: String
  let stderr: String
}

enum ModProcess {
  static func run(_ path: String, _ args: [String], timeout: TimeInterval) throws -> ModProcessResult {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("taby-proc-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let outURL = tmp.appendingPathComponent("stdout.txt")
    let errURL = tmp.appendingPathComponent("stderr.txt")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outURL)
    let errHandle = try FileHandle(forWritingTo: errURL)
    defer { try? outHandle.close(); try? errHandle.close() }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = outHandle
    p.standardError = errHandle
    do {
      try p.run()
    } catch {
      throw ModError.process("Das Hilfsprogramm „\(path)“ konnte nicht gestartet werden.")
    }

    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    var timedOut = false
    while p.isRunning {
      if DispatchTime.now().uptimeNanoseconds > deadline {
        timedOut = true
        p.terminate()
        break
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    p.waitUntilExit()

    let stdout = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
    let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
    return ModProcessResult(status: p.terminationStatus, timedOut: timedOut, stdout: stdout, stderr: stderr)
  }
}
