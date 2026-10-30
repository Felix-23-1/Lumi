// Status automatisch: während eines Fokus (Arbeitsphase) und eines laufenden Termins
// setzt Lumi bei den Konten einen Status (Slack), danach wird er wieder gelöscht.
// Entscheidung und Aufräumen sind Code. Lumi fasst nur an, was es selbst gesetzt hat:
// ein Status des Nutzers wird nie überschrieben, und gelöscht wird nur, wenn der
// aktuelle Status noch der von Lumi ist. Der Zustand liegt in SQLite, damit ein
// Absturz beim Start aufgeräumt wird.
import Foundation

/// Ein Dienst, bei dem Lumi den eigenen Status setzen kann (Slack).
public protocol StatusSetting: AnyObject, Sendable {
  /// Eigener Status (Text, Emoji); leer = kein Status.
  func readStatus() async throws -> (text: String, emoji: String)
  /// Setzt den Status; `until` = Ablauf, nil = kein Ablauf. Leerer Text löscht ihn.
  func writeStatus(text: String, emoji: String, until: Date?) async throws
  /// Ob der gelesene Status der ist, den Lumi laut Eintrag gesetzt hat (Standard: Text und Emoji gleich).
  func ownsStatus(_ current: (text: String, emoji: String), record: AutoStatusRecord) -> Bool
  /// Verlängert den eigenen Status im Takt (Standard: nichts zu tun).
  func refreshStatus(until: Date?) async throws
}

extension StatusSetting {
  public func ownsStatus(_ current: (text: String, emoji: String), record: AutoStatusRecord) -> Bool {
    current.text == record.text && current.emoji == record.emoji
  }

  public func refreshStatus(until: Date?) async throws {}
}

/// Was jetzt gelten soll.
public struct AutoStatusWant: Equatable, Sendable {
  public let kind: String  // "focus" oder "meeting"
  public let text: String
  public let emoji: String
  /// Lokaler ISO-Zeitpunkt, an dem der Status endet.
  public let endsAt: String
}

public enum AutoStatusRules {
  public static let focusText = "Im Fokus"
  public static let focusEmoji = ":headphones:"
  public static let meetingText = "Im Termin"
  public static let meetingEmoji = ":calendar:"

  /// Fokus (nur Arbeitsphase) geht vor Termin. Abgelaufenes zählt nicht.
  public static func want(focus: FocusSession?, meeting: CalendarEvent?, now: Date) -> AutoStatusWant? {
    if let f = focus, f.phase == .work, let end = LocalTime.parse(f.endsAt), end > now {
      return AutoStatusWant(kind: "focus", text: focusText, emoji: focusEmoji, endsAt: f.endsAt)
    }
    if let m = meeting, runningMeeting([m], now: now) != nil, let end = m.end {
      return AutoStatusWant(kind: "meeting", text: meetingText, emoji: meetingEmoji, endsAt: end)
    }
    return nil
  }

  /// Ein Termin läuft jetzt: nicht ganztägig, Beginn <= jetzt < Ende.
  public static func runningMeeting(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
    events.first { e in
      guard !e.allDay, let start = LocalTime.parse(e.start), let endText = e.end,
            let end = LocalTime.parse(endText) else { return false }
      return start <= now && now < end
    }
  }
}

/// Gleicht die gesetzten Status mit dem Soll ab. Läufe sind hintereinander geschaltet
/// (kein Überlappen zwischen Takt und Ereignissen).
@MainActor
public final class AutoStatusController {
  private let repo: AutoStatusRepository
  private let clock: Clock
  private let targets: @MainActor () -> [(accountId: String, setting: StatusSetting)]
  private let enabled: @MainActor () -> Bool
  /// Hinweis je Konto (nil = keiner) für die Verbindungskarte.
  public var onHint: @MainActor (String, String?) -> Void = { _, _ in }
  private var chain: Task<Void, Never>?

  public init(repo: AutoStatusRepository, clock: Clock,
              targets: @escaping @MainActor () -> [(accountId: String, setting: StatusSetting)],
              enabled: @escaping @MainActor () -> Bool) {
    self.repo = repo; self.clock = clock; self.targets = targets; self.enabled = enabled
  }

  /// `dayEnded`: Feierabend ist beantwortet, dann wird Lumi-Status gelöscht und nichts Neues gesetzt.
  public func reconcile(focus: FocusSession?, meeting: CalendarEvent?, dayEnded: Bool) async {
    let previous = chain
    let run = Task { @MainActor in
      await previous?.value
      await self.step(focus: focus, meeting: meeting, dayEnded: dayEnded)
    }
    chain = run
    await run.value
  }

  private func step(focus: FocusSession?, meeting: CalendarEvent?, dayEnded: Bool) async {
    let on = enabled()
    let want = on && !dayEnded ? AutoStatusRules.want(focus: focus, meeting: meeting, now: clock.now()) : nil
    let targets = targets()

    // 1. Nicht mehr gewollt oder anderes Ziel: zurücknehmen.
    for record in (try? repo.list()) ?? [] {
      let target = targets.first { $0.accountId == record.accountId }?.setting
      if let want, want.kind == record.kind, want.endsAt == record.endsAt, let target {
        try? await target.refreshStatus(until: LocalTime.parse(want.endsAt))
        continue
      }
      await release(record, target: target)
    }

    // 2. Gewollt, aber für das Konto noch nichts gesetzt: setzen.
    guard let want else { return }
    let held = Set(((try? repo.list()) ?? []).map(\.accountId))
    for entry in targets where !held.contains(entry.accountId) {
      await acquire(want, accountId: entry.accountId, target: entry.setting)
    }
  }

  private func acquire(_ want: AutoStatusWant, accountId: String, target: StatusSetting) async {
    do {
      let current = try await target.readStatus()
      // Ein Status des Nutzers bleibt stehen.
      guard current.text.isEmpty && current.emoji.isEmpty else { return }
      try await target.writeStatus(text: want.text, emoji: want.emoji, until: LocalTime.parse(want.endsAt))
      try repo.set(AutoStatusRecord(accountId: accountId, kind: want.kind, text: want.text, emoji: want.emoji,
                                    endsAt: want.endsAt))
      onHint(accountId, nil)
    } catch {
      onHint(accountId, Self.hint(error))
    }
  }

  /// Entfernt den Lumi-Status, wenn er noch unverändert ist. Ein geänderter Status des Nutzers bleibt.
  /// Bei Fehler bleibt der Eintrag und der nächste Takt versucht es erneut.
  private func release(_ record: AutoStatusRecord, target: StatusSetting?) async {
    guard let target else { try? repo.delete(record.accountId); return }
    do {
      let current = try await target.readStatus()
      if target.ownsStatus(current, record: record) {
        try await target.writeStatus(text: "", emoji: "", until: nil)
      }
      try repo.delete(record.accountId)
      onHint(record.accountId, nil)
    } catch {
      onHint(record.accountId, Self.hint(error))
    }
  }

  private static func hint(_ error: Error) -> String {
    (error as? MessengerFailure)?.message ?? "Status konnte nicht gesetzt werden."
  }
}
