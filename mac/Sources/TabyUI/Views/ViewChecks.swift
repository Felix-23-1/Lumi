// Prüfungen und Snapshots für Sources/TabyUI/Views (gehört dem Ansichten-Agenten).
import Foundation
import SwiftUI
import TabyCore

enum ViewChecks {
  static let now = "2026-10-11T09:00"
  static let today = "2026-10-11"

  @MainActor static var suite: CheckSuite {
    CheckSuite("Views", MicrosoftCardChecks.cases + PrivacyViewChecks.cases + logicCases + actionCases + layoutCases + packageOneCases + packageTwoCases + packageThreeCases + onboardingCases + PackageFourChecks.cases + MeetingPrepChecks.cases + ListeningChecks.cases + MusicChecks.cases + TodayLayoutChecks.cases + MailChecks.cases
               + NetworkChecks.cases + NetworkProUIChecks.cases + noteCheckboxCases + planPickerCases + planReorderCases
               + taskFolderCases + TaskCategoryChecks.cases + ViewSupportChecks.cases + TaskNotesChecks.cases + TaskStatusChecks.cases + TagChecks.cases + NoteEditorChecks.cases + NoteFilterChecks.cases + ObsidianChecks.cases + UpdatesPageChecks.cases
               + NotionAccountViewChecks.cases + ExplainChecks.cases + CircleChecks.cases + NotionStatusMapChecks.cases + NotionSectionChecks.cases)
  }

    // MARK: - Aufgaben-Ordner (rein und gegen FakeServices)

  /// Zwei Ordner mit Aufgaben, eine ohne Ordner, einer leer: für Snapshots und Prüfungen.
  @MainActor static func taskFolderFixture() -> FakeServices {
    let fake = FakeServices(sample: false)
    fake.current.taskFolders = [
      TaskFolder(id: "f-arbeit", name: "Arbeit", createdAt: "2026-10-01T08:00"),
      TaskFolder(id: "f-privat", name: "Privat", createdAt: "2026-10-01T08:00"),
      TaskFolder(id: "f-reise", name: "Reise", createdAt: "2026-10-01T08:00"),
    ]
    fake.current.tasks = [
      TabyTask(id: "g1", title: "Angebot für Kunde X", due: "2026-10-14", createdAt: "2026-10-13T08:00",
               category: .arbeit, folderId: "f-arbeit"),
      TabyTask(id: "g4", title: "Zahnarzt anrufen", due: "2026-10-15T09:00", createdAt: "2026-10-11T08:00"),
    ]
    return fake
  }

