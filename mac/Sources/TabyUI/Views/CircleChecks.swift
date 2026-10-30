// Prüfungen der Einkreisen-Logik: Auswahlrechteck und Sprech-Ende.
import CoreGraphics
import Foundation
import TabyCore

enum CircleChecks {
  static let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Einkreisen: Rechteck umschließt den Pfad mit Rand") {
        let r = CircleLogic.boundingRect(path: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200), CGPoint(x: 150, y: 250)],
                                         padding: 8, minSize: 24, bounds: screen)
        try expect(r == CGRect(x: 92, y: 92, width: 216, height: 166), "\(String(describing: r))")
      },
      CheckCase("Einkreisen: Mindestgröße bei Klick ohne Ziehen") {
        let r = CircleLogic.boundingRect(path: [CGPoint(x: 500, y: 400)], padding: 0, minSize: 24, bounds: screen)
        try expect(r == CGRect(x: 488, y: 388, width: 24, height: 24), "\(String(describing: r))")
      },
      CheckCase("Einkreisen: Rechteck bleibt im Bildschirm") {
        let r = CircleLogic.boundingRect(path: [CGPoint(x: -50, y: 790), CGPoint(x: 1200, y: 900)],
                                         padding: 8, minSize: 24, bounds: screen)
        try expect(r == CGRect(x: 0, y: 776, width: 1000, height: 24), "\(String(describing: r))")
      },
      CheckCase("Einkreisen: leerer Pfad gibt nil") {
        try expect(CircleLogic.boundingRect(path: [], padding: 8, minSize: 24, bounds: screen) == nil, "leer")
      },
      CheckCase("Einkreisen: Hören endet nach Stille, nicht davor") {
        let t0 = Date(timeIntervalSince1970: 1000)
        func stop(_ text: String, change: Double, now: Double) -> Bool {
          CircleLogic.shouldStopListening(text: text, lastChange: t0.addingTimeInterval(change),
                                          now: t0.addingTimeInterval(now), started: t0)
        }
        try expect(!stop("Was ist das", change: 2, now: 3), "nach 1 s noch nicht")
        try expect(stop("Was ist das", change: 2, now: 3.7), "nach 1,7 s Stille")
        try expect(!stop("", change: 0, now: 7.9), "ohne Text vor 8 s")
        try expect(stop("  ", change: 0, now: 8), "ohne Text nach 8 s")
      },
    ]
  }
}
