// Die Insel als reines SwiftUI (kein AppKit-Steuerelement), damit sie sich
// mit ImageRenderer fotografieren lässt. Eine schwarze Form (IslandShape)
// wächst federnd zwischen den Zuständen; das Maskottchen fliegt per
// matchedGeometryEffect vom Flügel in die Karte und zurück.
import SwiftUI
import TabyCore

/// Füllt das (übergroße, durchsichtige) Panel; die Insel sitzt oben mittig.
struct IslandRootView: View {
  @ObservedObject var store: IslandStore
  var animateEntrance = true

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
      IslandView(store: store, model: store.model, animateEntrance: animateEntrance)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .ignoresSafeArea()
    .environmentObject(store.model)
    .environment(\.colorScheme, .dark)
    .environment(\.mascotClock, store.now)
    .environment(\.mascotContextProvider, store.mascotContext)
  }
}

struct IslandView: View {
  @ObservedObject var store: IslandStore
  @ObservedObject var model: AppModel
  var animateEntrance = true
  @Namespace private var ns

  var body: some View {
    let mode = store.mode
    let size = store.targetSize
    let ear = IslandMetrics.earRadius(mode)
    let shape = IslandShape(width: size.width, height: size.height,
                            bottomRadius: IslandMetrics.bottomRadius(mode), ear: ear)
    ZStack(alignment: .top) {
      shape.fill(Color.black)
        .shadow(color: .black.opacity(mode == .closed ? 0 : 0.45), radius: 18, y: 8)
      ZStack(alignment: .top) {
        switch mode {
        case .closed, .peek:
          ClosedWings(store: store, model: model, ns: ns)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
        case .greeting:
          GreetingCard(store: store, ns: ns)
            .transition(.opacity.animation(.easeOut(duration: 0.25)))
        case .capture:
          CaptureCard(store: store, ns: ns)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)),
                                    removal: .opacity.animation(.easeIn(duration: 0.12))))
        case .flash:
          FlashCard(store: store, note: store.machine.flash ?? model.flash, ns: ns)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.06)),
                                    removal: .opacity.animation(.easeIn(duration: 0.12))))
        case .open:
          OpenBoard(store: store, model: model, ns: ns, animateEntrance: animateEntrance)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)),
                                    removal: .opacity.animation(.easeIn(duration: 0.12))))
        }
      }
      .frame(width: size.width, height: size.height, alignment: .top)
      .overlay(alignment: .bottom) {
        if mode == .open, let l = store.appState?.listening {
          ListeningStrip(listening: l, model: model).padding(.bottom, 6).transition(.opacity)
        }
      }
      .overlay {
        if store.dropTargeted { DropOverlay().transition(.opacity) }
      }
      .clipShape(shape)
    }
    .frame(width: size.width + 2 * ear, height: size.height, alignment: .top)
    .overlay(alignment: .top) { MascotEffectsOverlay(store: store) }
    .contentShape(shape)
    .onTapGesture {
      if store.mode != .open && store.mode != .capture { store.click() }
    }
    .onDrop(of: [.fileURL], isTargeted: Binding(get: { store.dropTargeted }, set: { store.setDropTargeted($0) })) { providers in
      guard !providers.isEmpty else { return false }
      Task { @MainActor in
        var paths: [String] = []
        for provider in providers.prefix(DropLogic.maxFiles) {
          if let url = await IslandDrop.fileURL(from: provider) { paths.append(url.path) }
        }
        store.handleDrop(paths: paths)
      }
      return true
    }
  }
}

/// Lädt eine Datei-URL aus einem Drop (NSItemProvider → async).
private enum IslandDrop {
  static func fileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url)
      }
    }
  }
}

/// Overlay beim Ziehen einer Datei über die Insel.
private struct DropOverlay: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.black.opacity(0.6))
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(MascotMood.idle.color, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
      VStack(spacing: 6) {
        Image(systemName: "doc.badge.plus")
          .font(.system(size: 26, weight: .medium))
          .foregroundStyle(MascotMood.idle.color)
        Text("Datei loslassen – Lumi liest sie")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .padding(10)
    .allowsHitTesting(false)
  }
}

