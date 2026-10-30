// Prüfungen und Snapshots für „Notizen mitnehmen“ und „Zusammenfassung erstellen“:
// Auswahl-Logik, Anlegen und Zusammenfassen über ViewActions gegen FakeServices,
// und die Karte in den drei Zuständen (Auswahl offen, mit Termin-Notiz, nachher).
import SwiftUI
import TabyCore

enum MeetingPrepChecks {
  static let meeting = MeetingBrief(id: "apple|e-9|2026-10-11T15:00", phase: .upcoming, title: "Jour fixe",
                                    start: "2026-10-11T15:00", end: "2026-10-11T16:00",
                                    notes: [MeetingRef(id: "n-1", title: "Ideen für Lumi")],
                                    tasks: [MeetingRef(id: "t-3", title: "Präsentation üben")])

  static func library() -> (notes: [Note], tasks: [TabyTask]) {
    let notes = [
      Note(id: "n-1", title: "Ideen für Lumi", content: "", createdAt: "2026-10-01T09:00", updatedAt: "2026-10-01T09:00"),
      Note(id: "n-2", title: "Einkauf", content: "", createdAt: "2026-10-01T09:00", updatedAt: "2026-10-01T09:00",
           tags: ["privat"]),
    ]
    let tasks = [
      TabyTask(id: "t-3", title: "Präsentation üben", createdAt: "2026-10-01T09:00", tags: ["arbeit"]),
      TabyTask(id: "t-4", title: "Alte Aufgabe", done: true, createdAt: "2026-10-01T09:00"),
      TabyTask(id: "t-5", title: "Angebot schicken", createdAt: "2026-10-01T09:00"),
    ]
    return (notes, tasks)
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Meeting-Einstieg: laufender oder nächster Termin, ganztägige und vergangene fallen weg") {
        func ev(_ id: String, _ s: String, _ e: String?, allDay: Bool = false) -> CalendarEvent {
          CalendarEvent(id: id, sourceId: "x", title: id, start: s, end: e, allDay: allDay)
        }
        let events = [ev("früh", "2026-10-11T08:00", "2026-10-11T09:00"), ev("tag", "2026-10-11", nil, allDay: true),
                      ev("später", "2026-10-11T15:00", "2026-10-11T16:00"), ev("jetzt", "2026-10-11T10:00", "2026-10-11T11:00")]
        try expectEqual(MeetingEntryLogic.target(events: events, now: "2026-10-11T10:30")?.id, "jetzt")
        try expectEqual(MeetingEntryLogic.target(events: events, now: "2026-10-11T11:30")?.id, "später")
        try expect(MeetingEntryLogic.target(events: events, now: "2026-10-11T17:00") == nil, "nach dem letzten Termin")
        let adhoc = MeetingEntryLogic.adhocBrief(now: "2026-10-11T10:30")
        try expectEqual(adhoc.id, "adhoc|2026-10-11T10:30")
        try expectEqual(adhoc.title, "Gespräch 10:30")
      },
      CheckCase("Notizen mitnehmen: Vorschläge des Termins sind vorgewählt") {
        let sel = MeetingPrepLogic.preselected(meeting)
        try expectEqual(sel.noteIds, Set(["n-1"]))
        try expectEqual(sel.taskIds, Set(["t-3"]))
      },
      CheckCase("Notizen mitnehmen: Umschalten wählt ab und wieder zu, Auswahl in Listenreihenfolge") {
        let lib = library()
        let rows = MeetingPrepLogic.rows(meeting: meeting, notes: lib.notes, tasks: lib.tasks, query: "", more: false)
        try expectEqual(rows.map(\.ref), ["n-1", "t-3"], "Nur die Vorschläge ohne „Weitere…“")
        let off = MeetingPrepLogic.toggled(MeetingPrepLogic.preselected(meeting), rows[0])
        try expect(!MeetingPrepLogic.isOn(off, rows[0]), "Abgewählt")
        let on = MeetingPrepLogic.toggled(off, rows[0])
        try expect(MeetingPrepLogic.isOn(on, rows[0]), "Wieder gewählt")
        let chosen = MeetingPrepLogic.chosen(rows, on)
        try expectEqual(chosen.noteIds, ["n-1"])
        try expectEqual(chosen.taskIds, ["t-3"])
      },
      CheckCase("Notizen mitnehmen: „Weitere…“ zeigt alle Notizen und nur offene Aufgaben, ohne Doppelte") {
        let lib = library()
        let rows = MeetingPrepLogic.rows(meeting: meeting, notes: lib.notes, tasks: lib.tasks, query: "", more: true)
        try expectEqual(rows.map(\.ref), ["n-1", "t-3", "n-2", "t-5"])
        try expect(!rows.contains { $0.ref == "t-4" }, "Erledigte Aufgabe fehlt")
      },
      CheckCase("Notizen mitnehmen: Suche über Titel und Kennzeichen, ohne Groß/Klein und ohne „#“") {
        let lib = library()
        let byTag = MeetingPrepLogic.rows(meeting: meeting, notes: lib.notes, tasks: lib.tasks, query: "#PRIVAT", more: true)
        try expectEqual(byTag.map(\.ref), ["n-2"])
        let byTitle = MeetingPrepLogic.rows(meeting: meeting, notes: lib.notes, tasks: lib.tasks, query: "  angebot ", more: true)
        try expectEqual(byTitle.map(\.ref), ["t-5"])
        let none = MeetingPrepLogic.rows(meeting: meeting, notes: lib.notes, tasks: lib.tasks, query: "gibts nicht", more: true)
        try expect(none.isEmpty, "Ohne Treffer leer")
        try expectEqual(MeetingPrepLogic.summaryText(taskCount: 2), "Zusammenfassung + 2 Aufgaben angelegt")
        try expectEqual(MeetingPrepLogic.summaryText(taskCount: 1), "Zusammenfassung + 1 Aufgabe angelegt")
      },
      CheckCase("Notizen mitnehmen: Anlegen über ViewActions legt Agenda aus der Auswahl an") {
        let lib = library()
        let fake = FakeServices(sample: false)
        fake.current.notes = lib.notes
        fake.current.tasks = lib.tasks
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        let err = await ViewActions.prepareMeeting(model, meeting.id, noteIds: ["n-2"], taskIds: ["t-5"])
        try expect(err == nil, "Anlegen gelingt: \(err ?? "")")
        let prepId = fake.current.meeting?.prepNoteId
        try expect(prepId != nil, "Termin verweist auf die Notiz")
        let note = fake.current.notes.first { $0.id == prepId }
        try expect(note?.content.contains("## Agenda") == true, "Agenda-Überschrift")
        try expect(note?.content.contains("## Mitschrift") == true, "Mitschrift-Überschrift")
        try expect(note?.content.contains("- Einkauf") == true && note?.content.contains("- Angebot schicken") == true,
                   "Gewählte Titel in der Agenda")
        try expect(note?.content.contains("Ideen für Lumi") == false, "Nicht Gewähltes fehlt")
      },
      CheckCase("Zusammenfassen: ohne Termin-Notiz meldet ViewActions einen Fehler, mit Notiz legt es eine Aufgabe an") {
        let lib = library()
        let fake = FakeServices(sample: false)
        fake.current.notes = lib.notes
        fake.current.tasks = lib.tasks
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        let early = await ViewActions.summarizeMeeting(model, meeting.id)
        try expect(early.error != nil, "Ohne Termin-Notiz kein Zusammenfassen")
        try expectEqual(early.tasks, 0)
        await ViewActions.prepareMeeting(model, meeting.id, noteIds: [], taskIds: [])
        let done = await ViewActions.summarizeMeeting(model, meeting.id)
        try expect(done.error == nil, "Zusammenfassung gelingt: \(done.error ?? "")")
        try expectEqual(done.tasks, 1)
        let prepId = fake.current.meeting?.prepNoteId
        let note = fake.current.notes.first { $0.id == prepId }
        try expect(note?.content.contains("## Zusammenfassung") == true, "Zusammenfassung in der Termin-Notiz")
      },
      CheckCase("Gliederung: Abschnitte und Unterabschnitte, Kästchen und Überschriften fallen richtig") {
        let content = """
        # Jour fixe – 11.10.2026

        ## Agenda
        ### Worum geht es
        - Preis
        ### Fragen
        - Frist?

        ## Offene Punkte
        - [ ] Angebot schicken – fällig 14.10.2026
        - [x] Alt

        ## Mitschrift
        -
        """
        let sections = MeetingOutline.parse(content)
        try expectEqual(sections.map(\.heading), ["Agenda", "Offene Punkte"], "Leere Mitschrift fällt weg")
        try expectEqual(sections[0].subs.map(\.heading), ["Worum geht es", "Fragen"])
        try expectEqual(sections[0].subs[1].items, ["Frist?"])
        try expectEqual(sections[1].subs[0].items, ["Angebot schicken – fällig 14.10.2026", "Alt"])
        let shown = MeetingOutline.preparation(sections)
        try expectEqual(shown.map(\.heading), ["Worum geht es", "Offene Aufgaben"])
        try expectEqual(MeetingOutline.parse("- a\n- b").first?.subs.first?.items, ["a", "b"], "Ohne Überschrift ein Abschnitt ohne Namen")
      },
      CheckCase("Gliederung der Zusammenfassung: Abschnitt „Zusammenfassung“ mit Unterabschnitten, sonst nichts") {
        let content = "# T\n\n## Mitschrift\n- x\n\n## Zusammenfassung\n### Ergebnis\n- Preis geklärt\n### Aufgaben\n- Rechnung senden\n"
        let summary = MeetingOutline.summary(in: content)
        try expectEqual(summary?.subs.map(\.heading), ["Ergebnis", "Aufgaben"])
        try expect(MeetingOutline.summary(in: "## Mitschrift\n- x\n") == nil, "Ohne Zusammenfassung nil")
      },
      CheckCase("Noch im Meeting: läuft bis „beendet“ oder bis die gewählte Zeit abläuft, nach Uhr") {
        let suite = UserDefaults(suiteName: "taby.check.meeting-live")!
        suite.removePersistentDomain(forName: "taby.check.meeting-live")
        defer { suite.removePersistentDomain(forName: "taby.check.meeting-live") }
        let id = "apple|e-9|2026-10-11T15:00"
        try expect(!MeetingLive.isRunning(id, now: "2026-10-11T16:10", defaults: suite), "Ohne Eintrag nicht laufend")
        MeetingLive.start(id, now: "2026-10-11T16:10", minutes: nil, defaults: suite)
        try expect(MeetingLive.isRunning(id, now: "2026-10-11T23:00", defaults: suite), "Offen: läuft, bis beendet")
        try expectEqual(MeetingLive.line(id, defaults: suite), "Läuft, bis du es beendest")
        MeetingLive.start(id, now: "2026-10-11T16:10", minutes: 30, defaults: suite)
        try expectEqual(MeetingLive.line(id, defaults: suite), "Läuft bis 16:40")
        try expect(MeetingLive.isRunning(id, now: "2026-10-11T16:39", defaults: suite), "Vor der Zeit läuft es")
        try expect(!MeetingLive.isRunning(id, now: "2026-10-11T16:40", defaults: suite), "Zur Zeit ist es vorbei")
        MeetingLive.clear(id, defaults: suite)
        try expect(!MeetingLive.isRunning(id, now: "2026-10-11T16:10", defaults: suite), "Beendet")
        try expectEqual(MeetingLive.durations, [15, 30, 60])
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-today-task-rows", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        let fake = FakeServices(sample: true)
        let model = AppModel(services: fake, preloaded: fake.current)
        let t = fake.current.tasks.filter { !$0.done }
        let now = "2026-10-11T09:41"
        return wrap(VStack(alignment: .leading, spacing: 4) {
          if let first = t.first {
            TaskRow(task: first, now: now, completing: false, onToggle: {}, startExpanded: true, plannedTime: "11:00")
          }
          ForEach(Array(t.dropFirst().prefix(2))) { task in
            TaskRow(task: task, now: now, completing: false, onToggle: {})
          }
        }.padding(8), model)
      },
      SnapshotSpec("view-meeting-entry", size: CGSize(width: TabLayout.contentWidth, height: 190)) {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake, preloaded: fake.current)
        let events = [CalendarEvent(id: "e-3", sourceId: "apple", title: "Design-Review",
                                    start: "2026-10-11T15:00", end: "2026-10-11T16:00")]
        return wrap(MeetingEntrySection(events: events, now: "2026-10-11T09:41").padding(8), model)
      },
      SnapshotSpec("view-meeting-picker", size: CGSize(width: TabLayout.contentWidth, height: 330)) {
        let lib = library()
        let fake = FakeServices(sample: false)
        fake.current.notes = lib.notes
        fake.current.tasks = lib.tasks
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: meeting, saved: nil, onSaved: { _ in }, onDone: {},
                                    prepOpen: true, prepMore: true), model)
      },
      SnapshotSpec("view-meeting-prepared", size: CGSize(width: TabLayout.contentWidth, height: 150)) {
        var prepared = meeting
        prepared.prepNoteId = "n-9"
        let fake = FakeServices(sample: false)
        fake.current.meeting = prepared
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: prepared, saved: nil, onSaved: { _ in }, onDone: {}), model)
      },
      SnapshotSpec("view-meeting-summary", size: CGSize(width: TabLayout.contentWidth, height: 190)) {
        var ended = meeting
        ended.phase = .ended
        ended.prepNoteId = "n-9"
        let fake = FakeServices(sample: false)
        fake.current.meeting = ended
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: ended, saved: nil, onSaved: { _ in }, onDone: {}), model)
      },
      SnapshotSpec("view-meeting-outline", size: CGSize(width: TabLayout.contentWidth, height: 340)) {
        var prepared = meeting
        prepared.prepNoteId = "n-9"
        let fake = FakeServices(sample: false)
        fake.current.meeting = prepared
        fake.current.notes = [Note(id: "n-9", title: "Jour fixe – Agenda", content: """
        # Jour fixe – 11.10.2026

        ## Agenda
        ### Worum geht es
        - Stand des Angebots
        ### Gesprächspunkte
        - Preis und Rabatt
        - Liefertermin
        ### Fragen
        - Ist die Frist fix?

        ## Offene Punkte
        - [ ] Präsentation üben – fällig 12.10.2026

        ## Mitschrift
        - Preis ist offen
        """, createdAt: "2026-10-11T09:00", updatedAt: "2026-10-11T09:00")]
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: prepared, saved: nil, onSaved: { _ in }, onDone: {}), model)
      },
      SnapshotSpec("view-meeting-summarized", size: CGSize(width: TabLayout.contentWidth, height: 300)) {
        var ended = meeting
        ended.phase = .ended
        ended.prepNoteId = "n-9"
        let fake = FakeServices(sample: false)
        fake.current.meeting = ended
        fake.current.notes = [Note(id: "n-9", title: "Jour fixe – Agenda", content: """
        # Jour fixe – 11.10.2026

        ## Zusammenfassung
        ### Ergebnis
        - Preis geklärt, Rabatt bleibt bei 5 Prozent
        ### Entscheidungen
        - Liefertermin bleibt
        ### Aufgaben
        - Rechnung an Frau Kern senden – bis 14.10.2026
        ### Offene Fragen
        - Ist die Frist fix?
        """, createdAt: "2026-10-11T09:00", updatedAt: "2026-10-11T09:00")]
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: ended, saved: "Zusammenfassung + 1 Aufgabe angelegt", onSaved: { _ in },
                                    onDone: {}), model)
      },
      SnapshotSpec("view-meeting-running", size: CGSize(width: TabLayout.contentWidth, height: 200)) {
        var ended = meeting
        ended.phase = .ended
        let suite = UserDefaults(suiteName: "taby.snapshot.meeting-live")!
        MeetingLive.start(ended.id, now: ViewChecks.now, minutes: 30, defaults: suite)
        let fake = FakeServices(sample: false)
        fake.current.meeting = ended
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(MeetingCardView(meeting: ended, saved: nil, onSaved: { _ in }, onDone: {}, defaults: suite), model)
      },
    ]
  }
}
