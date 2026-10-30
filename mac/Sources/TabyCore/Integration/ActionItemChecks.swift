// Prüfungen der Aufgaben-Erkennung aus der Mitschrift: Zuverlässigkeits-Regeln im Code
// (Zitat, Datum, Zuständiger, Einstufung), Merker, Fallback ohne Modell, Anlegen.
// Modell-HTTP ist die Grenze (StubServer); heute ist Montag 2026-10-12.
import Foundation

enum ActionItemChecks {
  static let today = LocalTime.parse("2026-10-12T08:00")!
  static let transcript = """
    - Einwilligung erteilt
    - [00:10] Ich: Ich schicke dir das Angebot bis Freitag.
    - [00:40] Andere: Wir sollten das Logo noch überarbeiten.
    - [01:00] Andere: Anna, kannst du die Preisliste prüfen bis morgen?
    - [01:30] Ich: Die Rechnung muss raus.
    - [01:35] ★ Merker
    - Mitschrift beendet
    """

  /// Termin mit Notiz und gefüllter Mitschrift.
  @MainActor static func meeting(_ rig: IntegrationRig, minutes: String = transcript) async throws -> String {
    let svc = rig.svc
    _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                           end: "2026-10-12T09:00")))
    await svc.packageFourTick()
    guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
    guard case .ok(let prep) = await svc.prepareMeeting(meeting.id, noteIds: [], taskIds: []) else {
      throw CheckFailure(message: "Vorbereitung fehlgeschlagen", location: "")
    }
    _ = try svc.store.notes.update(prep.id, content: MeetingPrep.replaceSection(MeetingPrep.notesHeading, body: minutes,
                                                                                in: prep.content))
    return meeting.id
  }

  static func raw(_ evidence: String, text: String = "Aufgabe", owner: String? = nil, due: String? = nil) -> ActionItems.Raw {
    .init(text: text, owner: owner, duePhrase: due, evidence: evidence)
  }

  @MainActor static var integration: [CheckCase] {
    let lines = ActionItems.parse(transcript)
    return [
      CheckCase("Mitschrift-Parser: Sekunden und Sprecher, Meta-Zeilen fallen weg") {
        try expectEqual(lines.count, 5)
        try expectEqual(lines[0], ActionItems.Line(seconds: 10, speaker: .me, text: "Ich schicke dir das Angebot bis Freitag."))
        try expectEqual(lines[4], ActionItems.Line(seconds: 95, speaker: .marker, text: "Merker"))
      },

      CheckCase("Klare Zusage mit Datum: clear, Zuständiger ich, Datum vom Parser (Freitag = 16.10.)") {
        let c = ActionItems.candidates(from: [raw("Ich schicke dir das Angebot bis Freitag", owner: "Hans", due: "bis Freitag")],
                                       lines: lines, today: today)
        try expectEqual(c.count, 1)
        try expectEqual(c[0].confidence, .clear)
        try expectEqual(c[0].owner, "ich")
        try expectEqual(c[0].due, "2026-10-16")
        try expectEqual(c[0].atSeconds, 10)
      },

      CheckCase("„Wir sollten …“ ist nur vermutet; Auftrag an Anna: Name aus dem Text, clear") {
        let c = ActionItems.candidates(from: [raw("Wir sollten das Logo noch überarbeiten"),
                                              raw("Anna, kannst du die Preisliste prüfen", due: "bis morgen")],
                                       lines: lines, today: today)
        try expectEqual(c[0].confidence, .guess)
        try expectEqual(c[0].owner, nil)
        try expectEqual(c[1].owner, "Anna")
        try expectEqual(c[1].due, "2026-10-13")
        try expectEqual(c[1].confidence, .clear)
      },

      CheckCase("Erfundenes Zitat wird verworfen, Groß/Klein und Leerraum zählen nicht") {
        let c = ActionItems.candidates(from: [raw("Ich buche das Hotel für alle"),
                                              raw("ICH  schicke dir  das Angebot")], lines: lines, today: today)
        try expectEqual(c.count, 1)
        try expectEqual(c[0].atSeconds, 10)
      },

      CheckCase("Datum in der Vergangenheit oder unklar → nil; Modell kann kein Datum setzen") {
        try expectEqual(ActionItems.dueDate("bis 01.10.2025", today: today), nil)
        try expectEqual(ActionItems.dueDate("irgendwann", today: today), nil)
        try expectEqual(ActionItems.dueDate("um 15 Uhr", today: today), nil)
        try expectEqual(ActionItems.dueDate("bis 2026-10-20", today: today), nil)
        try expectEqual(ActionItems.dueDate("nächste Woche", today: today), "2026-10-19")
      },

      CheckCase("Ohne Modell: Auslöserliste findet Zusage, Auftrag und Vermutetes; Merker kommt mit Kontext") {
        let rig = try IntegrationRig()
        let id = try await meeting(rig)
        guard case .ok(let items) = await rig.svc.extractMeetingActions(id) else {
          throw CheckFailure(message: "Erkennung fehlgeschlagen", location: "")
        }
        try expect(try rig.svc.store.tasks.list().isEmpty, "Erkennung darf nichts anlegen")
        let byTime = Dictionary(items.map { ($0.atSeconds, $0) }, uniquingKeysWith: { a, _ in a })
        try expectEqual(byTime[10]?.confidence, .clear)
        try expectEqual(byTime[10]?.due, "2026-10-16")
        try expectEqual(byTime[40]?.confidence, .guess)
        try expectEqual(byTime[60]?.owner, "Anna")
        let marked = try expectNotNil(items.first { $0.confidence == .marked })
        try expectEqual(marked.atSeconds, 95)
        try expectEqual(marked.evidence, "Die Rechnung muss raus.")
        try expect(marked.text.contains("Rechnung"), marked.text)
        try expect(items.map(\.atSeconds) == items.map(\.atSeconds).sorted(), "nach Zeit sortiert")
      },

      CheckCase("Mit Modell: Merker-Text und Vorschläge vom Modell, erfundenes Zitat fällt weg") {
        let json = """
          {"items":[{"text":"Angebot schicken","owner":"ich","due_phrase":"bis Freitag","evidence":"Ich schicke dir das Angebot bis Freitag."},\
          {"text":"Hotel buchen","owner":"ich","due_phrase":null,"evidence":"Ich buche das Hotel"}]}
          """
        let rig = try IntegrationRig(modelReplies: [StubServer.text("Rechnung versenden"), StubServer.text(json)])
        await rig.configureModel()
        let id = try await meeting(rig)
        guard case .ok(let items) = await rig.svc.extractMeetingActions(id) else {
          throw CheckFailure(message: "Erkennung fehlgeschlagen", location: "")
        }
        try expectEqual(items.map(\.text), ["Angebot schicken", "Rechnung versenden"])
        try expectEqual(items[0].due, "2026-10-16")
        try expectEqual(items[1].confidence, .marked)
      },

      CheckCase("Leere Mitschrift: Fehler auf Deutsch") {
        let rig = try IntegrationRig()
        let id = try await meeting(rig, minutes: "- Einwilligung erteilt")
        let r = await rig.svc.extractMeetingActions(id)
        try expect(!r.isOk && r.errorMessage?.contains("Mitschrift") == true, r.errorMessage ?? "")
      },

      CheckCase("Mehr als 20 Kandidaten werden auf 20 gekürzt, nach Zeit sortiert") {
        let many = (0..<30).map { ActionCandidate(id: "x\($0)", text: "Aufgabe Nummer \($0) alpha\($0)", confidence: .guess,
                                                  evidence: "Beleg \($0) beta\($0)", atSeconds: 300 - $0) }
        let out = ActionItems.merged(many)
        try expectEqual(out.count, 20)
        try expect(out.map(\.atSeconds) == out.map(\.atSeconds).sorted(), "unsortiert")
      },

      CheckCase("Anlegen: Warten auf Name mit Stand und Kennzeichen, Zitat in der Notiz, Dublette übersprungen") {
        let rig = try IntegrationRig()
        let id = try await meeting(rig)
        let mine = ActionCandidate(id: "a", text: "Angebot schicken", owner: "ich", due: "2026-10-16", confidence: .clear,
                                   evidence: "Ich schicke dir das Angebot bis Freitag.", atSeconds: 10)
        let anna = ActionCandidate(id: "b", text: "Preisliste prüfen", owner: "Anna", due: "2026-10-13", confidence: .clear,
                                   evidence: "Anna, kannst du die Preisliste prüfen", atSeconds: 60)
        guard case .ok(let made) = await rig.svc.acceptMeetingActions(id, [mine, anna, mine]) else {
          throw CheckFailure(message: "Anlegen fehlgeschlagen", location: "")
        }
        try expectEqual(made.count, 2)
        try expectEqual(made[0].title, "Angebot schicken")
        try expectEqual(made[0].due, "2026-10-16")
        try expectEqual(made[0].tags, ["meeting"])
        try expectEqual(made[1].title, "Warten auf Anna: Preisliste prüfen")
        try expectEqual(made[1].status, .needsInfo)
        try expectEqual(made[1].tags, ["meeting", "wartet-auf"])
        try expect(made[0].notes?.contains("[00:10]") == true && made[0].notes?.contains("Kundentermin") == true, made[0].notes ?? "")
        guard case .ok(let again) = await rig.svc.acceptMeetingActions(id, [mine, anna]) else {
          throw CheckFailure(message: "zweites Anlegen fehlgeschlagen", location: "")
        }
        try expectEqual(again.count, 0)
        try expectEqual(try rig.svc.store.tasks.list().count, 2)
      },
    ]
  }
}
