// Prüfungen für Sources/TabyCore/Export (Markdown-Export) mit einem
// temporären Ordner und einer Speicher-Datenbank mit steuerbarer Uhr.
import Foundation

private func exportDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("taby-export-\(StoreIds.make())")
}

private func readText(_ url: URL) throws -> String {
  try String(contentsOf: url, encoding: .utf8)
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

private func sameValue<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                     file: StaticString = #fileID, line: UInt = #line) throws {
  if actual != expected {
    let extra = message.isEmpty ? "" : " — \(message)"
    throw CheckFailure(message: "erwartet \(expected), war \(actual)\(extra)", location: "\(file):\(line)")
  }
}

enum ExportChecks {
  static let suite = CheckSuite("Export", [
    CheckCase("Export: Notizen, Aufgaben und Habits werden mit Inhalt geschrieben") {
      let dir = exportDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      _ = try store.notes.add(title: "Einkauf", content: "Milch\nBrot")
      _ = try store.tasks.add(title: "Zahnarzt", due: "2024-03-05T14:00")
      let altes = try store.tasks.add(title: "Altes")
      _ = try store.tasks.complete(altes.id)
      let habit = try store.habits.add(name: "Lesen")
      _ = try store.habits.check(habit.id, date: "2024-03-04")

      let result = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      try sameValue(result.files, 3, "1 Notiz + Aufgaben.md + Habits.md")
      try sameValue(result.folder, dir.appendingPathComponent("Lumi").path)

      let note = try readText(dir.appendingPathComponent("Lumi/Notizen/Einkauf.md"))
      try sameValue(note.hasPrefix("---\nerstellt: 2024-03-04T08:00\ngeändert: 2024-03-04T08:00\n---\n"), true,
                    "Front Matter")
      try sameValue(note.hasSuffix("Milch\nBrot\n"), true, "Inhalt")

      let aufgaben = try readText(dir.appendingPathComponent("Lumi/Aufgaben.md"))
      try sameValue(aufgaben.contains("## Offen"), true)
      try sameValue(aufgaben.contains("- [ ] Zahnarzt (fällig: 2024-03-05 14:00)"), true, "offene Aufgabe")
      try sameValue(aufgaben.contains("## Erledigt"), true)
      try sameValue(aufgaben.contains("- [x] Altes"), true, "erledigte Aufgabe")

      let habits = try readText(dir.appendingPathComponent("Lumi/Habits.md"))
      try sameValue(habits.contains("- Lesen – Serie: 1 Tag, heute erledigt"), true, "Habit mit Streak")
    },
    CheckCase("Export: Titel werden bereinigt, leere Titel werden zu 'Ohne Titel', Länge max. 80") {
      let dir = exportDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      _ = try store.notes.add(title: "Plan/2024:Ein?Test", content: "a")
      _ = try store.notes.add(title: ".Geheim", content: "b")
      _ = try store.notes.add(title: "   ", content: "c")
      _ = try store.notes.add(title: "a<b>c|d*e\"f\\g", content: "d")
      _ = try store.notes.add(title: String(repeating: "x", count: 120), content: "e")
      _ = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Lumi/Notizen").path)
        .filter { $0.hasSuffix(".md") }
      try sameValue(names.contains("Plan-2024-Ein-Test.md"), true, "verbotene Zeichen ersetzt: \(names)")
      try sameValue(names.contains("Geheim.md"), true, "führende Punkte entfernt: \(names)")
      try sameValue(names.contains("Ohne Titel.md"), true, "leerer Titel: \(names)")
      try sameValue(names.contains("a-b-c-d-e-f-g.md"), true, "alle Sonderzeichen: \(names)")
      let long = names.first { $0.hasPrefix("xxxx") }
      try sameValue(long?.count, 83, "80 Zeichen plus .md: \(names)")
    },
    CheckCase("Export: doppelte Titel werden mit ' (2)', ' (3)' nummeriert") {
      let dir = exportDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      _ = try store.notes.add(title: "Idee", content: "erste")
      clock.advance(seconds: 60)
      _ = try store.notes.add(title: "Idee", content: "zweite")
      clock.advance(seconds: 60)
      _ = try store.notes.add(title: "idee", content: "dritte")
      let result = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      try sameValue(result.files, 5)
      let notes = dir.appendingPathComponent("Lumi/Notizen")
      try sameValue(try readText(notes.appendingPathComponent("Idee.md")).hasSuffix("erste\n"), true)
      try sameValue(try readText(notes.appendingPathComponent("Idee (2).md")).hasSuffix("zweite\n"), true)
      let mdFiles = try FileManager.default.contentsOfDirectory(atPath: notes.path).filter { $0.hasSuffix(".md") }
      try sameValue(mdFiles.count, 3, "Groß/Klein zählt als gleicher Name: \(mdFiles)")
    },
    CheckCase("Export: zweiter Lauf entfernt gelöschte Notizen, fremde Dateien bleiben") {
      let dir = exportDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      let weg = try store.notes.add(title: "Wird gelöscht", content: "x")
      _ = try store.notes.add(title: "Bleibt", content: "y")
      let notes = dir.appendingPathComponent("Lumi/Notizen")
      // Fremde Dateien vor dem ersten Lauf: eine im Notizordner, eine daneben.
      try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
      try "meine Notiz".write(to: notes.appendingPathComponent("Eigene.txt"), atomically: true, encoding: .utf8)
      try "fremd".write(to: dir.appendingPathComponent("fremd.md"), atomically: true, encoding: .utf8)

      _ = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      try sameValue(exists(notes.appendingPathComponent("Wird gelöscht.md")), true)

      _ = try store.notes.delete(weg.id)
      clock.advance(seconds: 60)
      let result = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      try sameValue(result.files, 3)
      try sameValue(exists(notes.appendingPathComponent("Wird gelöscht.md")), false, "gelöschte Notiz entfernt")
      try sameValue(exists(notes.appendingPathComponent("Bleibt.md")), true)
      try sameValue(exists(notes.appendingPathComponent("Eigene.txt")), true, "fremde Datei bleibt")
      try sameValue(exists(dir.appendingPathComponent("fremd.md")), true, "fremde Datei außerhalb bleibt")
      try sameValue(exists(dir.appendingPathComponent("Lumi/.vorher/Wird gelöscht.md")), true,
                    "vor dem Entfernen gesichert")
    },
    CheckCase("Export: fremde Datei mit gleichem Namen wird nie überschrieben") {
      let dir = exportDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      let notes = dir.appendingPathComponent("Lumi/Notizen")
      try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
      try "original".write(to: notes.appendingPathComponent("Liste.md"), atomically: true, encoding: .utf8)
      _ = try store.notes.add(title: "Liste", content: "von Lumi")
      _ = try MarkdownExporter.export(store: store, folder: dir.path, clock: clock)
      try sameValue(try readText(notes.appendingPathComponent("Liste.md")), "original")
      try sameValue(try readText(notes.appendingPathComponent("Liste (2).md")).hasSuffix("von Lumi\n"), true)
    },
    CheckCase("Export: leerer Ordner wird abgelehnt") {
      let clock = ControllableClock("2024-03-04T08:00")
      let store = try Store.inMemory(clock: clock)
      try await expectThrows("leerer Ordner muss fehlschlagen") {
        _ = try MarkdownExporter.export(store: store, folder: "  ", clock: clock)
      }
    },
  ])
}
