// Darstellung des Notion-Seiteninhalts nach dem Textformat `NotionBodyFormat`
// (Überschriften, Aufzählungen, nummerierte Zeilen, To-dos, Zitate, Trenner …).
// To-do-Häkchen werden über `checkTask` einer Aufgabe zugeordnet; ohne Zuordnung
// bleiben sie nur Anzeige.
import SwiftUI
import TabyCore

struct NotionBodyView: View {
  /// Eine klassifizierte Zeile des Inhalts.
  struct Line: Equatable {
    enum Kind: Equatable { case heading, bullet, numbered, todo, quote, divider, subpage, toggle, text, blank }
    var kind: Kind
    /// Verschachtelungsebene (je zwei Leerzeichen Einzug).
    var level: Int = 0
    var text: String = ""
    /// Nur `.todo`: laut Notion-Text abgehakt (`☑`).
    var checked = false
    /// Nur `.numbered`: die Nummer mit Punkt, z. B. „2.“.
    var number = ""
  }

  let text: String
  /// n-te To-do-Zeile (0-basiert) und ihr Text → passende Aufgabe; nil = nur Anzeige.
  let checkTask: (Int, String) -> TabyTask?
  let onToggle: (TabyTask) -> Void
  /// Aufgaben, die gerade abgehakt werden (zeigen sofort „erledigt“).
  var completing: Set<String> = []

  init(text: String, checkTask: @escaping (Int, String) -> TabyTask? = { _, _ in nil },
       onToggle: @escaping (TabyTask) -> Void = { _ in }, completing: Set<String> = []) {
    self.text = text
    self.checkTask = checkTask
    self.onToggle = onToggle
    self.completing = completing
  }

  // MARK: - Reine Logik (testbar)

  static func lines(_ text: String) -> [Line] {
    text.components(separatedBy: "\n").map(line)
  }

  /// Texte der To-do-Zeilen in Reihenfolge (Grundlage der Zuordnung zu Aufgaben).
  static func todoTexts(_ text: String) -> [String] {
    lines(text).filter { $0.kind == .todo }.map(\.text)
  }

  static func line(_ raw: String) -> Line {
    var rest = Substring(raw)
    var level = 0
    while rest.hasPrefix(NotionBodyFormat.indent) {
      rest = rest.dropFirst(NotionBodyFormat.indent.count)
      level += 1
    }
    let s = String(rest)
    if s.trimmingCharacters(in: .whitespaces).isEmpty { return Line(kind: .blank, level: level) }
    if s.trimmingCharacters(in: .whitespaces) == "—" { return Line(kind: .divider, level: level) }
    func after(_ prefix: String) -> String? { s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil }
    if let t = after("### ") ?? after("## ") ?? after("# ") { return Line(kind: .heading, level: level, text: t) }
    if let t = after("• ") { return Line(kind: .bullet, level: level, text: t) }
    if let t = after("☐ ") { return Line(kind: .todo, level: level, text: t) }
    if let t = after("☑ ") { return Line(kind: .todo, level: level, text: t, checked: true) }
    if let t = after("> ") { return Line(kind: .quote, level: level, text: t) }
    if let t = after("↳ ") { return Line(kind: .subpage, level: level, text: t) }
    if let t = after("▸ ") { return Line(kind: .toggle, level: level, text: t) }
    // Nummerierung „<n>. “: nur Ziffern vor dem Punkt, danach ein Leerzeichen.
    if let dot = s.firstIndex(of: "."), dot > s.startIndex, s[..<dot].allSatisfy(\.isNumber),
       s[s.index(after: dot)...].hasPrefix(" ") {
      let body = s[s.index(dot, offsetBy: 2)...]
      return Line(kind: .numbered, level: level, text: String(body), number: "\(s[..<dot]).")
    }
    return Line(kind: .text, level: level, text: s)
  }

  // MARK: - Ansicht

  /// Zeilen mit der Nummer der To-do-Zeile (nil für alle anderen Zeilen).
  private var rows: [(line: Line, todo: Int?)] {
    var n = 0
    return Self.lines(text).map { l -> (line: Line, todo: Int?) in
      guard l.kind == .todo else { return (line: l, todo: nil) }
      defer { n += 1 }
      return (line: l, todo: n)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        lineView(row.line, todo: row.todo)
          .padding(.leading, CGFloat(row.line.level) * 10)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func lineView(_ l: Line, todo: Int?) -> some View {
    switch l.kind {
    case .heading:
      Text(l.text)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.text)
        .padding(.top, 6)
    case .bullet:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "circle.fill")
          .font(.system(size: 4))
          .foregroundStyle(Theme.tertiary)
          .frame(width: 6)
        plain(l.text, Theme.secondary)
      }
    case .numbered:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(l.number)
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(Theme.tertiary)
          .frame(minWidth: 18, alignment: .trailing)
        plain(l.text, Theme.secondary)
      }
    case .todo:
      let task = todo.flatMap { checkTask($0, l.text) }
      let checked = task.map { $0.done || completing.contains($0.id) } ?? l.checked
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let task {
          CheckCircle(checked: checked, size: 14) { onToggle(task) }
        } else {
          CheckCircle(checked: checked, size: 14) {}
            .opacity(0.45)
            .help("Nur in Notion abhakbar")
        }
        plain(l.text, checked ? Theme.tertiary : Theme.secondary)
          .strikethrough(checked, color: Theme.tertiary)
      }
    case .quote:
      plain(l.text, Theme.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle().fill(Theme.capsuleHover).frame(width: 2)
        }
    case .divider:
      Divider().padding(.vertical, 2)
    case .subpage:
      HStack(spacing: 6) {
        Image(systemName: "doc")
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
        Text(l.text)
          .font(.system(size: 12))
          .foregroundStyle(Theme.tertiary)
      }
    case .toggle:
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Theme.tertiary)
          .frame(width: 10)
        plain(l.text, Theme.text)
      }
    case .text:
      plain(l.text, Theme.secondary)
    case .blank:
      Color.clear.frame(height: 4)
    }
  }

  private func plain(_ s: String, _ color: Color) -> some View {
    Text(s)
      .font(.system(size: 12))
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
