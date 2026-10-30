// Protokoll: os.Logger je Bereich plus Ringpuffer der letzten Zeilen (nur im Speicher).
// Schreibt nie auf die Platte; gelesen wird der Puffer nur beim Diagnose-Export.
// Nur kurze Ereignisse loggen – nie Schlüssel, Tokens, Texte von Mails/Nachrichten/Notizen,
// Dateinamen oder Kontaktdaten. Fehler nur als Code (`TabyLog.code`), nie als Beschreibung.
import Foundation
import os

public enum LogCategory: String, CaseIterable, Sendable {
  case core, model, calendar, messenger, mail, mods, notion, update
}

public enum LogLevel: String, Sendable {
  case info, error
}

/// Begrenzter Ringpuffer; die ältesten Zeilen fallen heraus. Ein Schloss, kein Hintergrund-Takt.
public final class TabyLogBuffer: @unchecked Sendable {
  public let capacity: Int
  private let clock: Clock
  private let lock = NSLock()
  private var lines: [String] = []
  /// Schreibposition, sobald der Puffer voll ist (dort steht die älteste Zeile).
  private var next = 0

  public init(capacity: Int = 2000, clock: Clock = SystemClock()) {
    self.capacity = max(1, capacity)
    self.clock = clock
  }

  public func append(_ category: LogCategory, _ level: LogLevel, _ message: String) {
    let text = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    let line = "\(LocalTime.format(clock.now())) \(level.rawValue) [\(category.rawValue)] \(text.prefix(400))"
    lock.lock(); defer { lock.unlock() }
    if lines.count < capacity {
      lines.append(line)
    } else {
      lines[next] = line
      next = (next + 1) % capacity
    }
  }

  /// Zeilen, älteste zuerst.
  public func snapshot() -> [String] {
    lock.lock(); defer { lock.unlock() }
    guard lines.count == capacity else { return lines }
    return Array(lines[next...] + lines[..<next])
  }

  public var count: Int {
    lock.lock(); defer { lock.unlock() }
    return lines.count
  }
}

public enum TabyLog {
  public static let buffer = TabyLogBuffer()
  private static let subsystem = Bundle.main.bundleIdentifier ?? "de.taby.app"
  private static let loggers: [LogCategory: Logger] = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
    ($0, Logger(subsystem: subsystem, category: $0.rawValue))
  })

  public static func info(_ category: LogCategory, _ message: String) {
    emit(category, .info, message)
  }

  public static func error(_ category: LogCategory, _ message: String) {
    emit(category, .error, message)
  }

  private static func emit(_ category: LogCategory, _ level: LogLevel, _ message: String) {
    buffer.append(category, level, message)
    guard let logger = loggers[category] else { return }
    switch level {
    case .info: logger.info("\(message, privacy: .public)")
    case .error: logger.error("\(message, privacy: .public)")
    }
  }

  /// Nur Domäne und Nummer eines Fehlers – die Beschreibung kann Pfade oder Inhalte enthalten.
  public static func code(_ error: Error) -> String {
    let e = error as NSError
    return "\(e.domain) \(e.code)"
  }
}
