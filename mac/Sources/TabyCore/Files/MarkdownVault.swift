// Markdown-Ordner („Wissen“): Index für die Suche (Dateiname, erste Überschrift, Inhalt).
// Der Index entsteht beim ersten Suchen und wird bei jeder Suche per Änderungszeit geprüft;
// nur geänderte Dateien werden neu gelesen. Höchstens `maxFiles` Einträge werden angefasst,
// keine Symlinks, keine versteckten Ordner, keine Dateiwächter-Threads.
import Foundation

public final class MarkdownVault: @unchecked Sendable {
  /// Höchstens so viele Einträge pro Durchlauf (Schutz vor sehr großen Ordnern).
  public static let maxFiles = 5000
  public static let maxHits = 20
  /// Je Datei höchstens so viele Bytes für Index und Lesen.
  public static let maxFileBytes = 256 * 1024
  /// Insgesamt höchstens so viel Text im Speicher; darüber sind nur Name und Überschrift durchsuchbar.
  static let maxIndexedBytes = 16 * 1024 * 1024

  /// Eine gelesene Notiz: Pfad relativ zur Wurzel, Text (gekürzt, wenn `truncated`).
  public struct Note: Equatable, Sendable {
    public let path: String
    public let text: String
    public let truncated: Bool
  }

  private struct Entry {
    var mtime: Date
    var size: Int
    var title: String
    var body: String?
  }

  private let lock = NSLock()
  private var root = ""
  private var entries: [String: Entry] = [:]
  private var indexedBytes = 0
  private var lastScan: Date?

  public init() {}

  // MARK: Suche

  /// Kennzeichen der Vault-Treffer in `SearchHit.id` (danach der absolute Pfad der Datei).
  public static let hitPrefix = "vault:"

  /// Treffer (höchstens `maxHits`) als Suchtreffer; `id` trägt den absoluten Pfad für „Öffnen“.
  public func search(root rootPath: String, query: String) -> [SearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPath.isEmpty, !q.isEmpty else { return [] }
    lock.lock(); defer { lock.unlock() }
    let normalized = Self.normalizedRoot(rootPath)
    refresh(normalized)
    var hits: [SearchHit] = []
    for key in entries.keys.sorted() {
      guard let e = entries[key] else { continue }
      let inName = e.title.range(of: q, options: Self.opts) != nil || key.range(of: q, options: Self.opts) != nil
      let snippet = e.body.flatMap { Self.snippetAround($0, q) }
      guard inName || snippet != nil else { continue }
      hits.append(SearchHit(id: Self.hitPrefix + normalized + "/" + key, kind: .note,
                            title: e.title, snippet: snippet))
      if hits.count >= Self.maxHits { break }
    }
    return hits
  }

