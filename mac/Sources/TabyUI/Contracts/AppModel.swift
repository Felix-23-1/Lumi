// VERTRAG (nur Orchestrator ändert).
// Gemeinsamer Zustand der Oberfläche. Die Insel-Hülle (Shell/) und die
// Ansichten (Views/) lesen ihn per `@EnvironmentObject var model: AppModel`.
import Foundation
import SwiftUI
import TabyCore

/// Kleine Rückmeldungen der Ansichten an die Hülle, damit das Maskottchen
/// reagiert (z. B. Aufgabe erledigt → freut sich).
public enum UIReaction: Equatable, Sendable {
  case taskCompleted
  case itemAdded
  case itemDeleted
  case failed(String)
  case celebrate
}

public struct ReactionPulse: Equatable, Sendable {
  public let reaction: UIReaction
  /// Hochzählender Zähler, damit gleiche Reaktionen nacheinander auslösen.
  public let serial: Int
}

@MainActor
public final class AppModel: ObservableObject {
  public let services: TabyServices

  @Published public private(set) var state: AppState? {
    didSet { undoStateChanged(old: oldValue, new: state) }
  }
  /// Rückgängig-Hinweis („Aufgabe gelöscht – Rückgängig“): erscheint nach einer Änderung und verschwindet nach
  /// `undoBannerDuration` Sekunden von selbst, damit er die Sicht nicht verdeckt. Der Schritt bleibt rückgängig-bar.
  @Published public private(set) var undoBannerLabel: String?
  public var undoBannerDuration: Double = 6
  private var undoBannerTask: Task<Void, Never>?
  @Published public private(set) var briefing: Briefing?
  /// Offene Claude-Code-Freigaben (Kern lässt höchstens eine gleichzeitig zu).
  @Published public private(set) var agentRequests: [AgentPermissionRequest] = []
  /// Letzte Benachrichtigung (die Hülle poppt dafür kurz auf).
  @Published public private(set) var flash: TabyNotification?
  /// Notiz, die der Reiter „Notizen“ beim Öffnen aufklappen soll (z. B. Termin-Notiz).
  @Published public var focusedNoteId: String?
  /// Aufgabe, die der Reiter „Aufgaben“ beim Öffnen zeigen soll (z. B. aus der Suche): Filter weg, hinscrollen, kurz hervorheben.
  @Published public var focusedTaskId: String?
  @Published public private(set) var flashSerial = 0
  /// Modell denkt gerade (Chat) — das Maskottchen denkt mit.
  @Published public var isThinking = false
  @Published public private(set) var reaction: ReactionPulse?
  /// Zählt Claude-Code-Meldungen hoch (das Maskottchen hält dann einen Laptop hoch).
  @Published public private(set) var claudeNoticeSerial = 0
  /// Text für die Schnellerfassung (QuickCaptureView übernimmt ihn und setzt ihn auf nil).
  @Published public var captureDraft: String?
  /// Sprechen läuft gerade (Schnellerfassung zeigt das Mikrofon an).
  @Published public internal(set) var listening = false
  /// Live-Text der Spracherkennung.
  @Published public internal(set) var transcript = ""
  /// Tastenkürzel, die macOS nicht belegen ließ (schon von einer anderen App vergeben); App-Ebene setzt sie.
  @Published public var shortcutConflicts: [String] = []
  /// Wird für jedes Kern-Ereignis aufgerufen (die Hülle öffnet z. B. bei
  /// einer Freigabe-Anfrage die Insel).
  public var onEvent: ((AppEvent) -> Void)?
  /// Öffnet einen Reiter in einem eigenen, frei großziehbaren Fenster (App-Ebene).
  public var onDetach: ((TabyTab) -> Void)?
  /// Öffnet einen Reiter in der Notch (z. B. aus einem Suchtreffer); die Hülle setzt das.
  public var onOpenTab: ((TabyTab) -> Void)?
  /// Öffnet den Einrichtungs-Assistenten (Einstellungen → Allgemein → „Einrichtung öffnen“); die App setzt das.
  public var onOpenOnboarding: (() -> Void)?

  private var reactionSerial = 0

