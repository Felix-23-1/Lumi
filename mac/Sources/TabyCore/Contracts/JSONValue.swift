// VERTRAG (nur Orchestrator ändert).
// Beliebiger JSON-Wert: für Kalenderquellen-Konfiguration, Werkzeug-
// Argumente/-Ergebnisse, JSON-Schemata der Werkzeuge und Hook-Eingaben.
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n):
      if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
  public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
  public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
  public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

  /// Kompakte JSON-Zeichenkette (sortierte Schlüssel, deterministisch).
  public func jsonString() -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  public static func parse(_ s: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral v: String) { self = .string(v) }
  public init(booleanLiteral v: Bool) { self = .bool(v) }
  public init(integerLiteral v: Int) { self = .number(Double(v)) }
  public init(floatLiteral v: Double) { self = .number(v) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(nilLiteral: ()) { self = .null }
}
