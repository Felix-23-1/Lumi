// Notion-Aufgaben aus mehreren benannten Quellen (Tickets, To-dos, Weekly) einlesen und mit den
// Lumi-Aufgaben abgleichen. Lokale Erledigt-Haken gehen zurück nach Notion (syncTaskCheckedToNotion).
// Lokal gelöschte Aufgaben kommen nicht zurück; der Notizen-Text einer Verknüpfung wird nur
// überschrieben, wenn er sich in Notion seit dem letzten Abgleich geändert hat.
// Entscheidung: docs/decisions/0009-notion-tasks.md.
import Foundation

/// Lokaler Zustand der Notion-Anbindung, der nicht in den Verknüpfungen steht: gelöschte
/// Aufgaben (Notion-IDs) und der Hash des zuletzt gelesenen Seitentextes je Verknüpfung.
// shortcut: JSON-Datei neben der Datenbank statt einer Tabelle (Migrations gehören einem anderen
// Agenten); in eine Tabelle überführen, sobald die Migration dafür angelegt ist.
struct NotionLocalState: Codable, Equatable {
  var deleted: [String] = []
  var bodyHash: [String: String] = [:]
  /// Nur im Speicher (nicht in der Datei): Zugänge mit gespeichertem Code; nil = noch nicht gelesen.
  /// Jeder Schreibzugriff auf den Schlüsselbund liest den Stand seines Zugangs neu (`refreshNotionConnected`).
  var connectedAccounts: Set<String>?
  private enum CodingKeys: String, CodingKey { case deleted, bodyHash }
}

/// Lumi-Stand aus dem Notion-Status ableiten. Nur, wenn der Text neu ist (neue Aufgabe oder seit dem
/// letzten Abgleich geändert): ein lokal gesetzter Stand bleibt, solange Notion nichts ändert.
enum NotionStatusSync {
  static func statusToApply(previousNotion: String?, newNotion: String?, map: [String: String]) -> TaskStatus? {
    guard let newNotion, previousNotion != newNotion else { return nil }
    return NotionStatusRules.lumiStatus(forNotion: newNotion, map: map)
  }
}

extension CoreServices {
  /// Zugangscode des Standard-Zugangs (Altbestand, eigener Schlüsselbund-Eintrag, getrennt vom Kalender-Token).
  func notionTasksSecrets() -> ApiKeyStore { notionAccountSecrets(NotionAccount.legacyId) }

  /// Alle 15 Minuten automatisch abgleichen, wenn eingeschaltet.
  func notionTasksTickIfStale() async {
    guard settings.notionTasksEnabled else { return }
    let now = clock.now()
    if let last = notionTasksLastAutoSync, now.timeIntervalSince(last) < 15 * 60 { return }
    notionTasksLastAutoSync = now
    _ = await syncNotionTasks()
  }

