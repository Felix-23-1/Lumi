// Checkboxen in Notizen (Markdown-Aufgaben: "- [ ] text", "* [x] text") und die
// kleinen Bausteine dafür: Lese-Ansicht mit Schaltern, Editor, Füll-Container.
import AppKit
import SwiftUI

/// Eine Zeile der Notiz. `index` ist die nullbasierte Zeilennummer im Inhalt.
struct NoteLine: Equatable {
  enum Kind: Equatable { case text, checkbox }
  let index: Int
  let kind: Kind
  let checked: Bool
  /// Text ohne Einrückung und ohne Checkbox-Markierung.
  let text: String
  /// Anzahl führender Leerzeichen/Tabs (nur für Checkboxen gesetzt).
  let indent: Int
}

enum NoteCheckboxes {
  static func lines(_ content: String) -> [NoteLine] {
    content.components(separatedBy: "\n").enumerated().map { i, raw in
      if let m = marker(raw) {
        return NoteLine(index: i, kind: .checkbox, checked: m.checked, text: m.text, indent: m.indent)
      }
      return NoteLine(index: i, kind: .text, checked: false, text: raw, indent: 0)
    }
  }

  /// Schaltet die Checkbox in Zeile `line` um ([ ] <-> [x]); alle anderen Zeichen bleiben.
  /// Keine Checkbox oder Zeile außerhalb des Inhalts: unverändert.
  static func toggleCheckbox(in content: String, line: Int) -> String {
    var lines = content.components(separatedBy: "\n")
    guard lines.indices.contains(line), let m = marker(lines[line]) else { return content }
    var chars = Array(lines[line])
    chars[m.indent + 3] = m.checked ? " " : "x"
    lines[line] = String(chars)
    return lines.joined(separator: "\n")
  }

  /// Hängt eine leere Checkbox ans Ende an (Schaltfläche "Checkbox" im Editor).
  /// shortcut: Cursor-Position ist im TextEditor nicht zugänglich, daher immer Anhängen.
  static func appendCheckbox(to content: String) -> String {
    if content.isEmpty { return "- [ ] " }
    return content.hasSuffix("\n") ? content + "- [ ] " : content + "\n- [ ] "
  }

  private struct Marker {
    let checked: Bool
    let text: String
    let indent: Int
  }

  /// Erkennt `- [ ] text`, `* [x] text` (auch eingerückt). Nil = keine Checkbox.
  private static func marker(_ line: String) -> Marker? {
    let chars = Array(line)
    let indent = chars.prefix { $0 == " " || $0 == "\t" }.count
    guard chars.count >= indent + 5 else { return nil }
    guard chars[indent] == "-" || chars[indent] == "*", chars[indent + 1] == " ",
          chars[indent + 2] == "[", chars[indent + 4] == "]" else { return nil }
    let mark = chars[indent + 3]
    guard mark == " " || mark == "x" || mark == "X" else { return nil }
    let after = indent + 5
    guard after == chars.count || chars[after] == " " else { return nil }
    let text = String(chars[after...].drop(while: { $0 == " " }))
    return Marker(checked: mark != " ", text: text, indent: indent)
  }
}

/// Lese-Ansicht: Text zeilenweise, Checkboxen als antippbare Schalter.
struct NoteChecklist: View {
  let content: String
  var large = false
  let onToggle: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: large ? 8 : 5) {
      ForEach(NoteCheckboxes.lines(content), id: \.index) { line in
        row(line)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func row(_ line: NoteLine) -> some View {
    let size: CGFloat = large ? 14 : 13
    if line.kind == .checkbox {
      Button { onToggle(line.index) } label: {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: line.checked ? "checkmark.square.fill" : "square")
            .foregroundStyle(line.checked ? Theme.green : Theme.secondary)
          Text(line.text)
            .strikethrough(line.checked)
            .foregroundStyle(line.checked ? Theme.secondary : Theme.text)
        }
        .font(.system(size: size))
        .lineSpacing(large ? 4 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, CGFloat(line.indent) * 6)
      .accessibilityValue(line.checked ? "erledigt" : "offen")
    } else {
      Text(line.text.isEmpty ? " " : line.text)
        .font(.system(size: size))
        .lineSpacing(large ? 4 : 2)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }
}

/// Editor für den Notizinhalt mit Format-Leiste. Notch: höchstens 140 pt; eigenes Fenster: füllt die Höhe.
/// Der Text bleibt Markdown; die Live-Darstellung ist nur Hervorhebung (NoteMarkdownStyle).
struct NoteTextEditor: View {
  @Binding var text: String
  var fills = false
  @Environment(\.tabySnapshot) private var snapshot
  @State private var handle = NoteEditorHandle()

  var body: some View {
    let size: CGFloat = fills ? 14 : 13
    VStack(alignment: .leading, spacing: 4) {
      NoteFormatBar(handle: handle)
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text("Inhalt").font(.system(size: size)).foregroundStyle(Theme.tertiary)
            .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
        }
        if snapshot {
          Text(AttributedString(NoteMarkdownStyle.attributed(text, size: size)))
            .padding(.leading, 5).padding(.top, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          NoteMarkdownField(text: $text, size: size, handle: handle)
        }
      }
      .padding(8)
      .frame(minHeight: 70, maxHeight: fills ? .infinity : 140, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.capsule))
    }
    .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
  }
}

