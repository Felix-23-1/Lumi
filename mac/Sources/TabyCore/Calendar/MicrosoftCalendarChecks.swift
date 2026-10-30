// Prüfungen für den Outlook-Kalender (MicrosoftCalendarProvider) gegen gestubbtes Graph.
// Zeitzone Europe/Berlin fest, damit die Umrechnung unabhängig vom Rechner gilt.
import Foundation

enum MicrosoftCalendarChecks {
  static let berlin = TimeZone(identifier: "Europe/Berlin")!

  /// Outlook-Provider mit angemeldetem Konto (Erneuerung läuft über den Stub).
  static func provider(_ h: MicrosoftHarness) throws -> MicrosoftCalendarProvider {
    try h.signedIn()
    return MicrosoftCalendarProvider(id: "microsoft", auth: h.auth, clock: h.clock, zone: berlin)
  }

  static func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Outlook: Termine in der Systemzone, Teams-Link in den Notizen, Abgesagtes fehlt, ganztägig bleibt Datum") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("GET /v1.0/me/calendarView", [(200, ["value": [
          ["id": "e1", "subject": "Standup", "isAllDay": false, "isCancelled": false,
           "start": ["dateTime": "2026-10-20T09:00:00.0000000", "timeZone": "UTC"],
           "end": ["dateTime": "2026-10-20T09:30:00.0000000", "timeZone": "UTC"],
           "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/abc"]],
          ["id": "e2", "subject": "Urlaub", "isAllDay": true, "isCancelled": false,
           "start": ["dateTime": "2026-10-21T00:00:00.0000000", "timeZone": "Europe/Berlin"],
           "end": ["dateTime": "2026-10-22T00:00:00.0000000", "timeZone": "Europe/Berlin"]],
          ["id": "e3", "subject": "Abgesagt", "isAllDay": false, "isCancelled": true,
           "start": ["dateTime": "2026-10-20T12:00:00.0000000", "timeZone": "UTC"],
           "end": ["dateTime": "2026-10-20T13:00:00.0000000", "timeZone": "UTC"]],
        ]])])
        let events = try await p.listEvents(from: "2026-10-19", to: "2026-10-24")
        try expectEqual(events.map(\.id), ["e1", "e2"], "abgesagter Termin fehlt")
        let standup = events[0]
        try expectEqual(standup.start, "2026-10-20T11:00", "09:00 UTC ist 11:00 in Berlin")
        try expectEqual(standup.end, "2026-10-20T11:30")
        try expectEqual(standup.notes, "Teams: https://teams.microsoft.com/l/meetup-join/abc")
        try expect(!standup.allDay)
        try expectEqual(events[1].start, "2026-10-21", "ganztägig bleibt das Datum")
        try expect(events[1].allDay)
        let call = try expectNotNil(h.graphSeen.first)
        try expectEqual(call.headers["Prefer"], "outlook.timezone=\"Europe/Berlin\"")
        try expectEqual(query(call.url, "startDateTime"), "2026-10-18T22:00:00Z", "Mitternacht Berlin als UTC")
        try expectEqual(query(call.url, "endDateTime"), "2026-10-23T22:00:00Z")
      },

      CheckCase("Outlook: Seiten werden gefolgt, höchstens fünf") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        let next = "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=next"
        h.setGraph("GET /v1.0/me/calendarView", [
          (200, ["value": [["id": "a", "subject": "A", "start": ["dateTime": "2026-10-20T09:00:00", "timeZone": "Europe/Berlin"],
                             "end": ["dateTime": "2026-10-20T10:00:00", "timeZone": "Europe/Berlin"]]],
                 "@odata.nextLink": next]),
          (200, ["value": [["id": "b", "subject": "B", "start": ["dateTime": "2026-10-20T11:00:00", "timeZone": "Europe/Berlin"],
                             "end": ["dateTime": "2026-10-20T12:00:00", "timeZone": "Europe/Berlin"]]]]),
        ])
        let events = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
        try expectEqual(events.map(\.id), ["a", "b"])
        try expectEqual(h.graphSeen.count, 2)
        try expectEqual(h.graphSeen.last?.url.absoluteString, next)
      },

      CheckCase("Outlook: Dauerschleife bricht bei fünf Seiten ab") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("GET /v1.0/me/calendarView", [(200, ["value": [], "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=x"])])
        _ = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
        try expectEqual(h.graphSeen.count, 5)
      },

      CheckCase("Outlook: Weiterleitung (nextLink) auf einen fremden Host wird abgewiesen") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("GET /v1.0/me/calendarView", [(200, ["value": [], "@odata.nextLink": "https://evil.example/collect"])])
        do {
          _ = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
          throw CheckFailure(message: "fremder nextLink wurde nicht abgewiesen", location: "MicrosoftCalendarChecks")
        } catch let e as CalendarError {
          try expectEqual(CalendarSupport.message(for: e), "Microsoft: Der Server verweist auf eine fremde Adresse. Abgebrochen.")
        }
        try expect(!h.seen.contains { $0.url.host == "evil.example" }, "nie eine Anfrage an den fremden Host")
      },

      CheckCase("Outlook: 403 beim Lesen nennt die IT-Freigabe") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("GET /v1.0/me/calendarView", [(403, ["error": ["code": "Forbidden"]])])
        do {
          _ = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
          throw CheckFailure(message: "403 muss scheitern", location: "MicrosoftCalendarChecks")
        } catch let e as CalendarError {
          try expectEqual(CalendarSupport.message(for: e), "Microsoft verweigert den Zugriff (403). \(MicrosoftChecks.consent)")
        }
      },

      CheckCase("Outlook: Termin anlegen schickt Titel, Zeit in der Systemzone und Notiz") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("POST /v1.0/me/events", [(201, ["id": "new-1"])])
        let created = try await p.createEvent(NewEvent(title: "Review", start: "2026-10-20T14:00", end: "2026-10-20T15:00", notes: "Raum 2"))
        try expectEqual(created.id, "new-1")
        try expectEqual(created.start, "2026-10-20T14:00")
        let post = try expectNotNil(h.graphSeen.first)
        try expectEqual(post.method, "POST")
        try expectEqual(post.url.path, "/v1.0/me/events")
        let body = try expectNotNil(JSONValue.parse(post.body))
        try expectEqual(body["subject"]?.stringValue, "Review")
        try expectEqual(body["start"]?["dateTime"]?.stringValue, "2026-10-20T14:00:00")
        try expectEqual(body["start"]?["timeZone"]?.stringValue, "Europe/Berlin")
        try expectEqual(body["end"]?["dateTime"]?.stringValue, "2026-10-20T15:00:00")
        try expectEqual(body["isAllDay"]?.boolValue, false)
        try expectEqual(body["body"]?["content"]?.stringValue, "Raum 2")
      },

      CheckCase("Outlook: ganztägiger Termin ohne Ende ist ein Tag lang") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("POST /v1.0/me/events", [(201, ["id": "new-2"])])
        let created = try await p.createEvent(NewEvent(title: "Urlaub", start: "2026-10-23"))
        try expect(created.allDay)
        let body = try expectNotNil(JSONValue.parse(try expectNotNil(h.graphSeen.first).body))
        try expectEqual(body["isAllDay"]?.boolValue, true)
        try expectEqual(body["start"]?["dateTime"]?.stringValue, "2026-10-23T00:00:00")
        try expectEqual(body["end"]?["dateTime"]?.stringValue, "2026-10-24T00:00:00")
      },

      CheckCase("Outlook: Löschen und Verschieben treffen den Termin, auch mit Sonderzeichen in der Kennung") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("DELETE /v1.0/me/events/AAMk=", [(204, [:])])
        h.setGraph("PATCH /v1.0/me/events/AAMk=", [(200, ["id": "AAMk="])])
        try await p.deleteEvent(id: "AAMk=")
        let del = try expectNotNil(h.graphSeen.first)
        try expectEqual(del.method, "DELETE")
        try expect(del.url.absoluteString.hasSuffix("/me/events/AAMk%3D"), del.url.absoluteString)
        try await p.moveEvent(id: "AAMk=", to: NewEvent(title: "Verschoben", start: "2026-10-20T16:00", end: "2026-10-20T17:00"))
        let patch = try expectNotNil(h.graphSeen.last)
        try expectEqual(patch.method, "PATCH")
        try expectEqual(JSONValue.parse(patch.body)?["start"]?["dateTime"]?.stringValue, "2026-10-20T16:00:00")
      },

      CheckCase("Outlook: ohne Anmeldung ist die Quelle nicht erreichbar, ohne Netz") {
        let h = MicrosoftHarness()
        let p = MicrosoftCalendarProvider(id: "microsoft", auth: h.auth, clock: h.clock, zone: berlin)
        let health = await p.healthCheck()
        try expect(!health.ok)
        try expectEqual(health.message, "Nicht bei Microsoft angemeldet. Bitte unter Verbindungen → Microsoft anmelden.")
        try expect(h.seen.isEmpty)
      },

      CheckCase("Outlook: Zeit in fremder Zone wird umgerechnet (Windows-Name), unbekannte Zone gilt als UTC") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("GET /v1.0/me/calendarView", [(200, ["value": [
          ["id": "w", "subject": "W", "start": ["dateTime": "2026-10-20T09:00:00.0000000", "timeZone": "Eastern Standard Time"],
           "end": ["dateTime": "2026-10-20T10:00:00.0000000", "timeZone": "Eastern Standard Time"]],
          ["id": "u", "subject": "U", "start": ["dateTime": "2026-10-20T09:00:00.0000000", "timeZone": "Mars Standard Time"],
           "end": ["dateTime": "2026-10-20T10:00:00.0000000", "timeZone": "Mars Standard Time"]],
          ["id": "ok", "subject": "OK", "start": ["dateTime": "2026-10-20T09:00:00.0000000", "timeZone": "Europe/Berlin"],
           "end": ["dateTime": "2026-10-20T10:00:00.0000000", "timeZone": "Europe/Berlin"]],
        ]])])
        let events = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
        let byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        // New York im Oktober: 09:00 EDT = 13:00 UTC = 15:00 MESZ.
        try expectEqual(byId["w"]?.start, "2026-10-20T15:00")
        try expectEqual(byId["u"]?.start, "2026-10-20T11:00", "unbekannt = UTC")
        try expectEqual(byId["ok"]?.start, "2026-10-20T09:00", "gleiche Zone bleibt")
      },

      CheckCase("Outlook: mehr als 500 Termine: Quelle meldet „Zeitraum verkleinern“, Gelesenes bleibt") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        let next = "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=x"
        h.setGraph("GET /v1.0/me/calendarView", [(200, ["value": [["id": "a", "subject": "A",
                                                                  "start": ["dateTime": "2026-10-20T09:00:00", "timeZone": "Europe/Berlin"],
                                                                  "end": ["dateTime": "2026-10-20T10:00:00", "timeZone": "Europe/Berlin"]]],
                                                        "@odata.nextLink": next])])
        h.setGraph("GET /v1.0/me", [(200, ["id": "me-1"])])
        let events = try await p.listEvents(from: "2026-10-20", to: "2026-10-21")
        try expectEqual(events.count, 5, "fünf Seiten gelesen, je ein Termin")
        let health = await p.healthCheck()
        try expect(health.ok)
        try expectEqual(health.message, "mehr als 500 Termine, Zeitraum verkleinern")
      },

      CheckCase("Outlook: ganztägig mit Ende gleich Beginn ist ein Tag lang") {
        let h = MicrosoftHarness()
        let p = try provider(h)
        h.setGraph("POST /v1.0/me/events", [(201, ["id": "new-3"])])
        _ = try await p.createEvent(NewEvent(title: "Feiertag", start: "2026-10-23", end: "2026-10-23"))
        let body = try expectNotNil(JSONValue.parse(try expectNotNil(h.graphSeen.first).body))
        try expectEqual(body["start"]?["dateTime"]?.stringValue, "2026-10-23T00:00:00")
        try expectEqual(body["end"]?["dateTime"]?.stringValue, "2026-10-24T00:00:00", "Graph: Ende ist exklusiv")
      },
    ]
  }
}