  @MainActor static var taskFolderCases: [CheckCase] {
    [
      CheckCase("Ordner-Gruppen: Ordnerreihenfolge, leerer Ordner bleibt, Ohne Ordner nur bei Inhalt") {
        let f1 = TaskFolder(id: "f1", name: "Arbeit", createdAt: "")
        let f2 = TaskFolder(id: "f2", name: "Privat", createdAt: "")
        let f3 = TaskFolder(id: "f3", name: "Leer", createdAt: "")
        let open = [
          TabyTask(id: "a", title: "a", createdAt: "1", folderId: "f2"),
          TabyTask(id: "b", title: "b", createdAt: "2", folderId: "f1"),
          TabyTask(id: "c", title: "c", createdAt: "3"),
          TabyTask(id: "d", title: "d", createdAt: "4", folderId: "gibt-es-nicht"),
        ]
        let g = TaskFolderLogic.groups(open, folders: [f1, f2, f3])
        try expectEqual(g.map(\.name), ["Arbeit", "Privat", "Leer", "Ohne Ordner"])
        try expectEqual(g.map { $0.tasks.map(\.id) }, [["b"], ["a"], [], ["c", "d"]], "unbekannte ID zählt als ohne Ordner")
        try expectEqual(TaskFolderLogic.groups([open[1]], folders: [f1]).map(\.name), ["Arbeit"])
        try expectEqual(TaskFolderLogic.groups([], folders: [f1]).map(\.name), ["Arbeit"])
      },
      CheckCase("Ordner-Filter: nil zeigt alle, sonst nur der Ordner; Zahl zählt nur offene") {
        let t1 = TabyTask(id: "t1", title: "a", createdAt: "", folderId: "f1")
        let t2 = TabyTask(id: "t2", title: "b", done: true, doneAt: "x", createdAt: "", folderId: "f1")
        let t3 = TabyTask(id: "t3", title: "c", createdAt: "")
        try expect(TaskFolderLogic.matches(t3, folder: nil))
        try expect(TaskFolderLogic.matches(t1, folder: "f1"))
        try expect(!TaskFolderLogic.matches(t3, folder: "f1"))
        try expectEqual(TaskFolderLogic.openCount([t1, t2, t3], folder: "f1"), 1)
      },
      CheckCase("Ordner anlegen: Duplikat und leerer Name melden den Kern-Fehler") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let ok = await ViewActions.addFolder(model, name: "Arbeit")
        try expectEqual(ok, nil)
        let dup = await ViewActions.addFolder(model, name: "arbeit")
        try expectEqual(dup, "Diesen Ordner gibt es schon.")
        let empty = await ViewActions.addFolder(model, name: "  ")
        try expectEqual(empty, "Ordnername fehlt oder ist zu lang.")
        try expectEqual(fake.current.taskFolders.map(\.name), ["Arbeit"])
      },
      CheckCase("Aufgabe in Ordner anlegen, verschieben, herausnehmen; Ordner löschen lässt Aufgaben stehen") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        _ = await ViewActions.addFolder(model, name: "Arbeit")
        let fid = try expectNotNil(fake.current.taskFolders.first).id
        _ = await ViewActions.addTask(model, title: "Angebot", due: nil, category: .arbeit, folderId: fid)
        let t = try expectNotNil(fake.current.tasks.first)
        try expectEqual(t.folderId, fid, "im gewählten Ordner angelegt")
        try expectEqual(t.category, .arbeit, "Kategorie und Ordner zusammen")
        _ = await ViewActions.addTask(model, title: "Einkauf", due: nil, folderId: nil)
        try expectEqual(fake.current.tasks.last?.folderId, nil, "ohne Ordner ohne Auswahl")
        _ = await ViewActions.setTaskFolder(model, id: t.id, folderId: nil)
        try expectEqual(fake.current.tasks.first { $0.id == t.id }?.folderId, nil, "Aus Ordner nehmen")
        _ = await ViewActions.setTaskFolder(model, id: t.id, folderId: fid)
        try expectEqual(fake.current.tasks.first { $0.id == t.id }?.folderId, fid, "Verschieben")
        _ = await ViewActions.renameFolder(model, id: fid, name: "Büro")
        try expectEqual(fake.current.taskFolders.first?.name, "Büro")
        _ = await ViewActions.deleteFolder(model, id: fid)
        try expect(fake.current.taskFolders.isEmpty)
        try expectEqual(fake.current.tasks.count, 2, "Aufgaben bleiben erhalten")
        try expectEqual(fake.current.tasks.first { $0.id == t.id }?.folderId, nil, "Ordner-Zuordnung gelöst")
      },
    ]
  }

  // MARK: - Tagesplan: Ziehen zum Umordnen (rein, ohne Ansicht)

  static var planReorderCases: [CheckCase] {
    [
      CheckCase("Plan-Ziehen: nach oben, nach unten und ganz nach oben/unten") {
        let ids = ["a", "b", "c"]
        try expectEqual(PlanReorderLogic.moved(ids, from: 2, before: 0), ["c", "a", "b"])
        try expectEqual(PlanReorderLogic.moved(ids, from: 0, before: 3), ["b", "c", "a"])
        try expectEqual(PlanReorderLogic.moved(ids, from: 1, before: 0), ["b", "a", "c"])
        try expectEqual(PlanReorderLogic.moved(ids, from: 0, before: 2), ["b", "a", "c"])
      },
      CheckCase("Plan-Ziehen: auf sich selbst oder direkt darunter ändert nichts") {
        let ids = ["a", "b", "c"]
        try expectEqual(PlanReorderLogic.moved(ids, from: 1, before: 1), ids)
        try expectEqual(PlanReorderLogic.moved(ids, from: 1, before: 2), ids)
        try expectEqual(PlanReorderLogic.moved(ids, from: 2, before: 3), ids)
      },
      CheckCase("Plan-Ziehen: ungültige Indizes und leere Liste lassen alles stehen") {
        let ids = ["a", "b", "c"]
        try expectEqual(PlanReorderLogic.moved(ids, from: 5, before: 0), ids)
        try expectEqual(PlanReorderLogic.moved(ids, from: 0, before: 9), ids)
        try expectEqual(PlanReorderLogic.moved(ids, from: 0, before: -1), ids)
        try expectEqual(PlanReorderLogic.moved([String](), from: 0, before: 0), [])
        try expectEqual(PlanReorderLogic.moved(["a"], from: 0, before: 1), ["a"])
      },
      CheckCase("Plan-Ziehen: Lücke beim Überfahren nach oben über, nach unten unter der Zeile") {
        try expectEqual(PlanReorderLogic.slot(dragging: 3, over: 1), 1)
        try expectEqual(PlanReorderLogic.slot(dragging: 0, over: 2), 3)
        try expectEqual(PlanReorderLogic.slot(dragging: 0, over: 0), 0)
      },
    ]
  }

  // MARK: - Notizen: Checkboxen (rein, ohne Ansicht)

  @MainActor static var noteCheckboxCases: [CheckCase] {
    [
      CheckCase("Notiz-Checkbox: [ ] → [x] → [ ], auch Großbuchstabe X und * als Aufzählung") {
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: "- [ ] Milch", line: 0), "- [x] Milch")
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: "- [x] Milch", line: 0), "- [ ] Milch")
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: "- [X] Milch", line: 0), "- [ ] Milch")
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: "* [ ] Brot", line: 0), "* [x] Brot")
      },
      CheckCase("Notiz-Checkbox: nur die Zielzeile ändert sich, Einrückung und Rest bleiben exakt") {
        let text = "Meeting\n  - [ ] Budget  \n\n- [x] Angebot\nEnde"
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 1), "Meeting\n  - [x] Budget  \n\n- [x] Angebot\nEnde")
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 3), "Meeting\n  - [ ] Budget  \n\n- [ ] Angebot\nEnde")
      },
      CheckCase("Notiz-Checkbox: Zeile ohne Checkbox, Zeile außerhalb und Text ohne Leerzeichen bleiben unverändert") {
        let text = "Titel\n- [ ]ohneLeerzeichen\nnormal [ ] text\n- [ ] ok"
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 0), text)
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 1), text)
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 2), text)
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: 9), text)
        try expectEqual(NoteCheckboxes.toggleCheckbox(in: text, line: -1), text)
      },
      CheckCase("Notiz-Checkbox: Zeilen werden als Text oder Checkbox erkannt") {
        let lines = NoteCheckboxes.lines("Kopf\n- [x] Eins\n* [ ] Zwei\n  - [ ]   Drei")
        try expectEqual(lines.map(\.kind), [.text, .checkbox, .checkbox, .checkbox])
        try expectEqual(lines.map(\.checked), [false, true, false, false])
        try expectEqual(lines.map(\.text), ["Kopf", "Eins", "Zwei", "Drei"])
        try expectEqual(lines[3].indent, 2)
        try expectEqual(lines[3].index, 3)
      },
      CheckCase("Notiz-Checkbox: Anhängen an leeren, endenden und normalen Inhalt") {
        try expectEqual(NoteCheckboxes.appendCheckbox(to: ""), "- [ ] ")
        try expectEqual(NoteCheckboxes.appendCheckbox(to: "Liste"), "Liste\n- [ ] ")
        try expectEqual(NoteCheckboxes.appendCheckbox(to: "Liste\n"), "Liste\n- [ ] ")
      },
    ]
  }

  // MARK: - Reine Logik

  @MainActor static var logicCases: [CheckCase] {
    [
      CheckCase("Uhrzeit frei eingeben: 18:30, 1830, 9, 9.5 → HH:mm; Unsinn → nil; ±15 min über Mitternacht") {
        try expectEqual(SettingsLogic.normalizeTime("18:30"), "18:30")
        try expectEqual(SettingsLogic.normalizeTime("1830"), "18:30")
        try expectEqual(SettingsLogic.normalizeTime("9"), "09:00")
        try expectEqual(SettingsLogic.normalizeTime("9.5"), "09:50")
        try expectEqual(SettingsLogic.normalizeTime("745"), "07:45")
        try expectEqual(SettingsLogic.normalizeTime("25:00"), nil)
        try expectEqual(SettingsLogic.normalizeTime("abends"), nil)
        try expectEqual(SettingsLogic.shiftTime("23:50", by: 15), "00:05")
        try expectEqual(SettingsLogic.shiftTime("00:10", by: -15), "23:55")
      },
      CheckCase("Aktionszeile: add_task ok") {
        let m = ChatMessage(role: .tool, content: #"{"ok":true,"task":{"title":"Milch kaufen"}}"#, name: "add_task")
        try expectEqual(ChatLogic.actionLine(m), "Aufgabe angelegt: Milch kaufen")
      },
      CheckCase("Aktionszeile: verpacktes Werkzeug-Ergebnis wird gelesen") {
        let wrapped = ChatMessage(role: .tool, content: ForeignContent.wrap(#"{"ok":true,"task":{"title":"Milch"}}"#),
                                  name: "add_task")
        try expectEqual(ChatLogic.actionLine(wrapped), "Aufgabe angelegt: Milch")
        try expect(!ForeignContent.isWrapped("x <fremder_inhalt> y") && ForeignContent.isWrapped(ForeignContent.wrap("y")))
        try expectEqual(ForeignContent.unwrap(ForeignContent.wrap("abc")), "abc")
      },
      CheckCase("Aktionszeile: Fehler und Sonderfälle") {
        let fail = ChatMessage(role: .tool, content: #"{"ok":false,"error":"Titel fehlt."}"#, name: "add_task")
        try expectEqual(ChatLogic.actionLine(fail), "Aktion fehlgeschlagen: Titel fehlt.")
        let noMsg = ChatMessage(role: .tool, content: #"{"ok":false}"#, name: "add_event")
        try expectEqual(ChatLogic.actionLine(noMsg), "Aktion fehlgeschlagen: unbekannter Fehler")
        let wait = ChatMessage(role: .tool, content: #"{"ok":false,"code":"NEEDS_CONFIRMATION","summary":"Fakt merken"}"#,
                               name: "remember_fact")
        try expectEqual(ChatLogic.actionLine(wait), "Bitte in der Notch bestätigen: Fakt merken")
        try expectEqual(ChatLogic.actionLine(ChatMessage(role: .tool, content: "kein json", name: "add_task")), nil)
        try expectEqual(ChatLogic.actionLine(ChatMessage(role: .assistant, content: #"{"ok":true}"#)), nil)
        let ev = ChatMessage(role: .tool, content: #"{"ok":true,"event":{"title":"Standup"}}"#, name: "add_event")
        try expectEqual(ChatLogic.actionLine(ev), "Termin eingetragen: Standup")
        let list = ChatMessage(role: .tool, content: #"{"ok":true,"tasks":[]}"#, name: "list_tasks")
        try expectEqual(ChatLogic.actionLine(list), nil)
      },
      CheckCase("Chat-Anzeige: System und rohe Werkzeug-Nutzlast ausgeblendet") {
        let msgs = [
          ChatMessage(role: .system, content: "geheim"),
          ChatMessage(role: .user, content: "Leg Milch an"),
          ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "1", name: "add_task", arguments: "{}")]),
          ChatMessage(role: .tool, content: #"{"ok":true,"task":{"title":"Milch"}}"#, name: "add_task", toolCallId: "1"),
          ChatMessage(role: .tool, content: #"{"ok":true,"tasks":[]}"#, name: "list_tasks", toolCallId: "2"),
          ChatMessage(role: .assistant, content: "Erledigt."),
        ]
        let d = ChatLogic.display(msgs)
        try expectEqual(d.map(\.text), ["Leg Milch an", "Aufgabe angelegt: Milch", "Erledigt."])
        try expectEqual(d.map(\.isAction), [false, true, false])
        try expectEqual(Set(d.map(\.id)).count, 3, "eindeutige IDs")
      },
      CheckCase("Fehlertexte wie errorToGerman (Chat.tsx)") {
        let expected: [LlmErrorCode: String] = [
          .auth: "Anmeldung beim Modell fehlgeschlagen. Prüfe den API-Schlüssel in den Einstellungen.",
          .quota: "Kontingent beim Modell aufgebraucht. Prüfe dein Guthaben beim Anbieter.",
          .rateLimit: "Zu viele Anfragen in kurzer Zeit. Warte kurz und versuche es erneut.",
          .network: "Keine Verbindung zum Modell. Prüfe deine Internetverbindung und die Adresse des Anbieters.",
          .noTools: "Das Modell unterstützt keine Werkzeuge. Wähle ein anderes Modell in den Einstellungen.",
          .badResponse: "Unerwartete Antwort vom Modell. Versuche es erneut.",
          .unknown: "Unbekannter Fehler beim Chat. Versuche es erneut oder prüfe die Einstellungen.",
        ]
        for (code, text) in expected {
          try expectEqual(ChatLogic.errorToGerman(LlmError(code, "x")), text, code.rawValue)
        }
        try expectEqual(ChatLogic.errorToGerman(LlmError(.cancelled, "x")), nil)
        try expectEqual(ChatLogic.errorToGerman(CancellationError()), nil)
        struct Other: Error {}
        try expectEqual(ChatLogic.errorToGerman(Other()), expected[.unknown])
      },
      CheckCase("Modell-Kapsel kürzt Anbieter") {
        try expectEqual(ChatLogic.modelLabel("anthropic/claude-sonnet-4.5"), "claude-sonnet-4.5")
        try expectEqual(ChatLogic.modelLabel(""), "Kein Modell")
      },
      CheckCase("Fälligkeits-Chips") {
        try expectEqual(TaskLogic.dueChip(nil, now: now), nil)
        try expectEqual(TaskLogic.dueChip("2026-10-09", now: now)?.kind, .overdue)
        try expectEqual(TaskLogic.dueChip("2026-10-09", now: now)?.label, "Überfällig · Fr. 9. Okt.")
        try expectEqual(TaskLogic.dueChip("2026-10-11T08:00", now: now)?.kind, .overdue)
        try expectEqual(TaskLogic.dueChip("2026-10-11T11:00", now: now), DueChipInfo(kind: .today, label: "Heute 11:00"))
        try expectEqual(TaskLogic.dueChip("2026-10-11", now: now), DueChipInfo(kind: .today, label: "Heute"))
        try expectEqual(TaskLogic.dueChip("2026-10-12T08:00", now: now), DueChipInfo(kind: .soon, label: "Morgen 08:00"))
        try expectEqual(TaskLogic.dueChip("2026-10-20", now: now), DueChipInfo(kind: .later, label: "Di. 20. Okt."))
      },
      CheckCase("Aufgaben sortieren und Fälligkeit zusammensetzen") {
        let ts = [
          TabyTask(id: "a", title: "ohne", createdAt: "1"),
          TabyTask(id: "b", title: "spät", due: "2026-10-20", createdAt: "2"),
          TabyTask(id: "c", title: "früh", due: "2026-10-10", createdAt: "3"),
          TabyTask(id: "d", title: "fertig", done: true, doneAt: "x", createdAt: "4"),
        ]
        try expectEqual(TaskLogic.sortOpen(ts).map(\.id), ["c", "b", "a"])
        try expectEqual(TaskLogic.sortDone(ts).map(\.id), ["d"])
        try expectEqual(TaskLogic.composeDue(date: "2026-10-12", time: "08:30"), "2026-10-12T08:30")
        try expectEqual(TaskLogic.composeDue(date: "2026-10-12", time: nil), "2026-10-12")
        try expectEqual(TaskLogic.composeDue(date: nil, time: "08:30"), nil)
        try expectEqual(TaskLogic.validateTitle("  "), "Bitte einen Titel eingeben.")
        try expectEqual(TaskLogic.validateTitle("x"), nil)
      },
      CheckCase("Agenda: nach Tag gruppiert, ganztägig zuerst") {
        let evs = [
          CalendarEvent(id: "1", sourceId: "apple", title: "Mittag", start: "2026-10-11T12:30", end: "2026-10-11T13:30"),
          CalendarEvent(id: "2", sourceId: "local", title: "Morgen früh", start: "2026-10-12T08:00"),
          CalendarEvent(id: "3", sourceId: "ics-1", title: "Feiertag", start: "2026-10-11", allDay: true),
          CalendarEvent(id: "4", sourceId: "notion:x", title: "Standup", start: "2026-10-11T09:30", end: "2026-10-11T09:45"),
        ]
        let a = CalendarLogic.agenda(evs, today: today)
        try expectEqual(a.map(\.label), ["Heute", "Morgen"])
        try expectEqual(a[0].events.map(\.id), ["3", "4", "1"])
        try expectEqual(CalendarLogic.timeRange(evs[3]), "09:30–09:45")
        try expectEqual(CalendarLogic.timeRange(evs[2]), "ganztägig")
        try expectEqual(CalendarLogic.timeRange(evs[1]), "08:00")
        try expectEqual(CalendarLogic.kind(of: "notion:x"), .notion)
        try expectEqual(CalendarLogic.kind(of: "ics-1"), .ics)
        try expectEqual(CalendarLogic.kind(of: "apple"), .apple)
        try expectEqual(CalendarLogic.kind(of: "irgendwas"), .local)
      },
      CheckCase("Konflikttext nennt Titel und Zeit (Szenario A)") {
        let with = CalendarEvent(id: "e", sourceId: "apple", title: "Standup", start: "2026-10-11T09:30",
                                 end: "2026-10-11T09:45")
        let msg = CalendarLogic.conflictMessage(error: "Termin überschneidet sich.",
                                                conflicts: [Conflict(with: with, kind: .overlap)], today: today)
        try expectEqual(msg, "Überschneidet sich mit „Standup“ (Heute 09:30–09:45).")
        try expectEqual(CalendarLogic.conflictMessage(error: "", conflicts: [], today: today),
                        "Der Termin überschneidet sich.")
        let info = CalendarEvent(id: "i", sourceId: "ics", title: "Urlaub", start: "2026-10-11", allDay: true)
        try expectEqual(CalendarLogic.infoMessage([info], today: today), "Am selben Tag ganztägig: „Urlaub“.")
        try expectEqual(CalendarLogic.unreachableMessage([SourceProblem(id: "notion:x", message: "401")]),
                        "Nicht erreichbar: notion:x (401). Termine daraus fehlen eventuell.")
      },
      CheckCase("Terminformular: Prüfung und Ende aus Dauer") {
        try expectEqual(CalendarLogic.makeEvent(title: " ", date: today, time: "10:00", duration: .h1),
                        .failure(FormError("Bitte einen Titel eingeben.")))
        try expectEqual(CalendarLogic.makeEvent(title: "X", date: today, time: "1x:00", duration: .h1),
                        .failure(FormError("Bitte eine gültige Uhrzeit wählen (HH:mm).")))
        try expectEqual(CalendarLogic.makeEvent(title: "X", date: "kaputt", time: "10:00", duration: .h1),
                        .failure(FormError("Bitte ein gültiges Datum wählen.")))
        try expectEqual(CalendarLogic.makeEvent(title: " Review ", date: today, time: "23:30", duration: .h1),
                        .success(NewEvent(title: "Review", start: "2026-10-11T23:30", end: "2026-10-12T00:30")))
        try expectEqual(CalendarLogic.makeEvent(title: "Urlaub", date: today, time: "10:00", duration: .allDay),
                        .success(NewEvent(title: "Urlaub", start: today)))
      },
      CheckCase("Einstellungen: nur Geändertes patchen, URLs prüfen") {
        var s = TabySettings.defaults
        try expect(SettingsLogic.isEmpty(SettingsLogic.patch(from: s, to: s)))
        s.llmModel = "openai/gpt-5"
        s.reminderLeadMinutes = 15
        let p = SettingsLogic.patch(from: .defaults, to: s)
        try expectEqual(p, SettingsPatch(llmModel: "openai/gpt-5", reminderLeadMinutes: 15))
        try expectEqual(SettingsLogic.validateBaseUrl("https://openrouter.ai/api/v1"), nil)
        try expect(SettingsLogic.validateBaseUrl("openrouter.ai") != nil)
        try expectEqual(SettingsLogic.validateBaseUrl("http://localhost:11434/v1"), nil, "lokal ohne https")
        try expectEqual(SettingsLogic.validateBaseUrl("http://127.0.0.1:8080"), nil)
        try expectEqual(SettingsLogic.validateBaseUrl("http://[::1]:8080"), nil)
        try expect(SettingsLogic.validateBaseUrl("http://example.com/v1") != nil, "http nur lokal")
        try expect(SettingsLogic.validateBaseUrl("http://localhost.example.com") != nil)
        try expect(SettingsLogic.validateBaseUrl("https://") != nil)
        try expect(SettingsLogic.validateBaseUrl("ftp://example.com") != nil)
        try expectEqual(SettingsLogic.validateIcsUrl("webcal://example.com/a.ics"), nil)
        try expect(SettingsLogic.validateIcsUrl("kein link") != nil)
      },
      CheckCase("Einstellungen: riskante Felder nur bestätigt speichern, ungültige URL bleibt draußen") {
        var committed = TabySettings.defaults
        committed.llmBaseUrl = "https://openrouter.ai/api/v1"
        committed.globalShortcut = "Control+Option+Space"
        var form = committed
        form.llmBaseUrl = "http://example.com"   // halb getippt / unsicher
        form.globalShortcut = "Control+Option+X"  // Entwurf
        form.reminderLeadMinutes = 45            // sicheres Feld
        // Autosave: nur das sichere Feld geht raus, riskante bleiben beim letzten bestätigten Wert.
        let auto = SettingsLogic.autosaveTarget(form: form, committed: committed)
        try expectEqual(auto.llmBaseUrl, committed.llmBaseUrl)
        try expectEqual(auto.globalShortcut, committed.globalShortcut)
        try expectEqual(auto.reminderLeadMinutes, 45)
        try expectEqual(SettingsLogic.patch(from: committed, to: auto), SettingsPatch(reminderLeadMinutes: 45))
        // Bestätigen: ungültige URL bleibt beim letzten gültigen Wert, Fehler wird gemeldet, Shortcut geht durch.
        let c = SettingsLogic.commitTarget(form: form, committed: committed)
        try expect(c.urlError != nil)
        try expectEqual(c.target.llmBaseUrl, committed.llmBaseUrl)
        try expectEqual(c.target.globalShortcut, "Control+Option+X")
        try expectEqual(c.target.reminderLeadMinutes, 45, "andere Felder werden trotzdem gespeichert")
        form.llmBaseUrl = "http://localhost:1234/v1"
        let ok = SettingsLogic.commitTarget(form: form, committed: committed)
        try expectEqual(ok.urlError, nil)
        try expectEqual(ok.target.llmBaseUrl, "http://localhost:1234/v1")
      },
      CheckCase("Tastenkürzel-Aufnahme: nach Tastencode, Umkehrung stimmt, ohne Namen abgelehnt") {
        // Tastencode 6 ist die Position von Z (ANSI); QWERTZ-Z liegt auf der Position von ANSI-Y (16).
        try expectEqual(ShortcutKeys.name(forKeyCode: 6), "z")
        try expectEqual(ShortcutKeys.name(forKeyCode: 16), "y")
        try expectEqual(ShortcutKeys.name(forKeyCode: 36), "return")
        try expectEqual(ShortcutKeys.name(forKeyCode: 49), "space")
        try expectEqual(ShortcutKeys.name(forKeyCode: 122), nil, "F1 hat keinen Namen")
        for (name, code) in ShortcutKeys.codes where name != "enter" {
          try expectEqual(ShortcutKeys.name(forKeyCode: UInt16(code)), name, "Umkehrung von \(name)")
        }
      },
      CheckCase("Tastenkürzel: korrekt geschrieben, sonst unbekannt") {
        try expect(SettingsLogic.shortcutParses("Control+Option+Space"))
        try expect(SettingsLogic.shortcutParses("cmd+shift+n"))
        try expect(SettingsLogic.shortcutParses("Control+Option+N"))
        try expect(!SettingsLogic.shortcutParses("Control+Option+F1"), "F-Tasten kennt die Tabelle nicht")
        try expect(!SettingsLogic.shortcutParses("Space"), "ohne Modifikator")
        try expect(!SettingsLogic.shortcutParses("Control+Option"), "ohne Taste")
        try expect(!SettingsLogic.shortcutParses("Control+Option+Foo"))
        try expect(!SettingsLogic.shortcutParses("Control+Option+"), "halb getippt")
        try expect(!SettingsLogic.shortcutParses(""))
      },
      CheckCase("Tastenrecorder: Kombination in Schreibweise der Kurzbefehle, ohne Modifikator oder Taste nichts") {
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Option", "Control"], key: "space"), "Control+Option+Space")
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Command", "Shift"], key: "n"), "Shift+Command+N")
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Control"], key: "7"), "Control+7")
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Control"], key: "return"), "Control+Return")
        try expectEqual(SettingsLogic.shortcutString(modifiers: [], key: "n"), nil, "ohne Modifikator")
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Control"], key: "ö!"), nil, "keine Taste aus der Tabelle")
        try expectEqual(SettingsLogic.shortcutString(modifiers: ["Control"], key: "f1"), nil, "F-Tasten nicht erlaubt")
        // Was der Recorder schreibt, muss der Kern lesen können.
        let written = SettingsLogic.shortcutString(modifiers: ["Control", "Option"], key: "c")
        try expect(written.map(SettingsLogic.shortcutParses) == true)
      },
      CheckCase("Notion-Unterreiter: je Quelle nur deren verknüpfte Aufgaben") {
        let t1 = TabyTask(id: "nt1", title: "A", createdAt: "2026-10-13T08:00")
        let t2 = TabyTask(id: "nt2", title: "B", createdAt: "2026-10-13T08:00")
        let t3 = TabyTask(id: "nt3", title: "C", createdAt: "2026-10-13T08:00")
        let t4 = TabyTask(id: "nt4", title: "ohne Quelle", createdAt: "2026-10-13T08:00")
        let links = ["nt1": "s1", "nt2": "s2", "nt3": "s1"]
        let all = [t1, t2, t3, t4]
        try expectEqual(NotionPageView.tasks(all, source: "s1", links: links).map(\.id), ["nt1", "nt3"])
        try expectEqual(NotionPageView.tasks(all, source: "s2", links: links).map(\.id), ["nt2"])
        try expectEqual(NotionPageView.tasks(all, source: "s3", links: links).map(\.id), [])
      },
      CheckCase("Notion-Wochen: neueste Woche zuerst, Ohne Woche zuletzt, offen vor erledigt") {
        let tasks = [
          TabyTask(id: "a", title: "alt offen", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "b", title: "KW 42 erledigt", done: true, doneAt: "2026-10-12T17:00", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "c", title: "KW 42 offen", createdAt: "2026-10-12T10:00"),
          TabyTask(id: "d", title: "ohne Woche", createdAt: "2026-10-12T11:00"),
          TabyTask(id: "e", title: "KW 9 offen", createdAt: "2026-10-12T12:00"),
          TabyTask(id: "f", title: "KW 10 offen", createdAt: "2026-10-12T13:00"),
        ]
        let groups = ["a": "KW 41", "b": "KW 42", "c": "KW 42", "e": "KW 9", "f": "KW 10"]
        let result = NotionPageView.weekGroups(tasks, groups: groups)
        try expectEqual(result.map(\.name), ["KW 42", "KW 41", "KW 10", "KW 9", "Ohne Woche"])
        try expectEqual(result.first { $0.name == "KW 42" }?.tasks.map(\.id), ["c", "b"])
        try expectEqual(result.last { $0.name == "Ohne Woche" }?.tasks.map(\.id), ["d"])
      },
      CheckCase("Notion-Wochen: Datums-Woche wird als dd.MM.yyyy angezeigt, Inhalt-Aufgaben stehen vorn") {
        try expectEqual(NotionPageView.weekTitle("2026-10-13 · Weekly 1:1"), "13.10.2026 · Weekly 1:1")
        try expectEqual(NotionPageView.weekTitle("KW 42"), "KW 42")
        let rows = [
          TabyTask(id: "r1", title: "Weekly 1:1", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "r2", title: "Weekly 1:1", createdAt: "2026-10-08T08:00"),
          TabyTask(id: "td", title: "Locale AI", createdAt: "2026-10-07T08:00"),
          TabyTask(id: "td2", title: "Mit Notiz", notes: "Text", createdAt: "2026-10-13T09:00"),
        ]
        let groups = ["r1": "2026-10-13 · Weekly 1:1", "td": "2026-10-13 · Weekly 1:1",
                      "r2": "2026-10-08 · Weekly 1:1", "td2": "2026-10-13 · Weekly 1:1"]
        let result = NotionPageView.weekGroups(rows, groups: groups)
        try expectEqual(result.map(\.name), ["2026-10-13 · Weekly 1:1", "2026-10-08 · Weekly 1:1"])
        try expectEqual(result.first?.tasks.map(\.id), ["td2", "td", "r1"], "mit Notiz, dann offen")
      },
      CheckCase("Notion-Inhalt: Zeilen nach Textformat (Ebene, Überschrift, To-do, Nummer, Zitat)") {
        let text = "## Ziel\n• eins\n  ☑ erledigt\n    ☐ tief\n3. drei\n▸ Toggle\n—\n\n> Zitat\n↳ Seite\nFließtext"
        let rows = NotionBodyView.lines(text)
        try expectEqual(rows.map(\.kind), [.heading, .bullet, .todo, .todo, .numbered, .toggle, .divider, .blank,
                                           .quote, .subpage, .text])
        try expectEqual(rows[0].text, "Ziel")
        try expectEqual(rows[0].level, 0)
        try expectEqual(rows[2].level, 1)
        try expectEqual(rows[2].checked, true)
        try expectEqual(rows[2].text, "erledigt")
        try expectEqual(rows[3].level, 2)
        try expectEqual(rows[3].checked, false)
        try expectEqual(rows[4].number, "3.")
        try expectEqual(rows[4].text, "drei")
        try expectEqual(NotionBodyView.lines("Dr. Müller").map(\.kind), [.text], "Punkt ohne Ziffern ist Fließtext")
        try expectEqual(NotionBodyView.todoTexts(text), ["erledigt", "tief"])
      },
      CheckCase("Notion-Ticket-Zeile: Meta-Text, Jahr, veraltet, fehlende Teile") {
        let now = "2026-10-13T09:00"
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(createdAt: "2026-10-12T10:00", createdBy: "Felix",
                                                              status: "In Bearbeitung"), now: now),
                        [NotionPageView.MetaPart(text: "Felix", stale: false),
                         NotionPageView.MetaPart(text: "12.10.", stale: false),
                         NotionPageView.MetaPart(text: "In Bearbeitung", stale: false)])
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(createdAt: "2025-12-03T10:00"), now: now),
                        [NotionPageView.MetaPart(text: "03.12.25", stale: true)], "anderes Jahr: zweistelliges Jahr, veraltet")
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(createdAt: "2026-09-01T10:00"), now: now),
                        [NotionPageView.MetaPart(text: "01.09.", stale: true)], "über 14 Tage: bernsteinfarben")
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(createdAt: "2026-10-03T10:00"), now: now),
                        [NotionPageView.MetaPart(text: "03.10.", stale: false)], "frisch")
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(status: "Neu"), now: now),
                        [NotionPageView.MetaPart(text: "Neu", stale: false)], "nur Status")
        try expectEqual(NotionPageView.metaLine(NotionTaskMeta(), now: now), nil, "nichts da: keine Zeile")
      },
      CheckCase("Notion-Tickets: Reihenfolge wie TaskLogic.sortOpen (überfällig, heute, später, ohne Datum)") {
        let items = [
          TabyTask(id: "u2", title: "ohne Datum neu", createdAt: "2026-10-05T08:00"),
          TabyTask(id: "s", title: "später", due: "2026-10-20", createdAt: "2026-09-01T08:00"),
          TabyTask(id: "h2", title: "heute, neuer", due: "2026-10-13", createdAt: "2026-10-12T08:00"),
          TabyTask(id: "u1", title: "ohne Datum alt", createdAt: "2026-10-01T08:00"),
          TabyTask(id: "d", title: "erledigt", done: true, doneAt: "2026-10-02T08:00", createdAt: "2026-09-01T08:00"),
          TabyTask(id: "h", title: "heute, älter", due: "2026-10-13", createdAt: "2026-10-05T08:00"),
          TabyTask(id: "o", title: "überfällig", due: "2026-10-10", createdAt: "2026-09-01T08:00"),
        ]
        try expectEqual(TaskLogic.sortOpen(items).map(\.id), ["o", "h", "h2", "s", "u1", "u2"])
      },
      CheckCase("Notion-Wochen: To-do-Zeilen werden der Reihe nach Wochen-Aufgaben zugeordnet") {
        let todos = [
          TabyTask(id: "t1", title: "Locale AI", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "t2", title: "Mail schreiben", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "t3", title: "Mail schreiben", createdAt: "2026-10-13T08:00"),
        ]
        // n-te Zeile zuerst der n-ten To-do-Aufgabe, sonst erste freie mit gleichem Titel, sonst nil.
        let m = NotionPageView.matchTodos(["Mail schreiben", "Locale AI ", "Mail schreiben", "Unbekannt"], todos: todos)
        try expectEqual(m.map { $0?.id }, ["t2", "t1", "t3", nil])
        try expectEqual(NotionPageView.matchTodos(["Mail schreiben", "Mail schreiben"], todos: todos).map { $0?.id },
                        ["t2", "t3"], "gleicher Titel: der Reihe nach")
      },
      CheckCase("Notion: Stand „Zuletzt geholt“ wird nach einer Stunde orange") {
        try expect(!NotionPageView.syncStale("2026-10-28T09:30:00", now: "2026-10-28T10:15:00"), "45 Minuten frisch")
        try expect(NotionPageView.syncStale("2026-10-28T08:30:00", now: "2026-10-28T10:15:00"), "fast zwei Stunden alt")
        try expect(!NotionPageView.syncStale("kaputt", now: "2026-10-28T10:15:00"), "unlesbar gilt als frisch")
      },
      CheckCase("Notion-Wochen-Chips: Kurzdatum, Jahr, Titel ohne Datum, Duplikate mit Titel") {
        let now = "2026-10-14T09:00"
        try expectEqual(NotionPageView.weekChipLabel("2026-10-13 · Weekly 1:1", now: now), "13.10.")
        try expectEqual(NotionPageView.weekChipLabel("2025-12-03 · Weekly", now: now), "03.12.25", "anderes Jahr")
        try expectEqual(NotionPageView.weekChipLabel("KW 42", now: now), "KW 42")
        let long = NotionPageView.weekChipLabel("Ein sehr langer Wochentitel ohne Datum", now: now)
        try expectEqual(long.count, 24, "gekürzt")
        try expect(long.hasSuffix("…"))
        try expectEqual(NotionPageView.weekChipLabels(["2026-10-13 · Weekly 1:1", "2026-10-13 · Weekly 2",
                                                       "2026-10-08 · Weekly 1:1"], now: now),
                        ["13.10. · Weekly 1:1", "13.10. · Weekly 2", "08.10."], "gleiches Datum: Titel dazu")
        try expectEqual(NotionPageView.weekTitle("2026-10-13 · Weekly 1:1"), "13.10.2026 · Weekly 1:1")
      },
      CheckCase("Notion-Wochen-Auswahl: Standard ist die neueste, verschwundene Woche fällt auf die neueste zurück") {
        let names = ["2026-10-13 · Weekly 1:1", "2026-10-08 · Weekly 1:1", "Ohne Woche"]
        try expectEqual(NotionPageView.weekSelection(names, selected: nil), "2026-10-13 · Weekly 1:1")
        try expectEqual(NotionPageView.weekSelection(names, selected: "2026-10-08 · Weekly 1:1"), "2026-10-08 · Weekly 1:1")
        try expectEqual(NotionPageView.weekSelection(names, selected: "gelöscht"), "2026-10-13 · Weekly 1:1")
        try expectEqual(NotionPageView.weekSelection([], selected: nil), nil)
      },
      CheckCase("Notion-Wochen-Liste: To-dos in gespeicherter Reihenfolge, offene vor erledigten; leere Woche") {
        let week = [
          TabyTask(id: "m", title: "Weekly 1:1", notes: "## Core\n☐ a", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "x1", title: "erledigt zuerst gespeichert", done: true, doneAt: "2026-10-12T10:00", createdAt: "2026-10-12T08:00"),
          TabyTask(id: "x2", title: "a", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "x3", title: "c", createdAt: "2026-10-12T11:00"),
          TabyTask(id: "other", title: "andere Woche", createdAt: "2026-10-01T08:00"),
        ]
        let members = Array(week.prefix(4))  // ohne „andere Woche“
        try expectEqual(NotionPageView.weekTodos(members, all: week).map(\.id), ["x2", "x3", "x1"])
        try expectEqual(NotionPageView.weekTodos([week[0]], all: week).map(\.id), [], "nur Besprechung: leere Liste")
      },
      CheckCase("Notion-Quelle: Pflichtfelder und Standardfelder") {
        try expectEqual(SettingsLogic.notionConfig(token: "", databaseId: "db", titleField: "", startField: "",
                                                   endField: ""),
                        .failure(FormError("Notion-Zugangscode und Datenbank-ID werden gebraucht.")))
        let ok = try expectNotNil(try? SettingsLogic.notionConfig(token: " t ", databaseId: "db", titleField: "",
                                                                  startField: "", endField: "Ende").get())
        try expectEqual(ok, ["token": "t", "databaseId": "db", "titleField": "Name", "startField": "Datum",
                             "endField": "Ende"])
        let src = CalendarSourceConfig(id: "notion-1", kind: .notion, config: ok)
        try expect(!SettingsLogic.sourceDetail(src).contains("t\""), "Token nie anzeigen")
        try expectEqual(SettingsLogic.sourceDetail(src), "Datenbank db…")
      },
      CheckCase("Standard-Chip folgt dem tatsächlichen Schreibziel (markiert → Apple → lokal)") {
        let local = CalendarSourceConfig(id: "l", kind: .local)
        let apple = CalendarSourceConfig(id: "a", kind: .apple)
        let ics = CalendarSourceConfig(id: "i", kind: .ics, isDefaultWrite: true)
        try expectEqual(SettingsLogic.effectiveDefaultWriteId([local, apple, ics]), "a")
        try expectEqual(SettingsLogic.effectiveDefaultWriteId([local, CalendarSourceConfig(id: "a", kind: .apple, enabled: false)]), "l")
        try expectEqual(SettingsLogic.effectiveDefaultWriteId([CalendarSourceConfig(id: "l", kind: .local, isDefaultWrite: true), apple]), "l")
        try expectEqual(ChatLogic.actionLine(ChatMessage(role: .tool, content: #"{"ok":true,"event":{"title":"Zahnarzt"}}"#,
                                                         name: "move_event")), "Termin verschoben: Zahnarzt")
      },
      CheckCase("Auftragsregeln auf Deutsch") {
        try expectEqual(SettingsLogic.ruleText(.daily(time: "08:00")), "täglich 08:00")
        try expectEqual(SettingsLogic.ruleText(.weekly(days: [3, 1], time: "08:00")), "Mo., Mi. 08:00")
        try expectEqual(SettingsLogic.ruleText(.weekly(days: [0, 1], time: "08:00")), "Mo., So. 08:00")
        try expectEqual(SettingsLogic.ruleText(.once(at: "2026-10-12T08:00")), "einmalig Mo. 12. Okt. 08:00")
      },
      CheckCase("Agenten-Vorschau: Befehl, Pfad, JSON") {
        try expectEqual(AgentLogic.preview(["command": "npm test"]), AgentLogic.Preview(text: "npm test", isCommand: true))
        try expectEqual(AgentLogic.preview(["file_path": "/a/b.swift", "content": "x"]).text, "/a/b.swift")
        try expectEqual(AgentLogic.preview(["x": 1]).text, #"{"x":1}"#)
        try expect(AgentLogic.preview(["command": .string(String(repeating: "a", count: 500))]).text.count <= 221)
        try expectEqual(AgentLogic.shortPath("/Users/x/Projekte/taby", home: "/Users/x"), "~/Projekte/taby")
        try expectEqual(AgentLogic.headline("Bash"), "Claude Code möchte einen Befehl ausführen")
      },
      CheckCase("Verbindungen: frische Standardwerte → nur Claude Code (Standard an) ist verbunden") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        s.calendarSources = []
        let c = ConnectionLogic.cards(s)
        try expectEqual(c.map(\.id), ["model", "calendar", "reminders", "mail", "notion", "claude", "mcp",
                                      "imessage", "slack", "teams", "matrix", "obsidian"])
        // Element/Matrix ist nur mit eingebauter SDK "Verfügbar" (Bald sonst).
        let matrix: ConnectionStatus = MatrixAvailability.isAvailable ? .off : .soon
        try expectEqual(c.map(\.status), [.off, .off, .off, .off, .off, .connected, .off, .off, .off, .off, matrix, .off])
        try expectEqual(c[0].action, .open(.model))
        try expectEqual(c[6].action, .open(.connect))
      },
      CheckCase("Verbindungen: iMessage aus → Verbinden; verbunden → Trennen; Fehler → Problem; Rest bald") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        s.calendarSources = []
        var c = ConnectionLogic.cards(s)
        try expectEqual(c[7].status, .off)
        try expectEqual(c[7].action, .connectMessenger(.imessage))
        try expectEqual(c[7].detail, "Liest und sendet über die Nachrichten-App (Festplattenvollzugriff nötig)")
        try expectEqual(c[8].action, .slackForm)
        try expectEqual(c[8].detail, "Eigene Slack-App im Workspace mit einem Zugangscode (xoxp-…)")

        try expectEqual(c[9].title, "Microsoft Teams")
        try expectEqual(c[10].title, "Element / Matrix")
        if !MatrixAvailability.isAvailable {
          try expectEqual(c[10].detail, "Verschlüsselte Chats – in Vorbereitung")
          try expectEqual(c[10].action, .unavailable)
        }
        s.messengerAccounts = [MessengerAccount(id: "acc-im", service: .imessage, user: "Felix")]
        c = ConnectionLogic.cards(s)
        try expectEqual(c[7].status, .connected)
        try expectEqual(c[7].detail, "Felix")
        try expectEqual(c[7].action, .disconnectMessenger("acc-im"))
        s.messengerAccounts = [MessengerAccount(id: "acc-im", service: .imessage, user: "Felix",
                                                status: .error("Festplattenzugriff fehlt."))]
        c = ConnectionLogic.cards(s)
        try expectEqual(c[7].status, .problem)
        try expectEqual(c[7].detail, "Festplattenzugriff fehlt.")
        try expectEqual(c[7].action, .disconnectMessenger("acc-im"))
      },
      CheckCase("Element-Karte: aus → Formular; gesperrt → Entsperren; verbunden → Trennen; ohne SDK → Bald") {
        let off = ConnectionLogic.matrixCard(nil, available: true)
        try expectEqual(off.status, .off)
        try expectEqual(off.action, .matrixForm)
        let locked = ConnectionLogic.matrixCard(
          MessengerAccount(id: "acc-mx", service: .matrix, server: "matrix.org", user: "@felix:matrix.org", status: .locked),
          available: true)
        try expectEqual(locked.status, .problem)
        try expectEqual(locked.detail, "Gesperrt – Sicherheitsschlüssel fehlt")
        try expectEqual(locked.action, .matrixUnlock("acc-mx"))
        let on = ConnectionLogic.matrixCard(
          MessengerAccount(id: "acc-mx", service: .matrix, server: "matrix.org", user: "@felix:matrix.org"), available: true)
        try expectEqual(on.status, .connected)
        try expectEqual(on.detail, "@felix:matrix.org")
        try expectEqual(on.action, .disconnectMessenger("acc-mx"))
        let soon = ConnectionLogic.matrixCard(nil, available: false)
        try expectEqual(soon.status, .soon)
        try expectEqual(soon.action, .unavailable)
      },
      CheckCase("Nachrichten: Zeit heute HH:mm, sonst dd.MM.; ungelesen summiert") {
        try expectEqual(MessagesLogic.timeLabel("2026-10-11T08:40", today: "2026-10-11"), "08:40")
        try expectEqual(MessagesLogic.timeLabel("2026-10-10T19:12", today: "2026-10-11"), "10.10.")
        try expectEqual(MessagesLogic.timeLabel("2026-10-11", today: "2026-10-11"), "11.10.")
        let convs = [MessengerConversation(id: "a|1", accountId: "a", title: "x", unread: 2),
                     MessengerConversation(id: "a|2", accountId: "a", title: "y", unread: 0),
                     MessengerConversation(id: "a|3", accountId: "a", title: "z", unread: 3)]
        try expectEqual(MessagesLogic.unreadTotal(convs), 5)
        try expectEqual(MessagesLogic.unreadTotal([]), 0)
      },
      CheckCase("Verbindungen: Schlüssel, Mail und Notion verbunden; Fehler machen Problem") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        s.calendarSources = [CalendarSourceConfig(id: "local", kind: .local)]
        s.settings.hasApiKey = true
        s.settings.llmModel = "anthropic/claude-sonnet-5"
        s.settings.mailEnabled = true
        s.settings.notionTasksEnabled = true
        s.notionTasksConnected = true
        s.notionSources = [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "1a2b3c")]
        var c = ConnectionLogic.cards(s)
        try expectEqual(c[0].status, .connected)
        try expectEqual(c[0].detail, "anthropic/claude-sonnet-5")
        try expectEqual(c[1].detail, "Lokal")
        try expectEqual(c[3].status, .connected)
        try expectEqual(c[4].status, .connected)
        try expectEqual(c[4].detail, "1 Quelle")
        s.settings.appleRemindersSync = true
        s.remindersError = "Zugriff auf Erinnerungen verweigert."
        s.notionTasksSync = NotionTaskSync(lastError: "HTTP 401")
        c = ConnectionLogic.cards(s)
        try expectEqual(c[2].status, .problem)
        try expectEqual(c[2].detail, "Zugriff auf Erinnerungen verweigert.")
        try expectEqual(c[4].status, .problem)
        try expectEqual(c[4].detail, "HTTP 401")
      },
      CheckCase("Verbindungen: Apple Intelligence und fehlender Schlüssel") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        s.settings.llmModel = TabySettings.appleIntelligenceModel
        var c = ConnectionLogic.cards(s)
        try expectEqual(c[0].status, .connected)
        try expectEqual(c[0].detail, "Apple Intelligence")
        s.settings.llmModel = "openai/gpt-5"
        c = ConnectionLogic.cards(s)
        try expectEqual(c[0].status, .off)
        try expectEqual(c[0].detail, "Kein Schlüssel")
      },
      CheckCase("Heute: Kurztext ohne Modell und Begrüßung") {
        try expectEqual(TodayLogic.fallbackBriefing(.empty), "Für heute liegt nichts an. Guten Start!")
        let o = Overview(overdueTasks: [TabyTask(id: "a", title: "x", createdAt: "")],
                         todayTasks: [TabyTask(id: "b", title: "y", createdAt: "")])
        try expectEqual(TodayLogic.fallbackBriefing(o), "Heute: 1 Aufgabe offen, 1 überfällig.")
        try expect(TodayLogic.isEmpty(.empty))
        try expect(!TodayLogic.isEmpty(o))
        try expectEqual(TodayLogic.greeting(now: "2026-10-11T07:00"), "Guten Morgen")
        try expectEqual(TodayLogic.greeting(now: "2026-10-11T19:00"), "Guten Abend")
      },
    ]
  }

  // MARK: - Aktionen gegen FakeServices

  @MainActor static var actionCases: [CheckCase] {
    [
      CheckCase("Aufgabe anlegen: leerer Titel ruft den Kern nicht auf") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let err = await ViewActions.addTask(model, title: "   ", due: nil)
        try expectEqual(err, "Bitte einen Titel eingeben.")
        try expectEqual(fake.current.tasks.count, 0)
      },
      CheckCase("Aufgabe anlegen, abhaken, wieder öffnen, löschen") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let addErr = await ViewActions.addTask(model, title: " Zahnarzt ", due: "2026-10-12T09:00")
        try expectEqual(addErr, nil)
        let t = try expectNotNil(fake.current.tasks.first)
        try expectEqual(t.title, "Zahnarzt")
        try expectEqual(t.due, "2026-10-12T09:00")
        try expectEqual(model.reaction?.reaction, .itemAdded)
        try expectEqual(model.state?.tasks.count, 1, "Zustand neu geladen")
        _ = await ViewActions.setTaskDone(model, id: t.id, done: true)
        try expect(fake.current.tasks[0].done)
        try expectEqual(model.reaction?.reaction, .taskCompleted)
        _ = await ViewActions.setTaskDone(model, id: t.id, done: false)
        try expect(!fake.current.tasks[0].done)
        _ = await ViewActions.renameTask(model, id: t.id, title: "Zahnarzt anrufen")
        try expectEqual(fake.current.tasks[0].title, "Zahnarzt anrufen")
        _ = await ViewActions.deleteTask(model, id: t.id)
        try expect(fake.current.tasks.isEmpty)
        try expectEqual(model.reaction?.reaction, .itemDeleted)
      },
      CheckCase("Aufgaben-Kategorie: Menü setzt Arbeit, dann Privat, „Keine“ löscht, Filter trennt") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        _ = await ViewActions.addTask(model, title: "Angebot schreiben", due: nil)
        let id = try expectNotNil(fake.current.tasks.first).id
        let defs = TaskCategoryDef.builtIn
        for choice in ["arbeit", "privat"] {
          let cur = fake.current.tasks.first { $0.id == id }?.category?.rawValue
          let patch = try expectNotNil(TaskCategoryLogic.categoryPatch(choice: choice, current: cur, defs: defs))
          _ = await model.services.updateTask(id, TaskPatch(category: patch))
          try expectEqual(fake.current.tasks.first { $0.id == id }?.category?.rawValue, choice)
        }
        let cur = fake.current.tasks.first { $0.id == id }?.category?.rawValue
        let clear = TaskCategoryLogic.categoryPatch(choice: nil, current: cur, defs: defs) ?? ""
        _ = await model.services.updateTask(id, TaskPatch(category: clear))
        try expectEqual(fake.current.tasks.first { $0.id == id }?.category, nil, "Keine Kategorie löscht die Zuordnung")
        let t = TabyTask(id: "x", title: "x", createdAt: "", category: .privat)
        try expect(TaskLogic.matches(t, category: nil, folders: [], defs: defs, notionCategories: [:]))
        try expect(TaskLogic.matches(t, category: "privat", folders: [], defs: defs, notionCategories: [:]))
        try expect(!TaskLogic.matches(t, category: "arbeit", folders: [], defs: defs, notionCategories: [:]))
      },
      CheckCase("Menü-Wahl: gleiche Kategorie tut nichts, unbekannte Kennung zählt als keine") {
        let defs = TaskCategoryDef.builtIn + [TaskCategoryDef(id: "sport", name: "Sport", symbol: "figure.run")]
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: "privat", current: "privat", defs: defs), nil)
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: "sport", current: "privat", defs: defs), "sport")
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: nil, current: "sport", defs: defs), "")
        try expectEqual(TaskCategoryLogic.categoryPatch(choice: nil, current: "geloescht", defs: defs), nil, "unbekannt wie keine")
      },
      CheckCase("Aufgabe im Filter Arbeit anlegen bekommt Kategorie Arbeit, ohne Filter keine") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let err = await ViewActions.addTask(model, title: "Angebot prüfen", due: nil, category: .arbeit)
        try expectEqual(err, nil)
        let t = try expectNotNil(fake.current.tasks.first)
        try expectEqual(t.category, .arbeit)
        try expect(TaskLogic.matches(t, category: "arbeit", folders: [], defs: TaskCategoryDef.builtIn, notionCategories: [:]))
        try expect(TaskLogic.matches(t, category: nil, folders: [], defs: TaskCategoryDef.builtIn, notionCategories: [:]),
                   "Alle zeigt sie auch")
        _ = await ViewActions.addTask(model, title: "Einkauf", due: nil, category: nil)
        try expectEqual(fake.current.tasks.last?.category, nil)
      },
      CheckCase("Fälligkeit bearbeiten: morgen 15:00 setzen, Auswahl zurücklesen, entfernen") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        _ = await ViewActions.addTask(model, title: "Bericht", due: nil)
        let id = try expectNotNil(fake.current.tasks.first).id
        let today = LocalTime.datePart(ViewChecks.now)
        let due = TaskLogic.dueString(.tomorrow, today: today, custom: nil, time: "15:00")
        try expectEqual(due, "2026-10-12T15:00")
        let err = await ViewActions.setTaskDue(model, id: id, due: due)
        try expectEqual(err, nil)
        try expectEqual(fake.current.tasks.first { $0.id == id }?.due, "2026-10-12T15:00")
        let draft = TaskLogic.dueDraft("2026-10-12T15:00", today: today)
        try expect(draft.mode == .tomorrow && draft.date == "2026-10-12" && draft.time == "15:00", "Vorbelegung")
        try expectEqual(TaskLogic.dueDraft("2026-10-20", today: today).mode, .custom)
        _ = await ViewActions.setTaskDue(model, id: id, due: nil)
        let cleared = fake.current.tasks.first { $0.id == id }?.due
        try expect((cleared ?? "").isEmpty, "Fälligkeit entfernt")
        try expect(TaskLogic.dueChip(cleared, now: ViewChecks.now) == nil)
        try expectEqual(TaskLogic.dueDraft(cleared, today: today).mode, .none)
      },
      CheckCase("Aufgaben-Herkunft: nil alle, Zugang nur seine Quellen, Eigene nur unverknüpfte, mit Kategorie UND") {
        let links = ["n1": "s1", "n2": "s2"]
        let sources = [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "a", accountId: "arbeit-acc"),
                       NotionSource(id: "s2", name: "Projekte", category: .todos, link: "b", accountId: "privat-acc")]
        let n1 = TabyTask(id: "n1", title: "a", createdAt: "", category: .arbeit)
        let n2 = TabyTask(id: "n2", title: "b", createdAt: "", category: .privat)
        let n3 = TabyTask(id: "n3", title: "c", createdAt: "", category: .arbeit)
        let all = [n1, n2, n3]
        try expect(all.allSatisfy { TaskLogic.matches($0, origin: nil, sourceLinks: links, sources: sources) })
        try expectEqual(all.filter { TaskLogic.matches($0, origin: .account("arbeit-acc"), sourceLinks: links, sources: sources) }.map(\.id), ["n1"])
        try expectEqual(all.filter { TaskLogic.matches($0, origin: .own, sourceLinks: links, sources: sources) }.map(\.id), ["n3"])
        let defs = TaskCategoryDef.builtIn
        let notionCats = ["n1": "arbeit", "n2": "privat"]
        let combined = all.filter {
          TaskLogic.matches($0, category: "arbeit", folders: [], defs: defs, notionCategories: notionCats)
            && TaskLogic.matches($0, origin: .account("arbeit-acc"), sourceLinks: links, sources: sources)
        }
        try expectEqual(combined.map(\.id), ["n1"], "Kategorie Arbeit + Zugang Arbeit")
        let none = all.filter {
          TaskLogic.matches($0, category: "privat", folders: [], defs: defs, notionCategories: notionCats)
            && TaskLogic.matches($0, origin: .own, sourceLinks: links, sources: sources)
        }
        try expectEqual(none.map(\.id), [], "Privat + Eigene ist leer")
      },
      CheckCase("Fehler aus dem Kern kommen als Meldung zurück") {
        let model = AppModel(services: FakeServices(sample: false))
        let err = await ViewActions.setTaskDone(model, id: "gibt-es-nicht", done: true)
        try expectEqual(err, "Aufgabe nicht gefunden.")
        try expectEqual(model.reaction?.reaction, .failed("Aufgabe nicht gefunden."))
      },
      CheckCase("Notiz anlegen, ändern, löschen") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        _ = await ViewActions.addNote(model, title: "Idee", content: "Fokus-Timer")
        let n = try expectNotNil(fake.current.notes.first)
        _ = await ViewActions.updateNote(model, id: n.id, title: "Idee 2", content: "neu")
        try expectEqual(fake.current.notes[0].title, "Idee 2")
        try expectEqual(fake.current.notes[0].content, "neu")
        _ = await ViewActions.deleteNote(model, id: n.id)
        try expect(fake.current.notes.isEmpty)
      },
      CheckCase("Verpasst: Gesehen bestätigt alle") {
        let fake = FakeServices(sample: false)
        fake.current.overview.missed = [
          ReminderWithTitle(reminder: Reminder(id: "r1", source: .task, sourceRef: "t", dueAt: "2026-10-11T07:00"),
                            title: "Zahnarzt"),
        ]
        let model = AppModel(services: fake)
        await ViewActions.acknowledgeMissed(model, ids: ["r1"])
        try expect(fake.current.overview.missed.isEmpty)
      },
      CheckCase("Szenario A: Konflikt speichert nichts, erst Bestätigung speichert") {
        let svc = StubServices()
        let model = AppModel(services: svc)
        let ev = NewEvent(title: "Review", start: "2026-10-11T09:30", end: "2026-10-11T10:00")
        let first = await ViewActions.addEvent(model, ev, allowConflict: false, today: today)
        guard case .conflict(let msg, let pending, _) = first else { throw fail("Konflikt erwartet, war \(first)") }
        try expect(msg.contains("„Standup“"), msg)
        try expect(msg.contains("09:30–09:45"), msg)
        try expectEqual(pending, ev)
        try expectEqual(svc.saved.count, 0, "vor Bestätigung nichts gespeichert")
        let second = await ViewActions.addEvent(model, pending, allowConflict: true, today: today)
        try expectEqual(second, .saved(info: nil, unreachable: nil))
        try expectEqual(svc.saved, [ev])
        try expectEqual(svc.requests.map(\.allowConflict), [false, true])
      },
      CheckCase("Chat: Senden setzt Denken, lädt Verlauf") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let chat = ChatController()
        chat.input = "Hallo"
        chat.send(model)
        try expect(chat.thinking)
        try expect(model.isThinking)
        try expectEqual(chat.input, "")
        await chat.wait()
        try expect(!chat.thinking)
        try expect(!model.isThinking)
        try expectEqual(model.state?.messages.count, 2)
        try expectEqual(chat.error, nil)
      },
      CheckCase("Neuladen bündeln: 10 gleichzeitige refresh() → höchstens 2 state()-Aufrufe, danach wieder frisch") {
        let svc = StubServices()
        svc.stateDelayNs = 50_000_000
        let model = AppModel(services: svc)
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<10 { group.addTask { @MainActor in await model.refresh() } }
        }
        try expect(svc.stateCalls <= 2 && svc.stateCalls >= 1, "state() \(svc.stateCalls)×")
        try expect(model.state != nil)
        let before = svc.stateCalls
        await model.refresh()
        try expectEqual(svc.stateCalls, before + 1, "späteres refresh lädt neu")
      },
      CheckCase("Neuladen: stateChanged während state() blockiert nicht und lädt genau einmal nach") {
        let svc = StubServices()
        svc.stateDelayNs = 20_000_000
        svc.emitStateChangedOnce = true
        let model = AppModel(services: svc)
        // Der Kern meldet .stateChanged aus state() heraus; AppModel startet daraus ein Neuladen.
        await model.refresh()
        for _ in 0..<400 where svc.stateCalls < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        try expectEqual(svc.stateCalls, 2, "Neuladen aus dem Ereignis")
        await model.refresh()  // darf nicht hängen (refreshTask ist wieder frei)
        try expectEqual(svc.stateCalls, 3, "späteres refresh lädt neu")
      },
      CheckCase("Chat: Fehler wird deutsch angezeigt") {
        let svc = StubServices()
        svc.chatError = LlmError(.auth, "401")
        let model = AppModel(services: svc)
        let chat = ChatController()
        chat.input = "Hallo"
        chat.send(model)
        await chat.wait()
        try expectEqual(chat.error, ChatLogic.errorText(.auth))
        try expect(!model.isThinking)
      },
      CheckCase("Chat: Abbrechen bricht die Anfrage ab") {
        let svc = StubServices()
        svc.chatDelayNs = 2_000_000_000
        let model = AppModel(services: svc)
        let chat = ChatController()
        chat.input = "Lange Frage"
        chat.send(model)
        try await Task.sleep(nanoseconds: 50_000_000)
        chat.cancel(model)
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(!chat.thinking)
        try expect(!model.isThinking)
        try expectEqual(chat.notices, ["Abgebrochen."])
        try expectEqual(chat.error, nil)
        try expect(svc.chatWasCancelled, "Swift-Task abgebrochen")
      },
      CheckCase("Chat: laufende Antwort überlebt Ansichtswechsel (geteilter Chat)") {
        // Die Ansicht ist weg, der Chat (ChatController.shared) bleibt: Denken endet, Eingabe bleibt.
        let svc = StubServices()
        svc.chatDelayNs = 100_000_000
        let model = AppModel(services: svc)
        let chat = ChatController.shared
        chat.input = "Hallo"
        chat.send(model)
        try expect(chat.thinking)
        chat.input = "Entwurf"
        await chat.wait()
        try expect(!chat.thinking, "Denken endet nach dem Ansichtswechsel")
        try expect(!model.isThinking)
        try expectEqual(chat.input, "Entwurf", "Eingabe bleibt erhalten")
        try expectEqual(chat.error, nil)
      },
      CheckCase("Einstellungen: jede Seite steht in der Seitenleiste, Erweitertes nur auf Wunsch") {
        let listed = SettingsPage.visibleSections(advanced: true).flatMap(\.pages)
        for page in SettingsPage.allCases {
          try expect(listed.contains(page), "\(page.title) fehlt in der Seitenleiste")
          try expect(!page.summary.isEmpty, "\(page.title) ohne Erklärung")
        }
        let basic = SettingsPage.visibleSections(advanced: false).flatMap(\.pages)
        try expect(basic.contains(.model) && basic.contains(.accounts) && basic.contains(.rhythm), "Grundseiten fehlen")
        try expect(basic.contains(.updates), "Updates sind von der Grundseite aus erreichbar")
        try expect(basic.contains(.connections), "Verbindungen ist eine Grundseite")
        try expect(SettingsPage.updates.isAdvanced == false && SettingsPage.connections.isAdvanced == false, "Erweitert-Zuordnung")
        try expect(SettingsPage.network.isAdvanced && !basic.contains(.network), "Netzwerk bleibt erweitert")
        try expectEqual(Set(SettingsPage.allCases.map(\.title)).count, SettingsPage.allCases.count, "Titel doppelt")
      },
      CheckCase("Chat: leere Eingabe sendet nicht") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let chat = ChatController()
        chat.input = "   "
        try expect(!chat.canSend)
        chat.send(model)
        try expect(!chat.thinking)
        try expect(fake.current.messages.isEmpty)
      },
    ]
  }

  // MARK: - Layout

  @MainActor static var layoutCases: [CheckCase] {
    [
      CheckCase("CappedScroll: natürliche Höhe bis zur Grenze") {
        @MainActor func height<V: View>(_ v: V) -> Int {
          let r = ImageRenderer(content: v.frame(width: 100))
          r.scale = 1
          return r.cgImage?.height ?? -1
        }
        try expectEqual(height(CappedScroll(maxHeight: 200) { Color.red.frame(height: 50) }), 50)
        try expectEqual(height(CappedScroll(maxHeight: 200) { Color.red.frame(height: 900) }), 200)
      },
      CheckCase("Alle Reiter rendern in fester Breite und höchstens Maximalhöhe") {
        for spec in ViewSnapshots.tabSpecs + ViewChecks.planPickerSnapshots.prefix(2) {
          let r = ImageRenderer(content: spec.make())
          r.scale = 1
          let img = try expectNotNil(r.cgImage, "\(spec.name) rendert nicht")
          try expectEqual(img.width, Int(TabLayout.contentWidth), spec.name)
          try expect(img.height <= Int(TabLayout.maxContentHeight), "\(spec.name) zu hoch: \(img.height)")
          try expect(img.height >= 60, "\(spec.name) zu niedrig: \(img.height)")
        }
      },
    ]
  }
}

