// Prüfungen und Snapshots für „Daraus Aufgabe“ mit Karte (Mail und Chat): Fälligkeit, Kategorie,
// Notizen, Anlegen über ViewActions gegen FakeServices und die Karte unter der Mail-Liste.
import SwiftUI
import TabyCore

enum MailTaskCardChecks {
  static let today = "2026-10-11"
  static let sportDefs = TaskCategoryDef.builtIn + [TaskCategoryDef(id: "sport", name: "Sport", symbol: "figure.run")]

  static func mail() -> MailMessage {
    MailMessage(id: "<abc@mail.example>", senderName: "Lena", senderAddress: "lena@example.com",
                subject: "Angebot bis Freitag", date: "2026-10-11T08:00", read: false, flagged: false)
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Karte: ohne gewähltes Datum bleibt die Aufgabe ohne Fälligkeit") {
        let d = TaskFromMessage.compose(title: "Angebot", notes: "n", categoryId: nil, categories: sportDefs,
                                        mode: .none, today: today, date: "2026-10-14", time: "09:00")
        try expect(d != nil, "Titel reicht zum Anlegen")
        try expect(d?.due == nil, "Ohne Datum keine Fälligkeit, auch mit Uhrzeit: \(d?.due ?? "-")")
      },
      CheckCase("Karte: heute mit Uhrzeit wird zu „Datum THH:mm“, morgen ohne Uhrzeit nur Datum") {
        let today1 = TaskFromMessage.compose(title: "A", notes: "", categoryId: nil, categories: sportDefs,
                                             mode: .today, today: today, date: nil, time: "14:30")
        try expectEqual(today1?.due, "2026-10-11T14:30")
        let tomorrow = TaskFromMessage.compose(title: "A", notes: "", categoryId: nil, categories: sportDefs,
                                               mode: .tomorrow, today: today, date: nil, time: nil)
        try expectEqual(tomorrow?.due, "2026-10-12")
      },
      CheckCase("Karte: eigenes Datum ohne Uhrzeit ist nur das Datum") {
        let d = TaskFromMessage.compose(title: "A", notes: "", categoryId: nil, categories: sportDefs,
                                        mode: .custom, today: today, date: "2026-10-20", time: nil)
        try expectEqual(d?.due, "2026-10-20")
        let timed = TaskFromMessage.compose(title: "A", notes: "", categoryId: nil, categories: sportDefs,
                                            mode: .custom, today: today, date: "2026-10-20", time: "09:30")
        try expectEqual(timed?.due, "2026-10-20T09:30")
      },
      CheckCase("Karte: Kategorie „Keine“ und unbekannte Kategorie ergeben nil") {
        let none = TaskFromMessage.compose(title: "A", notes: "", categoryId: nil, categories: sportDefs,
                                           mode: .none, today: today, date: nil, time: nil)
        try expect(none?.categoryId == nil, "Keine Kategorie")
        let unknown = TaskFromMessage.compose(title: "A", notes: "", categoryId: "gibts-nicht",
                                              categories: sportDefs, mode: .none, today: today, date: nil, time: nil)
        try expect(unknown?.categoryId == nil, "Unbekannte Kennung zählt als keine")
      },
      CheckCase("Karte: leerer Titel wird abgelehnt") {
        let d = TaskFromMessage.compose(title: "   ", notes: "n", categoryId: nil, categories: sportDefs,
                                        mode: .none, today: today, date: nil, time: nil)
        try expect(d == nil, "Leerer Titel darf nicht angelegt werden")
      },
      CheckCase("Karte: eigene Kategorie „Sport“ aus den Einstellungen erscheint und wird übernommen") {
        let d = TaskFromMessage.compose(title: "Training", notes: "", categoryId: "sport", categories: sportDefs,
                                        mode: .none, today: today, date: nil, time: nil)
        try expectEqual(d?.categoryId, "sport")
        let builtIn = TaskFromMessage.compose(title: "Training", notes: "", categoryId: "sport",
                                              categories: TaskCategoryDef.builtIn, mode: .none, today: today,
                                              date: nil, time: nil)
        try expect(builtIn?.categoryId == nil, "Ohne Eintrag in den Einstellungen keine Kategorie")
      },
      CheckCase("Karte: Notizen bleiben der Rückverweis auf die Mail") {
        let t = TaskFromMessage.mail(mail())
        let d = TaskFromMessage.compose(title: t.title, notes: t.notes, categoryId: nil, categories: sportDefs,
                                        mode: .none, today: today, date: nil, time: nil)
        try expectEqual(d?.notes, t.notes)
        try expect(d?.notes?.contains("message://%3Cabc@mail.example%3E") == true, "Rückverweis fehlt")
        try expect(d?.notes?.hasPrefix("Mail von Lena") == true, "Absender fehlt")
      },
      CheckCase("Karte: Anlegen über ViewActions bringt Titel, Fälligkeit, Kategorie und Notizen") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let t = TaskFromMessage.mail(mail())
        let d = TaskFromMessage.compose(title: t.title, notes: t.notes, categoryId: "sport", categories: sportDefs,
                                        mode: .today, today: today, date: nil, time: "14:30")
        let error = await ViewActions.addTask(model, title: d!.title, due: d!.due,
                                              category: d!.categoryId.map { TaskCategory(rawValue: $0) },
                                              notes: d!.notes)
        try expect(error == nil, "Anlegen gelingt: \(error ?? "")")
        let task = fake.current.tasks.last
        try expectEqual(task?.title, "Angebot bis Freitag")
        try expectEqual(task?.due, "2026-10-11T14:30")
        try expectEqual(task?.category?.rawValue, "sport")
        try expectEqual(task?.notes, t.notes)
      },
      CheckCase("Karte: ohne Titel meldet ViewActions einen Fehler und legt nichts an") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let error = await ViewActions.addTask(model, title: " ", due: nil, notes: "n")
        try expect(error != nil, "Leerer Titel braucht eine Meldung")
        try expect(fake.current.tasks.isEmpty, "Nichts angelegt")
      },
      CheckCase("Karte: Chat-Auswahl nennt Konversation in den Notizen") {
        let msg = MessengerMessage(id: "1", conversationId: "c", sender: "Max", text: "Bitte Bericht schicken",
                                   at: "2026-10-11T08:00")
        let conv = MessengerConversation(id: "c", accountId: "a", title: "Team Ost")
        let t = TaskFromMessage.chat([msg], in: conv)
        let d = TaskFromMessage.compose(title: t.title, notes: t.notes, categoryId: nil, categories: sportDefs,
                                        mode: .none, today: today, date: nil, time: nil)
        try expectEqual(d?.notes, "Bitte Bericht schicken\n\nVon Max in Team Ost, 11.10. 08:00")
      },
    ]
  }
}

// MARK: - Snapshots

extension MailTaskCardChecks {
  /// Insel-Höhe: die Karte muss ganz in diesen Rahmen passen, sonst wird sie im PNG abgeschnitten.
  static let size = CGSize(width: TabLayout.contentWidth, height: TabLayout.maxContentHeight)

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-mail-task-card", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let preview = MailPreview(taskDraft: fake.sampleMail().messages.first, categories: sportDefs)
        return wrap(MailView(mail: fake.sampleMail(), preview: preview).tabyPage(), model)
      },
      SnapshotSpec("view-mail-task-card-due", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let seed = TaskCardSeed(mode: .custom, withTime: true, date: "2026-10-14", time: "09:30",
                                categoryId: "sport", categoryPicked: true)
        let preview = MailPreview(taskDraft: fake.sampleMail().messages.first, taskSeed: seed, categories: sportDefs)
        return wrap(MailView(mail: fake.sampleMail(), preview: preview).tabyPage(), model)
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(MailChecks.now).environment(\.tabySnapshot, true))
  }
}
