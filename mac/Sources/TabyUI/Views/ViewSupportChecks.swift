// Prüfungen und Snapshots der dritten Runde (Tagesplan-Abschnitte, Rückgängig-Leiste, Suche, Timer, Wiederholung).
import Foundation
import SwiftUI
import TabyCore

enum ViewSupportChecks {
  private static let now = "2026-10-11T09:00"

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Bestätigung: Nachricht wird gesendet, nicht gelöscht") {
        let msg = PendingConfirmation(id: "1", tool: "send_message", summary: "Nachricht an Anna senden: Hallo",
                                      createdAt: now)
        try expectEqual(ConfirmationCards.title(msg), "Nachricht senden?")
        try expectEqual(ConfirmationCards.confirmLabel(msg), "Senden")
        let del = PendingConfirmation(id: "2", tool: "delete_task", summary: "Aufgabe „X“ löschen", createdAt: now)
        try expectEqual(ConfirmationCards.confirmLabel(del), "Löschen")
        try expect(ConfirmationCards.title(del).contains("löschen"), "Löschen bleibt bei Löschen")
      },
      CheckCase("Bestätigung: Anlegen wird nicht als Löschen angezeigt") {
        let create = PendingConfirmation(id: "3", tool: "mcp_notion_create_page", summary: "Seite anlegen", createdAt: now)
        try expectEqual(ConfirmationKind(tool: create.tool), .create)
        try expectEqual(ConfirmationCards.confirmLabel(create), "Anlegen")
        try expectEqual(ConfirmationCards.title(create), "Seite anlegen?")
        try expect(!ConfirmationCards.title(create).contains("löschen"), "kein Löschen-Wortlaut")
      },
      CheckCase("Bestätigung: unbekanntes Werkzeug bleibt neutral, nie Löschen") {
        let other = PendingConfirmation(id: "4", tool: "update_task", summary: "Aufgabe ändern", createdAt: now)
        try expectEqual(ConfirmationKind(tool: other.tool), .other)
        try expectEqual(ConfirmationCards.title(other), "Lumi möchte eine Aktion ausführen")
        try expectEqual(ConfirmationCards.confirmLabel(other), "Ausführen")
        let stop = PendingConfirmation(id: "5", tool: "cancel_job", summary: "Auftrag stoppen", createdAt: now)
        try expectEqual(ConfirmationCards.confirmLabel(stop), "Stoppen")
        try expectEqual(ConfirmationCards.title(stop), "Auftrag stoppen?")
      },
      CheckCase("Bestätigung: Klartext-Zeile nennt Werkzeug und einfache Felder") {
        let detail = #"{"tool":"mcp_notion_create_page","arguments":{"title":"Angebot Nord","due":"2026-10-30","parent":{"id":"x"}}}"#
        let p = PendingConfirmation(id: "6", tool: "mcp_notion_create_page", summary: "x", createdAt: now, detail: detail)
        let line = ConfirmationCards.plainLine(p)
        try expect(line.hasPrefix("Werkzeug: notion create page"), line)
        try expect(line.contains("title: Angebot Nord") && line.contains("due: 2026-10-30"), line)
        try expect(!line.contains("parent"), "verschachtelte Felder fehlen")
        let broken = PendingConfirmation(id: "7", tool: "delete_note", summary: "x", createdAt: now, detail: "kein json")
        try expectEqual(ConfirmationCards.plainLine(broken), "Werkzeug: delete note")
        try expectEqual(ConfirmationCards.title(broken), "Notiz löschen?")
      },
      CheckCase("Sicherung: Hinweis zum Neustart sagt, dass Lumi sich beendet") {
        try expectEqual(BackupsCard.restartNotice, "Lumi startet neu und stellt die Sicherung wieder her.")
      },
      CheckCase("Tagesplan-Abschnitt: offen nur mit überfälliger oder heutiger Aufgabe") {
        func section(_ due: String?) -> PlanPickSection {
          let t = TabyTask(id: "x", title: "X", due: due, createdAt: "2026-10-01T08:00")
          return PlanPickSection(id: "s", title: "S", groups: [PlanPickGroup(title: "", tasks: [t])])
        }
        try expect(ViewSupportLogic.sectionOpenByDefault(section("2026-10-10"), now: now), "überfällig ist offen")
        try expect(ViewSupportLogic.sectionOpenByDefault(section("2026-10-11T15:00"), now: now), "heute ist offen")
        try expect(!ViewSupportLogic.sectionOpenByDefault(section("2026-10-20"), now: now), "später ist zu")
        try expect(!ViewSupportLogic.sectionOpenByDefault(section(nil), now: now), "ohne Datum ist zu")
        let mixed = PlanPickSection(id: "m", title: "M", groups: [
          PlanPickGroup(title: "", tasks: [TabyTask(id: "a", title: "A", due: "2026-10-30", createdAt: "x")]),
          PlanPickGroup(title: "Woche", tasks: [TabyTask(id: "b", title: "B", due: "2026-10-09", createdAt: "x")]),
        ])
        try expect(ViewSupportLogic.sectionOpenByDefault(mixed, now: now), "eine überfällige Aufgabe reicht")
      },
      CheckCase("Rückgängig-Leiste: nur bei echtem Etikett sichtbar") {
        try expect(!ViewSupportLogic.undoVisible(nil), "nil zeigt nichts")
        try expect(!ViewSupportLogic.undoVisible(""), "leer zeigt nichts")
        try expect(!ViewSupportLogic.undoVisible("   "), "nur Leerzeichen zeigt nichts")
        try expect(ViewSupportLogic.undoVisible("Aufgabe gelöscht"), "Etikett zeigt die Leiste")
      },
      CheckCase("Suche: Gruppen in fester Reihenfolge, leere fehlen, Anzahl stimmt") {
        let hits = [
          SearchHit(id: "m1", kind: .memory, title: "Kunde zahlt in 14 Tagen"),
          SearchHit(id: "n1", kind: .note, title: "Meeting"),
          SearchHit(id: "t1", kind: .task, title: "Angebot"),
          SearchHit(id: "t2", kind: .task, title: "Angebot prüfen"),
        ]
        let groups = ViewSupportLogic.searchGroups(hits)
        try expectEqual(groups.map(\.title), ["Aufgaben", "Notizen", "Gedächtnis"])
        try expectEqual(groups.map { $0.hits.count }, [2, 1, 1])
        try expectEqual(groups[0].hits.map(\.id), ["t1", "t2"], "Reihenfolge innerhalb der Gruppe bleibt")
        try expectEqual(ViewSupportLogic.searchGroups([]), [], "keine Treffer, keine Gruppen")
      },
      CheckCase("Suche: Datum mit und ohne Uhrzeit, ohne Datum nichts") {
        try expectEqual(ViewSupportLogic.searchDate(nil), nil)
        try expectEqual(ViewSupportLogic.searchDate(""), nil)
        try expectEqual(ViewSupportLogic.searchDate("2026-10-15"), "Do. 15. Okt.")
        try expectEqual(ViewSupportLogic.searchDate("2026-10-15T09:30"), "Do. 15. Okt. · 09:30")
        try expectEqual(ViewSupportLogic.debounceNanos, 250_000_000)
      },
      CheckCase("Suche: Treffer öffnen Aufgaben, Notizen, Termine; Gedächtnis nicht") {
        try expectEqual(ViewSupportLogic.tab(for: .task), .tasks)
        try expectEqual(ViewSupportLogic.tab(for: .note), .notes)
        try expectEqual(ViewSupportLogic.tab(for: .event), .calendar)
        try expectEqual(ViewSupportLogic.tab(for: .memory), nil)
      },
      CheckCase("Eingang heute: nur ohne Nachrichten-Reiter, ohne Mail") {
        let inbox = [InboxItem(id: "1", kind: .needsReply, channel: "Slack", title: "Angebot", from: "Anna", at: "2026-10-11T08:00"),
                     InboxItem(id: "2", kind: .waiting, channel: "Mail", title: "Rechnung", from: "Bank", at: "2026-10-11T07:00")]
        let shown = ViewSupportLogic.hiddenMessagesInbox(settings: TabySettings(hiddenTabs: [], messengerEnabled: true), inbox: inbox)
        try expectEqual(shown.map(\.id), [])
        let hiddenTab = ViewSupportLogic.hiddenMessagesInbox(settings: TabySettings(hiddenTabs: ["messages"], messengerEnabled: true), inbox: inbox)
        try expectEqual(hiddenTab.map(\.id), ["1"])
        let noMessenger = ViewSupportLogic.hiddenMessagesInbox(settings: TabySettings(hiddenTabs: [], messengerEnabled: false), inbox: inbox)
        try expectEqual(noMessenger.map(\.id), ["1"])
      },
      CheckCase("Timer: feste Minuten, eigene Eingabe 1 bis 720") {
        try expectEqual(ViewSupportLogic.timerPresets, [5, 10, 15, 25, 45])
        try expectEqual(ViewSupportLogic.customMinutes("25"), 25)
        try expectEqual(ViewSupportLogic.customMinutes(" 45 "), 45)
        try expectEqual(ViewSupportLogic.customMinutes("720"), 720)
        try expectEqual(ViewSupportLogic.customMinutes("0"), nil)
        try expectEqual(ViewSupportLogic.customMinutes("721"), nil)
        try expectEqual(ViewSupportLogic.customMinutes("zehn"), nil)
        try expectEqual(ViewSupportLogic.customMinutes(""), nil)
      },
      CheckCase("Timer: Restzeit m:ss, abgelaufen ohne Rest") {
        try expectEqual(ViewSupportLogic.remainingText(endsAt: "2026-10-11T09:12", now: now), "12:00")
        try expectEqual(ViewSupportLogic.remainingText(endsAt: "2026-10-11T09:00", now: now), "abgelaufen")
        try expectEqual(ViewSupportLogic.remainingText(endsAt: "2026-10-11T08:59", now: now), "abgelaufen")
        try expectEqual(ViewSupportLogic.remainingText(endsAt: "kaputt", now: now), "")
      },
      CheckCase("Wiederholen: Titel und Patch-Wert ohne/mit Auswahl") {
        try expectEqual(ViewSupportLogic.recurrenceTitle(nil), "Nie")
        try expectEqual(ViewSupportLogic.recurrencePatch(nil), "")
        try expectEqual(ViewSupportLogic.recurrenceTitle(.weekdays), "Werktags")
        try expectEqual(ViewSupportLogic.recurrencePatch(.weekdays), "weekdays")
        try expectEqual(ViewSupportLogic.recurrencePatch(.monthly), "monthly")
      },
      CheckCase("Sicherungen: Titel mit Datum und Uhrzeit, Größe lesbar") {
        let b = BackupInfo(name: "taby-2026-10-15-0830.sqlite", createdAt: "2026-10-15T08:30", sizeBytes: 2_048_000)
        try expectEqual(ViewSupportLogic.backupTitle(b), "Do. 15. Okt. · 08:30")
        try expect(!ViewSupportLogic.backupSize(b.sizeBytes).isEmpty, "Größe nicht leer")
      },
    ]
  }

  // MARK: Snapshots

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-confirmation-long-detail", size: CGSize(width: TabLayout.contentWidth, height: 420)) {
        let detail = """
        {"tool":"mcp_notion_create_page","arguments":{"parent":{"database_id":"3b1f0c2a9d4e4f6a8b7c1d2e3f4a5b6c"},"properties":{"Name":{"title":[{"text":{"content":"Angebot fuer Kunde Nord, Version 3 mit allen Anhaengen und Preisstaffeln"}}]},"Notiz":{"rich_text":[{"text":{"content":"Bitte vor dem Versand mit Lena abstimmen, Rabatt bis 15 Prozent ist freigegeben"}}]}},"children":[{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"Zeile eins des Entwurfs mit einigen Woertern, damit der Umbruch sichtbar wird."}}]}}]}}
        """
        let p = PendingConfirmation(id: "long", tool: "mcp_notion_create_page",
                                    summary: "MCP-Server „Notion“: create_page", createdAt: now, detail: detail)
        let model = AppModel(services: FakeServices())
        return ViewSnapshots.wrapPicker(ConfirmationCards(pending: [p], showAllDetail: true).tabyPage(), model)
      },
      SnapshotSpec("view-plan-picker-collapsed", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let model = AppModel(services: FakeServices())
        return ViewSnapshots.wrapPicker(PlanPickerView(tasks: ViewChecks.groupedTasks, plan: nil,
                                                       events: ViewChecks.pickerEvents,
                                                       notionSourceLinks: ViewChecks.groupedLinks,
                                                       notionSources: ViewChecks.groupedSources,
                                                       notionTaskGroups: ViewChecks.groupedWeeks,
                                                       onClose: {}).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-folder-icons-recurrence", size: ViewSnapshots.size) {
        let fake = ViewChecks.taskFolderFixture()
        let model = AppModel(services: fake)
        let tasks = [
          TabyTask(id: "r1", title: "Wasser trinken", due: "2026-10-11", createdAt: "2026-10-01T08:00",
                   recurrence: .daily),
          TabyTask(id: "r2", title: "Wochenbericht schreiben", due: "2026-10-16", createdAt: "2026-10-02T08:00",
                   category: .arbeit, folderId: "f-arbeit", recurrence: .weekly),
        ] + fake.current.tasks
        return ViewSnapshots.wrapPicker(TasksView(tasks: tasks, folders: fake.current.taskFolders).tabyPage(), model)
      },
      SnapshotSpec("view-today-undo-timer", size: ViewSnapshots.size) {
        let fake = FakeServices(sample: true)
        fake.current.undoLabel = "Aufgabe gelöscht"
        fake.current.timers = [TabyTimer(id: "w1", label: "Timer", endsAt: "2026-10-11T09:12")]
        let model = AppModel(services: fake)
        return ViewSnapshots.wrapPicker(TabContentView(tab: .today, preview: fake.current)
          .frame(maxHeight: .infinity, alignment: .top), model)
      },
      SnapshotSpec("view-search-results", size: CGSize(width: TabLayout.contentWidth, height: 480)) {
        let hits = [
          SearchHit(id: "h1", kind: .task, title: "Angebot für Kunde X", date: "2026-10-14"),
          SearchHit(id: "h2", kind: .task, title: "Angebot prüfen", date: "2026-10-20T09:00"),
          SearchHit(id: "h3", kind: .note, title: "Meeting Kunde Nord", snippet: "Angebot an Lena schicken"),
          SearchHit(id: "h4", kind: .event, title: "Angebot-Call", date: "2026-10-12T10:00"),
          SearchHit(id: "h5", kind: .memory, title: "Kunde X zahlt in 14 Tagen"),
        ]
        let model = AppModel(services: FakeServices())
        let files = [FileHit(path: "/Users/ich/Documents/Angebot.pdf", name: "Angebot.pdf",
                             modifiedAt: "2026-10-14T16:20", kind: "PDF-Dokument")]
        return ViewSnapshots.wrapPicker(SearchPanel(query: .constant("Angebot"), hits: hits, files: files,
                                                    appleOn: true, fileNotes: [:], onSummarize: { _ in },
                                                    onOpen: { _ in }, onClose: {})
          .tabyPage(), model)
      },
    ]
  }
}
