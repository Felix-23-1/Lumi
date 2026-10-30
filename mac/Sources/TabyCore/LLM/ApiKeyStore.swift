// Ablage des API-Keys. Ersetzt Electron `safeStorage` (src/main/llm/
// safe-storage.ts) durch den macOS-Schlüsselbund. Der Key liegt nie im
// Klartext in einer Datei, in Einstellungen, Logs oder Fehlermeldungen.
import Foundation
import Security

public struct ApiKeyStoreError: Error, Equatable, CustomStringConvertible {
  /// Deutsche Meldung, ohne den Schlüssel.
  public var message: String
  public var status: Int32
  public init(_ message: String, status: Int32 = 0) { self.message = message; self.status = status }
  public var description: String { message }
}

public protocol ApiKeyStore: AnyObject {
  /// nil, wenn kein Key gesetzt ist.
  func get() throws -> String?
  /// Leerer String löscht den Key.
  func set(_ key: String) throws
  func delete() throws
  func hasKey() -> Bool
}

/// Generisches Passwort im Anmelde-Schlüsselbund.
public final class KeychainApiKeyStore: ApiKeyStore, @unchecked Sendable {
  public static let defaultService = "de.felix.taby"
  public static let defaultAccount = "llm-api-key"

  public let service: String
  public let account: String

  /// Prüfungen (TabyChecks, Vorschau-Bilder) setzen das einmal beim Start: dann hält jede Instanz ihre
  /// Werte im Arbeitsspeicher und fasst NIE den echten Schlüsselbund an (jeder neue Prüf-Build würde
  /// sonst nach dem Passwort fragen und Hunderte Test-Einträge hinterlassen).
  nonisolated(unsafe) public static var memoryOnly = false
  private static let memoryLock = NSLock()
  nonisolated(unsafe) private static var memory: [String: String] = [:]
  private var memoryKey: String { "\(service)|\(account)" }

  public init(service: String = KeychainApiKeyStore.defaultService,
              account: String = KeychainApiKeyStore.defaultAccount) {
    self.service = service; self.account = account
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func get() throws -> String? {
    if Self.memoryOnly {
      Self.memoryLock.lock(); defer { Self.memoryLock.unlock() }
      return Self.memory[memoryKey]
    }
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return nil }
      let key = String(decoding: data, as: UTF8.self)
      return key.isEmpty ? nil : key
    case errSecItemNotFound:
      return nil
    default:
      throw ApiKeyStoreError("Der API-Schlüssel konnte nicht aus dem Schlüsselbund gelesen werden.", status: status)
    }
  }

  public func set(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { try delete(); return }
    if Self.memoryOnly {
      Self.memoryLock.lock(); Self.memory[memoryKey] = trimmed; Self.memoryLock.unlock()
      return
    }
    let data = Data(trimmed.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      add[kSecAttrLabel as String] = "Lumi – API-Schlüssel"
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw ApiKeyStoreError("Der API-Schlüssel konnte nicht im Schlüsselbund gespeichert werden.", status: status)
    }
  }

  public func delete() throws {
    if Self.memoryOnly {
      Self.memoryLock.lock(); Self.memory[memoryKey] = nil; Self.memoryLock.unlock()
      return
    }
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ApiKeyStoreError("Der API-Schlüssel konnte nicht aus dem Schlüsselbund entfernt werden.", status: status)
    }
  }

  public func hasKey() -> Bool {
    // Nur Existenz prüfen, ohne den Wert zu lesen.
    if Self.memoryOnly {
      Self.memoryLock.lock(); defer { Self.memoryLock.unlock() }
      return Self.memory[memoryKey] != nil
    }
    var query = baseQuery
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnAttributes as String] = true
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }
}

/// Für Prüfungen und den Testmodus: hält den Key nur im Speicher.
public final class InMemoryApiKeyStore: ApiKeyStore, @unchecked Sendable {
  private var key: String?
  private let lock = NSLock()

  public init(_ key: String? = nil) { self.key = key }

  public func get() throws -> String? {
    lock.lock(); defer { lock.unlock() }
    return key
  }

  public func set(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock(); self.key = trimmed.isEmpty ? nil : trimmed; lock.unlock()
  }

  public func delete() throws {
    lock.lock(); key = nil; lock.unlock()
  }

  public func hasKey() -> Bool {
    lock.lock(); defer { lock.unlock() }
    return key != nil
  }
}

/// Hält ein einmal gelesenes Geheimnis im Speicher. Jeder Daten-Lesezugriff auf den
/// Schlüsselbund kann bei einer neuen Code-Signatur (ad-hoc-Update) eine Freigabe-
/// Abfrage auslösen, die den aufrufenden Thread blockiert – deshalb höchstens einmal
/// je Geheimnis und Programmlauf. „Nicht vorhanden“ wird nicht gemerkt (billig, ohne
/// Abfrage), damit extern eingetragene Geheimnisse sofort wirken; eine abgelehnte
/// Abfrage dagegen schon, sonst fragt macOS bei jedem Neuladen erneut.
public final class CachedApiKeyStore: ApiKeyStore, @unchecked Sendable {
  private let inner: ApiKeyStore
  /// Schützt nur `value` und wird nie während eines Schlüsselbund-Zugriffs gehalten,
  /// damit `hasKey()` auf dem Hauptthread nie hinter einer Freigabe-Abfrage wartet.
  private let stateLock = NSLock()
  /// Serialisiert Lesen und Schreiben am Schlüsselbund (kann eine Abfrage auslösen).
  private let ioLock = NSLock()
  /// nil = noch nicht gelesen; .some(nil) = abgelehnt (bis set/delete).
  private var value: String??

  public init(_ inner: ApiKeyStore) { self.inner = inner }

  /// errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed.
  static let deniedStatuses: Set<Int32> = [-128, -25293, -25308]

  private func cached() -> String?? {
    stateLock.lock(); defer { stateLock.unlock() }
    return value
  }

  private func remember(_ v: String??) {
    stateLock.lock(); value = v; stateLock.unlock()
  }

  public func get() throws -> String? {
    if let hit = cached() { return hit }
    // Parallele Leser warten hier; der zweite findet den Wert, den der erste gelesen hat.
    ioLock.lock(); defer { ioLock.unlock() }
    if let hit = cached() { return hit }
    do {
      let read = try inner.get()
      if read != nil { remember(.some(read)) }
      return read
    } catch let e as ApiKeyStoreError where Self.deniedStatuses.contains(e.status) {
      remember(.some(nil))
      throw e
    }
  }

  public func set(_ key: String) throws {
    ioLock.lock(); defer { ioLock.unlock() }
    try inner.set(key)
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    remember(trimmed.isEmpty ? nil : .some(trimmed))  // setzt auch eine gemerkte Ablehnung zurück
  }

  public func delete() throws {
    ioLock.lock(); defer { ioLock.unlock() }
    try inner.delete()
    remember(nil)
  }

  public func hasKey() -> Bool {
    // Nur Existenz, kein Datenzugriff; ein gemerkter Wert ist ohne Abfrage gültig.
    if let hit = cached(), hit != nil { return true }
    return inner.hasKey()
  }

  /// Eine gemerkte Instanz je ID (z. B. je Kalenderquelle), threadsicher.
  public static func memoized(_ make: @escaping (String) -> ApiKeyStore) -> (String) -> ApiKeyStore {
    let lock = NSLock()
    var stores: [String: ApiKeyStore] = [:]
    return { id in
      lock.lock(); defer { lock.unlock() }
      if let s = stores[id] { return s }
      let s = CachedApiKeyStore(make(id))
      stores[id] = s
      return s
    }
  }
}
