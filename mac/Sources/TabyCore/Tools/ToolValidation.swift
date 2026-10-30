// Strenge Argumentvalidierung für Werkzeuge (Port von src/main/tools/validate.ts).
// Wirft `ToolValidationError`, die der Dispatcher auf
// { ok:false, code:"INVALID_ARGS" } abbildet. Nur Formprüfung der Zeiten.
import Foundation

public struct ToolValidationError: Error, Equatable, CustomStringConvertible, LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}

private func matches(_ s: String, _ pattern: String) -> Bool {
  s.range(of: pattern, options: .regularExpression) != nil
}

private let localDateOrDateTime = #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$"#
private let dateOnlyPattern = #"^\d{4}-\d{2}-\d{2}$"#
private let timeHHmm = #"^\d{2}:\d{2}$"#

/// Tage je Monat (Schaltjahr über `leap`).
private func daysIn(month: Int, year: Int) -> Int {
  let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
}

/// Form und Werte: Monat 1–12, Tag im Monat, Stunde 0–23, Minute 0–59; danach das Datum über `LocalTime.parse`.
private func validLocalDate(_ s: String, time: Bool) -> Bool {
  let parts = s.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
  guard parts.count == (time ? 5 : 3), (1...12).contains(parts[1]),
        (1...daysIn(month: parts[1], year: parts[0])).contains(parts[2]) else { return false }
  if time, !((0...23).contains(parts[3]) && (0...59).contains(parts[4])) { return false }
  return LocalTime.parse(s) != nil
}

private func validLocalDateTime(_ s: String) -> Bool {
  matches(s, localDateOrDateTime) && validLocalDate(s, time: s.contains("T"))
}

private func validDateOnly(_ s: String) -> Bool {
  matches(s, dateOnlyPattern) && validLocalDate(s, time: false)
}

private func validClock(_ s: String) -> Bool {
  guard matches(s, timeHHmm) else { return false }
  let parts = s.split(separator: ":").compactMap { Int($0) }
  return parts.count == 2 && (0...23).contains(parts[0]) && (0...59).contains(parts[1])
}

/// Werkzeug-Argumente als JSON-Objekt mit typisierten Zugriffen.
public struct ToolArgs: Equatable, Sendable {
  public let raw: [String: JSONValue]

  public init(_ raw: [String: JSONValue]) { self.raw = raw }

  /// Argumente müssen ein Objekt sein (kein Array, kein null, kein Primitiv).
  public static func from(_ value: JSONValue) throws -> ToolArgs {
    guard case .object(let o) = value else { throw ToolValidationError("Argumente müssen ein Objekt sein") }
    return ToolArgs(o)
  }

  /// Schlüssel vorhanden (auch mit null) – wie `key in args` in TS.
  public func has(_ key: String) -> Bool { raw[key] != nil }

  private func present(_ key: String) -> JSONValue? {
    guard let v = raw[key], v != .null else { return nil }
    return v
  }

  public func requireString(_ key: String) throws -> String {
    guard case .string(let s)? = raw[key], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ToolValidationError("\"\(key)\" fehlt oder ist leer")
    }
    return s
  }

  public func optionalString(_ key: String) throws -> String? {
    guard let v = present(key) else { return nil }
    guard case .string(let s) = v else { throw ToolValidationError("\"\(key)\" muss Text sein") }
    return s
  }

  public func optionalBool(_ key: String) throws -> Bool? {
    guard let v = present(key) else { return nil }
    guard case .bool(let b) = v else { throw ToolValidationError("\"\(key)\" muss ein Wahrheitswert sein") }
    return b
  }

  public func requireLocalDateTime(_ key: String) throws -> String {
    let v = try requireString(key)
    guard validLocalDateTime(v) else {
      throw ToolValidationError("\"\(key)\" muss \"JJJJ-MM-TT\" oder \"JJJJ-MM-TTTHH:mm\" sein")
    }
    return v
  }

  public func optionalLocalDateTime(_ key: String) throws -> String? {
    guard let v = try optionalString(key) else { return nil }
    guard validLocalDateTime(v) else {
      throw ToolValidationError("\"\(key)\" muss \"JJJJ-MM-TT\" oder \"JJJJ-MM-TTTHH:mm\" sein")
    }
    return v
  }

  public func requireDateOnly(_ key: String) throws -> String {
    let v = try requireString(key)
    guard validDateOnly(v) else { throw ToolValidationError("\"\(key)\" muss ein Datum \"JJJJ-MM-TT\" sein") }
    return v
  }

  public func optionalDateOnly(_ key: String) throws -> String? {
    guard let v = try optionalString(key) else { return nil }
    guard validDateOnly(v) else { throw ToolValidationError("\"\(key)\" muss ein Datum \"JJJJ-MM-TT\" sein") }
    return v
  }

  public func requireId(_ key: String = "id") throws -> String {
    try requireString(key)
  }

  private func requireTime(_ key: String) throws -> String {
    guard case .string(let s)? = raw[key], validClock(s) else {
      throw ToolValidationError("\"\(key)\" muss \"HH:mm\" sein")
    }
    return s
  }

  /// Wochentage 1–7 (Montag = 1 … Sonntag = 7, ISO), wie im TS-Original.
  private func requireWeekdays(_ key: String) throws -> [Int] {
    let err = ToolValidationError("\"\(key)\" muss eine Liste von Wochentagen (1-7) sein")
    guard case .array(let a)? = raw[key], !a.isEmpty else { throw err }
    return try a.map { v in
      guard case .number(let n) = v, n.rounded() == n, n >= 1, n <= 7 else { throw err }
      return Int(n)
    }
  }

  /// Validiert die JobRule-Union ({type:"daily"|"weekly"|"once", …}).
  public func jobRule(_ key: String = "rule") throws -> JobRule {
    guard case .object(let o)? = raw[key] else { throw ToolValidationError("\"\(key)\" muss ein Objekt sein") }
    let rule = ToolArgs(o)
    switch o["type"]?.stringValue {
    case "daily": return .daily(time: try rule.requireTime("time"))
    case "weekly": return .weekly(days: try rule.requireWeekdays("days"), time: try rule.requireTime("time"))
    case "once": return .once(at: try rule.requireLocalDateTime("at"))
    default: throw ToolValidationError("\"\(key).type\" muss \"daily\", \"weekly\" oder \"once\" sein")
    }
  }
}
