// Reine Regeln für die Zusatzszenen des Maskottchens: Requisiten, Tageszeit,
// Feiertagsmützen, Streicheln, Schütteln, Gummi-Ziehen, Glühbirne und die
// Rangfolge, nach der sich das alles überlagert. Alles ist eine Funktion der
// Zeit und der Eingaben (keine Uhr, keine Ansicht), damit Prüfungen und
// Snapshots stillstehen können.
import CoreGraphics
import Foundation
import SwiftUI
import TabyCore

// MARK: - Umgebung (Uhr und Momentaufnahme vom Store)

private struct MascotClockKey: EnvironmentKey {
  static let defaultValue: () -> Double = { Date().timeIntervalSinceReferenceDate }
}

private struct MascotContextKey: EnvironmentKey {
  static let defaultValue: (Double) -> MascotContext = { _ in MascotContext() }
}

extension EnvironmentValues {
  /// Uhr der Ereignisse (die Insel setzt die Store-Uhr; Snapshots können sie ersetzen).
  var mascotClock: () -> Double {
    get { self[MascotClockKey.self] }
    set { self[MascotClockKey.self] = newValue }
  }

  /// Momentaufnahme für das Maskottchen zu einem Zeitpunkt der Store-Uhr.
  var mascotContextProvider: (Double) -> MascotContext {
    get { self[MascotContextKey.self] }
    set { self[MascotContextKey.self] = newValue }
  }
}

// MARK: - Requisiten

/// Gegenstand, den Lumi in der rechten Hand hält (Arm oben).
public enum MascotProp: String, Equatable, Sendable { case envelope, laptop }

/// Ein Requisit mit Startzeit (Store-Uhr, Sekunden).
struct MascotPropEvent: Equatable, Sendable {
  static let duration: Double = 3
  let prop: MascotProp
  let startedAt: Double

  /// Sekunden seit Beginn, solange das Requisit gezeigt wird.
  func elapsed(at now: Double) -> Double? {
    let e = now - startedAt
    return e >= 0 && e < Self.duration ? e : nil
  }
}

// MARK: - Feiertage und Geburtstag

/// Mütze zu Feiertagen oder am Geburtstag.
enum MascotDecor: String, Equatable, Sendable {
  case santa, pumpkin, party

  /// `date` lokal "YYYY-MM-DD…", `birthday` "MM-DD" (leer = keiner).
  /// Weihnachtsmütze 1.–26. Dezember, Kürbis am 31. Oktober, Partyhut am Geburtstag.
  static func `for`(date: String, birthday: String, enabled: Bool) -> MascotDecor? {
    guard enabled, date.count >= 10 else { return nil }
    let md = String(date.dropFirst(5).prefix(5))
    if !birthday.isEmpty, md == birthday { return .party }
    let month = Int(md.prefix(2)) ?? 0
    let day = Int(md.suffix(2)) ?? 0
    if month == 12, (1...26).contains(day) { return .santa }
    if month == 10, day == 31 { return .pumpkin }
    return nil
  }
}

// MARK: - Tageszeit

/// Tagesabschnitt nach der lokalen Stunde.
enum MascotDaypart: Equatable, Sendable {
  case night, morning, day, evening

  /// 0–5 Uhr schläft Lumi, 6–8 gähnt es, 21–23 trägt es die Schlafmütze.
  static func at(hour: Int) -> MascotDaypart {
    switch hour {
    case 0..<6: .night
    case 6..<9: .morning
    case 21..<24: .evening
    default: .day
    }
  }
}

/// Gähnen am Morgen: alle 25 s, rund 2,4 s lang.
enum MascotYawn {
  static let period: Double = 25
  static let length: Double = 2.4

  /// Stärke 0…1 (0 = gerade kein Gähnen).
  static func amount(at now: Double, daypart: MascotDaypart) -> CGFloat {
    guard daypart == .morning, now >= 0 else { return 0 }
    let p = now.truncatingRemainder(dividingBy: period)
    guard p < length else { return 0 }
    return CGFloat(sin(Double.pi * p / length))
  }
}

// MARK: - Streicheln und Schütteln

/// Streicheln: die Maus ruht länger als 0,8 s auf dem Maskottchen.
enum MascotPetting {
  static let delay: Double = 0.8

