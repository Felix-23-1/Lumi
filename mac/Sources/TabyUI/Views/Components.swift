// Wiederverwendbare Bausteine der Ansichten: Farben, Knopfstile, Karte,
// Abschnittsüberschrift, Chips, Eingabekapsel, Häkchen, Tipp-Punkte und ein
// Scrollbereich mit natürlicher Höhe (die Insel federt auf unsere Höhe).
import SwiftUI
import TabyCore

// MARK: - Theme

enum Theme {
  /// Fast schwarze Karte auf der schwarzen Insel.
  static let card = Color(red: 0.055, green: 0.059, blue: 0.067)
  static let cardStroke = Color.white.opacity(0.08)
  static let raised = Color.white.opacity(0.06)
  static let raisedHover = Color.white.opacity(0.10)
  static let capsule = Color.white.opacity(0.09)
  static let capsuleHover = Color.white.opacity(0.15)

  static let text = Color.white.opacity(0.94)
  static let secondary = Color.white.opacity(0.74)
  static let tertiary = Color.white.opacity(0.62)

  static let red = Color(red: 1.0, green: 0.42, blue: 0.40)
  static let amber = Color(red: 1.0, green: 0.74, blue: 0.32)
  static let green = Color(red: 0.32, green: 0.86, blue: 0.54)
  static let blue = Color(red: 0.38, green: 0.64, blue: 1.0)
  static let purple = Color(red: 0.70, green: 0.56, blue: 1.0)
  static let teal = Color(red: 0.30, green: 0.83, blue: 0.80)
  static let orange = Color(red: 1.0, green: 0.56, blue: 0.24)

  static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
  static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.72)
  static let pop = Animation.spring(response: 0.30, dampingFraction: 0.45)

  /// Innenabstand des Inhaltsbereichs.
  static let pad: CGFloat = 12
  static let radius: CGFloat = 18

  /// Einfügen/Entfernen von Listenzeilen.
  static let rowTransition = AnyTransition.asymmetric(
    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
    removal: .opacity.combined(with: .scale(scale: 0.92))
  )
}

extension CalendarSourceKind {
  var color: Color {
    switch self {
    case .local: Theme.blue
    case .apple: Theme.red
    case .notion: Theme.purple
    case .ics: Theme.teal
    case .caldav: Theme.green
    case .microsoft: Theme.blue
    }
  }

  var germanName: String {
    switch self {
    case .local: "Lokal"
    case .apple: "Apple Kalender"
    case .notion: "Notion"
    case .ics: "ICS-Abo"
    case .caldav: "CalDAV"
    case .microsoft: "Outlook"
    }
  }

  var symbol: String {
    switch self {
    case .local: "internaldrive"
    case .apple: "applelogo"
    case .notion: "doc.text"
    case .ics: "link"
    case .caldav: "server.rack"
    case .microsoft: "envelope.badge"
    }
  }
}

// MARK: - "Jetzt" für Ansichten

private struct TabyNowKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

private struct TabySnapshotKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// true beim Rendern per ImageRenderer: AppKit-gestützte Bausteine
  /// (ScrollView, TextField, TextEditor, DatePicker) werden dort nicht
  /// gezeichnet und deshalb durch einfache Text-/Stapel-Ansichten ersetzt.
  var tabySnapshot: Bool {
    get { self[TabySnapshotKey.self] }
    set { self[TabySnapshotKey.self] = newValue }
  }

  /// Lokaler ISO-Zeitpunkt "YYYY-MM-DDTHH:mm" für Anzeige-Logik (Fälligkeit,
  /// "Heute"). Snapshots/Prüfungen setzen ihn fest; sonst Systemzeit.
  var tabyNow: String? {
    get { self[TabyNowKey.self] }
    set { self[TabyNowKey.self] = newValue }
  }

  /// Höchstens sichtbare Inhaltshöhe der Insel (eingeklappt 380, ausgeklappt mehr).
  /// Listen (`CappedScroll`) wachsen um denselben Zuwachs.
  var tabyContentCap: CGFloat {
    get { self[TabyContentCapKey.self] }
    set { self[TabyContentCapKey.self] = newValue }
  }
}

private struct TabyContentCapKey: EnvironmentKey {
  static let defaultValue: CGFloat = TabLayout.maxContentHeight
}

extension View {
  /// Fester Zeitpunkt für die Ansichten (Vorschau, Snapshots, Integrator mit Clock).
  public func tabyNow(_ iso: String?) -> some View { environment(\.tabyNow, iso) }

