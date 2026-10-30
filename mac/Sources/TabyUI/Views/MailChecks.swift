// Prüfungen und Snapshots für Paket 5 (Mail-Reiter, Mail-Einstellungen).
// Logik ohne Fenster, Ansichten als PNG (ImageRenderer).
import SwiftUI
import TabyCore

enum MailChecks {
  static let now = "2026-10-11T09:00"

  @MainActor static var cases: [CheckCase] {
    logicCases + actionCases + taskFromMessageCases + MailTaskCardChecks.cases + UndoBannerChecks.cases
  }

  // MARK: - Daraus Aufgabe (Mail und Chat)

  static var taskFromMessageCases: [CheckCase] {
    [
      CheckCase("Daraus Aufgabe: Mail nimmt Betreff und verlinkt die Message-ID") {
        let m = MailMessage(id: "<abc@mail.example>", senderName: "Lena", senderAddress: "lena@example.com",
                            subject: "Angebot bis Freitag", date: "2026-10-11T08:00", read: false, flagged: false)
        let t = TaskFromMessage.mail(m)
        try expectEqual(t.title, "Angebot bis Freitag")
        try expect(t.notes.contains("Mail von Lena <lena@example.com>"), "Absender fehlt in den Notizen")
        try expect(t.notes.contains("message://%3Cabc@mail.example%3E"), "Rückverweis fehlt: \(t.notes)")
      },
      CheckCase("Daraus Aufgabe: Mail ohne Betreff nimmt den Absender als Titel") {
        let m = MailMessage(id: "", senderName: "Lena", senderAddress: "lena@example.com",
                            subject: "  ", date: "2026-10-11T08:00", read: true, flagged: false)
        let t = TaskFromMessage.mail(m)
        try expectEqual(t.title, "Lena")
        try expect(!t.notes.contains("message://"), "ohne Message-ID kein Link")
      },
      CheckCase("Daraus Aufgabe: Chat – kurzer Titel mit Absender, voller Text und Rückverweis in den Notizen") {
        let msg = MessengerMessage(id: "1", conversationId: "c", sender: "Max", text: "Bitte Bericht schicken\nDanke",
                                   at: "2026-10-11T08:00")
        let conv = MessengerConversation(id: "c", accountId: "a", title: "Team Ost")
        let t = TaskFromMessage.chat(msg, in: conv)
        try expectEqual(t.title, "Max: Bitte Bericht schicken")
        try expectEqual(t.notes, "Bitte Bericht schicken\nDanke\n\nVon Max in Team Ost, 11.10. 08:00")
        let el = TaskFromMessage.chat(msg, in: conv, service: "Element")
        try expectEqual(el.title, "Max (Element): Bitte Bericht schicken")
        try expect(el.notes.hasSuffix("Von Max in Team Ost (Element), 11.10. 08:00"), el.notes)
        let second = MessengerMessage(id: "2", conversationId: "c", sender: "Eva", text: "bis Freitag",
                                      at: "2026-10-11T08:01")
        let both = TaskFromMessage.chat([msg, second], in: conv)
        try expectEqual(both.title, "Max: Bitte Bericht schicken")
        try expect(both.notes.contains("Max: Bitte Bericht") && both.notes.contains("Eva: bis Freitag"), both.notes)
      },
      CheckCase("Daraus Aufgabe: langer Satz wird zu einem kurzen Titel (7 Wörter, höchstens 48 Zeichen)") {
        let long = "Ich hab auch schon mehrfach über ein ticketsystem nachgedacht, dass die Mail lesen kann und Antworten vorschlägt."
        try expectEqual(TaskFromMessage.shortTitle(long), "Ich hab auch schon mehrfach über ein…")
        try expectEqual(TaskFromMessage.shortTitle("Kurz und knapp"), "Kurz und knapp")
        try expectEqual(TaskFromMessage.shortTitle(""), "")
        let msg = MessengerMessage(id: "1", conversationId: "c", sender: "Antonia", text: long, at: "2026-10-22T11:28")
        let conv = MessengerConversation(id: "c", accountId: "a", title: "Antonia")
        let t = TaskFromMessage.chat(msg, in: conv, service: "Element")
        try expectEqual(t.title, "Antonia (Element): Ich hab auch schon mehrfach über ein…")
        try expect(t.notes.hasPrefix(long), "voller Text vorn in den Notizen")
        try expect(t.notes.hasSuffix("22.10. 11:28"), t.notes)
        try expectEqual(TaskFromMessage.chat(MessengerMessage(id: "2", conversationId: "c", sender: "Eva", text: "  ", at: ""),
                                             in: conv).title, "Nachricht von Eva")
      },
    ]
  }

