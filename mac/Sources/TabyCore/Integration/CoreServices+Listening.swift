// Lokale Mitschrift in die Termin-Notiz (Abschnitt "Mitschrift"). Das Einwilligungs-Tor, das Zeilenformat,
// die Bündelung und das Beenden sind Code; die Quelle (`AudioTextSource`) liefert nur Text.
// Zeilenformat (von der Aufgaben-Erkennung gelesen): "- [mm:ss] Ich: Text" / "- [mm:ss] Andere: Text".
import Foundation

/// Laufende Mitschrift (nur im Speicher).
@MainActor
final class ListenSession {
  var info: MeetingListening
  let source: AudioTextSource
  let noteKey: String
  let started: Date
  /// Spätestens dann endet die Mitschrift von selbst (Ende des Termins + 15 Minuten).
  let autoStop: Date?
  var pending: [String] = []
  var lastFlush: Date
  var ticker: Task<Void, Never>?

  init(info: MeetingListening, source: AudioTextSource, noteKey: String, started: Date, autoStop: Date?) {
    self.info = info; self.source = source; self.noteKey = noteKey; self.started = started
    self.autoStop = autoStop; self.lastFlush = started
  }
}

extension CoreServices {
  static let listenFlushSeconds: TimeInterval = 5
  static let listenFlushLines = 10
  static let listenGraceMinutes = 15

  private func listenTime(_ date: Date) -> String { LocalTime.formatTime(date) }

  private func listenEvent(_ id: String) async -> (title: String, end: String?)? {
    if let m = p4.meeting, m.id == id { return (m.title, m.end) }
    if let a = Self.adhoc(id) { return (a.title, nil) }
    guard let e = await todaysEvents().first(where: { MeetingCompanion.key($0) == id }) else { return nil }
    return (e.title, e.end)
  }

  public func startMeetingListening(_ id: String, mode: MeetingListenMode, consentGiven: Bool) async -> ToolResult<Empty> {
    // Nur eine Mitschrift gleichzeitig; dieselbe noch einmal zu starten ändert nichts.
    if let s = listenSession {
      return s.info.meetingId == id && s.info.mode == mode ? .ok(Empty())
        : .failure(code: "BUSY", error: "Es läuft schon eine Mitschrift (\(s.info.title)). Beende sie zuerst.")
    }
    // Einwilligungs-Tor: ohne Zustimmung aller Teilnehmer wird der Systemton nicht angefasst.
    if mode == .everyone && !consentGiven {
      return .failure(code: "CONSENT", error: "Bitte bestätige zuerst, dass alle Teilnehmer wissen, dass mitgeschrieben wird.")
    }
    let event = await listenEvent(id)
    var existing = (try? store.notes.get(meetingKey: id)) ?? nil
    if existing == nil {
      switch await prepareMeeting(id, noteIds: [], taskIds: []) {
      case .ok(let note): existing = note
      case .failure(_, let error): return .failure(code: "NOT_FOUND", error: error)
      }
    }
    guard let note = existing else { return .failure(code: "NOT_FOUND", error: "Termin nicht gefunden.") }
    if listenSession != nil { return .failure(code: "BUSY", error: "Es läuft schon eine Mitschrift.") }  // während der Vorbereitung gestartet

    let now = clock.now()
    let source = audioSourceFactory()
    let end = event?.end.flatMap { LocalTime.parse($0) }
    let consentAt = mode == .everyone ? LocalTime.format(now) : nil
    let session = ListenSession(
      info: MeetingListening(meetingId: id, title: event?.title ?? note.title, mode: mode,
                             startedAt: LocalTime.format(now), consentAt: consentAt),
      source: source, noteKey: id, started: now,
      autoStop: end.map { $0.addingTimeInterval(Double(Self.listenGraceMinutes) * 60) })
    listenSession = session  // vor dem Start setzen: schließt parallele Starts aus

    let result = await source.start(
      mode: mode,
      onText: { [weak self, weak session] who, text, final in
        guard final, let self, let session else { return }
        self.listenReceived(session, speaker: who, text: text)
      },
      onFailure: { [weak self, weak session] message in
        guard let self, let session, self.listenSession === session else { return }
        self.finishListening(reason: message)
      })
    guard result.isOk else {
      if listenSession === session { listenSession = nil }
      return result
    }
    if let consentAt { session.pending.append("- Einwilligung aller Teilnehmer bestätigt um \(String(consentAt.suffix(5)))") }
    flushListening(session)
    session.ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(Self.listenFlushSeconds * 1_000_000_000))
        await self?.listenTick()
      }
    }
    emit(.stateChanged)
    return .ok(Empty())
  }

  public func stopMeetingListening() async {
    guard listenSession != nil else { return }
    finishListening(reason: nil)
  }

  public func markMeetingMoment() async {
    guard let s = listenSession else { return }
    s.pending.append("- \(MeetingPrep.stamp(seconds: elapsed(s))) ★ Merker")
    s.info.markers += 1
    flushListening(s)
    emit(.stateChanged)
  }

  /// Takt: gesammelte Zeilen schreiben, am Ende des Termins + 15 Minuten beenden.
  func listenTick() async {
    guard let s = listenSession else { return }
    if let stop = s.autoStop, clock.now() >= stop {
      finishListening(reason: "Der Termin ist vorbei, die Mitschrift wurde beendet.")
    } else {
      flushListening(s)
    }
  }

  /// Beendet die laufende Mitschrift: Rest schreiben, Abschlusszeile, Quelle stoppen. `reason` erscheint als Hinweis.
  func finishListening(reason: String?) {
    guard let s = listenSession else { return }
    listenSession = nil
    s.ticker?.cancel()
    s.pending.append("- Mitschrift beendet um \(listenTime(clock.now()))")
    flushListening(s, force: true)
    let source = s.source
    Task { await source.stop() }
    if let reason { emit(.flash(TabyNotification(title: "Mitschrift beendet", body: reason))) }
    emit(.stateChanged)
  }

  private func elapsed(_ s: ListenSession) -> Int { Int(clock.now().timeIntervalSince(s.started)) }

  private func listenReceived(_ s: ListenSession, speaker: ListenSpeaker, text: String) {
    guard listenSession === s else { return }
    let line = MeetingPrep.transcriptLine(seconds: elapsed(s), speaker: speaker.rawValue, text: text)
    guard !line.hasSuffix(": ") else { return }  // leerer Text
    s.pending.append(line)
    s.info.lines += 1
    if s.pending.count >= Self.listenFlushLines || clock.now().timeIntervalSince(s.lastFlush) >= Self.listenFlushSeconds {
      flushListening(s)
    }
    emit(.stateChanged)
  }

  /// Schreibt die gesammelten Zeilen in die Termin-Notiz (ein Schreibvorgang für alle).
  private func flushListening(_ s: ListenSession, force: Bool = false) {
    s.lastFlush = clock.now()
    guard !s.pending.isEmpty else { return }
    guard let note = (try? store.notes.get(meetingKey: s.noteKey)) ?? nil else { return }
    let content = MeetingPrep.appendingMitschrift(s.pending, to: note.content)
    if (try? store.notes.update(note.id, content: content)) != nil { s.pending = [] }
  }
}
