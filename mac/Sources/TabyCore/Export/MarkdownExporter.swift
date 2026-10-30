// Markdown-Export (Paket 2): Notizen, Aufgaben und Habits als Dateien in
// `<Ordner>/Lumi/`. Beim erneuten Export entfernt Lumi nur die Notiz-Dateien,
// die es selbst zuvor geschrieben hat (Liste im Markerfile `.taby-export`).
// Fremde Dateien im selben Ordner bleiben unangetastet; fremde Dateien mit
// gleichem Namen werden nie überschrieben (der Name bekommt " (2)" usw.).
import Foundation

public enum ExportError: Error, LocalizedError, Equatable {
  case noFolder

  public var errorDescription: String? {
    switch self {
    case .noFolder: return "Kein Exportordner gewählt."
    }
  }
}

public enum MarkdownExporter {
  static let folderName = "Lumi"
  static let notesFolderName = "Notizen"
  static let markerName = ".taby-export"
  /// Kopien der beim letzten Export entfernten Notiz-Dateien.
  static let backupFolderName = ".vorher"
  static let maxStemLength = 80
  static let untitled = "Ohne Titel"

  /// Entfernt Kopien aus `Lumi/.vorher`, die älter als einen Tag sind.
  public static func removeOldBackups(folder: String, now: Date) {
    let expanded = (folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    let vorher = URL(fileURLWithPath: expanded, isDirectory: true)
      .appendingPathComponent(folderName, isDirectory: true)
      .appendingPathComponent(backupFolderName, isDirectory: true)
    Leftovers.removeOlder(in: vorher, now: now)
  }

  /// Schreibt den Stand der Datenbank nach `folder`/Lumi/. `folder` darf mit `~` beginnen.
  /// `ExportResult.folder` ist der Pfad von `Lumi/`, `files` die Zahl der geschriebenen Dateien.
  public static func export(store: Store, folder: String, clock: Clock) throws -> ExportResult {
    let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ExportError.noFolder }
    let expanded = (trimmed as NSString).expandingTildeInPath
    let fm = FileManager.default
    let root = URL(fileURLWithPath: expanded, isDirectory: true)
      .appendingPathComponent(folderName, isDirectory: true)
    let notesDir = root.appendingPathComponent(notesFolderName, isDirectory: true)
    try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)

    // 1. Zuvor von Lumi geschriebene Notiz-Dateien entfernen (nur diese). Vorher eine Kopie
    //    nach `Lumi/.vorher/` legen, damit ein versehentlicher Export nichts endgültig kostet.
    let markerURL = root.appendingPathComponent(markerName)
    let vorher = root.appendingPathComponent(backupFolderName, isDirectory: true)
    var backedUp = false
    for name in previouslyWritten(at: markerURL) where isPlainMarkdownName(name) {
      let url = notesDir.appendingPathComponent(name)
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
        try fm.createDirectory(at: vorher, withIntermediateDirectories: true)
        let copy = vorher.appendingPathComponent(name)
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: url, to: copy)
        // Das Datum zählt ab dem Verschieben, nicht ab der Notiz-Änderung.
        try? fm.setAttributes([.modificationDate: clock.now()], ofItemAtPath: copy.path)
        try fm.removeItem(at: url)
        backedUp = true
      }
    }

    // 2. Notizen, älteste zuerst, damit Dubletten in Anlage-Reihenfolge nummeriert werden.
    var written: [String] = []
    var used = Set<String>()
    let notes = try store.notes.list().enumerated()
      .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
      .map(\.element)
    for note in notes {
      let name = uniqueFileName(for: note.title, in: notesDir, used: &used)
      let body = frontMatter(created: note.createdAt, updated: note.updatedAt)
        + (note.content.hasSuffix("\n") || note.content.isEmpty ? note.content : note.content + "\n")
      try body.write(to: notesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
      written.append(name)
    }
    let marker = written.map { $0 + "\n" }.joined()
    try marker.write(to: markerURL, atomically: true, encoding: .utf8)

    // 3. Aufgaben und Habits (werden jedes Mal überschrieben).
    let stamp = LocalTime.format(clock.now())
    let tasks = try store.tasks.list()
    let aufgaben = "# Aufgaben\n\nStand: \(stamp)\n\n"
      + "## Offen\n\n" + taskLines(tasks.filter { !$0.done }, done: false)
      + "\n## Erledigt\n\n" + taskLines(tasks.filter(\.done), done: true)
    try aufgaben.write(to: root.appendingPathComponent("Aufgaben.md"), atomically: true, encoding: .utf8)

    let habits = try store.habits.list()
    var habitText = "# Habits\n\nStand: \(stamp)\n\n"
    if habits.isEmpty {
      habitText += "_Keine Habits._\n"
    }
    for h in habits {
      let days = h.streak == 1 ? "Tag" : "Tage"
      let today = h.checkedToday ? ", heute erledigt" : ""
      habitText += "- \(oneLine(h.name)) – Serie: \(h.streak) \(days)\(today)\n"
    }
    try habitText.write(to: root.appendingPathComponent("Habits.md"), atomically: true, encoding: .utf8)

    return ExportResult(folder: root.path, files: written.count + 2,
                        backupFolder: backedUp ? vorher.path : nil)
  }

  // MARK: - Inhalte

  static func frontMatter(created: String, updated: String) -> String {
    "---\nerstellt: \(created)\ngeändert: \(updated)\n---\n\n"
  }

  static func taskLines(_ tasks: [TabyTask], done: Bool) -> String {
    guard !tasks.isEmpty else { return "_Keine._\n" }
    return tasks.map { t in
      let box = done ? "- [x] " : "- [ ] "
      let due = t.due.map { " (fällig: \($0.replacingOccurrences(of: "T", with: " ")))" } ?? ""
      return box + oneLine(t.title) + due + "\n"
    }.joined()
  }

  /// Einzeilig: Zeilenumbrüche und Steuerzeichen werden zu Leerzeichen.
  static func oneLine(_ s: String) -> String {
    var out = ""
    for c in s {
      out.append(c.unicodeScalars.contains { $0.value < 32 } ? " " : c)
    }
    return out.trimmingCharacters(in: .whitespaces)
  }

  // MARK: - Dateinamen

  /// Dateinamen-Stamm: verbotene Zeichen zu "-", führende Punkte weg, max. 80 Zeichen.
  static func sanitize(_ title: String) -> String {
    let forbidden: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
    var s = ""
    for c in oneLine(title) {
      s.append(forbidden.contains(c) ? "-" : c)
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasPrefix(".") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? untitled : s
  }

  /// Eindeutiger Dateiname "Titel.md", "Titel (2).md", … Vorhandene Dateien
  /// im Ordner und schon vergebene Namen (ohne Groß/Klein) zählen als belegt.
  static func uniqueFileName(for title: String, in dir: URL, used: inout Set<String>) -> String {
    let base = sanitize(title)
    var n = 1
    while true {
      let suffix = n == 1 ? "" : " (\(n))"
      let stem = String(base.prefix(maxStemLength - suffix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let name = stem + suffix + ".md"
      let taken = used.contains(name.lowercased())
        || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
      if !taken {
        used.insert(name.lowercased())
        return name
      }
      n += 1
    }
  }

  static func isPlainMarkdownName(_ name: String) -> Bool {
    name.hasSuffix(".md") && name.count > 3 && !name.hasPrefix(".")
      && !name.contains("/") && !name.contains("\\")
  }

  static func previouslyWritten(at url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