/// Verbindung von der Format-Leiste zum Textfeld.
@MainActor
final class NoteEditorHandle {
  weak var view: NoteMarkdownTextView?

  func perform(_ action: NoteFormatting.Action) { view?.format(action) }
}

/// Format-Leiste über dem Editor; die Knöpfe wirken auf Auswahl bzw. aktuelle Zeile.
private struct NoteFormatBar: View {
  let handle: NoteEditorHandle
  /// Snapshots ohne Scroll-Container, sonst bleibt die Leiste im Renderer leer.
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    // In der schmalen Insel läuft die Leiste zur Seite, statt Knöpfe abzuschneiden.
    if snapshot { bar } else { ScrollView(.horizontal, showsIndicators: false) { bar } }
  }

  private var bar: some View {
    HStack(spacing: 3) {
      button(.heading1, "Überschrift groß") { Text("H1").font(.system(size: 11, weight: .heavy)) }
      button(.heading2, "Überschrift mittel") { Text("H2").font(.system(size: 11, weight: .bold)) }
      button(.bold, "Fett (⌘B)") { Text("B").font(.system(size: 11, weight: .bold)) }
      button(.italic, "Kursiv (⌘I)") { Text("I").font(.system(size: 11, weight: .semibold).italic()) }
      Rectangle().fill(Theme.tertiary).frame(width: 1, height: 12).padding(.horizontal, 2)
      button(.bullet, "Aufzählung") { Image(systemName: "list.bullet") }
      button(.numbered, "Nummerierung") { Text("1.") }
      button(.checkbox, "Checkbox") { Image(systemName: "checklist") }
      button(.quote, "Zitat") { Image(systemName: "text.quote") }
      button(.rule, "Trennlinie") { Image(systemName: "minus") }
      Rectangle().fill(Theme.tertiary).frame(width: 1, height: 12).padding(.horizontal, 2)
      button(.indent, "Einrücken (Tab)") { Image(systemName: "increase.indent") }
      button(.outdent, "Ausrücken (⇧Tab)") { Image(systemName: "decrease.indent") }
      Spacer(minLength: 0)
    }
  }

  private func button<Label: View>(_ action: NoteFormatting.Action, _ help: String,
                                   @ViewBuilder _ label: () -> Label) -> some View {
    Button { handle.perform(action) } label: { label() }
      .buttonStyle(NoteFormatButtonStyle())
      .help(help)
      .accessibilityLabel(help)
  }
}

private struct NoteFormatButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Theme.secondary)
      .frame(minWidth: 26, minHeight: 22)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(configuration.isPressed ? Theme.capsuleHover : Theme.capsule))
      .contentShape(Rectangle())
  }
}

/// Textfeld (NSTextView) mit Markdown-Hervorhebung. Return setzt Listen fort; ⌘B/⌘I formatieren.
final class NoteMarkdownTextView: NSTextView {
  func format(_ action: NoteFormatting.Action) {
    apply(NoteFormatting.edit(action, text: string, selection: selectedRange()))
    window?.makeFirstResponder(self)
  }

  override func insertNewline(_ sender: Any?) {
    guard let edit = NoteFormatting.continueList(string, selection: selectedRange()) else {
      super.insertNewline(sender)
      return
    }
    apply(edit)
  }

