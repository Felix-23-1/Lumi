// Vorlesen mit den Stimmen des Systems (AVSpeechSynthesizer): Briefing
// morgens, Tagesabschluss abends, Ansagen für Erinnerungen, Termine und
// Terminkonflikte. Alles lokal auf dem Mac.
import AVFoundation
import Foundation

public protocol Speaking: AnyObject {
  func speak(_ text: String, voice: String?)
  func stop()
  /// Spricht gerade (Gesprächsmodus wartet darauf, bevor er wieder zuhört).
  var isSpeaking: Bool { get }
}

/// Eine Stelle für alle Sprachausgaben: Lumi schweigt im Fokus und während eines Termins.
/// Gesperrte Ausgaben werden verworfen, nicht nachgeholt.
enum SpeechGate {
  static func silenced(focusRunning: Bool, events: [CalendarEvent], now: String) -> Bool {
    focusRunning || MeetingCompanion.running(events: events, now: now) != nil
  }
}

/// Sammelt Ansagen (Prüfungen).
public final class SinkSpeaker: Speaking {
  public private(set) var spoken: [String] = []
  public init() {}
  public func speak(_ text: String, voice: String?) { spoken.append(text) }
  public func stop() {}
  public var isSpeaking: Bool { false }
}

public final class SystemSpeaker: NSObject, Speaking {
  private let synth = AVSpeechSynthesizer()
  /// Kennung für „Systemstimme“: spricht über /usr/bin/say mit der in den Bedienungshilfen
  /// eingestellten Stimme. Nur so erreicht Lumi Siri-Stimmen (z. B. „Stimme 2“), die macOS
  /// Apps nicht direkt anbietet.
  public static let systemVoiceId = "system"
  private var sayQueue: [String] = []
  private var sayProcess: Process?
  private let sayLock = NSLock()

  public override init() { super.init() }

  public func speak(_ text: String, voice: String?) {
    if voice == Self.systemVoiceId {
      sayLock.lock(); sayQueue.append(SpeechText.clean(text)); let idle = sayProcess == nil; sayLock.unlock()
      if idle { sayNext() }
      return
    }
    let u = AVSpeechUtterance(string: SpeechText.clean(text))
    u.voice = voice.flatMap { $0.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: $0) }
      ?? Self.bestGermanVoice()
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
    u.postUtteranceDelay = 0.2
    synth.speak(u)
  }

  public var isSpeaking: Bool {
    sayLock.lock(); defer { sayLock.unlock() }
    return synth.isSpeaking || sayProcess != nil || !sayQueue.isEmpty
  }

  public func stop() {
    synth.stopSpeaking(at: .word)
    sayLock.lock(); sayQueue.removeAll(); let p = sayProcess; sayLock.unlock()
    // terminate() auf einen noch nicht gestarteten Prozess wirft eine ObjC-Ausnahme.
    if let p, p.isRunning { p.terminate() }
  }

  /// Nächsten Text über `say -f <datei>` sprechen (Text nie als Argument, keine Shell).
  private func sayNext() {
    sayLock.lock()
    guard sayProcess == nil, !sayQueue.isEmpty else { sayLock.unlock(); return }
    let text = sayQueue.removeFirst()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("taby-say-\(UUID().uuidString).txt")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-f", file.path]
    sayProcess = p
    sayLock.unlock()
    do {
      try text.write(to: file, atomically: true, encoding: .utf8)
      p.terminationHandler = { [weak self] _ in
        try? FileManager.default.removeItem(at: file)
        guard let self else { return }
        self.sayLock.lock(); self.sayProcess = nil; self.sayLock.unlock()
        self.sayNext()
      }
      try p.run()
    } catch {
      try? FileManager.default.removeItem(at: file)
      sayLock.lock(); sayProcess = nil; sayLock.unlock()
    }
  }

  /// Deutsche Stimmen, beste Qualität zuerst (Premium > Erweitert > Standard).
  public static func germanVoices() -> [VoiceInfo] {
    [VoiceInfo(id: systemVoiceId, name: "Systemstimme (z. B. Siri)", quality: "System")] + appVoices()
  }

  static func appVoices() -> [VoiceInfo] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("de") }
      .sorted { a, b in
        a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
      }
      .map { v in
        let q: String
        switch v.quality {
        case .premium: q = "Premium"
        case .enhanced: q = "Erweitert"
        default: q = "Standard"
        }
        return VoiceInfo(id: v.identifier, name: v.name, quality: q)
      }
  }

  static func bestGermanVoice() -> AVSpeechSynthesisVoice? {
    appVoices().first.flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
      ?? AVSpeechSynthesisVoice(language: "de-DE")
  }
}

