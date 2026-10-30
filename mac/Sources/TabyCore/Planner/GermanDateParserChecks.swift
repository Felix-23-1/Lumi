// Prüfungen für GermanDateParser. Bezugstag ist Montag, 2024-03-04, 08:00.
import Foundation

enum GermanDateParserChecks {
  private static func parse(_ text: String, now: String = "2024-03-04T08:00") -> (title: String, due: String?) {
    guard let date = LocalTime.parse(now) else { preconditionFailure("ungültige Zeit \(now)") }
    return GermanDateParser.parse(text, now: date)
  }

  private static func check(_ text: String, _ title: String, _ due: String?, now: String = "2024-03-04T08:00") throws {
    let r = parse(text, now: now)
    try expectEqual(r.title, title, "Titel für \"\(text)\"")
    try expectEqual(r.due, due, "Fälligkeit für \"\(text)\"")
  }

  static let cases: [CheckCase] = [
    CheckCase("Datum: heute") { try check("Zahnarzt heute", "Zahnarzt", "2024-03-04") },
    CheckCase("Datum: morgen") { try check("Milch kaufen morgen", "Milch kaufen", "2024-03-05") },
    CheckCase("Datum: übermorgen") { try check("Paket übermorgen", "Paket", "2024-03-06") },
    CheckCase("Datum: Wochentag \"am Freitag\" ist das nächste Vorkommen") {
      try check("Bericht am Freitag", "Bericht", "2024-03-08")
    },
    CheckCase("Datum: gleicher Wochentag wie heute zählt als nächste Woche") {
      try check("Sport Montag", "Sport", "2024-03-11")
    },
    CheckCase("Datum: \"am Sonntag\" von Montag aus") { try check("Essen am Sonntag", "Essen", "2024-03-10") },
    CheckCase("Datum: \"nächste Woche\" ist der Montag danach") {
      try check("Termin nächste Woche", "Termin", "2024-03-11")
    },
    CheckCase("Datum: \"nächste Woche\" von Sonntag aus ist der Montag morgen") {
      try check("Termin nächste Woche", "Termin", "2024-03-11", now: "2024-03-10T09:00")
    },
    CheckCase("Datum: \"in 3 Tagen\"") { try check("Vertrag in 3 Tagen prüfen", "Vertrag prüfen", "2024-03-07") },
    CheckCase("Datum: \"in 2 Wochen\"") { try check("Urlaub in 2 Wochen", "Urlaub", "2024-03-18") },
    CheckCase("Datum: \"15.10.\" ohne Jahr ist das kommende 15.10.") {
      try check("Steuer 15.10.", "Steuer", "2024-10-15")
    },
    CheckCase("Datum: \"15.02.\" ohne Jahr rollt auf das nächste Jahr") {
      try check("Miete 15.02.", "Miete", "2025-02-15")
    },
    CheckCase("Datum: \"15.10.2026\" mit Jahr") { try check("Abgabe 15.10.2026", "Abgabe", "2026-10-15") },
    CheckCase("Datum: ungültiger Tag (31.02.) bleibt im Titel") {
      try check("Rechnung 31.02.", "Rechnung 31.02.", nil)
    },
    CheckCase("Uhrzeit: \"um 15 Uhr\" heute") { try check("Anruf um 15 Uhr", "Anruf", "2024-03-04T15:00") },
    CheckCase("Uhrzeit: \"15:30\" mit Datum morgen") {
      try check("Termin 15:30 morgen", "Termin", "2024-03-05T15:30")
    },
    CheckCase("Uhrzeit: \"15 Uhr 30\"") { try check("Termin 15 Uhr 30", "Termin", "2024-03-04T15:30") },
    CheckCase("Datum und Uhrzeit: \"am Freitag um 10 Uhr\"") {
      try check("Arzt am Freitag um 10 Uhr", "Arzt", "2024-03-08T10:00")
    },
    CheckCase("Datum und Uhrzeit: \"15.10. um 9:15\"") {
      try check("Flug 15.10. um 9:15", "Flug", "2024-10-15T09:15")
    },
    CheckCase("Uhrzeit: ungültige Stunde 25:00 bleibt im Titel") {
      try check("Backup 25:00", "Backup 25:00", nil)
    },
    CheckCase("Ohne Treffer: Text unverändert, keine Fälligkeit") {
      try check("Milch kaufen", "Milch kaufen", nil)
    },
    CheckCase("Wortgrenze: \"Morgenstunde\" ist kein \"morgen\"") {
      try check("Morgenstunde im Park", "Morgenstunde im Park", nil)
    },
    CheckCase("Substantiv: \"am Morgen\" und \"guten Morgen\" sind kein Datum") {
      try check("Arzt am Morgen", "Arzt am Morgen", nil)
      try check("Guten Morgen Team", "Guten Morgen Team", nil)
      try check("Milch morgen", "Milch", "2024-03-05")
    },
    CheckCase("Wortgrenze: \"Donnerstagsrunde\" ist kein Wochentag") {
      try check("Donnerstagsrunde planen", "Donnerstagsrunde planen", nil)
    },
    CheckCase("Nur Phrase: Titel wird leer (Aufrufer nimmt den Originaltext)") {
      try check("morgen", "", "2024-03-05")
    },
  ]
}