  /// Tab rückt Zeilen ein, Umschalt-Tab rückt aus (Listen verschachteln sich so).
  override func insertTab(_ sender: Any?) { format(.indent) }
  override func insertBacktab(_ sender: Any?) { format(.outdent) }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === self {
      switch event.charactersIgnoringModifiers {
      case "b": format(.bold); return true
      case "i": format(.italic); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Ganzer Text wird ersetzt (eine Rückgängig-Stufe); Hervorhebung folgt über den Delegaten.
  private func apply(_ edit: NoteFormatting.Edit) {
    let full = NSRange(location: 0, length: (string as NSString).length)
    insertText(edit.text, replacementRange: full)
    setSelectedRange(edit.selection)
    scrollRangeToVisible(edit.selection)
  }
}

/// SwiftUI-Brücke zum Markdown-Textfeld. Der Binding-Text bleibt der unveränderte Markdown-String.
struct NoteMarkdownField: NSViewRepresentable {
  @Binding var text: String
  let size: CGFloat
  let handle: NoteEditorHandle

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    let view = NoteMarkdownTextView()
    view.delegate = context.coordinator
    view.drawsBackground = false
    view.isRichText = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticLinkDetectionEnabled = false
    view.font = .systemFont(ofSize: size)
    view.textColor = .labelColor
    view.textContainerInset = NSSize(width: 0, height: 1)
    view.minSize = NSSize(width: 0, height: 0)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true

    let scroll = NSScrollView()
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder

    view.string = text
    NoteMarkdownStyle.apply(to: view.textStorage ?? NSTextStorage(), size: size)
    handle.view = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NoteMarkdownTextView else { return }
    context.coordinator.parent = self
    handle.view = view
    if view.string != text {
      view.string = text
      context.coordinator.highlight(view)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: NoteMarkdownField

    init(parent: NoteMarkdownField) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      // Während einer IME-/Tottasten-Komposition weder ins Binding schreiben noch umformatieren.
      guard !view.hasMarkedText() else { return }
      parent.text = view.string
      highlight(view)
    }

    func highlight(_ view: NSTextView) {
      guard let storage = view.textStorage else { return }
      NoteMarkdownStyle.apply(to: storage, size: parent.size)
    }
  }
}

/// Färbt und formatiert den Text nach `NoteFormatting.spans`. Die Zeichen selbst bleiben unverändert.
enum NoteMarkdownStyle {
  static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString(string: text)
    apply(to: out, size: size)
    return out
  }

  static func apply(to storage: NSMutableAttributedString, size: CGFloat) {
    storage.beginEditing()
    storage.setAttributes([.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor],
                          range: NSRange(location: 0, length: storage.length))
    for span in NoteFormatting.spans(storage.string) {
      let r = span.range
      switch span.style {
      case .heading(let level):
        let fontSize = level == 1 ? size + 7 : level == 2 ? size + 3 : size + 1
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        restyle(storage, r) { _ in NSFont.systemFont(ofSize: fontSize, weight: weight) }
        paragraph(storage, r) { $0.paragraphSpacingBefore = 4 }
      case .bold:
        restyle(storage, r) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
      case .italic:
        restyle(storage, r) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
      case .marker:
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
      case .quote:
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
        paragraph(storage, r) { $0.firstLineHeadIndent = 12; $0.headIndent = 12 }
      case .listItem:
        paragraph(storage, r) { $0.firstLineHeadIndent = 4; $0.headIndent = 18 }
      case .rule:
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
        paragraph(storage, r) { $0.paragraphSpacingBefore = 6; $0.paragraphSpacing = 6 }
      case .doneText:
        storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                               .foregroundColor: NSColor.secondaryLabelColor], range: r)
      }
    }
    storage.endEditing()
  }

  private static func restyle(_ s: NSMutableAttributedString, _ r: NSRange, _ change: (NSFont) -> NSFont) {
    var runs: [(NSRange, NSFont)] = []
    s.enumerateAttribute(.font, in: r) { value, sub, _ in
      runs.append((sub, change((value as? NSFont) ?? NSFont.systemFont(ofSize: 13))))
    }
    for (sub, font) in runs { s.addAttribute(.font, value: font, range: sub) }
  }

  private static func paragraph(_ s: NSMutableAttributedString, _ r: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
    let style = (s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?
      .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
    change(style)
    s.addAttribute(.paragraphStyle, value: style, range: r)
  }
}

/// Inhalt, der im eigenen Fenster die restliche Höhe füllt und dort selbst scrollt.
/// In der Insel (fills false) bleibt es bei der natürlichen Höhe der umgebenden Liste.
struct NoteFill<Content: View>: View {
  let fills: Bool
  @ViewBuilder var content: () -> Content
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if fills && !snapshot {
      ScrollView(.vertical, showsIndicators: false) {
        content().frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      content()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
    }
  }
}
