// VERTRAG (nur Orchestrator ändert).
// Kleines Prüf-Gerüst statt XCTest/swift-testing (beides gibt es ohne Xcode
// nicht). Jeder Bereich legt seine Prüfungen als `CheckSuite` in seinem
// eigenen Verzeichnis ab (z. B. Store/StoreChecks.swift); `swift run
// TabyChecks` führt alle aus. Prüfungen liegen im selben Modul wie der Code,
// damit sie auch `internal` Funktionen testen können.
import Foundation

public struct CheckFailure: Error, CustomStringConvertible {
  public let message: String
  public let location: String
  public var description: String { "\(location): \(message)" }
}

public struct CheckCase {
  public let name: String
  public let body: () async throws -> Void
  public init(_ name: String, _ body: @escaping () async throws -> Void) {
    self.name = name; self.body = body
  }
}

public struct CheckSuite {
  public let name: String
  public let cases: [CheckCase]
  public init(_ name: String, _ cases: [CheckCase]) {
    self.name = name; self.cases = cases
  }
}

public func expect(
  _ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "Bedingung nicht erfüllt",
  file: StaticString = #fileID, line: UInt = #line
) throws {
  if try !condition() {
    throw CheckFailure(message: message(), location: "\(file):\(line)")
  }
}

public func expectEqual<T: Equatable>(
  _ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: String = "",
  file: StaticString = #fileID, line: UInt = #line
) throws {
  let a = try actual()
  let e = try expected()
  if a != e {
    let extra = message.isEmpty ? "" : " — \(message)"
    throw CheckFailure(message: "erwartet \(e), war \(a)\(extra)", location: "\(file):\(line)")
  }
}

public func expectNotNil<T>(
  _ value: @autoclosure () throws -> T?, _ message: String = "war nil",
  file: StaticString = #fileID, line: UInt = #line
) throws -> T {
  guard let v = try value() else { throw CheckFailure(message: message, location: "\(file):\(line)") }
  return v
}

public func expectThrows(
  _ message: String = "sollte einen Fehler werfen", file: StaticString = #fileID, line: UInt = #line,
  _ body: () async throws -> Void
) async throws {
  do {
    try await body()
  } catch is CheckFailure {
    throw CheckFailure(message: message, location: "\(file):\(line)")
  } catch {
    return
  }
  throw CheckFailure(message: message, location: "\(file):\(line)")
}

public func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> CheckFailure {
  CheckFailure(message: message, location: "\(file):\(line)")
}

/// Alle Kern-Prüfungen. Jede `...Checks`-Aufzählung gehört dem Agenten, dem
/// das jeweilige Verzeichnis gehört; diese Liste ändert nur der Orchestrator.
public enum CoreChecks {
  @MainActor public static var all: [CheckSuite] {
    [
      ContractChecks.suite,
      StoreChecks.suite,
      ToolChecks.suite,
      LlmChecks.suite,
      AgentLoopChecks.suite,
      PlannerChecks.suite,
      CalendarChecks.suite,
      AgentHookChecks.suite,
      RemindersChecks.suite,
      ExportChecks.suite,
      MCPChecks.suite,
      ModChecks.suite,
      IntegrationChecks.suite,
      SystemAdapterChecks.suite,
      ProductivityChecks.suite,
      PackageFourIntegrationChecks.suite,
      PackageFiveIntegrationChecks.suite,
      PackageSixIntegrationChecks.suite,
      PackageNineIntegrationChecks.suite,
      MailChecks.suite,
      NotionTaskChecks.suite,
      Package10StoreChecks.suite,
      PackageTenIntegrationChecks.suite,
      NetworkChecks.suite,
      NetworkProChecks.suite,
      MessengerChecks.suite,
      PackageTwelveChecks.suite,
      PackageThirteenChecks.suite,
    ]
  }
}
