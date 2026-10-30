// App-Symbol und Menüleisten-Symbol im Stil des Maskottchens: dunkles,
// abgerundetes Quadrat, zwei weiße Augen-Pillen, feines Lächeln.
import AppKit
import SwiftUI

/// App-Symbol (1024er Raster nach macOS-Vorlage: Fläche 824 mit Rand 100).
public struct AppIconArt: View {
  public init() {}
  public var body: some View {
    Canvas { ctx, size in
      let s = size.width / 1024
      ctx.scaleBy(x: s, y: s)
      let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
      let shape = Path(roundedRect: rect, cornerRadius: 185, style: .continuous)
      var shadow = ctx
      shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 24, y: 12))
      shadow.fill(shape, with: .linearGradient(Gradient(colors: [Color(shellHex: 0x2A2A2E), Color(shellHex: 0x08080A)]),
                                               startPoint: CGPoint(x: 512, y: 100), endPoint: CGPoint(x: 512, y: 924)))
      ctx.stroke(shape, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 6))
      let white = GraphicsContext.Shading.color(.white)
      for x in [370.0, 654.0] {
        ctx.fill(Path(roundedRect: CGRect(x: x - 62, y: 330, width: 124, height: 250), cornerRadius: 62), with: white)
      }
      var smile = Path()
      smile.move(to: CGPoint(x: 420, y: 690))
      smile.addQuadCurve(to: CGPoint(x: 604, y: 690), control: CGPoint(x: 512, y: 760))
      ctx.stroke(smile, with: white, style: StrokeStyle(lineWidth: 26, lineCap: .round))
    }
  }
}

public enum MenuBarIcon {
  /// Vorlage-Bild (folgt hell/dunkel der Menüleiste): Gesicht ausgestanzt.
  public static func make(size: CGFloat = 18) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
      guard let cg = NSGraphicsContext.current?.cgContext else { return false }
      let k = r.width / 18
      cg.setFillColor(NSColor.black.cgColor)
      cg.addPath(CGPath(roundedRect: CGRect(x: 1.5 * k, y: 1.5 * k, width: 15 * k, height: 15 * k),
                        cornerWidth: 4.4 * k, cornerHeight: 4.4 * k, transform: nil))
      cg.fillPath()
      cg.setBlendMode(.clear)
      for x in [6.4, 11.6] {
        cg.addPath(CGPath(roundedRect: CGRect(x: (x - 1.15) * k, y: 5.2 * k, width: 2.3 * k, height: 4.6 * k),
                          cornerWidth: 1.15 * k, cornerHeight: 1.15 * k, transform: nil))
      }
      cg.fillPath()
      cg.setLineWidth(1.2 * k)
      cg.setLineCap(.round)
      cg.setStrokeColor(NSColor.black.cgColor)
      cg.move(to: CGPoint(x: 7.3 * k, y: 12 * k))
      cg.addQuadCurve(to: CGPoint(x: 10.7 * k, y: 12 * k), control: CGPoint(x: 9 * k, y: 13.4 * k))
      cg.strokePath()
      return true
    }
    img.isTemplate = true
    return img
  }
}
