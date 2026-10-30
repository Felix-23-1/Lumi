// Dezenter Effekt hinter der Now-Playing-Karte. Reine Optik, keine Audioanalyse.
// Klein gehalten: ein Canvas, 30 Bilder pro Sekunde, Pause (kein Timer) ohne Wiedergabe oder mit „Bewegung reduzieren“.
import SwiftUI

struct MusicEffectView: View {
  let effect: MusicEffect
  let playing: Bool
  let title: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    let live = MusicLogic.animates(playing: playing, reduceMotion: reduceMotion) && !snapshot
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
      // Statisches Bild: feste Zeit, damit es ruhig und vorhersagbar aussieht.
      let t = live ? context.date.timeIntervalSinceReferenceDate : 1.7
      Canvas { gc, size in
        switch effect {
        case .off: break
        case .bars: Self.drawBars(&gc, size, t)
        case .waves: Self.drawWaves(&gc, size, t)
        case .glow: Self.drawGlow(&gc, size, t, hue: MusicLogic.hue(title))
        }
      }
    }
    .opacity(playing ? 1 : 0.4)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private static func drawBars(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
    let n = 28
    let gap: CGFloat = 4
    let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
    for (i, h) in MusicLogic.barHeights(count: n, t: t).enumerated() {
      let bh = size.height * CGFloat(h)
      let r = CGRect(x: CGFloat(i) * (w + gap), y: size.height - bh, width: w, height: bh)
      gc.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(Theme.blue.opacity(0.2)))
    }
  }

  private static func drawWaves(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
    for line in 0..<3 {
      var p = Path()
      let mid = size.height * (0.4 + 0.2 * CGFloat(line))
      let amp = size.height * 0.28
      for step in 0...48 {
        let x = Double(step) / 48
        let pt = CGPoint(x: size.width * x, y: mid + amp * CGFloat(MusicLogic.waveOffset(line: line, x: x, t: t)))
        step == 0 ? p.move(to: pt) : p.addLine(to: pt)
      }
      gc.stroke(p, with: .color(Theme.blue.opacity(0.35 - 0.08 * Double(line))), lineWidth: 1.6)
    }
  }

  private static func drawGlow(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double, hue: Double) {
    let k = MusicLogic.glowPulse(t: t)
    let c1 = Color(hue: hue, saturation: 0.6, brightness: 0.9)
    let c2 = Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.9)
    for (i, c) in [c1, c2].enumerated() {
      let r = size.height * (1.1 + 0.15 * CGFloat(k))
      let cx = size.width * (i == 0 ? 0.3 : 0.7) + CGFloat(sin(t * 0.5 + Double(i) * 2)) * 20
      let rect = CGRect(x: cx - r, y: size.height - r * 0.7, width: r * 2, height: r * 1.4)
      gc.fill(Path(ellipseIn: rect),
              with: .radialGradient(Gradient(colors: [c.opacity(0.4 * k), c.opacity(0)]),
                                    center: CGPoint(x: cx, y: size.height * 0.9), startRadius: 0, endRadius: r))
    }
  }
}