  /// Sichtbare Inhaltshöhe deckeln (eigenes Fenster: sehr groß = keine Deckelung).
  public func tabyContentCap(_ cap: CGFloat) -> some View { environment(\.tabyContentCap, cap) }
}

enum NowResolver {
  static func now(_ env: String?) -> String { env ?? LocalTime.format(Date()) }
  static func today(_ env: String?) -> String { LocalTime.datePart(now(env)) }
}

// MARK: - Knöpfe

enum PillKind { case primary, secondary, ghost, danger }

/// Kapsel-Knopf: weiß (primär, stärkster Kontrast), grau (sekundär), ohne
/// Hintergrund (ghost) oder rötlich (danger). Hover hellt auf, Drücken federt.
struct PillButtonStyle: ButtonStyle {
  var kind: PillKind = .secondary
  var compact = false

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, kind: kind, compact: compact)
  }

  private struct PillBody: View {
    let configuration: Configuration
    let kind: PillKind
    let compact: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .font(.system(size: compact ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 5 : 7)
        .background(Capsule().fill(background))
        .overlay(Capsule().strokeBorder(Color.white.opacity(kind == .ghost && hover ? 0.12 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .scaleEffect(configuration.isPressed ? 0.94 : (hover && enabled ? 1.03 : 1))
        .opacity(enabled ? 1 : 0.4)
        .animation(Theme.snappy, value: configuration.isPressed)
        .animation(Theme.snappy, value: hover)
        .onHover { hover = $0 }
    }

    private var foreground: Color {
      switch kind {
      case .primary: .black
      case .secondary, .ghost: Theme.text
      case .danger: Theme.red
      }
    }

    private var background: Color {
      switch kind {
      case .primary: hover ? .white : Color.white.opacity(0.92)
      case .secondary: hover ? Theme.capsuleHover : Theme.capsule
      case .ghost: hover ? Theme.raised : .clear
      case .danger: Theme.red.opacity(hover ? 0.24 : 0.14)
      }
    }
  }
}

/// Runder Symbol-Knopf (z. B. Senden, Papierkorb).
struct RoundIconButtonStyle: ButtonStyle {
  var size: CGFloat = 26
  var filled = false
  var tint: Color = Theme.secondary

  func makeBody(configuration: Configuration) -> some View {
    IconBody(configuration: configuration, size: size, filled: filled, tint: tint)
  }

  private struct IconBody: View {
    let configuration: Configuration
    let size: CGFloat
    let filled: Bool
    let tint: Color
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .font(.system(size: size * 0.46, weight: .bold))
        .foregroundStyle(filled ? Color.black : (hover ? Theme.text : tint))
        .frame(width: size, height: size)
        .background(Circle().fill(filled ? Color.white.opacity(hover ? 1 : 0.92) : (hover ? Theme.capsuleHover : .clear)))
        // Trefferfläche mindestens 28 pt, damit kleine Knöpfe gut zu treffen sind.
        .frame(width: max(size, 28), height: max(size, 28))
        .contentShape(Circle())
        .scaleEffect(configuration.isPressed ? 0.88 : 1)
        .opacity(enabled ? 1 : 0.35)
        .animation(Theme.snappy, value: configuration.isPressed)
        .animation(Theme.snappy, value: hover)
        .onHover { hover = $0 }
    }
  }
}

/// Kleine Tastenkappe ("N", "Y") in Knöpfen.
struct KeyCap: View {
  let key: String
  var dark = false
  var body: some View {
    Text(key)
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .foregroundStyle(dark ? Color.black.opacity(0.55) : Theme.secondary)
      .frame(minWidth: 16, minHeight: 16)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(dark ? Color.black.opacity(0.3) : Color.white.opacity(0.3), lineWidth: 1)
      )
  }
}

// MARK: - Karte, Überschrift, Chips

struct CardModifier: ViewModifier {
  var tint: Color? = nil
  var padding: CGFloat = 12
  func body(content: Content) -> some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised)
          if let tint {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(RadialGradient(colors: [tint.opacity(0.16), .clear], center: .bottom, startRadius: 0,
                                   endRadius: 260))
          }
        }
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder((tint ?? .white).opacity(tint == nil ? 0.06 : 0.22), lineWidth: 1)
      )
  }
}

