// Prüfungen und Snapshots für Paket 4 (Tagesplan, Meeting, Dateien, Diktat,
// Wochenplanung, Fokus-Umgebung). Logik ohne Fenster, Ansichten als PNG.
import SwiftUI
import TabyCore

enum PackageFourChecks {
  static let now = "2026-10-11T10:15"

  @MainActor static var cases: [CheckCase] {
    logicCases + storeCases + actionCases
  }

  // MARK: - Reine Logik

  @MainActor static var logicCases: [CheckCase] {
    [
      CheckCase("Dauer: Stunden und Minuten") {
        try expectEqual(DurationText.hm(340), "5 h 40 min")
        try expectEqual(DurationText.hm(45), "45 min")
        try expectEqual(DurationText.hm(120), "2 h")
        try expectEqual(DurationText.hm(0), "0 min")
        try expectEqual(DurationText.hm(-5), "0 min")
      },
      CheckCase("Plan: vergangen, laufend, kommend") {
        let past = PlannedBlock(id: "a", taskId: "t", title: "A", start: "2026-10-11T09:00", end: "2026-10-11T09:30")
        let current = PlannedBlock(id: "b", taskId: "t", title: "B", start: "2026-10-11T10:00", end: "2026-10-11T10:30")
        let later = PlannedBlock(id: "c", taskId: "t", title: "C", start: "2026-10-11T11:00", end: "2026-10-11T11:30")
        try expectEqual(PlanLogic.status(past, now: now), .past)
        try expectEqual(PlanLogic.status(current, now: now), .current)
        try expectEqual(PlanLogic.status(later, now: now), .upcoming)
        // Blockende genau jetzt zählt als vorbei.
        try expectEqual(PlanLogic.status(current, now: "2026-10-11T10:30"), .past)
      },
      CheckCase("Plan: Zeitspanne und Hinweis auf nicht eingeplante Aufgaben") {
        let b = PlannedBlock(id: "b", taskId: "t", title: "B", start: "2026-10-11T10:00", end: "2026-10-11T10:30")
        try expectEqual(PlanLogic.timeRange(b), "10:00–10:30")
        try expectEqual(PlanLogic.unplannedHint(0), nil)
        try expectEqual(PlanLogic.unplannedHint(1), "1 passt heute nicht mehr rein")
        try expectEqual(PlanLogic.unplannedHint(2), "2 passen heute nicht mehr rein")
      },
      CheckCase("Meeting: Countdown in Minuten und Stunden") {
        try expectEqual(MeetingLogic.minutesUntil("2026-10-11T15:00", now: "2026-10-11T14:52"), 8)
        try expectEqual(MeetingLogic.relative(minutes: 8), "in 8 Min")
        try expectEqual(MeetingLogic.relative(minutes: 0), "jetzt")
        try expectEqual(MeetingLogic.relative(minutes: 65), "in 1 Std. 5 Min")
        try expectEqual(MeetingLogic.relative(minutes: 120), "in 2 Std.")
      },
      CheckCase("Meeting: Zeile „in 8 Min · 15:00–16:00“ und Speicher-Rückmeldung") {
        let m = MeetingBrief(id: "x", phase: .upcoming, title: "Review", start: "2026-10-11T15:00",
                             end: "2026-10-11T16:00")
        try expectEqual(MeetingLogic.countdownLine(m, now: "2026-10-11T14:52"), "in 8 Min · 15:00–16:00")
        let open = MeetingBrief(id: "y", phase: .upcoming, title: "Kurz", start: "2026-10-11T15:00")
        try expectEqual(MeetingLogic.span(open), "15:00")
        try expectEqual(MeetingLogic.savedText(taskCount: 2), "Notiz + 2 Aufgaben gespeichert")
        try expectEqual(MeetingLogic.savedText(taskCount: 1), "Notiz + 1 Aufgabe gespeichert")
        try expectEqual(MeetingLogic.savedText(taskCount: 0), "Notiz gespeichert")
      },
      CheckCase("Insel: Priorität Tagesstart > Feierabend > Wochenplanung > Meeting > Reiter") {
        try expectEqual(IslandCardRules.kind(dayStart: true, dayEnd: true, weeklyReview: true, meeting: true), .dayStart)
        try expectEqual(IslandCardRules.kind(dayStart: false, dayEnd: true, weeklyReview: true, meeting: true), .dayEnd)
        try expectEqual(IslandCardRules.kind(dayStart: false, dayEnd: false, weeklyReview: true, meeting: true),
                        .weeklyReview)
        try expectEqual(IslandCardRules.kind(dayStart: false, dayEnd: false, weeklyReview: false, meeting: true),
                        .meeting)
        try expectEqual(IslandCardRules.kind(dayStart: false, dayEnd: false, weeklyReview: false, meeting: false),
                        .tab)
        try expectEqual(IslandCardKind.meeting.title(tab: .today), "Meeting")
        try expectEqual(IslandCardKind.weeklyReview.title(tab: .today), "Wochenplanung")
        try expectEqual(IslandCardKind.tab.title(tab: .notes), "Notizen")
      },
      CheckCase("Insel: offen halten, solange Feierabend, Wochenplanung oder Meeting offen ist") {
        try expectEqual(IslandCardRules.promptHeld(dayEnd: false, weeklyReview: false, meeting: false), false)
        try expectEqual(IslandCardRules.promptHeld(dayEnd: true, weeklyReview: false, meeting: false), true)
        try expectEqual(IslandCardRules.promptHeld(dayEnd: false, weeklyReview: true, meeting: false), true)
        try expectEqual(IslandCardRules.promptHeld(dayEnd: false, weeklyReview: false, meeting: true), true)
        var s = AppState()
        s.weeklyReviewPrompt = true
        try expectEqual(IslandCardRules.weeklyShown(s), false, "ohne Rückblick keine Karte")
        s.weeklyReview = WeeklyReview(weekStart: "2026-10-05")
        try expectEqual(IslandCardRules.weeklyShown(s), true)
      },
      CheckCase("Wochenplanung: bis zu drei Ziele, getrimmt, leere weg") {
        try expectEqual(WeeklyLogic.goals(["  Steuer ", "", "Sport", "  ", "Lesen", "Mehr"]),
                        ["Steuer", "Sport", "Lesen"])
        try expectEqual(WeeklyLogic.goals(["", "", ""]), [])
        try expectEqual(WeeklyLogic.habitFraction(HabitWeek(name: "Lesen", days: 6, streak: 6)), "6/7")
      },
      CheckCase("Datei-Drop: höchstens drei Dateien") {
        try expectEqual(DropLogic.limited(["a", "", "b", "c", "d"]), ["a", "b", "c"])
        try expectEqual(DropLogic.limited([]), [])
      },
      CheckCase("Einstellungen: neue Felder landen nur bei Änderung im Patch") {
        var changed = TabySettings.defaults
        changed.planBlockMinutes = 45
        changed.focusHideApps = ["com.apple.mail"]
        changed.weeklyReviewDay = 5
        let p = SettingsLogic.patch(from: TabySettings.defaults, to: changed)
        try expectEqual(p.planBlockMinutes, 45)
        try expectEqual(p.focusHideApps, ["com.apple.mail"])
        try expectEqual(p.weeklyReviewDay, 5)
        try expectEqual(p.meetingCompanion, nil)
        try expectEqual(p.focusShortcutOn, nil)
        try expect(!SettingsLogic.isEmpty(p))
      },
      CheckCase("Einstellungen: Wochentage, Uhrzeiten, App-Auswahl") {
        try expectEqual(SettingsLogic.weekdays.count, 7)
        try expectEqual(SettingsLogic.weekdays.first?.label, "Mo")
        try expectEqual(SettingsLogic.weekdays.last?.day, 7)
        try expectEqual(SettingsLogic.weeklyTimes(current: "18:00"), SettingsLogic.dayEndTimes)
        try expectEqual(SettingsLogic.weeklyTimes(current: "09:00").first, "09:00")
        let apps = [AppInfo(id: "com.apple.mail", name: "Mail"), AppInfo(id: "com.apple.MobileSMS", name: "Nachrichten"),
                    AppInfo(id: "com.tinyspeck.slackmacgap", name: "Slack")]
        let ordered = SettingsLogic.filterApps(apps, search: "", selected: ["com.tinyspeck.slackmacgap"])
        try expectEqual(ordered.first?.name, "Slack", "ausgewählte zuerst")
        try expectEqual(SettingsLogic.filterApps(apps, search: "MA", selected: []).map(\.name), ["Mail"])
      },
    ]
  }

