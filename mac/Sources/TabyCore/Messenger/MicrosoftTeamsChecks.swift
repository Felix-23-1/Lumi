// Prüfungen für Microsoft Teams (TeamsConnector) und den Status „Nicht stören“, gegen gestubbtes Graph.
// Der Kern-Ablauf (Anmelden → Teams → Abmelden) läuft über CoreServices mit demselben Stub.
import Foundation

enum MicrosoftTeamsChecks {
  static let chatA = "19:a@thread.v2"
  static let chatB = "19:b@unq.gbl.spaces"

  static let me: (Int, Any) = (200, ["id": "me-1", "mail": "felix@contoso.de", "displayName": "Felix"])

  /// Erste Abfrage: Anna hat in „Projekt“ geschrieben (HTML), Bruno hat einen Systemeintrag als letzte Meldung.
  static func chatsFirst() -> (Int, Any) {
    (200, ["value": [
      ["id": chatA, "chatType": "group", "topic": "Projekt", "members": [],
       "lastMessagePreview": ["id": "p1", "createdDateTime": "2026-10-20T08:00:00.000Z", "messageType": "message",
                              "body": ["contentType": "html", "content": "<p>Hallo&nbsp;&amp; <b>Team</b></p>"],
                              "from": ["user": ["id": "u-anna", "displayName": "Anna"]]]],
      ["id": chatB, "chatType": "oneOnOne", "topic": NSNull(),
       "members": [["userId": "me-1", "displayName": "Felix"], ["userId": "u-bruno", "displayName": "Bruno"]],
       "lastMessagePreview": ["id": "p2", "createdDateTime": "2026-10-20T07:00:00.000Z", "messageType": "systemEventMessage",
                              "body": ["contentType": "html", "content": "<systemEventMessage/>"], "from": NSNull()]],
    ]])
  }

  /// Zweite Abfrage: Anna schreibt in „Projekt“ neu.
  static func chatsSecond() -> (Int, Any) {
    (200, ["value": [
      ["id": chatA, "chatType": "group", "topic": "Projekt", "members": [],
       "lastMessagePreview": ["id": "p3", "createdDateTime": "2026-10-20T09:00:00.000Z", "messageType": "message",
                              "body": ["contentType": "text", "content": "Bist du da?"],
                              "from": ["user": ["id": "u-anna", "displayName": "Anna"]]]],
    ]])
  }

  /// Nachrichten, neueste zuerst: meine, eine Systemmeldung (fällt weg), eine Nachricht mit HTML.
  static func messagesPayload() -> (Int, Any) {
    (200, ["value": [
      ["id": "m3", "createdDateTime": "2026-10-20T09:10:00Z", "messageType": "message",
       "body": ["contentType": "text", "content": "Ok"], "from": ["user": ["id": "me-1", "displayName": "Felix"]]],
      ["id": "m2", "createdDateTime": "2026-10-20T09:05:00Z", "messageType": "systemEventMessage",
       "body": ["contentType": "html", "content": "<systemEventMessage/>"], "from": NSNull()],
      ["id": "m1", "createdDateTime": "2026-10-20T09:00:00Z", "messageType": "message",
       "body": ["contentType": "html", "content": "<div>Hi<br>Du</div>"], "from": ["user": ["id": "u-anna", "displayName": "Anna"]]],
    ]])
  }

  /// Anmeldung im Stub: Konto ist angemeldet (Erneuerungs-Token da), Graph kennt „me“.
  static func signedIn(_ h: MicrosoftHarness) throws {
    try h.signedIn()
    h.setGraph("GET /v1.0/me", [me])
  }

  static func connector(_ h: MicrosoftHarness) -> TeamsConnector {
    TeamsConnector(auth: h.auth, clock: h.clock)
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Teams: ohne Microsoft-Anmeldung kommt kein Konto zustande") {
        let h = MicrosoftHarness()
        let c = connector(h)
        do {
          _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
          throw CheckFailure(message: "Anmeldung ohne Microsoft muss scheitern", location: "MicrosoftTeamsChecks")
        } catch let f as MessengerFailure {
          try expectEqual(f.message, "Erst bei Microsoft anmelden: Verbindungen → Microsoft.")
        }
      },