// MARK: - Geschlossen / Peek

private struct ClosedWings: View {
  @ObservedObject var store: IslandStore
  @ObservedObject var model: AppModel
  let ns: Namespace.ID

  var body: some View {
    let g = store.geometry
    let peek = store.mode == .peek
    let wing = (peek ? IslandMetrics.peekWing : IslandMetrics.closedWing) + (store.bumped ? IslandMetrics.bumpWidth / 2 : 0)
    let lines = store.tickerLines
    let controls = peek ? store.peekActions : nil
    // Die Flügel bleiben in Notch-Höhe; Laufband und Bedienzeile liegen darunter, mittig unter der Notch.
    let rows = (lines.isEmpty ? 0 : IslandMetrics.tickerHeight) + (controls == nil ? 0 : IslandMetrics.tickerHeight)
    let h = store.targetSize.height - rows
    let mascot = min(h + (peek ? 2 : -1), peek ? 44 : 36)
    // Rechter Flügel zeigt bei offener Freigabe schon das orange „!“; das Abzeichen am Maskottchen
    // entfällt dann, sonst stünde es doppelt da.
    let wingAttention = store.appState?.listening == nil && !model.agentRequests.isEmpty
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        TabyMascot(mood: store.mood, size: mascot, lowPower: !peek, badge: !wingAttention, play: store.mascotPlay, still: !peek)
          .matchedGeometryEffect(id: "mascot", in: ns)
          .mascotInteractions(store)
          .offset(y: 1)
          .frame(width: wing, height: h)
        Spacer(minLength: g.notchWidth)
        indicatorSlot(peek: peek)
          .frame(width: wing, height: h)
      }
      if !lines.isEmpty {
        TickerStrip(lines: lines, large: peek)
          .frame(height: IslandMetrics.tickerHeight)
      }
      if let controls {
        PeekControls(actions: controls, model: model)
          .frame(height: IslandMetrics.tickerHeight)
      }
    }
  }

  /// Rechter Flügel. Läuft ein Timer, tickt die Anzeige jede Sekunde neu; sonst reicht der Stand.
  @ViewBuilder private func indicatorSlot(peek: Bool) -> some View {
    // Laufende Mitschrift hat Vorrang: die Aufnahme muss immer sichtbar sein.
    if let l = store.appState?.listening {
      ListeningBadge(listening: l, large: peek)
    } else if store.appState?.timers.isEmpty == false {
      TimelineView(.periodic(from: .now, by: 1)) { _ in indicator(peek: peek) }
    } else {
      indicator(peek: peek)
    }
  }

  private func indicator(peek: Bool) -> some View {
    ClosedIndicatorView(indicator: StatusRules.indicator(state: store.appState,
                                                         agentPending: !model.agentRequests.isEmpty,
                                                         isThinking: model.isThinking, now: store.wallClock()),
                        mood: store.mood, large: peek)
  }
}

/// Bedienzeile der Peek-Ansicht: Musik (Zurück, Abspielen/Pause, Weiter) und "Beitreten".
private struct PeekControls: View {
  let actions: PeekActions
  let model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      if actions.media {
        mediaButton("backward.fill", "Zurück", .previous)
        mediaButton("playpause.fill", "Abspielen/Pause", .playPause)
        mediaButton("forward.fill", "Weiter", .next)
      }
      if let url = actions.join {
        Button { NSWorkspace.shared.open(url) } label: {
          Label("Beitreten", systemImage: "video.fill")
        }
        .help("Konferenz beitreten")
      }
    }
    .font(.system(size: 11, weight: .semibold, design: .rounded))
    .foregroundStyle(.white.opacity(0.9))
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
  }

  private func mediaButton(_ symbol: String, _ label: String, _ command: MediaCommand) -> some View {
    Button { Task { _ = await model.services.mediaControl(command) } } label: {
      Image(systemName: symbol)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(label)
    .help(label)
  }
}

