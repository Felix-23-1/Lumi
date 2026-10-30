// Prüfungen der lokalen Mitschrift gegen den echten Kern mit FakeAudioTextSource (die Grenze ist der Ton).
import Foundation

enum MeetingListenChecks {
  /// Kern mit Termin 08:08–09:00, Uhr auf 08:10, Attrappe als Tonquelle.
  @MainActor private static func rig() async throws -> (IntegrationRig, FakeAudioTextSource, String) {
    let rig = try IntegrationRig()
    let fake = FakeAudioTextSource()
    rig.svc.audioSourceFactory = { fake }
    _ = await rig.svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
    await rig.svc.packageFourTick()
    guard let meeting = await rig.svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
    try rig.goTo("2026-10-12T08:10")
    return (rig, fake, meeting.id)
  }

  @MainActor private static func minutes(_ svc: CoreServices, _ id: String) throws -> [String] {
    let note = try expectNotNil(try svc.store.notes.get(meetingKey: id), "Termin-Notiz fehlt")
    return MeetingPrep.mitschrift(in: note.content).components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  @MainActor static var integration: [CheckCase] {
    [
      CheckCase("Mitschrift: spontanes Gespräch ohne Termin legt eine Termin-Notiz an") {
        let (rig, _, _) = try await rig()
        let id = "adhoc|2026-10-12T08:30"
        let r = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try expect(r.isOk, r.errorMessage ?? "")
        let cur = await rig.svc.state().listening
        let st = try expectNotNil(cur)
        try expectEqual(st.title, "Gespräch 08:30")
        let note = try expectNotNil(try rig.svc.store.notes.get(meetingKey: id))
        try expect(note.title.hasPrefix("Gespräch 08:30"), note.title)
        await rig.svc.stopMeetingListening()
      },

      CheckCase("Mitschrift: Einwilligungs-Tor – ohne Zustimmung startet nichts, nur ich geht ohne") {
        let (rig, fake, id) = try await rig()
        let denied = await rig.svc.startMeetingListening(id, mode: .everyone, consentGiven: false)
        try expect(!denied.isOk && denied.errorMessage?.contains("Teilnehmer") == true, denied.errorMessage ?? "ok?")
        try expectEqual(fake.startedModes.count, 0)
        let cur1 = await rig.svc.state().listening
        try expect(cur1 == nil, "Zustand darf nichts zeigen")
        try expect(try rig.svc.store.notes.get(meetingKey: id) == nil, "keine Notiz ohne Start")
        let mine = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try expect(mine.isOk, mine.errorMessage ?? "")
        try expectEqual(fake.startedModes, [.onlyMe])
        let cur2 = await rig.svc.state().listening
        let st = try expectNotNil(cur2)
        try expectEqual(st.mode, .onlyMe)
        try expect(st.consentAt == nil, "kein Einwilligungszeitpunkt bei nur ich")
      },

      CheckCase("Mitschrift: Zeilenformat, Zeitmarken ab Start, Einwilligungs- und Abschlusszeile") {
        let (rig, fake, id) = try await rig()
        let r = await rig.svc.startMeetingListening(id, mode: .everyone, consentGiven: true)
        try expect(r.isOk, r.errorMessage ?? "")
        fake.say(.me, "Hallo   zusammen\nund willkommen")
        try rig.clock.set(try expectNotNil(LocalTime.parse("2026-10-12T08:10")).addingTimeInterval(65))
        fake.say(.others, "Das klingt gut")
        fake.say(.me, "partial", final: false)
        let cur3 = await rig.svc.state().listening
        let st = try expectNotNil(cur3)
        try expectEqual(st.lines, 2)
        try expectEqual(st.consentAt, "2026-10-12T08:10")
        await rig.svc.stopMeetingListening()
        let cur4 = await rig.svc.state().listening
        try expect(cur4 == nil, "nach Stopp keine Mitschrift")
        try expectEqual(try minutes(rig.svc, id), [
          "- Einwilligung aller Teilnehmer bestätigt um 08:10",
          "- [00:00] Ich: Hallo zusammen und willkommen",
          "- [01:05] Andere: Das klingt gut",
          "- Mitschrift beendet um 08:11",
        ])
        await rig.settle()
        try expectEqual(fake.stopCount, 1)
        let note = try expectNotNil(try rig.svc.store.notes.get(meetingKey: id))
        let raw = (MeetingPrep.section("Mitschrift", in: note.content) ?? "").components(separatedBy: "\n")
        try expect(!raw.contains { $0.trimmingCharacters(in: .whitespaces) == "-" }, "leerer Platzhalter blieb stehen")
      },

      CheckCase("Mitschrift: Notiz wird gebündelt (5 s oder 10 Zeilen), nicht pro Wort") {
        let (rig, fake, id) = try await rig()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        fake.say(.me, "eins")
        fake.say(.me, "zwei")
        try expectEqual(try minutes(rig.svc, id), [])
        rig.clock.set(rig.clock.now().addingTimeInterval(6))
        fake.say(.me, "drei")
        try expectEqual(try minutes(rig.svc, id).count, 3)
        for i in 0..<10 { fake.say(.me, "x\(i)") }
        try expectEqual(try minutes(rig.svc, id).count, 13)
        fake.say(.me, "spaet")
        try expectEqual(try minutes(rig.svc, id).count, 13)
        await rig.svc.listenTick()
        rig.clock.set(rig.clock.now().addingTimeInterval(6))
        await rig.svc.listenTick()
        try expectEqual(try minutes(rig.svc, id).count, 14)
      },

      CheckCase("Mitschrift: Merker hängt eine Zeile an und zählt hoch; ohne Mitschrift passiert nichts") {
        let (rig, fake, id) = try await rig()
        await rig.svc.markMeetingMoment()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        rig.clock.set(rig.clock.now().addingTimeInterval(125))
        await rig.svc.markMeetingMoment()
        fake.say(.me, "Aufgabe für mich")
        let cur5 = await rig.svc.state().listening
        try expectEqual(try expectNotNil(cur5).markers, 1)
        let cur6 = await rig.svc.state().listening
        try expectEqual(try expectNotNil(cur6).lines, 1)
        try expectEqual(try minutes(rig.svc, id).first, "- [02:05] ★ Merker")
      },

      CheckCase("Mitschrift: zweiter Start ist idempotent, Neustart nach Stopp dupliziert nichts") {
        let (rig, fake, id) = try await rig()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        let again = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try expect(again.isOk, again.errorMessage ?? "")
        try expectEqual(fake.startedModes.count, 1)
        fake.say(.me, "eins")
        await rig.svc.stopMeetingListening()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        fake.say(.me, "zwei")
        await rig.svc.stopMeetingListening()
        let note = try expectNotNil(try rig.svc.store.notes.get(meetingKey: id))
        try expectEqual(note.content.components(separatedBy: "## Mitschrift").count - 1, 1)
        try expectEqual(note.content.components(separatedBy: "## Agenda").count - 1, 1)
        try expectEqual(try rig.svc.store.notes.list().filter { $0.meetingKey == id }.count, 1)
        let lines = try minutes(rig.svc, id)
        try expectEqual(lines.filter { $0.hasSuffix("Ich: eins") }.count, 1)
        try expectEqual(lines.filter { $0.hasSuffix("Ich: zwei") }.count, 1)
        try expectEqual(lines.filter { $0.hasPrefix("- Mitschrift beendet") }.count, 2)
      },

      CheckCase("Mitschrift: nur eine gleichzeitig; Sprachausgabe schweigt währenddessen") {
        let (rig, _, id) = try await rig()
        rig.svc.p4.todayEvents = []  // sonst schweigt Lumi schon wegen des laufenden Termins
        try expect(rig.svc.speechAllowed(), "vor der Mitschrift darf gesprochen werden")
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        let other = await rig.svc.startMeetingListening("anderer|termin|2026-10-12T10:00", mode: .onlyMe, consentGiven: false)
        try expect(!other.isOk && other.errorMessage?.contains("läuft schon") == true, other.errorMessage ?? "ok?")
        let cur7 = await rig.svc.state().listening
        try expectEqual(try expectNotNil(cur7).meetingId, id)
        try expect(!rig.svc.speechAllowed(), "während der Mitschrift keine Sprachausgabe")
        await rig.svc.stopMeetingListening()
        try expect(rig.svc.speechAllowed(), "nach dem Stopp wieder erlaubt")
      },

      CheckCase("Mitschrift: Fehler der Quelle stoppt sauber mit Hinweis und Abschlusszeile") {
        let (rig, fake, id) = try await rig()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        fake.say(.me, "vor dem Ausfall")
        fake.fail("Das Mikrofon ist weg.")
        let cur8 = await rig.svc.state().listening
        try expect(cur8 == nil, "Mitschrift muss beendet sein")
        await rig.settle()
        try expect(rig.log.flashes.contains { $0.body.contains("Mikrofon ist weg") }, "Hinweis fehlt")
        try expectEqual(fake.stopCount, 1)
        let lines = try minutes(rig.svc, id)
        try expect(lines.first?.hasSuffix("Ich: vor dem Ausfall") == true, "\(lines)")
        try expect(lines.last?.hasPrefix("- Mitschrift beendet um") == true, "\(lines)")
      },

      CheckCase("Mitschrift: Start der Quelle scheitert (Freigabe) – nichts läuft, Meldung kommt durch") {
        let (rig, fake, id) = try await rig()
        rig.svc.p4.todayEvents = []
        fake.startResult = .failure(code: "PERMISSION", error: "Lumi darf das Mikrofon nicht nutzen.")
        let r = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try expectEqual(r.errorMessage, "Lumi darf das Mikrofon nicht nutzen.")
        let cur9 = await rig.svc.state().listening
        try expect(cur9 == nil, "darf nicht laufen")
        try expect(rig.svc.speechAllowed(), "Sprachausgabe bleibt erlaubt")
        fake.startResult = .ok(Empty())
        let retry = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try expect(retry.isOk, retry.errorMessage ?? "")
      },

      CheckCase("Mitschrift: endet 15 Minuten nach dem Termin von selbst") {
        let (rig, fake, id) = try await rig()
        _ = await rig.svc.startMeetingListening(id, mode: .onlyMe, consentGiven: false)
        try rig.goTo("2026-10-12T09:14")
        await rig.svc.listenTick()
        let cur10 = await rig.svc.state().listening
        try expect(cur10 != nil, "9:14 läuft noch")
        try rig.goTo("2026-10-12T09:16")
        await rig.svc.listenTick()
        let cur11 = await rig.svc.state().listening
        try expect(cur11 == nil, "9:16 muss beendet sein")
        await rig.settle()
        try expectEqual(fake.stopCount, 1)
        try expectEqual(try minutes(rig.svc, id).last, "- Mitschrift beendet um 09:16")
      },
    ]
  }
}
