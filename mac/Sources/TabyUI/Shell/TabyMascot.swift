// Lumi-Maskottchen v3 (Nutzerwunsch: weißes, abgerundetes Quadrat mit
// zwei schwarzen Augen-Pillen und feinem Lächeln).
// Ausdruck nur über Augen und Mund; Bewegung über Haltung (Hüpfen, Kippen,
// Atmen) und Blick (folgt optional der Maus).
// Gezeichnet in einem 100×100-Einheitenraum per Canvas; die Bewegung ist eine
// reine Funktion der Zeit (`MascotPose.at`), damit Snapshots stillstehen können.
import AppKit
import SwiftUI

/// Kurze Einlage beim Anklicken (1. Klick springen, 2. lachen, 3. Überraschung)
/// und bei Mausberührung (zufällige leichte Reaktion, siehe `MascotHoverPicker`).
public enum MascotAction: String, CaseIterable, Sendable {
  case jump, laugh, fall, spin, sneeze, love, wave
  /// Lehnt sich zur Maus und blinzelt zweimal.
  case peek
  /// Kurzes Wackeln mit Stauchen und Strecken.
  case wiggle
  /// Zwei Nicker, der Blick folgt.
  case nod

  /// Dauer in Sekunden.
  var duration: Double {
    switch self {
    case .jump: 0.75
    case .laugh: 1.5
    case .fall: 2.4
    case .spin: 1.8
    case .sneeze: 1.5
    case .love: 1.9
    case .wave: 1.7
    case .peek: 1.4
    case .wiggle: 1.2
    case .nod: 1.1
    }
  }

  /// Gesicht während der Einlage (nil = Stimmung behalten).
  func face(at e: Double) -> MascotMood? {
    switch self {
    case .laugh: .happy
    case .fall: e > 0.3 && e < 1.7 ? .error : nil
    case .spin: e > 0.8 ? .error : .happy
    case .love: .love
    case .jump, .sneeze, .wave, .peek, .wiggle, .nod: nil
    }
  }

  /// Zufällige Überraschungen für den dritten Klick.
  static let surprises: [MascotAction] = [.fall, .spin, .sneeze, .love, .wave]
}

/// Reaktion beim Überfahren mit der Maus: nach 0,3 s eine zufällige Einlage aus dem Pool,
/// nie zweimal dieselbe hintereinander, höchstens eine alle 2,5 s. Zufall ist injizierbar.
struct MascotHoverPicker {
  static let startDelay = 0.3
  static let spacing = 2.5
  static let pool: [MascotAction] = [.wave, .jump, .laugh, .spin, .peek, .wiggle, .nod]

  var last: MascotAction?
  /// Frühester Zeitpunkt für die nächste Reaktion (Store-Uhr).
  var nextAllowed = -Double.infinity
  var random: (Int) -> Int

  init(random: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }) { self.random = random }

  mutating func pick(at now: Double) -> MascotAction? {
    guard now >= nextAllowed else { return nil }
    let options = Self.pool.filter { $0 != last }
    let action = options[min(max(random(options.count), 0), options.count - 1)]
    last = action
    nextAllowed = now + Self.spacing
    return action
  }
}

/// Eine laufende Einlage; `startedAt` in Sekunden seit dem Referenzdatum.
public struct MascotPlay: Equatable, Sendable {
  public let action: MascotAction
  public let startedAt: Double
  public init(action: MascotAction, startedAt: Double) { self.action = action; self.startedAt = startedAt }

  func elapsed(at now: Double) -> Double? {
    let e = now - startedAt
    return e >= 0 && e < action.duration ? e : nil
  }
}

/// Wann die Figur sich bewegt. Ruhend (`still`) nur während einer laufenden Reaktion; Reduce Motion nie.
enum MascotPace {
  static func animates(still: Bool, play: MascotPlay?, now: Double, reduceMotion: Bool) -> Bool {
    if reduceMotion { return false }
    guard still else { return true }
    return play?.elapsed(at: now) != nil
  }
}

/// Klick-Serie: Klicks im Abstand von höchstens 1,5 s zählen zusammen.
struct MascotCombo {
  static let window = 1.5
  private(set) var count = 0
  private var lastTap: Double?

  mutating func tap(at now: Double, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> MascotAction {
    if let last = lastTap, now - last <= Self.window { count += 1 } else { count = 1 }
    lastTap = now
    switch count {
    case 1: return .jump
    case 2: return .laugh
    default:
      count = 0
      lastTap = nil
      return MascotAction.surprises[random(MascotAction.surprises.count)]
    }
  }
}

/// Haltung des Maskottchens zu einem Zeitpunkt (Einheiten des 100er-Raums).
struct MascotPose: Equatable {
  var dx: CGFloat = 0
  var dy: CGFloat = 0
  var sx: CGFloat = 1
  var sy: CGFloat = 1
  /// Grad, um die Körpermitte.
  var rotation: Double = 0
  /// Augenhöhe 1 = offen, ~0.1 = Lidschlag.
  var blink: CGFloat = 1
  /// Blickrichtung −1…1 (x: links/rechts, y: oben/unten).
  var lookX: CGFloat = 0
  var lookY: CGFloat = 0
  /// Rechtes Auge zwinkert (0 = offen, 1 = zu).
  var wink: CGFloat = 0
  /// Ärmchen anheben, Grad (0 = hängt locker, ~150 = ganz oben).
  var leftArm: Double = 0
  var rightArm: Double = 0
  var badgeScale: CGFloat = 1
  /// Phase für Partikel (Funkeln, z, Punkte).
  var t: Double = 0
  /// Gummi-Ziehen: Streckfaktor (1 = ruhig) in Richtung `stretchAngle` (Grad).
  var stretch: CGFloat = 1
  var stretchAngle: Double = 0