private struct ClosedIndicatorView: View {
  let indicator: ClosedIndicator
  let mood: MascotMood
  let large: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let font = Font.system(size: large ? 13 : 11, weight: .bold, design: .rounded)
    switch indicator {
    case .attention:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: large ? 18 : 15, weight: .bold))
        .foregroundStyle(.white, MascotMood.alert.color)
        .symbolEffect(.pulse, isActive: !reduceMotion)
        .shadow(color: MascotMood.alert.color.opacity(0.8), radius: 6)
    case .thinking:
      Image(systemName: "ellipsis")
        .font(.system(size: large ? 16 : 13, weight: .heavy))
        .foregroundStyle(MascotMood.thinking.color)
        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
    case .count(let n, let overdue):
      let c = overdue ? MascotMood.error.color : MascotMood.happy.color
      HStack(spacing: 4) {
        Circle().fill(c).frame(width: 6, height: 6).shadow(color: c, radius: 4)
        Text("\(n)").font(font).foregroundStyle(.white.opacity(0.9)).monospacedDigit()
      }
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(Capsule().fill(c.opacity(0.16)))
    case .calm:
      Circle().fill(mood.color).frame(width: 7, height: 7)
        .shadow(color: mood.color.opacity(0.9), radius: 5)
    case .focus(let session):
      FocusCountdown(session: session, large: large)
    case .timer(let remaining):
      HStack(spacing: 4) {
        Image(systemName: "timer").font(.system(size: large ? 12 : 10.5, weight: .bold))
        Text(FocusClock.format(remaining)).font(font).monospacedDigit()
      }
      .foregroundStyle(.white.opacity(0.92))
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(Capsule().fill(MascotMood.thinking.color.opacity(0.22)))
    }
  }
}

/// Laufband unter der Notch: eine Zeile mittig (optional mit SF-Symbol), alle 3,5 s rückt die nächste
/// von oben nach, die alte verschwindet nach unten. Bei einer Zeile statisch; bei Reduce Motion nur Überblendung.
private struct TickerStrip: View {
  let lines: [TickerLine]
  let large: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var index = 0

  var body: some View {
    // Die Uhr läuft am äußeren Container: `.id(index)` am Text würde sonst bei jedem Wechsel
    // die Aufgabe neu starten und den Zähler auf 0 zurücksetzen (Laufband stand still).
    let line = lines[index % lines.count]
    ZStack {
      HStack(spacing: 6) {
        if let symbol = line.symbol { Image(systemName: symbol) }
        Text(line.text)
      }
      .font(.system(size: large ? 14 : 13, weight: .semibold, design: .rounded))
      .foregroundStyle(.white.opacity(0.92))
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 14)
      .id(index % lines.count)
        .transition(reduceMotion ? .opacity : .asymmetric(
          insertion: .move(edge: .top).combined(with: .opacity),
          removal: .move(edge: .bottom).combined(with: .opacity)))
    }
    .clipped()
    .task(id: lines.count) {
      guard lines.count > 1 else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3.5))
        if Task.isCancelled { break }
        withAnimation(.smooth(duration: 0.7)) { index = (index + 1) % max(lines.count, 1) }
      }
    }
  }
}

// MARK: - Begrüßung

private struct GreetingCard: View {
  @ObservedObject var store: IslandStore
  let ns: Namespace.ID

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: store.geometry.notchHeight - 6)
      HStack(spacing: 16) {
        TabyMascot(mood: .happy, size: 66, waving: true, glow: true, badge: false)
          .matchedGeometryEffect(id: "mascot", in: ns)
        VStack(alignment: .leading, spacing: 3) {
          Text(store.greetingText)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
          Text("Schön, dass du da bist.")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 30)
      .frame(maxHeight: .infinity)
    }
  }
}

// MARK: - Schnellerfassung

