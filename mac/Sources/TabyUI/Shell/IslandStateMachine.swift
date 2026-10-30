// Reiner Zustandsautomat der Insel (Idee aus Coucous IslandStateMachine,
// eigene Zustände). Keine Zeitgeber im Inneren: jede Eingabe bekommt `now`
// (Sekunden, monoton) und `tick(now:)` löst fällige Fristen aus. So lassen
// sich Hover-/Verlassen-Zeiten in ShellChecks ohne Warten prüfen.
import Foundation
import TabyCore

enum IslandMode: String, Equatable, CaseIterable {
  /// Notch + Flügel: kleines Maskottchen links, Statuspunkt rechts.
  case closed
  /// Maus über der geschlossenen Insel: etwas größer.
  case peek
  /// Board mit Reitern und Inhalt.
  case open
  /// Benachrichtigung: Karte mit Maskottchen, Titel, Text (~4 s).
  case flash
  /// Begrüßung beim Start (~2,6 s, Maskottchen winkt).
  case greeting
  /// Schnellerfassung: schmales Eingabefeld ohne Reiterleiste. Bleibt offen,
  /// bis fertig oder Esc; Mausverlassen schließt nicht.
  case capture

  /// Reihenfolge für "wächst" vs. "schrumpft" (Feder vs. Ease-Kurve).
  var rank: Int {
    switch self {
    case .closed: 0
    case .peek: 1
    case .greeting: 2
    case .flash: 3
    case .capture: 4
    case .open: 5
    }
  }
}

struct IslandTiming: Equatable {
  var greeting: Double = 2.6
  var flash: Double = 6.0
  /// Karte mit „Erledigt“ / „In 10 Min“ bleibt länger, bis man handelt.
  var flashWithActions: Double = 15.0
  /// Maus muss so lange auf der geschlossenen Insel liegen, bevor die Peek-Ansicht aufgeht.
  var peekDwell: Double = 0.15
  /// Maus hat die offene Insel verlassen → zuklappen nach …
  var leaveClose: Double = 0.7
  /// Maus hat die Peek-Insel verlassen (kleine Gnadenfrist gegen Flackern am Rand).
  var peekLeave: Double = 0.12
  /// Maus hat eine Flash-Karte verlassen, die sie angehalten hatte.
  var flashLeave: Double = 1.2
}

struct IslandStateMachine: Equatable {
  enum TimerAction: Equatable { case closeOpen, endFlash, endGreeting, endPeek, openPeek }

  private(set) var mode: IslandMode = .closed
  private(set) var tab: TabyTab = .today
  private(set) var flash: TabyNotification?
  private(set) var mouseInside = false
  private(set) var typing = false
  private(set) var agentPending = false
  /// Eine Frage (Tagesabschluss) wartet auf Antwort – Insel bleibt offen.
  private(set) var promptPending = false
  /// Nutzer hat die Insel angeheftet (bleibt offen, auch beim Klick nach außen).
  private(set) var pinned = false
  /// Laufende Arbeit (Scan, Mitschnitt): Insel bleibt von selbst offen.
  private(set) var busy = false
  private(set) var deadline: Double?
  private(set) var pending: TimerAction?
  var timing = IslandTiming()

  /// Offene Insel bleibt offen, solange getippt wird oder eine Freigabe wartet.
  var isHeldOpen: Bool { typing || agentPending || promptPending || pinned || busy }

  init(timing: IslandTiming = IslandTiming()) { self.timing = timing }

  // MARK: - Eingaben

  mutating func launch(now: Double) {
    set(.greeting)
    schedule(.endGreeting, at: now + timing.greeting)
  }

  mutating func mouseEntered(now: Double) {
    mouseInside = true
    switch mode {
    case .closed:
      schedule(.openPeek, at: now + timing.peekDwell)
    case .peek:
      cancel()
    case .open:
      if pending == .closeOpen { cancel() }
    case .flash:
      // Lesen lassen: die Karte bleibt, solange die Maus darauf liegt.
      cancel()
    case .greeting, .capture:
      break
    }
  }

  mutating func mouseLeft(now: Double) {
    mouseInside = false
    switch mode {
    case .closed:
      if pending == .openPeek { cancel() }
    case .greeting, .capture:
      // Schnellerfassung: das Feld hat den Fokus, also bleibt sie bis fertig/Esc.
      break
    case .peek:
      schedule(.endPeek, at: now + timing.peekLeave)
    case .open:
      if !isHeldOpen { schedule(.closeOpen, at: now + timing.leaveClose) }
    case .flash:
      if deadline == nil { schedule(.endFlash, at: now + timing.flashLeave) }
    }
  }

