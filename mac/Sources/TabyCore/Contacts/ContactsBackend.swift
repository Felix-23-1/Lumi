// Zugriff auf die Kontakte (Apple Kontakte über CNContactStore). Nur diese Datei fasst das
// System an. Gefragt wird erst bei einer ausdrücklichen Nutzung (Suche, Senden); die Geburtstage
// lesen nur mit schon erteilter Freigabe und fragen nie nach. Prüfungen: `FakeContactsBackend`.
import Contacts
import Foundation

public protocol ContactsBackend: Sendable {
  /// Ist die Freigabe schon erteilt? Fragt nicht nach.
  func hasAccess() async -> Bool
  /// Fragt nach, wenn noch nicht entschieden (Systemdialog); liefert, ob Zugriff besteht.
  func requestAccess() async -> Bool
  /// Alle Kontakte mit Name, Firma, E-Mail, Telefon und Geburtstag. Nur nach `hasAccess() == true` aufrufen.
  func allContacts() throws -> [ContactCard]
}

public final class CNContactsBackend: ContactsBackend, @unchecked Sendable {
  private let store = CNContactStore()

  public init() {}

  public func hasAccess() async -> Bool {
    CNContactStore.authorizationStatus(for: .contacts) == .authorized
  }

  public func requestAccess() async -> Bool {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        store.requestAccess(for: .contacts) { granted, _ in continuation.resume(returning: granted) }
      }
    default:
      return false
    }
  }

  public func allContacts() throws -> [ContactCard] {
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactBirthdayKey as CNKeyDescriptor,
    ]
    var out: [ContactCard] = []
    try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
      let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
      let org = c.organizationName.isEmpty ? nil : c.organizationName
      let display = name.isEmpty ? (org ?? "") : name
      guard !display.isEmpty else { return }
      out.append(ContactCard(
        id: c.identifier, name: display, organization: org,
        emails: c.emailAddresses.map { $0.value as String },
        phones: c.phoneNumbers.map { $0.value.stringValue },
        birthday: Self.birthday(c.birthday)))
    }
    return out
  }

  /// "MM-DD", mit Jahr "JJJJ-MM-DD"; nil ohne Tag und Monat.
  static func birthday(_ dc: DateComponents?) -> String? {
    guard let dc, let m = dc.month, let d = dc.day else { return nil }
    let mmdd = String(format: "%02d-%02d", m, d)
    guard let y = dc.year else { return mmdd }
    return String(format: "%04d-", y) + mmdd
  }
}

/// Speicher-Ersatz für Kontakte: für Prüfungen und Integrationstests.
public final class FakeContactsBackend: ContactsBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var contacts: [ContactCard]
  private var granted: Bool
  private var reads = 0

  public init(contacts: [ContactCard] = [], granted: Bool = true) {
    self.contacts = contacts
    self.granted = granted
  }

  /// Wie oft die Kontaktliste gelesen wurde (für die Tageszwischenspeicherung).
  public var readCount: Int { lock.withLock { reads } }

  public func setGranted(_ value: Bool) { lock.withLock { granted = value } }

  public func hasAccess() async -> Bool { lock.withLock { granted } }

  /// Die Antwort des Nutzers im Dialog: der Test bestimmt sie über `granted`.
  public func requestAccess() async -> Bool { lock.withLock { granted } }

  public func allContacts() throws -> [ContactCard] {
    lock.withLock {
      reads += 1
      return contacts
    }
  }
}

/// Die Suche über die Freigabe: ohne Zugriff ein ACCESS-Fehler mit dem Hinweis für den Nutzer.
public enum ContactLookup {
  public static func search(_ backend: ContactsBackend, _ query: String) async -> ToolResult<[ContactCard]> {
    guard await backend.requestAccess() else { return .failure(code: "ACCESS", error: ContactTools.noAccessHint) }
    do {
      return .ok(ContactSearch.search(try backend.allContacts(), query: query))
    } catch {
      return .failure(code: "CONTACTS", error: "Kontakte konnten nicht gelesen werden.")
    }
  }
}

/// Geburtstage heute. Liest die Kontakte höchstens einmal am Tag und nur mit schon erteilter Freigabe
/// (ohne Freigabe wird nichts gemerkt, damit eine spätere Freigabe gleich wirkt).
public final class BirthdayToday {
  private let backend: ContactsBackend
  private let clock: Clock
  private var cached: (day: String, cards: [ContactCard])?

  public init(backend: ContactsBackend, clock: Clock) {
    self.backend = backend
    self.clock = clock
  }

  public func cards() async -> [ContactCard] {
    let day = LocalTime.formatDate(clock.now())
    if let cached, cached.day == day { return cached.cards }
    guard await backend.hasAccess(), let all = try? backend.allContacts() else { return [] }
    let cards = ContactSearch.birthdays(all, day: day)
    cached = (day, cards)
    return cards
  }
}
