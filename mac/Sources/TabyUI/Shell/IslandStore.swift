// Beobachtbarer Zustand der Insel: verbindet AppModel, den reinen Automaten
// und die SwiftUI-Ansicht. Kennt kein Fenster (das macht der Controller), damit
// die Ansicht auch ohne Fenster (Snapshots) läuft.
import AppKit
import Combine
import Foundation
import SwiftUI
import TabyCore

extension Animation {
  /// Öffnen/Wachsen (Coucou-Werte); bei Reduce Motion nur ein kurzes Ausblenden.
  static var islandOpen: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? .easeOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.72)
  }
  /// Schließen/Schrumpfen (Coucou-Werte); bei Reduce Motion nur ein kurzes Ausblenden.
  static var islandClose: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? .easeOut(duration: 0.15) : .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
  }
}

/// Sagt Text über VoiceOver, ohne den Tastaturfokus zu verschieben.
enum VoiceAnnounce {
  @MainActor static func say(_ text: String) {
    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}

@MainActor
final class IslandStore: ObservableObject {
  @Published private(set) var machine: IslandStateMachine
  @Published private(set) var geometry: NotchGeometry
  /// Gemessene natürliche Höhe des Reiterinhalts.
  @Published private(set) var contentHeight: CGFloat = 220
  /// Gemessene natürliche Höhe der Schnellerfassung (ohne Reiterleiste).
  @Published private(set) var captureHeight: CGFloat = 120
  /// Merk-dir-das-Karte; nil = normale Schnellerfassung.
  @Published private(set) var contextCard: CapturedContext?
  /// „Erklär mir das“-Karte; nil = keine.
  @Published private(set) var explain: ExplainCardState?
  @Published private(set) var mood: MascotMood = .idle
  /// Ausgeklappt: Reiterinhalt darf bis zur bildschirmabhängigen Grenze wachsen.
  @Published private(set) var expanded = false
  @Published private(set) var bumped = false
  /// Begrüßungstext (vom Controller nach Tageszeit gesetzt).
  @Published var greetingText = "Hallo!"
  /// Zählt Öffnungen hoch (gestaffeltes Einblenden startet neu).
  @Published private(set) var openSerial = 0
  /// Laufende Klick-Einlage des Maskottchens (springen, lachen, Überraschung).
  @Published private(set) var mascotPlay: MascotPlay?
  private var combo = MascotCombo()
  /// Jubel (Konfetti/Feuerwerk), der gerade über der Insel läuft.
  @Published private(set) var celebration: CelebrationBurst?
  /// Requisit (Briefumschlag, Laptop), das Lumi gerade hochhält.
  private(set) var mascotProp: MascotPropEvent?
  private(set) var bulbStart: Double?
  private var hoverStart: Double?
  /// Reaktionen beim Überfahren (Auswahl, Abstand) und ihr Takt-Task.
  private var hoverPicker = MascotHoverPicker()
  private var hoverTask: Task<Void, Never>?
  /// Mikro-Bewegungen zwischendurch (offen/Peek, nicht ruhend) und ihr Zufall (injizierbar).
  private var mascotLiveliness = MascotLiveliness()
  var mascotRandom: (Int) -> Int = { Int.random(in: 0..<$0) }
  private var dizzyStart: Double?
  private var pointerSamples: [MascotPointerSample] = []
  private var dragVector: CGSize?
  private var release: MascotRelease?
  private var burstSeed: UInt64 = 0
  /// Setzt die Figur nach einer Reaktion wieder auf ruhend (Neuzeichnen ohne Takt).
  private var mascotSettle: Task<Void, Never>?
  /// Wichtige, ungelesene Mails aus dem letzten Stand (nil = noch kein Stand).
  private var importantUnread: Set<String>?
  private var lastNoticeSerial = 0
  /// Offene Aufgaben für heute (heute fällig + überfällig) aus dem letzten Stand.
  private var openTodayCount: Int?
  /// Zeitpunkt einer erledigten Aufgabe (wartet auf den neuen Stand, um das Feuerwerk zu wählen).
  private var awaitingDone: Double?
  /// Zeitpunkt, zu dem die Liste heute leer wurde (vor der Rückmeldung).
  private var clearedTodayAt: Double?
  /// Lokales Datum "YYYY-MM-DD" und Stunde (Prüfungen dürfen das ersetzen).
  var localClock: () -> (date: String, hour: Int) = { IslandStore.systemLocalClock() }
  private var clockCache: (t: Double, value: (date: String, hour: Int))?
  /// Wanduhr (Zeitpunkt) für Termine, Timer und Musik; Prüfungen setzen sie fest.
  var wallClock: () -> Date = { Date() }