  // MARK: - Reine Logik

  @MainActor static var logicCases: [CheckCase] {
    [
      CheckCase("Mail: Zeit heute, gestern, Wochentag, Datum") {
        try expectEqual(MailLogic.relativeTime("2026-10-11T08:41", now: now), "08:41")
        try expectEqual(MailLogic.relativeTime("2026-10-11T23:59", now: now), "23:59")
        try expectEqual(MailLogic.relativeTime("2026-10-10T19:02", now: now), "gestern")
        try expectEqual(MailLogic.relativeTime("2026-10-09T07:15", now: now), "Fr")
        try expectEqual(MailLogic.relativeTime("2026-10-05T07:15", now: now), "Mo")
        try expectEqual(MailLogic.relativeTime("2026-10-04T07:15", now: now), "04.10.")
        try expectEqual(MailLogic.relativeTime("kaputt", now: now), "kaputt")
      },
      CheckCase("Mail: Julianische Tageszahl und Wochentag-Anker") {
        try expectEqual(MailLogic.dayNumber("2000-01-01"), 2451545)
        try expectEqual(MailLogic.dayNumber("2026-10-11T09:00"), MailLogic.dayNumber("2026-10-11"))
        try expect(MailLogic.dayNumber("2026-13") == nil, "Unvollständiges Datum muss nil sein")
      },
      CheckCase("Mail: Filter Wichtig, Alle, Newsletter (neueste zuerst)") {
        let msgs = [
          MailMessage(id: "a", senderName: "Zalando", senderAddress: "z@example.com", subject: "Angebot",
                      date: "2026-10-10T10:00", category: .newsletter),
          MailMessage(id: "b", senderName: "Lena", senderAddress: "l@example.com", subject: "Abend?",
                      date: "2026-10-11T08:00", category: .important),
          MailMessage(id: "c", senderName: "Max", senderAddress: "m@example.com", subject: "Fotos",
                      date: "2026-10-11T07:00", category: .normal),
        ]
        try expectEqual(MailLogic.filter(msgs, .all).map(\.id), ["b", "c", "a"])
        try expectEqual(MailLogic.filter(msgs, .important).map(\.id), ["b"])
        try expectEqual(MailLogic.filter(msgs, .newsletter).map(\.id), ["a"])
      },
      CheckCase("Mail: Standardfilter Wichtig nur bei ungelesenen wichtigen Mails") {
        let unreadImportant = [MailMessage(id: "a", senderName: "", senderAddress: "a@b.c", subject: "x",
                                           date: "2026-10-11T08:00", category: .important)]
        let readImportant = [MailMessage(id: "a", senderName: "", senderAddress: "a@b.c", subject: "x",
                                         date: "2026-10-11T08:00", read: true, category: .important)]
        try expectEqual(MailLogic.defaultFilter(unreadImportant), .important)
        try expectEqual(MailLogic.defaultFilter(readImportant), .all)
        try expectEqual(MailLogic.defaultFilter([]), .all)
      },
      CheckCase("Mail: Absenderanzeige fällt auf die Adresse zurück") {
        let named = MailMessage(id: "a", senderName: "Lena Weber", senderAddress: "lena@example.com", subject: "", date: "")
        let unnamed = MailMessage(id: "b", senderName: "  ", senderAddress: "info@example.com", subject: "", date: "")
        try expectEqual(MailLogic.senderLabel(named), "Lena Weber")
        try expectEqual(MailLogic.senderLabel(unnamed), "info@example.com")
      },
      CheckCase("Mail: Vorschau kürzt auf 600 Zeichen mit Auslassung") {
        let short = "Hallo Felix,\n\nbis morgen.\n"
        try expectEqual(MailLogic.previewText(short), "Hallo Felix,\n\nbis morgen.")
        let long = String(repeating: "a", count: 700)
        let cut = MailLogic.previewText(long)
        try expectEqual(cut.count, MailLogic.previewLimit + 1)
        try expect(cut.hasSuffix("…"), "Gekürzter Text endet mit …")
        try expectEqual(MailLogic.previewText(String(repeating: "b", count: 600)).count, 600)
      },
      CheckCase("Mail: Insel-Zeile „3 ungelesen · 2 wichtig“, Aus und Fehler") {
        try expectEqual(MailLogic.islandLines(nil), ["Aus"])
        let fake = FakeServices(sample: false, today: "2026-10-11")
        try expectEqual(MailLogic.islandLines(fake.sampleMail()), ["3 ungelesen · 2 wichtig"])
        try expectEqual(MailLogic.islandLines(MailOverview(error: "x", accessDenied: true)), ["Freigabe fehlt"])
        try expectEqual(MailLogic.islandLines(MailOverview(error: "x")), ["Nicht erreichbar"])
        try expectEqual(MailLogic.islandLines(MailOverview()), ["Alles gelesen"])
      },
      CheckCase("Einstellungen: Mail- und Claude-Schalter werden gepatcht") {
        try expectEqual(TabySettings.defaults.mailEnabled, false)
        try expectEqual(TabySettings.defaults.mailLocalOnly, true)
        var changed = TabySettings.defaults
        changed.mailEnabled = true
        changed.claudeNotify = false
        let patch = SettingsLogic.patch(from: TabySettings.defaults, to: changed)
        try expectEqual(patch.mailEnabled, true)
        try expectEqual(patch.claudeNotify, false)
        try expectEqual(patch.mailLocalOnly, nil)
      },
    ]
  }

