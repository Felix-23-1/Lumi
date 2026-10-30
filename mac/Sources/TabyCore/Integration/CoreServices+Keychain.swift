import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  static let tokenKey = "token"

  /// Altbestand: Tokens aus der Quellen-Konfiguration in den Schlüsselbund.
  static func moveTokensToKeychain(store: Store, secrets: (String) -> ApiKeyStore) {
    for src in (try? store.calendarSources.list()) ?? [] {
      guard let token = src.config[tokenKey]?.stringValue else { continue }
      do {
        if !token.isEmpty { try secrets(src.id).set(token) }
        var cfg = src.config
        cfg[tokenKey] = nil
        _ = try store.calendarSources.update(src.id, config: cfg)
      } catch {
        TabyLog.error(.calendar, "Kalender-Token nicht in den Schlüsselbund verschoben (\(TabyLog.code(error)))")
      }
    }
  }

  /// Einmalig: Der bisherige, einzige Schlüssel gehörte zu openrouter.ai. War beim Umstieg
  /// auf je Host getrennte Schlüssel ein anderer Endpunkt eingestellt, wandert der Schlüssel
  /// an dessen Konto. So geht er nie an einen anderen Host. Scheitert das Verschieben,
  /// bleibt die Markierung aus und der nächste Start versucht es erneut.
  static func migrateLegacyLlmKey(store: Store, keyStore: ApiKeyStore, hostKeyStore: (String) -> ApiKeyStore) {
    let flag = "llmKeyHostMigrated"
    guard ((try? store.db.query("SELECT key FROM app_settings WHERE key = ?", [.text(flag)])) ?? []).isEmpty else { return }
    let host = LlmConnection.host(of: (try? store.settings.get())?.llmBaseUrl ?? "") ?? ""
    if !host.isEmpty, host != LlmConnection.defaultHost, keyStore.hasKey() {
      do {
        if let old = try keyStore.get() {
          try hostKeyStore(host).set(old)
          try keyStore.delete()
        }
      } catch {
        TabyLog.error(.calendar, "API-Schlüssel nicht an den Endpunkt-Host verschoben (\(TabyLog.code(error)))")
        return
      }
    }
    _ = try? store.db.run("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)", [.text(flag), .text("true")])
  }

  /// Kennung des Zugangscodes im Schlüsselbund. Der Standard-Zugang behält den bisherigen Eintrag
  /// ("notion-tasks", siehe `connectNotionTasks`); jeder weitere Zugang bekommt "notion-<id>".
  static func notionSecretId(_ accountId: String) -> String {
    accountId == NotionAccount.legacyId ? "notion-tasks" : "notion-\(accountId)"
  }
}

extension CoreServices {
  func notionAccountSecrets(_ accountId: String) -> ApiKeyStore {
    secretStore(Self.notionSecretId(accountId))
  }

  /// Zugangscode eines Notion-Zugangs (getrimmt); nil, wenn keiner hinterlegt ist. Nie loggen.
  func notionAccountToken(_ accountId: String) -> String? {
    guard let raw = (try? notionAccountSecrets(accountId).get()) ?? nil else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Zugänge mit gespeichertem Zugangscode, in der Reihenfolge der Einstellungen. Aus dem Speicher
  /// (`notionConnectedSet`), ohne Schlüsselbund-Zugriff – `state()` läuft oft.
  func notionConnectedAccountIds(_ accounts: [NotionAccount]) -> [String] {
    let connected = notionConnectedSet(accounts)
    return accounts.map(\.id).filter { connected.contains($0) }
  }

  /// Menge der Zugänge mit Code. Einmal je Lauf per `hasKey` gelesen (ohne Wert, ohne Freigabe-Dialog),
  /// danach aus dem Speicher; jeder Schreibzugriff auf den Schlüsselbund ruft `refreshNotionConnected` auf.
  func notionConnectedSet(_ accounts: [NotionAccount]) -> Set<String> {
    if let cached = notionLocalState().connectedAccounts { return cached }
    let ids = Set(accounts.map(\.id).filter { notionAccountSecrets($0).hasKey() })
    timersUndo.notionLocal?.connectedAccounts = ids
    return ids
  }

  /// Nach jedem Schreiben oder Löschen eines Zugangscodes: nur dessen Stand neu lesen (`hasKey`).
  func refreshNotionConnected(_ accountId: String) {
    var ids = notionLocalState().connectedAccounts ?? notionConnectedSet(settings.notionAccounts)
    if notionAccountSecrets(accountId).hasKey() { ids.insert(accountId) } else { ids.remove(accountId) }
    timersUndo.notionLocal?.connectedAccounts = ids
  }
}
