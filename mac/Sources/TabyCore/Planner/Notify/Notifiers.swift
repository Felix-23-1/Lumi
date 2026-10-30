// Weitere Notifier: Datei-Senke für den Testmodus (wie TS `FileSinkNotifier`,
// Test-Hook ASSISTENT_NOTIFY_SINK), Konsole und Verteiler auf mehrere Ziele.
import Foundation

/// Schreibt jede Benachrichtigung als JSON-Zeile (`{"body":…,"title":…}`) in eine Datei,
/// damit End-to-End-Prüfungen sie ohne echte Systembenachrichtigung beobachten können.
public final class FileSinkNotifier: Notifier {
  public let url: URL
  private let lock = NSLock()
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }()

  public init(url: URL) {
    self.url = url
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }

  public convenience init(path: String) {
    self.init(url: URL(fileURLWithPath: path))
  }

  public func send(_ n: TabyNotification) {
    guard var line = try? encoder.encode(n) else { return }
    line.append(0x0A)
    lock.lock(); defer { lock.unlock() }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else {
      try? line.write(to: url)
    }
  }

  /// Liest alle Zeilen zurück (Prüfungen/Testmodus).
  public static func read(_ url: URL) -> [TabyNotification] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(TabyNotification.self, from: Data($0.utf8)) }
  }
}

/// Schreibt nur ins Protokoll (stderr).
public final class ConsoleNotifier: Notifier {
  public init() {}
  public func send(_ n: TabyNotification) {
    FileHandle.standardError.write(Data("[notify] \(n.title): \(n.body)\n".utf8))
  }
}

/// Verteilt auf mehrere Notifier (z. B. System + Aufpoppen der Notch-Insel).
public final class FanOutNotifier: Notifier {
  private let targets: [Notifier]
  public init(_ targets: [Notifier]) { self.targets = targets }
  public func send(_ n: TabyNotification) {
    for t in targets { t.send(n) }
  }
}

/// Ruft eine Funktion auf (z. B. `AppEvent.flash` an die Oberfläche).
public final class ClosureNotifier: Notifier {
  private let handler: (TabyNotification) -> Void
  public init(_ handler: @escaping (TabyNotification) -> Void) { self.handler = handler }
  public func send(_ n: TabyNotification) { handler(n) }
}