extension View {
  /// Erhöhte Fläche (Abschnitt) auf der Inhaltskarte.
  func tabyCard(tint: Color? = nil, padding: CGFloat = 12) -> some View {
    modifier(CardModifier(tint: tint, padding: padding))
  }

  /// Wurzel eines Reiters: fast schwarze Karte mit großer Rundung.
  func tabyPage() -> some View {
    self
      .padding(Theme.pad)
      .frame(width: TabLayout.contentWidth, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
      )
      .environment(\.colorScheme, .dark)
  }
}

struct SectionHeader: View {
  let symbol: String
  let title: String
  var count: Int? = nil
  var tint: Color = Theme.secondary

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.secondary)
        .textCase(.uppercase)
        .kerning(0.4)
      if let count {
        Text("\(count)")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Theme.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(Theme.capsule))
          .contentTransition(.numericText())
          .animation(Theme.spring, value: count)
      }
      Spacer(minLength: 0)
    }
  }
}

/// Abschnitt mit Einklapp-Pfeil in der Überschrift (für lange Listen). `collapsed`
/// gehört dem Aufrufer, damit er den Zustand merken kann. `trailing` z. B. ein Knopf.
struct CollapsibleSection<Trailing: View, Content: View>: View {
  let symbol: String
  let title: String
  var count: Int? = nil
  @Binding var collapsed: Bool
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Button { withAnimation(Theme.spring) { collapsed.toggle() } } label: {
          HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
              .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
              .frame(width: 12)
            SectionHeader(symbol: symbol, title: title, count: count)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        trailing()
      }
      if !collapsed { content() }
    }
  }
}

extension CollapsibleSection where Trailing == EmptyView {
  init(symbol: String, title: String, count: Int? = nil, collapsed: Binding<Bool>,
       @ViewBuilder content: @escaping () -> Content) {
    self.init(symbol: symbol, title: title, count: count, collapsed: collapsed,
              trailing: { EmptyView() }, content: content)
  }
}

struct Chip: View {
  let text: String
  var symbol: String? = nil
  var tint: Color = Theme.secondary

  var body: some View {
    HStack(spacing: 3) {
      if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
      Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(Capsule().fill(tint.opacity(0.15)))
  }
}

/// Auswählbare Kapsel (Segment, Schnellwahl).
struct ChoiceChip: View {
  let text: String
  var symbol: String? = nil
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
        Text(text).font(.system(size: 12, weight: selected ? .semibold : .medium))
      }
      .foregroundStyle(selected ? Color.black : Theme.text)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Capsule().fill(selected ? Color.white.opacity(0.92) : (hover ? Theme.capsuleHover : Theme.capsule)))
      .contentShape(Capsule())
    }
    .buttonStyle(PressScaleStyle())
    .onHover { hover = $0 }
    .animation(Theme.snappy, value: selected)
    .animation(Theme.snappy, value: hover)
  }
}

struct PressScaleStyle: ButtonStyle {
  var scale: CGFloat = 0.94
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .animation(Theme.snappy, value: configuration.isPressed)
  }
}

struct StatusDot: View {
  let color: Color
  var size: CGFloat = 7
  var body: some View {
    Circle().fill(color).frame(width: size, height: size)
      .shadow(color: color.opacity(0.6), radius: 3)
  }
}

/// Hinweis-/Warnzeile (rot, gelb, blau).
struct Banner: View {
  let symbol: String
  let text: String
  var tint: Color = Theme.amber

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
      Text(text).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
  }
}

struct EmptyState: View {
  let symbol: String
  let title: String
  var subtitle: String? = nil
  @State private var bounce = 0

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(Theme.tertiary)
        .symbolEffect(.bounce, value: bounce)
      Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
      if let subtitle {
        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .onAppear { bounce += 1 }
  }
}

// MARK: - Eingabe