// MARK: - Stub für Konflikt-, Fehler- und Abbruch-Fälle

/// Leitet an FakeServices weiter; addEvent meldet Konflikte mit "Standup"
/// (09:30–09:45), chatSend kann werfen oder warten.
@MainActor
final class StubServices: TabyServices {
  let inner = FakeServices(sample: false)
  var requests: [AddEventRequest] = []
  var saved: [NewEvent] = []
  var chatError: LlmError?
  var chatDelayNs: UInt64 = 0
  var chatWasCancelled = false
  let standup = CalendarEvent(id: "e-standup", sourceId: "apple", title: "Standup", start: "2026-10-11T09:30",
                              end: "2026-10-11T09:45")

  func addEvent(_ req: AddEventRequest) async -> AddEventResult {
    requests.append(req)
    let s = req.event.start, e = req.event.end ?? req.event.start
    let overlaps = s < (standup.end ?? standup.start) && e > standup.start
    if overlaps && !req.allowConflict {
      return .conflict(error: "Termin überschneidet sich.", conflicts: [Conflict(with: standup, kind: .overlap)])
    }
    saved.append(req.event)
    return .ok(event: CalendarEvent(id: "neu", sourceId: "local", title: req.event.title, start: s, end: req.event.end),
               info: [], unreachable: [])
  }