/// Maskottchen links, daneben das Erfassungsfeld (`QuickCaptureView`). Keine Reiterleiste;
/// die Höhe des Feldes wird gemessen und begrenzt (IslandMetrics.captureContentHeight).
private struct CaptureCard: View {
  @ObservedObject var store: IslandStore
  let ns: Namespace.ID

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: IslandMetrics.bandHeight(store.geometry))
      HStack(alignment: .center, spacing: 14) {
        TabyMascot(mood: store.mood, size: 44, glow: true)
          .matchedGeometryEffect(id: "mascot", in: ns)
          .frame(width: 52)
        Group {
          if let card = store.contextCard {
            ContextCaptureView(context: card, onDone: { store.close() })
          } else if let explain = store.explain {
            ExplainCard(state: explain, onAskInChat: {
              ChatController.shared.input = ExplainCardState.chatPrompt(for: explain.original)
              store.open(tab: .chat)
            }, onDone: { store.close() })
          } else {
            QuickCaptureView(onDone: { store.close() })
          }
        }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(GeometryReader { geo in
            Color.clear.preference(key: CaptureHeightKey.self, value: geo.size.height)
          })
      }
      .padding(.horizontal, 22)
      .frame(maxHeight: .infinity)
      .onPreferenceChange(CaptureHeightKey.self) { v in
        MainActor.assumeIsolated { store.setCaptureHeight(v) }
      }
    }
  }
}

private struct CaptureHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Flash (Benachrichtigung)

private struct FlashCard: View {
  @ObservedObject var store: IslandStore
  let note: TabyNotification?
  let ns: Namespace.ID
  @State private var remaining: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: store.geometry.notchHeight - 4)
      HStack(spacing: 14) {
        TabyMascot(mood: store.mood, size: 58, glow: true)
          .matchedGeometryEffect(id: "mascot", in: ns)
        VStack(alignment: .leading, spacing: 3) {
          Text(note?.title ?? "Lumi")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(note?.body ?? "")
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        if note?.overrun == true {
          VStack(alignment: .trailing, spacing: 6) {
            Button("Fertig") { store.completeFlashTask() }
              .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
              .help("⌘⏎")
            HStack(spacing: 6) {
              Button("Noch 15 Min") { store.extendFlashTask(minutes: 15) }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
              Button("Noch 30 Min") { store.extendFlashTask(minutes: 30) }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
          }
        } else if note?.taskId != nil {
          VStack(alignment: .trailing, spacing: 6) {
            Button("Ich arbeite daran") { store.workOnFlashTask() }
              .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
              .help("Startet den Fokus mit dieser Aufgabe")
            HStack(spacing: 6) {
              Button("Erledigt") { store.completeFlashTask() }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .help("⌘⏎")
              Button("In 10 Min") { store.snoozeFlashTask() }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
          }
        }
      }
      .padding(.horizontal, 24)
      .frame(maxHeight: .infinity)
      // Countdown bis zum Zuklappen (pausiert sichtbar, solange die Maus darauf liegt).
      GeometryReader { geo in
        Capsule().fill(store.mood.color.opacity(0.85))
          .frame(width: geo.size.width * remaining, height: 3)
      }
      .frame(height: 3)
      .padding(.horizontal, 26)
      .padding(.bottom, 10)
      .opacity(store.machine.mouseInside ? 0 : 1)
    }
    .onAppear {
      withAnimation(.linear(duration: store.machine.flashDuration)) { remaining = 0 }
    }
  }
}

// MARK: - Offen (Board)

/// Reiter links und rechts der Notch (jeder Reiter genau einmal, siehe Prüfung).
enum OpenBoardTabs {
  /// Standardreihenfolge nach Gruppen: Täglich, Planen, Kommunikation, Extras; Einstellungen immer rechts.
  static let left: [TabyTab] = [.today, .chat, .tasks, .calendar, .notes, .mail, .messages]
  static let right: [TabyTab] = [.music, .agents, .mods, .notion, .network, .settings]

  /// Gespeicherte Reihenfolge; unbekannte und doppelte Namen fallen weg, fehlende Reiter
  /// (neue Versionen) hängen in Standardreihenfolge hinten an.
  static func ordered(_ saved: [String]) -> [TabyTab] {
    var seen = Set<TabyTab>()
    var out: [TabyTab] = []
    for raw in saved {
      guard let t = TabyTab(rawValue: raw), seen.insert(t).inserted else { continue }
      out.append(t)
    }
    for t in left + right where seen.insert(t).inserted { out.append(t) }
    return out
  }