  public init(services: TabyServices) {
    self.services = services
    services.subscribe { [weak self] event in
      self?.handle(event)
    }
  }

  /// Für Vorschau-Bilder und Prüfungen: Zustand sofort da (Bilder werden synchron gezeichnet und können
  /// das asynchrone Laden nicht abwarten).
  public convenience init(services: TabyServices, preloaded: AppState) {
    self.init(services: services)
    self.state = preloaded
  }

  /// Neue Änderung → Hinweis zeigen und nach Ablauf ausblenden; „Rückgängig“ (Stapel wird kleiner) blendet sofort aus.
  /// shortcut: erkannt über Text und Stapelgröße; zwei gleiche Texte bei vollem Stapel (10) zeigen den Hinweis nicht neu.
  private func undoStateChanged(old: AppState?, new: AppState?) {
    let (oldLabel, oldCount) = (old?.undoLabel, old?.undoLabels.count ?? 0)
    let (newLabel, newCount) = (new?.undoLabel, new?.undoLabels.count ?? 0)
    guard newLabel != oldLabel || newCount != oldCount else { return }
    undoBannerTask?.cancel()
    guard let label = newLabel, newCount >= oldCount else { undoBannerLabel = nil; return }
    undoBannerLabel = label
    undoBannerTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(self?.undoBannerDuration ?? 6))
      guard !Task.isCancelled else { return }
      self?.undoBannerLabel = nil
    }
  }

  /// Läuft schon ein Neuladen, wird nur ein weiteres danach angehängt: viele
  /// `stateChanged` kurz hintereinander kosten so höchstens zwei `state()`-Aufrufe
  /// (die jeweils alle Kalender abfragen). Jeder Aufrufer wartet, bis ein Lauf fertig
  /// ist, der nach seinem Aufruf begonnen hat.
  public func refresh() async {
    refreshDirty = true
    if let running = refreshTask { await running.value; return }
    let task = Task { @MainActor in
      while refreshDirty {
        refreshDirty = false
        // Nur veröffentlichen, wenn sich etwas geändert hat: sonst zeichnen alle Ansichten neu.
        let fresh = await services.state()
        if fresh != state { state = fresh }
      }
      refreshTask = nil  // ohne Unterbrechung nach der letzten Prüfung (Hauptthread)
    }
    refreshTask = task
    await task.value
  }

  private var refreshTask: Task<Void, Never>?
  private var refreshDirty = false

  public func react(_ r: UIReaction) {
    reactionSerial += 1
    reaction = ReactionPulse(reaction: r, serial: reactionSerial)
  }

  /// Kurze Benachrichtigung über die Insel (z. B. Fehler).
  public func showFlash(_ n: TabyNotification) {
    flash = n
    flashSerial += 1
  }

  /// In die Notch gezogene Dateien, bis der Nutzer im Chat sagt, was damit passieren soll.
  @Published public var droppedFiles: [String] = []

  /// Dateien ablegen (höchstens drei); der Chat fragt dann, was damit passieren soll.
  public func ingestFiles(_ paths: [String]) async {
    let files = DropLogic.limited(paths)
    guard !files.isEmpty else { return }
    droppedFiles = files
  }

  /// Abgelegte Dateien übernehmen (danach ist die Ablage leer).
  public func takeDroppedFiles() -> [String] {
    defer { droppedFiles = [] }
    return droppedFiles
  }

  /// Abgelegte Dateien ohne Modell als Notizen speichern; Titel z. B. „Termin – datei.pdf“.
  /// Eine Notiz mit dem Termin-Titel erscheint in der Meeting-Karte dieses Termins.
  public func saveDroppedFilesAsNotes(titlePrefix: String?) async {
    var firstError: String?
    var saved = 0
    for path in takeDroppedFiles() {
      let url = URL(fileURLWithPath: path)
      let name = url.lastPathComponent
      do {
        let text = try FileTextExtractor.extract(url)
        let title = titlePrefix.map { "\($0) – \(name)" } ?? name
        if case .ok = await services.addNote(title: title, content: text) { saved += 1 }
      } catch {
        if firstError == nil { firstError = "„\(name)“ konnte ich nicht lesen." }
      }
    }
    await refresh()
    if let firstError {
      react(.failed(firstError))
      showFlash(TabyNotification(title: "Datei nicht gelesen", body: firstError))
    } else if saved > 0 {
      react(.celebrate)
      showFlash(TabyNotification(title: saved == 1 ? "Notiz gespeichert" : "\(saved) Notizen gespeichert",
                                 body: titlePrefix.map { "Zu „\($0)“" } ?? "Im Reiter Notizen"))
    }
  }

  private var startingToListen = false
  private var pendingStop: Bool?

  /// Spracherkennung starten; Zwischenstände landen in `transcript`.
  public func startListening() async {
    guard !listening, !startingToListen else { return }
    transcript = ""
    startingToListen = true
    pendingStop = nil
    let result = await services.startListening { [weak self] text, _ in
      self?.transcript = text
    }
    startingToListen = false
    switch result {
    case .ok:
      listening = true
      // Taste schon losgelassen, während das Mikrofon startete (z. B. Freigabe-Dialog).
      if let submit = pendingStop {
        pendingStop = nil
        await stopListening(submit: submit)
      }
    case .failure(_, let error):
      showFlash(TabyNotification(title: "Sprechen nicht möglich", body: error))
    }
  }

  /// Spracherkennung beenden. Mit `submit` geht der Text direkt in die
  /// Schnellerfassung, sonst landet er im Eingabefeld.
  public func stopListening(submit: Bool) async {
    if startingToListen { pendingStop = submit; return }
    guard listening else { return }
    listening = false
    let spoken = await services.stopListening().trimmingCharacters(in: .whitespacesAndNewlines)
    let text = spoken.isEmpty ? transcript.trimmingCharacters(in: .whitespacesAndNewlines) : spoken
    guard !text.isEmpty else { return }
    guard submit else {
      captureDraft = text
      return
    }
    isThinking = true
    do {
      _ = try await services.quickCapture(text)
      react(.itemAdded)
      await refresh()
    } catch {
      let message = ChatLogic.errorToGerman(error) ?? "Abgebrochen."
      react(.failed(message))
      showFlash(TabyNotification(title: "Schnellerfassung fehlgeschlagen", body: message))
    }
    isThinking = false
  }

  public func resolveAgentRequest(_ id: String, _ decision: AgentPermissionDecision) async {
    agentRequests.removeAll { $0.id == id }
    await services.resolveAgentRequest(id, decision)
    react(decision.behavior == .allow ? .celebrate : .itemDeleted)
  }

  private func handle(_ event: AppEvent) {
    switch event {
    case .stateChanged, .dayStartPrompt:
      Task { await refresh() }
    case .briefingReady(let b):
      briefing = b
    case .agentRequest(let req):
      agentRequests = [req]
    case .agentRequestClosed(let id):
      agentRequests.removeAll { $0.id == id }
    case .flash(let n):
      flash = n
      flashSerial += 1
    case .dayEndPrompt:
      Task { await refresh() }
    case .focusFinished(let f):
      flash = TabyNotification(title: f.phase == .work ? "Fokus geschafft!" : "Pause vorbei",
                               body: f.phase == .work ? "\(f.title) – Zeit für eine Pause." : "Weiter geht's.")
      flashSerial += 1
      react(f.phase == .work ? .celebrate : .itemAdded)
      Task { await refresh() }
    case .meetingPrompt, .weeklyReviewPrompt:
      Task { await refresh() }
    case .capturePackets:
      Task { await refresh() }
    case .claudeNotice(let n):
      claudeNoticeSerial += 1
      flash = TabyNotification(title: n.kind == .finished ? "Claude ist fertig" : "Claude wartet auf dich",
                               body: [n.project, n.message].filter { !$0.isEmpty }.joined(separator: " – "))
      flashSerial += 1
    case .confirmationRequested(let c):
      // Insel poppt auf; die Bestätigungskarte steht in Chat und Heute.
      flash = TabyNotification(title: "Bestätigung nötig", body: c.summary)
      flashSerial += 1
      Task { await refresh() }
    }
    onEvent?(event)
  }
}
