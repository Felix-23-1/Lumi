import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  public func agentsInstalled() async -> Bool {
    hookServer != nil && ClaudeHookInstaller.isInstalled(settingsURL: options.claudeSettingsURL)
  }

  public func agentsInstall() async -> ToolResult<Empty> {
    guard hookServer != nil, let socket = options.socketPath else {
      return .failure(code: "NO_SERVER", error: "Lokaler Agenten-Server nicht verfügbar.")
    }
    guard let relay = options.relayPath, FileManager.default.isExecutableFile(atPath: relay) else {
      return .failure(code: "NO_RELAY", error: "Hook-Relay nicht gefunden. Bitte Lumi als App starten.")
    }
    do {
      try ClaudeHookInstaller.install(settingsURL: options.claudeSettingsURL, relayPath: relay, socketPath: socket)
      return .ok(Empty())
    } catch {
      return .failure(code: "ERROR", error: "Claude-Code-Einstellungen konnten nicht geändert werden: \(error)")
    }
  }

  public func agentsUninstall() async {
    try? ClaudeHookInstaller.uninstall(settingsURL: options.claudeSettingsURL)
  }

  public func resolveAgentRequest(_ id: String, _ decision: AgentPermissionDecision) async {
    hookServer?.resolve(id: id, decision: decision)
  }
}