  func chatSend(_ text: String) async throws -> [ChatMessage] {
    if chatDelayNs > 0 {
      do { try await Task.sleep(nanoseconds: chatDelayNs) } catch {
        chatWasCancelled = true
        throw LlmError(.cancelled, "abgebrochen")
      }
    }
    if let chatError { throw chatError }
    return try await inner.chatSend(text)
  }

  var stateCalls = 0
  var stateDelayNs: UInt64 = 0
  /// Löst während des nächsten state()-Aufrufs ein .stateChanged aus (wie der Kern nach Änderungen).
  var emitStateChangedOnce = false
  private var handlers: [@MainActor (AppEvent) -> Void] = []
  func state() async -> AppState {
    stateCalls += 1
    if emitStateChangedOnce {
      emitStateChangedOnce = false
      for h in handlers { h(.stateChanged) }
    }
    if stateDelayNs > 0 { try? await Task.sleep(nanoseconds: stateDelayNs) }
    return await inner.state()
  }
  func chatClear() async { await inner.chatClear() }
  func quickCapture(_ text: String) async throws -> [ChatMessage] {
    if let chatError { throw chatError }
    return try await inner.quickCapture(text)
  }
  func appleReminderLists() async -> ToolResult<[ReminderListInfo]> { await inner.appleReminderLists() }
  func syncAppleReminders() async -> ToolResult<Empty> { await inner.syncAppleReminders() }
  func confirmAction(_ id: String) async -> ToolResult<Empty> { await inner.confirmAction(id) }
  func rejectAction(_ id: String) async { await inner.rejectAction(id) }
  func answerDayEnd(_ answer: DayEndAnswer) async { await inner.answerDayEnd(answer) }
  func moveTasksToTomorrow(_ ids: [String]) async -> ToolResult<Empty> { await inner.moveTasksToTomorrow(ids) }
  func startFocus(taskId: String?, minutes: Int?) async -> ToolResult<FocusSession> {
    await inner.startFocus(taskId: taskId, minutes: minutes)
  }
  func stopFocus() async { await inner.stopFocus() }
  func addMemory(_ text: String) async -> ToolResult<Memory> { await inner.addMemory(text) }
  func deleteMemory(_ id: String) async -> ToolResult<Empty> { await inner.deleteMemory(id) }
  func exportMarkdown(to folder: String?) async -> ToolResult<ExportResult> { await inner.exportMarkdown(to: folder) }
  func mcpCommandPath() async -> String? { await inner.mcpCommandPath() }
  func listShortcuts() async -> ToolResult<[String]> { await inner.listShortcuts() }
  func availableVoices() async -> [VoiceInfo] { await inner.availableVoices() }
  func requestPermission(_ kind: PermissionKind) async -> Bool { true }
  func planDay() async -> ToolResult<DayPlan> { await inner.planDay() }
  func clearPlan() async { await inner.clearPlan() }
  func dismissMeeting(_ id: String) async { await inner.dismissMeeting(id) }
  func submitMeetingNotes(_ id: String, text: String) async -> ToolResult<MeetingNotesResult> {
    await inner.submitMeetingNotes(id, text: text)
  }
  func ingestFile(path: String) async throws -> [ChatMessage] { try await inner.ingestFile(path: path) }
  func answerWeeklyReview(_ answer: WeeklyReviewAnswer) async { await inner.answerWeeklyReview(answer) }
  func openWeeklyReview() async { await inner.openWeeklyReview() }
  func setWeeklyGoalDone(_ id: String, _ done: Bool) async -> ToolResult<WeeklyGoal> {
    await inner.setWeeklyGoalDone(id, done)
  }
  func installedApps() async -> [AppInfo] { await inner.installedApps() }
  func startListening(_ onText: @escaping @MainActor (String, Bool) -> Void) async -> ToolResult<Empty> {
    await inner.startListening(onText)
  }
  func stopListening() async -> String { await inner.stopListening() }
  func refreshMail() async -> ToolResult<MailOverview> { await inner.refreshMail() }
  func mailBody(_ id: String) async -> ToolResult<String> { await inner.mailBody(id) }
  func setMailRead(_ id: String, _ read: Bool) async -> ToolResult<Empty> { await inner.setMailRead(id, read) }
  func setMailFlagged(_ id: String, _ flagged: Bool) async -> ToolResult<Empty> { await inner.setMailFlagged(id, flagged) }
  func archiveMail(_ id: String) async -> ToolResult<Empty> { await inner.archiveMail(id) }
  func trashMail(_ id: String) async -> ToolResult<Empty> { await inner.trashMail(id) }
  func mailToTask(_ id: String) async -> ToolResult<TabyTask> { await inner.mailToTask(id) }
  func draftMailReply(_ id: String, instruction: String) async throws -> MailDraft {
    try await inner.draftMailReply(id, instruction: instruction)
  }
  func sendMail(_ draft: MailDraft) async -> ToolResult<Empty> { await inner.sendMail(draft) }
  func refreshNetworkInfo() async -> ToolResult<NetworkInfo> { await inner.refreshNetworkInfo() }
  func scanNetwork() async -> ToolResult<[NetworkDevice]> { await inner.scanNetwork() }
  func updateNetworkDevice(_ id: String, name: String?, known: Bool?) async -> ToolResult<NetworkDevice> {
    await inner.updateNetworkDevice(id, name: name, known: known)
  }
  func ping(_ host: String) async -> ToolResult<PingResult> { await inner.ping(host) }
  func checkPorts(_ host: String, ports: [Int]?) async -> ToolResult<[PortResult]> { await inner.checkPorts(host, ports: ports) }
  func speedTest() async -> ToolResult<SpeedResult> { await inner.speedTest() }
  func wakeOnLan(mac: String) async -> ToolResult<Empty> { await inner.wakeOnLan(mac: mac) }
  func dnsLookup(_ name: String) async -> ToolResult<DnsResult> { await inner.dnsLookup(name) }
  func publicIP() async -> ToolResult<String> { await inner.publicIP() }
  func deepScan(_ host: String, depth: ScanDepth) async -> ToolResult<ScanReport> { await inner.deepScan(host, depth: depth) }
  func listConnections() async -> ToolResult<[Connection]> { await inner.listConnections() }
  func addOwnServer(host: String, label: String) async -> ToolResult<OwnServer> { await inner.addOwnServer(host: host, label: label) }
  func removeOwnServer(_ id: String) async -> ToolResult<Empty> { await inner.removeOwnServer(id) }
  func startCapture(interface: String?, filter: String) async -> ToolResult<CaptureState> { await inner.startCapture(interface: interface, filter: filter) }
  func stopCapture() async -> ToolResult<CaptureState> { await inner.stopCapture() }
  func saveCapture(to folder: String?) async -> ToolResult<String> { await inner.saveCapture(to: folder) }
  func connectNotionTasks(token: String) async -> ToolResult<Empty> { await inner.connectNotionTasks(token: token) }
  func disconnectNotionTasks() async { await inner.disconnectNotionTasks() }
  func syncNotionTasks() async -> ToolResult<Int> { await inner.syncNotionTasks() }
  func addNotionSource(name: String, category: NotionSourceCategory, link: String) async -> ToolResult<NotionSource> {
    await inner.addNotionSource(name: name, category: category, link: link)
  }
  func updateNotionSource(_ id: String, name: String?, category: NotionSourceCategory?,
                          link: String?) async -> ToolResult<NotionSource> {
    await inner.updateNotionSource(id, name: name, category: category, link: link)
  }
  func removeNotionSource(_ id: String) async -> ToolResult<Empty> { await inner.removeNotionSource(id) }
  func completeNotionOAuth(code: String) async -> ToolResult<Empty> { await inner.completeNotionOAuth(code: code) }
  func planTasks(_ items: [PlanItem]) async -> ToolResult<DayPlan> { await inner.planTasks(items) }
  func reorderPlan(taskIds: [String]) async -> ToolResult<DayPlan> { await inner.reorderPlan(taskIds: taskIds) }
  func setTaskPriority(taskIds: [String]) async -> ToolResult<Empty> { await inner.setTaskPriority(taskIds: taskIds) }
  func captureInterfaces() async -> [String] { await inner.captureInterfaces() }
  func previewVoice(_ id: String?) async {}
  func stopSpeaking() async {}
  func speakOverview() async {}
  func createShortcutMod(shortcutName: String, description: String, asTool: Bool,
                         triggers: [ModTrigger]) async -> ToolResult<ModInfo> {
    await inner.createShortcutMod(shortcutName: shortcutName, description: description, asTool: asTool, triggers: triggers)
  }
  func setModEnabled(_ id: String, _ enabled: Bool) async -> ToolResult<ModInfo> { await inner.setModEnabled(id, enabled) }
  func deleteMod(_ id: String) async -> ToolResult<Empty> { await inner.deleteMod(id) }
  func runMod(_ id: String, input: String?) async -> ToolResult<String> { await inner.runMod(id, input: input) }
  func exportMod(_ id: String, to folder: String) async -> ToolResult<String> { await inner.exportMod(id, to: folder) }
  func importMod(from path: String) async -> ToolResult<ModInfo> { await inner.importMod(from: path) }
  func modCatalog() async -> [CatalogMod] { await inner.modCatalog() }
  func connectMessenger(_ login: MessengerLogin) async -> ToolResult<MessengerAccount> { await inner.connectMessenger(login) }
  func unlockMessenger(_ accountId: String, recoveryKey: String) async -> ToolResult<Empty> {
    await inner.unlockMessenger(accountId, recoveryKey: recoveryKey)
  }
  func disconnectMessenger(_ accountId: String) async { await inner.disconnectMessenger(accountId) }
  func messengerMessages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]> {
    await inner.messengerMessages(conversationId, limit: limit)
  }
  func sendMessengerMessage(_ conversationId: String, text: String, replyTo: String?) async -> ToolResult<Empty> {
    await inner.sendMessengerMessage(conversationId, text: text, replyTo: replyTo)
  }
  func markMessengerRead(_ conversationId: String) async { await inner.markMessengerRead(conversationId) }
  func startMessengerVerification(_ accountId: String) async -> ToolResult<Empty> {
    await inner.startMessengerVerification(accountId)
  }
  func answerMessengerVerification(_ accountId: String, matches: Bool) async -> ToolResult<Empty> {
    await inner.answerMessengerVerification(accountId, matches: matches)
  }
  func cancelMessengerVerification(_ accountId: String) async { await inner.cancelMessengerVerification(accountId) }
  func checkForUpdate() async -> ToolResult<AppUpdate?> { await inner.checkForUpdate() }
  func refreshCalendars() async { await inner.refreshCalendars() }
  func addTaskFolder(name: String) async -> ToolResult<TaskFolder> { await inner.addTaskFolder(name: name) }
  func addTaskFolder(name: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    await inner.addTaskFolder(name: name, categoryId: categoryId)
  }
  func setTaskFolderCategory(_ id: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    await inner.setTaskFolderCategory(id, categoryId: categoryId)
  }
  func renameTaskFolder(_ id: String, name: String) async -> ToolResult<TaskFolder> {
    await inner.renameTaskFolder(id, name: name)
  }
  func deleteTaskFolder(_ id: String) async -> ToolResult<Empty> { await inner.deleteTaskFolder(id) }
  func startTimer(minutes: Int, label: String) async -> ToolResult<TabyTimer> {
    await inner.startTimer(minutes: minutes, label: label)
  }
  func cancelTimer(_ id: String) async { await inner.cancelTimer(id) }
  func mediaControl(_ command: MediaCommand) async -> ToolResult<Empty> { await inner.mediaControl(command) }
  func search(_ query: String) async -> [SearchHit] { await inner.search(query) }
  func undoLast() async -> ToolResult<String> { await inner.undoLast() }
  func listBackups() async -> [BackupInfo] { await inner.listBackups() }
  func findContacts(_ query: String) async -> [ContactCard] { await inner.findContacts(query) }
  func findFiles(_ query: String) async -> [FileHit] { await inner.findFiles(query) }
  func summarizeFile(_ path: String) async -> ToolResult<String> { await inner.summarizeFile(path) }
  func captureContext() async -> ToolResult<CapturedContext> { await inner.captureContext() }
  func saveCapture(_ context: CapturedContext, as target: CaptureTarget) async -> ToolResult<Empty> {
    await inner.saveCapture(context, as: target)
  }
  func markInboxDone(_ id: String) async { await inner.markInboxDone(id) }
  func draftReply(_ id: String) async -> ToolResult<Empty> { await inner.draftReply(id) }
  func draftMeetingFollowUp(eventId: String) async -> ToolResult<Empty> { await inner.draftMeetingFollowUp(eventId: eventId) }
  func exportDiagnostics(to folder: String?) async -> ToolResult<String> { await inner.exportDiagnostics(to: folder) }
  func whatNow() async -> ToolResult<WhatNowPick> { await inner.whatNow() }
  func listAudit(limit: Int) async -> [AuditEntry] { await inner.listAudit(limit: limit) }
  func testMCPServer(_ config: MCPServerConfig) async -> ToolResult<[String]> { await inner.testMCPServer(config) }
  func setModSetting(_ id: String, key: String, value: String) async -> ToolResult<ModInfo> {
    await inner.setModSetting(id, key: key, value: value)
  }
  func runSkill(_ id: String, input: String) async throws -> [ChatMessage] { try await inner.runSkill(id, input: input) }
  func restoreBackup(_ name: String) async -> ToolResult<Empty> { await inner.restoreBackup(name) }
  func installUpdate() async -> ToolResult<Empty> { await inner.installUpdate() }
  func installCatalogMod(_ id: String) async -> ToolResult<ModInfo> { await inner.installCatalogMod(id) }
  func updateSettings(_ patch: SettingsPatch, apiKey: String?) async -> TabySettings {
    await inner.updateSettings(patch, apiKey: apiKey)
  }
  func listModels() async -> ToolResult<[String]> { await inner.listModels() }
  func testLlm() async -> LlmTestResult { await inner.testLlm() }
  func answerDayStart(_ answer: DayStartAnswer) async { await inner.answerDayStart(answer) }
  func acknowledgeMissed(_ reminderIds: [String]) async { await inner.acknowledgeMissed(reminderIds) }
  func upsertCalendarSource(_ draft: CalendarSourceDraft) async -> ToolResult<CalendarSourceConfig> {
    await inner.upsertCalendarSource(draft)
  }
  func calendarHealthCheck(_ id: String) async -> HealthResult { await inner.calendarHealthCheck(id) }
  func addTask(title: String, notes: String?, due: String?) async -> ToolResult<TabyTask> {
    await inner.addTask(title: title, notes: notes, due: due)
  }
  func updateTask(_ id: String, _ patch: TaskPatch) async -> ToolResult<TabyTask> { await inner.updateTask(id, patch) }
  func completeTask(_ id: String) async -> ToolResult<TabyTask> { await inner.completeTask(id) }
  func reopenTask(_ id: String) async -> ToolResult<TabyTask> { await inner.reopenTask(id) }
  func deleteTask(_ id: String) async -> ToolResult<Empty> { await inner.deleteTask(id) }
  func addNote(title: String, content: String) async -> ToolResult<Note> {
    await inner.addNote(title: title, content: content)
  }
  func updateNote(_ id: String, _ patch: NotePatch) async -> ToolResult<Note> { await inner.updateNote(id, patch) }
  func deleteNote(_ id: String) async -> ToolResult<Empty> { await inner.deleteNote(id) }
  func addHabit(name: String, description: String?) async -> ToolResult<Habit> {
    await inner.addHabit(name: name, description: description)
  }
  func checkHabit(_ id: String, date: String) async -> ToolResult<Habit> { await inner.checkHabit(id, date: date) }
  func deleteHabit(_ id: String) async -> ToolResult<Empty> { await inner.deleteHabit(id) }
  func listEvents(from: String, to: String) async -> [CalendarEvent] { [standup] }
  func deleteEvent(id: String, sourceId: String) async -> ToolResult<Empty> { await inner.deleteEvent(id: id, sourceId: sourceId) }
  func scheduleJob(_ req: ScheduleJobRequest) async -> ToolResult<Job> { await inner.scheduleJob(req) }
  func cancelJob(_ id: String) async -> ToolResult<Empty> { await inner.cancelJob(id) }
  func agentsInstalled() async -> Bool { await inner.agentsInstalled() }
  func agentsInstall() async -> ToolResult<Empty> { await inner.agentsInstall() }
  func agentsUninstall() async { await inner.agentsUninstall() }
  func resolveAgentRequest(_ id: String, _ decision: AgentPermissionDecision) async {
    await inner.resolveAgentRequest(id, decision)
  }
  func subscribe(_ handler: @escaping @MainActor (AppEvent) -> Void) {
    handlers.append(handler)
    inner.subscribe(handler)
  }
}

