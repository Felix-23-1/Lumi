// Prüfungen für „Privat nebenbei“: Liste (mit Attrappe der Erinnerungen), Entwurf
// mit Escaping (ohne echtes Mail-Programm) und Teilnehmer-Zuordnung.
import Foundation

enum PrivateAndFollowUpChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Privat: ohne gewählte Liste kommt der Hinweis, nichts wird angelegt") {
        let backend = PrivateFakeReminders()
        let r = await PrivateListTools.execute(name: "add_to_private_list", argumentsJSON: "{\"items\":[\"Milch\"]}",
                                               listId: "", backend: backend)
        try expectEqual(r["code"]?.stringValue, "NO_LIST")
        try expectEqual(r["error"]?.stringValue, "Bitte in den Einstellungen eine Liste für Privates wählen.")
        try expectEqual(backend.items.count, 0)
      },
      CheckCase("Privat: Punkte werden als Erinnerungen in der gewählten Liste angelegt") {
        let backend = PrivateFakeReminders()
        let r = await PrivateListTools.execute(name: "add_to_private_list",
                                               argumentsJSON: "{\"items\":[\"Milch\",\"  Brot \",\"\"]}",
                                               listId: "L2", backend: backend)
        try expect(r["ok"]?.boolValue == true, "add fehlgeschlagen: \(String(describing: r["error"]))")
        try expectEqual(r["added"]?.numberValue, 2)
        try expectEqual(backend.items.map(\.title), ["Milch", "Brot"])
        try expectEqual(backend.items.compactMap { backend.listOf[$0.id] }, ["L2", "L2"])
      },
      CheckCase("Privat: list zeigt nur offene Punkte der gewählten Liste") {
        let backend = PrivateFakeReminders()
        backend.seed(ExternalReminder(id: "a", title: "Milch"), list: "L2")
        backend.seed(ExternalReminder(id: "b", title: "Alt", done: true), list: "L2")
        backend.seed(ExternalReminder(id: "c", title: "Anderes"), list: "L1")
        let r = await PrivateListTools.execute(name: "list_private_list", argumentsJSON: "", listId: "L2", backend: backend)
        try expect(r["ok"]?.boolValue == true, "list fehlgeschlagen")
        try expectEqual(r["count"]?.numberValue, 1)
        try expectEqual(r["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Milch"])
      },
      CheckCase("Privat: ohne Freigabe für Erinnerungen kommt ein Fehler") {
        let backend = PrivateFakeReminders()
        backend.granted = false
        let r = await PrivateListTools.execute(name: "add_to_private_list", argumentsJSON: "{\"items\":[\"Milch\"]}",
                                               listId: "L2", backend: backend)
        try expectEqual(r["code"]?.stringValue, "ACCESS")
        try expectEqual(backend.items.count, 0)
      },
      CheckCase("Privat: leere Punkteliste ist ein Eingabefehler") {
        let backend = PrivateFakeReminders()
        let r = await PrivateListTools.execute(name: "add_to_private_list", argumentsJSON: "{\"items\":[\" \"]}",
                                               listId: "L2", backend: backend)
        try expectEqual(r["code"]?.stringValue, "INVALID_ARGS")
      },
      CheckCase("Privat: Werkzeugnamen und Pflichtfeld stimmen") {
        try expectEqual(PrivateListTools.definitions.map(\.name), ["add_to_private_list", "list_private_list"])
        let required = PrivateListTools.definitions[0].parameters["required"]
        try expectEqual(required?.arrayValue?.compactMap(\.stringValue), ["items"])
      },

      // MARK: Mail-Entwurf
      CheckCase("Entwurf: Betreff nennt Titel und Datum") {
        try expectEqual(MeetingFollowUp.subject(title: "Steuer-Call", start: "2026-10-12T10:00"),
                        "Nachbereitung: Steuer-Call (12.10.2026)")
      },
      CheckCase("Entwurf: Teilnehmer-Adressen aus mailto, ohne Dubletten und Müll") {
        let got = MeetingFollowUp.addresses(from: [
          "mailto:lena@example.com", "MAILTO:Max%40Beispiel.de", "mailto:Lena@example.com",
          "https://zoom.example/x", "mailto:", "mailto:kaputt", "mailto:a b@example.com",
        ])
        try expectEqual(got, ["lena@example.com", "Max@Beispiel.de"])
      },
      CheckCase("Entwurf: ohne Teilnehmer bleibt der Empfänger leer") {
        let d = MeetingFollowUp.draft(title: "Steuer-Call", start: "2026-10-12T10:00", to: [], notes: nil, openTasks: [])
        try expectEqual(d.to, [])
        try expect(d.body.contains("kurze Zusammenfassung"), "Vorlage fehlt")
      },
      CheckCase("Entwurf: Stichpunkte und offene Aufgaben stehen im Text") {
        let body = MeetingFollowUp.body(title: "Steuer-Call", start: "2026-10-12T10:00",
                                        notes: "- Angebot schicken\n", openTasks: ["Angebot schicken"])
        try expect(body.contains("- Angebot schicken\n"), "Stichpunkte fehlen: \(body)")
        try expect(body.contains("Offene Punkte:\n- Angebot schicken"), "Aufgaben fehlen")
        try expect(!body.contains("Zusammenfassung"), "Vorlage darf bei Inhalt nicht stehen")
      },
      CheckCase("Entwurf: Notiz und offene Aufgaben werden dem Termin zugeordnet") {
        let note = Note(id: "n1", title: "Notizen: Steuer-Call (12.10.)", content: "- a", createdAt: "", updatedAt: "")
        try expectEqual(MeetingFollowUp.meetingNote([note], title: "Steuer-Call", start: "2026-10-12T10:00")?.id, "n1")
        try expectEqual(MeetingFollowUp.meetingNote([note], title: "Anderer", start: "2026-10-12T10:00")?.id, nil)
        let tasks = [
          TabyTask(id: "t1", title: "Offen", notes: "Aus: Steuer-Call", done: false, createdAt: ""),
          TabyTask(id: "t2", title: "Erledigt", notes: "Aus: Steuer-Call", done: true, createdAt: ""),
          TabyTask(id: "t3", title: "Fremd", notes: "Aus: Anderer", done: false, createdAt: ""),
        ]
        try expectEqual(MeetingFollowUp.openTasks(tasks, title: "Steuer-Call"), ["Offen"])
      },
      CheckCase("Entwurf: Argumente gehen als JSON, Text mit Anführungszeichen und Befehlen bleibt Daten") {
        let evil = "\"}); do shell script \"rm -rf ~\"; ({x: \"\n\\ \u{2028}' & end tell"
        let draft = MailDraft(to: ["a@example.com"], subject: evil, body: evil)
        let json = JSONValue.object(AppleMailBackend.draftParams(draft)).jsonString()
        let back = JSONValue.parse(json)
        try expectEqual(back?["subject"]?.stringValue, evil)
        try expectEqual(back?["body"]?.stringValue, evil)
        try expectEqual(back?["to"]?.arrayValue?.compactMap(\.stringValue), ["a@example.com"])
        try expect(!AppleMailScripts.newDraft.contains("rm -rf"), "Text darf nie im Skriptquelltext stehen")
        try expect(!AppleMailScripts.newDraft.contains("do shell script"), "Skript ist unerwartet")
      },
      CheckCase("Entwurf: Skript öffnet nur (visible) und sendet nicht") {
        try expect(AppleMailScripts.newDraft.contains("visible: true"), "Entwurf nicht sichtbar")
        try expect(!AppleMailScripts.newDraft.contains(".send("), "Entwurf darf nicht senden")
      },
      CheckCase("Entwurf: ohne Termin im Kalender kommt „nicht gefunden“, nichts wird geöffnet") {
        let mail = FakeMailBackend()
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-12T08:00"),
                                        keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(),
                                        plannerInterval: nil)
        opts.mailBackend = mail
        let svc = try CoreServices(options: opts)
        let r = await svc.draftMeetingFollowUp(eventId: "gibt-es-nicht")
        try expectEqual(r.errorMessage, "Termin nicht gefunden.")
        try expectEqual(mail.opened.count, 0)
      },
    ]
  }
}