  /// Sichtbare Reiter teilen: die erste Hälfte (aufgerundet) links der Notch, der Rest rechts.
  static func split(_ tabs: [TabyTab]) -> (left: [TabyTab], right: [TabyTab]) {
    let k = (tabs.count + 1) / 2
    return (Array(tabs.prefix(k)), Array(tabs.dropFirst(k)))
  }

  /// Leiste: alle sichtbaren Reiter außer den ausgeblendeten; die liegen unter „Mehr“.
  /// Einstellungen lassen sich nicht ausblenden, damit man sie immer erreicht.
  static func bar(_ visible: [TabyTab], hidden: [String]) -> (primary: [TabyTab], more: [TabyTab]) {
    let h = Set(hidden).subtracting([TabyTab.settings.rawValue])
    return (visible.filter { !h.contains($0.rawValue) }, visible.filter { h.contains($0.rawValue) })
  }

  /// Kleiner Punkt am Reiter: dort wartet etwas („Antwort nötig“ im Eingang, ungelesene Chats, Update am Zahnrad).
  static func needsAttention(_ t: TabyTab, state: AppState?) -> Bool {
    guard let s = state else { return false }
    switch t {
    case .settings: return s.update != nil
    case .mail: return s.inbox.contains { $0.channel == "Mail" && $0.kind == .needsReply }
    case .messages:
      return s.inbox.contains { $0.channel != "Mail" && $0.kind == .needsReply }
        || s.messengerConversations.contains { $0.unread > 0 }
    default: return false
    }
  }

  /// „Mehr“ ist hervorgehoben, wenn der gezeigte Reiter ausgeblendet ist.
  static func moreActive(current: TabyTab, hidden: [String], dayStartPrompt: Bool) -> Bool {
    current != .settings && hidden.contains(current.rawValue) && !dayStartPrompt
  }
}

/// Einheitlicher Symbolstil in der Leiste: nur Kontur-Symbole (Fill-Varianten fallen weg).
enum TabSymbol {
  static func name(_ t: TabyTab) -> String { t.symbol.replacingOccurrences(of: ".fill", with: "") }
}

private struct OpenBoard: View {
  @ObservedObject var store: IslandStore
  @ObservedObject var model: AppModel
  let ns: Namespace.ID
  let animateEntrance: Bool
  @State private var appeared: Bool
  @Namespace private var tabNS
  @Environment(\.tabyNow) private var nowEnv

  init(store: IslandStore, model: AppModel, ns: Namespace.ID, animateEntrance: Bool) {
    self.store = store; self.model = model; self.ns = ns; self.animateEntrance = animateEntrance
    _appeared = State(initialValue: !animateEntrance)
  }

  /// Reiter, über dem gerade ein gezogener Reiter schwebt (Hervorhebung).
  @State private var dropTarget: TabyTab?

  var body: some View {
    let g = store.geometry
    // Optionale Reiter (Netzwerk) erscheinen nur, wenn sie in den Einstellungen an sind.
    let settings = store.appState?.settings
    let visible = IslandExpansionRules.visible(OpenBoardTabs.ordered(settings?.tabOrder ?? []), settings: settings)
    let (primary, more) = OpenBoardTabs.bar(visible, hidden: settings?.hiddenTabs ?? [])
    let (left, right) = OpenBoardTabs.split(primary)
    let count = primary.count + (more.isEmpty ? 0 : 1)
    let w = IslandMetrics.tabButtonWidth(count: count, notchWidth: g.notchWidth)
    // Name neben dem aktiven Reiter nur, wenn die Leiste Platz hat (sonst Hilfetext wie bisher).
    let nameFits = IslandMetrics.activeLabelFits(store.tab.title, count: count, notchWidth: g.notchWidth)
    VStack(spacing: 0) {
      HStack(spacing: 4) {
        ForEach(Array(left.enumerated()), id: \.element) { i, t in tabButton(t, width: w, named: nameFits).stagger(appeared, i) }
        Spacer(minLength: g.notchWidth + 12)
        ForEach(Array(right.enumerated()), id: \.element) { i, t in
          tabButton(t, width: w, named: nameFits).stagger(appeared, left.count + i)
        }
        if !more.isEmpty { moreButton(more, width: w).stagger(appeared, primary.count) }
      }
      .padding(.horizontal, 22)
      .frame(height: IslandMetrics.bandHeight(g))

      card
        .padding(.horizontal, IslandMetrics.cardInset)
        .padding(.top, IslandMetrics.cardTopGap)
      Spacer(minLength: 0)
    }
    .onAppear {
      guard !appeared else { return }
      appeared = true
    }
  }

