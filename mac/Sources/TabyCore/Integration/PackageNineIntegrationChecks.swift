// Paket 9 gegen den echten Kern: Notion-Aufgaben verbinden, abgleichen,
// erneut abgleichen (keine Dubletten), trennen. Token im Speicher, nie im
// echten Schlüsselbund (eigener `calendarSecrets`-Rückfall je Prüfung).
import Foundation

/// Gestubtes Notion-Ticket (Seite p1, Titel „Name“, Datum „Datum“) für die Zurückschreib-Prüfungen.
final class NotionWriteBackStub {
  var title = "Original"
  /// Datums-Eigenschaften der Seite (Name → Notion-Wert `{start, end, time_zone}` oder null).
  var dates: [String: JSONValue] = ["Datum": .null]
  var failPatch = false
  var patches: [JSONValue] = []

  func page() -> JSONValue {
    var props: [String: JSONValue] = ["Name": ["type": "title", "title": [["plain_text": .string(title)]]]]
    for (name, value) in dates { props[name] = ["type": "date", "date": value] }
    return ["id": "p1", "properties": .object(props)]
  }

  func session(dbId: String) -> URLSession {
    NotionTaskStubURLProtocol.session { [self] req, body in
      let url = req.url!.absoluteString
      if url.hasSuffix("/v1/databases/\(dbId)") {
        return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
      }
      if url.hasSuffix("/v1/data_sources/ds/query") {
        return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [page()]]).jsonString().utf8))
      }
      if req.httpMethod == "GET", url.hasSuffix("/v1/pages/p1") { return (200, Data(page().jsonString().utf8)) }
      if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/p1") {
        patches.append(body ?? .null)
        if failPatch {
          return (500, Data(JSONValue.object(["object": "error", "message": "boom"]).jsonString().utf8))
        }
        for (name, value) in body?["properties"]?.objectValue ?? [:] {
          if let t = value["title"]?.arrayValue?.first?["text"]?["content"]?.stringValue { title = t }
          if let date = value["date"] { dates[name] = date }
        }
        return (200, Data())
      }
      return (404, Data())
    }
  }
}

enum PackageNineIntegrationChecks {
  /// Mit `databasePath` eine Datei-Datenbank (für Neustart-Prüfungen); sonst im Speicher.
  @MainActor static func rig(session: URLSession = .shared, oauthClientSecret: String? = nil, databasePath: String? = nil)
    throws -> (CoreServices, ControllableClock)
  {
    let clock = ControllableClock("2026-10-12T08:00")
    var stores: [String: InMemoryApiKeyStore] = [:]
    let oauthSecrets = InMemoryApiKeyStore(oauthClientSecret)
    let opts = CoreServices.Options(
      databasePath: databasePath, socketPath: nil, clock: clock, keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
      session: session, plannerInterval: nil,
      calendarSecrets: { id in
        if let s = stores[id] { return s }
        let s = InMemoryApiKeyStore(); stores[id] = s; return s
      },
      notionOAuthClientSecrets: { oauthSecrets })
    return (try CoreServices(options: opts), clock)
  }

  /// Verbindet, richtet die Stub-Datenbank ein, importiert sie und liefert die Aufgaben-ID der Seite „Original“.
  @MainActor static func importStubPage(_ stub: NotionWriteBackStub, dbId: String, svc: CoreServices) async throws -> String {
    _ = await svc.connectNotionTasks(token: "tok")
    _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
    _ = await svc.syncNotionTasks()
    let imported = await svc.state().tasks.first { $0.title == "Original" }?.id
    return try expectNotNil(imported, "importierte Aufgabe")
  }

  /// Gestubte Tickets-Datenbank mit zwei Zeilen von Benutzer u1; `/users/u1` antwortet mit `userStatus`.
  static func ticketSession(dbId: String, userStatus: Int, onUserCall: @escaping () -> Void) -> URLSession {
    func row(_ id: String, _ title: String) -> JSONValue {
      // Mittags UTC: bleibt am selben Tag für Zeitzonen von UTC-12 bis UTC+11 (unabhängig vom Rechner).
      ["id": .string(id), "created_time": "2026-10-09T12:00:00.000Z", "created_by": ["object": "user", "id": "u1"],
       "properties": [
         "Name": ["type": "title", "title": [["plain_text": .string(title)]]],
         "Status": ["type": "status", "status": ["name": "In Bearbeitung"]],
       ]]
    }
    return NotionTaskStubURLProtocol.session { req, _ in
      let url = req.url!.absoluteString
      if url.hasSuffix("/v1/databases/\(dbId)") {
        return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
      }
      if url.hasSuffix("/v1/data_sources/ds/query") {
        let rows = [row(String(repeating: "ab12", count: 8), "Ticket A"), row(String(repeating: "cd34", count: 8), "Ticket B")]
        return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": .array(rows)]).jsonString().utf8))
      }
      if url.hasSuffix("/v1/users/u1") {
        onUserCall()
        if userStatus == 200 {
          return (200, Data(JSONValue.object(["object": "user", "name": "Thomas"]).jsonString().utf8))
        }
        return (userStatus, Data(JSONValue.object(["object": "error", "message": "forbidden"]).jsonString().utf8))
      }
      return (404, Data())
    }
  }

  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration Paket 9", [
      CheckCase("Altbestand: Notion-Token aus der Quellen-Konfiguration wandert in den Schlüsselbund, nicht mehr in SQLite") {
        let store = try Store.inMemory(clock: ControllableClock("2026-10-12T08:00"))
        let src = try store.calendarSources.add(kind: .notion, config: [
          "databaseId": .string("db-1"), "token": .string("tok-test-123"),
        ])
        var stores: [String: InMemoryApiKeyStore] = [:]
        CoreServices.moveTokensToKeychain(store: store, secrets: { id in
          if let s = stores[id] { return s }
          let s = InMemoryApiKeyStore(); stores[id] = s; return s
        })
        try expectEqual(try stores[src.id]?.get(), "tok-test-123", "Token im Schlüsselbund (Speicher-Prüfspeicher)")
        let after = try store.calendarSources.get(src.id)
        try expect(after?.config["token"] == nil, "Token ist aus SQLite entfernt")
        try expectEqual(after?.config["databaseId"]?.stringValue, "db-1", "übrige Konfiguration bleibt")
        // Zweiter Start ändert nichts mehr.
        CoreServices.moveTokensToKeychain(store: store, secrets: { id in stores[id] ?? InMemoryApiKeyStore() })
        try expectEqual(try stores[src.id]?.get(), "tok-test-123")
      },
      CheckCase("Notion-Löschliste: IDs ohne Seite werden vergessen, vorhandene bleiben") {
        let kept = CoreServices.keptDeletedNotionIds(["a", "b", "c"], present: ["b", "x"])
        try expectEqual(kept, ["b"])
      },
      CheckCase("Aus: Abgleich verweigert, kein Zustand") {
        let (svc, _) = try rig()
        let r = await svc.syncNotionTasks()
        try expect(!r.isOk, "verweigert")
        let state = await svc.state()
        try expect(state.notionTasksSync == nil && !state.notionTasksConnected)
      },

