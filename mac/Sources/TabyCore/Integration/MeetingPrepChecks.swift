// Prüfungen der Meeting-Vorbereitung: Rahmen, Fallback-Agenda, Idempotenz und
// Zusammenfassung gegen den echten Kern. Ohne Modell, und mit gescripteter
// Modellantwort über StubServer (Modell-HTTP ist die Grenze).
import Foundation

enum MeetingPrepChecks {
  @MainActor static var integration: [CheckCase] {
    [
      CheckCase("Rahmen: Abschnitte in fester Reihenfolge, Aufgabe mit Fälligkeit, Mitschrift leer") {
        let rig = try IntegrationRig()
        guard case .ok(let task) = await rig.svc.addTask(title: "Angebot schicken", notes: nil,
                                                         due: "2026-10-14") else {
          throw CheckFailure(message: "Aufgabe nicht angelegt", location: "")
        }
        let text = MeetingPrep.frame(title: "Kundentermin", date: "12.10.2026",
                                     agenda: ["- Preis", "  - Rabatt"], tasks: [task])
        try expect(text.hasPrefix("# Kundentermin – 12.10.2026\n"), text)
        try expect(text.contains("## Agenda\n- Preis\n  - Rabatt\n\n## Offene Punkte\n- [ ] Angebot schicken – fällig 14.10.2026\n\n## Mitschrift\n- \n"), text)
        try expectEqual(MeetingPrep.mitschrift(in: text), "")
      },

      CheckCase("Fallback-Agenda: je Notiz Titel und höchstens 3 gekürzte Zeilen, ohne Modell") {
        let note = Note(id: "n1", title: "Ideen", content: "# Kopf\n- Eins\n\n- Zwei\nDrei\nVier\n",
                        createdAt: "", updatedAt: "")
        try expectEqual(MeetingPrep.fallbackAgenda(notes: [note]), ["- Ideen", "  - Eins", "  - Zwei", "  - Drei"])
        let long = Note(id: "n2", title: "Lang", content: String(repeating: "x", count: 300), createdAt: "", updatedAt: "")
        let lines = MeetingPrep.fallbackAgenda(notes: [long])
        try expect(lines[1].count <= MeetingPrep.maxLineChars + 4, "nicht gekürzt: \(lines[1].count)")
      },

      CheckCase("Zusammenfassung: zweimal anhängen ersetzt, dupliziert nicht, Mitschrift bleibt") {
        let base = "# T\n\n## Mitschrift\n- Punkt\n"
        let once = MeetingPrep.withSummary("- A", in: base)
        let twice = MeetingPrep.withSummary("- B", in: once)
        try expectEqual(twice.components(separatedBy: "## Zusammenfassung").count - 1, 1)
        try expect(twice.hasSuffix("## Zusammenfassung\n- B\n"), twice)
        try expectEqual(MeetingPrep.mitschrift(in: twice), "- Punkt")
      },

      CheckCase("Neuer Rahmen behält Mitschrift und Zusammenfassung, ersetzt die Agenda") {
        let old = MeetingPrep.withSummary("- A", in: "# T\n\n## Agenda\n- alt\n\n## Mitschrift\n- Lief gut\n")
        let fresh = MeetingPrep.frame(title: "T", date: "12.10.2026", agenda: ["- neu"], tasks: [])
        let merged = MeetingPrep.refreshed(fresh, keeping: old)
        try expect(merged.contains("- neu") && !merged.contains("- alt"), merged)
        try expectEqual(MeetingPrep.mitschrift(in: merged), "- Lief gut")
        try expect(merged.hasSuffix("## Zusammenfassung\n- A\n"), merged)
      },

      CheckCase("Modellantwort: Zusammenfassung und Aufgaben werden getrennt, Dubletten fallen weg") {
        let r = MeetingPrep.parseSummary("Zusammenfassung:\n- Angebot besprochen\n- Preis offen\nAufgaben:\n- Angebot senden\n")
        try expectEqual(r.summary, "- Angebot besprochen\n- Preis offen\n\n### Aufgaben\n- Angebot senden")
        try expectEqual(r.tasks, ["Angebot senden"])
        try expectEqual(MeetingPrep.mergedTasks(["A", "B"], ["b", "C"]), ["A", "B", "C"])
      },

      CheckCase("Modellantwort in Markdown: feste Abschnitte, „keine“ fällt weg, Aufgaben werden Aufgaben") {
        let reply = """
        ## Ergebnis
        - Preis geklärt
        ## Entscheidungen
        - keine
        ## Aufgaben
        - Rechnung an Frau Kern senden – bis 14.10.
        - Preis geklärt
        ## Offene Fragen
        - Liefertermin
        """
        let r = MeetingPrep.parseSummary(reply)
        try expectEqual(r.summary, "### Ergebnis\n- Preis geklärt\n\n### Aufgaben\n- Rechnung an Frau Kern senden – bis 14.10.\n- Preis geklärt\n\n### Offene Fragen\n- Liefertermin")
        try expectEqual(r.tasks, ["Rechnung an Frau Kern senden – bis 14.10.", "Preis geklärt"])
        try expectEqual(MeetingPrep.parseSummary("## Entscheidungen\n- keine\n").summary, "")
        let prompt = MeetingPrep.summaryPrompt(title: "T", minutes: "x", maxChars: 100)
        try expect(prompt.contains("## Ergebnis") && prompt.contains("## Offene Fragen"), "Prompt nennt die festen Abschnitte")
      },

      CheckCase("Agenda aus der Modellantwort: Unterabschnitte bleiben, Überschriften „##“ werden nie übernommen") {
        let lines = MeetingPrep.agendaLines(fromModel: "## Worum geht es\n- Preis\n### Fragen\n- Frist?\n")
        try expectEqual(lines, ["### Worum geht es", "- Preis", "### Fragen", "- Frist?"])
        try expectEqual(MeetingPrep.agendaLines(fromModel: "## Nur Überschrift\n"), [])
        let frame = MeetingPrep.frame(title: "T", date: "12.10.2026", agenda: lines, tasks: [])
        try expectEqual(MeetingPrep.mitschrift(in: frame), "")
        try expect(frame.contains("## Agenda\n### Worum geht es\n- Preis"), frame)
      },

      CheckCase("Vorbereitung ohne Modell: zweimal = eine Notiz, Agenda folgt der Auswahl, Karte zeigt die Notiz") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
        guard case .ok(let ideas) = await svc.addNote(title: "Angebot", content: "- Preis\n- Termin") else {
          throw CheckFailure(message: "Notiz nicht angelegt", location: "")
        }
        let tagged = try svc.store.notes.add(title: "Kunde", content: "Bisheriger Stand", tags: ["Kundentermin"])
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        try expect(meeting.notes.contains { $0.id == tagged.id }, "Kennzeichen-Notiz fehlt in den Vorschlägen")
        try expect(meeting.prepNoteId == nil, "vor der Vorbereitung keine Notiz")

        guard case .ok(let first) = await svc.prepareMeeting(meeting.id, noteIds: [ideas.id, tagged.id], taskIds: []) else {
          throw CheckFailure(message: "Vorbereitung fehlgeschlagen", location: "")
        }
        guard case .ok(let second) = await svc.prepareMeeting(meeting.id, noteIds: [ideas.id], taskIds: []) else {
          throw CheckFailure(message: "zweite Vorbereitung fehlgeschlagen", location: "")
        }
        try expectEqual(first.id, second.id)
        try expectEqual(second.meetingKey, meeting.id)
        try expectEqual(try svc.store.notes.list().filter { $0.meetingKey == meeting.id }.count, 1)
        try expect(second.content.contains("- Angebot\n  - Preis"), second.content)
        try expect(!second.content.contains("- Kunde"), "alte Auswahl blieb stehen")
        try expectEqual(second.title, "Kundentermin – Agenda")
        let after = await svc.state().meeting
        try expectEqual(after?.prepNoteId, second.id)
      },

      CheckCase("Vorbereitung mit Modell: Agenda kommt aus der Modellantwort") {
        let rig = try IntegrationRig(modelReplies: [StubServer.text("- Preis klären\n- Liefertermin\n")])
        await rig.configureModel()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
        guard case .ok(let ideas) = await svc.addNote(title: "Angebot", content: "Preis, Termin") else {
          throw CheckFailure(message: "Notiz nicht angelegt", location: "")
        }
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        guard case .ok(let note) = await svc.prepareMeeting(meeting.id, noteIds: [ideas.id], taskIds: []) else {
          throw CheckFailure(message: "Vorbereitung fehlgeschlagen", location: "")
        }
        try expect(note.content.contains("- Preis klären\n- Liefertermin"), note.content)
        try expect(!note.content.contains("Angebot\n  - "), "Code-Fallback statt Modell")
      },

      CheckCase("Zusammenfassung leer: Fehler auf Deutsch, keine Notiz geändert") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        _ = await svc.prepareMeeting(meeting.id, noteIds: [], taskIds: [])
        let result = await svc.summarizeMeeting(meeting.id)
        try expect(!result.isOk, "leere Mitschrift muss scheitern")
        try expect(result.errorMessage?.contains("Mitschrift") == true, result.errorMessage ?? "")
      },

