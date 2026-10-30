// Lokale Mitschrift eines Online-Meetings: Mikrofon ("Ich") und optional Systemton ("Andere")
// werden auf dem Mac in Text umgewandelt. Audio wird nie gespeichert, nur Text; kein Bot, keine Cloud.
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

public enum ListenSpeaker: String, Sendable {
  case me = "Ich"
  case others = "Andere"
}

/// Grenze zum Ton: liefert fortlaufend erkannten Text. Nur finale Ergebnisse, keine Teiltexte.
public protocol AudioTextSource: AnyObject {
  /// Startet die Quelle. Fehlt eine Freigabe, bricht der Start sauber ab (nichts läuft).
  /// `onFailure` meldet einen Ausfall während des Betriebs (die Quelle ist dann beendet).
  @MainActor func start(mode: MeetingListenMode,
                        onText: @escaping @MainActor (_ speaker: ListenSpeaker, _ text: String, _ final: Bool) -> Void,
                        onFailure: @escaping @MainActor (String) -> Void) async -> ToolResult<Empty>
  @MainActor func stop() async
}

/// Attrappe für Prüfungen: Text und Ausfall werden von Hand eingespeist.
@MainActor
public final class FakeAudioTextSource: AudioTextSource {
  public var startResult: ToolResult<Empty> = .ok(Empty())
  public private(set) var startedModes: [MeetingListenMode] = []
  public private(set) var stopCount = 0
  public private(set) var running = false
  private var onText: (@MainActor (ListenSpeaker, String, Bool) -> Void)?
  private var onFailure: (@MainActor (String) -> Void)?

  public init() {}

  public func start(mode: MeetingListenMode,
                    onText: @escaping @MainActor (ListenSpeaker, String, Bool) -> Void,
                    onFailure: @escaping @MainActor (String) -> Void) async -> ToolResult<Empty> {
    startedModes.append(mode)
    guard startResult.isOk else { return startResult }
    self.onText = onText; self.onFailure = onFailure; running = true
    return .ok(Empty())
  }

  public func stop() async { stopCount += 1; running = false; onText = nil; onFailure = nil }

  public func say(_ speaker: ListenSpeaker, _ text: String, final: Bool = true) { onText?(speaker, text, final) }
  public func fail(_ message: String) { onFailure?(message) }
}

// MARK: - Erkennung je Quelle

/// Eine Erkennung für einen Tonstrom. Apple begrenzt eine Sitzung auf etwa eine Minute; darum wird die
/// Task bei Ablauf, bei Fehler und nach einer Sprechpause neu gestartet. Geliefert werden nur finale Texte.
final class RecognitionLane: @unchecked Sendable {
  private final class Session {
    let request = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    var latest = ""
    var delivered = false
    let started = ProcessInfo.processInfo.systemUptime
    var lastChange = ProcessInfo.processInfo.systemUptime
  }

  static let maxSession: TimeInterval = 50
  static let pause: TimeInterval = 2

  private let recognizer: SFSpeechRecognizer
  private let speaker: ListenSpeaker
  private let deliver: @Sendable (ListenSpeaker, String) -> Void
  private let fail: @Sendable (String) -> Void
  private let lock = NSLock()
  private var current: Session?
  private var open = 0  // Sitzungen, deren Schlusstext noch aussteht
  private var stopped = false
  private var errorStreak = 0

  init(recognizer: SFSpeechRecognizer, speaker: ListenSpeaker,
       deliver: @escaping @Sendable (ListenSpeaker, String) -> Void, fail: @escaping @Sendable (String) -> Void) {
    self.recognizer = recognizer; self.speaker = speaker; self.deliver = deliver; self.fail = fail
  }

  func begin() {
    lock.lock(); defer { lock.unlock() }
    beginLocked()
  }

  private func beginLocked() {
    guard !stopped else { return }
    let session = Session()
    session.request.shouldReportPartialResults = true
    session.request.requiresOnDeviceRecognition = true  // nie still in die Cloud
    session.request.taskHint = .dictation
    open += 1
    session.task = recognizer.recognitionTask(with: session.request) { [weak self] result, error in
      self?.handle(session, text: result?.bestTranscription.formattedString, isFinal: result?.isFinal ?? false,
                   failed: error != nil)
    }
    current = session
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock(); let request = current?.request; lock.unlock()
    request?.append(buffer)
  }