  static func at(_ t: Double, mood: MascotMood, waving: Bool, look: CGPoint? = nil,
                 play: (action: MascotAction, elapsed: Double)? = nil,
                 micro: MascotMicroShow? = nil) -> MascotPose {
    var p = MascotPose(t: t)
    let tau = 2 * Double.pi
    // Sanftes Schweben und Atmen.
    let float = -1.4 * sin(tau * t / 3.6)
    let breathe = 0.012 * sin(tau * t / 3.6)
    // Lidschlag alle ~3,8 s, ab und zu doppelt.
    let bp = t.truncatingRemainder(dividingBy: 3.8)
    p.blink = blinkCurve(bp - 3.55)
    if Int(t / 3.8) % 3 == 2 { p.blink = min(p.blink, blinkCurve(bp - 3.25)) }

    switch mood {
    case .idle:
      p.dy = CGFloat(float)
      p.sx = CGFloat(1 + breathe); p.sy = CGFloat(1 - breathe)
      // Alle 6 s ein Blick nach links und rechts.
      let gp = t.truncatingRemainder(dividingBy: 6.0)
      if gp < 2.0 { p.lookX = CGFloat(0.7 * sin(tau * gp / 2.0)) }
      // Alle 7 s ein kleines Winken mit dem rechten Ärmchen.
      let wp = t.truncatingRemainder(dividingBy: 7.0)
      if wp < 1.6 {
        let env = sin(Double.pi * wp / 1.6)
        p.rightArm = env * (110 + 22 * sin(tau * wp * 2.4))
      }
    case .thinking:
      p.dy = CGFloat(float)
      p.rotation = 3 * sin(tau * t / 2.4)
      p.lookY = -0.7
      p.lookX = CGFloat(0.6 * sin(tau * t / 1.8))
      // Ärmchen an den Kopf (kratzt sich).
      p.rightArm = 128 + 6 * sin(tau * t / 0.5)
    case .alert:
      let ap = t.truncatingRemainder(dividingBy: 1.4)
      if ap < 0.55 {
        let decay = 1 - ap / 0.55
        p.rotation = 7 * sin(tau * 7 * ap) * decay
        p.sx = 1 + 0.05 * decay
        p.sy = 1 + 0.05 * decay
      }
      p.badgeScale = CGFloat(1 + 0.14 * max(0, sin(tau * t * 1.6)))
      // Ärmchen erschrocken hochgerissen.
      p.leftArm = 140; p.rightArm = 140
    case .happy:
      let hp = t.truncatingRemainder(dividingBy: 0.95) / 0.95
      let k = hopKeyframe(hp)
      p.dy = k.dy; p.sx = k.sx; p.sy = k.sy
      // Beide Ärmchen hoch, im Takt des Hüpfens.
      let up = 120 + 22 * sin(tau * hp)
      p.leftArm = up; p.rightArm = up
    case .love:
      p.dy = CGFloat(float)
      p.rotation = 3 * sin(tau * t / 2.0)
      // Stolzes Zwinkern alle 2,5 s.
      let wp = t.truncatingRemainder(dividingBy: 2.5)
      p.wink = wp < 0.5 ? CGFloat(sin(Double.pi * wp / 0.5)) : 0
      p.leftArm = 40 + 10 * sin(tau * t / 2.0)
      p.rightArm = 40 - 10 * sin(tau * t / 2.0)
    case .error:
      p.rotation = 6 * sin(tau * t * 1.2)
      p.dx = CGFloat(1.5 * sin(tau * t * 2.4))
      p.leftArm = -12; p.rightArm = -12
    case .sleepy:
      let b = sin(tau * t / 3.2)
      p.sx = CGFloat(1 + 0.03 * b); p.sy = CGFloat(1 - 0.03 * b)
      p.dy = CGFloat(1.2 * b)
      p.blink = 1
    }
    if waving {
      // Begrüßung: fröhliches Wippen und Zwinkern.
      p.rotation = 9 * sin(tau * t * 1.6)
      p.dy = CGFloat(-2 * abs(sin(tau * t * 1.6)))
      let wp = t.truncatingRemainder(dividingBy: 1.6)
      p.wink = wp < 0.35 ? CGFloat(sin(Double.pi * wp / 0.35)) : 0
      // Winken mit dem rechten Ärmchen.
      p.rightArm = 135 + 25 * sin(tau * t * 2.6)
    }
    if let play {
      p.apply(play.action, elapsed: play.elapsed, t: t, towards: (look?.x ?? 0) < 0 ? -1 : 1)
    }
    // Maus hat Vorrang vor dem Umherschauen (nur in ruhigen Stimmungen).
    if let look, play == nil, mood == .idle || mood == .love || mood == .sleepy {
      p.lookX = max(-1, min(1, look.x))
      p.lookY = max(-1, min(1, look.y))
    }
    if let micro, play == nil { p.applyMicro(micro) }
    return p
  }

  /// Mikro-Bewegung über die Haltung legen (nach Blick, nur ohne Einlage).
  private mutating func applyMicro(_ m: MascotMicroShow) {
    let env = sin(Double.pi * m.elapsed / MascotLiveliness.duration)
    switch m.move {
    case .glanceLeft: lookX = CGFloat(-0.9 * env)
    case .glanceRight: lookX = CGFloat(0.9 * env)
    case .doubleBlink: blink = min(Self.blinkCurve(m.elapsed - 0.25), Self.blinkCurve(m.elapsed - 0.55))
    case .tinyBounce: dy += CGFloat(-3 * env)
    case .lean: rotation += 4 * env
    }
  }

  /// Einlage über die Grundhaltung legen (e = Sekunden seit Start).
  private mutating func apply(_ action: MascotAction, elapsed e: Double, t: Double, towards: Double) {
    let tau = 2 * Double.pi
    func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    switch action {
    case .jump:
      // Großer Sprung mit Stauchen vor und nach der Landung, Ärmchen hoch.
      let k = Self.hopKeyframe(e / action.duration)
      dy = k.dy * 1.9; sx = k.sx; sy = k.sy
      rotation = 0
      leftArm = 150 * sin(Double.pi * e / action.duration); rightArm = leftArm
    case .laugh:
      // Schüttelt sich vor Lachen.
      let fade = 1 - ease((e - 1.1) / 0.4)
      rotation = 7 * sin(tau * e * 5) * fade
      dy = CGFloat(-3 * abs(sin(tau * e * 3.5)) * fade)
      sx = CGFloat(1 + 0.04 * sin(tau * e * 7) * fade); sy = CGFloat(1 - 0.04 * sin(tau * e * 7) * fade)
      leftArm = 70 + 25 * sin(tau * e * 5); rightArm = 70 - 25 * sin(tau * e * 5)
      blink = 1
    case .fall:
      // Kippt um, bleibt kurz liegen, rappelt sich mit Nachwippen wieder auf.
      if e < 0.35 {
        let f = e / 0.35
        rotation = 88 * f * f
      } else if e < 1.7 {
        rotation = 88 + 2 * sin(tau * (e - 0.35) * 1.2)
        dy = 0
      } else {
        let f = (e - 1.7) / (action.duration - 1.7)
        rotation = 88 * (1 - ease(f)) - 10 * sin(Double.pi * f) * (1 - f)
      }
      dx = CGFloat(rotation / 88 * 6)
      leftArm = e < 1.7 ? -15 : 60 * sin(Double.pi * min(1, (e - 1.7) / 0.7)); rightArm = leftArm
      lookX = 0; lookY = 0; blink = 1
    case .spin:
      // Eine Drehung, danach schwindeliges Nachwackeln.
      if e < 0.8 {
        rotation = 360 * ease(e / 0.8)
        dy = CGFloat(-8 * sin(Double.pi * e / 0.8))
        leftArm = 120; rightArm = 120
      } else {
        let d = 1 - (e - 0.8) / (action.duration - 0.8)
        rotation = 8 * sin(tau * (e - 0.8) * 2.2) * d
        dx = CGFloat(2 * sin(tau * (e - 0.8) * 1.1) * d)
        leftArm = -10; rightArm = -10
      }
    case .sneeze:
      // Luft holen … und hatschi!
      if e < 0.7 {
        let f = ease(e / 0.7)
        sy = CGFloat(1 + 0.08 * f); sx = CGFloat(1 - 0.05 * f)
        rotation = 6 * f; lookY = CGFloat(-0.6 * f); blink = CGFloat(1 - 0.6 * f)
        rightArm = 100 * f
      } else if e < 0.85 {
        sx = 1.12; sy = 0.86; rotation = -12; dx = -3; blink = 0.1
        rightArm = 130
      } else {
        let f = ease((e - 0.85) / (action.duration - 0.85))
        sx = CGFloat(1.12 - 0.12 * f); sy = CGFloat(0.86 + 0.14 * f); rotation = -12 * (1 - f)
        dx = CGFloat(-3 * (1 - f)); blink = CGFloat(0.1 + 0.9 * f)
        rightArm = 130 * (1 - f)
      }
    case .love:
      // Zwei verliebte Hüpfer mit Zwinkern.
      let k = Self.hopKeyframe((e / 0.95).truncatingRemainder(dividingBy: 1))
      dy = k.dy; sx = k.sx; sy = k.sy
      rotation = 5 * sin(tau * e / 0.95)
      wink = e > 0.9 && e < 1.4 ? 1 : 0
      leftArm = 90; rightArm = 90
    case .wave:
      rotation = 6 * sin(tau * e * 1.4)
      rightArm = 135 + 25 * sin(tau * e * 2.6)
      wink = e > 0.5 && e < 0.85 ? 1 : 0
    case .peek:
      // Lehnt sich zur Maus (towards: −1 links, +1 rechts) und blinzelt zweimal.
      rotation = 8 * towards * sin(Double.pi * e / action.duration)
      lookX = CGFloat(0.9 * towards)
      blink = min(Self.blinkCurve(e - 0.35), Self.blinkCurve(e - 0.9))
    case .wiggle:
      // Wackelt seitlich, Stauchen und Strecken im Takt, klingt ab.
      let fade = 1 - e / action.duration
      let w = sin(tau * e * 3)
      dx = CGFloat(4 * w * fade)
      rotation = 4 * w * fade
      sx = CGFloat(1 + 0.05 * w * fade); sy = CGFloat(1 - 0.05 * w * fade)
    case .nod:
      // Zwei Nicker nach unten, der Blick folgt.
      let fade = 1 - e / action.duration
      let n = abs(sin(Double.pi * e * 2 / action.duration))
      dy = CGFloat(3 * n * fade)
      lookY = CGFloat(0.8 * n)
    }
  }

