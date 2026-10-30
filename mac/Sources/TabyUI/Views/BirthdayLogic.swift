// Geburtstag für den Partyhut: Eingabe "TT.MM." wird als "MM-DD" gespeichert
// (leer = kein Geburtstag). Rein, prüfbar in NetworkChecks.swift.
import Foundation

enum BirthdayLogic {
  static let hint = "Geburtstag (TT.MM.)"
  static let placeholder = "z. B. 24.12."
  static let invalidMessage = "Bitte so eingeben: TT.MM., z. B. 24.12."

  private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

  /// "24.12." → "12-24"; leer → "" (kein Geburtstag); alles andere → nil.
  static func storedValue(_ input: String) -> String? {
    let t = input.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return "" }
    let parts = t.split(separator: ".", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let day = Int(parts[0]), let month = Int(parts[1]),
          (1...12).contains(month), (1...daysInMonth[month - 1]).contains(day) else { return nil }
    return String(format: "%02d-%02d", month, day)
  }

  /// "12-24" → "24.12."; leer oder ungültig → "".
  static func displayValue(_ stored: String) -> String {
    let parts = stored.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 2, (1...12).contains(parts[0]), (1...daysInMonth[parts[0] - 1]).contains(parts[1]) else {
      return ""
    }
    return String(format: "%02d.%02d.", parts[1], parts[0])
  }

  /// Hinweis unter dem Feld; nil, wenn die Eingabe gilt (auch leer).
  static func validationMessage(_ input: String) -> String? {
    storedValue(input) == nil ? invalidMessage : nil
  }
}
