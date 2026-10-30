// Paket 4 gegen den echten Kern (CoreServices mit SQLite im Speicher,
// lokalem Kalender und steuerbarer Uhr): Plan, Neu-Planen, Meeting-Karten,
// Stichpunkte, Wochenplanung, Datei-Fehler. Ohne Modell.
import Foundation

enum PackageFourIntegrationChecks {
  @MainActor static var suite: CheckSuite {
    CheckSuite("Integration Paket 4", BreakMemoryChecks.integration + MeetingPrepChecks.integration + ActionItemChecks.integration + MeetingListenChecks.integration + [
      CheckCase("Termine von heute: 60 s Zwischenspeicher, nur für denselben Tag, Leeren wirkt sofort") {
        let t0 = try expectNotNil(LocalTime.parse("2026-10-17T08:00"))
        var c = TodayEventsCache()
        try expect(c.value(day: "2026-10-17", now: t0) == nil, "leer am Anfang")
        c.store([], day: "2026-10-17", now: t0)
        try expect(c.value(day: "2026-10-17", now: t0.addingTimeInterval(59)) != nil, "frisch innerhalb 60 s")
        try expect(c.value(day: "2026-10-17", now: t0.addingTimeInterval(60)) == nil, "nach 60 s neu holen")
        try expect(c.value(day: "2026-10-18", now: t0.addingTimeInterval(1)) == nil, "anderer Tag")
        c.clear()
        try expect(c.value(day: "2026-10-17", now: t0) == nil, "EKEventStoreChanged leert den Zwischenspeicher")
      },
      CheckCase("Plan: Aufgaben landen in freien Lücken, nicht im Termin; Zustand zeigt den Plan") {
        let rig = try IntegrationRig()  // Montag 08:00
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Standup", start: "2026-10-12T08:00",
                                                               end: "2026-10-12T09:30")))
        _ = await svc.addTask(title: "Steuer (45 min)", notes: nil, due: "2026-10-12")
        _ = await svc.addTask(title: "Mails", notes: nil, due: nil)
        guard case .ok(let plan) = await svc.planDay() else { throw CheckFailure(message: "kein Plan", location: "") }
        try expectEqual(plan.blocks.count, 2)
        for b in plan.blocks { try expect(b.start >= "2026-10-12T09:30", "Block \(b.start) liegt im Termin") }
        try expectEqual(plan.blocks.first?.title, "Steuer (45 min)")
        let state = await svc.state()
        try expectEqual(state.plan?.blocks.count, 2)
        await svc.clearPlan()
        let cleared = await svc.state()
        try expect(cleared.plan == nil, "Plan gelöscht")
      },

      CheckCase("Plan: neuer Termin über einem Block → Block wird verschoben und gemeldet") {
        let rig = try IntegrationRig(start: "2026-10-12T07:00")  // Block um 08:00 hat noch nicht begonnen
        let svc = rig.svc
        _ = await svc.addTask(title: "Präsentation", notes: nil, due: "2026-10-12")
        guard case .ok(let plan) = await svc.planDay(), let block = plan.blocks.first else {
          throw CheckFailure(message: "kein Plan", location: "")
        }
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Chef ruft an", start: block.start,
                                                               end: block.end), allowConflict: true))
        await svc.packageFourTick()
        let moved = await svc.state().plan?.blocks.first
        try expect(moved != nil && moved!.start >= block.end, "verschoben: \(String(describing: moved))")
        try expect(rig.log.flashes.contains { $0.title == "Plan angepasst" }, "Meldung fehlt")
      },

      CheckCase("Meeting: Vorbereitung vor dem Termin mit Link, nach Schließen nicht noch einmal") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Design Review", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00",
                                                               notes: "Einwahl: https://zoom.us/j/123.")))
        _ = await svc.addNote(title: "Review-Ideen", content: "Design der Insel")
        await svc.packageFourTick()
        let meeting = await svc.state().meeting
        try expectEqual(meeting?.phase, .upcoming)
        try expectEqual(meeting?.link, "https://zoom.us/j/123")
        try expect(meeting?.notes.isEmpty == false, "passende Notiz fehlt")
        await svc.dismissMeeting(meeting!.id)
        await svc.packageFourTick()
        let again = await svc.state().meeting
        try expect(again == nil, "kommt nicht wieder")
      },

      CheckCase("Meeting: nach dem Termin werden Stichpunkte zu Notiz + Aufgaben") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:30",
                                                               end: "2026-10-12T09:15")))
        try rig.goTo("2026-10-12T09:20")
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        try expectEqual(meeting.phase, .ended)
        guard case .ok(let result) = await svc.submitMeetingNotes(meeting.id, text: "- Angebot schicken\nLief gut") else {
          throw CheckFailure(message: "nicht gespeichert", location: "")
        }
        try expectEqual(result.tasks.map(\.title), ["Angebot schicken"])
        try expect(result.note.title.hasPrefix("Notizen: Kundentermin"), result.note.title)
        let state = await svc.state()
        try expect(state.meeting == nil, "Karte geschlossen")
        try expect(state.tasks.contains { $0.title == "Angebot schicken" }, "Aufgabe gespeichert")
      },

      CheckCase("Wochenplanung: Sonntagabend fällig, Ziele gelten für nächste Woche, danach Ruhe") {
        let rig = try IntegrationRig(start: "2026-10-18T18:30")  // Sonntag
        let svc = rig.svc
        await svc.packageFourTick()
        let state = await svc.state()
        try expect(state.weeklyReviewPrompt, "Wochenplanung fällig")
        try expectEqual(state.weeklyReview?.weekStart, "2026-10-12")
        await svc.answerWeeklyReview(.save(["Steuer fertig", " ", "3x Sport"]))
        await svc.packageFourTick()
        let after = await svc.state()
        try expect(!after.weeklyReviewPrompt, "nicht noch einmal")
        try rig.goTo("2026-10-19T09:00")
        let monday = await svc.state()
        try expectEqual(monday.weeklyGoals.map(\.text), ["Steuer fertig", "3x Sport"])
        guard case .ok(let done) = await svc.setWeeklyGoalDone(monday.weeklyGoals[0].id, true) else {
          throw CheckFailure(message: "abhaken fehlgeschlagen", location: "")
        }
        try expect(done.done, "abgehakt")
      },

      CheckCase("Wochenplanung: „Später“ fragt nach 30 Minuten erneut, „Nicht diese Woche“ gar nicht") {
        let rig = try IntegrationRig(start: "2026-10-18T18:30")
        let svc = rig.svc
        await svc.packageFourTick()
        await svc.answerWeeklyReview(.later)
        try rig.goTo("2026-10-18T18:45")
        await svc.packageFourTick()
        let early = await svc.state().weeklyReviewPrompt
        try expect(!early, "noch nicht")
        try rig.goTo("2026-10-18T19:01")
        await svc.packageFourTick()
        let later = await svc.state().weeklyReviewPrompt
        try expect(later, "wieder da")
        await svc.answerWeeklyReview(.skip)
        try rig.goTo("2026-10-18T21:00")
        await svc.packageFourTick()
        let skipped = await svc.state().weeklyReviewPrompt
        try expect(!skipped, "übersprungen")
      },

      CheckCase("Datei: nicht lesbar → klare Antwort im Chat, kein Modell nötig") {
        let rig = try IntegrationRig()
        let messages = try await rig.svc.ingestFile(path: "/tmp/gibt-es-nicht-\(UUID().uuidString).pdf")
        try expectEqual(messages.count, 1)
        try expect(messages[0].content?.contains("nicht lesen") == true, messages[0].content ?? "")
      },
    ])
  }
}
