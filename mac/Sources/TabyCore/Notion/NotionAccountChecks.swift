// Prüfungen für Notion-Zugänge (Arbeitsbereiche): Kategorie je Zugang, getrennte Zugangscodes,
// Schlüsselbund-Namen, Entfernen mit und ohne Aufgaben (Rückgängig), Werkzeuge und Migration.
// Notion wird über das gestubbte URLProtocol aus NotionTaskChecks nachgebildet; Codes sind Testwerte im Speicher.
// Hinweis: Die Prüfungs-Helfer nehmen Ausdrücke als Autoclosure, deshalb stehen alle `await`-Aufrufe vorher in `let`.
import Foundation

/// Protokoll der gestubbten Notion-Anfragen (Adresse und Authorization-Kopfzeile je Anfrage).
final class NotionRequestLog {
  private(set) var entries: [(url: String, auth: String)] = []
  func record(url: String, auth: String) { entries.append((url, auth)) }
}

/// Zeichnet auf, unter welchen Kennungen der Schlüsselbund angesprochen wurde.
final class AccountSecretRecorder {
  var ids: [String] = []
  var stores: [String: InMemoryApiKeyStore] = [:]
}

enum NotionAccountChecks {
  /// Zwei Arbeitsbereiche: „Arbeit“ (Standard-Zugang, Code tok-a) und „Privat“ (Code tok-b).
  static let workDb = String(repeating: "a1", count: 16)
  static let privateDb = String(repeating: "b2", count: 16)

  @MainActor static func rig(session: URLSession = .shared) throws -> (CoreServices, AccountSecretRecorder) {
    let clock = ControllableClock("2026-10-20T08:00")
    let recorder = AccountSecretRecorder()
    let opts = CoreServices.Options(
      databasePath: nil, socketPath: nil, clock: clock, keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
      session: session, plannerInterval: nil,
      calendarSecrets: { id in
        recorder.ids.append(id)
        if let s = recorder.stores[id] { return s }
        let s = InMemoryApiKeyStore(); recorder.stores[id] = s; return s
      },
      notionOAuthClientSecrets: { InMemoryApiKeyStore() })
    return (try CoreServices(options: opts), recorder)
  }

  /// Gestubtes Notion für beide Arbeitsbereiche; nur der passende Code wird angenommen (sonst 401).
  /// `failPrivate` lässt den Privat-Bereich mit 500 scheitern.
  static func workspaceSession(log: NotionRequestLog, failPrivate: Bool = false) -> URLSession {
    NotionTaskStubURLProtocol.session { req, _ in
      let url = req.url!.absoluteString
      let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
      log.record(url: url, auth: auth)
      let work = (db: workDb, ds: "ds-a", token: "tok-a", title: "Ticket Arbeit", page: "pa", fail: false)
      let priv = (db: privateDb, ds: "ds-b", token: "tok-b", title: "Ticket Privat", page: "pb", fail: failPrivate)
      guard let ws = [work, priv].first(where: { url.contains("/databases/\($0.db)") || url.contains("/data_sources/\($0.ds)/") })
      else { return (404, Data()) }
      guard auth == "Bearer \(ws.token)" else {
        return (401, Data(JSONValue.object(["object": "error", "message": "unauthorized"]).jsonString().utf8))
      }
      if ws.fail { return (500, Data(JSONValue.object(["object": "error", "message": "boom"]).jsonString().utf8)) }
      if url.hasSuffix("/v1/databases/\(ws.db)") {
        return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": .string(ws.ds)]]]).jsonString().utf8))
      }
      if url.hasSuffix("/v1/data_sources/\(ws.ds)/query") {
        let row: JSONValue = ["id": .string(ws.page), "properties": [
          "Name": ["type": "title", "title": [["plain_text": .string(ws.title)]]],
        ]]
        return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
      }
      return (404, Data())
    }
  }

