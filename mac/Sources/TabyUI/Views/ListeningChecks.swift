// Prüfungen und Snapshots für die Mitschrift: Einwilligung, Gruppen und Vorauswahl der
// Aufgaben, Bearbeiten, Anlegen und Zeitanzeige (gegen FakeServices), dazu die Einwilligungs-
// karte, die Prüfliste und die Anzeige „Mitschrift läuft“ in der offenen und geschlossenen Insel.
import SwiftUI
import TabyCore

enum ListeningChecks {
  static let meeting = MeetingBrief(id: "apple|e-7|2026-10-11T15:00", phase: .upcoming, title: "Lieferantengespräch",
                                    start: "2026-10-11T15:00", end: "2026-10-11T16:00", notes: [], tasks: [])

  static let items: [ActionCandidate] = [
    ActionCandidate(id: "a1", text: "Angebot an Frau Kern schicken", owner: "ich", due: "2026-10-16", confidence: .clear,
                    evidence: "Ich schicke dir das Angebot bis Freitag.", atSeconds: 120),
    ActionCandidate(id: "a2", text: "Folie 3 überarbeiten", owner: "Jonas", due: nil, confidence: .guess,
                    evidence: "Folie 3 sollte man vielleicht noch anpassen.", atSeconds: 300),
    ActionCandidate(id: "a3", text: "Termin mit dem Lieferanten abstimmen", owner: nil, due: nil, confidence: .marked,
                    evidence: "Das ist eine Aufgabe: Termin mit dem Lieferanten abstimmen.", atSeconds: 480),
  ]