  /// Lidschlag-Kurve um x = 0 (Dauer ~0,16 s).
  private static func blinkCurve(_ x: Double) -> CGFloat {
    let d = abs(x)
    guard d < 0.08 else { return 1 }
    return CGFloat(0.1 + 0.9 * (d / 0.08))
  }

  /// Hüpfen mit Stauchen und Strecken.
  private static func hopKeyframe(_ p: Double) -> (dy: CGFloat, sx: CGFloat, sy: CGFloat) {
    let frames: [(Double, CGFloat, CGFloat, CGFloat)] = [
      (0, 0, 1, 1), (0.15, 2, 1.1, 0.9), (0.45, -12, 0.94, 1.07), (0.7, 0, 1.06, 0.94), (0.85, 0, 1, 1), (1, 0, 1, 1),
    ]
    for i in 1..<frames.count where p <= frames[i].0 {
      let a = frames[i - 1], b = frames[i]
      let f = CGFloat((p - a.0) / (b.0 - a.0))
      let e = f * f * (3 - 2 * f)
      return (a.1 + (b.1 - a.1) * e, a.2 + (b.2 - a.2) * e, a.3 + (b.3 - a.3) * e)
    }
    return (0, 1, 1)
  }
}

/// Mausposition als Blickrichtung (−1…1) relativ zur Bildschirmmitte oben,
/// wo die Insel sitzt. Nur für die Anzeige, nicht für Logik.
enum MascotGaze {
  /// Letzter Blick und seine Uhrzeit: höchstens 10× je Sekunde die Maus abfragen (Takt der Figur ist 30/s).
  nonisolated(unsafe) private static var cache: (t: Double, value: CGPoint?)?

  static func current(at t: Double, frame: CGRect? = nil) -> CGPoint? {
    if let c = cache, t >= c.t, t - c.t < 0.1 { return c.value }
    let value = sample(frame: frame)
    cache = (t, value)
    return value
  }

  /// Blick relativ zu einer Fläche: Maus links/rechts/unten in der offenen Insel → Augen folgen dort.
  static func look(mouse m: CGPoint, in f: CGRect) -> CGPoint {
    let x = (m.x - f.midX) / max(f.width / 2, 1)
    let y = (f.maxY - m.y) / max(f.height, 1) - 0.2
    return CGPoint(x: max(-1.4, min(1.4, x * 1.6)), y: max(-0.6, min(1.2, y * 1.3)))
  }

  private static func sample(frame: CGRect?) -> CGPoint? {
    let m = NSEvent.mouseLocation
    if let frame, frame.insetBy(dx: -40, dy: -40).contains(m) { return look(mouse: m, in: frame) }
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main else { return nil }
    let f = screen.frame
    let x = (m.x - f.midX) / (f.width / 2)
    // Oben an der Notch = geradeaus; weiter unten = nach unten schauen.
    let y = (f.maxY - m.y) / (f.height * 0.5) - 0.15
    return CGPoint(x: x * 1.4, y: y)
  }
}

/// Das Maskottchen. Öffentlich, damit die Ansichten es klein wiederverwenden können.
public struct TabyMascot: View {
  public let mood: MascotMood
  public let size: CGFloat
  public let waving: Bool
  public let glow: Bool
  public let lowPower: Bool
  public let time: Double?
  public let badge: Bool
  public let followsMouse: Bool
  /// Fläche, auf die sich der Blick bezieht (Bildschirmkoordinaten); nil = ganzer Bildschirm.
  public var gazeFrame: CGRect?
  public let play: MascotPlay?
  /// Geschlossen und ruhig: stehendes Bild ohne Takt; nur eine Reaktion (`play`) bewegt sie.
  public let still: Bool
  /// Feste Zusatzszenen (Vorschau/Snapshots); nil = aus der Umgebung der Insel.
  var context: MascotContext? = nil

  @Environment(\.mascotClock) private var clock
  @Environment(\.mascotContextProvider) private var provider

  /// Dieselbe Figur mit festen Zusatzszenen (Vorschau/Snapshots).
  func withContext(_ c: MascotContext?) -> TabyMascot {
    var m = self
    m.context = c
    return m
  }

