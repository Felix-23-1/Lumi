// Prüfungen für EventDetector. Bezugstag ist Montag, 2024-03-04, 08:00.
import Foundation

enum EventDetectorChecks {
  private static let now = LocalTime.parse("2024-03-04T08:00")!

  private static func detect(_ text: String, now: Date = EventDetectorChecks.now) -> EventDetector.DetectedEvent? {
    EventDetector.detect(text, now: now)
  }

  static let cases: [CheckCase] = [
    CheckCase("Termin: \"morgen um 15 Uhr\" mit Standarddauer 60 Min") {
      let e = try expectNotNil(detect("Zahnarzt morgen um 15 Uhr"), "Treffer")
      try expectEqual(e.title, "Zahnarzt")
      try expectEqual(e.start, "2024-03-05T15:00")
      try expectEqual(e.end, "2024-03-05T16:00")
      try expectEqual(e.durationMinutes, 60)
    },
    CheckCase("Termin: \"am Freitag 10:30\" nimmt das nächste Freitag") {
      let e = try expectNotNil(detect("Treffen am Freitag 10:30"), "Treffer")
      try expectEqual(e.title, "Treffen")
      try expectEqual(e.start, "2024-03-08T10:30")
      try expectEqual(EventDetector.chipLabel(e), "Fr 10:30")
    },
    CheckCase("Termin: \"nächste Woche 9 Uhr 30\"") {
      let e = try expectNotNil(detect("Review nächste Woche 9 Uhr 30"), "Treffer")
      try expectEqual(e.start, "2024-03-11T09:30")
    },
    CheckCase("Termin: Dauer \"für 90 Minuten\" zählt, steht nicht im Titel") {
      let e = try expectNotNil(detect("Call morgen 10:00 für 90 Minuten"), "Treffer")
      try expectEqual(e.title, "Call")
      try expectEqual(e.end, "2024-03-05T11:30")
      try expectEqual(e.durationMinutes, 90)
    },
    CheckCase("Termin: \"2 Stunden\" ergibt 120 Minuten") {
      let e = try expectNotNil(detect("Workshop morgen 13:00, 2 Stunden"), "Treffer")
      try expectEqual(e.end, "2024-03-05T15:00")
    },
    CheckCase("Termin: Englisch \"March 5, 2030 at 3pm\"") {
      let e = try expectNotNil(detect("Meeting on March 5, 2030 at 3pm"), "Treffer")
      try expectEqual(e.start, "2030-03-05T15:00")
    },
    CheckCase("Termin: kein Treffer bei Zahlen und Preisen") {
      try expect(detect("Der Preis ist 12,50 Euro") == nil, "Preis")
      try expect(detect("Ich habe 3 Katzen und 2 Hunde") == nil, "Stückzahl")
      try expect(detect("Bestellnummer 4711") == nil, "Bestellnummer")
      try expect(detect("Bis 1000 Euro gratis") == nil, "Betrag")
    },
    CheckCase("Termin: Datum ohne Uhrzeit ist kein Termin") {
      try expect(detect("Zahnarzt morgen") == nil, "nur Tag")
      try expect(detect("Wir treffen uns am 15.10.") == nil, "nur Datum")
    },
    CheckCase("Termin: Vergangenheit wird ignoriert") {
      let late = LocalTime.parse("2024-03-04T16:00")!
      try expect(detect("Termin um 15 Uhr", now: late) == nil, "heute 15 Uhr ist vorbei")
      try expect(detect("Meeting 05.01.2020 10:00") == nil, "altes Datum")
    },
  ]
}