  static let running = MeetingListening(meetingId: meeting.id, title: meeting.title, mode: .everyone,
                                        startedAt: "2026-10-11T08:50", consentAt: "2026-10-11T08:50",
                                        lines: 14, markers: 1)

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Mitschrift: „Alle“ startet nur mit Häkchen, „Nur ich“ immer; Einwilligung meldet nur bei „Alle“") {
        try expect(!ListeningLogic.canStart(mode: .everyone, consent: false), "Alle ohne Häkchen gesperrt")
        try expect(ListeningLogic.canStart(mode: .everyone, consent: true), "Alle mit Häkchen frei")
        try expect(ListeningLogic.canStart(mode: .onlyMe, consent: false), "Nur ich ohne Häkchen frei")
        try expect(!ListeningLogic.consentGiven(mode: .onlyMe, consent: true), "Nur ich meldet keine Einwilligung")
        try expect(ListeningLogic.consentGiven(mode: .everyone, consent: true), "Alle mit Häkchen ist Einwilligung")
      },
      CheckCase("Mitschrift: Start über Dienste – „Alle“ ohne Einwilligung wird abgelehnt, „Nur ich“ setzt den Zustand") {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        let denied = await ViewActions.startListening(model, meeting.id, mode: .everyone, consentGiven: false)
        try expect(denied != nil, "Ohne Einwilligung kein Start")
        try expect(fake.current.listening == nil, "Nichts gestartet")
        let ok = await ViewActions.startListening(model, meeting.id, mode: .onlyMe, consentGiven: false)
        try expect(ok == nil, "Nur ich startet: \(ok ?? "")")
        try expectEqual(fake.current.listening?.meetingId, meeting.id)
        try expectEqual(fake.current.listening?.mode, .onlyMe)
      },
      CheckCase("Mitschrift: Merker zählt, Stopp löscht den Zustand") {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        await ViewActions.startListening(model, meeting.id, mode: .onlyMe, consentGiven: false)
        await fake.markMeetingMoment()
        await fake.markMeetingMoment()
        try expectEqual(fake.current.listening?.markers, 2)
        await fake.stopMeetingListening()
        try expect(fake.current.listening == nil, "Nach dem Stopp keine Mitschrift")
      },
      CheckCase("Aufgaben prüfen: „Sicher“ und „Unklar“ getrennt, vorgewählt sind nur die sicheren") {
        try expectEqual(ListeningLogic.sure(items).map(\.id), ["a1", "a3"])
        try expectEqual(ListeningLogic.unclear(items).map(\.id), ["a2"])
        try expectEqual(ListeningLogic.preselected(items), Set(["a1", "a3"]))
        let withGuess = ListeningLogic.toggled(ListeningLogic.preselected(items), "a2")
        try expectEqual(ListeningLogic.chosen(items, withGuess).map(\.id), ["a1", "a2", "a3"],
                        "Umschalten wählt die Vermutung dazu, Listenreihenfolge bleibt")
      },
      CheckCase("Aufgaben prüfen: Bearbeiten ändert Text, Zuständige und Datum; leerer Text fällt aus der Auswahl") {
        var edited = ListeningLogic.edit(items, id: "a2") {
          $0.text = "Folie 3 mit Zahlen überarbeiten"; $0.owner = nil; $0.due = "2026-10-20"
        }
        try expectEqual(edited.first { $0.id == "a2" }?.due, "2026-10-20")
        try expectEqual(edited.first { $0.id == "a2" }?.owner, nil)
        try expectEqual(edited.count, 3, "Keine Zeile geht verloren")
        edited = ListeningLogic.edit(edited, id: "a1") { $0.text = "   " }
        let all = Set(["a1", "a2", "a3"])
        try expectEqual(ListeningLogic.chosen(edited, all).map(\.id), ["a2", "a3"])
        try expectEqual(ListeningLogic.acceptLabel(ListeningLogic.chosen(edited, all).count), "Ausgewählte anlegen (2)")
        try expectEqual(ListeningLogic.ownerOptions(items).map(ListeningLogic.ownerLabel), ["Ich", "Jonas", "Unklar"])
        try expectEqual(ListeningLogic.acceptedText(1), "1 Aufgabe angelegt")
        try expectEqual(ListeningLogic.acceptedText(3), "3 Aufgaben angelegt")
      },
      CheckCase("Aufgaben prüfen: Anlegen über Dienste legt nur die gewählten Kandidaten als Aufgaben an") {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        let extracted = await ViewActions.extractListenActions(model, meeting.id)
        try expect(extracted.error == nil, "Prüfen gelingt: \(extracted.error ?? "")")
        try expectEqual(extracted.items.count, 3)
        let before = fake.current.tasks.count
        let chosen = ListeningLogic.chosen(extracted.items, ListeningLogic.preselected(extracted.items))
        let r = await ViewActions.acceptListenActions(model, meeting.id, chosen)
        try expect(r.error == nil, "Anlegen gelingt: \(r.error ?? "")")
        try expectEqual(r.count, 2)
        try expectEqual(fake.current.tasks.count, before + 2)
        try expectEqual(fake.current.tasks.suffix(2).map(\.title), ["Angebot an Frau Kern schicken",
                                                                  "Termin mit dem Lieferanten abstimmen"])
      },
      CheckCase("Mitschrift: Laufzeit und Zeilen als Text") {
        try expectEqual(ListeningLogic.elapsedText(startedAt: "2026-10-11T10:00", now: "2026-10-11T10:12"), "12:00")
        try expectEqual(ListeningLogic.elapsedText(startedAt: "2026-10-11T10:00", now: "2026-10-11T09:59"), "00:00",
                        "Nie negativ")
        try expectEqual(ListeningLogic.linesText(1), "1 Zeile")
        try expectEqual(ListeningLogic.linesText(14), "14 Zeilen")
      },
    ]
  }

  @MainActor private static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("view-listening-consent-only", size: CGSize(width: TabLayout.contentWidth, height: 170)) {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(ListeningStartView(meeting: meeting, initialMode: .onlyMe, onClose: {}), model)
      },
      SnapshotSpec("view-listening-consent-all", size: CGSize(width: TabLayout.contentWidth, height: 330)) {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(ListeningStartView(meeting: meeting, initialMode: .everyone, onClose: {}), model)
      },
      SnapshotSpec("view-listening-review", size: CGSize(width: TabLayout.contentWidth, height: 360)) {
        let fake = FakeServices(sample: false)
        fake.current.meeting = meeting
        let model = AppModel(services: fake, preloaded: fake.current)
        return wrap(ListeningReviewView(meeting: meeting, onClose: {}, initialItems: items), model)
      },
      ShellSnapshots.islandAt("listening-closed", now: ViewChecks.now, height: 120) { s, fake in
        fake.current.listening = running
        s.previewState = fake.current
      },
      ShellSnapshots.islandAt("listening-open", now: ViewChecks.now, height: 470) { s, fake in
        fake.current.listening = running
        s.previewState = fake.current
        s.open(tab: .today)
      },
    ]
  }
}