  static func active(hoverStart: Double?, now: Double) -> Bool {
    guard let s = hoverStart else { return false }
    return now - s > delay
  }
}

/// Mauspunkt mit Zeitstempel (Store-Uhr), nur für die Schwindel-Erkennung.
struct MascotPointerSample: Equatable, Sendable {
  let t: Double
  let x: CGFloat
}

/// Schütteln: mindestens 4 Richtungswechsel innerhalb 1 s → schwindelig für 2 s.
enum MascotShake {
  static let window: Double = 1
  static let minReversals = 4
  static let minStep: CGFloat = 2
  static let dizzyDuration: Double = 2

  /// `samples` in zeitlicher Reihenfolge.
  static func isDizzy(_ samples: [MascotPointerSample], now: Double) -> Bool {
    let recent = samples.filter { $0.t <= now && now - $0.t <= window }
    var reversals = 0
    var lastSign = 0
    for (a, b) in zip(recent, recent.dropFirst()) {
      let d = b.x - a.x
      guard abs(d) >= minStep else { continue }
      let sign = d > 0 ? 1 : -1
      if lastSign != 0, sign != lastSign { reversals += 1 }
      lastSign = sign
    }
    return reversals >= minReversals
  }

  static func dizzyActive(since start: Double?, now: Double) -> Bool {
    guard let s = start else { return false }
    return now >= s && now - s < dizzyDuration
  }
}

// MARK: - Gummi-Ziehen

/// Loslassen nach dem Ziehen: Versatz und Zeitpunkt (Store-Uhr).
struct MascotRelease: Equatable, Sendable {
  let startedAt: Double
  let vector: CGSize
}

/// Der Körper streckt sich in Zugrichtung und federt beim Loslassen zurück.
enum MascotStretch {
  static let maxScale: CGFloat = 1.35
  /// Nach dieser Zeit ist die Feder vollständig abgeklungen (Streckung = 1,0).
  static let settleTime: Double = 1.6

  /// Winkel (Grad) und Streckfaktor (1 … 1,35) für einen Versatz in Punkten.
  static func shape(for v: CGSize) -> (angle: Double, scale: CGFloat) {
    let m = hypot(v.width, v.height)
    guard m > 0.5 else { return (0, 1) }
    return (Double(atan2(v.height, v.width)) * 180 / .pi, min(maxScale, 1 + m / 160))
  }

  /// Gedämpfte Feder: 1 beim Loslassen, überschwingt kurz (Vorzeichenwechsel), dann 0.
  static func released(_ v: CGSize, sinceRelease t: Double) -> CGSize {
    guard t >= 0, t < settleTime else { return .zero }
    let f = exp(-4.5 * t) * cos(2 * Double.pi * 2.2 * t)
    return CGSize(width: v.width * f, height: v.height * f)
  }

  static func isSettling(_ r: MascotRelease?, now: Double) -> Bool {
    guard let r else { return false }
    return now - r.startedAt < settleTime
  }
}

// MARK: - Glühbirne

/// Glühbirne über dem Kopf, wenn eine Antwort angekommen ist: auftauchen, halten, verschwinden.
enum MascotBulb {
  static let duration: Double = 1.5

  /// Sichtbarkeit 0…1 (nil = nicht zu sehen).
  static func visibility(startedAt s: Double?, now: Double) -> CGFloat? {
    guard let s, now >= s else { return nil }
    let e = now - s
    guard e < duration else { return nil }
    // Auftauchen mit leichtem Überschwingen (easeOutBack).
    let x = min(1, e / 0.3) - 1
    let c1 = 1.70158, c3 = c1 + 1
    let pop = 1 + c3 * pow(x, 3) + c1 * pow(x, 2)
    let fade = e > duration - 0.3 ? (duration - e) / 0.3 : 1
    return CGFloat(max(0, min(1.1, pop)) * fade)
  }
}

// MARK: - Rangfolge und Szene

/// Gesichtsüberschreibung. Rangfolge: Ziehen > Streicheln > Schwindel > Klick-Einlage > Tageszeit.
enum MascotFace: Equatable, Sendable { case normal, petting, dizzy, yawn, asleep }

