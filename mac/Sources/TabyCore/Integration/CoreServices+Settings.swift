import ApplicationServices
import AVFoundation
import EventKit
import Foundation
import Speech
import UserNotifications

extension PermissionKind {
  /// Direkt zur Freigabe in den Systemeinstellungen (Knopf „Systemeinstellungen öffnen“).
  public var settingsURL: URL {
    let pane: String
    switch self {
    case .calendar: pane = "Privacy_Calendars"
    case .reminders: pane = "Privacy_Reminders"
    case .notifications: return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    case .microphone: pane = "Privacy_Microphone"
    case .speechRecognition: pane = "Privacy_SpeechRecognition"
    case .accessibility: pane = "Privacy_Accessibility"
    case .mail: pane = "Privacy_Automation"
    }
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
  }
}

/// Freigaben nachlesen, ohne zu fragen (für die Einrichtung, die nach der Rückkehr neu prüft).
public enum PermissionCheck {
  /// Bedienungshilfen: AXIsProcessTrusted fragt nicht nach.
  public static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

  /// Ob eine Freigabe schon erteilt ist, ohne zu fragen. nil: macOS verrät das ohne Dialog nicht (Mail).
  public static func isGranted(_ kind: PermissionKind) async -> Bool? {
    switch kind {
    case .calendar:
      return [EKAuthorizationStatus.fullAccess, .authorized].contains(EKEventStore.authorizationStatus(for: .event))
    case .reminders:
      return EventKitRemindersBackend.isGranted(EKEventStore.authorizationStatus(for: .reminder))
    case .notifications:
      guard Bundle.main.bundleIdentifier != nil else { return false }
      let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      return status == .authorized || status == .provisional
    case .microphone:
      return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    case .speechRecognition:
      return SFSpeechRecognizer.authorizationStatus() == .authorized
    case .accessibility:
      return accessibilityGranted()
    case .mail:
      return nil
    }
  }
}

extension CoreServices {
  // MARK: Einrichtung

  public func requestPermission(_ kind: PermissionKind) async -> Bool {
    switch kind {
    case .calendar:
      return await AppleCalendarProvider(id: "apple", config: [:]).requestAccess()
    case .reminders:
      return await remindersBackend.requestAccess()
    case .notifications:
      guard Bundle.main.bundleIdentifier != nil else { return false }
      return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    case .microphone, .speechRecognition:
      return await SpeechRecognizer.requestAccess()
    case .accessibility:
      return options.requestAccessibility?() ?? false
    case .mail:
      return await requestMailAccess()
    }
  }

  public func mcpCommandPath() async -> String? { options.mcpCommandPath }

  /// MCP-Brücke je nach Einstellung starten/stoppen.
  func applyMcp() {
    // Nur-lokal schaltet auch die MCP-Brücke ab: Claude und andere Programme lesen dann keine Lumi-Daten.
    let want = settings.mcpEnabled && !settings.localOnly && options.mcpSocketPath != nil
    if want, mcpServer == nil, let path = options.mcpSocketPath {
      let box = calendarBox
      let host = TabyMCPHost(store: store, clock: clock, calendar: { box.value },
                             onMutation: { [weak self] in Task { @MainActor in self?.changed() } })
      let server = MCPBridgeServer(socketPath: path, host: host)
      do {
        try server.start()
        mcpServer = server
      } catch {
        TabyLog.error(.core, "MCP-Brücke nicht gestartet (\(TabyLog.code(error)))")
      }
    } else if !want, let server = mcpServer {
      server.stop()
      mcpServer = nil
    }
  }

  public func updateSettings(_ patch: SettingsPatch, apiKey: String?) async -> TabySettings {
    var problem: String?
    // Ungültige Kategorien werden nicht gespeichert; das soll man sehen, nicht still verlieren.
    if let categories = patch.taskCategories, let reason = TaskCategoryRules.problem(categories) {
      problem = "Kategorien nicht gespeichert: \(reason)"
    }
    if let apiKey {
      do { try llmKeyStore(for: patch.llmBaseUrl ?? settings.llmBaseUrl).set(apiKey) } catch {
        TabyLog.error(.core, "API-Schlüssel nicht im Schlüsselbund gespeichert (\(TabyLog.code(error)))")
        problem = "API-Schlüssel konnte nicht im Schlüsselbund gespeichert werden. Der Schlüssel bleibt im Feld."
      }
    }
    let before = settings
    guard let updated = try? store.settings.update(patch, hasApiKey: llmKeyStore(for: patch.llmBaseUrl ?? before.llmBaseUrl).hasKey())
    else {
      TabyLog.error(.core, "Einstellungen nicht in der Datenbank gespeichert")
      saveError = "Die Einstellungen konnten nicht gespeichert werden."
      emit(.flash(TabyNotification(title: "Nicht gespeichert", body: saveError ?? "")))
      changed()
      return before
    }
    // Ein erfolgreiches Speichern löscht den alten Fehler; ein Schlüsselfehler bleibt sichtbar.
    saveError = problem
    if let problem { emit(.flash(TabyNotification(title: "Nicht gespeichert", body: problem))) }
    if let start = patch.startOnLogin, start != before.startOnLogin { options.applyStartOnLogin?(start) }
    if patch.mcpEnabled != nil || patch.localOnly != nil { applyMcp() }
    changed()
    return updated
  }

  public func listModels() async -> ToolResult<[String]> {
    await LlmConnection.listModels(settings: settings, keyStore: llmKeyStore(for: settings.llmBaseUrl), session: options.session)
  }

  public func testLlm() async -> LlmTestResult {
    await LlmConnection.test(settings: settings, keyStore: llmKeyStore(for: settings.llmBaseUrl), session: options.session)
  }
}