  /// Ausschnitt von etwa 80 Zeichen um den ersten Treffer; nil ohne Treffer.
  static func snippetAround(_ text: String, _ query: String) -> String? {
    guard let r = text.range(of: query, options: opts) else { return nil }
    let lower = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
    let upper = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
    var s = String(text[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
    if lower > text.startIndex { s = "…" + s }
    if upper < text.endIndex { s += "…" }
    return s
  }

  // MARK: Lesen

  /// Liest eine Notiz. nil, wenn der Pfad ungültig ist, ausserhalb der Wurzel liegt oder keine .md-Datei ist.
  public static func readNote(root: String, path: String) -> Note? {
    guard let url = resolve(root: root, path: path),
          let text = readText(url) else { return nil }
    let rootPath = normalizedRoot(root)
    let rel = String(url.path.dropFirst(rootPath.count + 1))
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return Note(path: rel, text: text, truncated: size > maxFileBytes)
  }

  /// Prüft einen Pfad (relativ zur Wurzel oder absolut innerhalb davon): kein „..“, keine Ausbrüche
  /// über Symlinks, nur reguläre .md-Dateien. Liefert die aufgelöste URL oder nil.
  public static func resolve(root: String, path: String) -> URL? {
    let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty, !raw.isEmpty, !raw.contains("\0"), !raw.contains("\\") else { return nil }
    guard !raw.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
    let rootURL = URL(fileURLWithPath: normalizedRoot(root), isDirectory: true).resolvingSymlinksInPath()
    let candidate = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : rootURL.appendingPathComponent(raw)
    let real = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard real.pathExtension.lowercased() == "md", real.path.hasPrefix(rootURL.path + "/") else { return nil }
    guard let isFile = try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { return nil }
    return real
  }

  // MARK: Schreiben

  /// Fehler beim Schreiben; `message` ist für den Nutzer (Deutsch).
  public enum WriteError: Error, Equatable {
    case invalidFolder, notRegularFile, failed, rootMissing, tooLarge

    public var message: String {
      switch self {
      case .invalidFolder: return "Der Ordner liegt nicht im Obsidian-Vault."
      case .rootMissing: return "Obsidian-Ordner nicht gefunden – ist das Laufwerk verbunden?"
      case .tooLarge: return "Die Notiz ist zu groß zum Anhängen (mehr als 5 MB)."
      case .notRegularFile: return "Die Zieldatei ist keine normale Markdown-Datei."
      case .failed: return "Notiz konnte nicht geschrieben werden."
      }
    }
  }

  /// Schreibt in `<root>/<folder>/`. `append` hängt an `<title>.md` an, wenn die Datei existiert;
  /// sonst entsteht eine neue Datei (bei Namensgleichheit `-2`, `-3` …). Nie außerhalb der Wurzel.
  public static func write(root: String, title: String, content: String, append: Bool,
                           folder: String, now: Date) throws -> FileHit {
    let rootURL = URL(fileURLWithPath: normalizedRoot(root), isDirectory: true).resolvingSymlinksInPath()
    // Kein Ordner (z. B. Laufwerk nicht verbunden): nicht still einen Pfad anlegen.
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
      throw WriteError.rootMissing
    }
    let dir = try folderURL(rootURL, folder)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = LocalTime.format(now)
    let body = defuse(content)
    let base = safeFileName(title)
    let plain = dir.appendingPathComponent(base + ".md")
    if append, try exists(plain) {
      let size = (try? FileManager.default.attributesOfItem(atPath: plain.path))?[.size] as? Int ?? 0
      guard size <= maxAppendBytes else { throw WriteError.tooLarge }
      var data = try Data(contentsOf: plain)
      data.append(Data("\n\n## \(stamp)\n\(body)".utf8))
      try data.write(to: plain, options: .atomic)
      return try checked(plain, rootURL, stamp)
    }
    var file = plain
    var n = 2
    while try exists(file) {
      file = dir.appendingPathComponent("\(base)-\(n).md")
      n += 1
    }
    try Data("---\ncreated: \(stamp)\nsource: Lumi\n---\n\(body)".utf8).write(to: file, options: .atomic)
    return try checked(file, rootURL, stamp)
  }

  static let maxAppendBytes = 5 * 1024 * 1024

  /// Nach dem Schreiben: liegt die echte Datei (Symlinks aufgelöst) noch unter der Wurzel? Sonst wegwerfen.
  private static func checked(_ file: URL, _ rootURL: URL, _ stamp: String) throws -> FileHit {
    guard file.resolvingSymlinksInPath().path.hasPrefix(rootURL.path + "/") else {
      try? FileManager.default.removeItem(at: file)
      throw WriteError.invalidFolder
    }
    return hit(file, stamp)
  }

  /// Entschärft Skriptblöcke im Modell-Text (Dataview und Templater liefen beim Öffnen).
  /// shortcut: nur drei Muster, kein Markdown-Parser; neue Skript-Syntax hier ergänzen, sobald nötig.
  static func defuse(_ text: String) -> String {
    text.replacingOccurrences(of: "```dataviewjs", with: "```text")
      .replacingOccurrences(of: "```dataview", with: "```text")
      .replacingOccurrences(of: "<%", with: "< %")
  }

  /// Ordner wie ein Dateiname: jeder Teil nur mit erlaubten Zeichen, nie „.“ oder ein Punkt am Anfang.
  static func isSafeFolder(_ folder: String) -> Bool {
    let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !f.isEmpty, !f.hasPrefix("/") else { return false }
    return f.split(separator: "/").allSatisfy { part in
      let s = String(part)
      return s != "." && !s.hasPrefix(".") && safeFileName(s) == s
    }
  }

  /// Dateiname aus dem Titel: nur Buchstaben, Ziffern, Leerzeichen, `-` und `_`; höchstens 80 Zeichen.
  static func safeFileName(_ title: String) -> String {
    let kept = title.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
    let words = kept.split(separator: " ").joined(separator: " ")
    let trimmed = String(words.prefix(80)).trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Notiz" : trimmed
  }

  /// Ordner unterhalb der Wurzel; ohne Ausbruch über `..`, absolute Pfade oder Symlinks.
  private static func folderURL(_ rootURL: URL, _ folder: String) throws -> URL {
    let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSafeFolder(f), !f.contains("\0"), !f.contains("\\"),
          !f.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
      throw WriteError.invalidFolder
    }
    // Jeder Teil einzeln prüfen: ein Symlink (auch auf einen noch fehlenden Unterordner) ist ein Ausbruch.
    var dir = rootURL
    for part in f.split(separator: "/") {
      dir = dir.appendingPathComponent(String(part), isDirectory: true)
      if (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
        throw WriteError.invalidFolder
      }
    }
    return dir
  }

