// Fenster der Notch-Insel. Öffentlicher Einstieg für den Integrator.
//
// Klick-Durchlässigkeit (Technik wie Coucou): Das Panel hat eine FESTE
// Übergröße (größer als die größte Insel) und wird nie animiert vergrößert –
// die Insel wächst nur innerhalb per SwiftUI. Damit die durchsichtige
// Restfläche keine Klicks schluckt, steht `ignoresMouseEvents` standardmäßig
// auf true. Mausbewegungen (globaler und lokaler Monitor, ohne Freigabe für
// Mausereignisse) prüfen die Inselform und schalten `ignoresMouseEvents` aus,
// solange die Maus darüber liegt; daraus folgt Hover-Betreten/-Verlassen. Im
// Leerlauf kostet das nichts, weil nur echte Bewegungen Arbeit machen. Ein
// Zeitgeber ruft `store.tick()` auf: 1 Hz bei zugeklappter Insel (Laufband,
// Timer-Text), 4 Hz sonst (Stimmung, Animationen) und prüft dabei auch die
// Form, falls die Insel unter einer ruhenden Maus wächst.
import AppKit
import Combine
import SwiftUI
import TabyCore

/// Rahmenloses, nicht aktivierendes Panel über der Menüleiste.
final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  /// Nicht von macOS unter die Menüleiste schieben lassen.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting-View, die schon den ersten Klick annimmt (Panel ist meist nicht key).
final class IslandHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
public final class IslandWindowController {
  /// Feste Panelgröße: breiter als die offene Insel samt Ohren und Schatten,
  /// höher als die höchste Insel (Reiterleiste + max. Inhalt + Polster).
  static let panelSize = CGSize(width: 760, height: 540)
  /// Takt des Zeitgebers: zugeklappt 1 Hz (Laufband, Timer-Text), sonst 4 Hz (Stimmung, Animationen).
  /// Maus weit weg und Insel geschlossen: 5× pro Sekunde nachsehen (billig). In der Nähe oder aktiv: 30×.
  /// Kein globaler Maus-Beobachter: der würde jede Mausbewegung des Systems an Lumi liefern und den Zeiger bremsen.
  private static let idlePoll = 0.2
  private static let busyPoll = 1.0 / 30
  /// Rand um die Insel, ab dem schneller nachgesehen wird (pt).
  private static let nearMargin: CGFloat = 80

  private let model: AppModel
  private let store: IslandStore
  private let panel: IslandPanel
  private let startWithGreeting: Bool
  private var pollTimer: Timer?
  private var pollInterval: Double = 0
  private var mouseInside = false
  private var keyMonitor: Any?
  private var clickMonitor: Any?
  private var localClickMonitor: Any?
  private var mouseNear = false
  private var lastPolledMouse = NSPoint.zero
  private var lastStoreTick: CFTimeInterval = 0
  /// Zuletzt berechnete Inselrechtecke; neu nur, wenn sich Größe, Modus, Geometrie oder Panel ändern.
  private struct RectKey: Equatable {
    var size: CGSize
    var mode: IslandMode
    var geometry: NotchGeometry
    var frame: NSRect
  }
  private var rectCache: (key: RectKey, exact: NSRect, hover: NSRect)?
  /// Insel liegt hinter den Fenstern (nach einem Klick in ein anderes Fenster bei offener Insel).
  private var lowered = false
  static let topLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
  private var screenObserver: NSObjectProtocol?
  private var shown = false

  public init(model: AppModel, startWithGreeting: Bool = true) {
    self.model = model
    self.startWithGreeting = startWithGreeting
    let located = NotchScreenLocator.current()
    store = IslandStore(model: model, geometry: located?.1 ?? .preview)
    panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = Self.topLevel
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovable = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    // Damit das lokale .mouseMoved-Monitoring auch über der offenen Insel Bewegungen sieht.
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none

    let hosting = IslandHostingView(rootView: IslandRootView(store: store))
    hosting.sizingOptions = []
    hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
    hosting.autoresizingMask = [.width, .height]
    panel.contentView = hosting

    store.onModeChange = { [weak self] old, new in self?.modeChanged(from: old, to: new) }
    // Suchtreffer öffnen ihren Reiter in der Notch.
    model.onOpenTab = { [weak self] tab in self?.store.open(tab: tab) }
    if let (screen, _) = located { place(on: screen) }
  }

  /// Panel zeigen und Abfrage starten (Begrüßung, falls gewünscht).
  /// Reiter in einem eigenen Fenster öffnen (Integrator setzt das).
  public var onDetachTab: ((TabyTab) -> Void)? {
    get { store.onDetachTab }
    set { store.onDetachTab = newValue }
  }

  public func show() {
    guard !shown else { return }
    shown = true
    store.greetingText = StatusRules.greeting(hour: Calendar.current.component(.hour, from: Date()))
    panel.orderFrontRegardless()
    observeScreens()
    installKeyMonitor()
    installClickMonitor()
    paceTimer()
    if startWithGreeting { store.launch() }
  }