      CheckCase("Teams: Chats mit Titel, Vorschau ohne HTML, Systemmeldung ohne Vorschau, erster Blick ist gelesen") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/chats", [chatsFirst()])
        let c = connector(h)
        let account = try await c.login(MessengerLogin(service: .teams), accountId: "acc").account
        try expectEqual(account.user, "felix@contoso.de")
        try expectEqual(account.service, .teams)
        let list = try await c.conversations()
        try expectEqual(list.map(\.title).sorted(), ["Bruno", "Projekt"], "Gruppe mit Thema, Direktchat mit dem anderen Namen")
        let project = try expectNotNil(list.first { $0.title == "Projekt" })
        try expectEqual(project.id, "acc|\(chatA)")
        try expectEqual(project.lastText, "Hallo & Team")
        try expectEqual(project.unread, 0, "beim ersten Blick gilt alles als gelesen")
        try expect(!project.isDirect)
        let bruno = try expectNotNil(list.first { $0.title == "Bruno" })
        try expect(bruno.isDirect)
        try expectEqual(bruno.lastText, nil, "Systemmeldung ist keine Vorschau")
      },

      CheckCase("Teams: neue Nachricht eines anderen ist ungelesen, Lesestand setzt zurück") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/chats", [chatsFirst(), chatsSecond()])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        _ = try await c.conversations()
        let later = try await c.conversations()
        let project = try expectNotNil(later.first { $0.title == "Projekt" })
        try expectEqual(project.unread, 1)
        try expectEqual(project.lastText, "Bist du da?")
        try await c.markRead(roomId: chatA)
        let after = try await c.conversations()
        try expectEqual(try expectNotNil(after.first { $0.title == "Projekt" }).unread, 0)
      },

      CheckCase("Teams: Nachrichten ohne Systemmeldungen, HTML bereinigt, älteste zuerst, eigene als „Ich“") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/chats/\(chatA)/messages", [messagesPayload()])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let msgs = try await c.messages(roomId: chatA, limit: 10)
        try expectEqual(msgs.map(\.id), ["m1", "m3"], "Systemmeldung fällt weg, älteste zuerst")
        try expectEqual(msgs[0].sender, "Anna")
        try expectEqual(msgs[0].text, "Hi\nDu", "HTML ist entfernt")
        try expect(!msgs[0].mine)
        try expectEqual(msgs[1].sender, "Ich")
        try expect(msgs[1].mine)
        try expectEqual(msgs[1].conversationId, "acc|\(chatA)")
        try expectEqual(msgs[1].at, LocalTime.format(TeamsConnector.instant("2026-10-20T09:10:00Z")!), "lokale Zeit")
      },

      CheckCase("Teams: Senden als Text-Nachricht an den Chat") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("POST /v1.0/me/chats/\(chatA)/messages", [(201, ["id": "sent"])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        try await c.send(roomId: chatA, text: "Hallo \"Team\"")
        let post = try expectNotNil(h.graphSeen.last)
        try expectEqual(post.method, "POST")
        let body = try expectNotNil(JSONValue.parse(post.body))
        try expectEqual(body["body"]?["contentType"]?.stringValue, "text")
        try expectEqual(body["body"]?["content"]?.stringValue, "Hallo \"Team\"")
      },

      CheckCase("Teams: Fehler 403 (fehlende Freigabe) kommt mit dem IT-Hinweis") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/chats", [(403, ["error": ["code": "Forbidden"]])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        do {
          _ = try await c.conversations()
          throw CheckFailure(message: "403 muss scheitern", location: "MicrosoftTeamsChecks")
        } catch let f as MessengerFailure {
          try expectEqual(f.message, "Microsoft verweigert den Zugriff (403). \(MicrosoftChecks.consent)")
        }
      },

      CheckCase("Teams-Status: setzt „Nicht stören“ (PT1H), liest den Lumi-Status zurück, löscht ihn") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/presence", [(200, ["availability": "Available", "activity": "Available"])])
        h.setGraph("POST /v1.0/me/presence/setUserPreferredPresence", [(200, [:])])
        h.setGraph("POST /v1.0/me/presence/clearUserPreferredPresence", [(200, [:])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let before = try await c.readStatus()
        try expectEqual(before.text, "", "ohne Status")
        try await c.writeStatus(text: "Im Fokus", emoji: ":headphones:", until: nil)
        let set = try expectNotNil(h.graphSeen.last)
        try expectEqual(set.url.path, "/v1.0/me/presence/setUserPreferredPresence")
        let body = try expectNotNil(JSONValue.parse(set.body))
        try expectEqual(body["availability"]?.stringValue, "DoNotDisturb")
        try expectEqual(body["activity"]?.stringValue, "DoNotDisturb")
        try expectEqual(body["expirationDuration"]?.stringValue, "PT1H")
        h.setGraph("GET /v1.0/me/presence", [(200, ["availability": "DoNotDisturb", "activity": "DoNotDisturb"])])
        let mine = try await c.readStatus()
        try expectEqual(mine.text, "Im Fokus")
        try expectEqual(mine.emoji, ":headphones:")
        try await c.writeStatus(text: "", emoji: "", until: nil)
        try expectEqual(h.graphSeen.last?.url.path, "/v1.0/me/presence/clearUserPreferredPresence")
      },

      CheckCase("Teams-Status: nur bei eingeschaltetem „Status automatisch“ gibt es Presence-Aufrufe") {
        let clock = ControllableClock("2026-10-20T10:00")
        let store = try Store.inMemory(clock: clock)
        let focus = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
        let h = MicrosoftHarness()
        try signedIn(h)
        h.clock.set(clock.now())
        h.setGraph("GET /v1.0/me/presence", [(200, ["activity": "Available"])])
        h.setGraph("POST /v1.0/me/presence/setUserPreferredPresence", [(200, [:])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let targets: [(accountId: String, setting: StatusSetting)] = [(accountId: "acc", setting: c)]
        let off = await MainActor.run { AutoStatusController(repo: store.autoStatus, clock: clock, targets: { targets }, enabled: { false }) }
        await off.reconcile(focus: focus, meeting: nil, dayEnded: false)
        try expect(!h.graphSeen.contains { $0.url.path.contains("presence") }, "ausgeschaltet: kein Presence-Aufruf")
        let on = await MainActor.run { AutoStatusController(repo: store.autoStatus, clock: clock, targets: { targets }, enabled: { true }) }
        await on.reconcile(focus: focus, meeting: nil, dayEnded: false)
        let set = h.graphSeen.filter { $0.url.path.hasSuffix("setUserPreferredPresence") }
        try expectEqual(set.count, 1, "eingeschaltet: genau ein Setzen")
      },

      CheckCase("Microsoft im Kern: Anmelden legt Konto, Outlook-Quelle und Teams an, Abmelden räumt alles auf") {
        let h = MicrosoftHarness()
        h.setGraph("GET /v1.0/me", [me])
        h.setGraph("GET /v1.0/me/chats", [chatsFirst()])
        h.setGraph("GET /v1.0/me/chats/\(chatA)/messages", [messagesPayload()])
        h.tokenReplies = [MicrosoftChecks.pending(), MicrosoftChecks.tokens()]
        var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: h.clock, keyStore: InMemoryApiKeyStore(),
                                        systemNotifier: SinkNotifier(), session: h.urlSession(), plannerInterval: nil,
                                        calendarSecrets: { _ in InMemoryApiKeyStore() },
                                        notionOAuthClientSecrets: { InMemoryApiKeyStore() })
        opts.messengerPollInterval = nil
        opts.microsoftRefreshStore = h.refresh
        opts.microsoftPause = { seconds in h.clock.advance(seconds: seconds) }
        let config = opts
        let svc = try await MainActor.run { try CoreServices(options: config) }

        _ = await svc.updateSettings(SettingsPatch(microsoftClientId: MicrosoftHarness.clientId), apiKey: nil)
        let sign = await svc.startMicrosoftSignIn()
        try expectEqual(try expectNotNil(sign.value).userCode, "ABCD-1234")
        let finished = await svc.finishMicrosoftSignIn()
        try expectEqual(finished.value, "felix@contoso.de")
        var state = await svc.state()
        try expectEqual(state.settings.microsoftAccount, "felix@contoso.de")
        try expect(state.calendarSources.contains { $0.id == "microsoft" && $0.kind == .microsoft && $0.enabled }, "Outlook-Quelle")
        try expect(!String(describing: state).contains("rt-1"), "Erneuerungs-Token nie im Zustand")
        try expectEqual(try h.refresh.get(), "rt-1")

        let teams = await svc.connectMessenger(MessengerLogin(service: .teams))
        let account = try expectNotNil(teams.value, teams.errorMessage ?? "Teams verbinden")
        let convId = "\(account.id)|\(chatA)"
        let tool = await svc.tool("list_messages", ["conversation_id": .string(convId)]).jsonString()
        try expect(tool.contains("<fremder_inhalt>"), "Teams-Text läuft durch die Fremdinhalt-Hülle wie bei Slack")
        try expect(tool.contains("Hi"), tool)

        // Lumi hat einen Teams-Status gesetzt: Abmelden räumt ihn vor dem Abmelden.
        h.setGraph("POST /v1.0/me/presence/clearUserPreferredPresence", [(200, [:])])
        try await MainActor.run {
          try svc.store.autoStatus.set(AutoStatusRecord(accountId: account.id, kind: "focus", text: "Im Fokus",
                                                        emoji: ":headphones:", endsAt: "2026-10-20T10:25"))
        }
        let gone = await svc.disconnectMicrosoft()
        try expect(gone.isOk)
        try expect(h.graphSeen.contains { $0.url.path.hasSuffix("clearUserPreferredPresence") }, "Teams-Status vor dem Abmelden geräumt")
        let leftover = try await MainActor.run { try svc.store.autoStatus.list() }
        try expect(leftover.isEmpty, "Eintrag von Lumi entfernt")
        state = await svc.state()
        try expectEqual(state.settings.microsoftAccount, "")
        try expect(!state.calendarSources.contains { $0.kind == .microsoft }, "Outlook-Quelle entfernt")
        try expect(!state.messengerAccounts.contains { $0.service == .teams }, "Teams abgemeldet")
        try expect(try h.refresh.get() == nil, "Erneuerungs-Token gelöscht")
      },

      CheckCase("Teams: Wiederherstellen nach Neustart braucht die Microsoft-Anmeldung") {
        let h = MicrosoftHarness()
        let c = connector(h)
        let account = MessengerAccount(id: "acc", service: .teams, user: "felix@contoso.de")
        do {
          _ = try await c.restore(account, secret: "")
          throw CheckFailure(message: "ohne Anmeldung muss das Wiederherstellen scheitern", location: "MicrosoftTeamsChecks")
        } catch is MessengerFailure {}
        try h.signedIn()
        let back = try await c.restore(account, secret: "")
        try expectEqual(back.id, "acc")
      },

      CheckCase("Teams: ohne Freigabe für Chats (nur Kalender) kommt der Hinweis, es wird nichts geladen") {
        let h = MicrosoftHarness()
        h.grantedScope = MicrosoftChecks.calendarScope
        try signedIn(h)
        h.setGraph("GET /v1.0/me/chats", [chatsFirst()])
        let c = connector(h)
        do {
          _ = try await c.conversations()
          throw CheckFailure(message: "ohne Chat-Freigabe darf nichts laden", location: "MicrosoftTeamsChecks")
        } catch let f as MessengerFailure {
          try expectEqual(f.message, MicrosoftAuth.teamsNotReleasedText)
        }
        try expect(!h.graphSeen.contains { $0.url.path.hasSuffix("/me/chats") }, "keine Chat-Anfrage")
      },

      CheckCase("Teams-Status: Ablauf folgt dem geplanten Ende, mindestens PT5M, höchstens PT8H") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/presence", [(200, ["activity": "Available"])])
        h.setGraph("POST /v1.0/me/presence/setUserPreferredPresence", [(200, [:])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let now = h.clock.now()
        for (minutes, expected) in [(90, "PT1H30M"), (2, "PT5M"), (600, "PT8H"), (60, "PT1H")] {
          try await c.writeStatus(text: "Im Termin", emoji: ":calendar:", until: now.addingTimeInterval(TimeInterval(minutes * 60)))
          let body = try expectNotNil(JSONValue.parse(try expectNotNil(h.graphSeen.last).body))
          try expectEqual(body["expirationDuration"]?.stringValue, expected, "\(minutes) Minuten")
        }
      },

      CheckCase("Teams-Status: lange Termine werden im Takt verlängert, bis das Ende erreicht ist") {
        let h = MicrosoftHarness()
        try signedIn(h)
        h.setGraph("GET /v1.0/me/presence", [(200, ["activity": "Available"])])
        h.setGraph("POST /v1.0/me/presence/setUserPreferredPresence", [(200, [:])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let start = h.clock.now()
        let until = start.addingTimeInterval(10 * 3600)
        try await c.writeStatus(text: "Im Termin", emoji: ":calendar:", until: until)
        try await c.refreshStatus(until: until)
        try expectEqual(h.graphSeen.filter { $0.url.path.hasSuffix("setUserPreferredPresence") }.count, 1, "am Anfang keine Verlängerung")
        h.clock.advance(seconds: 28_200)  // 7 h 50 min: die 8 h sind in zehn Minuten um
        try await c.refreshStatus(until: until)
        let sets = h.graphSeen.filter { $0.url.path.hasSuffix("setUserPreferredPresence") }
        try expectEqual(sets.count, 2, "eine Verlängerung im Takt")
        let body = try expectNotNil(JSONValue.parse(try expectNotNil(sets.last).body))
        try expectEqual(body["expirationDuration"]?.stringValue, "PT2H10M", "bis zum Ende noch 2 h 10 min")
      },

      CheckCase("Teams-Status: nach dem Neustart räumt Lumi den Status am Eintrag, nicht am Text") {
        let clock = ControllableClock("2026-10-20T10:00")
        let store = try Store.inMemory(clock: clock)
        let h = MicrosoftHarness()
        h.clock.set(clock.now())
        try signedIn(h)
        try store.autoStatus.set(AutoStatusRecord(accountId: "acc", kind: "focus", text: "Im Fokus", emoji: ":headphones:",
                                                  endsAt: "2026-10-20T10:25"))
        // Teams meldet nach dem Neustart nur „Nicht stören“, kein Lumi-Text mehr.
        h.setGraph("GET /v1.0/me/presence", [(200, ["availability": "DoNotDisturb", "activity": "DoNotDisturb"])])
        h.setGraph("POST /v1.0/me/presence/clearUserPreferredPresence", [(200, [:])])
        let c = connector(h)
        _ = try await c.login(MessengerLogin(service: .teams), accountId: "acc")
        let targets: [(accountId: String, setting: StatusSetting)] = [(accountId: "acc", setting: c)]
        let ctl = await MainActor.run { AutoStatusController(repo: store.autoStatus, clock: clock, targets: { targets }, enabled: { false }) }
        await ctl.reconcile(focus: nil, meeting: nil, dayEnded: false)
        try expect(h.graphSeen.contains { $0.url.path.hasSuffix("clearUserPreferredPresence") }, "Status geräumt")
        try expect(try store.autoStatus.list().isEmpty, "Eintrag weg")
      },

      CheckCase("Teams-Status: ohne Eintrag von Lumi räumt nichts; eigene Meldungen bleiben") {
        let c = TeamsConnector(auth: MicrosoftHarness().auth, clock: ControllableClock("2026-10-20T10:00"))
        let record = AutoStatusRecord(accountId: "acc", kind: "focus", text: "Im Fokus", emoji: ":headphones:",
                                      endsAt: "2026-10-20T10:25")
        try expect(!c.ownsStatus(("Mein Status", ":coffee:"), record: record), "eigener Status bleibt")
        try expect(!c.ownsStatus(("", ""), record: record), "kein Status")
        try expect(c.ownsStatus((TeamsConnector.userDndText, ""), record: record), "Nicht stören mit Eintrag")
        try expect(c.ownsStatus(("Im Fokus", ":headphones:"), record: record), "in der Sitzung gesetzter Lumi-Status")
      },
    ]
  }
}
