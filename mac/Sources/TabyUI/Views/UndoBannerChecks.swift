// Rückgängig-Hinweis: erscheint nach einer Änderung, verschwindet von selbst, „Rückgängig“ blendet ihn sofort aus.
import SwiftUI
import TabyCore

enum UndoBannerChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Apple-Kalender wählen: Umschalten, „alle“ = leer, Rückkehr zu allen") {
        let all = ["a", "b", "c"]
        try expectEqual(AppleCalendarChoice.toggled("b", current: [], all: all), ["a", "c"])
        try expectEqual(AppleCalendarChoice.toggled("a", current: ["a", "c"], all: all), ["c"])
        try expectEqual(AppleCalendarChoice.toggled("b", current: ["a", "c"], all: all), [])
        try expectEqual(AppleCalendarChoice.toggled("c", current: ["c"], all: all), [])
      },
      CheckCase("Rückgängig-Hinweis: kommt mit der Änderung und verschwindet nach der Anzeigedauer von selbst") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        model.undoBannerDuration = 0.05
        await model.refresh()
        try expect(model.undoBannerLabel == nil, "ohne Änderung kein Hinweis")
        fake.current.undoLabel = "Aufgabe gelöscht"
        fake.current.undoLabels = ["Aufgabe gelöscht"]
        await model.refresh()
        try expectEqual(model.undoBannerLabel, "Aufgabe gelöscht")
        for _ in 0..<100 where model.undoBannerLabel != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(model.undoBannerLabel == nil, "Hinweis ist nach der Anzeigedauer weg")
        try expectEqual(model.state?.undoLabel, "Aufgabe gelöscht", "der Schritt bleibt rückgängig-bar")
      },
      CheckCase("Rückgängig-Hinweis: zweite Änderung zeigt ihn neu, „Rückgängig“ blendet ihn sofort aus") {
        let fake = FakeServices(sample: false)
        let model = AppModel(services: fake)
        model.undoBannerDuration = 30
        fake.current.undoLabel = "Aufgabe gelöscht"
        fake.current.undoLabels = ["Aufgabe gelöscht"]
        await model.refresh()
        try expectEqual(model.undoBannerLabel, "Aufgabe gelöscht")
        fake.current.undoLabel = "Notiz gelöscht"
        fake.current.undoLabels = ["Notiz gelöscht", "Aufgabe gelöscht"]
        await model.refresh()
        try expectEqual(model.undoBannerLabel, "Notiz gelöscht", "neuer Schritt ersetzt den Hinweis")
        fake.current.undoLabel = "Aufgabe gelöscht"
        fake.current.undoLabels = ["Aufgabe gelöscht"]
        await model.refresh()
        try expect(model.undoBannerLabel == nil, "nach „Rückgängig“ (Stapel wird kleiner) kein Hinweis")
      },
    ]
  }
}