  private func tabButton(_ t: TabyTab, width: CGFloat, named: Bool) -> some View {
    let active = store.tab == t && store.appState?.dayStartPrompt != true
    let showName = active && named
    let attention = t == .agents && !model.agentRequests.isEmpty
      || (t != .agents && OpenBoardTabs.needsAttention(t, state: store.appState))
    return Button {
      store.selectTab(t)
    } label: {
      ZStack(alignment: .topTrailing) {
        HStack(spacing: 4) {
          Image(systemName: TabSymbol.name(t))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Color.white : Theme.secondary)
            .frame(width: width, height: 24)
          if showName {
            Text(t.title)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.white.opacity(0.92))
              .lineLimit(1).fixedSize()
              .padding(.trailing, 6)
          }
        }
        .background {
          if active {
            Capsule().fill(Color.white.opacity(0.17))
              .matchedGeometryEffect(id: "activeTab", in: tabNS)
          }
        }
        .overlay {
          if dropTarget == t { Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1) }
        }
        if t == .agents && !model.agentRequests.isEmpty {
          Circle().fill(MascotMood.alert.color).frame(width: 7, height: 7)
            .shadow(color: MascotMood.alert.color, radius: 3)
            .offset(x: -3, y: 1)
        } else if OpenBoardTabs.needsAttention(t, state: store.appState) {
          Circle().fill(MascotMood.idle.color).frame(width: 6, height: 6)
            .shadow(color: MascotMood.idle.color, radius: 3)
            .offset(x: -3, y: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(TabButtonStyle())
    .help(t == .settings && store.appState?.update != nil ? "Update verfügbar" : t.title)
    .accessibilityLabel(attention ? "Hier ist etwas zu tun: \(t.title)" : t.title)
    .accessibilityAddTraits(active ? .isSelected : [])
    .draggable(t.rawValue)
    .dropDestination(for: String.self) { items, _ in
      moveTab(items, onto: t)
    } isTargeted: { targeted in
      if targeted { dropTarget = t } else if dropTarget == t { dropTarget = nil }
    }
  }

  /// „Mehr“: Menü mit den in den Einstellungen ausgeblendeten Reitern.
  private func moreButton(_ more: [TabyTab], width: CGFloat) -> some View {
    let active = OpenBoardTabs.moreActive(current: store.tab, hidden: store.appState?.settings.hiddenTabs ?? [],
                                          dayStartPrompt: store.appState?.dayStartPrompt == true)
    return Menu {
      ForEach(more) { t in
        Button { store.selectTab(t) } label: { Label(t.title, systemImage: TabSymbol.name(t)) }
      }
      Divider()
      Button {
        SettingsEntry.show(.notch)
        store.selectTab(.settings)
      } label: { Label("Reiter anordnen …", systemImage: "slider.horizontal.3") }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.5))
        .frame(width: width, height: 24)
        .background {
          if active {
            Capsule().fill(Color.white.opacity(0.17))
              .matchedGeometryEffect(id: "activeTab", in: tabNS)
          }
        }
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Mehr")
    .accessibilityLabel("Mehr")
  }