/// Eingabekapsel mit eigenem Platzhalter (bleibt auch in Snapshots sichtbar)
/// und dezentem Fokusring. Enter: `.onSubmit` am Aufrufer (wirkt auf das Feld).
struct InputCapsule<Trailing: View>: View {
  let placeholder: String
  @Binding var text: String
  var secure = false
  var mono = false
  /// Jede Änderung setzt den Fokus ins Feld (z. B. nach einem Beispiel-Tipp), ohne abzuschicken.
  var focusTick = 0
  @ViewBuilder var trailing: () -> Trailing
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    HStack(spacing: 6) {
      ZStack(alignment: .leading) {
        if text.isEmpty {
          Text(placeholder).foregroundStyle(Theme.tertiary).lineLimit(1).allowsHitTesting(false)
        }
        Group {
          if snapshot {
            Text(secure ? String(repeating: "•", count: text.count) : text).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else if secure {
            SecureField("", text: $text)
          } else {
            TextField("", text: $text)
          }
        }
        .textFieldStyle(.plain)
        .focused($focused)
      }
      .font(.system(size: 13, design: mono ? .monospaced : .default))
      .foregroundStyle(Theme.text)
      trailing()
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .frame(minHeight: 32)
    .background(Capsule().fill(focused ? Theme.capsuleHover : Theme.capsule))
    .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.22 : 0.0), lineWidth: 1))
    .animation(Theme.snappy, value: focused)
    .onChange(of: focusTick) { _, _ in focused = true }
  }
}

extension InputCapsule where Trailing == EmptyView {
  init(placeholder: String, text: Binding<String>, secure: Bool = false, mono: Bool = false) {
    self.init(placeholder: placeholder, text: text, secure: secure, mono: mono) { EmptyView() }
  }
}

/// Mehrzeiliges Feld (Notizen, eigene Anweisungen).
struct TextArea: View {
  let placeholder: String
  @Binding var text: String
  var minHeight: CGFloat = 60
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder).foregroundStyle(Theme.tertiary).padding(.top, 1).padding(.leading, 5)
          .allowsHitTesting(false)
      }
      if snapshot {
        Text(text).foregroundStyle(Theme.text).padding(.leading, 5).padding(.top, 1)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      } else {
        TextEditor(text: $text)
          .scrollContentBackground(.hidden)
          .focused($focused)
          .foregroundStyle(Theme.text)
      }
    }
    .font(.system(size: 13))
    .padding(8)
    .frame(minHeight: minHeight, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(focused ? Theme.capsuleHover : Theme.capsule))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
      .strokeBorder(Color.white.opacity(focused ? 0.22 : 0), lineWidth: 1))
    .animation(Theme.snappy, value: focused)
  }
}

/// Eigener Schalter (rendert auch in Snapshots, anders als der AppKit-Toggle).
struct PillToggle: View {
  let title: String
  @Binding var isOn: Bool

  var body: some View {
    Button {
      withAnimation(Theme.snappy) { isOn.toggle() }
    } label: {
      HStack {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
        Spacer()
        ZStack(alignment: isOn ? .trailing : .leading) {
          Capsule().fill(isOn ? Theme.green : Theme.capsuleHover).frame(width: 34, height: 20)
          Circle().fill(.white).frame(width: 16, height: 16).padding(2)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOn ? "an" : "aus")
  }
}

/// Zahl mit − / + (Erinnerungsvorlauf).
struct NumberStepper: View {
  @Binding var value: Int
  var step = 5
  var range: ClosedRange<Int> = 0...240
  var unit = ""

  var body: some View {
    HStack(spacing: 2) {
      Button { withAnimation(Theme.snappy) { value = max(range.lowerBound, value - step) } } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(RoundIconButtonStyle(size: 24))
      Text(value == 0 ? "aus" : "\(value)\(unit)")
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.text)
        .contentTransition(.numericText(value: Double(value)))
        .frame(minWidth: 52)
      Button { withAnimation(Theme.snappy) { value = min(range.upperBound, value + step) } } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(RoundIconButtonStyle(size: 24))
    }
    .padding(2)
    .background(Capsule().fill(Theme.capsule))
  }
}

// MARK: - Häkchen

/// Runde, federnde Checkbox.
struct CheckCircle: View {
  let checked: Bool
  var tint: Color = Theme.green
  var size: CGFloat = 20
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .strokeBorder(checked ? tint : Color.white.opacity(hover ? 0.6 : 0.32), lineWidth: 1.6)
        Circle()
          .fill(tint)
          .scaleEffect(checked ? 1 : 0.001)
        Image(systemName: "checkmark")
          .font(.system(size: size * 0.5, weight: .heavy))
          .foregroundStyle(.black.opacity(0.8))
          .scaleEffect(checked ? 1 : 0.2)
          .opacity(checked ? 1 : 0)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(PressScaleStyle(scale: 0.82))
    .onHover { hover = $0 }
    .animation(Theme.pop, value: checked)
    .animation(Theme.snappy, value: hover)
    .accessibilityLabel(checked ? "Erledigt" : "Abhaken")
  }
}

