// Prüfungen für NotionTaskSource: Feld-Erkennung per Typ, Seiten-To-dos
// (rekursiv), Abgleichsplan. HTTP über ein eigenes gestubbtes URLProtocol,
// kein echtes Netz.
import Foundation

private func notionJSON(_ v: JSONValue) -> Data { Data(v.jsonString().utf8) }

private func anyJSON(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v)) ?? Data() }

/// Schema einer Tickets-Datenbank: Status „Status“ mit Gruppen „To-do“ / „In progress“ / „Complete“.
private let statusSchemaJSON = #"""
{"object":"data_source","properties":{"Name":{"type":"title","title":{}},"Status":{"id":"s1","type":"status","status":{"options":[{"id":"o-todo","name":"Not started","color":"default"},{"id":"o-prog","name":"In Arbeit","color":"blue"},{"id":"o-done","name":"Done","color":"green"}],"groups":[{"id":"g1","name":"To-do","color":"gray","option_ids":["o-todo"]},{"id":"g2","name":"In progress","color":"blue","option_ids":["o-prog"]},{"id":"g3","name":"Complete","color":"green","option_ids":["o-done"]}]}}}}
"""#

/// Zeile mit Status-Eigenschaft (keine Checkbox).
private func statusRow(_ id: String, title: String, optionId: String, name: String) -> [String: Any] {
  ["id": id, "created_time": "2026-10-09T12:00:00.000Z",
   "properties": [
     "Name": ["type": "title", "title": [["plain_text": title]]],
     "Status": ["id": "s1", "type": "status", "status": ["id": optionId, "name": name]],
   ]]
}

/// Gestubbtes HTTP nur für diese Prüfungen (eigenes Protokoll, damit es nicht
/// mit `CalendarStubURLProtocol` kollidiert, falls beide je Prüfung gebraucht würden).
final class NotionTaskStubURLProtocol: URLProtocol {
  /// `JSONValue?` ist der dekodierte POST-Body (Query-Anfragen), sonst nil.
  typealias Handler = (URLRequest, JSONValue?) -> (Int, Data)
  private static let lock = NSLock()
  private static var handler: Handler?

  static func session(_ handler: @escaping Handler) -> URLSession {
    lock.withLock { self.handler = handler }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [NotionTaskStubURLProtocol.self]
    return URLSession(configuration: cfg)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var bodyData = request.httpBody
    if bodyData == nil, let stream = request.httpBodyStream {
      stream.open()
      var d = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        d.append(contentsOf: buf[0..<n])
      }
      stream.close()
      bodyData = d
    }
    let body = bodyData.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    let h = Self.lock.withLock { Self.handler }
    let (status, data) = h?(request, body) ?? (404, Data())
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func notionTitleRow(_ id: String, title: String, done: Bool? = nil, due: String? = nil) -> JSONValue {
  var props: [String: JSONValue] = [
    "Name": ["type": "title", "title": [["plain_text": .string(title)]]],
  ]
  if let done { props["Erledigt"] = ["type": "checkbox", "checkbox": .bool(done)] }
  if let due { props["Fällig"] = ["type": "date", "date": ["start": .string(due)]] }
  return ["id": .string(id), "properties": .object(props)]
}

private func notionTodoBlock(_ id: String, text: String, checked: Bool, hasChildren: Bool = false) -> JSONValue {
  ["id": .string(id), "type": "to_do", "has_children": .bool(hasChildren),
   "to_do": ["rich_text": [["plain_text": .string(text)]], "checked": .bool(checked)]]
}

public enum NotionTaskChecks {
  @MainActor public static var suite: CheckSuite {
    CheckSuite("Notion-Aufgaben", [
      CheckCase("setPageChecked: liest die Seite, findet die Checkbox-Eigenschaft per Typ, setzt genau die") {
        var patchedBody: JSONValue?
        var getCalls = 0
        let session = NotionTaskStubURLProtocol.session { req, body in
          if req.httpMethod == "GET", req.url!.absoluteString.hasSuffix("/v1/pages/p1") {
            getCalls += 1
            return (200, notionJSON(notionTitleRow("p1", title: "X", done: false)))
          }
          if req.httpMethod == "PATCH", req.url!.absoluteString.hasSuffix("/v1/pages/p1") {
            patchedBody = body
            return (200, notionJSON(["object": "page", "id": "p1"]))
          }
          return (404, Data())
        }
        try await NotionTaskSource(token: "tok", session: session).setPageChecked("p1", checked: true)
        try expectEqual(getCalls, 1)
        try expectEqual(patchedBody?["properties"]?["Erledigt"]?["checkbox"], true)
      },
      CheckCase("setPageChecked: keine Checkbox-Eigenschaft → nichts wird geschrieben, kein Fehler") {
        var patched = false
        let session = NotionTaskStubURLProtocol.session { req, _ in
          if req.httpMethod == "GET" { return (200, notionJSON(notionTitleRow("p1", title: "X"))) }
          patched = true
          return (200, Data())
        }
        try await NotionTaskSource(token: "tok", session: session).setPageChecked("p1", checked: true)
        try expect(!patched, "nichts geschrieben ohne Checkbox-Feld")
      },
      CheckCase("setBlockChecked: PATCHt direkt den to_do-Block, kein vorheriges GET nötig") {
        var calls: [String] = []
        let session = NotionTaskStubURLProtocol.session { req, body in
          calls.append(req.httpMethod ?? "?")
          try! expectEqual(body?["to_do"]?["checked"], false)
          return (200, Data())
        }
        try await NotionTaskSource(token: "tok", session: session).setBlockChecked("b1", checked: false)
        try expectEqual(calls, ["PATCH"])
      },
      CheckCase("NotionId.extract: nackte ID, mit Bindestrichen, aus einer kompletten URL mit ?v=, ungültig") {
        try expectEqual(NotionId.extract("38bb2fa4b2be8079bac4d196f1551f85"), "38bb2fa4b2be8079bac4d196f1551f85")
        try expectEqual(NotionId.extract("38bb2fa4-b2be-8079-bac4-d196f1551f85"), "38bb2fa4b2be8079bac4d196f1551f85")
        try expectEqual(NotionId.extract(
          "https://www.notion.so/meinworkspace/Wochenplan-38bb2fa4b2be8079bac4d196f1551f85?v=d32b2fa4b2be83f2a0e788105447b154&pvs=4"),
          "38bb2fa4b2be8079bac4d196f1551f85")
        try expectEqual(NotionId.extract("  38bb2fa4b2be8079bac4d196f1551f85  \n"), "38bb2fa4b2be8079bac4d196f1551f85")
        try expect(NotionId.extract("") == nil)
        try expect(NotionId.extract("kein-link-hier") == nil)
      },
      CheckCase("toItem: Titel per Typ erkannt, Checkbox und Datum optional") {
        let full = NotionTaskSource.toItem(notionTitleRow("p1", title: "Angebot schreiben", done: true, due: "2026-10-20"))
        var expected = NotionTaskSource.Item(id: "p1", title: "Angebot schreiben", done: true, due: "2026-10-20")
        expected.writeKind = .page
        expected.dueProperty = "Fällig"
        try expectEqual(full, expected)
        let bare = NotionTaskSource.toItem(notionTitleRow("p2", title: "Ohne Status"))
        var expectedBare = NotionTaskSource.Item(id: "p2", title: "Ohne Status", done: false, due: nil)
        expectedBare.writeKind = .page
        try expectEqual(bare, expectedBare)
      },
      CheckCase("toItem: ohne Titel-Eigenschaft gibt es keine Aufgabe") {
        try expect(NotionTaskSource.toItem(["id": "p3", "properties": [:]]) == nil)
      },
      CheckCase("Abgleich: neue Einträge → create, geänderte verknüpfte → update, unveränderte → nichts") {
        let items = [
          NotionTaskSource.Item(id: "n1", title: "Neu", done: false),
          NotionTaskSource.Item(id: "n2", title: "Geändert", done: true, due: "2026-10-20"),
          NotionTaskSource.Item(id: "n3", title: "Gleich", done: false),
        ]
        let linked = ["n2": "t2", "n3": "t3"]
        let tasks = [
          "t2": TabyTask(id: "t2", title: "Alt", done: false, createdAt: "2026-10-01T09:00"),
          "t3": TabyTask(id: "t3", title: "Gleich", done: false, createdAt: "2026-10-01T09:00"),
        ]
        let plan = NotionTaskSource.plan(items: items, linked: linked, existingTasks: tasks)
        try expectEqual(plan.create, [items[0]])
        try expectEqual(plan.update, [NotionTaskSource.ToUpdate(notionId: "n2", taskId: "t2", item: items[1])])
      },
      CheckCase("Notizen: lokale Notiz bleibt, solange der Notion-Text seit dem letzten Abgleich gleich ist") {
        var task = TabyTask(id: "t1", title: "A", done: false, createdAt: "2026-10-01T09:00")
        task.notes = "lokal"
        let item = NotionTaskSource.Item(id: "n1", title: "A", done: false, body: "neu")
        let same = NotionTaskSource.plan(items: [item], linked: ["n1": "t1"], existingTasks: ["t1": task],
                                         lastBodyHash: ["n1": NotionTaskSource.textHash("neu")])
        try expectEqual(same.update, [], "Text unverändert: lokale Notiz bleibt")
        let unknown = NotionTaskSource.plan(items: [item], linked: ["n1": "t1"], existingTasks: ["t1": task])
        try expectEqual(unknown.update, [], "ohne gemerkten Hash: lokale Notiz bleibt")
      },
      CheckCase("Notizen: Notion-Text seit dem letzten Abgleich geändert → übernehmen") {
        var task = TabyTask(id: "t1", title: "A", done: false, createdAt: "2026-10-01T09:00")
        task.notes = "lokal"
        let item = NotionTaskSource.Item(id: "n1", title: "A", done: false, body: "neu")
        let plan = NotionTaskSource.plan(items: [item], linked: ["n1": "t1"], existingTasks: ["t1": task],
                                         lastBodyHash: ["n1": NotionTaskSource.textHash("alt")])
        try expectEqual(plan.update.map(\.takeNotes), [true])
      },
      CheckCase("Abgleich: Verknüpfung ohne noch vorhandene Aufgabe (lokal gelöscht) wird wie neu behandelt") {
        let item = NotionTaskSource.Item(id: "n1", title: "Wieder da", done: false)
        let plan = NotionTaskSource.plan(items: [item], linked: ["n1": "weg"], existingTasks: [:])
        try expectEqual(plan.create, [item])
        try expect(plan.update.isEmpty)
      },
      CheckCase("fetchDatabase: Discovery, paginierte Query, Zeilen ohne Titel fallen weg") {
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/db-1") {
            return (200, notionJSON(["object": "database", "data_sources": [["id": "ds-1"]]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-1/query") {
            if body?["start_cursor"] == nil {
              return (200, notionJSON(["object": "list", "has_more": true, "next_cursor": "c2", "results": [
                notionTitleRow("p1", title: "Erste", done: false),
                ["id": "p-leer", "properties": [:]],
              ]]))
            }
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              notionTitleRow("p2", title: "Zweite", done: true, due: "2026-11-01"),
            ]]))
          }
          return (404, notionJSON(["object": "error", "message": "unbekannt"]))
        }
        let items = try await NotionTaskSource(token: "tok", session: session).fetchDatabase("db-1")
        try expectEqual(items.map(\.id), ["p1", "p2"])
        try expectEqual(items[1].done, true)
        try expectEqual(items[1].due, "2026-11-01")
      },
      CheckCase("fetchPageTodos: nur to_do-Blöcke, rekursiv in verschachtelte Kinder") {
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/page-1/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              notionTodoBlock("b1", text: "Oben", checked: false),
              ["id": "b2", "type": "paragraph", "has_children": false],
              notionTodoBlock("b3", text: "Hat Kinder", checked: false, hasChildren: true),
            ]]))
          }
          if url.contains("/v1/blocks/b3/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              notionTodoBlock("b3-1", text: "Verschachtelt", checked: true),
            ]]))
          }
          return (404, notionJSON(["object": "error", "message": "unbekannt"]))
        }
        let items = try await NotionTaskSource(token: "tok", session: session).fetchPageTodos("page-1")
        try expectEqual(Set(items.map(\.id)), ["b1", "b3", "b3-1"])
        try expect(items.first { $0.id == "b3-1" }?.done == true)
      },

      CheckCase("Ticket-Text: Blöcke werden zu Zeilen (Absatz, Überschrift, Listen, To-do, Zitat, Trenner)") {
        func rich(_ t: String) -> JSONValue { ["rich_text": [["plain_text": .string(t)]]] }
        func block(_ type: String, _ payload: JSONValue) -> JSONValue { ["type": .string(type), type: payload] }
        try expectEqual(NotionTaskSource.blockLine(block("paragraph", rich("Toner tauschen")), number: 0), "Toner tauschen")
        try expectEqual(NotionTaskSource.blockLine(block("bulleted_list_item", rich("Treiber")), number: 0), "• Treiber")
        try expectEqual(NotionTaskSource.blockLine(block("numbered_list_item", rich("Schritt")), number: 2), "2. Schritt")
        try expectEqual(NotionTaskSource.blockLine(block("heading_1", rich("Ziel")), number: 0), "# Ziel")
        try expectEqual(NotionTaskSource.blockLine(block("heading_2", rich("Aufgaben")), number: 0), "## Aufgaben")
        try expectEqual(NotionTaskSource.blockLine(block("heading_3", rich("Details")), number: 0), "### Details")
        try expectEqual(NotionTaskSource.blockLine(block("heading_4", rich("Notizen")), number: 0), "### Notizen")
        try expectEqual(NotionTaskSource.blockLine(block("toggle", rich("Notion")), number: 0), "▸ Notion")
        try expectEqual(NotionTaskSource.blockLine(block("quote", rich("Zitat")), number: 0), "> Zitat")
        try expectEqual(NotionTaskSource.blockLine(block("divider", ["x": "y"]), number: 0), "—")
        try expectEqual(NotionTaskSource.blockLine(block("child_page", ["title": "Anhang"]), number: 0), "↳ Anhang")
        let open: JSONValue = ["rich_text": [["plain_text": "Testdruck"]], "checked": false]
        let checked: JSONValue = ["rich_text": [["plain_text": "Testdruck"]], "checked": true]
        try expectEqual(NotionTaskSource.blockLine(block("to_do", open), number: 0), "☐ Testdruck")
        try expectEqual(NotionTaskSource.blockLine(block("to_do", checked), number: 0), "☑ Testdruck")
        let empty: JSONValue = ["rich_text": [], "checked": false]
        try expect(NotionTaskSource.blockLine(block("to_do", empty), number: 0) == nil, "leeres To-do fehlt im Text")
        let blank: JSONValue = ["rich_text": [["plain_text": "   "]], "checked": false]
        try expect(NotionTaskSource.blockLine(block("to_do", blank), number: 0) == nil,
                   "nur-Leerzeichen-To-do fehlt im Text (wie beim Import)")
        try expect(NotionTaskSource.blockLine(block("image", ["x": "y"]), number: 0) == nil, "Bild ignoriert")
      },

      CheckCase("Ticket-Text: drei Leerzeilen werden reduziert, lange Texte bei 4000 Zeichen gekappt") {
        try expectEqual(NotionTaskSource.finishText("  A\n\n\n\nB  "), "A\n\nB")
        let capped = NotionTaskSource.finishText(String(repeating: "a", count: 4500))
        try expectEqual(capped.count, 4001, "4000 Zeichen plus „…“")
        try expect(capped.hasSuffix("…"), "Kappung markiert")
        try expectEqual(NotionTaskSource.finishText(String(repeating: "b", count: 4000)).count, 4000, "genau 4000 bleibt ganz")
      },

      CheckCase("Ticket-Text: verschachtelte Blöcke werden eingerückt gelesen") {
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/pg/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              notionTodoBlock("oben", text: "Oben", checked: false, hasChildren: true),
            ]]))
          }
          if url.contains("/v1/blocks/oben/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              notionTodoBlock("unten", text: "Unter", checked: true),
            ]]))
          }
          return (404, notionJSON(["object": "error", "message": "unbekannt"]))
        }
        let text = try await NotionTaskSource(token: "tok", session: session).fetchPageText("pg")
        try expectEqual(text, "☐ Oben\n  ☑ Unter")
      },

      CheckCase("Ticket-Text: Format wie NotionBodyFormat – Überschrift, leeres To-do fehlt, Toggle mit eingerücktem Kind") {
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.contains("/v1/blocks/pg/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              ["id": "h", "type": "heading_2", "heading_2": ["rich_text": [["plain_text": "Core Task"]]]],
              notionTodoBlock("leer", text: "", checked: false),
              notionTodoBlock("locale", text: "Locale AI", checked: false),
              ["id": "tg", "type": "toggle", "has_children": .bool(true),
               "toggle": ["rich_text": [["plain_text": "Notion"]]]],
            ]]))
          }
          if url.contains("/v1/blocks/tg/children") {
            return (200, notionJSON(["object": "list", "has_more": false, "results": [
              ["id": "tp", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "Langdock"]]]],
            ]]))
          }
          return (404, notionJSON(["object": "error", "message": "unbekannt"]))
        }
        let text = try await NotionTaskSource(token: "tok", session: session).fetchPageText("pg")
        try expectEqual(text, "## Core Task\n☐ Locale AI\n▸ Notion\n  Langdock")
      },

      CheckCase("Ticket-Text: geänderter Inhalt aktualisiert Notizen, gleicher Inhalt nicht") {
        let task = TabyTask(id: "t1", title: "Drucker", notes: "alt", createdAt: "2026-10-12T08:00")
        let linked = ["n1": "t1"]
        let known = ["n1": NotionTaskSource.textHash("alt")]  // Stand des letzten Abgleichs
        let changed = NotionTaskSource.plan(
          items: [NotionTaskSource.Item(id: "n1", title: "Drucker", done: false, body: "neu")],
          linked: linked, existingTasks: ["t1": task], lastBodyHash: known)
        try expectEqual(changed.update.map(\.taskId), ["t1"], "Inhalt geändert")
        let same = NotionTaskSource.plan(
          items: [NotionTaskSource.Item(id: "n1", title: "Drucker", done: false, body: "alt")],
          linked: linked, existingTasks: ["t1": task], lastBodyHash: known)
        try expect(same.update.isEmpty, "gleicher Inhalt")
        let noBody = NotionTaskSource.plan(
          items: [NotionTaskSource.Item(id: "n1", title: "Drucker", done: false)],
          linked: linked, existingTasks: ["t1": task])
        try expect(noBody.update.isEmpty, "ohne gelesenen Inhalt bleiben Notizen unberührt")
      },

      CheckCase("Status-Import: Complete-Gruppe ist erledigt, In progress offen") {
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/db-s") {
            return (200, anyJSON(["object": "database", "data_sources": [["id": "ds-s"]]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-s/query") {
            return (200, anyJSON(["object": "list", "has_more": false, "results": [
              statusRow("p1", title: "Fertig", optionId: "o-done", name: "Gelöst"),
              statusRow("p2", title: "Läuft", optionId: "o-prog", name: "In Arbeit"),
            ]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-s") { return (200, Data(statusSchemaJSON.utf8)) }
          return (404, Data())
        }
        let items = try await NotionTaskSource(token: "tok", session: session).fetchDatabase("db-s", bodies: false)
        try expectEqual(items.map(\.done), [true, false], "Complete erledigt, In progress offen")
        try expectEqual(items.map(\.meta.status), ["Gelöst", "In Arbeit"], "Statusname bleibt in den Metadaten")
      },

      CheckCase("Status-Import: ohne lesbares Schema zählt der Name „Erledigt“ als erledigt, „In Arbeit“ nicht") {
        let session = NotionTaskStubURLProtocol.session { req, _ in
          let url = req.url!.absoluteString
          if url.hasSuffix("/v1/databases/db-s") {
            return (200, anyJSON(["object": "database", "data_sources": [["id": "ds-s"]]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-s/query") {
            return (200, anyJSON(["object": "list", "has_more": false, "results": [
              statusRow("p1", title: "Erledigt-Ticket", optionId: "x1", name: "Erledigt"),
              statusRow("p2", title: "Läuft", optionId: "x2", name: "In Arbeit"),
            ]]))
          }
          return (404, Data())
        }
        let items = try await NotionTaskSource(token: "tok", session: session).fetchDatabase("db-s", bodies: false)
        try expectEqual(items.map(\.done), [true, false], "Namens-Rückfall")
      },

      CheckCase("Status-Schreiben: Abhaken setzt die Complete-Option, Wiederöffnen die To-do-Option, nur die Status-Eigenschaft") {
        var patches: [JSONValue] = []
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/p1") {
            patches.append(body ?? .null)
            return (200, Data())
          }
          if url.hasSuffix("/v1/pages/p1") {
            return (200, anyJSON(statusRow("p1", title: "Ticket", optionId: "o-prog", name: "In Arbeit")
              .merging(["parent": ["type": "data_source_id", "data_source_id": "ds-s"]]) { $1 }))
          }
          if url.hasSuffix("/v1/data_sources/ds-s") { return (200, Data(statusSchemaJSON.utf8)) }
          return (404, Data())
        }
        let source = NotionTaskSource(token: "tok", session: session)
        try await source.setPageChecked("p1", checked: true)
        try await source.setPageChecked("p1", checked: false)
        try expectEqual(patches.count, 2, "zwei PATCHes")
        try expectEqual(patches[0]["properties"]?["Status"]?["status"]?["id"]?.stringValue, "o-done", "abhaken → Complete")
        try expectEqual(patches[1]["properties"]?["Status"]?["status"]?["id"]?.stringValue, "o-todo", "öffnen → To-do")
        try expectEqual(patches[0]["properties"]?.objectValue?.count, 1, "nur die Status-Eigenschaft")
      },

      CheckCase("Status-Schreiben: Zeile mit Datenbank-Parent löst die Datenquelle auf") {
        var patched: JSONValue?
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/p1") { patched = body; return (200, Data()) }
          if url.hasSuffix("/v1/pages/p1") {
            return (200, anyJSON(statusRow("p1", title: "Ticket", optionId: "o-prog", name: "In Arbeit")
              .merging(["parent": ["type": "database_id", "database_id": "db-s"]]) { $1 }))
          }
          if url.hasSuffix("/v1/databases/db-s") {
            return (200, anyJSON(["object": "database", "data_sources": [["id": "ds-s"]]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-s") { return (200, Data(statusSchemaJSON.utf8)) }
          return (404, Data())
        }
        try await NotionTaskSource(token: "tok", session: session).setPageChecked("p1", checked: true)
        try expectEqual(patched?["properties"]?["Status"]?["status"]?["id"]?.stringValue, "o-done")
      },

      CheckCase("Status-Schreiben: hat die Zeile auch eine Checkbox, wird nur die Checkbox gesetzt") {
        var patched: [JSONValue] = []
        var schemaReads = 0
        let session = NotionTaskStubURLProtocol.session { req, body in
          let url = req.url!.absoluteString
          if req.httpMethod == "PATCH", url.hasSuffix("/v1/pages/p1") { patched.append(body ?? .null); return (200, Data()) }
          if url.hasSuffix("/v1/pages/p1") {
            return (200, anyJSON(["id": "p1", "parent": ["type": "data_source_id", "data_source_id": "ds-s"], "properties": [
              "Erledigt": ["type": "checkbox", "checkbox": false],
              "Status": ["id": "s1", "type": "status", "status": ["id": "o-prog", "name": "In Arbeit"]],
            ]]))
          }
          if url.hasSuffix("/v1/data_sources/ds-s") { schemaReads += 1; return (200, Data(statusSchemaJSON.utf8)) }
          return (404, Data())
        }
        try await NotionTaskSource(token: "tok", session: session).setPageChecked("p1", checked: true)
        try expectEqual(patched.count, 1, "ein PATCH")
        try expectEqual(patched[0]["properties"]?["Erledigt"]?["checkbox"]?.boolValue, true, "Checkbox gesetzt")
        try expect(patched[0]["properties"]?["Status"] == nil, "Status unangetastet")
        try expectEqual(schemaReads, 0, "kein Schema nötig")
      },
      CheckCase("Fälligkeit: bevorzugter Name gewinnt vor „Erledigt am“ und alphabetischer Reihenfolge") {
        let props: [String: JSONValue] = [
          "Erledigt am": ["type": "date", "date": ["start": "2026-10-01"]],
          "Fällig": ["type": "date", "date": ["start": "2026-10-09"]],
        ]
        try expectEqual(NotionTaskSource.dueDateName(props), "Fällig")
        let created: [String: JSONValue] = [
          "Created": ["type": "date", "date": ["start": "2026-10-01"]],
          "Abgabe": ["type": "date", "date": ["start": "2026-10-02"]],
          "Due": ["type": "date", "date": ["start": "2026-10-09"]],
        ]
        try expectEqual(NotionTaskSource.dueDateName(created), "Due")
        let plain: [String: JSONValue] = [
          "Start": ["type": "date", "date": ["start": "2026-10-01"]],
          "Anlage": ["type": "date", "date": ["start": "2026-10-02"]],
        ]
        try expectEqual(NotionTaskSource.dueDateName(plain), "Anlage")
        let onlyDone: [String: JSONValue] = ["Erledigt am": ["type": "date", "date": ["start": "2026-10-01"]]]
        try expect(NotionTaskSource.dueDateName(onlyDone) == nil, "Erledigt am allein ist keine Fälligkeit")
      },
      CheckCase("Zurückschreiben: mit time_zone geht der Start ohne Versatz, sonst mit Versatz") {
        let zoned = NotionTaskSource.dateValue("2026-10-03T14:30", existing: ["time_zone": "Europe/Berlin"])
        try expectEqual(zoned["start"]?.stringValue, "2026-10-03T14:30:00")
        try expectEqual(zoned["time_zone"]?.stringValue, "Europe/Berlin")
        let plain = NotionTaskSource.dateValue("2026-10-03T14:30", existing: .null)
        try expectEqual(plain["start"]?.stringValue?.count, 22, "mit Versatz, z. B. 2026-10-03T14:30+02:00")
        try expect(plain["time_zone"] == nil, "ohne time_zone")
        let ranged = NotionTaskSource.dateValue("2026-10-03T14:30",
                                                existing: ["time_zone": "Europe/Berlin", "end": "2026-10-03T16:00:00.000"])
        try expectEqual(ranged["end"]?.stringValue, "2026-10-03T16:00:00.000", "späteres Ende bleibt mit time_zone")
      },
    ] + NotionAccountChecks.cases)
  }
}
