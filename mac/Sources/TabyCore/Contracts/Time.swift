// VERTRAG (nur Orchestrator ändert). Port von src/shared/time.ts.
//
// Zeit: lokale, zonenlose ISO-Strings.
// "YYYY-MM-DDTHH:mm" (mit Uhrzeit) oder "YYYY-MM-DD" (ganztägig).
// Nie `Date()` direkt in Logik verwenden — immer `Clock` injizieren.
import Foundation

public protocol Clock: AnyObject {
  func now() -> Date
}

public final class SystemClock: Clock {
  public init() {}
  public func now() -> Date { Date() }
}

/// Steuerbare Uhr für Prüfungen und den Testmodus.
public final class ControllableClock: Clock {
  private var current: Date
  private let lock = NSLock()

  public init(_ start: Date) { current = start }

  /// Startzeit als lokaler ISO-String; ungültig → Absturz (nur Tests/Testmodus).
  public convenience init(_ iso: String) {
    guard let d = LocalTime.parse(iso) else { preconditionFailure("ungültige Zeit: \(iso)") }
    self.init(d)
  }

  public func now() -> Date {
    lock.lock(); defer { lock.unlock() }
    return current
  }

  public func set(_ date: Date) {
    lock.lock(); current = date; lock.unlock()
  }

  public func advance(seconds: TimeInterval) {
    lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
  }
}

public enum LocalTime {
  /// Kalender in der lokalen Zeitzone des Systems.
  public static var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    c.locale = Locale(identifier: "de_DE")
    return c
  }

  /// Formatierer werden einmal gebaut (DateFormatter ist teuer und seit macOS 10.9 threadsicher);
  /// `parse`/`format` laufen bis zu 60-mal pro Sekunde im Notch-Takt.
  private static let formatters: [String: DateFormatter] = {
    var out: [String: DateFormatter] = [:]
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "HH:mm"] {
      let f = DateFormatter()
      f.calendar = Calendar(identifier: .gregorian)
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = .current
      f.dateFormat = format
      out[format] = f
    }
    return out
  }()

  private static func formatter(_ format: String) -> DateFormatter {
    if let f = formatters[format] { return f }
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = format
    return f
  }

  /// "YYYY-MM-DDTHH:mm"
  public static func format(_ date: Date) -> String {
    formatter("yyyy-MM-dd'T'HH:mm").string(from: date)
  }

  /// "YYYY-MM-DD"
  public static func formatDate(_ date: Date) -> String {
    formatter("yyyy-MM-dd").string(from: date)
  }

  /// "HH:mm"
  public static func formatTime(_ date: Date) -> String {
    formatter("HH:mm").string(from: date)
  }

  /// Akzeptiert "YYYY-MM-DD", "YYYY-MM-DDTHH:mm" und "YYYY-MM-DDTHH:mm:ss".
  public static func parse(_ s: String) -> Date? {
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
      if let d = formatter(fmt).date(from: s) { return d }
    }
    return nil
  }

  /// true für reine Datumsangaben ("YYYY-MM-DD", ganztägig).
  public static func isDateOnly(_ s: String) -> Bool {
    s.count == 10 && !s.contains("T")
  }

  /// Datumsteil eines lokalen ISO-Strings.
  public static func datePart(_ s: String) -> String {
    String(s.prefix(10))
  }
}