/// Texte für Ansagen (rein, prüfbar).
public enum SpeechText {
  /// Markdown/Aufzählungszeichen entfernen, Uhrzeiten sprechbar lassen.
  public static func clean(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    t = t.replacingOccurrences(of: "#", with: "")
    t = t.split(separator: "\n").map { line in
      var l = line.trimmingCharacters(in: .whitespaces)
      if l.hasPrefix("- ") || l.hasPrefix("• ") || l.hasPrefix("* ") { l = String(l.dropFirst(2)) }
      return l
    }.filter { !$0.isEmpty }.joined(separator: ". ")
    return t.replacingOccurrences(of: "..", with: ".")
  }

  /// "Achtung: „Zahnarzt“ und „Meeting“ überschneiden sich heute um 10:00."
  public static func conflict(_ a: CalendarEvent, _ b: CalendarEvent, today: String) -> String {
    let day = LocalTime.datePart(a.start) == today ? "heute" : "am \(germanDate(LocalTime.datePart(a.start)))"
    let time = a.allDay ? "" : " um \(String(a.start.suffix(5)))"
    return "Achtung: „\(a.title)“ und „\(b.title)“ überschneiden sich \(day)\(time)."
  }

  /// Abendansage: offen, erledigt, erster Termin morgen.
  public static func evening(open: [TabyTask], doneToday: Int, firstTomorrow: CalendarEvent?) -> String {
    var parts = ["Feierabend!"]
    if doneToday > 0 { parts.append("Heute hast du \(doneToday) \(doneToday == 1 ? "Aufgabe" : "Aufgaben") erledigt.") }
    switch open.count {
    case 0: parts.append("Es ist nichts mehr offen.")
    case 1: parts.append("Noch offen ist „\(open[0].title)“.")
    default:
      let names = open.prefix(3).map { "„\($0.title)“" }.joined(separator: ", ")
      parts.append("Noch offen sind \(open.count) Aufgaben, zum Beispiel \(names).")
    }
    if let e = firstTomorrow {
      parts.append(e.allDay ? "Morgen steht „\(e.title)“ an." : "Morgen geht es um \(String(e.start.suffix(5))) mit „\(e.title)“ los.")
    }
    return parts.joined(separator: " ")
  }

  /// Vorlesen-Knopf: Termine, die in den nächsten `windowMinutes` beginnen, dann
  /// überfällige und heute offene Aufgaben. `now` ist "YYYY-MM-DDTHH:mm".
  public static func readAloud(events: [CalendarEvent], tasks: [TabyTask], now: String, windowMinutes: Int) -> String {
    let today = LocalTime.datePart(now)
    let end = LocalTime.parse(now).map { LocalTime.format($0.addingTimeInterval(Double(windowMinutes) * 60)) } ?? now
    let upcoming = events.filter { !$0.allDay && $0.start >= now && $0.start <= end }.sorted { $0.start < $1.start }
    let window = windowPhrase(windowMinutes)
    var parts: [String] = []
    switch upcoming.count {
    case 0: parts.append("\(window) hast du keine Termine.")
    case 1: parts.append("\(window): \(eventPhrase(upcoming[0], today: today)).")
    default:
      let shown = upcoming.prefix(5).map { eventPhrase($0, today: today) }
      let more = upcoming.count - shown.count
      let list = more > 0 ? shown.joined(separator: ", ") + " und \(more) weitere"
        : shown.dropLast().joined(separator: ", ") + " und " + shown.last!
      parts.append("\(window) hast du \(upcoming.count) Termine: \(list).")
    }
    let open = tasks.filter { !$0.done }
    let overdue = open.filter { t in
      guard let due = t.due else { return false }
      return LocalTime.isDateOnly(due) ? due < today : due < now
    }
    let rest = open.filter { t in !overdue.contains { $0.id == t.id } }
    if !overdue.isEmpty { parts.append("Überfällig: \(taskList(overdue)).") }
    if !rest.isEmpty { parts.append("Heute offen: \(taskList(rest)).") }
    if open.isEmpty { parts.append("Für heute ist keine Aufgabe offen.") }
    return parts.joined(separator: " ")
  }

  static func windowPhrase(_ minutes: Int) -> String {
    if minutes == 60 { return "In der nächsten Stunde" }
    if minutes % 60 == 0 { return "In den nächsten \(minutes / 60) Stunden" }
    return "In den nächsten \(minutes) Minuten"
  }

  static func eventPhrase(_ e: CalendarEvent, today: String) -> String {
    let day = LocalTime.datePart(e.start) == today ? "" : "morgen "
    return "\(day)um \(String(e.start.suffix(5))) „\(e.title)“"
  }

  static func taskList(_ tasks: [TabyTask]) -> String {
    let names = tasks.prefix(3).map { "„\($0.title)“" }.joined(separator: ", ")
    return tasks.count > 3 ? "\(names) und \(tasks.count - 3) weitere" : names
  }

  static func germanDate(_ d: String) -> String {
    let p = d.split(separator: "-")
    guard p.count == 3, let day = Int(p[2]), let month = Int(p[1]) else { return d }
    return "\(day). \(month)."
  }
}