      CheckCase("Zusammenfassung ohne Modell: Mitschrift wird Zusammenfassung, Aufgaben aus Stichpunkten") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        guard case .ok(let prep) = await svc.prepareMeeting(meeting.id, noteIds: [], taskIds: []) else {
          throw CheckFailure(message: "Vorbereitung fehlgeschlagen", location: "")
        }
        let filled = MeetingPrep.replaceSection(MeetingPrep.notesHeading,
                                                body: "- Angebot schicken\nTODO: Angebot prüfen\nLief gut", in: prep.content)
        _ = try svc.store.notes.update(prep.id, content: filled)
        guard case .ok(let result) = await svc.summarizeMeeting(meeting.id) else {
          throw CheckFailure(message: "Zusammenfassung fehlgeschlagen", location: "")
        }
        try expectEqual(result.tasks.map(\.title), ["Angebot schicken", "Angebot prüfen"])
        try expect(result.note.content.contains("## Zusammenfassung\n- Angebot schicken\nTODO: Angebot prüfen\nLief gut"),
                   result.note.content)
        let closed = await svc.state()
        try expect(closed.meeting == nil, "Karte geschlossen")
      },

      CheckCase("Zusammenfassung mit Modell: Zusammenfassung und Aufgaben aus der Antwort, Notiz + Aufgaben angelegt") {
        let rig = try IntegrationRig(modelReplies: [StubServer.text("Zusammenfassung:\n- Preis geklärt\nAufgaben:\n- Rechnung senden\n")])
        await rig.configureModel()
        let svc = rig.svc
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Kundentermin", start: "2026-10-12T08:08",
                                                               end: "2026-10-12T09:00")))
        await svc.packageFourTick()
        guard let meeting = await svc.state().meeting else { throw CheckFailure(message: "keine Karte", location: "") }
        guard case .ok(let prep) = await svc.prepareMeeting(meeting.id, noteIds: [], taskIds: []) else {
          throw CheckFailure(message: "Vorbereitung fehlgeschlagen", location: "")
        }
        let filled = MeetingPrep.replaceSection(MeetingPrep.notesHeading, body: "Preis ist offen\nLief gut", in: prep.content)
        _ = try svc.store.notes.update(prep.id, content: filled)
        guard case .ok(let result) = await svc.summarizeMeeting(meeting.id) else {
          throw CheckFailure(message: "Zusammenfassung fehlgeschlagen", location: "")
        }
        try expectEqual(result.tasks.map(\.title), ["Rechnung senden"])
        try expect(result.note.content.hasSuffix("## Zusammenfassung\n- Preis geklärt\n\n### Aufgaben\n- Rechnung senden\n"), result.note.content)
        let saved = await svc.state()
        try expect(saved.tasks.contains { $0.title == "Rechnung senden" }, "Aufgabe gespeichert")
      },
    ]
  }
}