  public func connectNotionTasks(token: String) async -> ToolResult<Empty> {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(code: "INVALID", error: "Token fehlt.") }
    do {
      try notionTasksSecrets().set(trimmed)
      refreshNotionConnected(NotionAccount.legacyId)
      emit(.stateChanged)
      return .ok(Empty())
    } catch {
      return .failure(code: "KEYCHAIN", error: "Token konnte nicht im Schlüsselbund gespeichert werden.")
    }
  }

  /// Gilt nur für den Standard-Zugang ("notion"): der OAuth-Gastfluss liefert einen Code für einen
  /// Arbeitsbereich. Weitere Zugänge bekommen ihren Code von Hand (`setNotionAccountToken`).
  public func completeNotionOAuth(code: String) async -> ToolResult<Empty> {
    do {
      let token = try await NotionOAuthConfig.exchangeCode(code, secrets: notionOAuthSecretStore(), session: urlSession)
      try notionTasksSecrets().set(token)
      refreshNotionConnected(NotionAccount.legacyId)
      emit(.stateChanged)
      return .ok(Empty())
    } catch {
      return .failure(code: "OAUTH", error: calendarErrorMessage(error))
    }
  }

  /// Trennt den Standard-Zugang. Der Abgleich bleibt an, solange ein anderer Zugang noch einen Code hat;
  /// ausgeschaltet wird er nur, wenn danach gar kein Zugang verbunden ist. Die Aufgaben behalten ihre Kategorie.
  public func disconnectNotionTasks() async {
    try? notionTasksSecrets().delete()
    refreshNotionConnected(NotionAccount.legacyId)
    if notionConnectedAccountIds(settings.notionAccounts).isEmpty {
      _ = try? store.settings.update(SettingsPatch(notionTasksEnabled: false), hasApiKey: settings.hasApiKey)
      notionTasksSyncState = nil
    }
    emit(.stateChanged)
  }

  // MARK: Paket 11: mehrere benannte Quellen

  /// Einmalig: altes Einzelfeld (Datenbank- oder Seiten-ID) in eine Quelle übernehmen,
  /// damit ein bereits eingetragener Link nicht verloren geht.
  private func migrateLegacyNotionSettingsIfNeeded() {
    let s = settings
    guard (try? store.notionSources.list())?.isEmpty ?? true else { return }
    if !s.notionTasksDatabaseId.isEmpty {
      _ = try? store.notionSources.add(name: "Importiert", category: .tickets, link: s.notionTasksDatabaseId)
    } else if !s.notionTasksPageId.isEmpty {
      _ = try? store.notionSources.add(name: "Importiert", category: .todos, link: s.notionTasksPageId)
    }
  }

  /// Legt eine neue, leere Quelle an (Link kommt erst über `updateNotionSource`,
  /// sobald der Nutzer ihn in das Feld einfügt – "+ Quelle hinzufügen" legt
  /// bewusst eine noch-leere Zeile zum Ausfüllen an).
  /// Legt eine Quelle im Standard-Zugang an (die Form ohne Zugang).
  public func addNotionSource(name: String, category: NotionSourceCategory, link: String) async -> ToolResult<NotionSource> {
    await addNotionSource(name: name, category: category, link: link, accountId: NotionAccount.legacyId)
  }

  /// Legt eine Quelle in einem bestimmten Notion-Zugang an; ihre Seiten lesen wir mit dessen Code.
  public func addNotionSource(name: String, category: NotionSourceCategory, link: String,
                              accountId: String) async -> ToolResult<NotionSource> {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return .failure(code: "INVALID", error: "Name angeben.") }
    guard settings.notionAccounts.contains(where: { $0.id == accountId }) else {
      return .failure(code: "VALIDATION", error: "Den Notion-Zugang gibt es nicht.")
    }
    let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let s = try? store.notionSources.add(name: trimmedName, category: category, link: trimmedLink,
                                               accountId: accountId) else {
      return .failure(code: "STORE", error: "Konnte nicht gespeichert werden.")
    }
    emit(.stateChanged)
    return .ok(s)
  }

  public func updateNotionSource(_ id: String, name: String?, category: NotionSourceCategory?,
                                 link: String?) async -> ToolResult<NotionSource> {
    guard var s = (try? store.notionSources.update(id, name: name, category: category, link: link)) ?? nil else {
      return .failure(code: "NOT_FOUND", error: "Quelle nicht gefunden.")
    }
    // Modular: solange der Nutzer noch keinen eigenen Namen vergeben hat, übernimmt
    // Lumi nach einem gültigen Link automatisch den Titel der Notion-Seite/-Datenbank
    // selbst – der Unterreiter im Notion-Reiter heißt dann wie in Notion, ohne Tippen.
    if name == nil, link != nil, s.name.isEmpty || s.name == "Neue Quelle" || s.name == "Importiert",
       let notionId = NotionId.extract(s.link),
       let title = await fetchNotionSourceTitle(notionId, category: s.category, accountId: s.accountId),
       !title.isEmpty {
      s = (try? store.notionSources.update(id, name: title)) ?? s
    }
    emit(.stateChanged)
    return .ok(s)
  }

  /// Titel mit dem Zugangscode des Zugangs der Quelle (nie mit dem Code eines anderen Zugangs).
  private func fetchNotionSourceTitle(_ notionId: String, category: NotionSourceCategory,
                                      accountId: String) async -> String? {
    guard let token = notionAccountToken(accountId) else { return nil }
    let source = NotionTaskSource(token: token, session: urlSession)
    return await notionTitle(source, notionId, preferDatabase: category.isDatabase)
  }

  /// Titel zuerst als bevorzugte Art (Datenbank/Seite) lesen, sonst als die andere –
  /// Notion-Links sind nicht immer so, wie die Kategorie vermuten lässt.
  private func notionTitle(_ source: NotionTaskSource, _ id: String, preferDatabase: Bool) async -> String? {
    for isDatabase in [preferDatabase, !preferDatabase] {
      if let title = Self.usableNotionTitle(try? await source.fetchTitle(id, isDatabase: isDatabase)) { return title }
    }
    return nil
  }

  /// Nur ein echter Titel benennt eine Quelle: leer oder ein Platzhalter von Notion
  /// („Untitled“, „Unbenannt“, „Ohne Titel“, ohne Groß-/Kleinschreibung) zählt als kein Titel.
  static func usableNotionTitle(_ title: String?) -> String? {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, !["untitled", "unbenannt", "ohne titel"].contains(trimmed.lowercased()) else { return nil }
    return trimmed
  }

  /// Zeilen/To-dos lesen: zuerst die Art der Kategorie, bei Fehler die andere. Schlagen
  /// beide fehl, kommt der Fehler des ersten Versuchs zurück. 0 Einträge ist ein Erfolg.
  private func readNotionSource(_ source: NotionTaskSource, id: String, preferDatabase: Bool) async throws -> [NotionTaskSource.Item] {
    func read(_ database: Bool) async throws -> [NotionTaskSource.Item] {
      if database { return try await source.fetchDatabase(id) }
      return try await source.fetchPageTodos(id)
    }
    let items: [NotionTaskSource.Item]
    do {
      items = try await read(preferDatabase)
    } catch let first {
      do {
        return try await read(!preferDatabase)
      } catch {
        throw first
      }
    }
    // Leer ist nicht automatisch „nichts da“: Notion liefert für eine Datenbank-ID auf
    // /blocks/…/children manchmal eine leere Liste. Dann die andere Art versuchen.
    guard items.isEmpty else { return items }
    return (try? await read(!preferDatabase)).flatMap { $0.isEmpty ? nil : $0 } ?? items
  }

  /// Wochen-Quelle: erst als Seite (Unterseiten bzw. eingebettete Datenbank), sonst als
  /// Datenbank (Zeilen = Wochen). Schlagen beide fehl, kommt der Fehler des ersten Versuchs
  /// zurück – außer bei einer verknüpften Ansicht: dort ist der Hinweis auf die Originaldatenbank
  /// die brauchbare Meldung, also die des zweiten Versuchs.
  private func readNotionWeekly(_ source: NotionTaskSource, id: String) async throws -> [NotionTaskSource.Item] {
    do {
      let items = try await source.fetchWeekly(id)
      if !items.isEmpty { return items }
      // Leere Liste auf einer Datenbank-ID: die Zeilen-Lesart versuchen, bei Fehler bei [] bleiben.
      return (try? await source.fetchWeeklyDatabase(id)) ?? items
    } catch let first {
      do {
        return try await source.fetchWeeklyDatabase(id)
      } catch let second {
        if case CalendarError.unreachable(let msg) = second, msg.contains("verknüpfte Ansicht") { throw second }
        throw first
      }
    }
  }

  /// Haken setzen: zuerst die Methode der Kategorie, bei Fehler die andere. Schlagen
  /// beide fehl, kommt der Fehler des ersten Versuchs zurück.
  private func setNotionChecked(_ source: NotionTaskSource, _ id: String, checked: Bool, preferDatabase: Bool) async throws {
    do {
      if preferDatabase { try await source.setPageChecked(id, checked: checked) }
      else { try await source.setBlockChecked(id, checked: checked) }
    } catch let first {
      do {
        if preferDatabase { try await source.setBlockChecked(id, checked: checked) }
        else { try await source.setPageChecked(id, checked: checked) }
      } catch {
        throw first
      }
    }
  }

  /// Entfernt eine Notion-Quelle samt ihrer Verknüpfungen. Die Aufgaben bleiben.
  public func removeNotionSource(_ id: String) async -> ToolResult<Empty> {
    await removeNotionSource(id, deleteTasks: false)
  }

  /// Wie oben; `deleteTasks` löscht vorher die Aufgaben der Quelle (mit Rückgängig, solange ihre
  /// Verknüpfungen noch existieren). Schlägt das Löschen fehl, meldet das die Oberfläche.
  public func removeNotionSource(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty> {
    let source = (try? store.notionSources.get(id)) ?? nil
    let links = source == nil ? [] : notionLinks(sourceId: id)
    // Die Quelle zuerst weg, vor dem ersten `await`: ein laufender Abgleich prüft die Quelle nach jedem
    // Warten und legt für eine entfernte nichts mehr an. Die Verknüpfungen bleiben bis zum Schluss, damit
    // das Löschen der Aufgaben sie für Rückgängig festhält.
    do {
      try store.notionSources.delete(id)
    } catch {
      emit(.stateChanged)
      return .failure(code: "ERROR", error: "Die Notion-Quelle konnte nicht entfernt werden.")
    }
    if deleteTasks {
      for link in links {
        _ = await runUndoable("delete_task", ["id": .string(link.taskId)], ctx: toolContext(actor: .user))
      }
    }
    do {
      try store.notionTaskLinks.deleteBySource(id)
    } catch {
      emit(.stateChanged)
      return .failure(code: "ERROR", error: "Die Notion-Quelle konnte nicht entfernt werden.")
    }
    if let source { pushUndo(.removedNotionSource(source, links), "Notion-Quelle entfernt") }
    emit(.stateChanged)
    return .ok(Empty())
  }

  /// Ist die Quelle noch da? Nach jedem `await` im Abgleich prüfen (sie kann inzwischen entfernt sein).
  private func notionSourceExists(_ id: String) -> Bool {
    ((try? store.notionSources.get(id)) ?? nil) != nil
  }

  // MARK: Notion-Zugänge (Arbeitsbereiche mit eigener Kategorie und eigenem Code)

  /// Neuer Zugang: Code in den Schlüsselbund (nie in die Einstellungen), dann in die Einstellungen.
  public func addNotionAccount(name: String, categoryId: String, token: String) async -> ToolResult<NotionAccount> {
    let accounts = settings.notionAccounts
    guard accounts.count < NotionAccountRules.maxCount else {
      return .failure(code: "VALIDATION", error: "Höchstens \(NotionAccountRules.maxCount) Notion-Zugänge.")
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = NotionAccountRules.nameProblem(trimmedName, others: accounts.map(\.name)) {
      return .failure(code: "VALIDATION", error: problem)
    }
    let category = TaskCategoryRules.normalize(categoryId) ?? ""
    if let problem = NotionAccountRules.categoryProblem(category, defs: settings.taskCategories) {
      return .failure(code: "VALIDATION", error: problem)
    }
    let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { return .failure(code: "INVALID", error: "Zugangscode fehlt.") }
    let account = NotionAccount(id: StoreIds.make(), name: trimmedName, categoryId: category)
    guard NotionAccountRules.idsValid(accounts + [account]) else {
      return .failure(code: "VALIDATION", error: "Die Kennung des Notion-Zugangs ist ungültig.")
    }
    do {
      try notionAccountSecrets(account.id).set(secret)
      refreshNotionConnected(account.id)
    } catch {
      return .failure(code: "KEYCHAIN", error: "Zugangscode konnte nicht im Schlüsselbund gespeichert werden.")
    }
    do {
      _ = try store.settings.update(SettingsPatch(notionAccounts: accounts + [account]), hasApiKey: settings.hasApiKey)
    } catch {
      try? notionAccountSecrets(account.id).delete()
      refreshNotionConnected(account.id)
      return .failure(code: "STORE", error: "Der Notion-Zugang konnte nicht gespeichert werden.")
    }
    audit(actor: AuditActor.user, tool: "notion_account_add", confirmed: false, ok: true,
          summary: "Notion-Zugang angelegt")
    emit(.stateChanged)
    return .ok(account)
  }

  /// Name und/oder Kategorie. Eine neue Kategorie gilt sofort für alle Aufgaben des Zugangs
  /// (sie wird berechnet, nichts wird geschrieben).
  public func updateNotionAccount(_ id: String, name: String?, categoryId: String?) async -> ToolResult<NotionAccount> {
    var accounts = settings.notionAccounts
    guard let index = accounts.firstIndex(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    var account = accounts[index]
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let problem = NotionAccountRules.nameProblem(trimmed, others: accounts.filter { $0.id != id }.map(\.name)) {
        return .failure(code: "VALIDATION", error: problem)
      }
      account.name = trimmed
    }
    if let categoryId {
      let category = TaskCategoryRules.normalize(categoryId) ?? ""
      if let problem = NotionAccountRules.categoryProblem(category, defs: settings.taskCategories) {
        return .failure(code: "VALIDATION", error: problem)
      }
      account.categoryId = category
    }
    accounts[index] = account
    do {
      _ = try store.settings.update(SettingsPatch(notionAccounts: accounts), hasApiKey: settings.hasApiKey)
    } catch {
      return .failure(code: "STORE", error: "Der Notion-Zugang konnte nicht gespeichert werden.")
    }
    audit(actor: AuditActor.user, tool: "notion_account_update", confirmed: false, ok: true,
          summary: "Notion-Zugang geändert")
    emit(.stateChanged)
    return .ok(account)
  }

  /// Ersetzt den Zugangscode eines Zugangs (auch des Standard-Zugangs).
  public func setNotionAccountToken(_ id: String, token: String) async -> ToolResult<Empty> {
    guard settings.notionAccounts.contains(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else { return .failure(code: "INVALID", error: "Zugangscode fehlt.") }
    do {
      try notionAccountSecrets(id).set(secret)
      refreshNotionConnected(id)
    } catch {
      return .failure(code: "KEYCHAIN", error: "Zugangscode konnte nicht im Schlüsselbund gespeichert werden.")
    }
    audit(actor: AuditActor.user, tool: "notion_account_token", confirmed: false, ok: true,
          summary: "Notion-Zugangscode ersetzt")
    emit(.stateChanged)
    return .ok(Empty())
  }

  /// Entfernt einen Zugang: Code, Quellen und ihre Verknüpfungen. `deleteTasks` löscht die
  /// importierten Aufgaben (einzeln rückgängig machbar); sonst bleiben sie gewöhnliche Aufgaben ohne
  /// Kategorie. Der Standard-Zugang lässt sich nicht entfernen. Rückgängig stellt Zugang, Code,
  /// Quellen und (ohne `deleteTasks`) die Verknüpfungen wieder her.
  public func removeNotionAccount(_ id: String, deleteTasks: Bool) async -> ToolResult<Empty> {
    guard id != NotionAccount.legacyId else {
      return .failure(code: "VALIDATION", error: "Der Standard-Zugang „Notion“ lässt sich nicht entfernen. Trenne ihn stattdessen.")
    }
    let accounts = settings.notionAccounts
    guard let account = accounts.first(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Notion-Zugang nicht gefunden.")
    }
    let sources = ((try? store.notionSources.list()) ?? []).filter { $0.accountId == id }
    let links = sources.flatMap { notionLinks(sourceId: $0.id) }
    let token = notionAccountToken(id)
    // Vor dem ersten `await`: Quellen und Zugang sind schon weg, damit ein laufender Abgleich für diesen
    // Zugang nichts mehr anlegt und ein zweiter (veralteter) Aufruf nur „nicht gefunden“ sieht. Die
    // Verknüpfungen bleiben bis nach dem Löschen der Aufgaben, damit Rückgängig sie wiederherstellt.
    do {
      for source in sources { try store.notionSources.delete(source.id) }
      _ = try store.settings.update(SettingsPatch(notionAccounts: accounts.filter { $0.id != id }),
                                    hasApiKey: settings.hasApiKey)
    } catch {
      emit(.stateChanged)
      return .failure(code: "ERROR", error: "Der Notion-Zugang konnte nicht entfernt werden.")
    }
    if deleteTasks {
      for link in links {
        _ = await runUndoable("delete_task", ["id": .string(link.taskId)], ctx: toolContext(actor: .user))
      }
    } else {
      for link in links { _ = try? store.tasks.update(link.taskId, category: .set(nil)) }
    }
    do {
      for source in sources { try store.notionTaskLinks.deleteBySource(source.id) }
    } catch {
      emit(.stateChanged)
      return .failure(code: "ERROR", error: "Der Notion-Zugang konnte nicht entfernt werden.")
    }
    try? notionAccountSecrets(id).delete()
    refreshNotionConnected(id)
    pushUndo(.removedNotionAccount(account, token: token, sources: sources,
                                   links: deleteTasks ? [] : links), "Notion-Zugang entfernt")
    audit(actor: AuditActor.user, tool: "notion_account_remove", confirmed: false, ok: true,
          summary: "Notion-Zugang entfernt")
    emit(.stateChanged)
    return .ok(Empty())
  }

  /// Rückgängig für `removeNotionAccount`: Zugang, Code, Quellen und Verknüpfungen zurück.
  func restoreNotionAccount(_ account: NotionAccount, token: String?, sources: [NotionSource],
                            links: [NotionTaskLink]) throws {
    var accounts = settings.notionAccounts
    if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
    _ = try store.settings.update(SettingsPatch(notionAccounts: accounts), hasApiKey: settings.hasApiKey)
    if let token { try notionAccountSecrets(account.id).set(token) }
    refreshNotionConnected(account.id)
    for source in sources { try store.notionSources.restore(source) }
    try restoreLinks(links)
  }

  /// Gleicht alle Quellen aller Zugänge mit Zugangscode ab. Jede Quelle liest mit dem Code ihres
  /// Zugangs. Schlägt ein Zugang fehl, machen die anderen weiter; die Fehler nennen den Zugang.
  public func syncNotionTasks() async -> ToolResult<Int> {
    migrateLegacyNotionSettingsIfNeeded()
    let s = settings
    guard s.notionTasksEnabled else { return .failure(code: "OFF", error: "Notion-Aufgaben sind ausgeschaltet.") }
    var tokens: [String: String] = [:]
    for account in s.notionAccounts { if let t = notionAccountToken(account.id) { tokens[account.id] = t } }
    guard !tokens.isEmpty else {
      return .failure(code: "NO_TOKEN", error: "Kein Notion-Token hinterlegt.")
    }
    let sources = (try? store.notionSources.list()) ?? []
    guard !sources.isEmpty else {
      return .failure(code: "NO_SOURCE", error: "Noch keine Notion-Quelle eingerichtet.")
    }
    let now = LocalTime.format(clock.now())
    var total = 0
    // Fehler je Zugang (Reihenfolge wie die Zugänge), damit jede Meldung den Zugang nennt.
    var failures: [(accountId: String, message: String)] = []
    func fail(_ accountId: String, _ message: String) {
      guard !failures.contains(where: { $0.accountId == accountId && $0.message == message }) else { return }
      failures.append((accountId, message))
    }
    // Alle Seiten, die Notion gerade liefert; nur wenn jede Quelle sauber gelesen wurde, darf etwas
    // aus der Löschliste fallen (sonst fehlt eine Seite nur wegen eines Lesefehlers).
    var present = Set<String>()
    var complete = true
    for src in sources {
      let accountId = src.accountId
      let accountName = s.notionAccounts.first { $0.id == accountId }?.name ?? "Notion"
      guard let token = tokens[accountId] else {
        complete = false
        fail(accountId, "Kein Zugangscode für „\(accountName)“ hinterlegt.")
        continue
      }
      guard let id = NotionId.extract(src.link) else { complete = false; continue }
      let source = NotionTaskSource(token: token, session: urlSession)
      do {
        let fetched = src.category == .weekly
          ? try await readNotionWeekly(source, id: id)
          : try await readNotionSource(source, id: id, preferDatabase: src.category.isDatabase)
        // Nach jedem Warten prüfen: entfernt während des Lesens, legt dieser Abgleich nichts mehr an.
        guard notionSourceExists(src.id) else { complete = false; continue }
        var items = withoutForeignAccountItems(fetched, accountId: accountId)
        if let pushError = await writeBackLocalNotionEdits(&items, token: token) { fail(accountId, pushError) }
        guard notionSourceExists(src.id) else { complete = false; continue }
        present.formUnion(items.map(\.id))
        applyNotionItems(items, sourceId: src.id, now: now)
        total += items.count
        if src.name.isEmpty || src.name == "Neue Quelle" || src.name == "Importiert",
           let title = await notionTitle(source, id, preferDatabase: src.category.isDatabase) {
          _ = try? store.notionSources.update(src.id, name: title)
        }
      } catch {
        complete = false
        fail(accountId, calendarErrorMessage(error))
      }
    }
    if complete {
      updateNotionLocal { $0.deleted = CoreServices.keptDeletedNotionIds($0.deleted, present: present) }
    }
    let lastError: String? = failures.isEmpty ? nil : failures.map { failure in
      let name = s.notionAccounts.first { $0.id == failure.accountId }?.name ?? "Notion"
      return "„\(name)“: \(failure.message)"
    }.joined(separator: " ")
    notionTasksSyncState = NotionTaskSync(lastSyncAt: now, lastError: lastError, importedCount: total)
    changed()
    if let lastError, total == 0 { return .failure(code: "NOTION", error: lastError) }
    return .ok(total)
  }

  /// Seiten, die schon über einen anderen Zugang importiert sind, bleiben dort: eine Seite gehört
  /// genau zu dem Zugang, über dessen Quelle sie zuerst importiert wurde (nie gemischt).
  private func withoutForeignAccountItems(_ items: [NotionTaskSource.Item], accountId: String) -> [NotionTaskSource.Item] {
    let links = (try? store.notionTaskLinks.all()) ?? []
    guard !links.isEmpty else { return items }
    let accountBySource = Dictionary(((try? store.notionSources.list()) ?? []).map { ($0.id, $0.accountId) },
                                     uniquingKeysWith: { first, _ in first })
    let foreign = Set(links.filter { link in
      guard let owner = accountBySource[link.sourceId] else { return false }
      return owner != accountId
    }.map(\.notionId))
    return items.filter { !foreign.contains($0.id) }
  }

  /// Lokalen Zustand lesen (einmal geladen, dann aus dem Speicher).
  func notionLocalState() -> NotionLocalState {
    if let cached = timersUndo.notionLocal { return cached }
    var state = NotionLocalState()
    if let path = notionLocalPath, let data = FileManager.default.contents(atPath: path),
       let decoded = try? JSONDecoder().decode(NotionLocalState.self, from: data) {
      state = decoded
    }
    timersUndo.notionLocal = state
    return state
  }

  /// Lokalen Zustand ändern und sofort in die Datei schreiben (Fehler: nur im Speicher).
  func updateNotionLocal(_ change: (inout NotionLocalState) -> Void) {
    var state = notionLocalState()
    change(&state)
    timersUndo.notionLocal = state
    if let path = notionLocalPath, let data = try? JSONEncoder().encode(state) {
      try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
  }

  private var notionLocalPath: String? {
    store.db.path == ":memory:" || store.db.path.isEmpty ? nil
      : ((store.db.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("notion-lokal.json")
  }

  /// Notion-IDs lokal gelöschter Aufgaben merken, damit der nächste Abgleich sie nicht neu anlegt.
  func rememberNotionDeleted(_ notionIds: [String]) {
    guard !notionIds.isEmpty else { return }
    updateNotionLocal { state in
      for id in notionIds where !state.deleted.contains(id) { state.deleted.append(id) }
    }
  }

  /// Lokal gelöschte Notion-IDs, deren Seite es nicht mehr gibt, werden vergessen (die Liste wächst sonst ewig).
  static func keptDeletedNotionIds(_ deleted: [String], present: Set<String>) -> [String] {
    deleted.filter { present.contains($0) }
  }

  /// Gegenstück zu `rememberNotionDeleted`, wenn eine gelöschte Aufgabe per Rückgängig zurückkommt.
  func forgetNotionDeleted(_ notionIds: [String]) {
    guard !notionIds.isEmpty else { return }
    updateNotionLocal { state in state.deleted.removeAll { notionIds.contains($0) } }
  }

  /// Hash des zuletzt gelesenen Notion-Textes merken (Grundlage für „seit dem letzten Abgleich geändert“).
  func rememberBodyHash(_ notionId: String, _ body: String) {
    let hash = NotionTaskSource.textHash(body)
    guard notionLocalState().bodyHash[notionId] != hash else { return }
    updateNotionLocal { $0.bodyHash[notionId] = hash }
  }

  private func applyNotionItems(_ allItems: [NotionTaskSource.Item], sourceId: String, now: String) {
    let local = notionLocalState()
    // Lokal gelöschte Aufgaben kommen aus Notion nicht zurück.
    let deleted = Set(local.deleted)
    let items = allItems.filter { !deleted.contains($0.id) }
    let links = (try? store.notionTaskLinks.all()) ?? []
    let linkByNotionId = Dictionary(uniqueKeysWithValues: links.map { ($0.notionId, $0) })
    let existingIds = Set(links.map(\.taskId))
    let existingTasks = Dictionary(uniqueKeysWithValues:
      ((try? store.tasks.list()) ?? []).filter { existingIds.contains($0.id) }.map { ($0.id, $0) })
    let plan = NotionTaskSource.plan(
      items: items,
      linked: Dictionary(uniqueKeysWithValues: linkByNotionId.map { ($0.key, $0.value.taskId) }),
      existingTasks: existingTasks, lastBodyHash: local.bodyHash)
    // Stand aus dem Notion-Status: vor dem Schreiben der Verknüpfungen, damit der bisherige Text noch da ist.
    let statusMap = settings.notionStatusMap
    for item in items where !item.done {
      guard let link = linkByNotionId[item.id], let task = try? store.tasks.get(link.taskId), !task.done,
            let status = NotionStatusSync.statusToApply(previousNotion: link.meta.status, newNotion: item.meta.status, map: statusMap)
      else { continue }
      _ = try? store.tasks.update(task.id, status: status)
    }
    // Verknüpfungen mit Gruppe und Ticket-Metadaten bei jedem Abgleich frisch halten (billige
    // lokale Schreibung). Vor den Anlagen, damit eine neu angelegte Aufgabe die alte ID überschreibt.
    for item in items {
      guard let link = linkByNotionId[item.id] else { continue }
      try? store.notionTaskLinks.upsert(notionId: item.id, taskId: link.taskId, sourceId: sourceId, group: item.group,
                                        meta: item.meta, now: now)
    }
    for item in plan.create {
      guard let task = try? store.tasks.add(title: item.title, notes: item.body, due: item.due) else { continue }
      if item.done { _ = try? store.tasks.complete(task.id) }
      if !item.done, let status = NotionStatusSync.statusToApply(previousNotion: nil, newNotion: item.meta.status, map: statusMap) {
        _ = try? store.tasks.update(task.id, status: status)
      }
      if let body = item.body { rememberBodyHash(item.id, body) }
      try? store.notionTaskLinks.upsert(notionId: item.id, taskId: task.id, sourceId: sourceId, group: item.group,
                                        meta: item.meta, now: now)
      try? store.notionTaskLinks.setSyncBaseline(notionId: item.id, title: item.title, due: item.due)
    }
    for u in plan.update {
      _ = try? store.tasks.update(u.taskId, title: u.item.title,
                                  notes: u.takeNotes ? .set(u.item.body) : .keep,
                                  due: u.item.due == nil ? .set(nil) : .set(u.item.due))
      if u.item.done { _ = try? store.tasks.complete(u.taskId) } else { _ = try? store.tasks.reopen(u.taskId) }
      if u.takeNotes, let body = u.item.body { rememberBodyHash(u.item.id, body) }
      // Kein setSyncBaseline hier: writeBackLocalNotionEdits hat den Stand bereits richtig gesetzt
      // (bei fehlgeschlagenem Schreiben bleibt der alte Stand, damit der lokale Titel erneut geschrieben wird).
    }
  }

  /// Lokal geänderte Titel/Fälligkeiten verknüpfter Einträge nach Notion schreiben, bevor sie
  /// eingespielt werden (sonst überschreibt der Abgleich sie). Pro Feld: lokal geändert = weicht vom
  /// Stand des letzten Abgleichs ab. Hat Notion dasselbe Feld seither ebenfalls geändert, gewinnt
  /// Notion (dessen Zeit `last_edited_time` neuer ist als unser Stand; hier am Wert gemessen, weil
  /// Lumi die lokale Änderungszeit nicht speichert). Schlägt der Schreibzugriff fehl, bleibt der
  /// lokale Wert, der Stand wird nicht fortgeschrieben, und der nächste Abgleich versucht es erneut.
  /// Gibt die Fehlermeldung des letzten fehlgeschlagenen Schreibzugriffs zurück.
  private func writeBackLocalNotionEdits(_ items: inout [NotionTaskSource.Item], token: String) async -> String? {
    guard !items.isEmpty else { return nil }
    let links = (try? store.notionTaskLinks.all()) ?? []
    let linkByNotionId = Dictionary(links.map { ($0.notionId, $0) }, uniquingKeysWith: { first, _ in first })
    let tasks = Dictionary(((try? store.tasks.list()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var lastError: String?
    for i in items.indices {
      let item = items[i]
      guard item.writeKind != .none, let link = linkByNotionId[item.id], let task = tasks[link.taskId] else { continue }
      // Fälligkeit ohne Notion-Datum (To-do-Block, Datenbank ohne Datums-Eigenschaft) bleibt immer lokal.
      if item.writeKind == .block || item.dueProperty == nil { items[i].due = task.due }
      // Erstabgleich (noch kein gemeinsamer Stand gespeichert): Notion-Stand als Ausgangspunkt merken.
      guard let baseTitle0 = link.syncedTitle else {
        try? store.notionTaskLinks.setSyncBaseline(notionId: item.id, title: item.title, due: items[i].due)
        continue
      }
      let baseDue = link.syncedDue
      let pushTitle = task.title != baseTitle0 && item.title == baseTitle0
      let pushDue = item.writeKind == .page && item.dueProperty != nil && task.due != baseDue && item.due == baseDue
      var newTitle = item.title, newDue = items[i].due
      var keptTitle = item.title, keptDue = items[i].due
      if pushTitle || pushDue {
        do {
          let src = NotionTaskSource(token: token, session: urlSession)
          if item.writeKind == .block {
            if pushTitle { try await src.writeBlockTitle(item.id, title: task.title) }
          } else {
            try await src.writePage(item.id, title: pushTitle ? task.title : nil, setDue: pushDue, due: task.due,
                                    dueProperty: item.dueProperty)
          }
          if pushTitle { newTitle = task.title; keptTitle = task.title }
          if pushDue { newDue = task.due; keptDue = task.due }
        } catch {
          lastError = calendarErrorMessage(error)
          // Ausstehend: lokal behalten und Stand nicht fortschreiben, damit der nächste Abgleich erneut schreibt.
          if pushTitle { newTitle = task.title; keptTitle = baseTitle0 }
          if pushDue { newDue = task.due; keptDue = baseDue }
        }
      }
      items[i].title = newTitle
      items[i].due = newDue
      try? store.notionTaskLinks.setSyncBaseline(notionId: item.id, title: keptTitle, due: keptDue)
    }
    return lastError
  }

  // MARK: Abhaken synchron (einziger Schreibzugriff, docs/decisions/0009-notion-tasks.md)

  /// Aufgaben, die aus Notion importiert und noch verknüpft sind (für den Notion-Reiter).
  func notionLinkedTasks() -> [TabyTask] {
    guard let links = try? store.notionTaskLinks.all(), !links.isEmpty else { return [] }
    let linkedIds = Set(links.map(\.taskId))
    return ((try? store.tasks.list()) ?? []).filter { linkedIds.contains($0.id) }
  }

  /// Aufgaben-ID → Quellen-ID, damit der Notion-Reiter Aufgaben nach Quelle gruppieren kann.
  func notionSourceLinks() -> [String: String] {
    guard let links = try? store.notionTaskLinks.all() else { return [:] }
    return Dictionary(uniqueKeysWithValues: links.map { ($0.taskId, $0.sourceId) })
  }

  /// Aufgaben-ID → Woche (Wochen-Quelle), für die Gruppierung im Notion-Reiter.
  func notionTaskGroups() -> [String: String] {
    guard let links = try? store.notionTaskLinks.all() else { return [:] }
    return Dictionary(links.compactMap { link in
      guard let group = link.group, !group.isEmpty else { return nil }
      return (link.taskId, group)
    }, uniquingKeysWith: { first, _ in first })
  }

  /// Aufgaben-ID → Ticket-Metadaten (Erstellzeit, Ersteller, Status), nur nicht leere.
  func notionTaskMeta() -> [String: NotionTaskMeta] {
    guard let links = try? store.notionTaskLinks.all() else { return [:] }
    return Dictionary(links.compactMap { link in link.meta.isEmpty ? nil : (link.taskId, link.meta) },
                      uniquingKeysWith: { first, _ in first })
  }

  /// Aufgaben-ID → Notion-ID der Zeile/Seite, damit der Notion-Reiter das Ticket in Notion öffnen kann.
  func notionTaskPages() -> [String: String] {
    guard let links = try? store.notionTaskLinks.all() else { return [:] }
    return Dictionary(links.map { ($0.taskId, $0.notionId) }, uniquingKeysWith: { first, _ in first })
  }

  /// Setzt den Haken in Notion, wenn die Aufgabe mit einer importierten Zeile/einem To-do
  /// verknüpft ist. Bestes Bemühen im Hintergrund: schlägt es fehl, bricht nichts in Lumi ab,
  /// nur eine kurze Meldung. Ändert in Notion NUR die Erledigt-Checkbox, sonst nichts.
  func syncTaskCheckedToNotion(taskId: String, checked: Bool) {
    guard settings.notionTasksEnabled else { return }
    guard let links = try? store.notionTaskLinks.all(), let link = links.first(where: { $0.taskId == taskId })
    else { return }
    // Quelle weg: kein Zurückschreiben. Nie mit dem Code des Standard-Zugangs als Ersatz.
    guard let linkedSource = (try? store.notionSources.list())?.first(where: { $0.id == link.sourceId }) else { return }
    let isDatabase = linkedSource.category.isDatabase
    let accountId = linkedSource.accountId
    Task { @MainActor [weak self] in
      // Mit dem Code des Zugangs der Quelle, nie mit dem eines anderen Zugangs.
      guard let self, let token = self.notionAccountToken(accountId) else { return }
      let source = NotionTaskSource(token: token, session: self.urlSession)
      do {
        try await self.setNotionChecked(source, link.notionId, checked: checked, preferDatabase: isDatabase)
      } catch {
        let title = (try? self.store.tasks.get(taskId))??.title ?? "Aufgabe"
        self.emit(.flash(TabyNotification(title: "Notion nicht aktualisiert",
                                          body: "Haken bei „\(title)“ konnte nicht in Notion gesetzt werden. Bitte erneut versuchen.")))
      }
    }
  }
}

/// Zugehörigkeit der Notion-Aufgaben: Aufgabe → Quelle → Zugang → Kategorie. Berechnet aus den
/// Verknüpfungen; nichts davon wird in die Aufgabe geschrieben. Fehlt die Quelle, zählt die Aufgabe
/// als Notion-Aufgabe ohne Kategorie (Kennung ""), sie bleibt also nie eine eigene Aufgabe.
enum NotionTaskOwnership {
  /// Aufgaben-ID → Zugangs-ID.
  static func accountIds(store: Store) -> [String: String] {
    accountIds(links: (try? store.notionTaskLinks.all()) ?? [], store: store)
  }

  private static func accountIds(links: [NotionTaskLink], store: Store) -> [String: String] {
    guard !links.isEmpty else { return [:] }
    let accountBySource = Dictionary(((try? store.notionSources.list()) ?? []).map { ($0.id, $0.accountId) },
                                     uniquingKeysWith: { first, _ in first })
    return Dictionary(links.map { ($0.taskId, accountBySource[$0.sourceId] ?? "") }, uniquingKeysWith: { first, _ in first })
  }

  /// Aufgaben-ID → Kategorie-Kennung ihres Zugangs (`TaskCategoryRules.effective` prüft, ob es sie gibt).
  /// Ohne Notion-Verknüpfungen gibt es nichts zu berechnen (kein Zugriff auf Quellen und Einstellungen).
  static func categories(store: Store) -> [String: String] {
    let links = (try? store.notionTaskLinks.all()) ?? []
    guard !links.isEmpty else { return [:] }
    let accounts = (try? store.settings.get().notionAccounts) ?? [NotionAccount.legacy]
    let categoryOf = Dictionary(accounts.map { ($0.id, $0.categoryId) }, uniquingKeysWith: { first, _ in first })
    return accountIds(links: links, store: store).mapValues { categoryOf[$0] ?? "" }
  }

  /// „Geschäftlich → Arbeit“ für eine Notion-Aufgabe; nil, wenn die Aufgabe keine Notion-Aufgabe ist.
  static func label(taskId: String, store: Store) -> String? {
    guard let accountId = accountIds(store: store)[taskId] else { return nil }
    let accounts = (try? store.settings.get().notionAccounts) ?? [NotionAccount.legacy]
    let defs = (try? store.settings.get().taskCategories) ?? TaskCategoryDef.builtIn
    let account = accounts.first { $0.id == accountId }
    let categoryName = defs.first { $0.id == account?.categoryId }?.name ?? account?.categoryId ?? "keine"
    return "\(account?.name ?? "Notion") → \(categoryName)"
  }
}