  public func toggle() {
    store.toggle()
  }

  public func open(tab: TabyTab? = nil) {
    store.open(tab: tab)
  }

  public func close() {
    store.close()
  }

  /// Schnellerfassung zeigen: Panel wird key und das Eingabefeld bekommt den Fokus.
  /// Schließen mit Esc oder wenn die Erfassung fertig ist (dann Fokus zurück an die vorige App).
  public func openQuickCapture(prefill: String? = nil) {
    if !shown { show() }
    store.openCapture(prefill: prefill)
    guard store.mode == .capture else { return }
    panel.makeKeyAndOrderFront(nil)
    focusCaptureField(attemptsLeft: 30)
  }

  /// Merk-dir-das-Karte zeigen (Kontext der vorigen App); Esc oder ein Knopf schließt sie.
  public func openContextCapture(_ context: CapturedContext) {
    if !shown { show() }
    store.openContextCard(context)
    guard store.mode == .capture else { return }
    panel.makeKeyAndOrderFront(nil)
  }

  /// „Erklär mir das“-Karte zeigen (Ladezustand); `updateExplain` setzt danach Erklärung oder Fehler.
  public func openExplain(_ state: ExplainCardState) {
    if !shown { show() }
    store.openExplain(state)
    guard store.mode == .capture else { return }
    panel.makeKeyAndOrderFront(nil)
  }

  public func updateExplain(_ state: ExplainCardState) {
    store.updateExplain(state)
  }

  // MARK: - Fokus

  private func modeChanged(from old: IslandMode, to new: IslandMode) {
    if new == .open || new == .capture {
      // Für Texteingaben key werden, ohne die App zu aktivieren (nicht aktivierendes Panel).
      panel.makeKeyAndOrderFront(nil)
      if new == .capture { focusCaptureField(attemptsLeft: 30) }
    } else if old == .open || old == .capture {
      releaseKeyFocus()
    }
    // Schließen per Esc/Klick: sofort wieder klickdurchlässig und oben, nicht erst mit dem nächsten Takt.
    updateHover()
    paceTimer()
  }

