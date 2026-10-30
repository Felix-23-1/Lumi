// Fokus-Umgebung: beim Start optional ein Kurzbefehl, Ablenkungs-Apps werden
// ausgeblendet und bleiben ausgeblendet, wenn der Nutzer sie wieder aktiviert.
import AppKit
import Foundation

/// Zugriff auf die laufenden Apps (austauschbar für Prüfungen).
public protocol AppHider: AnyObject {
  /// Laufende Apps mit Bundle-ID und Aktion zum Ausblenden.
  func runningApps() -> [(bundleId: String, hide: () -> Void)]
}

public final class WorkspaceAppHider: AppHider {
  public init() {}

  public func runningApps() -> [(bundleId: String, hide: () -> Void)] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard let id = app.bundleIdentifier else { return nil }
      return (bundleId: id, hide: { _ = app.hide() })
    }
  }
}

@MainActor
public final class FocusEnvironment {
  /// true zwischen begin() und end().
  public private(set) var active = false
  /// Deutsche Meldung, wenn ein Kurzbefehl fehlgeschlagen ist.
  public var lastError: String?

  private let runner: ShortcutsRunning
  private let hider: AppHider
  private var observers: [NSObjectProtocol] = []
  private var shortcutTasks: [Task<Void, Never>] = []

  public init(runner: ShortcutsRunning = ShortcutsCLI(), hider: AppHider = WorkspaceAppHider()) {
    self.runner = runner
    self.hider = hider
  }

  /// Startet den Fokus: Kurzbefehl (leer = keiner) läuft im Hintergrund, die Apps werden ausgeblendet.
  public func begin(shortcutOn: String, hideApps: [String]) {
    active = true
    lastError = nil
    let ids = Set(hideApps)
    if !shortcutOn.isEmpty { runShortcut(shortcutOn) }
    hideRunning(ids)
    watch(ids)
  }

  /// Beendet den Fokus. Ausgeblendete Apps bleiben aus; das entscheidet der Nutzer.
  public func end(shortcutOff: String) {
    active = false
    unwatch()
    if !shortcutOff.isEmpty { runShortcut(shortcutOff) }
  }

  private func hideRunning(_ ids: Set<String>) {
    for app in hider.runningApps() where ids.contains(app.bundleId) {
      app.hide()
    }
  }

  private func watch(_ ids: Set<String>) {
    unwatch()
    let center = NSWorkspace.shared.notificationCenter
    let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification]
    observers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        // Läuft auf dem Hauptthread; nur die Bundle-ID (ein String) geht auf den MainActor.
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let id = app?.bundleIdentifier, ids.contains(id) else { return }
        Task { @MainActor in self?.hideIfActive(id) }
      }
    }
  }

  private func hideIfActive(_ id: String) {
    guard active else { return }
    for app in hider.runningApps() where app.bundleId == id {
      app.hide()
    }
  }

  private func unwatch() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in observers { center.removeObserver(observer) }
    observers = []
  }

  private func runShortcut(_ name: String) {
    let runner = self.runner
    shortcutTasks.append(Task { @MainActor [weak self] in
      let message: String? = await Blocking.run {
        do {
          _ = try runner.run(name, input: nil, timeout: 300)
          return nil
        } catch {
          return "Kurzbefehl „\(name)“ ist fehlgeschlagen: \(error.localizedDescription)"
        }
      }
      if let message { self?.lastError = message }
    })
  }

  /// Wartet, bis alle angestoßenen Kurzbefehle abgeschlossen sind (für Prüfungen).
  func awaitShortcuts() async {
    for task in shortcutTasks { await task.value }
  }
}
