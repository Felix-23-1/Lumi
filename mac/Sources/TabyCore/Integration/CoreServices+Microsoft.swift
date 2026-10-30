// Microsoft (Outlook, Teams) im Kern: Anmelden per Gerätecode, Abbrechen, Abmelden.
// Nach der Anmeldung stehen Mail-Adresse in den Einstellungen und die Quelle „Outlook“
// (feste Kennung „microsoft“) im Kalender. Abmelden räumt einen Teams-Status, den Lumi gesetzt hat,
// löscht das Erneuerungs-Token, die Quelle und das Teams-Konto. Die Anmeldung selbst liegt in MicrosoftAuth.
import Foundation

extension CoreServices {
  /// Feste Kennung der Outlook-Kalenderquelle (genau eine je Konto).
  static let microsoftCalendarId = "microsoft"

  static func microsoftMessage(_ error: Error) -> String {
    (error as? MicrosoftFailure)?.message ?? "Microsoft-Anmeldung fehlgeschlagen."
  }

  /// Alte Form: wie bisher mit Teams (Kalender und Teams-Chats).
  public func startMicrosoftSignIn() async -> ToolResult<MicrosoftSignIn> {
    await startMicrosoftSignIn(includeTeams: true)
  }

  public func startMicrosoftSignIn(includeTeams: Bool) async -> ToolResult<MicrosoftSignIn> {
    do {
      return .ok(try await microsoft.startSignIn(includeTeams: includeTeams))
    } catch {
      return .failure(code: "MICROSOFT", error: Self.microsoftMessage(error))
    }
  }

  public func cancelMicrosoftSignIn() async {
    microsoft.cancelSignIn()
  }

  public func finishMicrosoftSignIn() async -> ToolResult<String> {
    let mail: String
    do {
      mail = try await microsoft.finishSignIn()
    } catch {
      return .failure(code: "MICROSOFT", error: Self.microsoftMessage(error))
    }
    do {
      _ = try store.settings.update(SettingsPatch(microsoftAccount: mail))
      let hasOutlook = ((try? store.calendarSources.list()) ?? []).contains { $0.kind == .microsoft }
      if !hasOutlook {
        try store.calendarSources.add(kind: .microsoft, enabled: true, isDefaultWrite: false,
                                      id: Self.microsoftCalendarId)
      }
    } catch {
      return .failure(code: "ERROR", error: "Die Anmeldung hat geklappt, Lumi konnte sie aber nicht speichern.")
    }
    rebuildCalendar()
    changed()
    return .ok(mail)
  }

  public func disconnectMicrosoft() async -> ToolResult<Empty> {
    await clearTeamsPresence()
    do {
      try microsoft.signOut()
    } catch {
      return .failure(code: "KEYCHAIN", error: Self.microsoftMessage(error))
    }
    for account in ((try? store.messengerAccounts.list()) ?? []) where account.service == .teams {
      await messenger.disconnect(account.id)
    }
    for source in ((try? store.calendarSources.list()) ?? []) where source.kind == .microsoft {
      _ = try? store.calendarSources.delete(source.id)
    }
    _ = try? store.settings.update(SettingsPatch(microsoftAccount: ""))
    rebuildCalendar()
    changed()
    return .ok(Empty())
  }

  /// Teams-Status räumen, den Lumi gesetzt hat. Nur wo ein Eintrag von Lumi steht; ein Fehler lässt den Eintrag für später.
  func clearTeamsPresence() async {
    let teams = Set(((try? store.messengerAccounts.list()) ?? []).filter { $0.service == .teams }.map(\.id))
    let records = ((try? store.autoStatus.list()) ?? []).filter { teams.contains($0.accountId) }
    guard !records.isEmpty else { return }
    do {
      _ = try await microsoft.graph("POST", MicrosoftAuth.graphURL("me/presence/clearUserPreferredPresence"))
    } catch {
      TabyLog.error(.messenger, "Teams: Status konnte nicht geräumt werden (\(Self.microsoftMessage(error)))")
      return
    }
    for record in records { try? store.autoStatus.delete(record.accountId) }
  }

  /// Beim Beenden (synchron): Teams-Status räumen, höchstens drei Sekunden warten.
  func clearTeamsPresenceAtExit() {
    let teams = Set(((try? store.messengerAccounts.list()) ?? []).filter { $0.service == .teams }.map(\.id))
    let records = ((try? store.autoStatus.list()) ?? []).filter { teams.contains($0.accountId) }
    guard !records.isEmpty else { return }
    let auth = microsoft
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      _ = try? await auth.graph("POST", MicrosoftAuth.graphURL("me/presence/clearUserPreferredPresence"))
      done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
    for record in records { try? store.autoStatus.delete(record.accountId) }
  }
}
