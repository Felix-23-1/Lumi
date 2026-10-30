// Blockierende Arbeit (Prozesse, getnameinfo, Dateisystem-Scans) gehört nicht in den
// kooperativen Thread-Pool von Swift Concurrency: der hat nur so viele Threads wie Kerne.
// Ein `Task.detached { blockierend }` hält einen davon fest; einige gleichzeitig (Netz-Scan,
// Kurzbefehl mit 300 s Zeitlimit) und jede async-Arbeit der App steht still.
import Foundation

public enum Blocking {
  /// Führt `body` auf einer GCD-Warteschlange aus und wartet ohne Pool-Thread darauf.
  public static func run<T>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global(qos: qos).async { cont.resume(with: Result { try body() }) }
    }
  }

  public static func run<T>(qos: DispatchQoS.QoSClass = .utility, _ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: qos).async { cont.resume(returning: body()) }
    }
  }
}
