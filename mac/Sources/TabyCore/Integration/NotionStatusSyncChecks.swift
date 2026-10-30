// Prüfungen für den Notion-Status: Zuordnung (reine Regeln), Entscheidung beim Abgleich (rein) und
// der Abgleich selbst gegen den gestubbten Notion-HTTP-Pfad der Paket-9-Prüfungen.
import Foundation

enum NotionStatusSyncChecks {
  /// Eine Ticket-Zeile „Ticket A“, deren Notion-Status sich zwischen den Abgleichen ändern lässt.
  /// `status` nil = die Zeile hat keine Status-Eigenschaft.
  final class StatusStub {
    var status: String?
    init(status: String?) { self.status = status }

    func session(dbId: String) -> URLSession {
      NotionTaskStubURLProtocol.session { [self] req, _ in
        let url = req.url!.absoluteString
        if url.hasSuffix("/v1/databases/\(dbId)") {
          return (200, Data(JSONValue.object(["object": "database", "data_sources": [["id": "ds"]]]).jsonString().utf8))
        }
        if url.hasSuffix("/v1/data_sources/ds/query") {
          var props: [String: JSONValue] = ["Name": ["type": "title", "title": [["plain_text": "Ticket A"]]]]
          if let status { props["Status"] = ["type": "status", "status": ["name": .string(status)]] }
          let row: JSONValue = ["id": .string(String(repeating: "ab12", count: 8)), "created_time": "2026-10-09T12:00:00.000Z",
                                "created_by": ["object": "user", "id": "u1"], "properties": .object(props)]
          return (200, Data(JSONValue.object(["object": "list", "has_more": false, "results": [row]]).jsonString().utf8))
        }
        return (404, Data())
      }
    }
  }

  /// Verbindet, richtet die Stub-Quelle ein und gleicht einmal ab. Liefert die Aufgabe „Ticket A“.
  @MainActor static func syncOnce(_ svc: CoreServices, dbId: String) async throws -> TabyTask {
    _ = await svc.connectNotionTasks(token: "tok")
    _ = await svc.addNotionSource(name: "Status-Quelle", category: .tickets, link: dbId)
    _ = await svc.updateSettings(SettingsPatch(notionTasksEnabled: true), apiKey: nil)
    guard await svc.syncNotionTasks().isOk else { throw CheckFailure(message: "Abgleich fehlgeschlagen", location: "") }
    let state = await svc.state()
    return try expectNotNil(state.tasks.first { $0.title == "Ticket A" }, "Ticket A importiert")
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Notion-Status: Vorschläge und Ablehnung ohne Zuordnung") {
        try expectEqual(NotionStatusRules.suggested(forNotion: "Not started"), .open)
        try expectEqual(NotionStatusRules.suggested(forNotion: "In progress"), .inProgress)
        try expectEqual(NotionStatusRules.suggested(forNotion: "Blocked"), .needsInfo)
        try expectEqual(NotionStatusRules.suggested(forNotion: "Warten"), .needsInfo)
        try expectEqual(NotionStatusRules.suggested(forNotion: "  In Bearbeitung "), .inProgress, "Rand und Groß/Klein egal")
        try expectEqual(NotionStatusRules.suggested(forNotion: "Erledigt"), nil, "unbekannt = nil")
        try expectEqual(NotionStatusRules.suggested(forNotion: "   "), nil, "leer = nil")
      },

      CheckCase("Notion-Status: Zuordnung des Nutzers gewinnt, leere Zuordnung lässt den Stand") {
        try expectEqual(NotionStatusRules.lumiStatus(forNotion: "Waiting for client", map: ["waiting for client": "open"]), .open)
        try expectEqual(NotionStatusRules.lumiStatus(forNotion: "Waiting for client", map: ["waiting for client": "needsInfo"]), .needsInfo)
        try expectEqual(NotionStatusRules.lumiStatus(forNotion: "In progress", map: ["in progress": ""]), nil, "leer = nicht ändern")
        try expectEqual(NotionStatusRules.lumiStatus(forNotion: "In progress", map: [:]), .inProgress)
      },

      CheckCase("Notion-Status: gereinigte Zuordnung verwirft ungültige Werte und leere Schlüssel") {
        let cleaned = NotionStatusRules.cleaned(["a": "bogus", "b": "open", "": "open", " C ": "inProgress", "d": ""])
        try expectEqual(cleaned, ["b": "open", "c": "inProgress", "d": ""])
      },

