// Prüfprogramm (ersetzt XCTest ohne Xcode).
//   swift run TabyChecks                 alle Prüfungen
//   swift run TabyChecks Store Planner   nur Suiten, deren Name passt
//   swift run TabyChecks --snapshots DIR [FILTER]   UI als PNG rendern
import AppKit
import Foundation
import TabyCore
import TabyUI

@MainActor
func runChecks(filters: [String]) async -> Int32 {
  let suites = CoreChecks.all + UIChecks.all
  var passed = 0
  var failed: [(String, String)] = []
  for suite in suites where filters.isEmpty || filters.contains(where: { suite.name.localizedCaseInsensitiveContains($0) }) {
    print("▸ \(suite.name) (\(suite.cases.count))")
    for c in suite.cases {
      do {
        try await c.body()
        passed += 1
        print("  ✓ \(c.name)")
      } catch {
        failed.append(("\(suite.name) › \(c.name)", "\(error)"))
        print("  ✗ \(c.name)\n      \(error)")
      }
    }
  }
  print("")
  print("\(passed) bestanden, \(failed.count) fehlgeschlagen")
  for (name, err) in failed { print("FEHLER \(name): \(err)") }
  return failed.isEmpty ? 0 : 1
}

// Prüfungen dürfen nie den echten Schlüsselbund anfassen (Passwort-Dialoge, Test-Einträge).
KeychainApiKeyStore.memoryOnly = true
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--snapshots" {
  guard args.count >= 2 else {
    print("Aufruf: TabyChecks --snapshots DIR [FILTER]")
    exit(2)
  }
  _ = NSApplication.shared
  let dir = URL(fileURLWithPath: args[1])
  let filter = args.count >= 3 ? args[2] : nil
  let urls = try await MainActor.run { try UISnapshots.renderAll(to: dir, filter: filter) }
  for u in urls { print(u.path) }
  exit(0)
}
let code = await runChecks(filters: args)
exit(code)