  /// Klick auf die Insel (geschlossen, Peek, Flash, Begrüßung → öffnen).
  mutating func click(now: Double) {
    guard mode != .open, mode != .capture else { return }
    open(tab: nil, now: now)
  }

  mutating func open(tab newTab: TabyTab?, now: Double) {
    if let newTab { tab = newTab }
    flash = nil
    cancel()
    set(.open)
  }

  mutating func close() {
    cancel()
    flash = nil
    pinned = false
    set(.closed)
  }

  mutating func toggle(now: Double) {
    if mode == .open || mode == .capture { close() } else { open(tab: nil, now: now) }
  }

  /// Schnellerfassung öffnen. Eine Freigabe-Anfrage hat Vorrang: dann bleibt
  /// das Board mit den Agenten offen und die Erfassung wird nicht geöffnet.
  mutating func openCapture(now: Double) {
    guard !agentPending else { return }
    flash = nil
    cancel()
    set(.capture)
  }

  mutating func selectTab(_ t: TabyTab) { tab = t }

  /// Benachrichtigung: poppt als Karte auf. Bei offener Insel bleibt das Board
  /// (die Hülle lässt dann nur das Maskottchen reagieren).
  mutating func showFlash(_ n: TabyNotification, now: Double) {
    guard mode != .open, mode != .capture else { return }
    flash = n
    set(.flash)
    if mouseInside { cancel() } else { schedule(.endFlash, at: now + flashDuration) }
  }

  /// Sichtdauer der aktuellen Karte: Aufgaben-Karten mit Knöpfen länger.
  var flashDuration: Double { flash?.taskId == nil ? timing.flash : timing.flashWithActions }

  /// Karte nach einem Knopfdruck schließen.
  mutating func dismissFlash() {
    guard mode == .flash else { return }
    cancel()
    flash = nil
    set(mouseInside ? .peek : .closed)
  }

  /// Claude-Code-Freigabe: zwingend offen auf dem Agenten-Reiter.
  mutating func agentRequest(now: Double) {
    agentPending = true
    open(tab: .agents, now: now)
  }

  mutating func agentRequestsCleared(now: Double) {
    agentPending = false
    reconsiderHold(now: now)
  }

  /// Tagesabschluss: öffnet die Insel und hält sie offen, bis beantwortet.
  mutating func setPromptPending(_ value: Bool, now: Double) {
    guard value != promptPending else { return }
    promptPending = value
    if value, mode != .open, mode != .capture { open(tab: nil, now: now) }
    reconsiderHold(now: now)
  }

  mutating func setPinned(_ value: Bool, now: Double) {
    guard value != pinned else { return }
    pinned = value
    if value, mode != .open, mode != .capture { open(tab: nil, now: now) }
    reconsiderHold(now: now)
  }

  mutating func setBusy(_ value: Bool, now: Double) {
    guard value != busy else { return }
    busy = value
    if value, mode != .open, mode != .capture { open(tab: nil, now: now) }
    reconsiderHold(now: now)
  }

  mutating func setTyping(_ value: Bool, now: Double) {
    guard value != typing else { return }
    typing = value
    reconsiderHold(now: now)
  }

  /// Fällige Fristen auslösen.
  mutating func tick(now: Double) {
    guard let d = deadline, now >= d, let action = pending else { return }
    cancel()
    switch action {
    case .closeOpen:
      if mode == .open, !isHeldOpen, !mouseInside { set(.closed) }
    case .endFlash:
      if mode == .flash { flash = nil; set(mouseInside ? .peek : .closed) }
    case .endGreeting:
      if mode == .greeting { set(mouseInside ? .peek : .closed) }
    case .endPeek:
      if mode == .peek, !mouseInside { set(.closed) }
    case .openPeek:
      if mode == .closed, mouseInside { set(.peek) }
    }
  }

  // MARK: - Intern

  private mutating func reconsiderHold(now: Double) {
    guard mode == .open else { return }
    if isHeldOpen {
      if pending == .closeOpen { cancel() }
    } else if !mouseInside, deadline == nil {
      schedule(.closeOpen, at: now + timing.leaveClose)
    }
  }

  private mutating func set(_ m: IslandMode) { mode = m }

  private mutating func schedule(_ a: TimerAction, at t: Double) {
    pending = a
    deadline = t
  }

  private mutating func cancel() {
    pending = nil
    deadline = nil
  }
}