  /// Zieht einen Reiter auf die Position des Ziel-Reiters und speichert die Reihenfolge.
  private func moveTab(_ items: [String], onto target: TabyTab) -> Bool {
    guard let raw = items.first, let from = TabyTab(rawValue: raw), from != target else { return false }
    var all = OpenBoardTabs.ordered(store.appState?.settings.tabOrder ?? [])
    guard let i = all.firstIndex(of: from) else { return false }
    all.remove(at: i)
    guard let j = all.firstIndex(of: target) else { return false }
    all.insert(from, at: j)
    dropTarget = nil
    Task {
      _ = await model.services.updateSettings(SettingsPatch(tabOrder: all.map(\.rawValue)), apiKey: nil)
      await model.refresh()
    }
    return true
  }

  private var card: some View {
    let mood = store.mood
    let state = store.appState
    let kind = IslandCardRules.kind(dayStart: state?.dayStartPrompt == true,
                                    dayEnd: state?.dayEndPrompt == true,
                                    weeklyReview: IslandCardRules.weeklyShown(state),
                                    meeting: store.meetingCard != nil)
    let title = kind.title(tab: store.tab)
    var lines: [String]
    switch kind {
    case .dayStart: lines = ["Bereit für den Tag?"]
    case .dayEnd: lines = ["Was bleibt offen?"]
    case .weeklyReview: lines = ["Rückblick & Ziele"]
    case .meeting:
      if let m = store.meetingCard {
        lines = [m.phase == .upcoming ? MeetingLogic.countdownLine(m, now: NowResolver.now(nowEnv))
                 : "Nachbereitung"]
      } else {
        lines = []
      }
    case .tab:
      lines = StatusRules.lines(tab: store.tab, state: state, agentRequests: model.agentRequests.count,
                                isThinking: model.isThinking)
    }
    if let focus = state?.focus, kind == .tab {
      lines = [FocusClock.statusLine(focus, now: Date())] + lines.prefix(1)
    }
    return HStack(alignment: .top, spacing: 14) {
      VStack(spacing: 6) {
        TabyMascot(mood: mood, size: 80, glow: true, play: store.mascotPlay, still: store.mascotStill,
                   gazeFrame: store.islandScreenRect)
          .contentShape(Rectangle())
          .onTapGesture { store.mascotTapped() }
          .matchedGeometryEffect(id: "mascot", in: ns)
          .mascotInteractions(store, drag: true)
        VStack(spacing: 1) {
          Text(title)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.opacity)
          ForEach(lines, id: \.self) { l in
            Text(l)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.5))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
        .multilineTextAlignment(.center)
        .stagger(appeared, 2)
        if kind == .tab {
          HStack(spacing: 6) { pinButton; windowButton; expandButton }.stagger(appeared, 4)
        }
      }
      .frame(width: IslandMetrics.sideColumnWidth)

      content(kind)
        .stagger(appeared, 3)
    }
    .padding(IslandMetrics.cardPadding)
    .background {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Color(shellHex: 0x0E0E10))
        // Leiser Schimmer in Stimmungsfarbe am unteren Rand: Kreisverlauf, auf Ellipse gestaucht
        // (kein Weichzeichner im Lauf; der Rand fällt auf Alpha 0 ab).
        Rectangle()
          .fill(RadialGradient(colors: [mood.color.opacity(0.26), mood.color.opacity(0)], center: .center,
                               startRadius: 0, endRadius: 260))
          .frame(width: 520, height: 520)
          .scaleEffect(y: 120 / 520)
          .frame(height: 120)
          .offset(y: 70)
          .animation(.easeInOut(duration: 0.5), value: mood)
      }
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
  }

  /// Aktuellen Reiter in einem eigenen Fenster öffnen (mehr Platz, frei größenverstellbar).
  private var windowButton: some View {
    Button { store.detachCurrentTab() } label: {
      Image(systemName: "macwindow")
    }
    .buttonStyle(RoundIconButtonStyle(size: 24))
    .padding(.top, 2)
    .foregroundStyle(Color.white.opacity(0.7))
    .help("In eigenem Fenster öffnen")
    .accessibilityLabel("In eigenem Fenster öffnen")
  }

  /// Insel anheften: bleibt offen, auch wenn man daneben klickt.
  private var pinButton: some View {
    Button { store.togglePinned() } label: {
      Image(systemName: store.pinned ? "pin.fill" : "pin")
    }
    .buttonStyle(RoundIconButtonStyle(size: 24))
    .padding(.top, 2)
    .foregroundStyle(store.pinned ? MascotMood.love.color : Color.white.opacity(0.7))
    .help(store.pinned ? "Lösen" : "Angeheftet halten")
    .accessibilityLabel(store.pinned ? "Lösen" : "Anheften")
  }

  /// Klein unter der Statuszeile: Reiterinhalt eingeklappt/ausgeklappt (je Reiter gemerkt).
  private var expandButton: some View {
    Button { store.toggleExpanded() } label: {
      Image(systemName: store.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
    }
    .buttonStyle(RoundIconButtonStyle(size: 24))
    .padding(.top, 2)
    .help(store.expanded ? "Verkleinern" : "Vergrößern")
    .accessibilityLabel(store.expanded ? "Verkleinern" : "Vergrößern")
  }

  @ViewBuilder private func content(_ kind: IslandCardKind) -> some View {
    let h = IslandMetrics.cardContentHeight(store.contentHeight, cap: store.contentCap)
    ZStack(alignment: .top) {
      Group {
        switch kind {
        case .dayStart:
          DayStartView().id("dayStart")
        case .dayEnd:
          DayEndView().id("dayEnd")
        case .weeklyReview:
          if let review = store.appState?.weeklyReview { WeeklyReviewView(review: review).id("weekly") }
        case .meeting:
          if let meeting = store.meetingCard {
            MeetingCardView(meeting: meeting, saved: store.meetingSaved,
                            onSaved: { store.showMeetingSaved($0) },
                            onDone: { store.closeMeetingCard() })
              .id("meeting")
          }
        case .tab:
          if let preview = store.previewContent {
            preview.id(store.tab)
          } else {
            TabContentView(tab: store.tab).id(store.tab)
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: TabLayout.contentWidth)
      // Listen dürfen im ausgeklappten Zustand mehr Höhe nutzen (CappedScroll liest den Wert).
      .environment(\.tabyContentCap, store.contentCap)
      .background(GeometryReader { geo in
        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
      })
      .transition(.blurSlide(store.tabDirection))
    }
    .frame(width: TabLayout.contentWidth, height: h, alignment: .top)
    .clipped()
    .onPreferenceChange(ContentHeightKey.self) { v in
      MainActor.assumeIsolated { store.setContentHeight(v) }
    }
  }
}

private struct TabButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.88 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
  }
}

