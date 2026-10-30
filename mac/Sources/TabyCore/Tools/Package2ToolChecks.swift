// Prüfungen für Paket 2 im Werkzeugbereich: gemerkte Fakten, postpone_tasks
// und DueShift. Echte Datenbank (im Speicher) und echter Dispatcher.
import Foundation

private func p2Ctx(now: String = "2024-03-04T08:00", mode: JobMode = .standard) throws -> ToolContext {
  let clock = ControllableClock(now)
  return ToolContext(store: try Store.inMemory(clock: clock), mode: mode)
}

private func p2Run(_ name: String, _ args: JSONValue = [:], _ ctx: ToolContext) async -> JSONValue {
  await ToolRegistry.execute(name: name, args: args, ctx: ctx)
}

private func p2Same<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                  file: StaticString = #fileID, line: UInt = #line) throws {
  if actual != expected {
    let extra = message.isEmpty ? "" : " — \(message)"
    throw CheckFailure(message: "erwartet \(expected), war \(actual)\(extra)", location: "\(file):\(line)")
  }
}

private func p2Code(_ r: JSONValue, _ code: String, file: StaticString = #fileID, line: UInt = #line) throws {
  try p2Same(r["ok"]?.boolValue, false, "ok muss false sein", file: file, line: line)
  try p2Same(r["code"]?.stringValue, code, "Fehlercode", file: file, line: line)
}

