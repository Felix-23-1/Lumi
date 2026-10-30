// Reine Logik für „einkreisen und fragen“: Auswahlrechteck aus dem Mauspfad und Sprech-Ende.
import CoreGraphics
import Foundation

public enum CircleLogic {
  /// Begrenzungsrechteck des Pfads, auf mindestens `minSize` vergrößert, um `padding` erweitert und in `bounds` geklemmt.
  /// nil bei leerem Pfad oder wenn `bounds` kleiner als `minSize` ist.
  public static func boundingRect(path: [CGPoint], padding: CGFloat, minSize: CGFloat, bounds: CGRect) -> CGRect? {
    guard let first = path.first, bounds.width >= minSize, bounds.height >= minSize else { return nil }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in path { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
    let (x0, x1) = span(minX - padding, maxX + padding, minSize, bounds.minX, bounds.maxX)
    let (y0, y1) = span(minY - padding, maxY + padding, minSize, bounds.minY, bounds.maxY)
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  /// Eine Achse: auf mindestens `size` um die Mitte weiten, dann auf [lo, hi] kürzen und bei Bedarf nach innen verlängern.
  private static func span(_ a: CGFloat, _ b: CGFloat, _ size: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> (CGFloat, CGFloat) {
    let mid = (a + b) / 2, half = max(b - a, size) / 2
    var s = max(mid - half, lo), e = min(mid + half, hi)
    if e - s < size { if s == lo { e = min(lo + size, hi) } else { s = max(hi - size, lo) } }
    return (s, e)
  }

  /// Hören beenden: Text da und `quiet` Sekunden unverändert, oder `maxWait` Sekunden ohne Text.
  public static func shouldStopListening(text: String, lastChange: Date, now: Date, started: Date,
                                         quiet: TimeInterval = 1.6, maxWait: TimeInterval = 8) -> Bool {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return now.timeIntervalSince(started) >= maxWait
    }
    return now.timeIntervalSince(lastChange) >= quiet
  }
}