  /// - Parameters:
  ///   - size: Kantenlänge in Punkt (Partikel/Abzeichen ragen leicht darüber hinaus).
  ///   - waving: Begrüßung (wippt und zwinkert).
  ///   - glow: farbiger Schimmer in Stimmungsfarbe darunter.
  ///   - lowPower: nur ~15 Bilder/s (geschlossene Insel, kleine Darstellungen).
  ///   - time: feste Zeit statt Animation (Snapshots).
  ///   - badge: Abzeichen der Stimmung zeigen (✓, !, …).
  ///   - followsMouse: Augen folgen dem Mauszeiger.
  ///   - still: ruhendes Bild (geschlossene Insel): kein Takt, außer während einer Reaktion.
  public init(mood: MascotMood = .idle, size: CGFloat = 40, waving: Bool = false, glow: Bool = false,
              lowPower: Bool = false, time: Double? = nil, badge: Bool = true, followsMouse: Bool = true,
              play: MascotPlay? = nil, still: Bool = false, gazeFrame: CGRect? = nil) {
    self.gazeFrame = gazeFrame
    self.mood = mood; self.size = size; self.waving = waving; self.glow = glow; self.play = play
    self.lowPower = lowPower; self.time = time; self.badge = badge; self.followsMouse = followsMouse
    self.still = still
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public var body: some View {
    ZStack {
      if glow {
        Circle()
          .fill(RadialGradient(colors: [mood.color.opacity(0.7), mood.color.opacity(0)], center: .center,
                               startRadius: 0, endRadius: size * 0.75))
          .frame(width: size * 1.6, height: size * 1.1)
          .offset(y: size * 0.3)
          .blur(radius: size * 0.12)
          .animation(.easeInOut(duration: 0.4), value: mood)
      }
      // Snapshots: `time` ist dann auch die Uhr der Einlage und der Ereignisse.
      // Reduce Motion: feste Pose statt Animation.
      let animate = MascotPace.animates(still: still, play: play, now: clock(), reduceMotion: reduceMotion)
      if let frozen = time ?? (reduceMotion ? 0 : nil) {
        scene(now: frozen, t: frozen, look: nil)
      } else if !animate {
        // Ruhend: ein Bild beim Zeichnen, keine TimelineView (0 Bilder/s).
        let now = clock()
        scene(now: now, t: now.truncatingRemainder(dividingBy: 10_000), look: nil)
      } else {
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 15 : 1.0 / 30)) { _ in
          let now = clock()
          scene(now: now, t: now.truncatingRemainder(dividingBy: 10_000),
                look: followsMouse ? MascotGaze.current(at: now, frame: gazeFrame) : nil)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement()
    .accessibilityLabel("Lumi")
  }

  /// Eine Einzelbild-Szene aus Zeit, Einlage und Zusatzszenen (reine Funktion, siehe MascotScene).
  @ViewBuilder
  private func scene(now: Double, t: Double, look: CGPoint?) -> some View {
    let base = context ?? provider(now)
    let running = play.flatMap { p in p.elapsed(at: now).map { (action: p.action, elapsed: $0) } }
    // Reduce Motion: keine Mikro-Bewegungen (nur Atmen und Lidschlag).
    let scene = MascotScene.make(mood: mood, waving: waving, t: t, now: now, look: look, play: running,
                                 context: reduceMotion ? base.withoutMicro : base)
    // Große Darstellung (offene Insel, Onboarding): weiche Verläufe statt Canvas-Weichzeichner.
    MascotCanvas(scene: scene, size: size, badge: badge && running == nil, soft: !lowPower)
  }
}

private struct MascotCanvas: View {
  let scene: MascotScene
  let size: CGFloat
  let badge: Bool
  var soft = false

  /// Zeichenfläche ragt 30 Einheiten über jeden Rand (Abzeichen, Partikel).
  private static let pad: CGFloat = 30

  var body: some View {
    let k = size / 100
    let full = size + 2 * Self.pad * k
    Canvas { ctx, _ in
      ctx.scaleBy(x: k, y: k)
      ctx.translateBy(x: Self.pad, y: Self.pad)
      MascotPainter(pose: scene.pose, mood: scene.mood, badge: badge, scene: scene, soft: soft).paint(&ctx)
    }
    .frame(width: full, height: full)
    .frame(width: size, height: size)
    .allowsHitTesting(false)
  }
}

struct MascotPainter {
  let pose: MascotPose
  let mood: MascotMood
  let badge: Bool
  let scene: MascotScene
  /// Weiche Verläufe statt Weichzeichner-Filter (teuer bei jedem Bild).
  var soft = false

  // Sitzende Bohne mit Ärmchen (eigene Form im Stil von Notch-Figuren):
  // weiß, kein Rand, Glanz oben, unten ein Schimmer in der Stimmungsfarbe,
  // als fiele das Licht der Insel darauf. Gesicht: Augen-Pillen + Lächeln.
  static let bodyTop = Color(shellHex: 0xFFFFFF)
  static let bodyBottom = Color(shellHex: 0xEDEDF2)
  static let face = Color(shellHex: 0x16161A)

  static let eyeY: CGFloat = 44
  static let eyeL: CGFloat = 34
  static let eyeR: CGFloat = 66
  /// Schultern (Drehpunkte der Ärmchen) und Ruhewinkel.
  static let shoulderL = CGPoint(x: 19, y: 62)
  static let shoulderR = CGPoint(x: 81, y: 62)
  static let armRest: Double = 30

  /// Bohnen-Körper im 100er-Raum: schmaler Kopf, breiter sitzender Bauch.
  static var beanPath: Path {
    var p = Path()
    p.move(to: CGPoint(x: 50, y: 22))
    p.addCurve(to: CGPoint(x: 84, y: 60), control1: CGPoint(x: 72, y: 22), control2: CGPoint(x: 82, y: 40))
    p.addCurve(to: CGPoint(x: 76, y: 86), control1: CGPoint(x: 87, y: 74), control2: CGPoint(x: 86, y: 84))
    p.addCurve(to: CGPoint(x: 24, y: 86), control1: CGPoint(x: 62, y: 89), control2: CGPoint(x: 38, y: 89))
    p.addCurve(to: CGPoint(x: 16, y: 60), control1: CGPoint(x: 14, y: 84), control2: CGPoint(x: 13, y: 74))
    p.addCurve(to: CGPoint(x: 50, y: 22), control1: CGPoint(x: 18, y: 40), control2: CGPoint(x: 28, y: 22))
    p.closeSubpath()
    return p
  }

  func paint(_ ctx: inout GraphicsContext) {
    let tau = 2 * Double.pi
    // Weicher Schatten unter der Figur.
    var shadow = ctx
    if soft {
      // Ellipse mit weichem Rand: Kreisverlauf, in der Höhe auf 4/28 gestaucht (Rand bei Alpha 0).
      shadow.translateBy(x: 50, y: 90)
      shadow.scaleBy(x: 1, y: 4.0 / 28)
      shadow.fill(Path(ellipseIn: CGRect(x: -28, y: -28, width: 56, height: 56)),
                  with: .radialGradient(Gradient(colors: [.black.opacity(0.3), .black.opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: 28))
    } else {
      shadow.addFilter(.blur(radius: 2.5))
      shadow.fill(Path(ellipseIn: CGRect(x: 22, y: 86, width: 56, height: 8)), with: .color(.black.opacity(0.3)))
    }

    var c = ctx
    c.translateBy(x: 50 + pose.dx, y: 88 + pose.dy)
    c.scaleBy(x: pose.sx, y: pose.sy)
    c.rotate(by: .degrees(pose.rotation))
    if pose.stretch != 1 {
      // Gummi: in Zugrichtung strecken, senkrecht etwas stauchen (Volumen ungefähr gleich).
      c.rotate(by: .degrees(pose.stretchAngle))
      c.scaleBy(x: pose.stretch, y: 1 / sqrt(pose.stretch))
      c.rotate(by: .degrees(-pose.stretchAngle))
    }
    c.translateBy(x: -50, y: -88)

    // Leuchten in Stimmungsfarbe unter dem Bauch.
    var glow = c
    if soft {
      // Weicher Fleck: Mitte kräftig, Rand fällt auf Alpha 0 ab (Ellipse 32 × 13 um (50, 79)).
      glow.translateBy(x: 50, y: 79)
      glow.scaleBy(x: 1, y: 13.0 / 32)
      glow.fill(Path(ellipseIn: CGRect(x: -32, y: -32, width: 64, height: 64)),
                with: .radialGradient(Gradient(stops: [
                  .init(color: mood.color.opacity(0.45), location: 0),
                  .init(color: mood.color.opacity(0.3), location: 0.6),
                  .init(color: mood.color.opacity(0), location: 1),
                ]), center: .zero, startRadius: 0, endRadius: 32))
    } else {
      glow.addFilter(.blur(radius: 9))
      glow.fill(Path(ellipseIn: CGRect(x: 18, y: 66, width: 64, height: 26)), with: .color(mood.color.opacity(0.45)))
    }

    // Ärmchen hinter dem Körper.
    arm(&c, at: Self.shoulderL, degrees: Self.armRest + pose.leftArm)
    arm(&c, at: Self.shoulderR, degrees: -(Self.armRest + pose.rightArm))

    let shape = Self.beanPath
    c.fill(shape, with: .linearGradient(Gradient(colors: [Self.bodyTop, Self.bodyBottom]),
                                        startPoint: CGPoint(x: 50, y: 22), endPoint: CGPoint(x: 50, y: 88)))
    var inner = c
    inner.clip(to: shape)
    // Stimmungsfarbe von unten (Licht der Insel).
    inner.fill(shape, with: .linearGradient(Gradient(colors: [.clear, mood.color.opacity(0.38)]),
                                            startPoint: CGPoint(x: 50, y: 58), endPoint: CGPoint(x: 50, y: 90)))
    // Weiche Schattierung zu den Rändern (Volumen statt Kontur).
    inner.fill(shape, with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.10)]),
                                            center: CGPoint(x: 46, y: 52), startRadius: 24, endRadius: 52))
    // Glanzlicht oben links.
    inner.fill(Path(ellipseIn: CGRect(x: 24, y: 26, width: 36, height: 18)),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.95), .clear]),
                                     center: CGPoint(x: 40, y: 32), startRadius: 0, endRadius: 18))

    drawBodyAccessories(&c)
    // Gesicht: folgt dem Blick ein Stück (wirkt räumlich).
    var f = c
    f.translateBy(x: 50 + pose.lookX * 5, y: 54 + pose.lookY * 3.5)
    f.scaleBy(x: 0.62, y: 0.62)
    f.translateBy(x: -50, y: -55)
    if scene.face == .petting { blush(&f) }
    eyes(&f)
    mouth(&f)
    if badge { drawBadge(&c, tau: tau) }
    particles(&ctx, tau: tau)
    extras(&ctx, tau: tau)
  }

  /// Ein Ärmchen: abgerundeter Stummel, der von der Schulter nach unten hängt;
  /// positive Winkel drehen das Ende nach links (für das linke Ärmchen: nach außen).
  private func arm(_ c: inout GraphicsContext, at shoulder: CGPoint, degrees: Double) {
    var a = c
    a.translateBy(x: shoulder.x, y: shoulder.y)
    a.rotate(by: .degrees(degrees))
    let stub = Path(roundedRect: CGRect(x: -5, y: -3, width: 10, height: 19), cornerRadius: 5)
    a.fill(stub, with: .linearGradient(Gradient(colors: [Self.bodyTop, Self.bodyBottom]),
                                       startPoint: CGPoint(x: 0, y: -3), endPoint: CGPoint(x: 0, y: 16)))
  }

  // MARK: Gesicht

  private var white: GraphicsContext.Shading { .color(Self.face) }

  private func pill(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    let hh = max(2.4, h)
    c.fill(Path(roundedRect: CGRect(x: x - w / 2, y: y - hh / 2, width: w, height: hh), cornerRadius: min(w, hh) / 2),
           with: white)
  }

  private func arc(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, up: Bool, width w: CGFloat = 13) {
    var p = Path()
    p.move(to: CGPoint(x: x - w / 2, y: y + (up ? 4 : -2)))
    p.addQuadCurve(to: CGPoint(x: x + w / 2, y: y + (up ? 4 : -2)), control: CGPoint(x: x, y: y + (up ? -9 : 5)))
    c.stroke(p, with: white, style: StrokeStyle(lineWidth: 4.4, lineCap: .round))
  }

  private func eyes(_ c: inout GraphicsContext) {
    let y = Self.eyeY
    let L = Self.eyeL, R = Self.eyeR
    let h = 24 * pose.blink
    switch scene.face {
    case .dizzy:
      spiral(&c, x: L, y: y)
      spiral(&c, x: R, y: y)
      return
    case .yawn:
      pill(&c, x: L, y: y, w: 12, h: 8)
      pill(&c, x: R, y: y, w: 12, h: 8)
      return
    case .petting:
      arc(&c, x: L, y: y, up: true)
      arc(&c, x: R, y: y, up: true)
      return
    case .normal, .asleep:
      break
    }
    switch mood {
    case .idle:
      pill(&c, x: L, y: y, w: 12, h: h)
      pill(&c, x: R, y: y, w: 12, h: h * (1 - pose.wink * 0.9))
    case .thinking:
      pill(&c, x: L, y: y - 1, w: 11, h: h * 0.85)
      pill(&c, x: R, y: y - 3, w: 11, h: h * 0.95)
    case .alert:
      pill(&c, x: L, y: y, w: 14, h: 28 * pose.blink)
      pill(&c, x: R, y: y, w: 14, h: 28 * pose.blink)
    case .happy:
      arc(&c, x: L, y: y, up: true)
      arc(&c, x: R, y: y, up: true)
    case .love:
      pill(&c, x: L, y: y, w: 12, h: h)
      if pose.wink > 0.5 { arc(&c, x: R, y: y, up: true) } else { pill(&c, x: R, y: y, w: 12, h: h * (1 - pose.wink)) }
    case .error:
      for x in [L, R] {
        var p = Path()
        p.move(to: CGPoint(x: x - 5.5, y: y - 5.5)); p.addLine(to: CGPoint(x: x + 5.5, y: y + 5.5))
        p.move(to: CGPoint(x: x + 5.5, y: y - 5.5)); p.addLine(to: CGPoint(x: x - 5.5, y: y + 5.5))
        c.stroke(p, with: white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
      }
    case .sleepy:
      arc(&c, x: L, y: y + 2, up: false)
      arc(&c, x: R, y: y + 2, up: false)
    }
  }

  private func mouth(_ c: inout GraphicsContext) {
    let y: CGFloat = 66
    let line = StrokeStyle(lineWidth: 3, lineCap: .round)
    if scene.face == .yawn {
      // Gähnen: rundes „O“.
      c.stroke(Path(ellipseIn: CGRect(x: 45.5, y: y - 3, width: 9, height: 12)), with: white,
               style: StrokeStyle(lineWidth: 2.8))
      return
    }
    var p = Path()
    switch faceMouthMood {
    case .idle:
      p.move(to: CGPoint(x: 42, y: y)); p.addQuadCurve(to: CGPoint(x: 58, y: y), control: CGPoint(x: 50, y: y + 6))
      c.stroke(p, with: white, style: line)
    case .thinking:
      p.move(to: CGPoint(x: 47, y: y + 2)); p.addLine(to: CGPoint(x: 57, y: y + 1))
      c.stroke(p, with: white, style: line)
    case .alert:
      c.stroke(Path(ellipseIn: CGRect(x: 46.5, y: y - 1, width: 7, height: 8)), with: white, style: StrokeStyle(lineWidth: 2.6))
    case .happy:
      // Breites, offenes Lachen.
      p.move(to: CGPoint(x: 39, y: y - 2))
      p.addQuadCurve(to: CGPoint(x: 61, y: y - 2), control: CGPoint(x: 50, y: y + 12))
      p.closeSubpath()
      c.fill(p, with: white)
    case .love:
      // Stolzes, schiefes Lächeln.
      p.move(to: CGPoint(x: 43, y: y + 1)); p.addQuadCurve(to: CGPoint(x: 59, y: y - 2), control: CGPoint(x: 52, y: y + 7))
      c.stroke(p, with: white, style: line)
    case .error:
      p.move(to: CGPoint(x: 41, y: y + 3))
      p.addCurve(to: CGPoint(x: 59, y: y + 3), control1: CGPoint(x: 46, y: y - 3), control2: CGPoint(x: 54, y: y + 9))
      c.stroke(p, with: white, style: line)
    case .sleepy:
      p.move(to: CGPoint(x: 47, y: y + 2)); p.addLine(to: CGPoint(x: 53, y: y + 2))
      c.stroke(p, with: white, style: line)
    }
  }

  // MARK: Abzeichen + Partikel

  private func drawBadge(_ c: inout GraphicsContext, tau: Double) {
    let color = mood.color
    let center = mood == .thinking ? CGPoint(x: 88, y: 20) : CGPoint(x: 80, y: 24)
    var b = c
    b.translateBy(x: center.x, y: center.y)
    b.scaleBy(x: pose.badgeScale, y: pose.badgeScale)
    let ring = StrokeStyle(lineWidth: 3)
    let white = GraphicsContext.Shading.color(.white)
    let circle = Path(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24))
    switch mood {
    case .thinking:
      let pill = Path(roundedRect: CGRect(x: -22, y: -10, width: 38, height: 20), cornerRadius: 10)
      b.fill(pill, with: .color(color)); b.stroke(pill, with: .color(.black), style: ring)
      for i in 0..<3 {
        let bounce = -3.2 * max(0, sin(tau * pose.t / 0.9 - Double(i) * 0.7))
        b.fill(Path(ellipseIn: CGRect(x: -15 + CGFloat(i) * 9 - 2.8, y: CGFloat(bounce) - 2.8, width: 5.6, height: 5.6)),
               with: white)
      }
    case .alert:
      b.fill(circle, with: .color(color)); b.stroke(circle, with: .color(.black), style: ring)
      b.fill(Path(roundedRect: CGRect(x: -2, y: -7.5, width: 4, height: 10), cornerRadius: 2), with: white)
      b.fill(Path(ellipseIn: CGRect(x: -2.2, y: 4, width: 4.4, height: 4.4)), with: white)
    case .happy:
      b.fill(circle, with: .color(color)); b.stroke(circle, with: .color(.black), style: ring)
      var check = Path(); check.move(to: CGPoint(x: -5.5, y: 0.5)); check.addLine(to: CGPoint(x: -1.5, y: 4.5))
      check.addLine(to: CGPoint(x: 5.5, y: -4))
      b.stroke(check, with: white, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
    case .error:
      b.fill(circle, with: .color(color)); b.stroke(circle, with: .color(.black), style: ring)
      var x = Path(); x.move(to: CGPoint(x: -4, y: -4)); x.addLine(to: CGPoint(x: 4, y: 4))
      x.move(to: CGPoint(x: 4, y: -4)); x.addLine(to: CGPoint(x: -4, y: 4))
      b.stroke(x, with: white, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
    case .love:
      b.fill(circle, with: .color(color)); b.stroke(circle, with: .color(.black), style: ring)
      b.fill(sparkle(at: .zero, radius: 7.5, inner: 2.6), with: white)
    case .idle, .sleepy:
      break
    }
  }

  private func particles(_ ctx: inout GraphicsContext, tau: Double) {
    switch mood {
    case .love:
      let spots: [(CGFloat, CGFloat, Double)] = [(2, 30, 0), (64, 10, 0.33), (102, 58, 0.66)]
      for (x, y, off) in spots {
        let ph = (pose.t / 1.4 + off).truncatingRemainder(dividingBy: 1)
        let s = CGFloat(max(0, sin(Double.pi * ph)))
        var t = ctx
        t.opacity = Double(s)
        t.fill(sparkle(at: CGPoint(x: x, y: y), radius: 3 + 4 * s, inner: 1 + 0.8 * s), with: .color(mood.color))
      }
    case .sleepy:
      for i in 0..<2 {
        let ph = (pose.t / 2.4 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
        let o = ph < 0.2 ? ph / 0.2 : 1 - (ph - 0.2) / 0.8
        let size = 11 + 7 * ph
        let text = Text("z").font(.system(size: size, weight: .heavy, design: .rounded)).foregroundColor(mood.color)
        var t = ctx
        t.opacity = o
        t.draw(text, at: CGPoint(x: 86 + 10 * ph, y: 26 - 26 * ph))
      }
    default:
      break
    }
  }

  // MARK: Zusatzszenen

  /// Stimmung für den Mund: Streicheln lächelt verliebt, Schwindel wackelt.
  private var faceMouthMood: MascotMood {
    switch scene.face {
    case .petting: .love
    case .dizzy: .error
    case .normal, .yawn, .asleep: mood
    }
  }

  /// Spitze eines Ärmchens (Länge 19) ohne Körperbewegung; `degrees` wie beim Zeichnen.
  private func armTip(_ s: CGPoint, degrees: Double) -> CGPoint {
    let r = degrees * Double.pi / 180
    return CGPoint(x: s.x - 19 * CGFloat(sin(r)), y: s.y + 19 * CGFloat(cos(r)))
  }

  /// Kopfhörer (Fokus Arbeit) und Mützen; liegen auf dem Körper, vor dem Gesicht.
  private func drawBodyAccessories(_ c: inout GraphicsContext) {
    let acc = scene.accessories
    if acc.headphones {
      var band = Path()
      band.move(to: CGPoint(x: 17, y: 56))
      band.addQuadCurve(to: CGPoint(x: 83, y: 56), control: CGPoint(x: 50, y: -20))
      c.stroke(band, with: .color(Self.face), style: StrokeStyle(lineWidth: 4, lineCap: .round))
      for x: CGFloat in [13, 79] {
        c.fill(Path(roundedRect: CGRect(x: x, y: 49, width: 10, height: 18), cornerRadius: 4), with: .color(Self.face))
        c.fill(Path(ellipseIn: CGRect(x: x + 2.5, y: 56, width: 5, height: 5)), with: .color(mood.color))
      }
    }
    if acc.nightcap {
      cap(&c, color: mood.color.opacity(0.9), pompom: .white, band: .white.opacity(0.85))
    }
    switch acc.hat {
    case .santa:
      cap(&c, color: Color(shellHex: 0xD7263D), pompom: .white, band: .white)
    case .pumpkin:
      pumpkin(&c)
    case .party:
      partyHat(&c)
    case nil:
      break
    }
  }

  /// Weiche Zipfelmütze mit Bommel; `band` ist der weiße Rand unten (Nikolausmütze).
  private func cap(_ c: inout GraphicsContext, color: Color, pompom: Color, band: Color?) {
    var h = Path()
    h.move(to: CGPoint(x: 24, y: 34))
    h.addQuadCurve(to: CGPoint(x: 78, y: 22), control: CGPoint(x: 42, y: 2))
    h.addQuadCurve(to: CGPoint(x: 76, y: 36), control: CGPoint(x: 84, y: 34))
    h.addQuadCurve(to: CGPoint(x: 24, y: 34), control: CGPoint(x: 50, y: 40))
    h.closeSubpath()
    c.fill(h, with: .color(color))
    if let band {
      c.fill(Path(roundedRect: CGRect(x: 20, y: 29, width: 60, height: 10), cornerRadius: 5), with: .color(band))
    }
    c.fill(Path(ellipseIn: CGRect(x: 72, y: 14, width: 12, height: 12)), with: .color(pompom))
  }

  /// Kürbis auf dem Kopf mit Stiel.
  private func pumpkin(_ c: inout GraphicsContext) {
    let orange = Color(shellHex: 0xFF8A1F)
    c.fill(Path(ellipseIn: CGRect(x: 24, y: 15, width: 52, height: 20)), with: .color(orange))
    for dx: CGFloat in [-8, 8] {
      var rib = Path()
      rib.move(to: CGPoint(x: 50 + dx * 0.4, y: 16))
      rib.addQuadCurve(to: CGPoint(x: 50 + dx, y: 34), control: CGPoint(x: 50 + dx * 1.6, y: 25))
      c.stroke(rib, with: .color(Color(shellHex: 0xC25E0A)), style: StrokeStyle(lineWidth: 1.6))
    }
    c.fill(Path(roundedRect: CGRect(x: 46, y: 8, width: 8, height: 10), cornerRadius: 3), with: .color(Color(shellHex: 0x3C8D2F)))
  }

  /// Partyhut: rosa Kegel mit gelbem Streifen und Stern.
  private func partyHat(_ c: inout GraphicsContext) {
    var cone = Path()
    cone.move(to: CGPoint(x: 28, y: 30))
    cone.addLine(to: CGPoint(x: 72, y: 30))
    cone.addLine(to: CGPoint(x: 50, y: -8))
    cone.closeSubpath()
    c.fill(cone, with: .color(Color(shellHex: 0xF472B6)))
    var stripe = Path()
    stripe.move(to: CGPoint(x: 38, y: 30)); stripe.addLine(to: CGPoint(x: 62, y: 30)); stripe.addLine(to: CGPoint(x: 50, y: 6))
    stripe.closeSubpath()
    c.fill(stripe, with: .color(Color(shellHex: 0xFACC15)))
    c.fill(sparkle(at: CGPoint(x: 50, y: -12), radius: 6, inner: 2), with: .color(Color(shellHex: 0xFACC15)))
  }

  /// Rosa Wangen unter den Augen (Streicheln).
  private func blush(_ f: inout GraphicsContext) {
    for x: CGFloat in [27, 73] {
      f.fill(Path(ellipseIn: CGRect(x: x - 6, y: 51, width: 12, height: 7)), with: .color(Color(shellHex: 0xFF7A9C).opacity(0.55)))
    }
  }

  /// Spirale statt Auge (Schwindel).
  private func spiral(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat) {
    var p = Path()
    for i in 0...20 {
      let a = Double(i) * 0.55
      let r = CGFloat(0.8 + 0.4 * Double(i))
      let pt = CGPoint(x: x + r * CGFloat(cos(a)), y: y + r * CGFloat(sin(a)))
      if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    c.stroke(p, with: white, style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
  }

  /// Regenwolke über dem Kopf mit fallenden Tropfen (Fehler).
  private func drawRain(_ ctx: inout GraphicsContext) {
    let cloud = Color(shellHex: 0x9AA3B5)
    ctx.fill(Path(ellipseIn: CGRect(x: 20, y: -4, width: 20, height: 16)), with: .color(cloud))
    ctx.fill(Path(ellipseIn: CGRect(x: 34, y: -10, width: 22, height: 19)), with: .color(cloud))
    ctx.fill(Path(ellipseIn: CGRect(x: 48, y: -2, width: 18, height: 14)), with: .color(cloud))
    ctx.fill(Path(roundedRect: CGRect(x: 26, y: 2, width: 40, height: 10), cornerRadius: 5), with: .color(cloud))
    for i in 0..<3 {
      let fr = (pose.t * 1.1 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
      var d = ctx
      d.opacity = 1 - fr
      d.fill(Path(ellipseIn: CGRect(x: 29 + CGFloat(i) * 14, y: 14 + 12 * CGFloat(fr), width: 4, height: 6)),
             with: .color(MascotMood.idle.color))
    }
  }

  /// Glühbirne über dem Kopf (Antwort ist angekommen).
  private func drawBulb(_ ctx: inout GraphicsContext, visibility v: CGFloat) {
    var b = ctx
    b.translateBy(x: 50, y: -16)
    b.scaleBy(x: v, y: v)
    b.fill(Path(ellipseIn: CGRect(x: -17, y: -17, width: 34, height: 34)), with: .color(Color(shellHex: 0xFFD54A).opacity(0.22)))
    b.fill(Path(ellipseIn: CGRect(x: -7.5, y: -9, width: 15, height: 15)), with: .color(Color(shellHex: 0xFFE07A)))
    b.fill(Path(roundedRect: CGRect(x: -3.5, y: 5, width: 7, height: 5), cornerRadius: 1.5), with: .color(Color(shellHex: 0x9AA0AD)))
    var rays = Path()
    rays.move(to: CGPoint(x: -12, y: -4)); rays.addLine(to: CGPoint(x: -15, y: -6))
    rays.move(to: CGPoint(x: 12, y: -4)); rays.addLine(to: CGPoint(x: 15, y: -6))
    rays.move(to: CGPoint(x: 0, y: -14)); rays.addLine(to: CGPoint(x: 0, y: -18))
    b.stroke(rays, with: .color(Color(shellHex: 0xFFE07A)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
  }

  /// Tasse in der linken Hand mit Dampf (Fokus-Pause).
  private func drawCoffee(_ ctx: inout GraphicsContext, tau: Double) {
    let tip = armTip(Self.shoulderL, degrees: Self.armRest + pose.leftArm)
    let x = tip.x + pose.dx - 4
    let y = tip.y + pose.dy - 6
    ctx.fill(Path(roundedRect: CGRect(x: x - 8, y: y, width: 16, height: 13), cornerRadius: 3.5), with: .color(.white))
    ctx.fill(Path(roundedRect: CGRect(x: x - 8, y: y, width: 16, height: 3.5), cornerRadius: 1.5),
             with: .color(Color(shellHex: 0x8B5A2B)))
    ctx.stroke(Path(ellipseIn: CGRect(x: x + 6, y: y + 3, width: 7, height: 6)), with: .color(.white),
               style: StrokeStyle(lineWidth: 2.4))
    for i in 0..<2 {
      let ph = (pose.t / 1.8 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
      let sx = x - 2 + CGFloat(i) * 4
      var s = Path()
      s.move(to: CGPoint(x: sx, y: y - 2))
      s.addQuadCurve(to: CGPoint(x: sx, y: y - 12), control: CGPoint(x: sx + 3 * CGFloat(sin(tau * ph)), y: y - 7))
      var st = ctx
      st.opacity = 0.7 * (1 - ph)
      st.stroke(s, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }
  }

  /// Requisit in der rechten Hand: Briefumschlag oder kleiner Laptop mit blinkendem Cursor.
  private func drawProp(_ ctx: inout GraphicsContext, show: MascotPropShow, tau: Double) {
    let tip = armTip(Self.shoulderR, degrees: -(Self.armRest + pose.rightArm))
    var g = ctx
    g.translateBy(x: tip.x + pose.dx, y: tip.y + pose.dy - 2)
    g.opacity = min(1, show.elapsed / 0.25, (MascotPropEvent.duration - show.elapsed) / 0.3)
    switch show.prop {
    case .envelope:
      g.translateBy(x: 0, y: CGFloat(sin(tau * show.elapsed * 1.5)) * 1.2)
      g.fill(Path(roundedRect: CGRect(x: -10, y: -7, width: 20, height: 14), cornerRadius: 2.5), with: .color(.white))
      var flap = Path()
      flap.move(to: CGPoint(x: -10, y: -7)); flap.addLine(to: CGPoint(x: 0, y: 1)); flap.addLine(to: CGPoint(x: 10, y: -7))
      g.stroke(flap, with: .color(MascotMood.idle.color), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    case .laptop:
      let screen = CGRect(x: -10, y: -10, width: 20, height: 13)
      g.fill(Path(roundedRect: screen, cornerRadius: 2), with: .color(Color(shellHex: 0x2A2D3A)))
      g.stroke(Path(roundedRect: screen.insetBy(dx: 1.2, dy: 1.2), cornerRadius: 1.2),
               with: .color(MascotMood.idle.color.opacity(0.9)), style: StrokeStyle(lineWidth: 1))
      if (show.elapsed * 2).truncatingRemainder(dividingBy: 1) < 0.5 {
        g.fill(Path(CGRect(x: -6, y: -5.5, width: 2, height: 5)), with: .color(.white))
      }
      g.fill(Path(roundedRect: CGRect(x: -12, y: 3, width: 24, height: 3.5), cornerRadius: 1.5),
             with: .color(Color(shellHex: 0xC9CCD6)))
    }
  }

  /// Glitzer-Konfetti rund um die Partymütze (gelegentlich).
  private func partyConfetti(_ ctx: inout GraphicsContext) {
    let cyc = pose.t.truncatingRemainder(dividingBy: 6)
    guard cyc < 1.8 else { return }
    for i in 0..<6 {
      let x = 50 + CGFloat(i - 3) * 9 + CGFloat(i % 2) * 3
      let y = -8 + 40 * CGFloat(cyc) + 25 * CGFloat(cyc * cyc)
      var p = ctx
      p.translateBy(x: x, y: y)
      p.rotate(by: .radians(cyc * 6 + Double(i)))
      p.opacity = 1 - cyc / 1.8
      p.fill(Path(CGRect(x: -2, y: -1.25, width: 4, height: 2.5)),
             with: .color(MascotConfetti.palette[i % MascotConfetti.palette.count].color))
    }
  }

  /// Funkel-Sterne über dem Kopf (Klick-Einlage „Verliebt“).
  private func drawSparkles(_ ctx: inout GraphicsContext, elapsed e: Double) {
    let env = CGFloat(sin(Double.pi * min(1, e / MascotAction.love.duration)))
    guard env > 0.01 else { return }
    let spots: [(p: CGPoint, k: CGFloat)] = [(CGPoint(x: 12, y: 18), 0.8), (CGPoint(x: 88, y: 22), 0.8), (CGPoint(x: 50, y: 4), 1)]
    for s in spots {
      ctx.fill(sparkle(at: s.p, radius: 7 * env * s.k, inner: 1.6 * env * s.k), with: .color(Color(shellHex: 0xFFE07A)))
    }
  }

  /// Alle Zusatzszenen außerhalb des Körpers (Regen, Glühbirne, Tasse, Requisit, Konfetti, Funkeln).
  private func extras(_ ctx: inout GraphicsContext, tau: Double) {
    if let e = scene.sparkle { drawSparkles(&ctx, elapsed: e) }
    if scene.rain { drawRain(&ctx) }
    if let v = scene.bulb, v > 0.01 { drawBulb(&ctx, visibility: v) }
    if scene.accessories.coffee { drawCoffee(&ctx, tau: tau) }
    if let p = scene.prop { drawProp(&ctx, show: p, tau: tau) }
    if scene.accessories.hat == .party { partyConfetti(&ctx) }
  }

  /// Vierzackiger Stern.
  private func sparkle(at p: CGPoint, radius r: CGFloat, inner i: CGFloat) -> Path {
    var s = Path()
    s.move(to: CGPoint(x: p.x, y: p.y - r))
    s.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + i, y: p.y - i))
    s.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x + i, y: p.y + i))
    s.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - i, y: p.y + i))
    s.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x - i, y: p.y - i))
    s.closeSubpath()
    return s
  }
}