// MARK: - Tipp-Punkte

/// Drei hüpfende Punkte ("denkt…").
struct TypingDots: View {
  var body: some View {
    // 30 Bilder/s reichen für drei Punkte; ohne Grenze zeichnet ProMotion 120-mal pro Sekunde.
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
      let t = tl.date.timeIntervalSinceReferenceDate
      HStack(spacing: 4) {
        ForEach(0..<3, id: \.self) { i in
          let phase = sin(t * 6 - Double(i) * 0.8)
          Circle()
            .fill(Color.white.opacity(0.45 + 0.4 * max(0, phase)))
            .frame(width: 6, height: 6)
            .offset(y: -3 * max(0, phase))
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Capsule().fill(Theme.capsule))
    .accessibilityLabel("denkt")
  }
}

// MARK: - Natürliche Höhe mit Scroll-Grenze

/// Nimmt die natürliche Höhe des Inhalts an, höchstens `maxHeight`; darüber
/// scrollt der Inhalt (so wächst die Insel mit, Eingaben bleiben sichtbar).
struct CappedHeight: Layout {
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let first = subviews.first else { return .zero }
    let ideal = first.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

/// Scrollbereich, der höchstens `maxHeight` hoch wird.
struct CappedScroll<Content: View>: View {
  let maxHeight: CGFloat
  @ViewBuilder var content: () -> Content
  @Environment(\.tabySnapshot) private var snapshot
  @Environment(\.tabyContentCap) private var contentCap

  /// Ausgeklappt wächst die Grenze um den Zuwachs der Inhaltshöhe.
  static func limit(_ maxHeight: CGFloat, contentCap: CGFloat) -> CGFloat {
    maxHeight + max(0, contentCap - TabLayout.maxContentHeight)
  }

  var body: some View {
    CappedHeight(maxHeight: Self.limit(maxHeight, contentCap: contentCap)) {
      if snapshot {
        content().frame(maxWidth: .infinity, alignment: .topLeading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxHeight: .infinity, alignment: .top)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          content().frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .clipShape(Rectangle())
  }
}

/// Hover-Zustand für Zeilen (Papierkorb einblenden usw.).
struct HoverRow<Content: View>: View {
  @ViewBuilder var content: (Bool) -> Content
  @State private var hover = false

  var body: some View {
    content(hover)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.raised : .clear))
      .contentShape(Rectangle())
      .onHover { h in withAnimation(Theme.snappy) { hover = h } }
  }
}

/// Kompakter Datums-/Zeitwähler; im Snapshot als Kapsel mit Text.
struct CompactDatePicker: View {
  @Binding var date: Date
  var time = false
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if snapshot {
      Text(time ? LocalTime.formatTime(date) : GermanDate.short(LocalTime.formatDate(date)))
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Theme.capsule))
    } else {
      DatePicker("", selection: $date, displayedComponents: time ? .hourAndMinute : .date)
        .labelsHidden()
        .datePickerStyle(.field)
        .frame(width: time ? 56 : 92)
    }
  }
}

/// Freie Uhrzeit "HH:mm": tippen (18:30, 1830, 9) oder mit −/+ in 15-Minuten-Schritten.
struct TimeOfDayField: View {
  @Binding var time: String
  @State private var text = ""
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    // Vorschauen zeigen nur den Wert: das native Eingabefeld rendert dort mit einem Verbotssymbol.
    if snapshot {
      Text(time.isEmpty ? "HH:mm" : time)
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(Theme.text)
        .frame(width: 88)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    } else {
      liveField
    }
  }

  private var liveField: some View {
    HStack(spacing: 2) {
      stepButton("minus") { time = SettingsLogic.shiftTime(time, by: -15) }
      TextField("HH:mm", text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        .multilineTextAlignment(.center)
        .frame(width: 52)
        .focused($focused)
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
      stepButton("plus") { time = SettingsLogic.shiftTime(time, by: 15) }
    }
    .padding(.horizontal, 4).padding(.vertical, 3)
    .background(Capsule().fill(Color.white.opacity(0.08)))
    .onAppear { text = time }
    .onChange(of: time) { _, t in text = t }
    .accessibilityLabel("Uhrzeit \(time)")
  }

  private func commit() {
    if let t = SettingsLogic.normalizeTime(text) { time = t; text = t } else { text = time }
  }

  private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white.opacity(0.75))
  }
}
