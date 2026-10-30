// Diktat mit der Apple-Spracherkennung (Speech) und dem Mikrofon
// (AVAudioEngine). Auf dem Mac, wenn das deutsche Modell dafür vorhanden ist.
import AVFoundation
import Foundation
import Speech

@MainActor
public final class SpeechRecognizer {
  public typealias TextHandler = @MainActor (String, Bool) -> Void
  public typealias ErrorHandler = @MainActor (String) -> Void

  /// Harte Obergrenze einer Aufnahme.
  private static let maxDuration: UInt64 = 60_000_000_000

  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var onText: TextHandler?
  private var onError: ErrorHandler?
  /// Lautester Pegel der laufenden Aufnahme (0 = das Mikrofon liefert nur Stille).
  private var level = AudioLevel()
  private var recognitionError: String?
  /// Erhöht sich bei jedem Start/Stopp; alte Erkennungs-Rückrufe werden verworfen.
  private var generation = 0
  private var latest = ""
  private var finalSeen = false
  private var finalDelivered = false
  private var running = false
  private var stopping = false

  public init() {}

  public var isRunning: Bool { running }

  /// Fragt Spracherkennung und Mikrofon an; true nur, wenn beides erteilt ist.
  public static func requestAccess() async -> Bool {
    let speech = await speechAllowed()
    let mic = await micAllowed()
    return speech && mic
  }