// MARK: - Snapshots


extension ViewChecks {
  @MainActor static var packageOneCases: [CheckCase] {
    [
      CheckCase("Verbrauch: Dollar mit deutschem Komma, kleine Beträge signifikant") {
        try expectEqual(UsageLogic.dollars(0), "0,00 $")
        try expectEqual(UsageLogic.dollars(1.37), "1,37 $")
        try expectEqual(UsageLogic.dollars(0.0042), "0,0042 $")
        try expectEqual(UsageLogic.limitLabel(0), "kein")
      },
      CheckCase("Verbrauch: Tokens in Tsd./Mio.") {
        try expectEqual(UsageLogic.tokens(950), "950 Tokens")
        try expectEqual(UsageLogic.tokens(18_400), "18,4 Tsd. Tokens")
        try expectEqual(UsageLogic.tokens(1_250_000), "1,2 Mio. Tokens")
      },
      CheckCase("Verbrauch: Warnstufe") {
        try expectEqual(UsageLogic.level(UsageSummary()), .none)
        try expectEqual(UsageLogic.level(UsageSummary(nearLimit: true)), .near)
        try expectEqual(UsageLogic.level(UsageSummary(limitReached: true, nearLimit: true)), .reached)
        try expect(UsageLogic.chipText(.none) == nil)
      },
      CheckCase("Einstellungen: Patch enthält die neuen Felder nur bei Änderung") {
        var b = TabySettings.defaults
        b.briefingModel = "openai/gpt-5-mini"
        b.bufferMinutes = 15
        b.dailyCostLimitUsd = 2
        b.appleRemindersSync = true
        b.appleRemindersListId = "L2"
        b.quickCaptureShortcut = "Control+Option+K"
        let p = SettingsLogic.patch(from: .defaults, to: b)
        try expectEqual(p.briefingModel, "openai/gpt-5-mini")
        try expectEqual(p.bufferMinutes, 15)
        try expectEqual(p.dailyCostLimitUsd, 2)
        try expectEqual(p.monthlyCostLimitUsd, nil)
        try expectEqual(p.appleRemindersSync, true)
        try expectEqual(p.appleRemindersListId, "L2")
        try expectEqual(p.quickCaptureShortcut, "Control+Option+K")
        try expect(SettingsLogic.isEmpty(SettingsLogic.patch(from: b, to: b)))
      },
      CheckCase("Kalender: zu knapp nennt Termin und Abstand, echte Überschneidung bleibt") {
        let e = CalendarEvent(id: "e", sourceId: "local", title: "Standup", start: "2026-10-11T09:30",
                              end: "2026-10-11T09:45")
        let tight = CalendarLogic.conflictMessage(error: "zu knapp", conflicts: [Conflict(with: e, kind: .tooClose)],
                                                  today: ViewChecks.today, bufferMinutes: 15)
        try expect(tight.hasPrefix("Zu knapp an „Standup“"), tight)
        try expect(tight.contains("weniger als 15 Minuten"), tight)
        let overlap = CalendarLogic.conflictMessage(error: "Termin überschneidet sich.",
                                                    conflicts: [Conflict(with: e, kind: .overlap)], today: ViewChecks.today)
        try expect(overlap.contains("Überschneidet sich mit"), overlap)
      },
      CheckCase("Chat: eigenes Kostenlimit wird nicht als Anbieter-Kontingent gemeldet") {
        let msg = ChatLogic.errorToGerman(LlmError(.quota, "Kostenlimit erreicht – das Modell pausiert."))
        try expect(msg?.hasPrefix("Kostenlimit") == true, msg ?? "nil")
        try expectEqual(ChatLogic.errorToGerman(LlmError(.quota, "402")), ChatLogic.errorText(.quota))
      },
      CheckCase("Schnellerfassung: Erfolg legt an und zeigt die Antwort") {
        let fake = FakeServices(sample: false)
        let m = QuickCaptureModel(services: fake)
        m.text = "  Zahnarzt anrufen  "
        let ok = await m.submit()
        try expect(ok)
        try expectEqual(fake.current.tasks.map(\.title), ["Zahnarzt anrufen"])
        try expectEqual(m.text, "")
        guard case .done(let reply) = m.phase else { throw fail("erwartet .done, war \(m.phase)") }
        try expect(reply.contains("Zahnarzt"), reply)
      },
      CheckCase("Schnellerfassung: leere Eingabe wird nicht gesendet") {
        let fake = FakeServices(sample: false)
        let m = QuickCaptureModel(services: fake)
        m.text = "   "
        try expect(!m.canSend)
        let ok = await m.submit()
        try expect(!ok)
        try expectEqual(fake.current.tasks.count, 0)
      },
      CheckCase("Schnellerfassung: Fehler zeigt deutschen Text und behält die Eingabe") {
        let stub = StubServices()
        stub.chatError = LlmError(.network, "x")
        let m = QuickCaptureModel(services: stub)
        m.text = "Milch kaufen"
        let ok = await m.submit()
        try expect(!ok)
        try expectEqual(m.text, "Milch kaufen")
        try expectEqual(m.phase, .failed(ChatLogic.errorText(.network)))
      },
    ]
  }
}


