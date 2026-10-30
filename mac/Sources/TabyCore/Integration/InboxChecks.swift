// Prüfungen für den Eingang: Regeln mit fester Zeit, Erledigt-Speicher über einen Neustart,
// Entwurf-Skript ohne Werte im Quelltext und der Weg über den echten Kern mit einer Mail-Attrappe.
import Foundation

enum InboxChecks {
  static let now = LocalTime.parse("2026-10-12T08:00")!

  static func mail(_ id: String, _ subject: String, at: String, read: Bool = false, flagged: Bool = false) -> MailMessage {
    MailMessage(id: id, senderName: "Lena Weber", senderAddress: "lena@example.com", subject: subject, date: at,
                read: read, flagged: flagged)
  }

  static func chat(_ id: String, unread: Int, at: String, direct: Bool = true) -> MessengerConversation {
    MessengerConversation(id: id, accountId: "acc", title: id, unread: unread, lastText: "text", lastAt: at, isDirect: direct)
  }

  static func last(_ conv: String, mine: Bool, at: String) -> MessengerMessage {
    MessengerMessage(id: "\(conv)-\(at)", conversationId: conv, sender: mine ? "Ich" : "Anna", text: "text", at: at,
                     mine: mine)
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Eingang: Mail-Regeln (Frage, Frist, Newsletter, gelesen)") {
        let raw = [
          mail("q", "Kino heute?", at: "2026-10-12T07:30"),
          mail("flag", "Info", at: "2026-10-12T07:00", read: true, flagged: true),
          mail("alt", "Frage?", at: "2026-10-08T09:00"),
          mail("gelesen", "Frage?", at: "2026-10-12T07:00", read: true),
          MailMessage(id: "news", senderName: "Shop", senderAddress: "newsletter@shop.example",
                      subject: "Sale: 20 % auf alles", date: "2026-10-12T06:00"),
          MailMessage(id: "bob", senderName: "Bob", senderAddress: "bob@example.com", subject: "Hallo",
                      date: "2026-10-12T07:45"),
        ]
        let msgs = MailTriage.overview(raw, now: "2026-10-12T08:00").messages
        let items = InboxRules.mailItems(msgs, now: now)
        try expectEqual(Set(items.map(\.id)), ["q", "flag"])
        try expectEqual(items.first(where: { $0.id == "q" })?.kind, .needsReply)
        try expectEqual(items.first?.channel, "Mail")
      },

      CheckCase("Eingang: Chat-Regeln (Antwort nötig, wartet, Auswahl)") {
        let convs = [
          chat("a", unread: 1, at: "2026-10-12T07:00"),   // Antwort nötig
          chat("b", unread: 0, at: "2026-10-12T07:00"),   // gelesen, letzte Nachricht von dir ist nicht da
          chat("c", unread: 0, at: "2026-10-11T07:00"),   // wartet (25 Stunden)
          chat("d", unread: 0, at: "2026-10-12T07:50"),   // zu frisch
          chat("e", unread: 2, at: "2026-10-12T07:00", direct: false),
          chat("f", unread: 1, at: "2026-10-12T07:50"),   // zu frisch
          chat("g", unread: 1, at: "2026-09-01T07:00"),   // älter als 14 Tage
        ]
        let lastMessages = [
          "a": last("a", mine: false, at: "2026-10-12T07:00"),
          "b": last("b", mine: false, at: "2026-10-12T07:00"),
          "c": last("c", mine: true, at: "2026-10-11T07:00"),
          "d": last("d", mine: true, at: "2026-10-12T07:50"),
          "e": last("e", mine: false, at: "2026-10-12T07:00"),
          "f": last("f", mine: false, at: "2026-10-12T07:50"),
          "g": last("g", mine: false, at: "2026-09-01T07:00"),
        ]
        try expectEqual(Set(InboxRules.chatCandidates(convs, now: now).map(\.id)), ["a", "b", "c"])
        let items = InboxRules.ordered(InboxRules.chatItems(convs, last: lastMessages, channels: ["acc": "Slack"], now: now))
        try expectEqual(items.map(\.id), ["a", "c"])
        try expectEqual(items.map(\.kind), [.needsReply, .waiting])
        try expectEqual(items.first?.channel, "Slack")
      },