  // MARK: - Aktionen gegen Fakes

  @MainActor static var actionCases: [CheckCase] {
    [
      CheckCase("Mail: lesen, markieren, archivieren und Papierkorb ändern den Zustand") {
        let fake = FakeServices(sample: false)
        fake.current.mail = fake.sampleMail()
        _ = await fake.setMailRead("m1", true)
        try expectEqual(fake.current.mail?.unread, 2)
        _ = await fake.setMailFlagged("m1", true)
        try expect(fake.current.mail?.messages.first { $0.id == "m1" }?.flagged == true, "Markierung fehlt")
        _ = await fake.archiveMail("m4")
        try expectEqual(fake.current.mail?.messages.count, 3)
        _ = await fake.trashMail("m2")
        try expectEqual(fake.current.mail?.messages.map(\.id), ["m1", "m3"])
        try expectEqual(fake.current.mail?.unread, 0)
      },
      CheckCase("Mail: Entwurf geht an den Absender, Aufgabe aus Mail") {
        let fake = FakeServices(sample: false)
        fake.current.mail = fake.sampleMail()
        let draft = try await fake.draftMailReply("m1", instruction: "Ja, 19 Uhr passt")
        try expectEqual(draft.replyToId, "m1")
        try expectEqual(draft.to, ["lena@example.com"])
        try expect(draft.subject.hasPrefix("Re:"), "Betreff der Antwort beginnt mit Re:")
        let sent = await fake.sendMail(draft)
        try expect(sent.isOk, "Senden nach Klick muss gelingen")
        let task = await fake.mailToTask("m1")
        try expect(task.value?.title.hasPrefix("Antworten:") == true, "Aufgabentitel aus dem Betreff")
      },
    ]
  }
}

// MARK: - Snapshots

extension MailChecks {
  static let sampleBody = "Hi Felix,\n\nkommst du heute Abend um 19 Uhr mit ins Kino?\n\nLG Lena"

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-mail", size: ViewSnapshots.size) {
        let fake = FakeServices()
        fake.current.mail = fake.sampleMail()
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .mail, preview: fake.current), model)
      },
      SnapshotSpec("view-mail-off", size: ViewSnapshots.size) {
        let fake = FakeServices()
        fake.current.mail = nil
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .mail, preview: fake.current), model)
      },
      SnapshotSpec("view-mail-expanded", size: CGSize(width: TabLayout.contentWidth, height: 520)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let preview = MailPreview(expandedId: "m1", body: sampleBody)
        return wrap(MailView(mail: fake.sampleMail(), preview: preview).tabyPage(), model)
      },
      SnapshotSpec("view-mail-reply-preview", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let draft = MailDraft(replyToId: "m1", to: ["lena@example.com"], subject: "Re: Kommst du heute Abend?",
                              body: "Hi Lena,\n\nja, 19 Uhr passt!\n\nLG Felix")
        let preview = MailPreview(expandedId: "m1", body: sampleBody, draft: draft)
        return wrap(MailView(mail: fake.sampleMail(), preview: preview).tabyPage(), model)
      },
      SnapshotSpec("view-mail-error-denied", size: ViewSnapshots.size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let denied = MailOverview(error: "Lumi darf Apple Mail nicht steuern. Erlaube es in den Systemeinstellungen.",
                                  accessDenied: true)
        return wrap(MailView(mail: denied).tabyPage(), model)
      },
      SnapshotSpec("view-settings-mail", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .accounts)
        view.pageHeight = 360
        return wrap(view.tabyPage(), model)
      },
    ] + MailTaskCardChecks.snapshots
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true))
  }
}