  /// Ob die Datei existiert; ein Symlink oder Nicht-Datei ist ein Fehler (wird nie überschrieben).
  private static func exists(_ url: URL) throws -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
    guard attrs[.type] as? FileAttributeType == .typeRegular else { throw WriteError.notRegularFile }
    return true
  }

  private static func hit(_ url: URL, _ stamp: String) -> FileHit {
    FileHit(path: url.path, name: url.lastPathComponent, modifiedAt: stamp, kind: "Obsidian-Notiz")
  }

  // MARK: Anzahl

  /// Anzahl der indexierten Notizen. Der Ordner wird höchstens alle 60 s neu abgeglichen (oder mit `force`).
  public func noteCount(root rootPath: String, now: Date, force: Bool = false) -> Int {
    guard !rootPath.isEmpty else { return 0 }
    lock.lock(); defer { lock.unlock() }
    let normalized = Self.normalizedRoot(rootPath)
    let stale = lastScan.map { abs(now.timeIntervalSince($0)) >= 60 } ?? true
    if force || stale || normalized != root {
      refresh(normalized)
      lastScan = now
    }
    return entries.count
  }

  // MARK: Zählung für den Zustand

  /// Eigenes Schloss, damit der Zustand nie auf einen laufenden Ordnerlauf wartet (der hält `lock`).
  private let stateLock = NSLock()
  private var stateCount = 0
  private var stateScanning = false
  private var stateScannedAt: Date?

  /// Für den Zustand: nur der letzte Stand, nie ein Ordnerlauf am Aufrufer. Ist er älter als 60 s,
  /// läuft ein Lauf im Hintergrund (höchstens einer gleichzeitig).
  public func noteCountForState(root rootPath: String, now: Date) -> Int {
    stateLock.lock()
    let count = stateCount
    let stale = stateScannedAt.map { abs(now.timeIntervalSince($0)) >= 60 } ?? true
    let start = stale && !stateScanning
    if start { stateScanning = true }
    stateLock.unlock()
    if start {
      DispatchQueue.global(qos: .utility).async { [self] in _ = rescan(root: rootPath, now: now) }
    }
    return count
  }

  /// Ordner neu lesen und den Stand für den Zustand merken (nicht auf dem Hauptthread aufrufen).
  @discardableResult
  public func rescan(root rootPath: String, now: Date) -> Int {
    let n = noteCount(root: rootPath, now: now, force: true)
    stateLock.lock()
    stateCount = n
    stateScannedAt = now
    stateScanning = false
    stateLock.unlock()
    return n
  }

  // MARK: Index

  private static let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  static func normalizedRoot(_ path: String) -> String {
    var p = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p
  }

  /// Gleicht den Index mit dem Ordner ab: neue und geänderte Dateien lesen, verschwundene entfernen.
  private func refresh(_ rootPath: String) {
    if rootPath != root {
      root = rootPath
      entries = [:]
      indexedBytes = 0
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
    guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath, isDirectory: true),
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
      entries = [:]; indexedBytes = 0
      return
    }
    var seen = Set<String>()
    var visited = 0
    for case let url as URL in en {
      visited += 1
      if visited > Self.maxFiles { break }
      guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      if v.isSymbolicLink == true { en.skipDescendants(); continue }
      guard v.isRegularFile == true, url.pathExtension.lowercased() == "md" else { continue }
      let key = String(url.path.dropFirst(rootPath.count + 1))
      seen.insert(key)
      let mtime = v.contentModificationDate ?? .distantPast
      let size = v.fileSize ?? 0
      if let old = entries[key], old.mtime == mtime, old.size == size { continue }
      if let old = entries[key] { indexedBytes -= old.body?.utf8.count ?? 0 }
      entries[key] = load(url, key: key, mtime: mtime, size: size)
    }
    for key in entries.keys where !seen.contains(key) {
      indexedBytes -= entries[key]?.body?.utf8.count ?? 0
      entries[key] = nil
    }
  }

  /// Liest Titel und Text einer Datei; der Text geht nur in den Index, solange das Gesamtbudget reicht.
  private func load(_ url: URL, key: String, mtime: Date, size: Int) -> Entry {
    let fallback = (key as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "", options: .caseInsensitive)
    guard let text = Self.readText(url) else { return Entry(mtime: mtime, size: size, title: fallback, body: nil) }
    let heading = text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: false)
      .first { $0.hasPrefix("# ") }
      .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
    let title = heading.flatMap { $0.isEmpty ? nil : String($0) } ?? fallback
    let fits = indexedBytes + text.utf8.count <= Self.maxIndexedBytes
    return Entry(mtime: mtime, size: size, title: title, body: fits ? text : nil)
  }

  /// Höchstens `maxFileBytes` einer Datei als Text (ungültiges UTF-8 wird ersetzt).
  private static func readText(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxFileBytes) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
