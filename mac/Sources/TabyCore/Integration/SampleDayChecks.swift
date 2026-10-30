// Prüfungen des Beispiel-Tags: anlegen, nicht doppeln, genau die Beispiele entfernen.
// Fake-Speicher im Arbeitsspeicher, Uhr auf Montag 2026-10-12.
import Foundation

enum SampleDayChecks {
  static func succeeded<T>(_ r: ToolResult<T>) -> Bool {
    if case .ok = r { return true }
    return false
  }

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Beispiel-Tag: legt drei Aufgaben, eine Notiz und einen Termin 14:00–14:30 heute an") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addTask(title: "Eigene Aufgabe", notes: nil, due: nil)
        let seeded = await svc.seedSampleDay()
        try expect(succeeded(seeded), "Anlegen sollte gelingen")
        let st = await svc.state()
        try expectEqual(st.tasks.filter { SampleDay.isSample($0.notes) }.map(\.title), SampleDay.taskTitles)
        try expectEqual(st.notes.filter { SampleDay.isSample($0.content) }.count, 1)
        let events = await svc.listEvents(from: "2026-10-12", to: "2026-10-13")
        let e = try expectNotNil(events.first { SampleDay.isSample($0.notes) }, "Beispiel-Termin fehlt")
        try expectEqual(e.start, "2026-10-12T14:00")
        try expectEqual(e.end, "2026-10-12T14:30")
      },
      CheckCase("Beispiel-Tag: zweimal anlegen verdoppelt nichts") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.seedSampleDay()
        _ = await svc.seedSampleDay()
        let st = await svc.state()
        try expectEqual(st.tasks.count, 3)
        try expectEqual(st.notes.count, 1)
        let count = await svc.listEvents(from: "2026-10-12", to: "2026-10-13").count
        try expectEqual(count, 1)
      },
      CheckCase("Beispiel-Tag: Entfernen löscht nur die Beispiele, echte Einträge bleiben") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addTask(title: "Eigene Aufgabe", notes: nil, due: nil)
        _ = await svc.addNote(title: "Meine Notiz", content: "Nichts Besonderes")
        _ = await svc.addEvent(AddEventRequest(event: NewEvent(title: "Echt", start: "2026-10-12T10:00",
                                                               end: "2026-10-12T11:00")))
        _ = await svc.seedSampleDay()
        let found = await svc.hasSampleDay()
        try expect(found, "Beispiele sollten erkannt werden")
        let removed = await svc.removeSampleDay()
        try expect(succeeded(removed), "Entfernen sollte gelingen")
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Eigene Aufgabe"])
        try expectEqual(st.notes.map(\.title), ["Meine Notiz"])
        let events = await svc.listEvents(from: "2026-10-12", to: "2026-10-13")
        try expectEqual(events.map(\.title), ["Echt"])
        let stillThere = await svc.hasSampleDay()
        try expect(!stillThere, "nach dem Entfernen keine Beispiele mehr")
      },
      CheckCase("Beispiel-Tag: eigener Eintrag mit „[Beispiel]“ bleibt beim Entfernen erhalten, Ids werden vergessen") {
        let rig = try IntegrationRig()
        let svc = rig.svc
        _ = await svc.addTask(title: "Mit Marker", notes: "[Beispiel] selbst geschrieben", due: nil)
        _ = await svc.seedSampleDay()
        try expectEqual(svc.sampleDayIds().tasks.count, 3, "drei Aufgaben gemerkt")
        _ = await svc.removeSampleDay()
        let st = await svc.state()
        try expectEqual(st.tasks.map(\.title), ["Mit Marker"], "nur der eigene Eintrag bleibt")
        try expect(svc.sampleDayIds().isEmpty, "Ids vergessen")
        let stillMarked = await svc.hasSampleDay()
        try expect(!stillMarked, "kein Beispiel mehr gemerkt")
      },
      CheckCase("Beispiel-Tag: Marker erkennt nur Texte mit [Beispiel]") {
        try expect(SampleDay.isSample("x [Beispiel] y"), "Marker")
        try expect(!SampleDay.isSample("Normale Notiz"), "ohne Marker")
        try expect(!SampleDay.isSample(nil), "nil")
        let w = SampleDay.eventWindow(day: "2026-10-12")
        try expectEqual(w.start, "2026-10-12T14:00")
        try expectEqual(w.end, "2026-10-12T14:30")
      },
    ]
  }
}