  private static func speechAllowed() async -> Bool {
    if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
    }
  }

  private static func micAllowed() async -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      AVCaptureDevice.requestAccess(for: .audio) { granted in cont.resume(returning: granted) }
    }
  }

  /// Startet die Aufnahme. Teiltexte kommen als onText(text, false), der Schluss als onText(text, true).
  /// Kommt kein Text, weil die Erkennung abbricht oder das Mikrofon stumm ist, meldet onError den Grund.
  public func start(onText: @escaping TextHandler, onError: ErrorHandler? = nil) async -> ToolResult<Empty> {
    if running || stopping { return .failure(code: "BUSY", error: "Die Spracheingabe läuft schon.") }
    guard await Self.requestAccess() else {
      return .failure(code: "PERMISSION", error: "Lumi darf das Mikrofon oder die Spracherkennung nicht nutzen. Systemeinstellungen → Datenschutz & Sicherheit.")
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")), recognizer.isAvailable else {
      return .failure(code: "UNAVAILABLE", error: "Spracherkennung ist gerade nicht verfügbar.")
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    // Nicht erzwingen: ohne geladenes deutsches Diktat-Paket nahm macOS auf, erkannte aber still nichts.
    // macOS nimmt die Erkennung auf dem Mac, sobald das Paket da ist, sonst Apples Diktat-Dienst.
    req.requiresOnDeviceRecognition = false

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return .failure(code: "AUDIO", error: "Das Mikrofon liefert kein Signal.")
    }
    let level = AudioLevel()
    input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(req, level: level))
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      return .failure(code: "AUDIO", error: "Das Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)")
    }

    generation += 1
    let gen = generation
    latest = ""
    finalSeen = false
    finalDelivered = false
    self.onText = onText
    self.onError = onError
    self.level = level
    recognitionError = nil
    request = req
    running = true
    task = recognizer.recognitionTask(with: req, resultHandler: Self.resultHandler { [weak self] text, isFinal, error in
      self?.handle(gen, text: text, isFinal: isFinal, error: error)
    })

    // Nach 60 s automatisch beenden.
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.maxDuration)
      guard let self, self.running, self.generation == gen else { return }
      _ = await self.stop()
    }
    return .ok(Empty())
  }

  /// Beendet die Aufnahme, wartet bis zu 1,5 s auf das Schlussergebnis und liefert den besten Text.
  public func stop() async -> String {
    guard running else { return "" }
    running = false
    stopping = true
    let gen = generation

    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    request?.endAudio()

    var waited = 0
    while !finalSeen && waited < 30 && generation == gen {
      try? await Task.sleep(nanoseconds: 50_000_000)
      waited += 1
    }
    deliverFinal()
    let text = Self.cleanTranscript(latest)
    if text.isEmpty, let problem = Self.emptyResultReason(peak: level.peak, seconds: level.seconds, error: recognitionError) {
      TabyLog.error(.core, "Diktat: \(problem)")
      onError?(problem)
    }

    task?.cancel()
    task = nil
    request = nil
    onText = nil
    onError = nil
    generation += 1
    stopping = false
    return text
  }

  // Rückrufe laufen auf Audio-/Hintergrund-Threads: außerhalb des MainActors
  // bauen, damit sie nicht als MainActor-isoliert gelten.
  private nonisolated static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest, level: AudioLevel) -> AVAudioNodeTapBlock {
    { buffer, _ in
      level.record(buffer)
      req.append(buffer)
    }
  }

  private nonisolated static func resultHandler(
    _ forward: @escaping @MainActor (String?, Bool, String?) -> Void
  ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
    { result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = (result?.isFinal ?? false) || error != nil
      let message = error.map { e -> String in
        let ns = e as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
      }
      Task { @MainActor in forward(text, isFinal, message) }
    }
  }

  private func handle(_ gen: Int, text: String?, isFinal: Bool, error: String? = nil) {
    guard gen == generation, let onText else { return }
    if let error { recognitionError = error }
    if let text { latest = text }
    if isFinal {
      deliverFinal()
      if running { Task { _ = await self.stop() } }
    } else {
      onText(Self.cleanTranscript(latest), false)
    }
  }

  private func deliverFinal() {
    guard !finalDelivered, let onText else { return }
    finalDelivered = true
    finalSeen = true
    onText(Self.cleanTranscript(latest), true)
  }

  /// Warum nach einer Aufnahme kein Text da ist (nil = einfach nichts gesagt).
  /// `peak` ist der lauteste Abtastwert (0…1), `seconds` die aufgenommene Länge,
  /// `error` der Fehler der Erkennung. Kürzer als eine halbe Sekunde zählt nicht als Stille.
  public static func emptyResultReason(peak: Float, seconds: Double, error: String?) -> String? {
    if seconds >= 0.5 && peak < 0.00001 {
      return "Das Mikrofon liefert nur Stille. Prüfe Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon (Lumi aus- und wieder einschalten) und das Eingabegerät unter Ton."
    }
    if let error {
      return "Die Spracherkennung hat abgebrochen (\(error)). Prüfe Systemeinstellungen → Tastatur → Diktat: an, Sprache Deutsch."
    }
    if seconds >= 1 && peak >= 0.01 {
      return "Ich habe dich gehört, aber keinen Text erkannt. Prüfe Systemeinstellungen → Tastatur → Diktat: an, Sprache Deutsch (Sprachpaket geladen)."
    }
    return nil
  }

  /// Text aufräumen: Leerraum zusammenziehen, erster Buchstabe groß.
  public static func cleanTranscript(_ s: String) -> String {
    let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard let first = collapsed.first else { return "" }
    return first.uppercased() + collapsed.dropFirst()
  }
}

/// Lautester Pegel einer Aufnahme; wird vom Audio-Thread beschrieben.
final class AudioLevel: @unchecked Sendable {
  private let lock = NSLock()
  private var max: Float = 0
  private var duration: Double = 0

  var peak: Float { lock.lock(); defer { lock.unlock() }; return max }
  var seconds: Double { lock.lock(); defer { lock.unlock() }; return duration }

  func record(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    var local: Float = 0
    for i in 0..<Int(buffer.frameLength) { local = Swift.max(local, abs(data[0][i])) }
    let length = Double(buffer.frameLength) / Swift.max(buffer.format.sampleRate, 1)
    lock.lock(); if local > max { max = local }; duration += length; lock.unlock()
  }
}