  /// Das Eingabefeld der Erfassung zum ersten Responder machen. SwiftUI baut die Ansicht
  /// erst nach dem Moduswechsel auf, daher kurz nachfassen (ca. 30 ms je Versuch).
  private func focusCaptureField(attemptsLeft: Int) {
    guard store.mode == .capture else { return }
    if let field = firstEditableField(in: panel.contentView) {
      panel.makeFirstResponder(field)
      return
    }
    guard attemptsLeft > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
      MainActor.assumeIsolated { self?.focusCaptureField(attemptsLeft: attemptsLeft - 1) }
    }
  }

  private func firstEditableField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable, field.window === panel,
       !field.isHiddenOrHasHiddenAncestor {
      return field
    }
    for sub in view.subviews {
      if let field = firstEditableField(in: sub) { return field }
    }
    return nil
  }

  /// Tastaturfokus an die vorher aktive App zurückgeben (nie Fokus stehlen, solange zu).
  private func releaseKeyFocus() {
    guard panel.isKeyWindow else { return }
    panel.makeFirstResponder(nil)
    store.setTyping(false)
    if let front = NSWorkspace.shared.frontmostApplication,
       front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      front.activate()
    } else {
      panel.resignKey()
    }
  }

  /// Klick in ein anderes Fenster, während die Insel offen ist (angepinnt, Tippen, Agent wartet):
  /// die Insel rutscht hinter die Fenster und verdeckt nichts mehr. Kommt die Maus zurück zur
  /// Insel oder schließt sie, liegt sie wieder oben. Globale Mausereignisse brauchen keine Freigabe.
  private func installClickMonitor() {
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      DispatchQueue.main.async { self?.clickedElsewhere() }
    }
    localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      if event.window === self?.panel { MainActor.assumeIsolated { self?.raise() } }
      return event
    }
  }

  private func clickedElsewhere() {
    guard store.mode == .open || store.mode == .capture,
          !islandRects().hover.contains(NSEvent.mouseLocation) else { return }
    lowered = true
    panel.level = .normal
  }

  private func raise() {
    guard lowered else { return }
    lowered = false
    panel.level = Self.topLevel
    panel.orderFrontRegardless()
  }

  private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // ⌘1…⌘9 wählen die sichtbaren Reiter (nur bei offener Insel).
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
         let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
        let handled = MainActor.assumeIsolated { self?.store.selectTab(number: digit) ?? false }
        return handled ? nil : event
      }
      // ⌘⏎ hakt die Aufgabe der Benachrichtigungskarte ab (Return 36, Enter 76).
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
         event.keyCode == 36 || event.keyCode == 76 {
        let handled = MainActor.assumeIsolated { () -> Bool in
          guard let self, self.store.machine.flash?.taskId != nil else { return false }
          self.store.completeFlashTask()
          return true
        }
        return handled ? nil : event
      }
      // Esc (53) klappt zu (Board, Schnellerfassung, Flash, Begrüßung).
      guard event.keyCode == 53 else { return event }
      let handled = MainActor.assumeIsolated { () -> Bool in
        guard let self, self.store.mode != .closed else { return false }
        self.store.close()
        return true
      }
      return handled ? nil : event
    }
  }

  // MARK: - Bildschirm

  /// Panel oben mittig; hoch genug für die größte Insel (ausgeklappt, nach Bildschirmhöhe).
  private func place(on screen: NSScreen) {
    let sf = screen.frame
    let g = NotchScreenLocator.geometry(of: screen)
    let s = CGSize(width: Self.panelSize.width,
                   height: max(Self.panelSize.height, ceil(IslandMetrics.maxOpenHeight(screenHeight: sf.height,
                                                                                     geometry: g) + 20)))
    panel.setFrame(NSRect(x: sf.midX - s.width / 2, y: sf.maxY - s.height, width: s.width, height: s.height),
                   display: true)
  }

  private func observeScreens() {
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.relocate() }
    }
  }

  /// Bildschirm angesteckt/abgezogen, Deckel zu, Auflösung geändert → Insel umziehen.
  private func relocate() {
    guard let (screen, geometry) = NotchScreenLocator.current() else { return }
    store.setGeometry(geometry)
    place(on: screen)
  }

  // MARK: - Maus und Takt

  /// Maus über der Inselform? Dann nimmt das Panel Klicks an; Hover-Betreten/-Verlassen an den Automaten.
  private func updateHover() {
    let inside = islandRects().hover.contains(NSEvent.mouseLocation)
    if panel.ignoresMouseEvents != !inside {
      panel.ignoresMouseEvents = !inside
    }
    if inside != mouseInside {
      mouseInside = inside
      if inside { store.mouseEntered() } else { store.mouseLeft() }
      // Der Automat hat jetzt evtl. eine Frist (Peek in 0,15 s): schnell takten, sonst käme sie erst mit 1 Hz.
      paceTimer()
    }
    // Nähe zur Insel: ab hier schneller nachsehen; Bewegung über der offenen Insel hält das Maskottchen wach.
    let mouse = NSEvent.mouseLocation
    mouseNear = islandRects().hover.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(mouse)
    if mouse != lastPolledMouse {
      lastPolledMouse = mouse
      if inside, store.mode != .closed { store.noteMouseMoved() }
    }
    // Ein Klick auf die Insel holt sie nach vorn (wie bei jedem Fenster), bloßes Darüberfahren nicht.
    if store.mode == .closed { raise() }
  }

  /// Inselrechtecke (genau und mit Randzone) in Bildschirmkoordinaten (AppKit, Ursprung unten links).
  /// Zwischengespeichert: neu berechnet nur bei geänderter Größe, Modus, Geometrie oder Panelposition.
  private func islandRects() -> (exact: NSRect, hover: NSRect) {
    let key = RectKey(size: store.targetSize, mode: store.mode, geometry: store.geometry, frame: panel.frame)
    if let c = rectCache, c.key == key { return (c.exact, c.hover) }
    let ear = IslandMetrics.earRadius(key.mode)
    let exact = NSRect(x: key.frame.midX - key.size.width / 2 - ear, y: key.frame.maxY - key.size.height,
                       width: key.size.width + 2 * ear, height: key.size.height)
    let inset = IslandMetrics.hoverInset(mode: key.mode, geometry: key.geometry)
    let hover = exact.insetBy(dx: -inset, dy: -inset)
    rectCache = (key, exact, hover)
    store.setIslandScreenRect(exact)
    return (exact, hover)
  }

  private func paceTimer() {
    let idle = store.mode == .closed && !store.bumped && !mouseInside && !mouseNear && !store.hasDeadline
    schedulePoll(idle ? Self.idlePoll : Self.busyPoll)
  }

  private func schedulePoll(_ interval: Double) {
    guard interval != pollInterval || pollTimer == nil else { return }
    pollTimer?.invalidate()
    pollInterval = interval
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    t.tolerance = interval * 0.2
    RunLoop.main.add(t, forMode: .common)
    pollTimer = t
  }

  private func tick() {
    // Der Zustandsautomat läuft langsamer als die Mausabfrage: geschlossen 1×, sonst 4× pro Sekunde.
    let now = CACurrentMediaTime()
    let storeEvery = (store.mode == .closed && !store.bumped && !mouseInside) ? 1.0 : 0.25
    if now - lastStoreTick >= storeEvery {
      lastStoreTick = now
      store.tick()
    }
    // Ruhende Maus: nach jedem Takt prüfen, ob die Insel unter ihr gewachsen oder geschrumpft ist.
    updateHover()
    // Tippt jemand in ein Textfeld der Insel? (Feldeditor ist ein NSTextView.)
    let typing = panel.isKeyWindow && panel.firstResponder is NSTextView
    store.setTyping(typing)
    paceTimer()
  }
}