/// Momentaufnahme aller Eingaben, die die Zusatzszenen brauchen (vom Store).
struct MascotContext: Equatable, Sendable {
  var islandOpen = false
  var typing = false
  var focus: FocusSession.Phase?
  var daypart: MascotDaypart = .day
  var decor: MascotDecor?
  var prop: MascotPropEvent?
  var bulbStart: Double?
  var hoverStart: Double?
  var dizzyStart: Double?
  var drag: CGSize?
  var release: MascotRelease?
  /// Kleine Mikro-Bewegung im offenen oder Peek-Zustand (nil = keine).
  var micro: MascotMicroShow? = nil

  var withoutMicro: MascotContext { var c = self; c.micro = nil; return c }
}

/// Kleine Bewegungen zwischendurch, damit Lumi nicht starr wirkt.
enum MascotMicroMove: CaseIterable, Sendable { case glanceLeft, glanceRight, doubleBlink, tinyBounce, lean }

struct MascotMicroShow: Equatable, Sendable {
  let move: MascotMicroMove
  let elapsed: Double
}

/// Plant alle 4–8 s (Zufall injizierbar) eine Mikro-Bewegung. Läuft nur, solange die Figur
/// sichtbar und wach ist; sonst wird alles zurückgesetzt. Kein eigener Takt: der Store ruft `tick` auf.
struct MascotLiveliness: Equatable, Sendable {
  static let minGap = 4.0
  static let maxGap = 8.0
  static let duration = 1.2

  private(set) var nextAt: Double?
  private(set) var move: MascotMicroMove?
  private(set) var startedAt = 0.0

  /// `random(n)` liefert eine Zahl in 0..<n.
  mutating func tick(now: Double, active: Bool, random: (Int) -> Int) {
    guard active else { self = MascotLiveliness(); return }
    if nextAt == nil { nextAt = now + Self.gap(random) }
    if move != nil, now - startedAt >= Self.duration { move = nil }
    guard move == nil, let due = nextAt, now >= due else { return }
    let all = MascotMicroMove.allCases
    move = all[min(max(random(all.count), 0), all.count - 1)]
    startedAt = now
    nextAt = now + Self.gap(random)
  }

  /// Laufende Bewegung zur Store-Uhr `now`, sonst nil.
  func show(at now: Double) -> MascotMicroShow? {
    guard let m = move, now >= startedAt, now - startedAt < Self.duration else { return nil }
    return MascotMicroShow(move: m, elapsed: now - startedAt)
  }

  /// Abstand in Sekunden, gleichmäßig in minGap…maxGap (Schritte von 1 ms).
  static func gap(_ random: (Int) -> Int) -> Double {
    let steps = Int((maxGap - minGap) * 1000)
    return minGap + Double(min(max(random(steps + 1), 0), steps)) / 1000
  }
}

enum MascotPriority {
  /// Zubehör am Kopf und in den Händen. Kopfhörer ersetzen die Schlafmütze,
  /// Tageszeit geht vor der Feiertagsmütze.
  struct Accessories: Equatable {
    var headphones = false
    var coffee = false
    var nightcap = false
    var hat: MascotDecor?
  }

  static func face(_ c: MascotContext, now: Double, playing: Bool) -> MascotFace {
    if c.drag != nil || MascotStretch.isSettling(c.release, now: now) { return .normal }
    if MascotPetting.active(hoverStart: c.hoverStart, now: now) { return .petting }
    if MascotShake.dizzyActive(since: c.dizzyStart, now: now) { return .dizzy }
    if playing { return .normal }
    // Nachts schläft Lumi, außer die Insel ist offen oder ein Fokus läuft.
    if c.daypart == .night, !c.islandOpen, c.focus == nil { return .asleep }
    if MascotYawn.amount(at: now, daypart: c.daypart) > 0 { return .yawn }
    return .normal
  }

  static func accessories(_ c: MascotContext) -> Accessories {
    var a = Accessories()
    a.headphones = c.focus == .work
    a.coffee = c.focus == .rest
    a.nightcap = !a.headphones && c.daypart == .evening
    a.hat = a.nightcap ? nil : c.decor
    return a
  }