  static func systemLocalClock() -> (date: String, hour: Int) {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: Date())
    return (String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), c.hour ?? 12)
  }

  /// +1 = neuer Reiter liegt rechts vom alten, −1 = links (Richtung des Wechsels).
  @Published private(set) var tabDirection: CGFloat = 1
  /// Meeting-Karte: bleibt stehen, bis sie geschlossen oder mit „Fertig“ beendet wird.
  @Published private(set) var meetingCard: MeetingBrief? {
    didSet { syncPromptHold(with: appState) }
  }
  /// Rückmeldung nach dem Speichern der Stichpunkte (zeigt die Meeting-Karte weiter an).
  @Published private(set) var meetingSaved: String?
  /// Datei wird über die Insel gezogen (Overlay „Datei loslassen“).
  @Published private(set) var dropTargeted = false

  let model: AppModel
  /// Merkt den Ausklapp-Zustand je Reiter (Snapshots/Prüfungen: im Speicher).
  let expansion: IslandExpansionStore
  /// Nur Snapshots: Zustand, solange `model.state` noch nicht geladen ist
  /// (AppModel lädt asynchron, Snapshots rendern synchron).
  var previewState: AppState? {
    didSet { refreshDerived(appState) }
  }
  /// Nur Snapshots: Inhalt statt `TabContentView` (z. B. lange Liste für die Begrenzung).
  var previewContent: AnyView?
  var appState: AppState? { model.state ?? previewState }
  /// Monotone Uhr in Sekunden (injizierbar für Prüfungen).
  let now: () -> Double
  /// Wird nach jedem Moduswechsel gerufen (Controller: Tastaturfokus, Abfragerate).
  var onModeChange: ((IslandMode, IslandMode) -> Void)?
  /// Reiter in einem eigenen, frei vergrößerbaren Fenster öffnen (Controller setzt das).
  var onDetachTab: ((TabyTab) -> Void)?

  private var lastReaction: (UIReaction, Double)?
  private var lastActivity: Double
  /// Letzte Bedienung oder Mausbewegung über der offenen Insel (weckt das Maskottchen).
  private var lastInteraction: Double
  /// Maskottchen ruht (offene Insel, 10 s ohne Bedienung): stehendes Bild, kein Takt.
  @Published private(set) var mascotStill = false
  /// Inselfläche in Bildschirmkoordinaten (vom Fenster-Controller); bei offener Insel folgen
  /// Lumis Augen der Maus innerhalb dieser Fläche statt über den ganzen Bildschirm.
  @Published private(set) var islandScreenRect: CGRect?
  func setIslandScreenRect(_ r: CGRect) { if islandScreenRect != r { islandScreenRect = r } }
  private var bumpUntil: Double?
  private var bag: Set<AnyCancellable> = []
  private var seenFlashSerial: Int
  private var hadDayStartPrompt = false
  private var thinking = false
  private var announcedJoin: URL?

  init(model: AppModel, geometry: NotchGeometry = .preview, expansion: IslandExpansionStore = .standard,
       now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
    self.model = model
    self.geometry = geometry
    self.expansion = expansion
    self.now = now
    machine = IslandStateMachine()
    expanded = expansion.isExpanded(.today)
    lastActivity = now()
    lastInteraction = now()
    seenFlashSerial = model.flashSerial
    observe()
    refreshDerived(appState)
  }

  var mode: IslandMode { machine.mode }

  var tab: TabyTab { machine.tab }

  /// Höchstens sichtbare Inhaltshöhe: eingeklappt 380, ausgeklappt nach Bildschirmhöhe.
  var contentCap: CGFloat {
    IslandMetrics.contentCap(expanded: expanded, screenHeight: geometry.screenFrame.height)
  }

  /// Zwischengespeicherte zeitabhängige Anzeige (berechnet in `refreshDerived`, je Takt bzw. bei Zustandswechsel):
  /// Zeilen des Laufbands unter der Notch (leer = kein Band), nächster Konferenzbeitritt, Bedienknöpfe der Peek-Ansicht.
  @Published private(set) var tickerLines: [TickerLine] = []
  @Published private(set) var meetingJoin: MeetingJoin?
  @Published private(set) var peekActions: PeekActions?

  /// ⌘1…⌘9: wählt den n-ten sichtbaren Reiter (Leiste, ohne „Mehr“), nur bei offener Insel.
  @discardableResult func selectTab(number n: Int) -> Bool {
    guard machine.mode == .open else { return false }
    let settings = appState?.settings
    let visible = IslandExpansionRules.visible(OpenBoardTabs.ordered(settings?.tabOrder ?? []), settings: settings)
    let (primary, _) = OpenBoardTabs.bar(visible, hidden: settings?.hiddenTabs ?? [])
    guard primary.indices.contains(n - 1) else { return false }
    selectTab(primary[n - 1])
    return true
  }

  /// Zielgröße (ohne Ohren) des aktuellen Zustands.
  var targetSize: CGSize {
    IslandMetrics.size(mode: machine.mode, geometry: geometry, contentHeight: contentHeight, bumped: bumped,
                       captureHeight: captureHeight, contentCap: contentCap, ticker: !tickerLines.isEmpty,
                       peekControls: machine.mode == .peek && peekActions != nil)
  }

  // MARK: - Eingaben (Controller / Ansicht)

  func launch() { apply { $0.launch(now: now()) } }
  func mouseEntered() { activity(); apply { $0.mouseEntered(now: now()) } }
  /// Nur Snapshots/Prüfungen: die Verweilzeit bis zur Peek-Ansicht als verstrichen annehmen.
  func skipPeekDwellForPreview() { apply { $0.tick(now: self.now() + IslandTiming().peekDwell) } }
  func mouseLeft() { apply { $0.mouseLeft(now: now()) } }
  func click() { activity(); apply { $0.click(now: now()) } }
  func open(tab: TabyTab?) { activity(); apply { $0.open(tab: tab, now: now()) } }
  func close() { contextCard = nil; explain = nil; apply { $0.close() } }

  /// Aufgaben-Karte: „Erledigt“ (⌘⏎ oder Knopf) schließt die Karte und hakt die Aufgabe ab.
  func completeFlashTask() {
    guard let id = machine.flash?.taskId else { return }
    apply { $0.dismissFlash() }
    Task { _ = await model.services.completeTask(id) }
  }

  /// Aufgaben-Karte: „Ich arbeite daran“ startet den Fokus mit der Aufgabe und schließt die Karte.
  func workOnFlashTask() {
    guard let id = machine.flash?.taskId else { return }
    apply { $0.dismissFlash() }
    Task { _ = await model.services.startFocus(taskId: id, minutes: nil); await model.refresh() }
  }

  /// Zeit-um-Karte: „Noch X Min“ verlängert die Arbeit an der Aufgabe, die übrigen Aufgaben rücken nach.
  func extendFlashTask(minutes: Int) {
    guard let id = machine.flash?.taskId else { return }
    apply { $0.dismissFlash() }
    Task { _ = await model.services.startFocus(taskId: id, minutes: minutes); await model.refresh() }
  }

  /// Aufgaben-Karte: „In 10 Min“ verschiebt die Fälligkeit und schließt die Karte.
  func snoozeFlashTask() {
    guard let id = machine.flash?.taskId else { return }
    apply { $0.dismissFlash() }
    let due = ReminderText.snoozeDue(now: wallClock())
    Task { _ = await model.services.updateTask(id, TaskPatch(due: due)) }
  }
  /// Insel anheften/lösen (Pin-Knopf).
  func setPinned(_ v: Bool) { activity(); apply { $0.setPinned(v, now: now()) } }
  func togglePinned() { setPinned(!machine.pinned) }
  func detachCurrentTab() { onDetachTab?(machine.tab) }
  /// Laufende Arbeit hält die Insel offen (Scan, Mitschnitt); Kern meldet das.
  func setBusy(_ v: Bool) { apply { $0.setBusy(v, now: now()) } }
  var pinned: Bool { machine.pinned }
  /// Schnellerfassung öffnen (Esc bzw. `QuickCaptureView`s onDone schließen sie wieder).
  /// `prefill`: Text, der im Eingabefeld erscheint (z. B. aus Diktat oder markiertem Text).
  func openCapture(prefill: String? = nil) {
    contextCard = nil
    explain = nil
    if let prefill { model.captureDraft = prefill }
    activity()
    apply { $0.openCapture(now: now()) }
  }
  /// Merk-dir-das-Karte in der Schnellerfassung zeigen (statt des Eingabefelds).
  func openContextCard(_ context: CapturedContext) {
    contextCard = context
    activity()
    apply { $0.openCapture(now: now()) }
  }
  /// Erklär-mir-das-Karte in der Schnellerfassung zeigen (Ladezustand, dann Antwort).
  func openExplain(_ state: ExplainCardState) {
    contextCard = nil
    explain = state
    activity()
    apply { $0.openCapture(now: now()) }
  }
  /// Stand der Erklär-Karte ersetzen; ist sie geschlossen, bleibt sie zu.
  func updateExplain(_ state: ExplainCardState) {
    guard explain != nil else { return }
    explain = state
  }
  func toggle() { activity(); apply { $0.toggle(now: now()) } }
  func setTyping(_ v: Bool) {
    guard v != machine.typing else { return }
    apply { $0.setTyping(v, now: now()) }
  }

  func selectTab(_ t: TabyTab) {
    guard t != machine.tab else { return }
    activity()
    let all = TabyTab.allCases
    tabDirection = (all.firstIndex(of: t) ?? 0) >= (all.firstIndex(of: machine.tab) ?? 0) ? 1 : -1
    apply { $0.selectTab(t) }
  }

  /// Ausklappen/Einklappen des aktuellen Reiters (wird je Reiter gemerkt).
  func toggleExpanded() {
    activity()
    let on = !expanded
    expansion.setExpanded(machine.tab, on)
    withAnimation(.islandOpen) { expanded = on }
  }

  /// Datei über der Insel: öffnet sie (Chat), damit das Overlay sichtbar ist.
  func setDropTargeted(_ v: Bool) {
    guard v != dropTargeted else { return }
    withAnimation(.easeOut(duration: 0.15)) { dropTargeted = v }
    if v, machine.mode != .open, machine.mode != .capture {
      activity()
      apply { $0.open(tab: .chat, now: now()) }
    }
  }

  /// Dateien losgelassen: Chat zeigen und das Modell lesen lassen.
  func handleDrop(paths: [String]) {
    setDropTargeted(false)
    let files = DropLogic.limited(paths)
    guard !files.isEmpty else { return }
    open(tab: .chat)
    Task { await model.ingestFiles(files) }
  }

  /// Meeting-Karte: Stichpunkte gespeichert, Rückmeldung zeigen.
  func showMeetingSaved(_ text: String) { meetingSaved = text }

  /// Meeting-Karte schließen (Schließen, Überspringen oder Fertig).
  func closeMeetingCard() {
    meetingSaved = nil
    meetingCard = nil
  }

  /// Nur Snapshots: Meeting-Karte ohne Modellzustand zeigen.
  func previewMeeting(_ m: MeetingBrief, saved: String? = nil) {
    meetingSaved = saved
    meetingCard = m
  }

  /// Maskottchen angeklickt: 1. springen, 2. lachen, 3. zufällige Überraschung.
  func mascotTapped() {
    activity()
    let t = now()
    let action = combo.tap(at: t)
    mascotPlay = MascotPlay(action: action, startedAt: t)
    settleMascot(after: action.duration)
  }

  private func settleMascot(after seconds: Double) {
    mascotSettle?.cancel()
    mascotSettle = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds + 0.05))
      guard !Task.isCancelled else { return }
      // Einlage vorbei: ohne laufende Einlage ruht die Figur (kein Takt mehr, siehe MascotPace).
      self?.mascotPlay = nil
      self?.objectWillChange.send()
    }
  }

  /// Maus über dem Maskottchen: nach 0,3 s eine Reaktion, dann höchstens alle 2,5 s (Streicheln nach 0,8 s).
  func mascotHover(_ inside: Bool) {
    if !inside {
      hoverStart = nil
      pointerSamples = []
      hoverTask?.cancel()
      hoverTask = nil
    } else if hoverStart == nil {
      hoverStart = now()
      hoverTask?.cancel()
      // Eine Reaktion je Drüberfahren; danach folgt Lumi nur noch der Maus (kein Durchlauf aller Einlagen).
      hoverTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(MascotHoverPicker.startDelay))
        guard !Task.isCancelled, let self else { return }
        let t = self.now()
        if self.machine.mode != .closed, let action = self.hoverPicker.pick(at: t) {
          self.mascotPlay = MascotPlay(action: action, startedAt: t)
          self.settleMascot(after: action.duration)
        }
      }
    }
  }

  /// Mauspunkt über dem Maskottchen: schnelles Hin und Her macht Lumi schwindelig.
  func mascotPointer(x: CGFloat) {
    let t = now()
    pointerSamples = (pointerSamples + [MascotPointerSample(t: t, x: x)]).filter { t - $0.t <= MascotShake.window }
    if MascotShake.isDizzy(pointerSamples, now: t) {
      dizzyStart = t
      hoverStart = nil
      hoverTask?.cancel()
      hoverTask = nil
      pointerSamples = []
    }
  }

  /// Maskottchen wird gezogen (Versatz seit Beginn der Geste).
  func mascotDrag(_ v: CGSize) { dragVector = v }

  /// Loslassen: der Körper federt zurück.
  func mascotDragEnded() {
    if let v = dragVector { release = MascotRelease(startedAt: now(), vector: v) }
    dragVector = nil
  }

  /// Momentaufnahme für das Maskottchen zur Store-Uhr `t` (Tageszeit, Fokus, Ereignisse …).
  func mascotContext(at t: Double) -> MascotContext {
    // Datum und Stunde ändern sich nur minütlich: höchstens einmal pro Sekunde abfragen.
    let local: (date: String, hour: Int)
    if let c = clockCache, t >= c.t, t - c.t < 1 {
      local = c.value
    } else {
      local = localClock()
      clockCache = (t, local)
    }
    let s = appState
    return MascotContext(
      islandOpen: machine.mode == .open, typing: machine.typing, focus: s?.focus?.phase,
      daypart: .at(hour: local.hour),
      decor: MascotDecor.for(date: local.date, birthday: s?.settings.birthday ?? "",
                             enabled: s?.settings.seasonalDecor ?? false),
      prop: mascotProp, bulbStart: bulbStart, hoverStart: hoverStart, dizzyStart: dizzyStart,
      drag: dragVector, release: release, micro: mascotStill ? nil : mascotLiveliness.show(at: t))
  }

  /// Jubel starten (Konfetti oder Feuerwerk) und Lumi hüpft dazu.
  func celebrate(_ kind: CelebrationBurst.Kind) {
    burstSeed &+= 1
    celebration = CelebrationBurst(kind: kind, startedAt: now(), seed: burstSeed)
    mascotPlay = MascotPlay(action: .jump, startedAt: now())
    settleMascot(after: MascotAction.jump.duration)
  }

  func setGeometry(_ g: NotchGeometry) {
    guard g != geometry else { return }
    geometry = g
  }

  func setContentHeight(_ h: CGFloat) {
    let cap = contentCap
    let c = IslandMetrics.clampContent(h, cap: cap)
    guard abs(c - IslandMetrics.clampContent(contentHeight, cap: cap)) > 0.5 else {
      contentHeight = h
      return
    }
    withAnimation(.islandOpen) { contentHeight = h }
  }

  func setCaptureHeight(_ h: CGFloat) {
    let c = IslandMetrics.captureContentHeight(h)
    guard abs(c - IslandMetrics.captureContentHeight(captureHeight)) > 0.5 else {
      captureHeight = h
      return
    }
    withAnimation(.islandOpen) { captureHeight = h }
  }

  /// Fristen auslösen und Stimmung nachführen (Controller ruft das im Takt: 1 Hz zu, 4 Hz offen).
  func tick() {
    let t = now()
    apply { $0.tick(now: t) }
    if let until = bumpUntil, t >= until {
      bumpUntil = nil
      withAnimation(.islandClose) { bumped = false }
    }
    // Termin beginnt, Musik startet oder Laufband ändert sich ohne neuen Stand: neu berechnen.
    refreshDerived(appState)
    let still = machine.mode == .open && t - lastInteraction >= Self.mascotStillAfter
    if still != mascotStill { mascotStill = still }
    mascotLiveliness.tick(now: t, active: (machine.mode == .open || machine.mode == .peek) && !still,
                          random: mascotRandom)
    // Konferenz-Beitreten erscheint: einmal ansagen (je Link).
    if meetingJoin?.url != announcedJoin {
      announcedJoin = meetingJoin?.url
      if let join = meetingJoin { VoiceAnnounce.say("Beitreten: \(join.title), \(join.time)") }
    }
    updateMood()
  }

  /// Zeitabhängige Anzeige einmal je Takt bzw. bei Zustandswechsel berechnen; Ansichten lesen nur das Ergebnis.
  /// Veröffentlicht nur geänderte Werte. Die Uhr wird hier und nur hier gelesen.
  private func refreshDerived(_ s: AppState?) {
    let now = wallClock()
    let join = StatusRules.meetingJoin(state: s, now: now)
    let lines = StatusRules.tickerLines(state: s, today: localClock().date, now: now, join: join)
    let peek = StatusRules.peekActions(state: s, join: join)
    if meetingJoin != join { meetingJoin = join }
    if tickerLines != lines { tickerLines = lines }
    if peekActions != peek { peekActions = peek }
  }

  // MARK: - Intern

  private func activity() { lastActivity = now(); interact() }

  /// Offene Insel: ohne Mausbewegung oder Bedienung seit so vielen Sekunden ruht das Maskottchen.
  static let mascotStillAfter: Double = 10

  /// Bedienung oder Mausbewegung: weckt das ruhende Maskottchen sofort.
  private func interact() {
    lastInteraction = now()
    if mascotStill { mascotStill = false }
  }

  /// Mausbewegung (Controller): zählt nur über der offenen Insel.
  /// Der Automat wartet auf eine Frist (Peek öffnen, Schließen, Flash-Ende): der Takt muss schnell laufen.
  var hasDeadline: Bool { machine.deadline != nil }

  func noteMouseMoved() {
    guard machine.mode == .open else { return }
    interact()
  }

  /// Automat ändern und den Moduswechsel passend animieren
  /// (wachsen = Feder, schrumpfen = Ease-Kurve).
  private func apply(_ f: (inout IslandStateMachine) -> Void) {
    var m = machine
    f(&m)
    guard m != machine else { return }
    let old = machine.mode
    // Je Reiter gemerkt: beim Reiterwechsel gilt der Ausklapp-Zustand des neuen Reiters.
    let nextExpanded = m.tab != machine.tab ? expansion.isExpanded(m.tab) : expanded
    if m.mode != old {
      let grows = m.mode.rank > old.rank
      if m.mode == .open { openSerial += 1 }
      withAnimation(grows ? .islandOpen : .islandClose) { machine = m; expanded = nextExpanded }
      onModeChange?(old, m.mode)
    } else if m.tab != machine.tab {
      withAnimation(.islandOpen) { machine = m; expanded = nextExpanded }
    } else {
      machine = m
    }
    updateMood()
  }

  private func observe() {
    model.$agentRequests
      .map { !$0.isEmpty }
      .removeDuplicates()
      .sink { [weak self] pending in
        guard let self else { return }
        self.activity()
        if pending { VoiceAnnounce.say("Freigabe nötig") }
        self.apply { pending ? $0.agentRequest(now: self.now()) : $0.agentRequestsCleared(now: self.now()) }
      }
      .store(in: &bag)

    model.$flashSerial
      .sink { [weak self] serial in
        guard let self, serial != self.seenFlashSerial else { return }
        self.seenFlashSerial = serial
        guard let n = self.model.flash else { return }
        self.activity()
        VoiceAnnounce.say("\(n.title). \(n.body)")
        self.apply { $0.showFlash(n, now: self.now()) }
      }
      .store(in: &bag)

    model.$reaction
      .compactMap { $0 }
      .sink { [weak self] pulse in
        guard let self else { return }
        self.activity()
        self.lastReaction = (pulse.reaction, self.now())
        if self.machine.mode == .closed || self.machine.mode == .peek {
          self.bumpUntil = self.now() + 0.45
          withAnimation(.islandOpen) { self.bumped = true }
        }
        if pulse.reaction == .taskCompleted { self.taskDone() }
        self.updateMood()
      }
      .store(in: &bag)

    model.$isThinking
      .removeDuplicates()
      .sink { [weak self] thinking in
        // Der Sink läuft vor dem Setzen (willSet) → Wert merken statt nachlesen.
        guard let self else { return }
        // Antwort angekommen: Glühbirne über dem Kopf.
        if self.thinking && !thinking { self.bulbStart = self.now() }
        self.thinking = thinking
        self.activity()
        self.updateMood()
      }
      .store(in: &bag)

    // Claude-Code-Meldung: Lumi hält kurz einen Laptop hoch.
    model.$claudeNoticeSerial
      .sink { [weak self] serial in
        guard let self, serial != self.lastNoticeSerial else { return }
        self.lastNoticeSerial = serial
        self.mascotProp = MascotPropEvent(prop: .laptop, startedAt: self.now())
      }
      .store(in: &bag)

    // Ausgeblendeter Reiter (z. B. Netzwerk nach dem Ausschalten): zurück zu Heute.
    model.$state
      .sink { [weak self] newState in
        // Der Sink läuft vor dem Setzen: den neuen Stand übergeben statt `appState` zu lesen.
        self?.refreshDerived(newState ?? self?.previewState)
      }
      .store(in: &bag)

    model.$state
      .sink { [weak self] newState in
        guard let self, let settings = newState?.settings else { return }
        let fallback = IslandExpansionRules.fallbackTab(self.machine.tab, settings: settings)
        if fallback != self.machine.tab { self.apply { $0.selectTab(fallback) } }
      }
      .store(in: &bag)

    model.$state
      .map { $0?.dayStartPrompt == true }
      .removeDuplicates()
      .sink { [weak self] prompt in
        guard let self else { return }
        if prompt && !self.hadDayStartPrompt { self.apply { $0.open(tab: nil, now: self.now()) } }
        self.hadDayStartPrompt = prompt
      }
      .store(in: &bag)

    // Tagesabschluss, Wochenplanung und Meeting: öffnen und offen halten, bis beantwortet.
    // (Der Sink läuft vor dem Setzen; deshalb wird der neue Zustand übergeben.)
    model.$state
      .sink { [weak self] newState in
        guard let self else { return }
        if let s = newState { self.observeMascotEvents(s) }
        if let m = newState?.meeting, m != self.meetingCard {
          self.meetingSaved = nil
          self.meetingCard = m
        }
        self.syncPromptHold(with: newState)
        self.setBusy(IslandCardRules.isBusy(newState))
      }
      .store(in: &bag)
  }

  /// Neue wichtige Mail → Briefumschlag; leere Liste für heute nach einer Aufgabe → Feuerwerk.
  func observeMascotEvents(_ s: AppState) {
    let important = Set((s.mail?.messages ?? []).filter { $0.category == .important && !$0.read }.map(\.id))
    if let prev = importantUnread, !important.subtracting(prev).isEmpty {
      mascotProp = MascotPropEvent(prop: .envelope, startedAt: now())
    }
    importantUnread = important

    let open = s.overview.todayTasks.count + s.overview.overdueTasks.count
    if let prev = openTodayCount, prev > 0, open == 0 {
      if let a = awaitingDone, now() - a < 4 {
        awaitingDone = nil
        celebrate(.fireworks)
      } else {
        clearedTodayAt = now()
      }
    }
    openTodayCount = open
  }

  /// Aufgabe erledigt: Konfetti, bei der letzten Aufgabe für heute stattdessen Feuerwerk.
  private func taskDone() {
    if let c = clearedTodayAt, now() - c < 4 {
      clearedTodayAt = nil
      celebrate(.fireworks)
    } else {
      awaitingDone = now()
      celebrate(.confetti)
    }
  }

  /// Hält die Insel offen, solange eine Frage (Feierabend, Wochenplanung, Meeting) offen ist.
  private func syncPromptHold(with state: AppState?) {
    let held = IslandCardRules.promptHeld(dayEnd: state?.dayEndPrompt == true,
                                          weeklyReview: IslandCardRules.weeklyShown(state),
                                          meeting: meetingCard != nil)
    apply { $0.setPromptPending(held, now: self.now()) }
  }

  func updateMood() {
    let t = now()
    let m = MoodRules.derive(
      agentPending: machine.agentPending, isThinking: thinking,
      reaction: lastReaction?.0, reactionAge: lastReaction.map { t - $0.1 },
      flashActive: machine.mode == .flash, idleFor: t - lastActivity, islandOpen: machine.mode == .open)
    if m != mood { mood = m }
  }
}