      CheckCase("An, ohne Token: klare Fehlermeldung statt Absturz") {
        let (svc, _) = try rig()
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: "db-1"), apiKey: nil)
        let r = await svc.syncNotionTasks()
        try expectEqual(r.errorMessage, "Kein Notion-Token hinterlegt.")
      },

      CheckCase("An, mit Token, ohne Quelle: klare Fehlermeldung") {
        let (svc, _) = try rig()
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        let r = await svc.syncNotionTasks()
        try expectEqual(r.errorMessage, "Noch keine Notion-Quelle eingerichtet.")
      },

      CheckCase("Voller Ablauf: verbinden, abgleichen legt Aufgaben an, erneuter Abgleich dupliziert nicht") {
        let dbId = "db11db11db11db11db11db11db11db11"
        var call = 0
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds-1"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds-1/query") {
            call += 1
            let title = call == 1 ? "Erste Fassung" : "Zweite Fassung"
            let row: JSONValue = ["id": "p1", "properties": [
              "Name": ["type": "title", "title": [["plain_text": .string(title)]]],
              "Erledigt": ["type": "checkbox", "checkbox": .bool(call > 1)],
            ]]
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        let connected = await svc.state().notionTasksConnected
        try expect(connected, "verbunden")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)

        guard case .ok(let count1) = await svc.syncNotionTasks() else { throw CheckFailure(message: "erster Abgleich fehlgeschlagen", location: "") }
        try expectEqual(count1, 1)
        let afterFirst = await svc.state()
        try expectEqual(afterFirst.tasks.map(\.title), ["Erste Fassung"])
        try expectEqual(afterFirst.tasks.first?.done, false)
        try expectEqual(afterFirst.notionTasksSync?.importedCount, 1)

        guard case .ok(let count2) = await svc.syncNotionTasks() else { throw CheckFailure(message: "zweiter Abgleich fehlgeschlagen", location: "") }
        try expectEqual(count2, 1)
        let afterSecond = await svc.state()
        try expectEqual(afterSecond.tasks.count, 1, "keine Dublette")
        try expectEqual(afterSecond.tasks.first?.title, "Zweite Fassung", "Titel aktualisiert")
        try expectEqual(afterSecond.tasks.first?.done, true, "erledigt übernommen")

        await svc.disconnectNotionTasks()
        let afterDisconnect = await svc.state()
        try expect(!afterDisconnect.notionTasksConnected && afterDisconnect.notionTasksSync == nil)
        try expectEqual(afterDisconnect.settings.notionTasksEnabled, false, "schaltet aus")
        try expectEqual(afterDisconnect.tasks.count, 1, "importierte Aufgabe bleibt lokal erhalten")
      },

      CheckCase("Abhaken synchron: verknüpfte Aufgabe setzt den Notion-Haken, unverknüpfte rührt Notion nicht an") {
        let dbId = String(repeating: "cc11", count: 8)
        var patchedChecked: [Bool] = []
        var getCalls = 0
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let row: JSONValue = ["id": "p1", "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Verknüpft"]]],
              "Erledigt": ["type": "checkbox", "checkbox": false],
            ]]
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
          }
          if req.httpMethod == "GET", url.hasSuffix("/v1/pages/p1") {
            getCalls += 1
            let row: JSONValue = ["id": "p1", "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Verknüpft"]]],
              "Erledigt": ["type": "checkbox", "checkbox": false],
            ]]
            return (200, Data(row.jsonString().utf8))
          }
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/p1") {
            if let v = body?["properties"]?["Erledigt"]?["checkbox"]?.boolValue { patchedChecked.append(v) }
            return (200, Data())
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let linkedId = await svc.state().tasks.first { $0.title == "Verknüpft" }?.id
        let linked = try expectNotNil(linkedId, "importierte Aufgabe")

        guard case .ok(let plain) = await svc.addTask(title: "Normale Aufgabe", notes: nil, due: nil) else {
          throw CheckFailure(message: "addTask fehlgeschlagen", location: "")
        }

        _ = await svc.completeTask(linked)
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await svc.reopenTask(linked)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try expectEqual(patchedChecked, [true, false], "Notion folgt dem Haken in Lumi")
        try expect(getCalls == 2, "liest die Checkbox-Eigenschaft bei jedem Schreiben neu (\(getCalls))")

        _ = await svc.completeTask(plain.id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try expectEqual(patchedChecked, [true, false], "unverknüpfte Aufgabe rührt Notion nicht an")
      },

      CheckCase("Zurückschreiben: lokal geänderter Titel geht als PATCH nach Notion, lokaler Wert bleibt") {
        let dbId = String(repeating: "ee55", count: 8)
        let stub = NotionWriteBackStub()
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let imported = await svc.state().tasks.first { $0.title == "Original" }?.id
        let id = try expectNotNil(imported, "importierte Aufgabe")
        _ = await svc.updateTask(id, TaskPatch(title: "Lokal"))
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 1, "ein PATCH")
        try expectEqual(stub.patches.first?["properties"]?["Name"]?["title"]?.arrayValue?.first?["text"]?["content"]?.stringValue,
                        "Lokal", "neuer Titel im PATCH")
        let local = await svc.state().tasks.first { $0.id == id }?.title
        try expectEqual(local, "Lokal", "lokaler Titel bleibt nach dem Abgleich")
      },

      CheckCase("Zurückschreiben: fehlgeschlagener PATCH überschreibt nicht, nächster Abgleich schreibt erneut") {
        let dbId = String(repeating: "ee66", count: 8)
        let stub = NotionWriteBackStub()
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let imported = await svc.state().tasks.first { $0.title == "Original" }?.id
        let id = try expectNotNil(imported, "importierte Aufgabe")
        _ = await svc.updateTask(id, TaskPatch(title: "Lokal"))
        stub.failPatch = true
        _ = await svc.syncNotionTasks()
        let failedError = await svc.state().notionTasksSync?.lastError
        try expect(failedError != nil, "Fehlertext im Sync-Status")
        let afterFail = await svc.state().tasks.first { $0.id == id }?.title
        try expectEqual(afterFail, "Lokal", "kein Überschreiben nach Fehlschlag")
        stub.failPatch = false
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 2, "zweiter Versuch im nächsten Abgleich")
        try expectEqual(stub.title, "Lokal", "Notion hat den lokalen Titel übernommen")
        let finalState = await svc.state()
        try expectEqual(finalState.tasks.first { $0.id == id }?.title, "Lokal", "lokaler Titel bleibt")
        try expect(finalState.notionTasksSync?.lastError == nil, "Fehler nach Erfolg gelöscht")
      },

      CheckCase("Zurückschreiben: hat Notion denselben Titel seither geändert, gewinnt Notion") {
        let dbId = String(repeating: "ee77", count: 8)
        let stub = NotionWriteBackStub()
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let imported = await svc.state().tasks.first { $0.title == "Original" }?.id
        let id = try expectNotNil(imported, "importierte Aufgabe")
        _ = await svc.updateTask(id, TaskPatch(title: "Lokal"))
        stub.title = "In Notion geändert"
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 0, "kein PATCH, Notion gewinnt")
        let afterNotion = await svc.state().tasks.first { $0.id == id }?.title
        try expectEqual(afterNotion, "In Notion geändert", "Notion-Titel übernommen")
      },

      CheckCase("Zurückschreiben: zwei Datums-Eigenschaften, geschrieben wird nur die importierte") {
        let dbId = String(repeating: "eea1", count: 8)
        let stub = NotionWriteBackStub()
        stub.dates = ["Anlage": .object(["start": .string("2026-10-01")]),
                      "Frist": .object(["start": .string("2026-10-09")])]
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        let id = try await importStubPage(stub, dbId: dbId, svc: svc)
        _ = await svc.updateTask(id, TaskPatch(due: "2026-10-20"))
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 1, "ein PATCH")
        let keys = (stub.patches.first?["properties"]?.objectValue ?? [:]).keys.sorted()
        try expectEqual(keys, ["Anlage"], "nur die importierte Datums-Eigenschaft im PATCH")
        try expectEqual(stub.dates["Frist"]?["start"]?.stringValue, "2026-10-09", "andere Datums-Eigenschaft unverändert")
      },

      CheckCase("Zurückschreiben: nur Fälligkeit geändert, Titel steht nicht im PATCH") {
        let dbId = String(repeating: "eea2", count: 8)
        let stub = NotionWriteBackStub()
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        let id = try await importStubPage(stub, dbId: dbId, svc: svc)
        _ = await svc.updateTask(id, TaskPatch(due: "2026-10-20"))
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 1, "ein PATCH")
        let keys = (stub.patches.first?["properties"]?.objectValue ?? [:]).keys.sorted()
        try expectEqual(keys, ["Datum"], "kein Titel (Name) im PATCH")
        try expectEqual(stub.dates["Datum"]?["start"]?.stringValue, "2026-10-20", "neue Fälligkeit in Notion")
      },

      CheckCase("Zurückschreiben: Datumsbereich – Ende bleibt nach neuem Start, sonst null; Zeitzone bleibt") {
        let dbId = String(repeating: "eea3", count: 8)
        let stub = NotionWriteBackStub()
        stub.dates = ["Datum": .object(["start": .string("2026-10-01"), "end": .string("2026-10-05"),
                                        "time_zone": .string("Europe/Berlin")])]
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        let id = try await importStubPage(stub, dbId: dbId, svc: svc)
        _ = await svc.updateTask(id, TaskPatch(due: "2026-10-03"))
        _ = await svc.syncNotionTasks()
        let kept = stub.patches.last?["properties"]?["Datum"]?["date"]
        try expectEqual(kept?["start"]?.stringValue, "2026-10-03", "neuer Start")
        try expectEqual(kept?["end"]?.stringValue, "2026-10-05", "Ende liegt nach dem neuen Start und bleibt")
        try expectEqual(kept?["time_zone"]?.stringValue, "Europe/Berlin", "Zeitzone bleibt")
        _ = await svc.updateTask(id, TaskPatch(due: "2026-10-09"))
        _ = await svc.syncNotionTasks()
        let dropped = stub.patches.last?["properties"]?["Datum"]?["date"]
        try expectEqual(dropped?["start"]?.stringValue, "2026-10-09", "neuer Start")
        try expect(dropped?["end"] == JSONValue.null, "Ende liegt vor dem neuen Start und wird gelöscht")
      },

      CheckCase("Zurückschreiben: lokale Änderung vor einem Neustart geht nach dem Neustart noch als PATCH raus") {
        let dbId = String(repeating: "eea4", count: 8)
        let stub = NotionWriteBackStub()
        let path = FileManager.default.temporaryDirectory
          .appendingPathComponent("taby-notion-restart-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (first, _) = try rig(session: stub.session(dbId: dbId), databasePath: path)
        let id = try await importStubPage(stub, dbId: dbId, svc: first)
        _ = await first.updateTask(id, TaskPatch(title: "Lokal"))
        // Neustart: neuer Dienst auf derselben Datenbank; vor dem Neustart wurde nicht abgeglichen.
        let (second, _) = try rig(session: stub.session(dbId: dbId), databasePath: path)
        _ = await second.connectNotionTasks(token: "tok")
        _ = await second.syncNotionTasks()
        try expectEqual(stub.patches.count, 1, "ein PATCH nach dem Neustart")
        try expectEqual(stub.title, "Lokal", "Notion hat die lokale Änderung übernommen")
      },

      CheckCase("OAuth: Rückruf-Code wird gegen ein Token getauscht und verbindet") {
        var sentAuth: String?
        var sentBody: JSONValue?
        let session = NotionTaskStubURLProtocol.session { req, body in
          if req.httpMethod == "POST", req.url!.absoluteString.hasSuffix("/v1/oauth/token") {
            sentAuth = req.value(forHTTPHeaderField: "Authorization")
            sentBody = body
            return (200, Data(JSONValue.object(["access_token": "oauth-tok-123", "token_type": "bearer"]).jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session, oauthClientSecret: "my-secret")
        let before = await svc.state().notionTasksConnected
        try expect(!before, "noch nicht verbunden")
        let r = await svc.completeNotionOAuth(code: "abc123")
        try expect(r.isOk, "Token-Austausch erfolgreich: \(r.errorMessage ?? "")")
        let after = await svc.state().notionTasksConnected
        try expect(after, "nach Austausch verbunden")
        let expectedAuth = "Basic " + Data("\(NotionOAuthConfig.clientId):my-secret".utf8).base64EncodedString()
        try expectEqual(sentAuth, expectedAuth, "Client-ID/Secret per Basic-Auth gesendet")
        try expectEqual(sentBody?["code"]?.stringValue, "abc123")
        try expectEqual(sentBody?["redirect_uri"]?.stringValue, NotionOAuthConfig.redirectUri)
      },

      CheckCase("OAuth: eingefügte Adresse oder nackter Code wird zum Code, Fehler und Freitext nicht") {
        try expectEqual(NotionOAuthConfig.code(fromPasted: "https://notion-callback?code=abc&state=x"), "abc")
        try expectEqual(NotionOAuthConfig.code(fromPasted: "  https://notion-callback?code=abc&state=x\n"), "abc")
        try expectEqual(NotionOAuthConfig.code(fromPasted: "abc123"), "abc123")
        try expectEqual(NotionOAuthConfig.code(fromPasted: "https://notion-callback?error=access_denied"), nil)
        try expectEqual(NotionOAuthConfig.code(fromPasted: ""), nil)
        try expectEqual(NotionOAuthConfig.code(fromPasted: "hallo welt"), nil)
        let url = NotionOAuthConfig.makeAuthorizeURL()
        try expect(url.absoluteString.contains("redirect_uri=https"), "Anmelde-URL trägt den https-Rückruf")
      },

      CheckCase("OAuth: state wird geprüft, nur einmal verwendbar, fremder Rückruf wird abgelehnt") {
        func state(of url: URL) -> String? {
          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        }
        let url = NotionOAuthConfig.makeAuthorizeURL()
        let s = try expectNotNil(state(of: url), "state in der Anmelde-URL")
        try expect(s.count >= 32, "state ist zufällig und lang")
        try expectEqual(try NotionOAuthConfig.verifiedCode(fromPasted: "https://notion-callback?code=abc&state=\(s)"), "abc")
        // Einmalig: derselbe Rückruf ein zweites Mal wird abgelehnt.
        try await expectThrows { _ = try NotionOAuthConfig.verifiedCode(fromPasted: "https://notion-callback?code=abc&state=\(s)") }
        // Fremder state, fehlender state und nackter Code werden abgelehnt.
        _ = NotionOAuthConfig.makeAuthorizeURL()
        try await expectThrows { _ = try NotionOAuthConfig.verifiedCode(fromPasted: "https://notion-callback?code=abc&state=fremd") }
        _ = NotionOAuthConfig.makeAuthorizeURL()
        try await expectThrows { _ = try NotionOAuthConfig.verifiedCode(fromPasted: "https://notion-callback?code=abc") }
        try await expectThrows { _ = try NotionOAuthConfig.verifiedCode(fromPasted: "abc123") }
      },

      CheckCase("OAuth: ohne Client-Secret im Schlüsselbund klare Fehlermeldung, nicht verbunden") {
        let (svc, _) = try rig()
        let r = await svc.completeNotionOAuth(code: "abc123")
        try expect(!r.isOk, "ohne Secret kein Erfolg")
        let connected = await svc.state().notionTasksConnected
        try expect(!connected)
      },

      CheckCase("Quelle anlegen: \"+ Quelle hinzufügen\" legt eine leere Zeile an (kein Link-Zwang)") {
        let (svc, _) = try rig()
        let r = await svc.addNotionSource(name: "Neue Quelle", category: .tickets, link: "")
        guard case .ok(let s) = r else { throw CheckFailure(message: "addNotionSource mit leerem Link schlägt fehl", location: "") }
        try expectEqual(s.link, "")
        let sources = await svc.state().notionSources
        try expectEqual(sources.map(\.id), [s.id], "Quelle erscheint sofort in der Liste")
      },

      CheckCase("Quelle modular benennen: Link einfügen übernimmt den Notion-Titel, solange der Name noch Platzhalter ist") {
        let pageId = String(repeating: "aa22", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/pages/\(pageId)") {
            let page: JSONValue = ["id": .string(pageId), "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Persönliche To-dos"]]],
            ]]
            return (200, Data(page.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        guard case .ok(let created) = await svc.addNotionSource(name: "Neue Quelle", category: .todos, link: "") else {
          throw CheckFailure(message: "addNotionSource fehlgeschlagen", location: "")
        }
        guard case .ok(let updated) = await svc.updateNotionSource(created.id, name: nil, category: nil, link: pageId) else {
          throw CheckFailure(message: "updateNotionSource fehlgeschlagen", location: "")
        }
        try expectEqual(updated.name, "Persönliche To-dos", "Name kommt automatisch vom Notion-Seitentitel")

        // Ein eigener Name bleibt erhalten und wird nicht überschrieben.
        _ = try? await svc.updateNotionSource(created.id, name: "Mein eigener Name", category: nil, link: nil)
        guard case .ok(let untouched) = await svc.updateNotionSource(created.id, name: nil, category: nil, link: pageId) else {
          throw CheckFailure(message: "updateNotionSource fehlgeschlagen", location: "")
        }
        try expectEqual(untouched.name, "Mein eigener Name", "eigener Name wird nicht überschrieben")
      },

      CheckCase("Wochen-Seite mit eingebetteter Datenbank: deren Zeilen werden als Aufgaben importiert") {
        let pageId = String(repeating: "ab12", count: 8)
        let dbId = String(repeating: "ab34", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/\(pageId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": .string(dbId), "type": "child_database", "has_children": false, "child_database": ["title": "Wochen"]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let row: JSONValue = ["id": "w1", "properties": [
              "Name": ["type": "title", "title": [["plain_text": "KW 41"]]],
            ]]
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Wochen", category: .weekly, link: pageId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        guard case .ok(let count) = await svc.syncNotionTasks() else {
          throw CheckFailure(message: "Abgleich der Wochen-Seite fehlgeschlagen", location: "")
        }
        try expectEqual(count, 1)
        let state = await svc.state()
        try expectEqual(state.tasks.map(\.title), ["KW 41"])
        try expectEqual(state.notionTaskGroups.values.sorted(), ["KW 41"], "Zeile ist immer Aufgabe, Woche = Titel ohne Datum")
      },

      CheckCase("Ticket-Quelle, die eine Seite ist: Datenbank-Lesen scheitert, To-dos der Seite werden gelesen, Name kommt von der Seite") {
        let pageId = String(repeating: "ef56", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/\(pageId)") {
            let err: JSONValue = ["object": "error", "message": "Provided database_id is a page, not a database."]
            return (400, Data(err.jsonString().utf8))
          }
          if url.hasSuffix("/v1/pages/\(pageId)") {
            let page: JSONValue = ["id": .string(pageId), "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Drucker-Liste"]]],
            ]]
            return (200, Data(page.jsonString().utf8))
          }
          if url.contains("/v1/blocks/\(pageId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "t1", "type": "to_do", "has_children": false,
               "to_do": ["checked": false, "rich_text": [["plain_text": "Drucker reparieren"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Neue Quelle", category: .tickets, link: pageId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        let r = await svc.syncNotionTasks()
        try expect(r.isOk, "Abgleich ohne Fehler: \(r.errorMessage ?? "")")
        let state = await svc.state()
        try expectEqual(state.tasks.map(\.title), ["Drucker reparieren"])
        try expectEqual(state.notionSources.first?.name, "Drucker-Liste", "Name per Seiten-Titel")
      },

      CheckCase("Abhaken bei eingebetteter Datenbank-Zeile: Block-PATCH scheitert, Seiten-PATCH setzt den Haken") {
        let pageId = String(repeating: "cd78", count: 8)
        let dbId = String(repeating: "cd90", count: 8)
        let rowId = String(repeating: "dd33", count: 8)
        var pagePatches: [Bool] = []
        var blockPatches = 0
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/\(pageId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": .string(dbId), "type": "child_database", "has_children": false, "child_database": ["title": "Zeilen"]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let row: JSONValue = ["id": .string(rowId), "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Zeile"]]],
              "Erledigt": ["type": "checkbox", "checkbox": false],
            ]]
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
          }
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/blocks/\(rowId)") {
            blockPatches += 1
            let err: JSONValue = ["object": "error", "message": "Provided block_id is a page, not a block."]
            return (400, Data(err.jsonString().utf8))
          }
          if req.httpMethod == "GET", url.hasSuffix("/v1/pages/\(rowId)") {
            let row: JSONValue = ["id": .string(rowId), "properties": [
              "Erledigt": ["type": "checkbox", "checkbox": false],
            ]]
            return (200, Data(row.jsonString().utf8))
          }
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/\(rowId)") {
            if let v = body?["properties"]?["Erledigt"]?["checkbox"]?.boolValue { pagePatches.append(v) }
            return (200, Data())
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Aufgaben", category: .todos, link: pageId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let rows = await svc.state().tasks
        let linked = try expectNotNil(rows.first { $0.title == "Zeile" }?.id, "importierte Zeile")

        _ = await svc.completeTask(linked)
        try? await Task.sleep(nanoseconds: 200_000_000)
        try expectEqual(blockPatches, 1, "Block-Weg zuerst versucht")
        try expectEqual(pagePatches, [true], "Seiten-Weg setzt den Haken der Zeile")
      },

      CheckCase("Wochen-Seite mit Unterseiten: To-dos je Unterseite werden nach Woche gruppiert") {
        let pageId = String(repeating: "ab12", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/\(pageId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "cd41", "type": "child_page", "has_children": true, "child_page": ["title": "KW 41"]],
              ["id": "cd42", "type": "child_page", "has_children": true, "child_page": ["title": "KW 42"]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.contains("/v1/blocks/cd41/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "t41", "type": "to_do", "has_children": false,
               "to_do": ["checked": false, "rich_text": [["plain_text": "Angebot schreiben"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.contains("/v1/blocks/cd42/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "t42", "type": "to_do", "has_children": false,
               "to_do": ["checked": true, "rich_text": [["plain_text": "Review halten"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Wochen", category: .weekly, link: pageId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        guard case .ok(let count) = await svc.syncNotionTasks() else {
          throw CheckFailure(message: "Abgleich der Wochen-Seite fehlgeschlagen", location: "")
        }
        // Je Unterseite: die Seite selbst (Titel = Woche) plus ihr To-do.
        try expectEqual(count, 4)
        let state = await svc.state()
        let groups = state.tasks.reduce(into: [String: String]()) { $0[$1.title] = state.notionTaskGroups[$1.id] }
        try expectEqual(groups, ["KW 41": "KW 41", "KW 42": "KW 42", "Angebot schreiben": "KW 41", "Review halten": "KW 42"])
        let page41 = state.tasks.first { $0.title == "KW 41" }
        try expect(page41?.notes?.contains("Angebot schreiben") == true, "Unterseite trägt ihren Inhalt als Notiz")
      },

      CheckCase("Wochen-Seite mit eingebetteter Datenbank: To-dos je Zeile werden nach Woche gruppiert") {
        let pageId = String(repeating: "ab56", count: 8)
        let dbId = String(repeating: "ab78", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/\(pageId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": .string(dbId), "type": "child_database", "has_children": false, "child_database": ["title": "Wochen"]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let rows: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "r41", "properties": ["Name": ["type": "title", "title": [["plain_text": "KW 41"]]]]],
              ["id": "r42", "properties": ["Name": ["type": "title", "title": [["plain_text": "KW 42"]]]]],
            ]]
            return (200, Data(rows.jsonString().utf8))
          }
          if url.contains("/v1/blocks/r41/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "t41", "type": "to_do", "has_children": false,
               "to_do": ["checked": false, "rich_text": [["plain_text": "Protokoll"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          if url.contains("/v1/blocks/r42/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "t42", "type": "to_do", "has_children": false,
               "to_do": ["checked": false, "rich_text": [["plain_text": "Slides"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Wochen", category: .weekly, link: pageId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        guard case .ok(let count) = await svc.syncNotionTasks() else {
          throw CheckFailure(message: "Abgleich der Wochen-Datenbank fehlgeschlagen", location: "")
        }
        // Je Zeile: die Zeile selbst (Titel = Woche) plus ihr To-do.
        try expectEqual(count, 4)
        let state = await svc.state()
        let groups = state.tasks.reduce(into: [String: String]()) { $0[$1.title] = state.notionTaskGroups[$1.id] }
        try expectEqual(groups, ["KW 41": "KW 41", "KW 42": "KW 42", "Protokoll": "KW 41", "Slides": "KW 42"])
      },

      CheckCase("Quelle: leere Block-Liste auf einer Datenbank-ID fällt auf die Datenbank-Lesart zurück") {
        let dbId = String(repeating: "fb34", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/\(dbId)/children") {
            return (200, Data(JSONValue.object(["object": "list", "results": [], "has_more": false]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let rows: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "tk1", "properties": ["Name": ["type": "title", "title": [["plain_text": "Drucker reparieren"]]]]],
            ]]
            return (200, Data(rows.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "To-dos", category: .todos, link: dbId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        guard case .ok(let count) = await svc.syncNotionTasks() else {
          throw CheckFailure(message: "Abgleich mit leerer Block-Liste fehlgeschlagen", location: "")
        }
        try expectEqual(count, 1)
        let titles = await svc.state().tasks.map(\.title)
        try expectEqual(titles, ["Drucker reparieren"])
      },

      CheckCase("Wochen-Datenbank: leere Block-Liste, Zeilen mit Datum werden je Woche mit Titel und Inhalt importiert") {
        let dbId = String(repeating: "fa12", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          // Verknüpfte Datenbank: /blocks/…/children liefert eine leere Liste (200), kein Fehler.
          if url.contains("/v1/blocks/\(dbId)/children") {
            return (200, Data(JSONValue.object(["object": "list", "results": [], "has_more": false]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let rows: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "wk1", "properties": [
                "Name": ["type": "title", "title": [["plain_text": "Weekly 1:1"]]],
                "Datum": ["type": "date", "date": ["start": "2026-10-13"]],
                "Core Task completed": ["type": "checkbox", "checkbox": false]]],
              ["id": "wk2", "properties": [
                "Name": ["type": "title", "title": [["plain_text": "Weekly 1:1"]]],
                "Datum": ["type": "date", "date": ["start": "2026-10-08"]],
                "Core Task completed": ["type": "checkbox", "checkbox": false]]],
            ]]
            return (200, Data(rows.jsonString().utf8))
          }
          // Jede Zeilen-Seite: Überschrift, To-do und Toggle mit Inhalt (eigene Block-IDs je Zeile).
          for (row, todo) in [("wk1", "td1"), ("wk2", "td2")] where url.contains("/v1/blocks/\(row)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": .string("h\(row)"), "type": "heading_2", "has_children": false,
               "heading_2": ["rich_text": [["plain_text": "Core Task"]]]],
              ["id": .string(todo), "type": "to_do", "has_children": false,
               "to_do": ["checked": false, "rich_text": [["plain_text": "Locale AI + Hermes Agenten ?"]]]],
              ["id": .string("g\(row)"), "type": "toggle", "has_children": false,
               "toggle": ["rich_text": [["plain_text": "Notion / Langdock KI / Claude"]]]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Wochen", category: .weekly, link: dbId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        guard case .ok(let count) = await svc.syncNotionTasks() else {
          throw CheckFailure(message: "Abgleich der Wochen-Datenbank fehlgeschlagen", location: "")
        }
        try expectEqual(count, 4)
        let state = await svc.state()
        let groups = Set(state.notionTaskGroups.values)
        try expectEqual(groups, ["2026-10-13 · Weekly 1:1", "2026-10-08 · Weekly 1:1"])
        for week in ["2026-10-13 · Weekly 1:1", "2026-10-08 · Weekly 1:1"] {
          let inWeek = state.tasks.filter { state.notionTaskGroups[$0.id] == week }
          try expectEqual(inWeek.count, 2, "Zeile + To-do in \(week)")
          let row = inWeek.first { $0.title == "Weekly 1:1" }
          try expect(row?.notes?.contains("Core Task") == true, "Zeile trägt Überschrift als Notiz (\(week))")
          try expect(row?.notes?.contains("Notion / Langdock") == true, "Zeile trägt Toggle als Notiz (\(week))")
          try expect(inWeek.contains { $0.title == "Locale AI + Hermes Agenten ?" }, "To-do in \(week)")
        }
      },

      CheckCase("Verknüpfte Ansicht: ohne Datenquelle klare Meldung statt stummem Fehler") {
        for category in [NotionSourceCategory.tickets, .weekly] {
          let id = String(repeating: "ef90", count: 8)
          let session = NotionTaskStubURLProtocol.session { req, _ in
            let url = req.url!.absoluteString
            if url.hasSuffix("/v1/databases/\(id)") {
              return (200, Data(JSONValue.object(["object": "database", "data_sources": []]).jsonString().utf8))
            }
            if url.contains("/v1/blocks/\(id)/children") {
              let err: JSONValue = ["object": "error", "message": "Block not found"]
              return (400, Data(err.jsonString().utf8))
            }
            return (404, Data())
          }
          let (svc, _) = try rig(session: session)
          _ = await svc.connectNotionTasks(token: "tok")
          _ = await svc.addNotionSource(name: "Ansicht", category: category, link: id)
          _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
          let r = await svc.syncNotionTasks()
          try expect(!r.isOk, "Abgleich (\(category)) muss scheitern")
          try expect(r.errorMessage?.contains("verknüpfte Ansicht") == true,
                     "Meldung nennt die verknüpfte Ansicht (\(category)): \(r.errorMessage ?? "")")
        }
      },

      CheckCase("Ticket-Inhalt: Seiteninhalt wird Notizen, Änderung zieht nach, Seiten-ID zum Öffnen") {
        let dbId = String(repeating: "dd22", count: 8)
        let rowId = String(repeating: "ee33", count: 8)
        var paragraph = "Toner tauschen"
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            let row: JSONValue = ["id": .string(rowId), "properties": [
              "Name": ["type": "title", "title": [["plain_text": "Drucker"]]],
              "Erledigt": ["type": "checkbox", "checkbox": false],
            ]]
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
          }
          if url.contains("/v1/blocks/\(rowId)/children") {
            let blocks: JSONValue = ["object": "list", "has_more": false, "results": [
              ["id": "b1", "type": "paragraph", "has_children": false,
               "paragraph": ["rich_text": [["plain_text": .string(paragraph)]]]],
              ["id": "b2", "type": "to_do", "has_children": false,
               "to_do": ["rich_text": [["plain_text": "Testdruck"]], "checked": false]],
            ]]
            return (200, Data(blocks.jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true, notionTasksDatabaseId: dbId), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let first = await svc.state()
        let task = try expectNotNil(first.tasks.first { $0.title == "Drucker" }, "Ticket importiert")
        let notes1 = task.notes ?? ""
        try expect(notes1.contains("Toner tauschen") && notes1.contains("☐ Testdruck"), "Inhalt als Notizen: \(notes1)")
        try expectEqual(first.notionTaskPages[task.id], rowId, "Seiten-ID zum Öffnen in Notion")

        paragraph = "Toner gewechselt"
        _ = await svc.syncNotionTasks()
        let second = await svc.state()
        let notes2 = second.tasks.first { $0.id == task.id }?.notes ?? ""
        try expect(notes2.contains("Toner gewechselt"), "zweiter Abgleich zieht Änderung nach: \(notes2)")
        try expectEqual(second.tasks.count, 1, "keine Dublette")
      },

      CheckCase("Auto-Name: Notion-Platzhalter „Untitled“ benennt die Quelle nicht um") {
        let dbId = String(repeating: "ab12", count: 8)
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/\(dbId)") {
            return (200, Data(JSONValue.object(["object": "database", "title": [["plain_text": "Untitled"]],
                                                "data_sources": [["id": "ds"]]]).jsonString().utf8))
          }
          if url.hasSuffix("/v1/data_sources/ds/query") {
            return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": []]).jsonString().utf8))
          }
          return (404, Data())
        }
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Neue Quelle", category: .tickets, link: dbId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        _ = await svc.syncNotionTasks()
        let names = await svc.state().notionSources.map(\.name)
        try expectEqual(names, ["Neue Quelle"], "Platzhalter-Titel wird nicht übernommen")
        try expectEqual(CoreServices.usableNotionTitle("  UNBENANNT "), nil)
        try expectEqual(CoreServices.usableNotionTitle("Ohne Titel"), nil)
        try expectEqual(CoreServices.usableNotionTitle(""), nil)
        try expectEqual(CoreServices.usableNotionTitle(" Angebot "), "Angebot")
      },

      CheckCase("Ticket-Meta: Erstellzeit, Ersteller und Status kommen aus der Zeile, Benutzer nur einmal abgefragt") {
        let dbId = String(repeating: "dd11", count: 8)
        var userCalls = 0
        let session = Self.ticketSession(dbId: dbId, userStatus: 200, onUserCall: { userCalls += 1 })
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Neue Quelle", category: .tickets, link: dbId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        let r = await svc.syncNotionTasks()
        try expect(r.isOk, "Abgleich ok")
        let state = await svc.state()
        guard let taskId = state.tasks.first(where: { $0.title == "Ticket A" })?.id else {
          throw CheckFailure(message: "Ticket A fehlt", location: "")
        }
        let meta = state.notionTaskMeta[taskId]
        try expectEqual(meta?.createdBy, "Thomas")
        try expectEqual(meta?.status, "In Bearbeitung")
        // Erwartung über dieselbe Umrechnung wie der Import: unabhängig von der Zeitzone des Rechners.
        try expectEqual(meta?.createdAt, CalendarSupport.localFromISO("2026-10-09T12:00:00.000Z"), "Erstellzeit aus created_time")
        try expectEqual(state.notionTaskMeta.count, 2, "beide Tickets haben Meta")
        try expectEqual(userCalls, 1, "zwei Zeilen desselben Erstellers = eine Anfrage")
      },

      CheckCase("Ticket-Meta: ohne Berechtigung „Benutzerinformationen lesen“ fehlt nur der Name") {
        let dbId = String(repeating: "ee55", count: 8)
        let session = Self.ticketSession(dbId: dbId, userStatus: 403, onUserCall: {})
        let (svc, _) = try rig(session: session)
        _ = await svc.connectNotionTasks(token: "tok")
        _ = await svc.addNotionSource(name: "Neue Quelle", category: .tickets, link: dbId)
        _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
        let r = await svc.syncNotionTasks()
        try expect(r.isOk, "Abgleich trotz 403 ok")
        let state = await svc.state()
        guard let taskId = state.tasks.first(where: { $0.title == "Ticket A" })?.id else {
          throw CheckFailure(message: "Ticket A fehlt", location: "")
        }
        let meta = state.notionTaskMeta[taskId]
        try expect(meta?.createdBy == nil, "ohne Name")
        try expectEqual(meta?.status, "In Bearbeitung")
        try expect(meta?.createdAt != nil, "Erstellzeit bleibt")
      },

      CheckCase("Zurückschreiben scheitert, Notion ändert Fälligkeit: nächster Abgleich schreibt den lokalen Titel erneut") {
        let dbId = String(repeating: "eea9", count: 8)
        let stub = NotionWriteBackStub()
        let (svc, _) = try rig(session: stub.session(dbId: dbId))
        let id = try await importStubPage(stub, dbId: dbId, svc: svc)
        _ = await svc.updateTask(id, TaskPatch(title: "Lokal"))
        stub.failPatch = true
        stub.dates["Datum"] = .object(["start": .string("2026-10-30")])  // Notion ändert ein anderes Feld
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 1, "ein fehlgeschlagener PATCH")
        stub.failPatch = false
        _ = await svc.syncNotionTasks()
        try expectEqual(stub.patches.count, 2, "erneuter PATCH im nächsten Abgleich")
        try expectEqual(stub.title, "Lokal", "lokaler Titel landet in Notion")
      },
    ])
  }
}