/// Attrappe der Erinnerungen (wie RemindersBackend, ohne EventKit).
private final class PrivateFakeReminders: RemindersBackend {
  var granted = true
  var items: [ExternalReminder] = []
  var listOf: [String: String] = [:]
  private var nextId = 100

  func requestAccess() async -> Bool { granted }

  func lists() async throws -> [ReminderListInfo] {
    [ReminderListInfo(id: "L1", title: "Erinnerungen"), ReminderListInfo(id: "L2", title: "Privates")]
  }

  func fetchAll(listIds: [String]?) async throws -> [ExternalReminder] {
    items.map { r -> ExternalReminder in
      var copy = r
      copy.listId = listOf[r.id]
      return copy
    }.filter { listIds == nil || listIds!.contains($0.listId ?? "") }
  }

  func create(_ r: ExternalReminder, listId: String?) async throws -> String {
    let id = "R\(nextId)"
    nextId += 1
    items.append(ExternalReminder(id: id, title: r.title, notes: r.notes, due: r.due, done: r.done))
    listOf[id] = listId
    return id
  }

  func update(_ r: ExternalReminder) async throws {
    if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r }
  }

  func delete(id: String) async throws {
    items.removeAll { $0.id == id }
    listOf[id] = nil
  }

  func seed(_ r: ExternalReminder, list: String) {
    items.append(r)
    listOf[r.id] = list
  }
}