      CheckCase("Notion-Status: Entscheidung nur bei neuem oder geändertem Text") {
        let map: [String: String] = [:]
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: nil, newNotion: "In progress", map: map), .inProgress, "neu")
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: "In progress", newNotion: "In progress", map: map), nil, "unverändert")
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: "In progress", newNotion: "Warten", map: map), .needsInfo, "geändert")
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: "In progress", newNotion: nil, map: map), nil, "kein Status")
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: nil, newNotion: "Xyz", map: map), nil, "unbekannt")
        try expectEqual(NotionStatusSync.statusToApply(previousNotion: nil, newNotion: "Waiting for client",
                                                       map: ["waiting for client": "open"]), .open, "Zuordnung vor Vorschlag")
      },

      CheckCase("Notion-Status: neue Aufgabe mit „In progress“ wird „In Bearbeitung“") {
        let dbId = String(repeating: "5a7c", count: 8)
        let stub = StatusStub(status: "In progress")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        let task = try await syncOnce(svc, dbId: dbId)
        try expectEqual(task.status, .inProgress)
      },

      CheckCase("Notion-Status: lokal gesetzter Stand bleibt, solange der Notion-Text gleich ist") {
        let dbId = String(repeating: "5a7d", count: 8)
        let stub = StatusStub(status: "In progress")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        let task = try await syncOnce(svc, dbId: dbId)
        try expectEqual(task.status, .inProgress)
        _ = try expectNotNil(try svc.store.tasks.update(task.id, status: .open), "lokal geändert")
        guard await svc.syncNotionTasks().isOk else { throw CheckFailure(message: "zweiter Abgleich fehlgeschlagen", location: "") }
        let state = await svc.state()
        let after = try expectNotNil(state.tasks.first { $0.id == task.id }, "Aufgabe bleibt")
        try expectEqual(after.status, .open, "lokaler Stand nicht überschrieben")
      },

      CheckCase("Notion-Status: Notion-Text ändert sich zu „Warten“ wird „Info fehlt“") {
        let dbId = String(repeating: "5a7e", count: 8)
        let stub = StatusStub(status: "In progress")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        _ = try await syncOnce(svc, dbId: dbId)
        stub.status = "Warten"
        guard await svc.syncNotionTasks().isOk else { throw CheckFailure(message: "zweiter Abgleich fehlgeschlagen", location: "") }
        let state = await svc.state()
        let task = try expectNotNil(state.tasks.first { $0.title == "Ticket A" }, "Ticket A")
        try expectEqual(task.status, .needsInfo)
      },

      CheckCase("Notion-Status: Zuordnung des Nutzers schlägt den Vorschlag im Abgleich") {
        let dbId = String(repeating: "5a7f", count: 8)
        let stub = StatusStub(status: "Waiting for client")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        _ = await svc.updateSettings(SettingsPatch(notionStatusMap: ["waiting for client": "open"]), apiKey: nil)
        let task = try await syncOnce(svc, dbId: dbId)
        try expectEqual(task.status, .open, "Zuordnung gewinnt über „wait“-Vorschlag")
      },

      CheckCase("Notion-Status: unbekannter Text lässt den lokalen Stand") {
        let dbId = String(repeating: "5a80", count: 8)
        let stub = StatusStub(status: "In progress")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        let first = try await syncOnce(svc, dbId: dbId)
        _ = try expectNotNil(try svc.store.tasks.update(first.id, status: .needsInfo), "lokal geändert")
        stub.status = "Erledigt-Ähnliches"
        guard await svc.syncNotionTasks().isOk else { throw CheckFailure(message: "zweiter Abgleich fehlgeschlagen", location: "") }
        let state = await svc.state()
        let task = try expectNotNil(state.tasks.first { $0.id == first.id }, "Ticket A")
        try expectEqual(task.status, .needsInfo, "unbekannter Text ändert nichts")
      },

      CheckCase("Notion-Status: Leere Zuordnung lässt den Stand bei neuer Aufgabe") {
        let dbId = String(repeating: "5a81", count: 8)
        let stub = StatusStub(status: "In progress")
        let (svc, _) = try PackageNineIntegrationChecks.rig(session: stub.session(dbId: dbId))
        _ = await svc.updateSettings(SettingsPatch(notionStatusMap: ["in progress": ""]), apiKey: nil)
        let task = try await syncOnce(svc, dbId: dbId)
        try expectEqual(task.status, .open, "leere Zuordnung = nicht ändern")
      },
    ]
  }
}