extension ViewChecks {
  @MainActor static var packageTwoCases: [CheckCase] {
    [
      CheckCase("Tagesabschluss: offene Aufgaben ohne Doppelte, überfällige zuerst, erledigte raus") {
        let a = TabyTask(id: "a", title: "Alt", due: "2026-10-09", createdAt: "")
        let b = TabyTask(id: "b", title: "Heute", due: "2026-10-11", createdAt: "")
        let d = TabyTask(id: "d", title: "Fertig", due: "2026-10-11", done: true, createdAt: "")
        let o = Overview(overdueTasks: [a], todayTasks: [b, a, d])
        try expectEqual(DayEndLogic.openTasks(o).map(\.id), ["a", "b"])
      },
      CheckCase("Fokus: Restzeit und Anzeige") {
        let now = try expectNotNil(LocalTime.parse("2026-10-11T09:10:30"))
        try expectEqual(FocusLogic.remaining(endsAt: "2026-10-11T09:25:00", now: now), 870)
        try expectEqual(FocusLogic.format(870), "14:30")
        try expectEqual(FocusLogic.remaining(endsAt: "2026-10-11T09:00:00", now: now), 0)
        try expectEqual(FocusLogic.todayLine(0), nil)
        try expectEqual(FocusLogic.todayLine(50), "Heute fokussiert: 50 Min")
        try expectEqual(FocusLogic.todayLine(95), "Heute fokussiert: 1 Std 35 Min")
      },
      CheckCase("Einstellungen: Patch für Paket-2-Felder und MCP-Schnipsel") {
        var b = TabySettings.defaults
        b.dayEndTime = "21:00"
        b.focusMinutes = 45
        b.mcpEnabled = true
        b.exportFolder = "/tmp/x"
        let p = SettingsLogic.patch(from: .defaults, to: b)
        try expectEqual(p.dayEndTime, "21:00")
        try expectEqual(p.focusMinutes, 45)
        try expectEqual(p.mcpEnabled, true)
        try expectEqual(p.exportFolder, "/tmp/x")
        try expectEqual(p.breakMinutes, nil)
        try expectEqual(SettingsLogic.claudeSnippet("/A/taby-mcp"), "claude mcp add taby -- \"/A/taby-mcp\"")
        try expect(SettingsLogic.yamlSnippet("/A/taby-mcp").contains("command: \"/A/taby-mcp\""))
      },
      CheckCase("Tagesabschluss über FakeServices: Alles auf morgen verschiebt") {
        let fake = FakeServices()
        await fake.answerDayEnd(.moveAllToTomorrow)
        let open = fake.current.tasks.filter { !$0.done }
        try expect(open.allSatisfy { ($0.due ?? "2026-10-12").hasPrefix("2026-10-12") }, "\(open.map(\.due))")
      },
    ]
  }
}


extension ViewChecks {
  @MainActor static var packageThreeCases: [CheckCase] {
    [
      CheckCase("Mods: Reiter-Trennung ab vier Mods, Hinweis nur für frisch hinzugefügte") {
        let base = ModManifest(id: "n-mod", name: "N", description: "x", kind: .shortcut, shortcutName: "N")
        try expect(!ModsLogic.splitView(3) && ModsLogic.splitView(4), "Schwelle bei vier Mods")
        try expect(ModsLogic.isNew(ModInfo(manifest: base)), "neu: aus und nie freigegeben")
        try expect(!ModsLogic.isNew(ModInfo(manifest: base, enabled: true, approved: false)), "eingeschaltet ist nicht neu")
      },
      CheckCase("Mods: Status, Reihenfolge (Freigabe nötig zuerst), Texte") {
        let base = ModManifest(id: "a-mod", name: "B", description: "x", kind: .shortcut, shortcutName: "B")
        let active = ModInfo(manifest: base, enabled: true, approved: true)
        var m2 = base; m2.id = "b-mod"; m2.name = "A"
        let off = ModInfo(manifest: m2)
        var m3 = base; m3.id = "c-mod"; m3.name = "C"
        let pending = ModInfo(manifest: m3, enabled: true, approved: false)
        try expectEqual(ModsLogic.status(active), .active)
        try expectEqual(ModsLogic.status(off), .off)
        try expectEqual(ModsLogic.status(pending), .needsApproval)
        try expectEqual(ModsLogic.sorted([off, active, pending]).map(\.id), ["c-mod", "a-mod", "b-mod"])
        try expectEqual(ModsLogic.triggerText(.focusStarted), "bei Fokus-Start")
      },
      CheckCase("Mods: Freigabe-Texte nennen Kurzbefehl bzw. Rechte") {
        let sc = ModManifest(id: "fokus", name: "Fokus an", description: "", kind: .shortcut, shortcutName: "Fokus an")
        try expect(ModsLogic.grants(sc).first?.contains("„Fokus an“") == true)
        let js = ModManifest(id: "wetter", name: "Wetter", description: "", kind: .script, entry: "main.js",
                             permissions: ["tasks.read", "http:api.open-meteo.com"])
        try expectEqual(ModsLogic.grants(js), ["Aufgaben lesen", "Internet: api.open-meteo.com abrufen", "Kann gelesene Daten ins Internet schicken"])
        let none = ModManifest(id: "leer", name: "Leer", description: "", kind: .script, entry: "main.js")
        try expectEqual(ModsLogic.grants(none), ["Keine besonderen Rechte"])
      },
      CheckCase("Mods über FakeServices: Kurzbefehl-Mod anlegen und einschalten") {
        let fake = FakeServices(sample: false)
        guard case .ok(let m) = await fake.createShortcutMod(shortcutName: "Licht dimmen", description: "Dimmt",
                                                             asTool: true, triggers: [.focusStarted]) else {
          throw fail("nicht angelegt")
        }
        try expectEqual(m.manifest.kind, .shortcut)
        try expect(m.manifest.tool != nil)
        try expectEqual(ModsLogic.status(m), .off)
        guard case .ok(let on) = await fake.setModEnabled(m.id, true) else { throw fail("nicht eingeschaltet") }
        try expectEqual(ModsLogic.status(on), .active)
      },
    ]
  }
}


extension ViewChecks {
  @MainActor static var onboardingCases: [CheckCase] {
    [
      CheckCase("Einrichtung: Schrittfolge vor/zurück, Fortschritt") {
        try expectEqual(OnboardingFlow.next(.setup), .model)
        try expectEqual(OnboardingFlow.next(.shortcuts), .howTo)
        try expectEqual(OnboardingFlow.next(.howTo), .done)
        try expectEqual(OnboardingFlow.next(.done), .done)
        try expectEqual(OnboardingFlow.back(.setup), .setup)
        try expectEqual(OnboardingFlow.back(.calendar), .model)
        try expectEqual(OnboardingFlow.progress(.setup), 0)
        try expectEqual(OnboardingFlow.progress(.done), 1)
      },
      CheckCase("Einrichtung: Freigaben über FakeServices") {
        let fake = FakeServices(sample: false)
        let ok = await fake.requestPermission(.reminders)
        try expect(ok)
      },
    ] + OnboardingSetupChecks.cases
  }
}

enum ViewSnapshots {
  static let size = CGSize(width: TabLayout.contentWidth, height: 420)

  @MainActor static var all: [SnapshotSpec] {
    // Oben ausgerichtet; der Rest des 420-pt-Rahmens zeigt die natürliche Höhe.
    (tabSpecs + [daystart]).map { spec in
      SnapshotSpec(spec.name, size: size) {
        AnyView(spec.make().frame(maxHeight: .infinity, alignment: .top))
      }
    } + PackageFourChecks.snapshots + MeetingPrepChecks.snapshots + ListeningChecks.snapshots + MailChecks.snapshots + NetworkChecks.snapshots + NetworkProUIChecks.snapshots + MusicChecks.snapshots + onboardingSpecs
      + noteSnapshots + ViewChecks.planPickerSnapshots + settingsWindowSnapshots + settingsPageSnapshots
      + ViewSupportChecks.snapshots
      + TaskNotesChecks.snapshots + TaskStatusChecks.snapshots + TagChecks.snapshots + NoteEditorChecks.snapshots + NoteFilterChecks.snapshots + TaskCategoryChecks.snapshots + PrivacyViewChecks.snapshots + ObsidianChecks.snapshots
      + UpdatesPageChecks.snapshots
      + NotionAccountViewChecks.snapshots + ExplainChecks.snapshots + NotionStatusMapChecks.snapshots + NotionSectionChecks.snapshots
      + ShareSnapshots.all + MicrosoftSnapshots.all
  }

  /// Notizen mit Checkboxen: Insel-Ansicht und eigenes Fenster (800 × 600), das die Fläche füllt.
  @MainActor static var noteSnapshots: [SnapshotSpec] {
    let checklist = """
    Meeting Kunde Nord
    - [x] Budget freigegeben
    - [ ] Angebot an Lena schicken
    - [ ] Termin mit dem Kunden bestätigen
    Ergebnis: Rollout verschiebt sich auf KW 44, weil die Schnittstelle noch fehlt.
      - [ ] Testzugänge anlegen
    Nächster Schritt: Review am Freitag.
    """
    func notesFake() -> FakeServices {
      let fake = FakeServices(sample: false)
      fake.current.notes = [
        Note(id: "nc1", title: "Meeting Kunde Nord", content: checklist, createdAt: ViewChecks.now, updatedAt: ViewChecks.now),
        Note(id: "nc2", title: "Einkaufsliste", content: "- [ ] Kaffee\n- [x] Hafermilch", createdAt: ViewChecks.now,
             updatedAt: ViewChecks.now),
        Note(id: "nc3", title: "Ideen für Lumi", content: "Wetter im Briefing, Fokus-Timer, Spotify",
             createdAt: ViewChecks.now, updatedAt: ViewChecks.now),
      ]
      return fake
    }
    return [
      SnapshotSpec("view-notes-checklist", size: size) {
        let fake = notesFake()
        return wrap(NotesView(notes: fake.current.notes, expanded: "nc1").tabyPage(), AppModel(services: fake))
      },
      SnapshotSpec("view-notes-detached-expanded", size: CGSize(width: 800, height: 600)) {
        let fake = notesFake()
        return wrap(DetachedNotesView(notes: fake.current.notes, expanded: "nc1"), AppModel(services: fake))
      },
      SnapshotSpec("view-notes-detached-list", size: CGSize(width: 800, height: 600)) {
        let fake = notesFake()
        return wrap(DetachedNotesView(notes: fake.current.notes), AppModel(services: fake))
      },
    ]
  }

  /// Einrichtungs-Assistent (eigenes Fenster, 560 × 520).
  @MainActor static var onboardingSpecs: [SnapshotSpec] {
    [onboarding("onboarding-setup", .setup), onboarding("onboarding-model", .model),
     onboarding("onboarding-calendar", .calendar), onboarding("onboarding-notify", .notify),
     onboarding("onboarding-shortcuts", .shortcuts), onboarding("onboarding-howto", .howTo),
     onboarding("onboarding-done", .done), onboarding("onboarding-model-cloud", .model, think: .cloud),
     onboarding("onboarding-setup-failed", .setup, setup: .failed("Zertifikat konnte nicht angelegt werden (security 1)."))]
  }