extension ToolChecks {
  static let package2Checks: [CheckCase] = [
    CheckCase("Fakten: remember_fact trimmt, list_memories listet, forget_fact löscht") {
      let ctx = try p2Ctx()
      let r = await p2Run("remember_fact", ["text": "  Zahnarzt ist Dr. Müller  "], ctx)
      try p2Same(r["ok"]?.boolValue, true)
      try p2Same(r["memory"]?["text"]?.stringValue, "Zahnarzt ist Dr. Müller")
      let id = try expectNotNil(r["memory"]?["id"]?.stringValue, "id fehlt")
      let listed = await p2Run("list_memories", [:], ctx)
      try p2Same(listed["memories"]?.arrayValue?.count, 1)
      let gone = await p2Run("forget_fact", ["id": .string(id)], ctx)
      try p2Same(gone["ok"]?.boolValue, true)
      try p2Code(await p2Run("forget_fact", ["id": .string(id)], ctx), "NOT_FOUND")
      try p2Same(try ctx.store.memories.list().count, 0)
    },
    CheckCase("Fakten: leerer Text wird abgelehnt (INVALID_ARGS), nichts gespeichert") {
      let ctx = try p2Ctx()
      try p2Code(await p2Run("remember_fact", ["text": "   "], ctx), "INVALID_ARGS")
      try p2Code(await p2Run("forget_fact", [:], ctx), "INVALID_ARGS")
      try p2Same(try ctx.store.memories.list().count, 0)
      try await expectThrows("Store-Ebene lehnt leeren Text ab") { _ = try ctx.store.memories.add("  ") }
    },
    CheckCase("Fakten: Lesemodus erlaubt nur list_memories, Schreiben wird gesperrt") {
      let ctx = try p2Ctx(mode: .readOnly)
      _ = try ctx.store.memories.add("Bestehender Fakt")
      let listed = await p2Run("list_memories", [:], ctx)
      try p2Same(listed["ok"]?.boolValue, true)
      try p2Same(listed["memories"]?.arrayValue?.count, 1)
      try p2Code(await p2Run("remember_fact", ["text": "Neu"], ctx), "READ_ONLY")
      try p2Code(await p2Run("forget_fact", ["id": "x"], ctx), "READ_ONLY")
      try p2Code(await p2Run("postpone_tasks", ["ids": []], ctx), "READ_ONLY")
      try p2Same(try ctx.store.memories.list().count, 1)
    },
    CheckCase("Fakten: nur Änderungen landen im Protokoll, Lesen nicht") {
      let ctx = try p2Ctx()
      _ = await p2Run("remember_fact", ["text": "Fakt"], ctx)
      _ = await p2Run("list_memories", [:], ctx)
      let tools = try ctx.store.actionLog.list(limit: 10).map(\.tool)
      try p2Same(tools, ["remember_fact"], "nur Änderungen werden protokolliert")
    },
    CheckCase("postpone_tasks: Datum ohne Uhrzeit, Uhrzeit bleibt, ohne Fälligkeit → morgen, erledigte übersprungen") {
      let ctx = try p2Ctx(now: "2024-03-04T08:00")
      let dateOnly = try ctx.store.tasks.add(title: "Datum", due: "2024-03-01")
      let timed = try ctx.store.tasks.add(title: "Uhrzeit", due: "2024-03-04T14:30")
      let none = try ctx.store.tasks.add(title: "Ohne")
      let done = try ctx.store.tasks.add(title: "Erledigt", due: "2024-03-04")
      _ = try ctx.store.tasks.complete(done.id)
      let r = await p2Run("postpone_tasks", ["ids": .array([.string(dateOnly.id), .string(timed.id),
                                                            .string(none.id), .string(done.id)])], ctx)
      try p2Same(r["ok"]?.boolValue, true)
      try p2Same(r["moved"]?.numberValue, 3)
      try p2Same(try ctx.store.tasks.get(dateOnly.id)?.due, "2024-03-05")
      try p2Same(try ctx.store.tasks.get(timed.id)?.due, "2024-03-05T14:30")
      try p2Same(try ctx.store.tasks.get(none.id)?.due, "2024-03-05")
      try p2Same(try ctx.store.tasks.get(done.id)?.due, "2024-03-04", "erledigte Aufgabe bleibt unverändert")
    },
    CheckCase("postpone_tasks: unbekannte IDs werden übersprungen, ungültige Liste → INVALID_ARGS") {
      let ctx = try p2Ctx()
      let t = try ctx.store.tasks.add(title: "T", due: "2024-03-04")
      let r = await p2Run("postpone_tasks", ["ids": .array([.string("gibt-es-nicht"), .string(t.id)])], ctx)
      try p2Same(r["moved"]?.numberValue, 1)
      try p2Code(await p2Run("postpone_tasks", ["ids": "kein Array"], ctx), "INVALID_ARGS")
      try p2Code(await p2Run("postpone_tasks", ["ids": .array([.number(3)])], ctx), "INVALID_ARGS")
    },
    CheckCase("DueShift: Monats-, Jahres- und Schaltjahrgrenzen") {
      try p2Same(DueShift.toTomorrow(nil, today: "2024-01-31"), "2024-02-01")
      try p2Same(DueShift.toTomorrow(nil, today: "2024-02-28"), "2024-02-29", "Schaltjahr 2024")
      try p2Same(DueShift.toTomorrow(nil, today: "2023-02-28"), "2023-03-01", "kein Schaltjahr 2023")
      try p2Same(DueShift.toTomorrow(nil, today: "2023-12-31"), "2024-01-01")
      try p2Same(DueShift.toTomorrow("", today: "2024-04-30"), "2024-05-01")
    },
    CheckCase("DueShift: Uhrzeit bleibt erhalten, Datum ohne Uhrzeit wird morgen") {
      try p2Same(DueShift.toTomorrow("2024-03-04T14:30", today: "2024-03-04"), "2024-03-05T14:30")
      try p2Same(DueShift.toTomorrow("2024-12-31T23:59", today: "2024-12-31"), "2025-01-01T23:59")
      try p2Same(DueShift.toTomorrow("2020-01-01", today: "2024-03-04"), "2024-03-05", "alte Fälligkeit → morgen")
      try p2Same(DueShift.toTomorrow("2024-03-04T25:99", today: "2024-03-04"), "2024-03-05", "ungültige Uhrzeit")
    },
  ]
}
