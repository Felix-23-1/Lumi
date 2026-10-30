// Text aus Mails: Kopfzeilen nach RFC 2047 (=?UTF-8?B?…?=), Transfer-Codierung
// (quoted-printable, base64), Zeichensätze und MIME-Teile. Kein Netz, keine Logs.
import Foundation

enum MailText {
  // MARK: Zeichensätze

  static func decodeBytes(_ d: Data, charset: String?) -> String {
    let cs = (charset ?? "utf-8").lowercased()
    if cs.contains("8859") || cs.contains("latin") {
      return String(data: d, encoding: .isoLatin1) ?? ""
    }
    if cs.contains("1252") {
      return String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1) ?? ""
    }
    return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
  }

  // MARK: Kopfzeilen (RFC 2047)

  /// Ersetzt alle `=?charset?B|Q?text?=`-Wörter. Leerraum zwischen zwei Wörtern entfällt.
  static func decodeWords(_ s: String) -> String {
    guard s.contains("=?"),
          let re = try? NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=")
    else { return s }
    let ns = s as NSString
    var out = ""
    var last = 0
    for (index, m) in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).enumerated() {
      let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
      let adjacent = index > 0 && between.allSatisfy { $0.isWhitespace }
      if !adjacent { out += between }
      let charset = ns.substring(with: m.range(at: 1))
      let encoding = ns.substring(with: m.range(at: 2)).uppercased()
      let text = ns.substring(with: m.range(at: 3))
      let bytes: Data? = encoding == "B"
        ? Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        : qDecode(text)
      if let bytes {
        out += decodeBytes(bytes, charset: charset.components(separatedBy: "*").first)
      } else {
        out += ns.substring(with: m.range)
      }
      last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
  }

  /// Q-Codierung für Kopfzeilen: `_` ist Leerzeichen, `=XX` ist ein Byte.
  static func qDecode(_ s: String) -> Data {
    let b = Array(s.utf8)
    var out = Data()
    var i = 0
    while i < b.count {
      if b[i] == UInt8(ascii: "_") {
        out.append(0x20); i += 1
      } else if b[i] == UInt8(ascii: "="), i + 2 < b.count, let v = hexByte(b[i + 1], b[i + 2]) {
        out.append(v); i += 3
      } else {
        out.append(b[i]); i += 1
      }
    }
    return out
  }

  // MARK: Transfer-Codierung

  static func decodeTransfer(_ d: Data, encoding: String) -> Data {
    switch encoding.lowercased() {
    case "base64":
      let text = String(decoding: d, as: UTF8.self).filter { !$0.isWhitespace }
      return Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? d
    case "quoted-printable":
      return quotedPrintable(d)
    default:
      return d
    }
  }

  static func quotedPrintable(_ d: Data) -> Data {
    let b = [UInt8](d)
    var out = [UInt8]()
    out.reserveCapacity(b.count)
    var i = 0
    while i < b.count {
      guard b[i] == UInt8(ascii: "=") else { out.append(b[i]); i += 1; continue }
      if i + 1 < b.count, b[i + 1] == 0x0D || b[i + 1] == 0x0A {
        // Weicher Zeilenumbruch: "=" am Zeilenende.
        i += 2
        if b[i - 1] == 0x0D, i < b.count, b[i] == 0x0A { i += 1 }
        continue
      }
      if i + 2 < b.count, let v = hexByte(b[i + 1], b[i + 2]) {
        out.append(v); i += 3
      } else {
        out.append(b[i]); i += 1
      }
    }
    return Data(out)
  }

  private static func hexByte(_ a: UInt8, _ b: UInt8) -> UInt8? {
    UInt8(String(decoding: [a, b], as: UTF8.self), radix: 16)
  }

  // MARK: MIME

  /// Trennt Kopf und Körper an der ersten Leerzeile.
  static func splitMessage(_ raw: Data) -> (headers: String, body: Data) {
    if let r = raw.range(of: Data("\r\n\r\n".utf8)) {
      return (String(decoding: raw[..<r.lowerBound], as: UTF8.self), Data(raw[r.upperBound...]))
    }
    if let r = raw.range(of: Data("\n\n".utf8)) {
      return (String(decoding: raw[..<r.lowerBound], as: UTF8.self), Data(raw[r.upperBound...]))
    }
    return (String(decoding: raw, as: UTF8.self), Data())
  }

  /// Kopfzeilen mit Schlüsseln in Kleinbuchstaben; Fortsetzungszeilen werden angehängt.
  static func parseHeaders(_ block: String) -> [String: String] {
    var result: [String: String] = [:]
    var currentKey: String?
    for line in block.components(separatedBy: "\n") {
      let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
      if let first = l.first, first == " " || first == "\t", let key = currentKey {
        result[key, default: ""] += " " + l.trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let colon = l.firstIndex(of: ":") else { currentKey = nil; continue }
      let key = l[..<colon].lowercased()
      result[key] = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      currentKey = key
    }
    return result
  }

  /// `text/plain; charset="utf-8"` → ("text/plain", ["charset": "utf-8"]).
  static func contentType(_ value: String) -> (type: String, params: [String: String]) {
    let parts = value.components(separatedBy: ";")
    let type = (parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
      guard let eq = p.firstIndex(of: "=") else { continue }
      let k = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
      var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
      params[k] = v
    }
    return (type, params)
  }

  /// Sucht den ersten text/plain-Teil (sonst text/html, als Text gekürzt) einer Mail.
  static func plainText(message raw: Data) -> String {
    let texts = textParts(raw, depth: 0)
    if let plain = texts.plain { return plain }
    if let html = texts.html { return stripHTML(html) }
    return ""
  }

  private static func textParts(_ raw: Data, depth: Int) -> (plain: String?, html: String?) {
    let (headerBlock, body) = splitMessage(raw)
    let headers = parseHeaders(headerBlock)
    let ct = contentType(headers["content-type"] ?? "text/plain")
    if ct.type.hasPrefix("multipart/"), let boundary = ct.params["boundary"], depth < 5 {
      var plain: String?
      var html: String?
      for part in splitMultipart(body, boundary: boundary) {
        let found = textParts(part, depth: depth + 1)
        plain = plain ?? found.plain
        html = html ?? found.html
      }
      return (plain, html)
    }
    guard ct.type == "text/plain" || ct.type == "text/html" || ct.type.isEmpty else { return (nil, nil) }
    let decoded = decodeTransfer(body, encoding: headers["content-transfer-encoding"] ?? "")
    let text = decodeBytes(decoded, charset: ct.params["charset"])
    return ct.type == "text/html" ? (nil, text) : (text, nil)
  }

  static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
    let delim = Data("--\(boundary)".utf8)
    var marks: [Range<Data.Index>] = []
    var from = body.startIndex
    while from < body.endIndex, let r = body.range(of: delim, in: from..<body.endIndex) {
      marks.append(r)
      from = r.upperBound
    }
    guard marks.count >= 2 else { return [] }
    var parts: [Data] = []
    for k in 0..<(marks.count - 1) {
      var start = marks[k].upperBound
      var end = marks[k + 1].lowerBound
      if start < end, body[start] == 0x0D { start += 1 }
      if start < end, body[start] == 0x0A { start += 1 }
      if end > start, body[end - 1] == 0x0A { end -= 1 }
      if end > start, body[end - 1] == 0x0D { end -= 1 }
      parts.append(Data(body[start..<end]))
    }
    return parts
  }

  // MARK: HTML

  /// Sehr einfache Umwandlung in Text: Skripte und Tags raus, Zeilenumbrüche für Blockelemente.
  static func stripHTML(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                      options: .regularExpression)
    s = s.replacingOccurrences(of: "(?i)<br[^>]*>|</(p|div|tr|li|h[1-6])>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    s = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