  @MainActor static var tabSpecs: [SnapshotSpec] {
    [
      tab("view-today", .today) { fake, model in
        fake.current.overview.missed = [
          ReminderWithTitle(reminder: Reminder(id: "r1", source: .task, sourceRef: "t", dueAt: "2026-10-11T07:30"),
                            title: "Medikament nehmen"),
        ]
        fake.current.overview.conflicts = [
          Conflict(with: CalendarEvent(id: "c", sourceId: "apple", title: "Mittag mit Lena", start: "2026-10-11T12:30",
                                       end: "2026-10-11T13:30"), kind: .overlap),
        ]
        fake.emit(.briefingReady(Briefing(overview: fake.current.overview,
                                          text: "Guten Morgen! Drei Termine heute, der erste um 09:30. Die Steuererklärung ist seit Freitag überfällig – vielleicht direkt nach dem Standup?",
                                          generatedByModel: true)))
        _ = model
      },
      tab("view-today-empty", .today, sample: false),
      tab("view-chat", .chat) { fake, _ in
        fake.current.messages += [
          ChatMessage(role: .user, content: "Erinnere mich morgen um 8 an den Wochenplan."),
          ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "1", name: "add_task", arguments: "{}")]),
          ChatMessage(role: .tool, content: #"{"ok":true,"task":{"title":"Wochenplan"}}"#, name: "add_task",
                      toolCallId: "1"),
          ChatMessage(role: .assistant, content: "Erledigt – ich erinnere dich morgen um 08:00."),
        ]
      },
      SnapshotSpec("view-chat-thinking", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        model.isThinking = true
        let page = ChatView(state: fake.current, controller: ChatController(thinking: true,
                                                                            pendingUserText: "Was steht morgen an?"))
          .tabyPage()
        return wrap(page, model)
      },
      SnapshotSpec("view-chat-error", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let page = ChatView(state: fake.current, controller: ChatController(error: ChatLogic.errorText(.auth)))
          .tabyPage()
        return wrap(page, model)
      },
      tab("view-chat-empty", .chat, sample: false),
      SnapshotSpec("view-agents-request", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        fake.emit(.agentRequest(AgentPermissionRequest(
          id: "req-1", toolName: "Bash",
          toolInput: ["command": "npx prisma migrate deploy", "description": "Migration"],
          cwd: NSHomeDirectory() + "/Projekte/taby")))
        return wrap(AgentsView(installed: true).tabyPage(), model)
      },
      SnapshotSpec("view-agents-idle", size: size) {
        let model = AppModel(services: FakeServices())
        return wrap(AgentsView(installed: true).tabyPage(), model)
      },
      SnapshotSpec("view-agents-setup", size: size) {
        let model = AppModel(services: FakeServices())
        return wrap(AgentsView(installed: false).tabyPage(), model)
      },
      tab("view-tasks", .tasks),
      SnapshotSpec("view-tasks-done-due", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, showDone: true, showDue: true).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-notion-origin", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = [
          TabyTask(id: "nt1", title: "Angebot für Kunde X", due: "2026-10-14", createdAt: "2026-10-13T08:00", category: .arbeit),
          TabyTask(id: "nt2", title: "Steuerunterlagen sortieren", createdAt: "2026-10-12T10:00", category: .privat),
          TabyTask(id: "nt3", title: "Review PR #42", done: true, doneAt: "2026-10-12T17:00", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "own1", title: "Zahnarzt anrufen", due: "2026-10-15T09:00", createdAt: "2026-10-11T08:00"),
          TabyTask(id: "own2", title: "Einkaufsliste", createdAt: "2026-10-11T18:00", category: .privat),
        ]
        fake.current.notionSourceLinks = ["nt1": "s1", "nt2": "s1", "nt3": "s2"]
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, notionLinks: fake.current.notionSourceLinks,
                              showDone: true).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-edit-due", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.tasks = [
          TabyTask(id: "e1", title: "Zahnarzt anrufen", due: "2026-10-12T15:00", createdAt: "2026-10-11T08:00"),
          TabyTask(id: "e2", title: "Einkaufsliste", createdAt: "2026-10-11T18:00", category: .privat),
        ]
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, editingId: "e1").tabyPage(), model)
      },
      SnapshotSpec("view-tasks-folders-grouped", size: size) {
        let fake = ViewChecks.taskFolderFixture()
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, folders: fake.current.taskFolders).tabyPage(), model)
      },
      SnapshotSpec("view-tasks-folder-selected", size: size) {
        let fake = ViewChecks.taskFolderFixture()
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, folders: fake.current.taskFolders,
                              selectedFolder: "f-arbeit").tabyPage(), model)
      },
      SnapshotSpec("view-tasks-categories", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.settings.taskCategories = TaskCategoryChecks.defs
        fake.current.taskFolders = [
          TaskFolder(id: "f-reise", name: "Reise", createdAt: "2026-10-01T08:00", categoryId: "privat"),
          TaskFolder(id: "f-lauf", name: "Laufen", createdAt: "2026-10-01T08:00", categoryId: "sport"),
          TaskFolder(id: "f-ideen", name: "Ideen", createdAt: "2026-10-01T08:00"),
        ]
        fake.current.tasks = [
          TabyTask(id: "c1", title: "Flug nach Lissabon buchen", due: "2026-10-14", createdAt: "2026-10-13T08:00",
                   category: .privat, folderId: "f-reise"),
          TabyTask(id: "c2", title: "Einkauf", createdAt: "2026-10-11T18:00", category: .privat),
          TabyTask(id: "c3", title: "10 km Intervalle", due: "2026-10-15T07:00", createdAt: "2026-10-12T08:00",
                   category: TaskCategory(rawValue: "sport")),
        ]
        let model = AppModel(services: fake)
        return wrap(TasksView(tasks: fake.current.tasks, folders: fake.current.taskFolders,
                              categories: TaskCategoryChecks.defs, selectedCategory: "privat").tabyPage(), model)
      },
      tab("view-tasks-empty", .tasks, sample: false),
      tab("view-notes", .notes),
      SnapshotSpec("view-notes-expanded", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        return wrap(NotesView(notes: fake.current.notes, expanded: fake.current.notes.first?.id).tabyPage(), model)
      },
      tab("view-notes-empty", .notes, sample: false),
      tab("view-calendar", .calendar) { fake, _ in
        fake.current.overview.eventsUpcoming = [
          CalendarEvent(id: "u1", sourceId: "ics-1", title: "Feiertag", start: "2026-10-12", allDay: true,
                        readOnly: true),
          CalendarEvent(id: "u2", sourceId: "local", title: "Laufen", start: "2026-10-12T18:00", end: "2026-10-12T19:00"),
          CalendarEvent(id: "u3", sourceId: "notion:team", title: "Sprint-Planung", start: "2026-10-14T10:00",
                        end: "2026-10-14T11:30"),
        ]
        fake.current.calendarSources.append(CalendarSourceConfig(id: "notion:team", kind: .notion))
        fake.current.calendarSources.append(CalendarSourceConfig(id: "ics-1", kind: .ics))
      },
      SnapshotSpec("view-calendar-conflict", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let standup = fake.current.overview.eventsToday[0]
        let msg = CalendarLogic.conflictMessage(error: "Termin überschneidet sich.",
                                                conflicts: [Conflict(with: standup, kind: .overlap)],
                                                today: ViewChecks.today)
        let pending = NewEvent(title: "Review", start: "2026-10-11T09:30", end: "2026-10-11T10:30")
        return wrap(CalendarView(state: fake.current, outcome: .conflict(message: msg, pending: pending, tight: true),
                                 title: "Review").tabyPage(), model)
      },
      tab("view-calendar-empty", .calendar, sample: false),
      tab("view-settings", .settings) { fake, _ in
        fake.current.jobs = [
          Job(id: "j1", name: "Wochenplan", prompt: "…", rule: .weekly(days: [1], time: "08:00"), createdAt: ""),
          Job(id: "j2", name: "Morgen-Briefing", prompt: "…", rule: .daily(time: "07:30"), mode: .readOnly,
              createdAt: ""),
        ]
      },
      SnapshotSpec("view-settings-full", size: CGSize(width: TabLayout.contentWidth, height: 1500)) {
        let fake = FakeServices()
        fake.current.settings.appleRemindersSync = true
        fake.current.settings.bufferMinutes = 15
        fake.current.settings.dailyCostLimitUsd = 2
        fake.current.usage.nearLimit = true
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs).tabyPage(), model)
      },
      SnapshotSpec("view-settings-tasks", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        // Nur die Karte: das Formular der Einstellungen lädt seinen Stand aus dem Dienst, nicht aus dem Argument.
        return wrap(TaskCategoriesCard(categories: .constant(TaskCategoryChecks.defs)).tabyPage(), model)
      },
      SnapshotSpec("view-settings-calendar", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .accounts).tabyPage(), model)
      },
      SnapshotSpec("view-settings-calendar-add-caldav", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let fake = FakeServices()
        fake.current.calendarSources = []  // Formular oben, damit es im Bild ist
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, addKind: .caldav,
                                 page: .accounts).tabyPage(), model)
      },
      SnapshotSpec("view-settings-voice", size: size) {
        let fake = FakeServices()
        fake.current.settings.voiceEnabled = true
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .assistant).tabyPage(), model)
      },
      SnapshotSpec("view-quickcapture", size: CGSize(width: TabLayout.contentWidth, height: 120)) {
        let model = AppModel(services: FakeServices(sample: false))
        return wrap(QuickCaptureView(onDone: {}), model)
      },
      SnapshotSpec("view-calendar-tooclose", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let standup = fake.current.overview.eventsToday[0]
        let msg = CalendarLogic.conflictMessage(error: "zu knapp", conflicts: [Conflict(with: standup, kind: .tooClose)],
                                                today: ViewChecks.today, bufferMinutes: 15)
        let pending = NewEvent(title: "Review", start: "2026-10-11T09:50", end: "2026-10-11T10:30")
        return wrap(CalendarView(state: fake.current, outcome: .conflict(message: msg, pending: pending, tight: true),
                                 title: "Review").tabyPage(), model)
      },
      SnapshotSpec("view-dayend", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        fake.current.dayEndPrompt = true
        return wrap(DayEndView(preview: fake.current.overview), model)
      },
      SnapshotSpec("view-today-focus", size: size) {
        let fake = FakeServices()
        fake.current.focus = FocusSession(id: "f", title: "Präsentation üben", startedAt: "2026-10-11T09:00:00",
                                          endsAt: "2026-10-11T09:25:00", minutes: 25)
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .today, preview: fake.current), model)
      },
      // Heute ohne Plan-Abschnitt: nur Aufgaben und Termine, Plan-Zeit nur bei Abweichung.
      SnapshotSpec("view-today-clean", size: size) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .today, preview: fake.current), model)
      },
      SnapshotSpec("view-today-tagesplan", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        return wrap(TodayView(state: fake.current, startsWithPlan: true).tabyPage(), model)
      },
      SnapshotSpec("view-today-was-jetzt", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        let pick = WhatNowPick(task: fake.current.tasks[0], reason: "Überfällig seit Mo")
        return wrap(TodayView(state: fake.current, whatNow: pick).tabyPage(), model)
      },
      SnapshotSpec("view-plan-grund", size: CGSize(width: TabLayout.contentWidth, height: 260)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        fake.current.plan?.blocks[0].reason = "Freie Lücke vor „Standup“"
        fake.current.plan?.blocks[1].reason = "Nach der Mittagspause"
        let model = AppModel(services: fake)
        return wrap(PlanSection(state: fake.current, reasonOpen: fake.current.plan?.blocks.first?.id).tabyPage(), model)
      },
      tab("view-mods", .mods),
      // Bibliothek ohne installierte Mods (Abschnitt steht oben) und mit einem installierten Eintrag.
      tab("view-mods-library", .mods, sample: false),
      tab("view-mods-library-installed", .mods, sample: false) { fake, _ in
        let entry = ModCatalog.entries[0]
        fake.current.mods = [ModInfo(manifest: entry.manifest, code: entry.code)]
      },
      // Die Wetter-Zeile allein: im Reiter begrenzt die Bibliothek die Höhe, die lange Rechte-Reihe muss umbrechen.
      SnapshotSpec("view-mods-library-wetter", size: size) {
        let model = AppModel(services: FakeServices(sample: false))
        return wrap(CatalogRow(entry: ModCatalog.entries[3], installed: false, onMessage: { _, _ in })
          .padding(16).frame(width: TabLayout.contentWidth, alignment: .leading), model)
      },
      SnapshotSpec("view-notion-empty", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-notion-set", size: size) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionTasksSync = NotionTaskSync(lastSyncAt: "2026-10-13T08:30", importedCount: 2)
        fake.current.notionLinkedTasks = [
          TabyTask(id: "nt1", title: "Angebot für Kunde X", createdAt: fake.current.overview.eventsToday.isEmpty ? "2026-10-13T08:00" : "2026-10-13T08:00"),
          TabyTask(id: "nt2", title: "Review PR #42", done: true, doneAt: "2026-10-12T17:00", createdAt: "2026-10-12T09:00"),
        ]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-notion-sources", size: CGSize(width: TabLayout.contentWidth, height: 600)) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Tickets Projekt", category: .tickets, link: "1a2b3c"),
          NotionSource(id: "s2", name: "Weekly", category: .weekly, link: "4d5e6f"),
          NotionSource(id: "s3", name: "Büro", category: .todos, link: "7a8b9c"),
        ]
        fake.current.notionLinkedTasks = [
          TabyTask(id: "nt1", title: "Angebot für Kunde X", createdAt: "2026-10-13T08:00"),
          TabyTask(id: "nt2", title: "Steuerunterlagen sortieren", createdAt: "2026-10-12T10:00"),
          TabyTask(id: "nt3", title: "Weekly 1:1", notes: "## Core Task\n☐ 1:1 vorbereiten", createdAt: "2026-10-13T09:00"),
          TabyTask(id: "nt4", title: "Review PR #42", done: true, doneAt: "2026-10-12T17:00", createdAt: "2026-10-12T09:00"),
        ]
        fake.current.notionSourceLinks = ["nt1": "s1", "nt2": "s3", "nt3": "s2", "nt4": "s3"]
        fake.current.notionTaskGroups = ["nt3": "2026-10-13 · Weekly 1:1"]
        fake.current.notionTaskMeta = ["nt1": NotionTaskMeta(createdAt: "2026-10-13T08:00", createdBy: "Felix",
                                                             status: "In Bearbeitung")]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-notion-ticket-open", size: CGSize(width: TabLayout.contentWidth, height: 600)) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Tickets Projekt", category: .tickets, link: "1a2b3c"),
        ]
        fake.current.notionLinkedTasks = [
          TabyTask(id: "t1", title: "Drucker im Büro", notes: """
            # Ausgangslage
            Toner im Schrank links tauschen.
            ☐ Testdruck auf Etage 2
              • Treiber auf dem Laptop aktualisieren
            > Bitte vorher den Admin informieren
            —
            ↳ Anleitung Drucker
            ▸ Details
            """, createdAt: "2026-10-13T08:00"),
          TabyTask(id: "t2", title: "VPN-Zugang für Praktikantin", createdAt: "2025-12-03T09:00"),
        ]
        fake.current.notionSourceLinks = ["t1": "s1", "t2": "s1"]
        fake.current.notionTaskPages = ["t1": "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"]
        fake.current.notionTaskMeta = [
          "t1": NotionTaskMeta(createdAt: "2026-10-13T08:00", createdBy: "Felix", status: "Neu"),
          "t2": NotionTaskMeta(createdAt: "2025-12-03T09:00", status: "In Bearbeitung"),
        ]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current, openTicket: "t1").tabyPage(), model)
      },
      SnapshotSpec("view-notion-weekly", size: CGSize(width: TabLayout.contentWidth, height: 600)) {
        // Weekly: zwei Wochen als Chips, gewählt die neueste; darunter ihre To-dos (eins erledigt).
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Weekly", category: .weekly, link: "4d5e6f"),
        ]
        fake.current.notionLinkedTasks = [
          TabyTask(id: "w1", title: "Weekly 1:1", notes: """
            ## Core Task
            ☐ Locale AI + Hermes Agenten ?
            ☑ Review PR #42
            > Nächste Woche neu besprechen
            • Notion / Langdock KI / Claude
            """, createdAt: "2026-10-13T08:00"),
          TabyTask(id: "w2", title: "Locale AI + Hermes Agenten ?", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "w5", title: "Notion aufräumen", due: "2026-10-16", createdAt: "2026-10-12T12:00"),
          TabyTask(id: "w4", title: "Review PR #42", done: true, doneAt: "2026-10-13T10:00", createdAt: "2026-10-12T11:00"),
          TabyTask(id: "w3", title: "Weekly 1:1", notes: "## Core Task\n☑ Mail an Kunde",
                   done: true, doneAt: "2026-10-09T17:00", createdAt: "2026-10-08T10:00"),
          TabyTask(id: "w6", title: "Mail an Kunde", createdAt: "2026-10-08T11:00"),
        ]
        fake.current.notionSourceLinks = ["w1": "s1", "w2": "s1", "w3": "s1", "w4": "s1", "w5": "s1", "w6": "s1"]
        fake.current.notionTaskGroups = ["w1": "2026-10-13 · Weekly 1:1", "w2": "2026-10-13 · Weekly 1:1",
                                         "w4": "2026-10-13 · Weekly 1:1", "w5": "2026-10-13 · Weekly 1:1",
                                         "w3": "2026-10-08 · Weekly 1:1", "w6": "2026-10-08 · Weekly 1:1"]
        fake.current.notionTaskPages = ["w1": "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-notion-weekly-page", size: CGSize(width: TabLayout.contentWidth, height: 600)) {
        // Wie oben, aber „Ganze Seite“ der Besprechung ist aufgeklappt (Notion-Inhalt mit Häkchen).
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Weekly", category: .weekly, link: "4d5e6f"),
        ]
        fake.current.notionLinkedTasks = [
          TabyTask(id: "w1", title: "Weekly 1:1", notes: "## Core Task\n☐ Locale AI + Hermes Agenten ?\n☑ Review PR #42",
                   createdAt: "2026-10-13T08:00"),
          TabyTask(id: "w2", title: "Locale AI + Hermes Agenten ?", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "w4", title: "Review PR #42", done: true, doneAt: "2026-10-13T10:00", createdAt: "2026-10-12T11:00"),
        ]
        fake.current.notionSourceLinks = ["w1": "s1", "w2": "s1", "w4": "s1"]
        fake.current.notionTaskGroups = ["w1": "2026-10-13 · Weekly 1:1", "w2": "2026-10-13 · Weekly 1:1",
                                         "w4": "2026-10-13 · Weekly 1:1"]
        fake.current.notionTaskPages = ["w1": "1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6"]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current, openTicket: "w1").tabyPage(), model)
      },
      SnapshotSpec("view-notion-todos", size: CGSize(width: TabLayout.contentWidth, height: 600)) {
        // To-dos-Kategorie: zwei offene, zwei erledigte; „Erledigt“ bleibt eingeklappt.
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Büro", category: .todos, link: "7a8b9c"),
        ]
        fake.current.notionLinkedTasks = [
          TabyTask(id: "d1", title: "Drucker-Toner bestellen", due: "2026-10-13", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "d2", title: "Mail an Lieferant schreiben", createdAt: "2026-10-11T10:00"),
          TabyTask(id: "d3", title: "Review PR #42", done: true, doneAt: "2026-10-12T17:00", createdAt: "2026-10-12T09:00"),
          TabyTask(id: "d4", title: "Rechnung ablegen", done: true, doneAt: "2026-10-10T11:00", createdAt: "2026-10-09T09:00"),
        ]
        fake.current.notionSourceLinks = ["d1": "s1", "d2": "s1", "d3": "s1", "d4": "s1"]
        let model = AppModel(services: fake)
        return wrap(NotionPageView(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-settings-notion-row", size: CGSize(width: TabLayout.contentWidth, height: 260)) {
        // Die Quellenliste liest model.state (privat, im Snapshot leer) – hier die Zeile direkt.
        let fake = FakeServices()
        let model = AppModel(services: fake)
        return wrap(VStack(alignment: .leading, spacing: 8) {
          NotionSourceRow(source: NotionSource(id: "s1", name: "Tickets Projekt", category: .tickets, link: "1a2b3c"),
                          onUpdate: { _, _, _ in }, onRemove: {})
          NotionSourceRow(source: NotionSource(id: "s2", name: "Weekly KW41", category: .weekly, link: "4d5e6f"),
                          onUpdate: { _, _, _ in }, onRemove: {})
        }.tabyPage(), model)
      },
      SnapshotSpec("view-settings-notion", size: size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, addKind: .notion)
          .tabyPage(), model)
      },
      SnapshotSpec("view-settings-notion-tasks", size: size) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.settings.notionTasksDatabaseId = "1a2b3c4d5e"
        fake.current.notionTasksSync = NotionTaskSync(lastSyncAt: "2026-10-13T08:30", importedCount: 4)
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .accounts)
          .tabyPage(), model)
      },
      SnapshotSpec("view-settings-connections", size: size) {
        // Wie die Einstellungsseite: Inhalt in CappedScroll (Höhe 200), damit die Liste scrollt.
        let fake = FakeServices()
        fake.current.settings.hasApiKey = true
        fake.current.settings.llmModel = "anthropic/claude-sonnet-5"
        fake.current.settings.mailEnabled = true
        fake.current.settings.notionTasksEnabled = true
        fake.current.notionTasksConnected = true
        fake.current.notionSources = [NotionSource(id: "s1", name: "Tickets Projekt", category: .tickets, link: "1a2b3c")]
        fake.current.settings.appleRemindersSync = true
        fake.current.remindersError = "Zugriff auf Erinnerungen verweigert."
        let model = AppModel(services: fake)
        let cards = ConnectionLogic.cards(fake.current)
        return wrap(CappedScroll(maxHeight: 200) {
          ConnectionsView(cards: cards)
        }.tabyPage(), model)
      },
      SnapshotSpec("view-settings-connections-messengers", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        // Die vier Chat-Dienste: iMessage aus (Verbinden), Slack/Teams/Element bald.
        let model = AppModel(services: FakeServices())
        return wrap(ConnectionsView(cards: ConnectionLogic.messengerCards([])).tabyPage(), model)
      },
      tab("view-messages-list", .messages, sample: false) { fake, _ in
        fake.current.messengerAccounts = [MessengerAccount(id: "acc-im", service: .imessage, user: "Felix")]
        fake.current.messengerConversations = Self.messagePreview.conversations
      },
      SnapshotSpec("view-messages-thread", size: size) {
        let fake = FakeServices(sample: false)
        fake.current.messengerAccounts = [MessengerAccount(id: "acc-im", service: .imessage, user: "Felix")]
        fake.current.messengerConversations = Self.messagePreview.conversations
        let id = "acc-im|g1"
        fake.fakeMessengerMessages = [id: Self.messagePreview.thread]
        let model = AppModel(services: fake)
        return wrap(MessagesView(state: fake.current, openConversation: id,
                                 seed: fake.fakeMessengerMessages).tabyPage(), model)
      },
      SnapshotSpec("view-plan-reorder", size: CGSize(width: TabLayout.contentWidth, height: 230)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        return wrap(PlanSection(state: fake.current).tabyPage(), model)
      },
      SnapshotSpec("view-plan-priority", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let open = fake.current.tasks.filter { !$0.done }.map(\.id)
        fake.current.taskPriority = Array(open.prefix(3))
        let model = AppModel(services: fake)
        return wrap(PlanSection(state: fake.current).tabyPage(), model)
      },
    ]
  }

  /// Feste Nachrichten-Vorschau: drei Unterhaltungen, Gruppenverlauf mit eigenen und fremden Nachrichten.
  static var messagePreview: (conversations: [MessengerConversation], thread: [MessengerMessage]) {
    let id = "acc-im|g1"
    let conversations = [
      MessengerConversation(id: "acc-im|mama", accountId: "acc-im", title: "Mama", unread: 2,
                            lastText: "Kommst du heute Abend?", lastAt: "2026-10-11T08:40", isDirect: true),
      MessengerConversation(id: id, accountId: "acc-im", title: "Familie Schmidt", unread: 0,
                            lastText: "Danke euch!", lastAt: "2026-10-11T08:16"),
      MessengerConversation(id: "acc-im|max", accountId: "acc-im", title: "Max Mustermann", unread: 0,
                            lastText: "Danke für die Unterlagen", lastAt: "2026-10-03T14:05", isDirect: true),
    ]
    let thread = [
      MessengerMessage(id: "m1", conversationId: id, sender: "Anna", text: "Wer bringt den Nachtisch mit?", at: "2026-10-11T08:10"),
      MessengerMessage(id: "m2", conversationId: id, sender: "Felix", text: "Ich kümmere mich um den Kuchen.", at: "2026-10-11T08:12", mine: true),
      MessengerMessage(id: "m3", conversationId: id, sender: "Jonas", text: "Super, dann bringe ich Getränke mit.", at: "2026-10-11T08:15"),
      MessengerMessage(id: "m4", conversationId: id, sender: "Felix", text: "Danke euch!", at: "2026-10-11T08:16", mine: true),
    ]
    return (conversations, thread)
  }

  @MainActor static var daystart: SnapshotSpec {
    SnapshotSpec("view-daystart", size: size) {
      let fake = FakeServices()
      let model = AppModel(services: fake)
      // DayStartView liest model.state; ohne await nur über den leeren Zustand.
      return wrap(DayStartView(), model)
    }
  }

  @MainActor private static func tab(_ name: String, _ tab: TabyTab, sample: Bool = true,
                                     prepare: @escaping @MainActor (FakeServices, AppModel) -> Void = { _, _ in })
    -> SnapshotSpec
  {
    SnapshotSpec(name, size: size) {
      let fake = FakeServices(sample: sample)
      let model = AppModel(services: fake)
      prepare(fake, model)
      return wrap(TabContentView(tab: tab, preview: fake.current), model)
    }
  }

  @MainActor private static func onboarding(_ name: String, _ step: OnboardingStep, think: ThinkChoice? = nil,
                                            setup: SetupState = .idle) -> SnapshotSpec {
    SnapshotSpec(name, size: CGSize(width: 560, height: 520)) {
      let model = AppModel(services: FakeServices())
      return wrap(OnboardingView(onFinish: {}, start: step, think: think, setup: setup), model)
    }
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }
}

