// Takt für den Planer: tickt sofort beim Start, dann alle `interval` Sekunden und
// zusätzlich beim Aufwachen aus dem Ruhezustand (statt Electron powerMonitor 'resume').
// Die Logik bleibt in `Planner.tick()`; hier nur Zeitsteuerung.
import AppKit
import Foundation

public final class PlannerRunner {
  public typealias TickHandler = (PlannerTickReport) async -> Void

  public let planner: Planner
  public let interval: TimeInterval
  private let observeSystemWake: Bool
  private let onTick: TickHandler?
  private let lock = NSLock()
  private var loop: Task<Void, Never>?
  private var wakeObserver: NSObjectProtocol?

  /// - interval: Sekunden zwischen Ticks (BAUPLAN: 30).
  /// - observeSystemWake: bei `NSWorkspace.didWakeNotification` sofort ticken.
  /// - onTick: nach jedem Tick (Hintergrund-Task; für die UI selbst auf den MainActor wechseln).
  public init(planner: Planner, interval: TimeInterval = 30, observeSystemWake: Bool = true,
              onTick: TickHandler? = nil) {
    self.planner = planner
    self.interval = max(0.01, interval)
    self.observeSystemWake = observeSystemWake
    self.onTick = onTick
  }

  deinit { stop() }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return loop != nil
  }

  public func start() {
    stop()
    let planner = planner, interval = interval, onTick = onTick
    let task = Task.detached {
      while !Task.isCancelled {
        let report = await planner.tick()
        if let onTick, !Task.isCancelled { await onTick(report) }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
    var observer: NSObjectProtocol?
    if observeSystemWake {
      observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
      ) { [weak self] _ in self?.tickNow() }
    }
    lock.lock()
    loop = task
    wakeObserver = observer
    lock.unlock()
  }

  public func stop() {
    lock.lock()
    let task = loop, observer = wakeObserver
    loop = nil
    wakeObserver = nil
    lock.unlock()
    task?.cancel()
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }

  /// Sofortiger Zusatz-Tick (Aufwachen, Entsperren). Läuft gerade einer, wird er übersprungen.
  public func tickNow() {
    let planner = planner, onTick = onTick
    Task.detached {
      let report = await planner.tick()
      if let onTick, !report.skipped { await onTick(report) }
    }
  }
}