  // MARK: - Insel und Modell (wie in Shell-Prüfungen, ohne Warten)

  @MainActor static var storeCases: [CheckCase] {
    [
      CheckCase("Insel: Meeting öffnet, hält offen und schließt erst auf Knopfdruck") {
        let (store, _, fake, clock) = ShellChecks.makeStore()
        store.mouseLeft()
        let m = fake.sampleMeeting(.upcoming)
        store.previewState = fake.current
        store.previewMeeting(m)
        try expectEqual(store.mode, .open)
        try expectEqual(store.meetingCard, m)
        clock.advance(10)
        store.tick()
        try expectEqual(store.mode, .open, "bleibt offen, solange die Karte offen ist")
        store.closeMeetingCard()
        clock.advance(1)
        store.tick()
        try expectEqual(store.mode, .closed)
      },
      CheckCase("Insel: gespeicherte Meeting-Notizen bleiben bis „Fertig“") {
        let (store, _, fake, _) = ShellChecks.makeStore()
        store.previewState = fake.current
        store.previewMeeting(fake.sampleMeeting(.ended))
        store.showMeetingSaved("Notiz + 2 Aufgaben gespeichert")
        try expectEqual(store.meetingSaved, "Notiz + 2 Aufgaben gespeichert")
        try expect(store.meetingCard != nil)
        store.closeMeetingCard()
        try expectEqual(store.meetingSaved, nil)
        try expectEqual(store.meetingCard, nil)
      },
      CheckCase("Insel: Datei über der Insel öffnet den Chat, Overlay an und aus") {
        let (store, _, _, _) = ShellChecks.makeStore()
        store.setDropTargeted(true)
        try expect(store.dropTargeted)
        try expectEqual(store.mode, .open)
        try expectEqual(store.tab, .chat)
        store.setDropTargeted(false)
        try expect(!store.dropTargeted)
      },
      CheckCase("Insel: Schnellerfassung mit Entwurf (Diktat-Text)") {
        let (store, model, _, _) = ShellChecks.makeStore()
        store.openCapture(prefill: "Milch kaufen")
        try expectEqual(store.mode, .capture)
        try expectEqual(model.captureDraft, "Milch kaufen")
      },
    ]
  }