// MARK: - Tagesplan: Aufgaben wählen (Paket 13)

extension ViewChecks {
  static var pickerTasks: [TabyTask] {
    [
      TabyTask(id: "p1", title: "Steuererklärung abschicken", due: "2026-10-11", createdAt: "2026-10-10T08:00"),
      TabyTask(id: "p2", title: "Präsentation üben", createdAt: "2026-10-10T09:00"),
      TabyTask(id: "p3", title: "Angebot für Kunde X", due: "2026-10-15T09:00", createdAt: "2026-10-09T10:00"),
      TabyTask(id: "p4", title: "Einkaufsliste", createdAt: "2026-10-09T18:00", category: .privat),
    ]
  }

  static var pickerEvents: [CalendarEvent] {
    [CalendarEvent(id: "e1", sourceId: "ics-1", title: "Termin", start: "\(today)T10:00", end: "\(today)T11:00")]
  }

  /// Plan mit zwei Blöcken: die zugehörigen Aufgaben sind vorausgewählt.
  static var pickerPlan: DayPlan {
    DayPlan(date: today, blocks: [
      PlannedBlock(id: "pb1", taskId: "p1", title: "Steuererklärung abschicken", start: "\(today)T10:00", end: "\(today)T10:30"),
      PlannedBlock(id: "pb2", taskId: "p2", title: "Präsentation üben", start: "\(today)T13:45", end: "\(today)T14:15"),
    ])
  }

  static var pickerTimes: [PlanPickItem] {
    [
      PlanPickItem(taskId: "p1", title: "Steuererklärung abschicken", pinned: false, time: "09:30", minutes: 30),
      PlanPickItem(taskId: "p2", title: "Präsentation üben", pinned: true, time: "10:30", minutes: 60),
    ]
  }

  @MainActor static var planPickerSnapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-plan-picker-select", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let model = AppModel(services: FakeServices())
        return ViewSnapshots.wrapPicker(PlanPickerView(tasks: pickerTasks, plan: pickerPlan, events: pickerEvents,
                                                       onClose: {}).tabyPage(), model)
      },
      SnapshotSpec("view-plan-picker-times", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let model = AppModel(services: FakeServices())
        return ViewSnapshots.wrapPicker(PlanPickerView(tasks: pickerTasks, plan: nil, events: pickerEvents,
                                                       initialStep: .times, initialItems: pickerTimes,
                                                       onClose: {}).tabyPage(), model)
      },
      SnapshotSpec("view-plan-picker-grouped", size: CGSize(width: TabLayout.contentWidth, height: 380)) {
        let model = AppModel(services: FakeServices())
        return ViewSnapshots.wrapPicker(PlanPickerView(tasks: groupedTasks, plan: nil, events: pickerEvents,
                                                       notionSourceLinks: groupedLinks, notionSources: groupedSources,
                                                       notionTaskGroups: groupedWeeks, onClose: {}).tabyPage(), model)
      },
      SnapshotSpec("view-plan-section-pinned", size: CGSize(width: TabLayout.contentWidth, height: 230)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        fake.current.plan?.blocks[0].pinned = true
        let model = AppModel(services: fake)
        return ViewSnapshots.wrapPicker(PlanSection(state: fake.current).tabyPage(), model)
      },
    ]
  }

  // MARK: Reine Logik

  /// Gemischte Aufgaben für die Gruppierung: Tickets, zwei Wochen, Projekt-To-dos, Arbeit, Privat, ohne Kategorie.
  static var groupedTasks: [TabyTask] {
    [
      TabyTask(id: "t1", title: "Ticket B", due: "2026-10-09", createdAt: "2026-10-01T08:00"),
      TabyTask(id: "t2", title: "Ticket A", createdAt: "2026-10-02T08:00"),
      TabyTask(id: "t3", title: "Besprechung alt", createdAt: "2026-10-03T08:00"),
      TabyTask(id: "t4", title: "Besprechung neu", createdAt: "2026-10-04T08:00"),
      TabyTask(id: "t5", title: "Projekt-Schritt", due: "2026-10-12", createdAt: "2026-10-05T08:00"),
      TabyTask(id: "t6", title: "Angebot schreiben", due: "2026-10-20", createdAt: "2026-10-06T08:00", category: .arbeit),
      TabyTask(id: "t7", title: "Arbeit früh", due: "2026-10-11T08:00", createdAt: "2026-10-07T08:00", category: .arbeit),
      TabyTask(id: "t8", title: "Einkauf", createdAt: "2026-10-08T08:00", category: .privat),
      TabyTask(id: "t9", title: "Irgendwas", createdAt: "2026-10-09T08:00"),
      TabyTask(id: "t10", title: "Erledigt", done: true, createdAt: "2026-10-10T08:00", category: .arbeit),
    ]
  }
  /// Notion-Aufgaben unter der Kategorie ihres Zugangs: Tickets und Weekly → Arbeit, Projekte → Privat.
  static var groupedNotionCats: [String: String] {
    ["t1": "arbeit", "t2": "arbeit", "t3": "arbeit", "t4": "arbeit", "t5": "privat", "t10": "arbeit"]
  }
  static var groupedSources: [NotionSource] {
    [NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "1a2b3c"),
     NotionSource(id: "s2", name: "Weekly", category: .weekly, link: "4d5e6f"),
     NotionSource(id: "s3", name: "Projekte", category: .todos, link: "7a8b9c")]
  }
  static var groupedLinks: [String: String] {
    ["t1": "s1", "t2": "s1", "t3": "s2", "t4": "s2", "t5": "s3", "t10": "s1"]
  }
  static var groupedWeeks: [String: String] {
    ["t3": "2026-10-08 · Weekly", "t4": "2026-10-13 · Weekly"]
  }

  static var planPickerCases: [CheckCase] {
    [
      CheckCase("Plan-Auswahl: Abschnitte in fester Reihenfolge, Wochen absteigend, überfällig zuerst") {
        let now = "2026-10-11T09:00"
        let out = PlanPickerLogic.sections(groupedTasks, sourceLinks: groupedLinks, sources: groupedSources,
                                           taskGroups: groupedWeeks, now: now, notionCategories: groupedNotionCats)
        try expectEqual(out.map(\.title), ["Arbeit", "Privat", "Ohne Kategorie"])
        try expectEqual(out.map(\.count), [6, 2, 1])
        try expectEqual(out[0].groups.map(\.title), ["", "Notion · Tickets", "Notion · 2026-10-13 · Weekly",
                                                     "Notion · 2026-10-08 · Weekly"])
        try expectEqual(out[0].groups[0].tasks.map(\.title), ["Arbeit früh", "Angebot schreiben"])
        try expectEqual(out[0].groups[1].tasks.map(\.title), ["Ticket B", "Ticket A"])
        try expectEqual(out[1].groups.map(\.title), ["", "Notion · Projekte"], "Notion-Projekt unter Privat")
        try expectEqual(out.flatMap { $0.groups.flatMap(\.tasks) }.contains { $0.id == "t10" }, false)
      },
      CheckCase("Plan-Auswahl: leere Abschnitte fehlen; unbekannte Quelle zählt als eigene Aufgabe") {
        let now = "2026-10-11T09:00"
        let gone = TabyTask(id: "u", title: "Gone", createdAt: "x", category: .arbeit)
        let out = PlanPickerLogic.sections([gone], sourceLinks: ["u": "missing"], sources: groupedSources,
                                           taskGroups: [:], now: now, notionCategories: [:])
        try expectEqual(out.map(\.title), ["Arbeit"])
        try expectEqual(PlanPickerLogic.sections([], sourceLinks: [:], sources: [], taskGroups: [:], now: now,
                                                 notionCategories: [:]).isEmpty, true)
      },
      CheckCase("Plan-Auswahl: Vorauswahl ist der Plan, nur offene Aufgaben zählen") {
        let items = PlanPickerLogic.items(from: pickerPlan.blocks)
        try expectEqual(PlanPickerLogic.selection(openIds: ["p1", "p3", "p4"], items: items), ["p1"])
      },
      CheckCase("Plan-Auswahl: neue Aufgaben starten nach der nächsten halben Stunde und ketten sich mit ihrer Dauer") {
        let tasks = Array(pickerTasks.prefix(2))
        let out = PlanPickerLogic.build(selected: tasks, known: [], now: "2026-10-11T09:10", events: [], today: today)
        try expectEqual(out.map(\.time), ["09:30", "10:00"])
        try expectEqual(out.map(\.minutes), [30, 30])
        try expectEqual(out.map(\.pinned), [false, false])
      },
      CheckCase("Plan-Auswahl: bekannte Einträge behalten Zeit, Dauer und Fixierung") {
        let tasks = Array(pickerTasks.prefix(2))
        let known = [PlanPickItem(taskId: "p2", title: "Alt", pinned: true, time: "13:45", minutes: 60)]
        let out = PlanPickerLogic.build(selected: tasks, known: known, now: "2026-10-11T09:10", events: [], today: today)
        try expectEqual(out.map(\.time), ["09:30", "13:45"])
        try expectEqual(out[1].minutes, 60)
        try expect(out[1].pinned, "feste Zeit geht verloren")
        try expectEqual(out[1].title, "Präsentation üben")
      },
      CheckCase("Plan-Auswahl: freie Zeit überspringt überschneidende Termine") {
        let standup = [CalendarEvent(id: "s", sourceId: "ics-1", title: "Standup", start: "\(today)T09:30", end: "\(today)T10:00")]
        let out = PlanPickerLogic.build(selected: [pickerTasks[0]], known: [], now: "2026-10-11T09:10", events: standup, today: today)
        try expectEqual(out.map(\.time), ["10:00"])
      },
      CheckCase("Überschneidung: feste Uhrzeit im Termin nennt den Termin; Grenze und Automatik ohne Warnung") {
        let hit = PlanPickItem(taskId: "p2", title: "x", pinned: true, time: "10:30", minutes: 60)
        try expectEqual(PlanPickerLogic.conflictText(hit, events: pickerEvents, today: today), "Überschneidet sich mit „Termin“")
        let touching = PlanPickItem(taskId: "p2", title: "x", pinned: true, time: "11:00", minutes: 30)
        try expectEqual(PlanPickerLogic.conflictText(touching, events: pickerEvents, today: today), nil)
        let auto = PlanPickItem(taskId: "p2", title: "x", pinned: false, time: "10:30", minutes: 60)
        try expectEqual(PlanPickerLogic.conflictText(auto, events: pickerEvents, today: today), nil)
      },
      CheckCase("Überschneidung: ganztägige Termine zählen nicht; nach Mitternacht wird gewarnt") {
        let allDay = [CalendarEvent(id: "u", sourceId: "ics-1", title: "Urlaub", start: "\(today)T00:00",
                                    end: "\(today)T23:59", allDay: true)]
        let item = PlanPickItem(taskId: "p2", title: "x", pinned: true, time: "10:30", minutes: 60)
        try expectEqual(PlanPickerLogic.conflictText(item, events: allDay, today: today), nil)
        let late = PlanPickItem(taskId: "p2", title: "x", pinned: true, time: "23:30", minutes: 60)
        try expectEqual(PlanPickerLogic.conflictText(late, events: [], today: today),
                        "Endet nach Mitternacht, wird bis 23:59 gekürzt")
      },
      CheckCase("Uhrzeit: Format, Parsen und Grenzen") {
        try expectEqual(PlanPickerLogic.format(570), "09:30")
        try expectEqual(PlanPickerLogic.minutes(of: "10:30"), 630)
        try expectEqual(PlanPickerLogic.minutes(of: "24:00"), nil)
        try expectEqual(PlanPickerLogic.minutes(of: "9"), nil)
        try expectEqual(PlanPickerLogic.clock("2026-10-11T13:45"), "13:45")
        try expectEqual(PlanPickerLogic.nextHalfHour(after: "2026-10-11T09:30"), 600)
        try expectEqual(PlanPickerLogic.nextHalfHour(after: "2026-10-11T23:45"), PlanPickerLogic.dayEnd)
      },
      CheckCase("Plan-Auswahl: Dauer aus dem Block, ungültig → 30 Min; Speichern nur mit Schalter fixiert") {
        let b = PlannedBlock(id: "a", taskId: "p1", title: "x", start: "\(today)T10:00", end: "\(today)T10:45", pinned: true)
        try expectEqual(PlanPickerLogic.duration(b), 45)
        let bad = PlannedBlock(id: "a", taskId: "p1", title: "x", start: "\(today)T10:00", end: "\(today)T10:00")
        try expectEqual(PlanPickerLogic.duration(bad), 30)
        try expect(PlanPickerLogic.items(from: [b])[0].pinned, "Block nicht fixiert übernommen")
        let items = [PlanPickItem(taskId: "p1", title: "x", pinned: false, time: "09:30", minutes: 15),
                     PlanPickItem(taskId: "p2", title: "y", pinned: true, time: "10:30", minutes: 60)]
        try expectEqual(PlanPickerLogic.planItems(items), [
          PlanItem(taskId: "p1", start: nil, minutes: 15),
          PlanItem(taskId: "p2", start: "10:30", minutes: 60),
        ])
      },
    ]
  }
}

extension ViewSnapshots {
  @MainActor static func wrapPicker<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }
}

// MARK: - Einstellungen im eigenen Fenster (Seitenleiste)

extension ViewSnapshots {
  /// Eigene Größe (760 × 580), nicht die 470-pt-Insel.
  /// Jede Einstellungsseite in Notch-Breite (kompakt, hohe Vorschau), zum Prüfen auf Überlauf und abgeschnittene Schalter.
  @MainActor static var settingsPageSnapshots: [SnapshotSpec] {
    SettingsPage.allCases.map { page in
      SnapshotSpec("view-settings-page-\(page.rawValue)", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: page, privacyState: s)
        view.pageHeight = 740
        return wrap(view.tabyPage().frame(maxHeight: .infinity, alignment: .top), model)
      }
    }
  }

  @MainActor static var settingsWindowSnapshots: [SnapshotSpec] {
    [
    // Einstellungen im eigenen Fenster: Seitenleiste + Inhalt (wie SettingsWindowView).
    SnapshotSpec("view-settings-window", size: CGSize(width: 760, height: 580)) {
      let fake = FakeServices()
      fake.current.settings.hasApiKey = true
      let model = AppModel(services: fake)
      let s = fake.current
      return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, layout: .window), model)
    },
    // Modell: Anbieter-Voreinstellung mit gesetztem Schlüssel und ohne Schlüssel (Schlüssel-Link, Hinweis).
    SnapshotSpec("view-settings-model-openai", size: CGSize(width: 760, height: 580)) {
      let fake = FakeServices()
      LlmProviders.apply(LlmProviders.openAI, to: &fake.current.settings)
      fake.current.settings.hasApiKey = true
      let model = AppModel(services: fake)
      let s = fake.current
      return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, layout: .window), model)
    },
    SnapshotSpec("view-settings-model-nokey", size: CGSize(width: 760, height: 580)) {
      let fake = FakeServices()
      LlmProviders.apply(LlmProviders.groq, to: &fake.current.settings)
      fake.current.settings.hasApiKey = false
      let model = AppModel(services: fake)
      let s = fake.current
      return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, layout: .window), model)
    },
    SnapshotSpec("view-settings-window-shortcuts", size: CGSize(width: 760, height: 580)) {
      // Ein Tastenkürzel, das macOS nicht belegen konnte: roter Hinweis daneben.
      let fake = FakeServices()
      fake.current.settings.globalShortcut = "Control+Option+Space"
      let model = AppModel(services: fake)
      model.shortcutConflicts = ["Control+Option+Space"]
      let s = fake.current
      return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .shortcuts,
                               layout: .window), model)
    },
    ]
  }
}