  private func handle(_ session: Session, text: String?, isFinal: Bool, failed: Bool) {
    var out: String?
    var give: String?
    lock.lock()
    if let text, !text.isEmpty {
      if text != session.latest { session.lastChange = ProcessInfo.processInfo.systemUptime }
      session.latest = text
      errorStreak = 0
    }
    if (isFinal || failed) && !session.delivered {
      session.delivered = true
      open -= 1
      if !session.latest.isEmpty { out = session.latest }
      if current === session {
        current = nil
        if failed && session.latest.isEmpty { errorStreak += 1 }
        // Fehler (z. B. "keine Sprache erkannt") beenden die Task: neu starten, aber nicht endlos bei Dauerfehler.
        if errorStreak >= 5 { give = "Die Spracherkennung bricht immer wieder ab. Prüfe Systemeinstellungen → Tastatur → Diktat (Deutsch)." }
        else { beginLocked() }
      }
    }
    lock.unlock()
    if let out { deliver(speaker, out) }
    if let give { fail(give) }
  }

  /// Einmal pro Sekunde: nach Sprechpause oder Ablauf die Sitzung beenden (der Schlusstext folgt von selbst) und neu starten.
  func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    if let s = current, !stopped {
      let paused = !s.latest.isEmpty && now - s.lastChange >= Self.pause
      if paused || now - s.started >= Self.maxSession {
        beginLocked()
        s.request.endAudio()
      }
    }
    lock.unlock()
  }

  /// Beendet die Erkennung und wartet bis zu 1,5 s auf ausstehende Schlusstexte.
  func finish() async {
    lock.lock(); stopped = true; let s = current; current = nil; lock.unlock()
    s?.request.endAudio()
    for _ in 0..<30 {
      lock.lock(); let pending = open; lock.unlock()
      if pending <= 0 { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    s?.task?.cancel()
  }
}

// MARK: - Systemton (ScreenCaptureKit)

private final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let lane: RecognitionLane
  let onStop: @Sendable (String) -> Void
  init(lane: RecognitionLane, onStop: @escaping @Sendable (String) -> Void) { self.lane = lane; self.onStop = onStop }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcm(sampleBuffer) else { return }
    lane.append(buffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onStop("Der Systemton ist ausgefallen: \(error.localizedDescription)")
  }

  static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = CMSampleBufferGetFormatDescription(sb),
          var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
          let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
    guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    pcm.frameLength = frames
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                              into: pcm.mutableAudioBufferList)
    return status == noErr ? pcm : nil
  }
}

// MARK: - Echte Quelle

@MainActor
public final class LiveMeetingListener: AudioTextSource {
  private let engine = AVAudioEngine()
  private var mic: RecognitionLane?
  private var system: RecognitionLane?
  private var stream: SCStream?
  private var tap: SystemAudioTap?
  private var ticker: Task<Void, Never>?
  private var onFailure: (@MainActor (String) -> Void)?
  private var running = false

  public init() {}

  public func start(mode: MeetingListenMode,
                    onText: @escaping @MainActor (ListenSpeaker, String, Bool) -> Void,
                    onFailure: @escaping @MainActor (String) -> Void) async -> ToolResult<Empty> {
    if running { return .failure(code: "BUSY", error: "Die Mitschrift läuft schon.") }
    if let problem = await Self.permissionProblem(mode: mode) { return .failure(code: "PERMISSION", error: problem) }
    guard let micRecognizer = Self.makeRecognizer() else {
      return .failure(code: "UNAVAILABLE", error: Self.onDeviceMissing)
    }

    let report: @Sendable (String) -> Void = { msg in Task { @MainActor [weak self] in self?.failed(msg) } }
    let deliver: @Sendable (ListenSpeaker, String) -> Void = { who, text in
      Task { @MainActor in onText(who, text, true) }
    }
    let micLane = RecognitionLane(recognizer: micRecognizer, speaker: .me, deliver: deliver, fail: report)

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return .failure(code: "AUDIO", error: "Das Mikrofon liefert kein Signal.")
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(micLane))
    engine.prepare()
    do { try engine.start() } catch {
      input.removeTap(onBus: 0)
      return .failure(code: "AUDIO", error: "Das Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)")
    }
    micLane.begin()
    mic = micLane

