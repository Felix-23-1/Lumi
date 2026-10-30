// Minimaler IMAP-Antwortparser (RFC 3501): Atome, Zahlen, NIL, Quoted Strings,
// Literale {n} und Listen. Ein Stück Protokoll, keine Vollständigkeit.
import Foundation

/// Ein Wert einer IMAP-Antwort.
indirect enum IMAPValue: Equatable {
  /// Atom, Zahl oder Antwortschlüssel wie `BODY[HEADER]` (Klammerinhalt bleibt im Atom).
  case atom(String)
  /// Quoted String oder Literal: rohe Bytes.
  case text(Data)
  case nilValue
  case list([IMAPValue])

  var string: String? {
    switch self {
    case .atom(let s): return s
    case .text(let d): return MailText.decodeBytes(d, charset: nil)
    default: return nil
    }
  }

  var data: Data? {
    if case .text(let d) = self { return d }
    return nil
  }

  var list: [IMAPValue]? {
    if case .list(let items) = self { return items }
    return nil
  }

  /// Text oder nil (NIL zählt als fehlend).
  var optionalString: String? {
    if case .nilValue = self { return nil }
    return string
  }
}

/// Eine Zeile der Antwort: `*` (ungetaggt) oder ein Befehls-Tag, danach die Werte.
struct IMAPResponse {
  let tag: String?
  let items: [IMAPValue]

  /// Schlüsselwort in Großbuchstaben: "OK", "SEARCH", "LIST", bei `* 5 FETCH` also "FETCH".
  var keyword: String? {
    guard let first = items.first?.string else { return nil }
    if number != nil, items.count >= 2 { return items[1].string?.uppercased() }
    return first.uppercased()
  }

  /// Für `* n KEYWORD …`: die Zahl vor dem Schlüsselwort.
  var number: Int? {
    guard let n = items.first?.string, let v = Int(n) else { return nil }
    return v
  }
}

enum IMAPParseError: Error, Equatable {
  /// Antwort ist noch nicht vollständig; weiterlesen.
  case incomplete
  case malformed
  /// Literal größer als `IMAPParser.maxLiteral`.
  case tooLarge
}

/// Parst einen Puffer in Antwortzeilen. Wirft `.incomplete`, wenn Daten fehlen.
struct IMAPParser {
  private let b: [UInt8]
  private var i = 0

  /// Obergrenze für ein Literal (eine Mail-Quelle mit Anhängen bleibt darunter).
  static let maxLiteral = 10 * 1024 * 1024

  private init(_ data: Data) { b = [UInt8](data) }

  static func responses(_ data: Data) throws -> [IMAPResponse] {
    var p = IMAPParser(data)
    var out: [IMAPResponse] = []
    while true {
      p.skipSpaces()
      if p.i >= p.b.count { break }
      if p.b[p.i] == 0x0D || p.b[p.i] == 0x0A { p.i += 1; continue }
      let first = try p.value()
      guard let tag = first.string else { throw IMAPParseError.malformed }
      var items: [IMAPValue] = []
      while true {
        p.skipSpaces()
        guard p.i < p.b.count else { throw IMAPParseError.incomplete }
        if p.b[p.i] == 0x0D {
          guard p.i + 1 < p.b.count else { throw IMAPParseError.incomplete }
          guard p.b[p.i + 1] == 0x0A else { throw IMAPParseError.malformed }
          p.i += 2
          break
        }
        if p.b[p.i] == 0x0A { p.i += 1; break }
        items.append(try p.value())
      }
      out.append(IMAPResponse(tag: tag == "*" ? nil : tag, items: items))
    }
    return out
  }

  private mutating func skipSpaces() {
    while i < b.count, b[i] == 0x20 { i += 1 }
  }

  private mutating func value() throws -> IMAPValue {
    skipSpaces()
    guard i < b.count else { throw IMAPParseError.incomplete }
    switch b[i] {
    case UInt8(ascii: "("):
      i += 1
      var items: [IMAPValue] = []
      while true {
        skipSpaces()
        guard i < b.count else { throw IMAPParseError.incomplete }
        if b[i] == UInt8(ascii: ")") { i += 1; return .list(items) }
        items.append(try value())
      }
    case UInt8(ascii: "\""):
      return .text(try quoted())
    case UInt8(ascii: "{"):
      return .text(try literal())
    default:
      let atom = try atomText()
      if atom.uppercased() == "NIL" { return .nilValue }
      return .atom(atom)
    }
  }

  private mutating func quoted() throws -> Data {
    i += 1
    var out = Data()
    while true {
      guard i < b.count else { throw IMAPParseError.incomplete }
      let c = b[i]
      if c == UInt8(ascii: "\\") {
        guard i + 1 < b.count else { throw IMAPParseError.incomplete }
        out.append(b[i + 1]); i += 2; continue
      }
      if c == UInt8(ascii: "\"") { i += 1; return out }
      if c == 0x0D || c == 0x0A { throw IMAPParseError.malformed }
      out.append(c); i += 1
    }
  }

  private mutating func literal() throws -> Data {
    i += 1
    var digits = ""
    while true {
      guard i < b.count else { throw IMAPParseError.incomplete }
      if b[i] == UInt8(ascii: "}") { break }
      guard b[i] >= 0x30, b[i] <= 0x39 else { throw IMAPParseError.malformed }
      digits.append(Character(UnicodeScalar(b[i])))
      i += 1
    }
    i += 1
    guard let n = Int(digits) else { throw IMAPParseError.malformed }
    guard n <= Self.maxLiteral else { throw IMAPParseError.tooLarge }
    guard i + 1 < b.count else { throw IMAPParseError.incomplete }
    guard b[i] == 0x0D, b[i + 1] == 0x0A else { throw IMAPParseError.malformed }
    i += 2
    guard n <= b.count - i else { throw IMAPParseError.incomplete }
    let out = Data(b[i..<(i + n)])
    i += n
    return out
  }

  /// Atom bis Leerzeichen, Klammer, Zeilenende oder Anführungszeichen. Ein `[…]`-Abschnitt
  /// (etwa `BODY[HEADER.FIELDS (X-Y)]`) gehört mit zum Atom, auch mit Leerzeichen darin.
  private mutating func atomText() throws -> String {
    let start = i
    while i < b.count {
      let c = b[i]
      if c == UInt8(ascii: "[") {
        while i < b.count, b[i] != UInt8(ascii: "]") { i += 1 }
        guard i < b.count else { throw IMAPParseError.incomplete }
        i += 1
        continue
      }
      if c == 0x20 || c == 0x0D || c == 0x0A || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")
        || c == UInt8(ascii: "\"") { break }
      i += 1
    }
    guard i > start else { throw IMAPParseError.malformed }
    return String(decoding: b[start..<i], as: UTF8.self)
  }
}

extension IMAPParser {
  /// Schlüssel-Wert-Paare eines FETCH-Eintrags `* 5 FETCH (UID 10 FLAGS (\Seen) …)`, Schlüssel in Großbuchstaben.
  static func pairs(_ r: IMAPResponse) -> [String: IMAPValue]? {
    guard let list = r.items.last?.list else { return nil }
    var out: [String: IMAPValue] = [:]
    var k = 0
    while k + 1 < list.count {
      if let key = list[k].string?.uppercased() { out[key] = list[k + 1] }
      k += 2
    }
    return out
  }
}
