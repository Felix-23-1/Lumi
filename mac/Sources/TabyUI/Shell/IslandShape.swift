// Form der Insel: oben bündig mit der Bildschirmkante, unten rund, an den
// oberen Ecken konkave "Ohren", die weich in die Kante übergehen (wie die
// echte Notch). Alle Maße sind animierbar, damit die Form beim Öffnen
// federnd wächst statt zu überblenden.
import SwiftUI

struct IslandShape: Shape {
  /// Breite/Höhe des Körpers (ohne Ohren). Die Form ist `width + 2·ear` breit.
  var width: CGFloat
  var height: CGFloat
  var bottomRadius: CGFloat
  var ear: CGFloat

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { .init(.init(width, height), .init(bottomRadius, ear)) }
    set {
      width = newValue.first.first
      height = newValue.first.second
      bottomRadius = newValue.second.first
      ear = newValue.second.second
    }
  }

  func path(in rect: CGRect) -> Path {
    // Körper mittig im Rahmen (der Rahmen kann breiter sein, z. B. das Panel).
    let e = max(0, ear)
    let left = rect.midX - width / 2
    let right = rect.midX + width / 2
    let top = rect.minY
    let bottom = top + height
    let r = min(bottomRadius, width / 2, height / 2)
    let er = min(e, height / 2)
    var p = Path()
    p.move(to: CGPoint(x: left - e, y: top))
    p.addLine(to: CGPoint(x: right + e, y: top))
    // Rechtes Ohr: konkav von der Kante nach unten in die Seitenwand.
    p.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: top + er), radius: min(e, er))
    p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: r)
    p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: r)
    p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left - e, y: top), radius: min(e, er))
    p.closeSubpath()
    return p
  }
}