  /// Requisit wird nur gezeigt, wenn gerade keine Klick-Einlage läuft.
  static func prop(_ c: MascotContext, now: Double, playing: Bool) -> MascotPropShow? {
    guard !playing, let p = c.prop, let e = p.elapsed(at: now) else { return nil }
    return MascotPropShow(prop: p.prop, elapsed: e)
  }
}

struct MascotPropShow: Equatable {
  let prop: MascotProp
  let elapsed: Double
}

/// Alles, was das Maskottchen in einem Augenblick zeigt. Reine Funktion von Zeit und Eingaben.
struct MascotScene {
  var pose: MascotPose
  /// Gesichtsstimmung (Klick-Einlage, Schlaf).
  var mood: MascotMood
  var face: MascotFace
  var accessories: MascotPriority.Accessories
  var prop: MascotPropShow?
  var bulb: CGFloat?
  var rain: Bool
  var yawn: CGFloat
  /// Sekunden seit Beginn der Klick-Einlage „Verliebt“ (Funkeln), sonst nil.
  var sparkle: Double? = nil

  static func make(mood: MascotMood, waving: Bool, t: Double, now: Double, look: CGPoint?,
                   play: (action: MascotAction, elapsed: Double)?, context c: MascotContext) -> MascotScene {
    let tau = 2 * Double.pi
    let face = MascotPriority.face(c, now: now, playing: play != nil)
    let base: MascotMood = face == .asleep ? .sleepy : mood
    var pose = MascotPose.at(t, mood: base, waving: waving, look: look, play: play, micro: c.micro)
    var faceMood = base
    if let play, let f = play.action.face(at: play.elapsed) { faceMood = f }
    let accessories = MascotPriority.accessories(c)

    // Kopfhörer: Kopfnicken im Takt von 100 bpm.
    if accessories.headphones {
      pose.rotation += 2.5 * sin(tau * t * 100 / 60)
      pose.dy += CGFloat(-1.0 * abs(sin(Double.pi * t * 100 / 60)))
    }
    // Gähnen: Arme hoch, Körper gestreckt.
    let yawn = face == .yawn ? MascotYawn.amount(at: now, daypart: c.daypart) : 0
    if yawn > 0 {
      pose.leftArm = max(pose.leftArm, Double(150 * yawn))
      pose.rightArm = max(pose.rightArm, Double(150 * yawn))
      pose.sy *= 1 + 0.05 * yawn
      pose.sx *= 1 - 0.03 * yawn
    }
    // Schwindel: wackelnd, mit abklingender Amplitude.
    if face == .dizzy, let s = c.dizzyStart {
      let e = now - s
      pose.rotation += 10 * sin(tau * e * 2.5) * max(0, 1 - e / MascotShake.dizzyDuration)
    }
    // Schreibt der Nutzer, schaut Lumi zum Eingabefeld hinunter.
    if c.typing, face == .normal, play == nil {
      pose.lookX = 0.35
      pose.lookY = 0.9
    }
    // Gummi-Ziehen: Streckung in Zugrichtung, Augen folgen dem Zug.
    let shown: CGSize? = c.drag ?? c.release.map {
      MascotStretch.released($0.vector, sinceRelease: now - $0.startedAt)
    }
    if let v = shown, hypot(v.width, v.height) > 0.5 {
      let s = MascotStretch.shape(for: v)
      pose.stretch = s.scale
      pose.stretchAngle = s.angle
      pose.lookX = max(-1, min(1, v.width / 60))
      pose.lookY = max(-1, min(1, v.height / 60))
    }
    // Requisit: rechter Arm hoch, damit man es sieht.
    let prop = MascotPriority.prop(c, now: now, playing: play != nil)
    if prop != nil {
      pose.rightArm = 128 + 5 * sin(tau * t * 1.3)
    }
    // Kaffeetasse: linker Arm hält sie vor den Körper.
    if accessories.coffee {
      pose.leftArm = 110 + 3 * sin(tau * t * 0.8)
    }

    return MascotScene(pose: pose, mood: faceMood, face: face, accessories: accessories, prop: prop,
                       bulb: MascotBulb.visibility(startedAt: c.bulbStart, now: now), rain: mood == .error,
                       yawn: yawn, sparkle: play?.action == .love ? play?.elapsed : nil)
  }
}
