// Reine Logik des Notiz-Editors auf Markdown-Text: Format-Aktionen (Auswahl oder Cursor),
// Listen-Fortsetzung, Zeilenart und Hervorhebungs-Bereiche. Ohne AppKit, damit prüfbar.
// Bereiche sind UTF-16-Bereiche (NSRange), wie NSTextView sie benutzt.
import Foundation

enum NoteFormatting {
  /// Aktionen der Format-Leiste.
  enum Action: CaseIterable, Equatable {
    case heading1, heading2, bold, italic, bullet, numbered, checkbox, quote, rule, indent, outdent
  }

  /// Neuer Text und neue Auswahl.
  struct Edit: Equatable {
    let text: String
    let selection: NSRange
  }

  enum LineKind: Equatable {
    case heading(Int), bullet, numbered, checkbox(checked: Bool), quote, rule, text
  }

  /// Hervorhebung: die Zeichen bleiben Markdown, nur die Darstellung ändert sich.
  enum Style: Equatable {
    case heading(Int), bold, italic, marker, quote, listItem, rule, doneText
  }

  struct Span: Equatable {
    let range: NSRange
    let style: Style
  }

  // MARK: - Zeilenart

  /// Markierung am Zeilenanfang (Art und Länge in Zeichen, Einrückung eingeschlossen).
  private static func marker(_ line: String) -> (kind: LineKind, length: Int)? {
    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
    let body = line.dropFirst(indent)
    if body.hasPrefix("- [ ] ") { return (.checkbox(checked: false), indent + 6) }
    if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") { return (.checkbox(checked: true), indent + 6) }
    if body.hasPrefix("- ") { return (.bullet, indent + 2) }
    if line.hasPrefix("> ") { return (.quote, 2) }
    for level in 1...6 where line.hasPrefix(String(repeating: "#", count: level) + " ") {
      return (.heading(level), level + 1)
    }
    let digits = body.prefix { $0.isASCII && $0.isNumber }.count
    if digits > 0, body.dropFirst(digits).hasPrefix(". ") { return (.numbered, indent + digits + 2) }
    return nil
  }

  static func lineKind(_ line: String) -> LineKind {
    if let m = marker(line) { return m.kind }
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.count >= 3, t.allSatisfy({ $0 == "-" }) { return .rule }
    return .text
  }

  /// Zeile, in der `loc` liegt. Am Textende nach einem Zeilenumbruch ist es eine leere Zeile.
  private static func lineAt(_ ns: NSString, _ loc: Int) -> NSRange {
    if ns.length == 0 { return NSRange(location: 0, length: 0) }
    if loc >= ns.length {
      return ns.character(at: ns.length - 1) == 10
        ? NSRange(location: ns.length, length: 0)
        : ns.lineRange(for: NSRange(location: ns.length - 1, length: 0))
    }
    return ns.lineRange(for: NSRange(location: loc, length: 0))
  }

  // MARK: - Format-Aktionen

  /// Neuer Text und Auswahl für eine Format-Aktion. Auswahl leer = Cursor.
  static func edit(_ action: Action, text: String, selection: NSRange) -> Edit {
    let len = (text as NSString).length
    let loc = min(max(0, selection.location), len)
    let sel = NSRange(location: loc, length: min(max(0, selection.length), len - loc))
    switch action {
    case .bold: return emphasis("**", text, sel)
    case .italic: return emphasis("*", text, sel)
    case .rule: return rule(text, sel)
    case .indent: return shift(outdent: false, text, sel)
    case .outdent: return shift(outdent: true, text, sel)
    default: return linePrefix(action, text, sel)
    }
  }

