// Konfetti und Feuerwerk aus der Notch sowie die Mausgesten am Maskottchen.
// Die Teilchen sind eine reine Funktion von Startzeit, Saat und Zeit: gleiche
// Eingaben ergeben immer dieselben Positionen (Snapshots, Prüfungen).
import SwiftUI
import TabyCore

/// Ein laufender Jubel: Konfetti (Aufgabe erledigt) oder Feuerwerk (letzte Aufgabe für heute).
struct CelebrationBurst: Equatable, Sendable {
  enum Kind: Sendable { case confetti, fireworks }
  let kind: Kind
  /// Store-Uhr in Sekunden.
  let startedAt: Double
  /// Saat für die Teilchen (bei jedem Jubel anders).
  let seed: UInt64

  var duration: Double { kind == .confetti ? 1.2 : 2.1 }
}

/// Kleiner, deterministischer Zufallsgenerator (SplitMix64).
struct MascotSplitMix {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  /// Gleichverteilt in 0 ..< 1.
  mutating func unit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z >> 31)
    return Double(z >> 11) / Double(1 << 53)
  }
}

/// Ein Teilchen im Koordinatensystem der Notch (y nach unten, Ursprung unter der Notchmitte).
struct MascotParticle: Equatable {
  var x: CGFloat
  var y: CGFloat
  var angle: Double
  var colorIndex: Int
  var width: CGFloat
  var height: CGFloat
  var alpha: Double
}

enum MascotConfetti {
  static let gravity: CGFloat = 900
  static let palette: [MascotMood] = [.happy, .idle, .love, .alert, .error]

  /// Konfetti: spritzt nach oben, fällt mit Schwerkraft und dreht sich.
  static func pieces(seed: UInt64, count: Int, elapsed e: Double, duration: Double) -> [MascotParticle] {
    var rng = MascotSplitMix(seed: seed)
    var out: [MascotParticle] = []
    let ce = CGFloat(e)
    for _ in 0..<count {
      let vx = CGFloat(rng.unit() * 2 - 1) * 300
      let vy = -CGFloat(80 + rng.unit() * 220)
      let spin = (rng.unit() * 2 - 1) * 14
      let color = min(palette.count - 1, Int(rng.unit() * Double(palette.count)))
      let w = CGFloat(5 + rng.unit() * 4)
      let h = CGFloat(3 + rng.unit() * 3)
      out.append(MascotParticle(x: ce * vx, y: ce * vy + 0.5 * gravity * ce * ce, angle: spin * e,
                                colorIndex: color, width: w, height: h, alpha: fade(e, duration: duration)))
    }
    return out
  }

  /// Feuerwerk: drei Salven nacheinander, jede mit radial fliegenden Funken.
  static let bursts: [(x: CGFloat, y: CGFloat, start: Double)] = [(-96, -14, 0), (2, -36, 0.35), (96, -10, 0.75)]
  static let sparkLife: Double = 1.3

  static func fireworks(seed: UInt64, elapsed e: Double) -> [MascotParticle] {
    var rng = MascotSplitMix(seed: seed)
    var out: [MascotParticle] = []
    for b in bursts {
      let local = e - b.start
      // Pro Salve feste Zahl Funken, unabhängig vom Zeitpunkt (Zufall bleibt stabil).
      let sparks = 30
      for _ in 0..<sparks {
        let angle = rng.unit() * 2 * Double.pi
        let speed = CGFloat(150 + rng.unit() * 150)
        let color = min(palette.count - 1, Int(rng.unit() * Double(palette.count)))
        guard local >= 0, local < sparkLife else { continue }
        let le = CGFloat(local)
        let x = b.x + CGFloat(cos(angle)) * speed * le
        let y = b.y + CGFloat(sin(angle)) * speed * le + 0.5 * 260 * le * le
        out.append(MascotParticle(x: x, y: y, angle: 0, colorIndex: color, width: 5.5, height: 5.5,
                                  alpha: fade(local, duration: sparkLife)))
      }
    }
    return out
  }

  /// Ausblenden in den letzten 0,3 s.
  static func fade(_ e: Double, duration: Double) -> Double {
    guard e >= 0, e < duration else { return 0 }
    return min(1, (duration - e) / 0.3)
  }
}

/// Konfetti/Feuerwerk oberhalb der Notch; nur während eines Ausbruchs sichtbar.
struct MascotEffectsOverlay: View {
  @ObservedObject var store: IslandStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Reduce Motion: kein Konfetti und kein Feuerwerk.
    if let b = store.celebration, !reduceMotion {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
        let e = store.now() - b.startedAt
        Canvas { ctx, _ in
          let origin = CGPoint(x: 450, y: store.geometry.notchHeight * 0.5)
          let parts: [MascotParticle]
          switch b.kind {
          case .confetti:
            parts = MascotConfetti.pieces(seed: b.seed, count: 70, elapsed: e, duration: b.duration)
          case .fireworks:
            parts = MascotConfetti.fireworks(seed: b.seed, elapsed: e)
          }
          for p in parts where p.alpha > 0 {
            var c = ctx
            c.translateBy(x: origin.x + p.x, y: origin.y + p.y)
            c.rotate(by: .radians(p.angle))
            let color = MascotConfetti.palette[p.colorIndex].color
            let rect = CGRect(x: -p.width / 2, y: -p.height / 2, width: p.width, height: p.height)
            c.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(p.alpha)))
          }
        }
        .frame(width: 900, height: 900)
        .allowsHitTesting(false)
      }
    }
  }
}

/// Hover, Schüttel-Erkennung und Ziehen am Maskottchen (nur Mauseingaben).
struct MascotInteraction: ViewModifier {
  let store: IslandStore
  let drag: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    let hovered = content
      .onHover { store.mascotHover($0) }
      .onContinuousHover { phase in
        if case .active(let p) = phase { store.mascotPointer(x: p.x) }
      }
    if drag {
      hovered.gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { store.mascotDrag($0.translation) }
          .onEnded { _ in store.mascotDragEnded() }
      )
    } else {
      hovered
    }
  }
}

extension View {
  /// Hover (Streicheln), Mauspunkte (Schwindel) und optional Ziehen am Maskottchen.
  func mascotInteractions(_ store: IslandStore, drag: Bool = false) -> some View {
    modifier(MascotInteraction(store: store, drag: drag))
  }
}