  // MARK: - Modell-Aktionen

  @MainActor static var actionCases: [CheckCase] {
    [
      CheckCase("Diktat: Start, Stopp ohne Senden füllt den Entwurf") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        await model.startListening()
        try expect(model.listening)
        try expectEqual(model.transcript, fake.fakeTranscript)
        await model.stopListening(submit: false)
        try expect(!model.listening)
        try expectEqual(model.captureDraft, fake.fakeTranscript)
      },
      CheckCase("Gespräch: Gesprochenes geht nach der Pause in den Chat, „Stopp“ beendet") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let chat = ChatController()
        let voice = VoiceChat()
        let before = fake.current.messages.count
        voice.start(chat, model)
        for _ in 0..<40 where fake.current.messages.count == before { try? await Task.sleep(for: .milliseconds(100)) }
        voice.stop(model)
        try expect(fake.current.messages.count > before, "gesendet")
        try expectEqual(fake.current.messages.dropFirst(before).first?.content, fake.fakeTranscript)
        try expect(!voice.active)
        let full = (0..<80).map { ChatMessage(role: .assistant, content: "alt \($0)") }
          + [ChatMessage(role: .user, content: "Wie spät?"), ChatMessage(role: .assistant, content: "Zehn Uhr.")]
        try expectEqual(VoiceChat.reply(after: "Wie spät?", in: Array(full.suffix(80))), "Zehn Uhr.", "auch bei vollem Verlauf")
        try expectEqual(VoiceChat.reply(after: "Andere Frage", in: full), nil)
        try expect(VoiceChat.isEnd("Stopp.") && VoiceChat.isEnd(" tschüss ") && !VoiceChat.isEnd("stopp den timer"))
      },
      CheckCase("Datei ablegen: höchstens drei, Chat fragt; Bitte geht mit allen ans Modell") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let before = fake.current.messages.count
        await model.ingestFiles(["/Users/test/a.pdf", "/Users/test/b.txt", "/Users/test/c.png", "/Users/test/d.md"])
        try expectEqual(model.droppedFiles.count, 3)
        try expectEqual(fake.current.messages.count, before, "noch nichts gesendet")
        let chat = ChatController()
        chat.ask("Mach daraus eine Mail", model)
        await chat.wait()
        try expectEqual(fake.current.messages.count - before, 3)
        try expect(model.droppedFiles.isEmpty)
      },
      CheckCase("Datei als Notiz zu einem Termin: ohne Modell, Titel mit Termin") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-drop-\(UUID().uuidString).txt")
        try "Agenda: Budget".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        await model.ingestFiles([url.path])
        await model.saveDroppedFilesAsNotes(titlePrefix: "Jour fixe")
        try expectEqual(fake.current.notes.last?.title, "Jour fixe – " + url.lastPathComponent)
        try expect(model.droppedFiles.isEmpty)
      },
      CheckCase("Meeting-Stichpunkte: Zeilen mit „-“ werden Aufgaben") {
        let fake = FakeServices(sample: false)
        fake.current.meeting = fake.sampleMeeting(.ended)
        let result = await fake.submitMeetingNotes(fake.sampleMeeting(.ended).id,
                                                   text: "Besprochen\n- Angebot schicken\n- Folie 3 anpassen")
        guard case .ok(let res) = result else {
          try expect(false, "Stichpunkte nicht gespeichert")
          return
        }
        try expectEqual(res.tasks.count, 2)
        try expectEqual(MeetingLogic.savedText(taskCount: res.tasks.count), "Notiz + 2 Aufgaben gespeichert")
      },
      CheckCase("Plan: planen und löschen aktualisiert den Zustand") {
        let fake = FakeServices(sample: true)
        let open = fake.current.tasks.filter { !$0.done }.count
        let result = await fake.planDay()
        try expectEqual(result.value?.blocks.count, open)
        try expect(fake.current.plan != nil)
        await fake.clearPlan()
        try expect(fake.current.plan == nil)
      },
    ]
  }
}

