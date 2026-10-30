// Bündelt Textteile eines Modell-Stroms: meldet höchstens alle `interval`
// Sekunden den gesamten bisherigen Text. Was im Intervall hinzukommt, geht
// mit einer einzigen Nachlauf-Meldung raus (kein Timer-Polling, kein Busy-Loop).
import Foundation

public final class PartialThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private let interval: TimeInterval
  private let now: @Sendable () -> TimeInterval
  private let emit: @Sendable (String) -> Void
  private var text = ""
  private var lastEmit: TimeInterval = -.infinity
  private var pending: Task<Void, Never>?
  private var finished = false

  /// 15 Meldungen pro Sekunde. `emit` muss schnell sein (z. B. nur einen Task zum Hauptakteur starten).
  public init(interval: TimeInterval = 1.0 / 15,
              now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
              emit: @escaping @Sendable (String) -> Void) {
    self.interval = interval; self.now = now; self.emit = emit
  }

  /// Hängt ein Textstück an. Meldet sofort, wenn das Intervall vorbei ist, sonst mit dem Nachlauf.
  /// `emit` läuft unter dem Schloss, damit die Meldungen in Reihenfolge ankommen.
  public func append(_ delta: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    text += delta
    let t = now()
    if t - lastEmit >= interval {
      lastEmit = t
      emit(text)
    } else if pending == nil {
      let wait = interval - (t - lastEmit)
      pending = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
        self?.flush()
      }
    }
  }

  /// Keine Meldungen mehr (Strom zu Ende oder abgebrochen). Ein noch offener Rest
  /// geht vorher einmal sofort raus, damit der letzte Stand nicht verloren geht.
  public func finish() {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    guard pending != nil else { return }
    pending?.cancel()
    pending = nil
    emit(text)
  }

  private func flush() {
    lock.lock()
    defer { lock.unlock() }
    pending = nil
    guard !finished else { return }
    lastEmit = now()
    emit(text)
  }
}