    if mode == .everyone {
      guard let sysRecognizer = Self.makeRecognizer() else {
        await teardown()
        return .failure(code: "UNAVAILABLE", error: Self.onDeviceMissing)
      }
      let lane = RecognitionLane(recognizer: sysRecognizer, speaker: .others, deliver: deliver, fail: report)
      if let problem = await startSystemAudio(lane: lane, report: report) {
        await teardown()
        return .failure(code: "AUDIO", error: problem)
      }
      system = lane
    }

    self.onFailure = onFailure
    running = true
    let lanes = [mic, system].compactMap { $0 }
    ticker = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        for lane in lanes { lane.tick() }
      }
    }
    return .ok(Empty())
  }

  public func stop() async {
    onFailure = nil
    running = false
    await teardown()
  }

  private func failed(_ message: String) {
    guard running else { return }
    let handler = onFailure
    running = false
    onFailure = nil
    Task { await teardown() }
    handler?(message)
  }

  private func teardown() async {
    ticker?.cancel(); ticker = nil
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    if let stream { try? await stream.stopCapture() }
    stream = nil; tap = nil
    await mic?.finish(); await system?.finish()
    mic = nil; system = nil
  }

  private func startSystemAudio(lane: RecognitionLane, report: @escaping @Sendable (String) -> Void) async -> String? {
    do {
      let content = try await SCShareableContent.current
      guard let display = content.displays.first else { return "Kein Bildschirm für den Systemton gefunden." }
      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true  // Lumis eigene Stimme nicht mitschreiben
      config.sampleRate = 48_000
      config.channelCount = 1
      config.width = 2; config.height = 2  // Bild wird nicht gebraucht, so klein wie möglich
      config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let tap = SystemAudioTap(lane: lane, onStop: report)
      let stream = SCStream(filter: filter, configuration: config, delegate: tap)
      try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: DispatchQueue(label: "lumi.listen.system"))
      try await stream.startCapture()
      lane.begin()
      self.stream = stream; self.tap = tap
      return nil
    } catch {
      return "Der Systemton konnte nicht gestartet werden (\(error.localizedDescription)). Prüfe Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme."
    }
  }

  // MARK: Freigaben und Erkennung

  private static let onDeviceMissing = "Die Spracherkennung auf dem Mac ist nicht verfügbar (Systemeinstellungen → Tastatur → Diktat: an, Sprache Deutsch, Sprachpaket geladen). Lumi schreibt nie über die Cloud mit."

  /// Erkennung für Deutsch, nur wenn sie auf dem Mac läuft (sonst nil statt stiller Cloud-Erkennung).
  private static func makeRecognizer() -> SFSpeechRecognizer? {
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")), r.isAvailable, r.supportsOnDeviceRecognition
    else { return nil }
    return r
  }

  /// Deutsche Meldung, wenn eine Freigabe fehlt; nil = alles erteilt.
  private static func permissionProblem(mode: MeetingListenMode) async -> String? {
    let speech: Bool
    if SFSpeechRecognizer.authorizationStatus() == .authorized { speech = true } else {
      speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
      }
    }
    guard speech else {
      return "Lumi darf die Spracherkennung nicht nutzen. Systemeinstellungen → Datenschutz & Sicherheit → Spracherkennung."
    }
    let mic: Bool
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { mic = true } else {
      mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
      }
    }
    guard mic else {
      return "Lumi darf das Mikrofon nicht nutzen. Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."
    }
    if mode == .everyone, !CGPreflightScreenCaptureAccess() {
      _ = CGRequestScreenCaptureAccess()
      return "Für den Ton der anderen braucht Lumi die Freigabe „Bildschirm- & Systemaudioaufnahme“ (Systemeinstellungen → Datenschutz & Sicherheit). Danach Lumi neu öffnen und noch einmal starten."
    }
    return nil
  }

  private nonisolated static func tapBlock(_ lane: RecognitionLane) -> AVAudioNodeTapBlock {
    { buffer, _ in lane.append(buffer) }
  }
}
