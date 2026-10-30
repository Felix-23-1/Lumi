import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  // MARK: Sprache

  /// Spricht, wenn eingeschaltet (Briefings bzw. Ansagen getrennt schaltbar).
  func say(_ text: String, briefing: Bool) {
    let s = settings
    guard s.voiceEnabled, briefing ? s.voiceBriefings : s.voiceAlerts, speechAllowed() else { return }
    speaker.speak(text, voice: s.voiceName.isEmpty ? nil : s.voiceName)
  }

  /// Schweigt im Fokus und während eines Termins; jede Sprachausgabe fragt hier.
  /// Termine kommen aus dem Takt (`packageFourTick`), daher ist die Liste höchstens 30 s alt.
  func speechAllowed() -> Bool {
    let focusRunning = ((try? store.focus.current()) ?? nil) != nil
    return listenSession == nil && !SpeechGate.silenced(focusRunning: focusRunning, events: p4.todayEvents, now: LocalTime.format(clock.now()))
  }

  /// Ausdrücklich gewünschtes Vorlesen während Fokus oder Termin: kurzer Hinweis statt Stille.
  private func emitSilencedHint() {
    emit(.flash(TabyNotification(title: "Stumm", body: "Im Fokus oder Termin bleibt Lumi still.")))
  }

  /// Doppelt belegte Zeiten (heute und demnächst) – jedes Paar einmal ansagen.
  func announceNewConflicts(_ ov: Overview) {
    let events = (ov.eventsToday + ov.eventsUpcoming).filter { !$0.allDay }
    // Ohne Änderung der Termine gibt es keine neuen Konflikte: den Paarvergleich (O(n²)) dann überspringen.
    let scanKey = events.map { "\($0.id)|\($0.title)|\($0.start)|\($0.end ?? "")" }.joined(separator: "\n")
    guard scanKey != conflictScanKey else { return }
    conflictScanKey = scanKey
    let today = LocalTime.formatDate(clock.now())
    for (i, a) in events.enumerated() {
      let rest = Array(events[(i + 1)...])
      for c in findConflicts(NewEvent(title: a.title, start: a.start, end: a.end), rest) {
        let key = [a.id, c.with.id].sorted().joined(separator: "|")
        guard !announcedConflicts.contains(key) else { continue }
        announcedConflicts.insert(key)
        say(SpeechText.conflict(a, c.with, today: today), briefing: false)
      }
    }
  }

  /// Abendansage zum Tagesabschluss.
  func speakEvening() async {
    let ov = await overview()
    let today = LocalTime.formatDate(clock.now())
    guard let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: clock.now()) else { return }
    let tomorrow = LocalTime.formatDate(tomorrowDate)
    let dayAfter = LocalTime.formatDate(Calendar.current.date(byAdding: .day, value: 2, to: clock.now()) ?? tomorrowDate)
    let open = (ov.overdueTasks + ov.todayTasks).filter { !$0.done }
    let doneToday = ((try? store.tasks.list()) ?? []).filter { $0.done && ($0.doneAt.map { LocalTime.datePart($0) } == today) }.count
    let first = await calendarAccess.listAllEvents(from: tomorrow, to: dayAfter).events.sorted { $0.start < $1.start }
      .first { !$0.allDay } ?? nil
    say(SpeechText.evening(open: open, doneToday: doneToday, firstTomorrow: first), briefing: true)
  }

  /// Vorlesen-Knopf: spricht immer (unabhängig von voiceEnabled/voiceAlerts), weil der Nutzer es auslöst.
  public func speakOverview() async {
    guard speechAllowed() else { return emitSilencedHint() }
    let s = settings
    let now = clock.now()
    let window = min(max(s.readAloudMinutes, 5), 1440)
    let from = LocalTime.formatDate(now)
    let to = LocalTime.formatDate(Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now)
    let events = await calendarAccess.listAllEvents(from: from, to: to).events
    let ov = await overview()
    let text = SpeechText.readAloud(events: events, tasks: ov.overdueTasks + ov.todayTasks,
                                    now: LocalTime.format(now), windowMinutes: window)
    speaker.stop()
    speaker.speak(text, voice: s.voiceName.isEmpty ? nil : s.voiceName)
  }

  public func availableVoices() async -> [VoiceInfo] { SystemSpeaker.germanVoices() }

  public func previewVoice(_ id: String?) async {
    guard speechAllowed() else { return emitSilencedHint() }
    speaker.stop()
    speaker.speak("Hallo, ich bin Lumi. So klinge ich, wenn ich dir dein Briefing vorlese.",
                  voice: id ?? (settings.voiceName.isEmpty ? nil : settings.voiceName))
  }

  public func stopSpeaking() async { speaker.stop() }

  /// Gesprächsmodus: vom Nutzer gewollt, daher auch ohne eingeschaltete Ansagen.
  public func speakReply(_ text: String) async {
    let s = settings
    speaker.stop()
    speaker.speak(text, voice: s.voiceName.isEmpty ? nil : s.voiceName)
    try? await Task.sleep(for: .milliseconds(300))
    // Höchstens 2 Minuten warten (hängt eine Stimme, hört Lumi trotzdem wieder zu).
    for _ in 0..<600 where speaker.isSpeaking && !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  public func stopSpeaking() { speaker.stop() }
}
