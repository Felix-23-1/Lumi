// Paket „Kontakte“ im Kern: Suche für Werkzeuge und Oberfläche, Geburtstage heute für Tagesstart
// und Heute-Tab. Die Kontakte liest nur `contactsBackend` (Apple Kontakte oder Attrappe).
import Foundation

extension CoreServices {
  /// Suche über die Kontakte. Fragt bei der ersten ausdrücklichen Nutzung nach der Freigabe.
  public func contactSearch(_ query: String) async -> ToolResult<[ContactCard]> {
    await ContactLookup.search(contactsBackend, query)
  }

  /// Kontakte nach Name, Firma oder E-Mail (höchstens 10). Ohne Freigabe leer.
  public func findContacts(_ query: String) async -> [ContactCard] {
    await contactSearch(query).value ?? []
  }

  /// Geburtstage heute. Nur mit schon erteilter Freigabe; höchstens einmal am Tag gelesen.
  func todaysBirthdays() async -> [ContactCard] {
    await birthdayToday.cards()
  }
}
