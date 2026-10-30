// Serieller Zugriff auf ein nicht threadsicheres Objekt (vor allem EKEventStore).
// Absturzberichte zeigten Use-after-free in EventKit, wenn mehrere Tasks den Store
// gleichzeitig abfragten (Kalender-Provider im TaskGroup, Planer-Takt, Erinnerungs-Abgleich).
import EventKit
import Foundation

public final class SerialAccess<Resource>: @unchecked Sendable {
  private let resource: Resource
  private let queue: DispatchQueue

  public init(_ resource: Resource, label: String) {
    self.resource = resource
    self.queue = DispatchQueue(label: label)
  }

  /// Führt `body` exklusiv auf der seriellen Queue aus. Objekte des Stores nie aus `body` herausreichen.
  public func run<T>(_ body: @escaping (Resource) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
      queue.async { cont.resume(with: Result { try body(self.resource) }) }
    }
  }
}

public enum EventKitStore {
  /// Ein Store für die ganze App (Kalender und Erinnerungen); Apple empfiehlt genau einen.
  public static let shared = SerialAccess(EKEventStore(), label: "taby.eventkit")
}