private struct ContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Übergänge

private struct BlurSlide: ViewModifier {
  let progress: CGFloat
  let dx: CGFloat
  func body(content: Content) -> some View {
    content
      .blur(radius: 8 * progress)
      .opacity(1 - progress)
      .offset(x: dx * progress)
  }
}

extension AnyTransition {
  /// Reiterwechsel: weichzeichnen, ausblenden, seitlich gleiten (Richtung = Reiterreihenfolge).
  static func blurSlide(_ direction: CGFloat) -> AnyTransition {
    .asymmetric(
      insertion: .modifier(active: BlurSlide(progress: 1, dx: 22 * direction), identity: BlurSlide(progress: 0, dx: 0)),
      removal: .modifier(active: BlurSlide(progress: 1, dx: -22 * direction), identity: BlurSlide(progress: 0, dx: 0)))
  }
}

private struct Stagger: ViewModifier {
  let shown: Bool
  let index: Int
  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : -7)
      .blur(radius: shown ? 0 : 3)
      .animation(.spring(response: 0.42, dampingFraction: 0.8).delay(0.05 + Double(index) * 0.025), value: shown)
  }
}

extension View {
  fileprivate func stagger(_ shown: Bool, _ index: Int) -> some View { modifier(Stagger(shown: shown, index: index)) }
}