  /// Richtet „Arbeit“ (Standard-Zugang) und „Privat“ mit je einer Quelle ein und gleicht ab. Liefert die Kennung von „Privat“.
  @MainActor static func connectTwo(_ svc: CoreServices) async throws -> String {
    _ = await svc.connectNotionTasks(token: "tok-a")
    let added = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: "tok-b")
    let privat = try expectNotNil(added.value, "Zugang Privat angelegt")
    _ = await svc.addNotionSource(name: "Arbeit", category: .tickets, link: workDb, accountId: NotionAccount.legacyId)
    _ = await svc.addNotionSource(name: "Privat", category: .tickets, link: privateDb, accountId: privat.id)
    _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
    _ = await svc.syncNotionTasks()
    return privat.id
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Kategorie wirksam: eigene, Ordner, Notion-Zugang, unbekannte Kennungen") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-20T08:00"))
        let defs = TaskCategoryDef.builtIn + [TaskCategoryDef(id: "sport", name: "Sport", symbol: "figure.run")]
        let folder = TaskFolder(id: "f1", name: "Reise", createdAt: "2026-10-01T08:00", categoryId: "privat")
        let own = try store.tasks.add(title: "Eigene", category: TaskCategory(rawValue: "sport"))
        let inFolder = try store.tasks.add(title: "Im Ordner", folderId: "f1")
        let notion = try store.tasks.add(title: "Notion", category: TaskCategory(rawValue: "sport"))
        let unknown = try store.tasks.add(title: "Unbekannt", category: TaskCategory(rawValue: "geloescht"))
        let loose = try store.tasks.add(title: "Lose")
        let notionCategories = [notion.id: "arbeit"]
        func eff(_ id: String) throws -> String? {
          let task = try expectNotNil(try store.tasks.get(id), "Aufgabe")
          return TaskCategoryRules.effective(task, folders: [folder], defs: defs, notionCategories: notionCategories)
        }
        try expectEqual(try eff(own.id), "sport", "eigene Kategorie")
        try expectEqual(try eff(inFolder.id), "privat", "Kategorie des Ordners")
        try expectEqual(try eff(notion.id), "arbeit", "Notion: Kategorie des Zugangs, nie die eigene")
        try expectEqual(try eff(unknown.id), nil, "unbekannte Kennung zählt nicht")
        try expectEqual(try eff(loose.id), nil, "ohne alles keine Kategorie")
        // Notion-Aufgabe mit unbekanntem Zugang (Kennung "") bekommt nie ihre eigene Kategorie.
        let orphan = try store.tasks.add(title: "Verwaist", category: TaskCategory(rawValue: "privat"))
        let orphanTask = try expectNotNil(try store.tasks.get(orphan.id), "Aufgabe")
        let orphanCategory = TaskCategoryRules.effective(orphanTask, folders: [folder], defs: defs,
                                                         notionCategories: [orphan.id: ""])
        try expectEqual(orphanCategory, nil, "Notion-Aufgabe ohne Zugang: keine Kategorie")
      },

      CheckCase("Notion-Aufgabe des Arbeits-Zugangs erscheint nie unter privat (list_tasks)") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-20T08:00"))
        let task = try store.tasks.add(title: "Ticket Arbeit")
        let source = try store.notionSources.add(name: "Tickets", category: .tickets, link: workDb)
        try store.notionTaskLinks.upsert(notionId: "n1", taskId: task.id, sourceId: source.id, now: "2026-10-20T08:00")
        let ctx = ToolContext(store: store, mode: .standard)
        let privat = await ToolRegistry.execute(name: "list_tasks", args: ["category": "privat"], ctx: ctx)
        try expectEqual(privat["tasks"]?.arrayValue?.count, 0, "unter privat nichts")
        let arbeit = await ToolRegistry.execute(name: "list_tasks", args: ["category": "arbeit"], ctx: ctx)
        try expectEqual(arbeit["tasks"]?.arrayValue?.count, 1, "unter arbeit die Notion-Aufgabe")
        try expectEqual(arbeit["tasks"]?.arrayValue?.first?["category"]?.stringValue, "arbeit", "Kategorie des Zugangs gezeigt")
      },

      CheckCase("Zugang: Kategorie ändern verschiebt seine Aufgaben sofort (notionTaskCategories)") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        _ = await svc.addNotionSource(name: "Arbeit", category: .tickets, link: workDb, accountId: NotionAccount.legacyId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let before = await svc.state()
        let taskId = try expectNotNil(before.tasks.first { $0.title == "Ticket Arbeit" }?.id, "importiert")
        try expectEqual(before.notionTaskCategories, [taskId: "arbeit"], "vorher Arbeit")
        _ = await svc.updateNotionAccount(NotionAccount.legacyId, name: nil, categoryId: "privat")
        let moved = await svc.state()
        try expectEqual(moved.notionTaskCategories, [taskId: "privat"], "nach Umstellen Privat, ohne Schreiben")
        let renamed = await svc.updateNotionAccount(NotionAccount.legacyId, name: "Geschäftlich", categoryId: nil)
        try expectEqual(renamed.value?.name, "Geschäftlich", "Umbenennen des Standard-Zugangs")
        let after = await svc.state()
        try expectEqual(after.notionTaskCategories, [taskId: "privat"], "Name ändert die Kategorie nicht")
      },

      CheckCase("Zwei Zugänge, zwei Codes: jede Quelle wird mit dem Code ihres Zugangs gelesen") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let privatId = try await connectTwo(svc)
        let state = await svc.state()
        try expectEqual(state.tasks.count, 2, "beide Bereiche importiert")
        let workTask = try expectNotNil(state.tasks.first { $0.title == "Ticket Arbeit" }?.id, "Arbeit-Aufgabe")
        let privTask = try expectNotNil(state.tasks.first { $0.title == "Ticket Privat" }?.id, "Privat-Aufgabe")
        try expectEqual(state.notionTaskCategories, [workTask: "arbeit", privTask: "privat"], "je Zugang seine Kategorie")
        try expectEqual(Set(state.notionConnectedAccounts), Set([NotionAccount.legacyId, privatId]), "beide Zugänge mit Code")
        let toWork = log.entries.filter { $0.url.contains(workDb) || $0.url.contains("/data_sources/ds-a/") }
        let toPriv = log.entries.filter { $0.url.contains(privateDb) || $0.url.contains("/data_sources/ds-b/") }
        try expect(!toWork.isEmpty && !toPriv.isEmpty, "beide Quellen abgefragt")
        try expect(toWork.allSatisfy { $0.auth == "Bearer tok-a" }, "Arbeit nur mit tok-a")
        try expect(toPriv.allSatisfy { $0.auth == "Bearer tok-b" }, "Privat nur mit tok-b")
      },

      CheckCase("Ein Zugang scheitert: die anderen werden trotzdem importiert, die Meldung nennt den Zugang") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log, failPrivate: true))
        _ = try await connectTwo(svc)
        let state = await svc.state()
        try expectEqual(state.tasks.map(\.title), ["Ticket Arbeit"], "Arbeit bleibt, Privat fehlt")
        let error = state.notionTasksSync?.lastError ?? ""
        try expect(error.contains("„Privat“"), "Meldung nennt den Zugang Privat: \(error)")
        try expect(!error.contains("„Notion“"), "Arbeit meldet keinen Fehler")
      },

      CheckCase("Schlüsselbund: Standard-Zugang behält den bisherigen Eintrag, weitere heißen notion-<id>") {
        let log = NotionRequestLog()
        let (svc, recorder) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        let added = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: "tok-b")
        let privat = try expectNotNil(added.value, "angelegt")
        try expect(recorder.ids.contains("notion-tasks"), "Standard-Zugang liest den bisherigen Eintrag")
        try expect(recorder.ids.contains("notion-\(privat.id)"), "neuer Zugang: notion-<id>")
        try expect(!recorder.ids.contains("notion-notion"), "Standard-Zugang nie unter notion-notion")
        try expectEqual(recorder.stores["notion-\(privat.id)"]?.hasKey(), true, "Code im Schlüsselbund dieses Zugangs")
        try expectEqual(recorder.stores["notion-tasks"]?.hasKey(), true, "Standard-Code im bisherigen Eintrag")
      },

      CheckCase("Geheimnis: Zugangscode steht nie in Einstellungen, Zustand oder Audit") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let secret = "geheimer-code-4711"
        let added = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: secret)
        try expect(added.isOk, "angelegt")
        _ = await svc.setNotionAccountToken(NotionAccount.legacyId, token: secret + "-2")
        let state = await svc.state()
        let settingsJSON = String(decoding: try JSONEncoder().encode(state.settings), as: UTF8.self)
        try expect(!settingsJSON.contains("geheimer"), "nicht in den Einstellungen")
        try expect(!String(describing: state).contains("geheimer"), "nicht im Zustand")
        let audit = try svc.store.audit.list(limit: 100).map { "\($0.tool) \($0.summary)" }.joined()
        try expect(!audit.contains("geheimer"), "nicht im Audit")
        try expect(!audit.isEmpty, "Audit-Einträge vorhanden")
      },

      CheckCase("Zugang entfernen ohne Aufgaben: Aufgaben bleiben ohne Kategorie, Rückgängig stellt alles her") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let privatId = try await connectTwo(svc)
        let before = await svc.state()
        let privTask = try expectNotNil(before.tasks.first { $0.title == "Ticket Privat" }?.id, "Privat-Aufgabe")
        let removed = await svc.removeNotionAccount(privatId, deleteTasks: false)
        try expect(removed.isOk, "entfernt")
        let afterRemove = await svc.state()
        try expectEqual(afterRemove.tasks.count, 2, "Aufgaben bleiben")
        try expectEqual(afterRemove.tasks.first { $0.id == privTask }?.category, nil, "gewöhnliche Aufgabe ohne Kategorie")
        try expectEqual(afterRemove.notionTaskCategories.keys.contains(privTask), false, "keine Notion-Aufgabe mehr")
        try expectEqual(afterRemove.settings.notionAccounts.map(\.id), [NotionAccount.legacyId], "Zugang weg")
        _ = await svc.undoLast()
        let restored = await svc.state()
        try expectEqual(restored.notionTaskCategories[privTask], "privat", "Rückgängig: wieder Notion-Aufgabe Privat")
        try expect(restored.notionConnectedAccounts.contains(privatId), "Rückgängig: Code wieder da")
      },

      CheckCase("Zugang entfernen mit Aufgaben: Aufgaben weg, Rückgängig holt sie zurück") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let privatId = try await connectTwo(svc)
        let before = await svc.state()
        let privTask = try expectNotNil(before.tasks.first { $0.title == "Ticket Privat" }?.id, "Privat-Aufgabe")
        let removed = await svc.removeNotionAccount(privatId, deleteTasks: true)
        try expect(removed.isOk, "entfernt")
        let afterRemove = await svc.state()
        try expectEqual(afterRemove.tasks.map(\.title), ["Ticket Arbeit"], "Privat-Aufgaben gelöscht")
        _ = await svc.undoLast()  // Zugang, Code, Quelle
        _ = await svc.undoLast()  // gelöschte Aufgabe mit ihrer Verknüpfung
        let restored = await svc.state()
        try expectEqual(Set(restored.tasks.map(\.title)), ["Ticket Arbeit", "Ticket Privat"], "Aufgabe zurück")
        try expectEqual(restored.notionTaskCategories[privTask], "privat", "wieder dem Zugang Privat zugeordnet")
        try expect(restored.notionConnectedAccounts.contains(privatId), "Code zurück")
      },

      CheckCase("Standard-Zugang lässt sich nicht entfernen") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        let removed = await svc.removeNotionAccount(NotionAccount.legacyId, deleteTasks: true)
        try expect(removed.errorMessage != nil, "abgewiesen")
        let state = await svc.state()
        try expectEqual(state.settings.notionAccounts.map(\.id), [NotionAccount.legacyId], "bleibt")
        try expectEqual(state.notionConnectedAccounts, [NotionAccount.legacyId], "Code bleibt")
      },

      CheckCase("Werkzeug update_task: Kategorie einer Notion-Aufgabe wird abgewiesen, add_task bleibt frei") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-20T08:00"))
        let task = try store.tasks.add(title: "Ticket")
        let source = try store.notionSources.add(name: "Tickets", category: .tickets, link: workDb)
        try store.notionTaskLinks.upsert(notionId: "n1", taskId: task.id, sourceId: source.id, now: "2026-10-20T08:00")
        let ctx = ToolContext(store: store, mode: .standard)
        let r = await ToolRegistry.execute(name: "update_task", args: ["id": .string(task.id), "category": "privat"], ctx: ctx)
        try expectEqual(r["ok"]?.boolValue, false, "abgewiesen")
        try expectEqual(r["error"]?.stringValue,
                        "Notion-Aufgaben gehören zur Kategorie ihres Notion-Zugangs (Notion → Arbeit). Ändere sie in den Einstellungen.",
                        "Meldung nennt Zugang und Kategorie")
        try expectEqual(try store.tasks.get(task.id)?.category, nil, "nichts geändert")
        let added = await ToolRegistry.execute(name: "add_task", args: ["title": "Privat", "category": "privat"], ctx: ctx)
        try expectEqual(added["ok"]?.boolValue, true, "add_task ist davon nicht betroffen")
      },

      CheckCase("Migration: bestehende Quellen gehören zum Standard-Zugang \"notion\"") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-20T08:00"))
        let added = try store.notionSources.add(name: "Alt", category: .todos, link: "p")
        try expectEqual(try store.notionSources.get(added.id)?.accountId, "notion", "neue Quelle ohne Zugang")
        try store.db.run("INSERT INTO notion_source (id, name, category, link, sort_order) VALUES (?, ?, ?, ?, ?)",
                         [.text("old"), .text("Ohne Spalte"), .text("tickets"), .text("q"), .of(9)])
        try expectEqual(try store.notionSources.get("old")?.accountId, "notion", "Standardwert der Spalte")
      },

      CheckCase("Quelle und Zugang: unbekannter Zugang, doppelter Name, Länge, Steuerzeichen, Kategorie, Obergrenze") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let unknown = await svc.addNotionSource(name: "X", category: .tickets, link: workDb, accountId: "gibt-es-nicht")
        try expect(unknown.errorMessage != nil, "unbekannter Zugang abgewiesen")
        let noSource = await svc.state()
        try expectEqual(noSource.notionSources.count, 0, "keine Quelle angelegt")
        _ = await svc.connectNotionTasks(token: "tok-a")
        let added = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: "tok-b")
        let privat = try expectNotNil(added.value, "angelegt")
        let duplicate = await svc.addNotionAccount(name: "privat", categoryId: "privat", token: "tok-c")
        try expect(duplicate.errorMessage != nil, "Name ohne Groß/Klein doppelt")
        let long = await svc.addNotionAccount(name: String(repeating: "x", count: 25), categoryId: "privat", token: "t")
        try expect(long.errorMessage != nil, "Name zu lang")
        let control = await svc.addNotionAccount(name: "Geheim\nNeu", categoryId: "privat", token: "t")
        try expect(control.errorMessage != nil, "Steuerzeichen")
        let category = await svc.addNotionAccount(name: "Sport", categoryId: "gibt-es-nicht", token: "t")
        try expect(category.errorMessage != nil, "unbekannte Kategorie")
        for i in 0..<6 {
          _ = await svc.addNotionAccount(name: "Zugang \(i)", categoryId: "arbeit", token: "t\(i)")
        }
        let tooMany = await svc.addNotionAccount(name: "Zu viel", categoryId: "arbeit", token: "t")
        try expect(tooMany.errorMessage != nil, "höchstens 8 Zugänge")
        let ok = await svc.addNotionSource(name: "Privat", category: .tickets, link: privateDb, accountId: privat.id)
        try expectEqual(ok.value?.accountId, privat.id, "Quelle im Zugang Privat")
      },

      CheckCase("Trennen des Standard-Zugangs: mit zweitem Zugang bleibt der Abgleich an, verbunden und die Kategorie") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let privatId = try await connectTwo(svc)
        let before = await svc.state()
        let privTask = try expectNotNil(before.tasks.first { $0.title == "Ticket Privat" }?.id, "Privat-Aufgabe")
        await svc.disconnectNotionTasks()
        let after = await svc.state()
        try expect(after.settings.notionTasksEnabled, "Abgleich bleibt an")
        try expect(after.notionTasksConnected, "verbunden: Privat hat noch einen Code")
        try expectEqual(after.notionConnectedAccounts, [privatId], "nur Privat hat noch einen Code")
        try expectEqual(after.notionTaskCategories[privTask], "privat", "Privat-Aufgabe behält ihre Kategorie")
        let synced = await svc.syncNotionTasks()
        try expect(synced.isOk, "Abgleich über Privat läuft weiter")
      },

      CheckCase("Trennen des letzten Zugangs schaltet den Abgleich aus") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        await svc.disconnectNotionTasks()
        let state = await svc.state()
        try expect(!state.settings.notionTasksEnabled, "ausgeschaltet")
        try expect(!state.notionTasksConnected, "nicht verbunden")
        try expect(state.notionTasksSync == nil, "kein Abgleichstand")
      },

      CheckCase("Kennungen: nur „notion“ oder UUID; Laden verwirft fremde, Speichern lehnt die ganze Liste ab") {
        try expect(NotionAccountRules.idIsValid("notion"), "Standard-Kennung")
        try expect(NotionAccountRules.idIsValid("3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "UUID")
        try expect(!NotionAccountRules.idIsValid("../../etc/passwd"), "Pfad abgelehnt")
        try expect(!NotionAccountRules.idIsValid("notion-x"), "fremde Kennung abgelehnt")
        try expect(!NotionAccountRules.idIsValid(String(repeating: "a", count: 37)), "37 Zeichen abgelehnt")
        let loaded = NotionAccountRules.loadable([NotionAccount(id: "bad/id", name: "X", categoryId: "arbeit"), NotionAccount.legacy])
        try expectEqual(loaded.map(\.id), [NotionAccount.legacyId], "ungültige fallen beim Laden weg")
        let onlyBad = NotionAccountRules.loadable([NotionAccount(id: "bad", name: "X", categoryId: "arbeit")])
        try expectEqual(onlyBad.map(\.id), [NotionAccount.legacyId], "nie leer: Standard-Zugang bleibt")
        try expect(!NotionAccountRules.idsValid([NotionAccount.legacy, NotionAccount(id: "x y", name: "Y", categoryId: "arbeit")]),
                   "Speichern: Liste mit ungültiger Kennung abgelehnt")
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        let before = await svc.state().settings.notionAccounts.map(\.id)
        let evil = [NotionAccount.legacy, NotionAccount(id: "../evil", name: "Böse", categoryId: "arbeit")]
        _ = await svc.updateSettings(SettingsPatch(notionAccounts: evil), apiKey: nil)
        let stored = await svc.state().settings.notionAccounts.map(\.id)
        try expectEqual(stored, before, "ganze Liste abgelehnt, alles bleibt")
      },

      CheckCase("Zugang entfernt zweimal (veraltetes Formular): der zweite Aufruf löscht nichts") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        let privatId = try await connectTwo(svc)
        let first = await svc.removeNotionAccount(privatId, deleteTasks: true)
        try expect(first.isOk, "erster Aufruf entfernt")
        let second = await svc.removeNotionAccount(privatId, deleteTasks: true)
        try expect(second.errorMessage != nil, "zweiter Aufruf: nicht gefunden")
        let state = await svc.state()
        try expectEqual(state.settings.notionAccounts.map(\.id), [NotionAccount.legacyId], "nur der Standard-Zugang bleibt")
        try expectEqual(state.tasks.map(\.title), ["Ticket Arbeit"], "keine weitere Aufgabe gelöscht")
      },

      CheckCase("Zurückschreiben: verwaiste Verknüpfung (Quelle weg) wird nicht mit dem Standard-Zugang geschrieben") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = try await connectTwo(svc)
        let state = await svc.state()
        let workTask = try expectNotNil(state.tasks.first { $0.title == "Ticket Arbeit" }?.id, "Arbeit-Aufgabe")
        let workSource = try expectNotNil(try svc.store.notionSources.list().first { $0.accountId == NotionAccount.legacyId }?.id,
                                          "Quelle Arbeit")
        try svc.store.notionSources.delete(workSource)  // Quelle weg, Verknüpfung bleibt (Altfall)
        let before = log.entries.count
        svc.syncTaskCheckedToNotion(taskId: workTask, checked: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(log.entries.count, before, "keine Anfrage an Notion")
      },

      CheckCase("Schlüsselbund wird für state() nicht erneut gefragt") {
        let counter = NotionKeyCounter()
        let opts = CoreServices.Options(
          databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-20T08:00"), keyStore: InMemoryApiKeyStore(),
          systemNotifier: SinkNotifier(), session: workspaceSession(log: NotionRequestLog()), plannerInterval: nil,
          calendarSecrets: { id in CountingApiKeyStore(InMemoryApiKeyStore(), counter: counter, counted: id.hasPrefix("notion")) },
          notionOAuthClientSecrets: { InMemoryApiKeyStore() })
        let svc = try CoreServices(options: opts)
        _ = await svc.connectNotionTasks(token: "tok-a")
        _ = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: "tok-b")
        _ = await svc.state()  // Warmlauf
        let before = counter.calls
        for _ in 0..<5 { _ = await svc.state() }
        try expectEqual(counter.calls, before, "fünf state()-Aufrufe: kein Schlüsselbund-Zugriff")
      },

      CheckCase("Quelle entfernt während eines Abgleichs: der Abgleich legt für sie nichts an") {
        let log = NotionRequestLog()
        let (svc, _) = try rig(session: workspaceSession(log: log))
        _ = await svc.connectNotionTasks(token: "tok-a")
        let added = await svc.addNotionAccount(name: "Privat", categoryId: "privat", token: "tok-b")
        let privat = try expectNotNil(added.value, "Zugang Privat")
        _ = await svc.addNotionSource(name: "Arbeit", category: .tickets, link: workDb, accountId: NotionAccount.legacyId)
        let privSourceResult = await svc.addNotionSource(name: "Privat", category: .tickets, link: privateDb, accountId: privat.id)
        let privSource = try expectNotNil(privSourceResult.value?.id, "Quelle Privat")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        let sync = Task { @MainActor in await svc.syncNotionTasks() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let removal = await svc.removeNotionSource(privSource, deleteTasks: true)
        _ = await sync.value
        try expect(removal.isOk, "entfernt")
        let state = await svc.state()
        try expect(!state.tasks.contains { $0.title == "Ticket Privat" }, "keine Privat-Aufgabe mehr")
        try expect(svc.store.notionTaskLinks.all().allSatisfy { $0.sourceId != privSource }, "keine Verknüpfung der Quelle")
      },
    ]
  }
}

/// Zählt Schlüsselbund-Zugriffe der Notion-Zugänge (für die Prüfung „state() fragt nicht ab“).
final class NotionKeyCounter {
  var calls = 0
}

/// Schlüsselbund-Attrappe, die ihre Zugriffe zählt (nur für Notion-Kennungen).
final class CountingApiKeyStore: ApiKeyStore {
  private let inner: InMemoryApiKeyStore
  private let counter: NotionKeyCounter
  private let counted: Bool
  init(_ inner: InMemoryApiKeyStore, counter: NotionKeyCounter, counted: Bool) {
    self.inner = inner; self.counter = counter; self.counted = counted
  }
  private func tick() { if counted { counter.calls += 1 } }
  func get() throws -> String? { tick(); return try inner.get() }
  func set(_ key: String) throws { tick(); try inner.set(key) }
  func delete() throws { tick(); try inner.delete() }
  func hasKey() -> Bool { tick(); return inner.hasKey() }
}
