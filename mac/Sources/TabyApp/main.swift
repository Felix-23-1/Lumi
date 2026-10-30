// App-Start und Verdrahtung (Integrator, Welle 2): Kern (CoreServices),
// Oberfläche (AppModel + Notch-Insel), Menüleisten-Symbol, Einzelinstanz,
// Start bei Anmeldung.
import AppKit
import SwiftUI
import ServiceManagement
import TabyCore
import TabyUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private var services: CoreServices?
  private var model: AppModel?
  private var island: IslandWindowController?
  private var statusItem: NSStatusItem?
  private var lockFD: Int32 = -1
  private let hotKeys = HotKeyCenter()
  private var registeredShortcuts: [String] = []
  private var onboardingWindow: NSWindow?
  private var howToWindow: NSWindow?
  private var sampleItem: NSMenuItem?
  private var updateItem: NSMenuItem?
  private var toolWindows: ToolWindowController?
  private let textService = TextServiceProvider()

  /// Eigener Ordner (nicht ~/Library/Application Support/taby der Electron-
  /// Version: APFS unterscheidet Groß/Klein nicht, beide teilten sonst taby.sqlite).
  static var dataDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("de.felix.taby", isDirectory: true)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    signal(SIGPIPE, SIG_IGN)  // ein sterbender MCP-Server darf die App nicht beenden
    FrontAppTracker.start()  // Merk dir das: zuletzt aktive fremde App merken
    let dir = Self.dataDirectory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Einzelinstanz: Bundle-ID-Prüfung reicht ohne Bundle (swift run) nicht –
    // zusätzlich eine exklusive Sperre auf den Datenordner. Sonst liefen zwei
    // Planer auf derselben Datenbank (doppelte Erinnerungen) und der zweite
    // würde den Agenten-Socket übernehmen.
    if Self.anotherInstanceRunning() || !acquireLock(in: dir) {
      NSApp.terminate(nil)
      return
    }
    NSApp.setActivationPolicy(.accessory)
    installMainMenu()

    let isBundled = Bundle.main.bundleIdentifier != nil
    // Nur aus der echten App: ein Pfad in .build/ würde nach dem nächsten
    // Bauen ins Leere zeigen, steht aber dann in ~/.claude/settings.json.
    let relay = isBundled
      ? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("taby-hook-relay").path
      : nil

    // Keine Mitteilungs-Abfrage beim Start: die Einrichtung fragt, oder der erste Versand.
    let systemNotifier = isBundled ? UserNotificationsNotifier(requestAuthorizationNow: false) : nil
    var options = CoreServices.Options(
      databasePath: dir.appendingPathComponent("taby.sqlite").path,
      socketPath: dir.appendingPathComponent("taby-agent.sock").path,
      relayPath: relay,
      systemNotifier: systemNotifier ?? ConsoleNotifier(),
      applyStartOnLogin: { enabled in Self.setStartOnLogin(enabled) }
    )
    options.requestAccessibility = { SelectionGrabber.isTrusted(prompt: true) }
    options.mediaKeySender = { MediaKeys.send($0) }
    options.mcpSocketPath = MCPPaths.defaultSocketPath
    options.modsRoot = dir.appendingPathComponent("Mods", isDirectory: true)
    options.mcpCommandPath = isBundled
      ? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("taby-mcp").path
      : nil

    do {
      let services = try CoreServices(options: options)
      self.services = services
      // Knöpfe „Ich arbeite daran“ / „Erledigt“ / „In 10 Min“ der Systembenachrichtigung (wie in der Notch).
      systemNotifier?.onTaskAction = { [weak services] action, taskId in
        Task { @MainActor in
          switch action {
          case .working: _ = await services?.startFocus(taskId: taskId, minutes: nil)
          case .more15: _ = await services?.startFocus(taskId: taskId, minutes: 15)
          case .more30: _ = await services?.startFocus(taskId: taskId, minutes: 30)
          case .done: _ = await services?.completeTask(taskId)
          case .snooze:
            _ = await services?.updateTask(taskId, TaskPatch(due: ReminderText.snoozeDue(now: SystemClock().now())))
          }
        }
      }
      let model = AppModel(services: services)
      self.model = model
      model.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
      let island = IslandWindowController(model: model, startWithGreeting: true)
      self.island = island
      let toolWindows = ToolWindowController(model: model)
      self.toolWindows = toolWindows
      island.onDetachTab = { [weak toolWindows] tab in toolWindows?.open(tab) }
      model.onDetach = { [weak toolWindows] tab in toolWindows?.open(tab) }
      island.show()
      installStatusItem()
      // Dienste-Menü „Mit Lumi erfassen“ (Rechtsklick auf markierten Text).
      textService.onText = { [weak self] text in self?.island?.openQuickCapture(prefill: text) }
      textService.onExplain = { [weak self] text in self?.explain(text: text) }
      NSApp.servicesProvider = textService
      NSUpdateDynamicServices()
      Task {
        await model.refresh()
        // Systemzustand und Einstellung abgleichen (Nutzer kann den Login-
        // Eintrag in den Systemeinstellungen entfernt haben).
        if let wanted = model.state?.settings.startOnLogin { Self.setStartOnLogin(wanted) }
        self.applyShortcuts()
        // Erster Start: Einrichtungs-Assistent. Wer schon eingerichtet ist
        // (Schlüssel gesetzt, z. B. nach einem Update), überspringt ihn still.
        if let s = model.state?.settings, !s.onboardingDone {
          if s.hasApiKey {
            _ = await services.updateSettings(SettingsPatch(onboardingDone: true), apiKey: nil)
          } else {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            self.showOnboarding()
          }
        } else if OnboardingEntry.isReturningFromSigning() {
          // Nach dem Signieren aus der Menüleiste: die Freigaben noch einmal anbieten.
          self.showOnboarding()
        }
      }
      // Kurzbefehle neu belegen, wenn sie in den Einstellungen geändert wurden.
      model.onEvent = { [weak self] event in
        if case .stateChanged = event { Task { @MainActor in self?.applyShortcuts() } }
      }
    } catch {
      let alert = NSAlert()
      alert.messageText = "Lumi konnte nicht starten"
      alert.informativeText = "Die Datenbank ließ sich nicht öffnen: \(error)"
      alert.runModal()
      NSApp.terminate(nil)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    services?.shutdown()
    MCPManager.shared.terminateAll()
  }

  /// Einrichtungs-Assistent in einem eigenen Fenster (Platz für Eingaben und
  /// die Freigabe-Dialoge von macOS).
  @objc private func showOnboarding() {
    if let w = onboardingWindow {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    guard let model else { return }
    let view = OnboardingView(onFinish: { [weak self] in
      self?.onboardingWindow?.close()
      self?.onboardingWindow = nil
      self?.island?.open(tab: .today)
    }, resume: true).environmentObject(model)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Lumi einrichten"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = true
    window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    window.contentView = NSHostingView(rootView: view)
    window.center()
    onboardingWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// „So geht’s“ in eigenem Fenster (Menüleiste).
  @objc private func showHowTo() {
    if let w = howToWindow {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let view = HowToView().padding(24).frame(width: 560, height: 520, alignment: .topLeading)
      .background(Color(red: 0.05, green: 0.05, blue: 0.06)).environment(\.colorScheme, .dark)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "So geht’s"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = true
    window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    window.contentView = NSHostingView(rootView: view)
    window.center()
    howToWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Beispiel-Tag entfernen (nur sichtbar, solange Beispiel-Einträge da sind).
  @objc private func removeSampleDay() {
    guard let services else { return }
    Task { @MainActor in
      _ = await services.removeSampleDay()
      await self.model?.refresh()
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard let services else { return }
    Task { @MainActor [weak self] in
      let hasSample = await services.hasSampleDay()
      // Kein eigener `state()`-Aufruf: das Modell hält den Stand und aktualisiert sich selbst.
      let update = self?.model?.state?.update
      self?.sampleItem?.isHidden = !hasSample
      self?.updateItem?.isHidden = update == nil
      if let update { self?.updateItem?.title = "Update verfügbar – \(update.versionName) installieren…" }
    }
  }

  /// Kurzbefehle: Insel ein-/ausblenden (globalShortcut) und Schnellerfassung.
  private func applyShortcuts() {
    guard let settings = model?.state?.settings else { return }
    let wanted = [settings.globalShortcut, settings.quickCaptureShortcut, settings.captureSelectionShortcut,
                  settings.captureContextShortcut, settings.voiceInputShortcut, settings.explainShortcut, settings.circleShortcut]
    guard wanted != registeredShortcuts else { return }
    hotKeys.unregisterAll()
    // Was macOS nicht belegen ließ (z. B. schon von einer anderen App vergeben): die Einstellungen zeigen es rot.
    var refused: [String] = []
    func claim(_ shortcut: String, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
      guard !shortcut.isEmpty else { return }
      let ok = onRelease.map { hotKeys.register(shortcut, onPress: onPress, onRelease: $0) }
        ?? hotKeys.register(shortcut, action: onPress)
      if !ok {
        FileHandle.standardError.write(Data("Kurzbefehl nicht belegbar: \(shortcut)\n".utf8))
        refused.append(shortcut)
      }
    }
    // Insel ein-/ausblenden; Schnellerfassung öffnet die Insel direkt mit dem Eingabefeld.
    claim(settings.globalShortcut) { [weak self] in self?.island?.toggle() }
    claim(settings.quickCaptureShortcut) { [weak self] in self?.island?.openQuickCapture() }
    // Markierten Text übernehmen (braucht die Bedienungshilfen-Freigabe).
    claim(settings.captureSelectionShortcut) { [weak self] in self?.captureSelection() }
    // Merk dir das: Kontext der vorigen App als kleine Karte anbieten.
    claim(settings.captureContextShortcut) { [weak self] in self?.captureContext() }
    // Sprechen: gedrückt halten, loslassen schickt den Text an die Schnellerfassung.
    claim(settings.voiceInputShortcut, onPress: { [weak self] in self?.startVoice() },
          onRelease: { [weak self] in self?.stopVoice() })
    // Fest belegt (kein Einstellungsfeld im Vertrag): markierten Text erklären lassen.
    claim(settings.explainShortcut) { [weak self] in self?.explainSelection() }
    // Fest belegt: Bildschirmausschnitt einkreisen und per Stimme dazu fragen.
    claim(settings.circleShortcut) { [weak self] in self?.circleAndAsk() }
    model?.shortcutConflicts = refused
    registeredShortcuts = wanted
  }

  static let explainShortcut = "Control+Option+E"
  static let circleShortcut = "Control+Option+K"

  /// „Lumi, erklär mir das“: markierten Text holen, Karte zeigen, Erklärung holen.
  /// Erklärung für einen schon vorhandenen Text (Rechtsklick → Dienste → „Mit Lumi erklären“, braucht keine Freigabe).
  private func explain(text: String) {
    guard let model else { return }
    Task { @MainActor in
      self.island?.openExplain(ExplainCardState(original: text))
      switch await model.services.explainText(text, speak: ExplainSettings.speak) {
      case .ok(let answer): self.island?.updateExplain(ExplainCardState(original: text, phase: .answer(answer)))
      case .failure(_, let error): self.island?.updateExplain(ExplainCardState(original: text, phase: .failure(error)))
      }
    }
  }

  private func explainSelection() {
    guard SelectionGrabber.isTrusted(prompt: true) else {
      model?.showFlash(TabyNotification(
        title: "Freigabe nötig",
        body: "Erlaube Lumi unter Datenschutz & Sicherheit → Bedienungshilfen, markierten Text zu kopieren."))
      return
    }
    Task { @MainActor in
      guard let model, let text = await SelectionGrabber.grab() else {
        self.model?.showFlash(TabyNotification(
          title: "Erklär mir das",
          body: "Ich habe keinen markierten Text bekommen. Markiere Text und drücke Ctrl+Option+E – oder Rechtsklick → Dienste → „Mit Lumi erklären“."))
        return
      }
      self.island?.openExplain(ExplainCardState(original: text))
      switch await model.services.explainText(text, speak: ExplainSettings.speak) {
      case .ok(let answer): self.island?.updateExplain(ExplainCardState(original: text, phase: .answer(answer)))
      case .failure(_, let error): self.island?.updateExplain(ExplainCardState(original: text, phase: .failure(error)))
      }
    }
  }

  private var circleTask: Task<Void, Never>?
  private var regionSelector: RegionSelector?

  /// Einkreisen und fragen; ein zweiter Tastendruck bricht die laufende Runde ab.
  private func circleAndAsk() {
    if let task = circleTask {
      regionSelector?.cancel()
      task.cancel()
      return
    }
    circleTask = Task { @MainActor in
      await self.runCircleAndAsk()
      self.regionSelector = nil
      self.circleTask = nil
    }
  }

  private func runCircleAndAsk() async {
    guard let model else { return }
    guard ScreenRegionCapture.ensureAccess() else {
      model.showFlash(TabyNotification(
        title: "Freigabe nötig",
        body: "Erlaube Lumi unter Datenschutz & Sicherheit → Bildschirmaufnahme, den Ausschnitt zu lesen."))
      return
    }
    let selector = RegionSelector()
    regionSelector = selector
    guard let selection = await selector.select(), !Task.isCancelled else { return }
    try? await Task.sleep(nanoseconds: 150_000_000) // Fenster sollen sicher aus dem Bild sein
    let label = "Bildschirmausschnitt"
    self.island?.openExplain(ExplainCardState(original: label))
    func fail(_ message: String) { island?.updateExplain(ExplainCardState(original: label, phase: .failure(message))) }
    guard let image = await ScreenRegionCapture.capture(selection) else {
      return fail("Den Ausschnitt konnte ich nicht aufnehmen.")
    }
    let ocr: String
    switch await TextRecognizer.recognize(image) {
    case .ok(let text): ocr = text
    case .failure(_, let error): return fail(error)
    }
    guard !Task.isCancelled else { return fail("Abgebrochen.") }
    let spoken = await listenForQuestion(model)
    guard !Task.isCancelled else { return fail("Abgebrochen.") }
    let original = String(ocr.prefix(300))
    switch await model.services.askAboutText(ocr, question: spoken, speak: ExplainSettings.speak) {
    case .ok(let answer): island?.updateExplain(ExplainCardState(original: original, phase: .answer(answer)))
    case .failure(_, let error): island?.updateExplain(ExplainCardState(original: original, phase: .failure(error)))
    }
  }

  /// Hört, bis nach einer Sprechpause genug Text da ist (oder 8 s ohne Text); leer = einfach erklären.
  private func listenForQuestion(_ model: AppModel) async -> String {
    final class Heard { var text = ""; var changed = Date() }
    let heard = Heard()
    let started = Date()
    let result = await model.services.startListening { text, _ in
      if text != heard.text { heard.text = text; heard.changed = Date() }
    }
    guard case .ok = result else { return "" }
    model.showFlash(TabyNotification(title: "Ich höre zu …", body: "Sag z. B. „Was ist das?“"))
    while !Task.isCancelled,
          !CircleLogic.shouldStopListening(text: heard.text, lastChange: heard.changed, now: Date(), started: started) {
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    let final = await model.services.stopListening()
    return Task.isCancelled ? "" : (final.isEmpty ? heard.text : final).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func captureContext() {
    guard let model else { return }
    Task { @MainActor in
      switch await model.services.captureContext() {
      case .ok(let context): self.island?.openContextCapture(context)
      case .failure(_, let error): model.showFlash(TabyNotification(title: "Merk dir das", body: error))
      }
    }
  }

  private func captureSelection() {
    guard SelectionGrabber.isTrusted(prompt: true) else {
      model?.showFlash(TabyNotification(
        title: "Freigabe nötig",
        body: "Erlaube Lumi unter Datenschutz & Sicherheit → Bedienungshilfen, markierten Text zu kopieren."))
      return
    }
    Task { @MainActor in
      let text = await SelectionGrabber.grab()
      self.island?.openQuickCapture(prefill: text ?? "")
    }
  }

  private var voiceActive = false

  private func startVoice() {
    guard !voiceActive, let model else { return }
    voiceActive = true
    island?.openQuickCapture()
    Task { await model.startListening() }
  }

  private func stopVoice() {
    guard voiceActive, let model else { return }
    voiceActive = false
    Task { await model.stopListening(submit: true) }
  }

  private func acquireLock(in dir: URL) -> Bool {
    let fd = open(dir.appendingPathComponent("taby.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return true }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false
    }
    lockFD = fd
    return true
  }

  /// Ohne Hauptmenü fehlt die Bearbeiten-Kette: ⌘C/⌘V/⌘A/⌘Z gingen in den
  /// Textfeldern (Chat, API-Schlüssel) nicht.
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu(title: "Lumi")
    appItem.submenu?.addItem(withTitle: "Lumi beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Bearbeiten")
    edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = MenuBarIcon.make()
    item.button?.image?.accessibilityDescription = "Lumi"
    let menu = NSMenu()
    let version = menu.addItem(withTitle: "Lumi \(AppUpdate.versionName(build: CoreServices.bundleBuild()))", action: nil, keyEquivalent: "")
    version.isEnabled = false
    let update = menu.addItem(withTitle: "Update verfügbar", action: #selector(openUpdates), keyEquivalent: "")
    update.target = self
    update.isHidden = true
    updateItem = update
    menu.addItem(.separator())
    menu.addItem(withTitle: "Lumi öffnen", action: #selector(openIsland), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(withTitle: "Nach Updates suchen…", action: #selector(openUpdates), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Einrichtung…", action: #selector(showOnboarding), keyEquivalent: "").target = self
    menu.addItem(withTitle: "So geht’s…", action: #selector(showHowTo), keyEquivalent: "").target = self
    let sample = menu.addItem(withTitle: "Beispiel-Tag entfernen", action: #selector(removeSampleDay), keyEquivalent: "")
    sample.target = self
    sample.isHidden = true
    sampleItem = sample
    menu.delegate = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Lumi beenden", action: #selector(quit), keyEquivalent: "q").target = self
    item.menu = menu
    statusItem = item
  }

  @objc private func openIsland() { island?.open() }
  @objc private func openSettings() { toolWindows?.open(.settings) }
  @objc private func openUpdates() {
    toolWindows?.open(.settings)
    SettingsEntry.showUpdates()
  }
  @objc private func quit() { NSApp.terminate(nil) }

  private static func anotherInstanceRunning() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let mine = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .contains { $0.processIdentifier != mine }
  }

  private static func setStartOnLogin(_ enabled: Bool) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let isOn = SMAppService.mainApp.status == .enabled
    guard isOn != enabled else { return }
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      FileHandle.standardError.write(Data("Start bei Anmeldung nicht geändert: \(error)\n".utf8))
    }
  }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