      CheckCase("Eingang: Reihenfolge, Zähler und Erledigt-Regel") {
        let w = InboxItem(id: "w", kind: .waiting, channel: "Slack", title: "W", from: "Du", at: "2026-10-12T07:00")
        let n1 = InboxItem(id: "n1", kind: .needsReply, channel: "Mail", title: "N1", from: "X", at: "2026-10-12T06:00")
        let n2 = InboxItem(id: "n2", kind: .needsReply, channel: "Mail", title: "N2", from: "X", at: "2026-10-12T07:30")
        try expectEqual(InboxRules.ordered([w, n1, n2]).map(\.id), ["n2", "n1", "w"])
        try expectEqual(InboxRules.needsReplyCount([w, n1, n2]), 2)
        // Erledigt bis zur gleichen Zeit: bleibt weg. Erst eine neuere Nachricht bringt den Punkt zurück.
        let dismissed = ["n1": "2026-10-12T06:00", "w": "2026-10-12T07:00"]
        try expectEqual(InboxRules.visible([n1, n2, w], dismissed: dismissed).map(\.id), ["n2"])
        let newer = InboxItem(id: "w", kind: .waiting, channel: "Slack", title: "W", from: "Du", at: "2026-10-12T07:10")
        try expectEqual(InboxRules.visible([newer], dismissed: dismissed).map(\.id), ["w"])
      },

      CheckCase("Eingang: Erledigt überlebt einen Neustart") {
        let path = NSTemporaryDirectory() + "inbox-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let clock = ControllableClock("2026-10-12T08:00")
        do {
          let store = try Store.open(path: path, clock: clock)
          try store.inboxDismissed.set("m1", at: "2026-10-12T07:30")
        }
        let reopened = try Store.open(path: path, clock: clock)
        try expectEqual(try reopened.inboxDismissed.all(), ["m1": "2026-10-12T07:30"])
        let item = InboxItem(id: "m1", kind: .needsReply, channel: "Mail", title: "T", from: "L", at: "2026-10-12T07:30")
        try expectEqual(InboxRules.visible([item], dismissed: try reopened.inboxDismissed.all()).count, 0)
        try reopened.inboxDismissed.set("m1", at: "2026-10-12T07:40")
        try expectEqual(try reopened.inboxDismissed.all(), ["m1": "2026-10-12T07:40"])
      },

      CheckCase("Eingang: Entwurf-Skript baut keine Werte in den Quelltext") {
        let evil = "x\"); Mail.quit(); (\"\n'"
        let arg = JSONValue.object(["id": .string(evil)]).jsonString()
        let parsed = try JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: String]
        try expectEqual(parsed?["id"], evil)
        try expect(!arg.contains("\n"), "Zeilenumbruch im JSON-Argument")
        try expect(!AppleMailScripts.replyDraft.contains(evil), "Kennung steht im Skript")
        try expect(!AppleMailScripts.replyDraft.contains("send"), "Entwurf-Skript sendet")
        try expect(AppleMailScripts.replyDraft.contains("openingWindow: true"), "Antwortfenster nicht offen")
      },

      CheckCase("Eingang: Kern – Entwurf öffnet nur, Erledigt blendet aus") {
        let (svc, backend, _) = try PackageFiveIntegrationChecks.rig()
        _ = await svc.updateSettings(SettingsPatch(mailEnabled: true), apiKey: nil)
        _ = await svc.refreshMail()
        let before = await svc.state().inbox.map(\.id)
        try expect(before.contains("m1"), "m1 fehlt im Eingang: \(before)")
        try expect(!before.contains("m2"), "Newsletter im Eingang")
        let draft = await svc.draftReply("m1")
        try expect(draft.isOk, "Entwurf fehlgeschlagen: \(draft.errorMessage ?? "")")
        try expect(backend.calls.contains("reply-draft:m1"), "kein Entwurf-Aufruf bei Apple Mail")
        try expect(backend.sent.isEmpty, "Antwort wurde gesendet")
        await svc.markInboxDone("m1")
        let after = await svc.state().inbox.map(\.id)
        try expect(!after.contains("m1"), "erledigter Punkt bleibt sichtbar")
        let missing = await svc.draftReply("nicht-da")
        try expect(missing.errorMessage != nil, "unbekannter Punkt ohne Fehler")
      },
    ]
  }
}
