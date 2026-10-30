// Kleiner Speicher je Mod (`taby.storage`): eine Datei `<root>/storage.json` mit
// `{ modId: { key: JSON } }`. Geschrieben wird nur beim Setzen, höchstens 64 KB je Mod.
import Foundation

public enum ModStorageError: Error, LocalizedError, Equatable {
  case full, invalidKey, unreadable

  public var errorDescription: String? {
    switch self {
    case .full: return "Der Speicher des Mods ist voll (max. 64 KB). Bitte alte Werte löschen."
    case .invalidKey: return "Der Schlüssel fehlt oder ist zu lang (max. 100 Zeichen)."
    case .unreadable: return "Der Speicher des Mods ist unlesbar."
    }
  }
}

extension ModLibrary {
  static let storageFile = "storage.json"
  /// Obergrenze je Mod in Bytes (JSON-kodiert).
  public static let storageCapBytes = 65_536
  /// Lesen, Ändern und Schreiben der Datei laufen nacheinander, sonst überschreibt ein zweiter
  /// Schreibvorgang den ersten (zwei Mods oder zwei Läufe gleichzeitig).
  static let storageLock = NSLock()

  public func storageGet(_ id: String, key: String) throws -> JSONValue {
    try readStorage()[id]?[key] ?? .null
  }

  public func storageSet(_ id: String, key: String, value: JSONValue) throws {
    guard !key.isEmpty, key.count <= 100 else { throw ModStorageError.invalidKey }
    Self.storageLock.lock(); defer { Self.storageLock.unlock() }
    var all = try readStorage()
    var mine = all[id] ?? [:]
    mine[key] = value
    let size = try JSONEncoder().encode(mine).count
    guard size <= Self.storageCapBytes else { throw ModStorageError.full }
    all[id] = mine
    try writeStorage(all)
  }

  func removeStorage(_ id: String) throws {
    Self.storageLock.lock(); defer { Self.storageLock.unlock() }
    var all = try readStorage()
    guard all.removeValue(forKey: id) != nil else { return }
    try writeStorage(all)
  }

  private func readStorage() throws -> [String: [String: JSONValue]] {
    let url = root.appendingPathComponent(Self.storageFile)
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let all = try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data) else {
      throw ModStorageError.unreadable
    }
    return all
  }

  private func writeStorage(_ all: [String: [String: JSONValue]]) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(all)
    try data.write(to: root.appendingPathComponent(Self.storageFile), options: .atomic)
  }
}