  /// Umschalten einer Markierung um Auswahl oder Cursor: umrahmt -> entfernen, sonst setzen.
  private static func emphasis(_ mk: String, _ text: String, _ sel: NSRange) -> Edit {
    let ns = text as NSString
    let m = mk.utf16.count
    let s = sel.location, e = sel.location + sel.length
    let edge = String(mk.last!)
    func slice(_ loc: Int, _ len: Int) -> String? {
      guard loc >= 0, loc + len <= ns.length else { return nil }
      return ns.substring(with: NSRange(location: loc, length: len))
    }
    // Markierung liegt außen um die Auswahl (oder der Cursor steht zwischen zwei Markierungen)
    let outer = slice(s - m, m) == mk && slice(e, m) == mk
      && slice(s - m - 1, 1) != edge && slice(e + m, 1) != edge
    if outer {
      let inner = ns.substring(with: sel)
      let range = NSRange(location: s - m, length: sel.length + 2 * m)
      return Edit(text: ns.replacingCharacters(in: range, with: inner),
                  selection: NSRange(location: s - m, length: sel.length))
    }
    let inner = ns.substring(with: sel)
    // Markierung steht in der Auswahl selbst
    if sel.length >= 2 * m, inner.hasPrefix(mk), inner.hasSuffix(mk) {
      let core = (inner as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
      return Edit(text: ns.replacingCharacters(in: sel, with: core),
                  selection: NSRange(location: s, length: core.utf16.count))
    }
    return Edit(text: ns.replacingCharacters(in: sel, with: mk + inner + mk),
                selection: NSRange(location: s + m, length: sel.length))
  }

  /// Präfix für alle Zeilen der Auswahl umschalten; gilt die Art schon überall, wird sie entfernt.
  private static func linePrefix(_ action: Action, _ text: String, _ sel: NSRange) -> Edit {
    let ns = text as NSString
    let block = sel.length == 0 ? lineAt(ns, sel.location) : ns.lineRange(for: sel)
    let raw = ns.substring(with: block)
    let hasNL = raw.hasSuffix("\n")
    let lines = (hasNL ? String(raw.dropLast()) : raw).components(separatedBy: "\n")
    let markers = lines.map { marker($0) }
    let filled = zip(lines, markers).filter { !$0.0.isEmpty }
    let on = !filled.isEmpty && filled.allSatisfy { matches(action, $0.1?.kind) }

    var n = 0
    var newLines: [String] = []
    for (line, m) in zip(lines, markers) {
      let rest = m.map { String(line.dropFirst($0.length)) } ?? line
      if on {
        newLines.append(rest)
      } else {
        n += 1
        newLines.append(prefix(action, n) + rest)
      }
    }
    let newBlock = newLines.joined(separator: "\n") + (hasNL ? "\n" : "")
    let result = ns.replacingCharacters(in: block, with: newBlock)

    if sel.length == 0 {
      // Cursor: in derselben Zeile bleiben, Längenänderung des Präfixes mitnehmen.
      let index = ns.substring(with: NSRange(location: block.location, length: sel.location - block.location))
        .filter { $0 == "\n" }.count
      let i = min(index, lines.count - 1)
      var oldStart = block.location, newStart = block.location
      for j in 0..<i {
        oldStart += lines[j].utf16.count + 1
        newStart += newLines[j].utf16.count + 1
      }
      let delta = newLines[i].utf16.count - lines[i].utf16.count
      let offset = min(max(0, sel.location - oldStart + delta), newLines[i].utf16.count)
      return Edit(text: result, selection: NSRange(location: newStart + offset, length: 0))
    }
    let length = newBlock.utf16.count - (hasNL ? 1 : 0)
    return Edit(text: result, selection: NSRange(location: block.location, length: length))
  }

  private static func matches(_ action: Action, _ kind: LineKind?) -> Bool {
    guard let kind else { return false }
    switch (action, kind) {
    case (.heading1, .heading(1)), (.heading2, .heading(2)), (.bullet, .bullet), (.numbered, .numbered),
         (.checkbox, .checkbox), (.quote, .quote):
      return true
    default:
      return false
    }
  }

  private static func prefix(_ action: Action, _ n: Int) -> String {
    switch action {
    case .heading1: return "# "
    case .heading2: return "## "
    case .bullet: return "- "
    case .numbered: return "\(n). "
    case .checkbox: return "- [ ] "
    case .quote: return "> "
    case .bold, .italic, .rule, .indent, .outdent: return ""
    }
  }

  /// Zeilen der Auswahl (oder die Cursor-Zeile) einrücken: zwei Leerzeichen davor.
  /// Ausrücken nimmt einen Tab oder bis zu zwei Leerzeichen am Zeilenanfang weg.
  private static func shift(outdent: Bool, _ text: String, _ sel: NSRange) -> Edit {
    let ns = text as NSString
    let block = sel.length == 0 ? lineAt(ns, sel.location) : ns.lineRange(for: sel)
    let raw = ns.substring(with: block)
    let hasNL = raw.hasSuffix("\n")
    let lines = (hasNL ? String(raw.dropLast()) : raw).components(separatedBy: "\n")
    let newLines = lines.map { line -> String in
      guard outdent else { return "  " + line }
      if line.hasPrefix("\t") { return String(line.dropFirst()) }
      return String(line.dropFirst(min(2, line.prefix { $0 == " " }.count)))
    }
    let newBlock = newLines.joined(separator: "\n") + (hasNL ? "\n" : "")
    let result = ns.replacingCharacters(in: block, with: newBlock)

    if sel.length == 0 {
      // Cursor bleibt auf seinem Zeichen; die Einrückung verschiebt ihn um die Längendifferenz.
      let delta = newLines[0].utf16.count - lines[0].utf16.count
      let col = min(max(0, sel.location - block.location + delta), newLines[0].utf16.count)
      return Edit(text: result, selection: NSRange(location: block.location + col, length: 0))
    }
    return Edit(text: result, selection: NSRange(location: block.location, length: newBlock.utf16.count - (hasNL ? 1 : 0)))
  }

  /// Trennlinie als eigene Zeile hinter der aktuellen Zeile, mit Leerzeile davor (sonst wird
  /// "Text" + "---" zur Überschrift). Auf leerer Zeile steht die Linie direkt dort.
  private static func rule(_ text: String, _ sel: NSRange) -> Edit {
    let ns = text as NSString
    let line = lineAt(ns, sel.location)
    let raw = ns.substring(with: line)
    let body = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    if body.trimmingCharacters(in: .whitespaces).isEmpty {
      var prevFilled = false
      if line.location > 0 {
        let prev = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
        prevFilled = !ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      let insertion = (prevFilled ? "\n" : "") + "---"
      return Edit(text: ns.replacingCharacters(in: NSRange(location: line.location, length: 0), with: insertion),
                  selection: NSRange(location: line.location + insertion.utf16.count, length: 0))
    }
    let contentEnd = line.location + body.utf16.count
    let insertion = "\n\n---"
    return Edit(text: ns.replacingCharacters(in: NSRange(location: contentEnd, length: 0), with: insertion),
                selection: NSRange(location: contentEnd + insertion.utf16.count, length: 0))
  }

  // MARK: - Listen-Fortsetzung

  /// Return in einer Liste: nächste Markierung setzen; auf leerer Listenzeile die Liste beenden.
  /// Nil = keine Liste (Return normal einfügen) oder mit Auswahl.
  static func continueList(_ text: String, selection: NSRange) -> Edit? {
    guard selection.length == 0 else { return nil }
    let ns = text as NSString
    let line = lineAt(ns, selection.location)
    let raw = ns.substring(with: line)
    let content = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    guard let m = marker(content) else { return nil }
    let prefix = String(content.prefix(m.length))
    let next: String
    switch m.kind {
    case .checkbox: next = "- [ ] "
    case .bullet: next = "- "
    case .numbered: next = "\((Int(prefix.filter { $0.isNumber }) ?? 0) + 1). "
    default: return nil
    }
    guard selection.location >= line.location + m.length else { return nil }
    if String(content.dropFirst(m.length)).trimmingCharacters(in: .whitespaces).isEmpty {
      // leere Listenzeile: Markierung und Einrückung weg, Liste endet
      let range = NSRange(location: line.location, length: content.utf16.count)
      return Edit(text: ns.replacingCharacters(in: range, with: ""),
                  selection: NSRange(location: line.location, length: 0))
    }
    let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
    let insertion = "\n" + indent + next
    return Edit(text: ns.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: insertion),
                selection: NSRange(location: selection.location + insertion.utf16.count, length: 0))
  }

  // MARK: - Zähler und Speicherstand

  /// Wörter (durch Leerraum getrennt) und Zeichen des Textes, für den dezenten Zähler im Editor.
  static func stats(_ text: String) -> (words: Int, chars: Int) {
    (text.split(whereSeparator: \.isWhitespace).count, text.count)
  }

  /// Kurze Zeile zum Speicherstand unter dem Editor.
  static func saveLabel(dirty: Bool) -> String { dirty ? "Ungesicherte Änderungen" : "Alles gesichert" }

  // MARK: - Hervorhebung

  /// Bereiche für die Darstellung: Zeilenart, Markierungen (gedimmt), fett und kursiv.
  static func spans(_ text: String) -> [Span] {
    var out: [Span] = []
    var offset = 0
    for line in text.components(separatedBy: "\n") {
      out += lineSpans(line, base: offset)
      offset += line.utf16.count + 1
    }
    return out
  }

  private static func lineSpans(_ line: String, base: Int) -> [Span] {
    let full = NSRange(location: base, length: line.utf16.count)
    let mk = marker(line)
    let markerRange = NSRange(location: base, length: mk?.length ?? 0)
    var out: [Span] = []
    switch lineKind(line) {
    case .heading(let level):
      out.append(Span(range: full, style: .heading(level)))
      out.append(Span(range: markerRange, style: .marker))
    case .bullet, .numbered:
      out.append(Span(range: full, style: .listItem))
      out.append(Span(range: markerRange, style: .marker))
    case .checkbox(let checked):
      out.append(Span(range: full, style: .listItem))
      out.append(Span(range: markerRange, style: .marker))
      if checked {
        out.append(Span(range: NSRange(location: base + markerRange.length, length: full.length - markerRange.length),
                        style: .doneText))
      }
    case .quote:
      out.append(Span(range: full, style: .quote))
      out.append(Span(range: markerRange, style: .marker))
    case .rule:
      out.append(Span(range: full, style: .rule))
    case .text:
      break
    }
    out += emphasisSpans(line, base: base)
    return out
  }

  // shortcut: ein Muster je Art, kompiliert einmal statt pro Zeile und Tastendruck
  private static let boldPattern = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
  private static let italicPattern = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?=[^\\s*])([^*]+?)(?<=[^\\s*])\\*(?!\\*)")

  private static func emphasisSpans(_ line: String, base: Int) -> [Span] {
    let whole = NSRange(location: 0, length: line.utf16.count)
    var out: [Span] = []
    for m in boldPattern.matches(in: line, range: whole) {
      let inner = m.range(at: 1)
      out.append(Span(range: NSRange(location: base + m.range.location, length: 2), style: .marker))
      out.append(Span(range: NSRange(location: base + m.range.location + m.range.length - 2, length: 2), style: .marker))
      out.append(Span(range: NSRange(location: base + inner.location, length: inner.length), style: .bold))
    }
    for m in italicPattern.matches(in: line, range: whole) {
      let inner = m.range(at: 1)
      out.append(Span(range: NSRange(location: base + m.range.location, length: 1), style: .marker))
      out.append(Span(range: NSRange(location: base + m.range.location + m.range.length - 1, length: 1), style: .marker))
      out.append(Span(range: NSRange(location: base + inner.location, length: inner.length), style: .italic))
    }
    return out
  }
}
