// Mod-Bibliothek (Paket 3): Ordner `<root>/<id>/` mit mod.json und ggf. Skript.
// Zustand (eingeschaltet, freigegebene Fassung, letzter Lauf) liegt in `<root>/state.json`.
import Foundation
import CryptoKit

public enum ModError: Error, LocalizedError, Equatable {
  case invalid([String])
  case notFound(String)
  case missingCode
  case unreadable(String)
  case archive(String)
  case process(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let problems): return "Der Mod ist ungültig: " + problems.joined(separator: " ")
    case .notFound(let id): return "Der Mod „\(id)“ wurde nicht gefunden."
    case .missingCode: return "Ein Skript-Mod braucht den Programmcode."
    case .unreadable(let text): return text
    case .archive(let text): return text
    case .process(let text): return text
    }
  }
}

public final class ModLibrary {
  public let root: URL

  static let manifestFile = "mod.json"
  static let stateFile = "state.json"
  static let defaultEntry = "main.js"
  static let maxImportFiles = 20
  static let maxImportFileBytes = 1_048_576

  /// Letzte Liste samt Dateisignatur; `all()` liest Dateien nur neu, wenn sich der Mod-Ordner geändert hat.
  private var listCache: (signature: String, mods: [ModInfo])?
  private let cacheLock = NSLock()

  public init(root: URL) {
    self.root = root
  }

  // MARK: Öffentliche Schnittstelle

  public func all() throws -> [ModInfo] {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let signature = fileSignature()
    cacheLock.lock()
    let cached = listCache.flatMap { $0.signature == signature ? $0.mods : nil }
    cacheLock.unlock()
    if let cached { return cached }
    let state = try readState()
    var result: [ModInfo] = []
    for dir in try modDirectories() {
      let id = dir.lastPathComponent
      do {
        let loaded = try loadMod(id)
        result.append(info(loaded, state: state))
      } catch {
        logToStderr("Mod „\(id)“ übersprungen (\(TabyLog.code(error)))")
      }
    }
    let sorted = result.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    cacheLock.lock(); listCache = (signature, sorted); cacheLock.unlock()
    return sorted
  }

  /// Verwirft die Liste (nach Schreibvorgängen in diesem Prozess).
  func invalidateCache() {
    cacheLock.lock(); listCache = nil; cacheLock.unlock()
  }