// MARK: - Snapshots

extension PackageFourChecks {
  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-today-plan", size: ViewSnapshots.size) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .today, preview: fake.current), model, now: now)
      },
      SnapshotSpec("view-today-plan-empty", size: ViewSnapshots.size) {
        let fake = FakeServices(sample: true)
        fake.current.plan = nil
        let model = AppModel(services: fake)
        return wrap(TabContentView(tab: .today, preview: fake.current), model, now: now)
      },
      SnapshotSpec("view-quickcapture-listening", size: CGSize(width: TabLayout.contentWidth, height: 120)) {
        let model = AppModel(services: FakeServices(sample: false))
        model.listening = true
        model.transcript = "Erinner mich morgen an den Zahnarzt"
        return wrap(QuickCaptureView(onDone: {}), model)
      },
      SnapshotSpec("view-settings-planning", size: ViewSnapshots.size) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .rhythm)
          .tabyPage(), model)
      },
      SnapshotSpec("view-settings-focus", size: CGSize(width: TabLayout.contentWidth, height: 780)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .rhythm,
                                shortcuts: ["Nicht stören an", "Nicht stören aus"],
                                apps: [AppInfo(id: "com.apple.mail", name: "Mail"),
                                       AppInfo(id: "com.tinyspeck.slackmacgap", name: "Slack")])
        view.pageHeight = 700
        return wrap(view.tabyPage(), model)
      },
      SnapshotSpec("view-settings-shortcuts", size: CGSize(width: TabLayout.contentWidth, height: 560)) {
        let fake = FakeServices()
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .general)
        view.pageHeight = 520
        return wrap(view.tabyPage(), model)
      },
      SnapshotSpec("view-plan-empty", size: CGSize(width: TabLayout.contentWidth, height: 120)) {
        let fake = FakeServices(sample: true)
        fake.current.plan = nil
        let model = AppModel(services: fake)
        return wrap(PlanSection(state: fake.current).tabyPage(), model, now: now)
      },
      SnapshotSpec("view-plan-section", size: CGSize(width: TabLayout.contentWidth, height: 230)) {
        let fake = FakeServices(sample: true)
        fake.fillPackageFour()
        let model = AppModel(services: fake)
        return wrap(PlanSection(state: fake.current).tabyPage(), model, now: now)
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel, now: String = ViewChecks.now) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(now).environment(\.tabySnapshot, true))
  }
}