  /// Änderungszeit und Größe des Root-Ordners, von state.json und aller Dateien je Mod-Ordner.
  /// Nur Metadaten (stat und Verzeichnislisten), keine Dateiinhalte.
  private func fileSignature() -> String {
    let fm = FileManager.default
    func stamp(_ url: URL) -> String {
      let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
      let t = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      return "\(t):\((a[.size] as? NSNumber)?.intValue ?? -1)"
    }
    var parts = [stamp(root), stamp(root.appendingPathComponent(Self.stateFile))]
    for dir in (try? modDirectories()) ?? [] {
      parts.append(dir.lastPathComponent + "|" + stamp(dir))
      for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
        parts.append(f.lastPathComponent + "|" + stamp(f))
      }
    }
    return parts.joined(separator: "\n")
  }

  public func manifest(_ id: String) throws -> ModManifest? {
    guard exists(id) else { return nil }
    return try loadMod(id).manifest
  }

  public func code(_ id: String) throws -> String? {
    guard exists(id) else { return nil }
    return try loadMod(id).code
  }

  /// Schreibt den Mod-Ordner neu. Neue oder geänderte Mods sind danach nicht freigegeben und ausgeschaltet.
  /// Ist der Inhalt unverändert, bleiben Schalter und Freigabe erhalten.
  @discardableResult
  public func install(_ m: ModManifest, code: String?) throws -> ModInfo {
    invalidateCache()
    let problems = ModValidation.validate(m)
    if !problems.isEmpty { throw ModError.invalid(problems) }

    var script = Data()
    if m.kind == .script {
      guard let code else { throw ModError.missingCode }
      script = Data(code.utf8)
    }
    let manifestData = try Self.encoder().encode(m)
    let newHash = Self.hash(manifestBytes: manifestData, script: script)

    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = try dirURL(m.id)
    // Vor dem Ersetzen lesen: sonst gleicht der alte Hash immer dem neuen und die Freigabe bliebe stehen.
    let oldHash = (try? loadMod(m.id))?.hash

    // Erst in einen versteckten Ordner schreiben, dann ersetzen: keine Mischzustände.
    let stage = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    do {
      try manifestData.write(to: stage.appendingPathComponent(Self.manifestFile))
      if m.kind == .script {
        try script.write(to: stage.appendingPathComponent(m.entry ?? Self.defaultEntry))
      }
      if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
      try fm.moveItem(at: stage, to: dir)
    } catch {
      try? fm.removeItem(at: stage)
      throw error
    }

    var state = try readState()
    if oldHash != newHash {
      // Neue Fassung: Freigabe weg, Einstellungen des Nutzers bleiben erhalten.
      state.mods[m.id] = ModState(settingValues: state.mods[m.id]?.settingValues)
    }
    try writeState(state)
    return info(try loadMod(m.id), state: state)
  }

  /// Einschalten gibt die aktuelle Fassung frei. Ausschalten nimmt die Freigabe zurück.
  public func setEnabled(_ id: String, _ enabled: Bool, now: String) throws -> ModInfo {
    let loaded = try loadMod(id)
    var state = try readState()
    var s = state.mods[id] ?? ModState()
    s.enabled = enabled
    if enabled {
      s.approvedHash = loaded.hash
      s.approvedAt = now
    } else {
      s.approvedHash = nil
      s.approvedAt = nil
    }
    state.mods[id] = s
    try writeState(state)
    return info(loaded, state: state)
  }

  /// Läuft nur, wenn eingeschaltet und die aktuelle Fassung freigegeben ist.
  public func isRunnable(_ id: String) throws -> Bool {
    let loaded = try loadMod(id)
    guard let s = try readState().mods[id], s.enabled, let approved = s.approvedHash else { return false }
    return approved == loaded.hash
  }

  public func recordRun(_ id: String, at: String, error: String?) throws {
    _ = try requireDir(id)
    var state = try readState()
    var s = state.mods[id] ?? ModState()
    s.lastRunAt = at
    s.lastError = error
    state.mods[id] = s
    try writeState(state)
  }

  public func delete(_ id: String) throws {
    invalidateCache()
    let dir = try requireDir(id)
    try FileManager.default.removeItem(at: dir)
    var state = try readState()
    state.mods.removeValue(forKey: id)
    try writeState(state)
    try removeStorage(id)
  }

  /// Packt den Mod als `<folder>/<id>.tabymod` (ZIP mit einem Ordner `<id>` darin).
  public func export(_ id: String, to folder: URL) throws -> URL {
    let dir = try requireDir(id)
    _ = try loadMod(id)
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let dest = folder.appendingPathComponent("\(id).tabymod")
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    let r = try ModProcess.run("/usr/bin/ditto",
                               ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noacl", dir.path, dest.path],
                               timeout: 120)
    guard !r.timedOut, r.status == 0 else {
      throw ModError.archive("Der Mod konnte nicht gepackt werden. \(r.stderr.trimmedText)")
    }
    return dest
  }

  /// Entpackt, prüft und installiert ein Paket. Der Mod kommt ausgeschaltet an.
  public func importMod(from file: URL) throws -> ModInfo {
    invalidateCache()
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("taby-mod-import-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    // 1. Namen im Archiv prüfen, bevor etwas entpackt wird.
    let listing = try ModProcess.run("/usr/bin/unzip", ["-Z1", file.path], timeout: 30)
    guard !listing.timedOut, listing.status == 0 else {
      throw ModError.archive("Die Datei ist kein gültiges Mod-Paket.")
    }
    let names = listing.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    guard !names.isEmpty else { throw ModError.archive("Das Paket ist leer.") }
    for name in names {
      if name.hasPrefix("/") || name.contains("\\") || name.contains("\0") {
        throw ModError.archive("Das Paket enthält einen unzulässigen Pfad und wird abgelehnt.")
      }
      let parts = name.split(separator: "/", omittingEmptySubsequences: true)
      if parts.contains("..") || parts.contains(".") {
        throw ModError.archive("Das Paket enthält einen unzulässigen Pfad („..“) und wird abgelehnt.")
      }
    }
    let fileNames = names.filter { !$0.hasSuffix("/") }
    if fileNames.count > Self.maxImportFiles {
      throw ModError.archive("Das Paket enthält mehr als \(Self.maxImportFiles) Dateien.")
    }

    // 2. Entpacken in einen Arbeitsordner, dann Einträge prüfen (Symlinks, Größe).
    let stage = work.appendingPathComponent("unpacked", isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    let extract = try ModProcess.run("/usr/bin/ditto", ["-x", "-k", file.path, stage.path], timeout: 60)
    guard !extract.timedOut, extract.status == 0 else {
      throw ModError.archive("Das Paket konnte nicht entpackt werden.")
    }
    let files = try collectFiles(stage)
    if files.count > Self.maxImportFiles {
      throw ModError.archive("Das Paket enthält mehr als \(Self.maxImportFiles) Dateien.")
    }
    for (_, size) in files where size > Self.maxImportFileBytes {
      throw ModError.archive("Eine Datei im Paket ist größer als 1 MB und wird abgelehnt.")
    }

    // 3. Mod-Ordner finden: direkt im Paket oder als einziger Ordner darin.
    let modDir: URL
    if fm.fileExists(atPath: stage.appendingPathComponent(Self.manifestFile).path) {
      modDir = stage
    } else {
      let subdirs = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
        .filter { fm.fileExists(atPath: $0.appendingPathComponent(Self.manifestFile).path) }
      guard subdirs.count == 1, let only = subdirs.first else {
        throw ModError.archive("Im Paket fehlt die Datei mod.json.")
      }
      modDir = only
    }

    // 4. Manifest und Skript prüfen.
    guard let mBytes = try? Data(contentsOf: modDir.appendingPathComponent(Self.manifestFile)),
          let manifest = try? JSONDecoder().decode(ModManifest.self, from: mBytes) else {
      throw ModError.invalid(["mod.json ist kein gültiges Manifest."])
    }
    let problems = ModValidation.validate(manifest)
    if !problems.isEmpty { throw ModError.invalid(problems) }

    var code: String? = nil
    if manifest.kind == .script {
      let entry = manifest.entry ?? Self.defaultEntry
      guard let data = try? Data(contentsOf: modDir.appendingPathComponent(entry)),
            let text = String(data: data, encoding: .utf8) else {
        throw ModError.invalid(["Die Skriptdatei „\(entry)“ fehlt oder ist kein UTF-8-Text."])
      }
      code = text
    }

    // 5. Installieren und ausschalten.
    let installed = try install(manifest, code: code)
    var state = try readState()
    state.mods[installed.id] = ModState()
    try writeState(state)
    return info(try loadMod(installed.id), state: state)
  }

  /// Gespeicherte Einstellungswerte eines Mods (leer, wenn keine gesetzt sind).
  public func settingValues(_ id: String) -> [String: String] {
    (try? readState())?.mods[id]?.settingValues ?? [:]
  }

  /// Speichert einen Einstellungswert (Prüfung der Art passiert vorher; die Freigabe bleibt unberührt).
  public func setSettingValue(_ id: String, key: String, value: String) throws -> ModInfo {
    invalidateCache()
    let loaded = try loadMod(id)
    var state = try readState()
    var s = state.mods[id] ?? ModState()
    var values = s.settingValues ?? [:]
    values[key] = value
    s.settingValues = values
    state.mods[id] = s
    try writeState(state)
    return info(loaded, state: state)
  }

  // MARK: Intern

  struct ModState: Codable, Equatable {
    var enabled: Bool = false
    var approvedHash: String?
    var approvedAt: String?
    var lastRunAt: String?
    var lastError: String?
    /// Vom Nutzer gesetzte Einstellungen (optional, damit alte state.json weiter lesbar bleibt).
    var settingValues: [String: String]?
  }

  struct StateFile: Codable {
    var mods: [String: ModState] = [:]
  }

  struct LoadedMod {
    let manifest: ModManifest
    let code: String?
    let hash: String
    var id: String { manifest.id }
  }

  static func encoder() -> JSONEncoder {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return enc
  }

  /// SHA-256 über mod.json-Bytes und Skript-Bytes.
  static func hash(manifestBytes: Data, script: Data) -> String {
    var h = SHA256()
    h.update(data: manifestBytes)
    h.update(data: script)
    return h.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func info(_ loaded: LoadedMod, state: StateFile) -> ModInfo {
    let s = state.mods[loaded.id] ?? ModState()
    let approved = s.approvedHash != nil && s.approvedHash == loaded.hash
    return ModInfo(manifest: loaded.manifest, enabled: s.enabled, approved: approved, code: loaded.code,
                   lastRunAt: s.lastRunAt, lastError: s.lastError, settingValues: s.settingValues ?? [:])
  }

  private func dirURL(_ id: String) throws -> URL {
    guard ModValidation.isValidID(id) else { throw ModError.notFound(id) }
    return root.appendingPathComponent(id, isDirectory: true)
  }

  private func requireDir(_ id: String) throws -> URL {
    let dir = try dirURL(id)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
      throw ModError.notFound(id)
    }
    return dir
  }

  private func exists(_ id: String) -> Bool {
    (try? requireDir(id)) != nil
  }

  private func modDirectories() throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    return entries.filter { url in
      guard ModValidation.isValidID(url.lastPathComponent) else { return false }
      let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      return isDir
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func loadMod(_ id: String) throws -> LoadedMod {
    let dir = try requireDir(id)
    let mURL = dir.appendingPathComponent(Self.manifestFile)
    try rejectSymlink(mURL)
    guard let mBytes = try? Data(contentsOf: mURL) else {
      throw ModError.unreadable("mod.json von „\(id)“ fehlt oder ist nicht lesbar.")
    }
    guard let manifest = try? JSONDecoder().decode(ModManifest.self, from: mBytes) else {
      throw ModError.invalid(["mod.json ist kein gültiges Manifest."])
    }
    let problems = ModValidation.validate(manifest)
    if !problems.isEmpty { throw ModError.invalid(problems) }
    guard manifest.id == id else {
      throw ModError.invalid(["Die ID „\(manifest.id)“ passt nicht zum Ordnernamen „\(id)“."])
    }

    var script = Data()
    var code: String? = nil
    if manifest.kind == .script {
      let entry = manifest.entry ?? Self.defaultEntry
      let sURL = dir.appendingPathComponent(entry)
      try rejectSymlink(sURL)
      guard let data = try? Data(contentsOf: sURL) else {
        throw ModError.invalid(["Die Skriptdatei „\(entry)“ fehlt."])
      }
      script = data
      code = String(decoding: data, as: UTF8.self)
    }
    return LoadedMod(manifest: manifest, code: code,
                     hash: Self.hash(manifestBytes: mBytes, script: script))
  }

  private func rejectSymlink(_ url: URL) throws {
    let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    if type == .typeSymbolicLink {
      throw ModError.invalid(["„\(url.lastPathComponent)“ ist ein Symlink und wird nicht gelesen."])
    }
  }

  /// Alle Dateien unter `dir`; Symlinks oder Sonderdateien führen zu einer Ablehnung.
  private func collectFiles(_ dir: URL) throws -> [(URL, Int)] {
    let fm = FileManager.default
    var out: [(URL, Int)] = []
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: []) else { return [] }
    for case let url as URL in en {
      let attrs = try fm.attributesOfItem(atPath: url.path)
      let type = attrs[.type] as? FileAttributeType
      switch type {
      case .typeSymbolicLink:
        throw ModError.archive("Das Paket enthält einen Symlink und wird abgelehnt.")
      case .typeDirectory:
        continue
      case .typeRegular:
        out.append((url, (attrs[.size] as? NSNumber)?.intValue ?? 0))
      default:
        throw ModError.archive("Das Paket enthält eine unzulässige Datei und wird abgelehnt.")
      }
    }
    return out
  }

  private func readState() throws -> StateFile {
    let url = root.appendingPathComponent(Self.stateFile)
    guard let data = try? Data(contentsOf: url) else { return StateFile() }
    // Unlesbarer Zustand: nichts ist freigegeben (sicher).
    guard let state = try? JSONDecoder().decode(StateFile.self, from: data) else {
      logToStderr("state.json unlesbar, alle Mods sind ausgeschaltet.")
      return StateFile()
    }
    return state
  }

  private func writeState(_ state: StateFile) throws {
    invalidateCache()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try Self.encoder().encode(state)
    try data.write(to: root.appendingPathComponent(Self.stateFile), options: .atomic)
  }

  private func logToStderr(_ text: String) {
    TabyLog.error(.mods, text)
  }
}
