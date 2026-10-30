// Prüfungen für das Paket Kontakte: Suche, Freigabe, Geburtstage, Mehrdeutigkeit bei
// send_mail / send_message, find_contact über den echten Dispatcher und der Briefing-Satz.
// Kontakte kommen aus einer Attrappe; Zeit aus einer steuerbaren Uhr.
import Foundation

/// Dienste für die Werkzeuge: Unterhaltungen und Kontakte; der Rest ist nicht nötig.
private final class ContactsFakeServices: AssistantToolServices {
  let backend: ContactsBackend
  let conversationList: [MessengerConversation]

  init(backend: ContactsBackend, conversations: [MessengerConversation] = []) {
    self.backend = backend
    self.conversationList = conversations
  }

  func conversations() async -> [MessengerConversation] { conversationList }
  func messages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]> {
    .failure(code: "NICHT_GENUTZT", error: "Nicht Teil dieser Prüfung")
  }
  func send(_ conversationId: String, text: String) async -> ToolResult<Empty> {
    .failure(code: "NICHT_GENUTZT", error: "Nicht Teil dieser Prüfung")
  }
  func startFocus(taskId: String?, minutes: Int?) async -> ToolResult<FocusSession> {
    .failure(code: "NICHT_GENUTZT", error: "Nicht Teil dieser Prüfung")
  }
  func stopFocus() async {}
  func planDay() async -> ToolResult<DayPlan> {
    .failure(code: "NICHT_GENUTZT", error: "Nicht Teil dieser Prüfung")
  }
  func whatNow() async -> ToolResult<WhatNowPick> {
    .failure(code: "NICHT_GENUTZT", error: "Nicht Teil dieser Prüfung")
  }
  func contactSearch(_ query: String) async -> ToolResult<[ContactCard]> {
    await ContactLookup.search(backend, query)
  }
}

enum ContactsChecks {
  static let anna = ContactCard(id: "c1", name: "Anna Beispiel", organization: "Muster GmbH",
                                emails: ["anna@example.com"], phones: ["+49 30 1234-56"], birthday: "10-15")
  static let annaMueller = ContactCard(id: "c2", name: "Anna Müller", emails: ["mueller@example.org"],
                                       birthday: "1990-03-02")
  static let bruno = ContactCard(id: "c3", name: "Bruno Ohne Mail", phones: [], birthday: nil)
  static let all = [anna, annaMueller, bruno]
  static let convAnna = MessengerConversation(id: "acc|r1", accountId: "acc", title: "Anna Beispiel", isDirect: true)
  static let convMueller = MessengerConversation(id: "acc|r2", accountId: "acc", title: "Anna Müller", isDirect: true)

  static func failureCode(_ error: Error) -> String? {
    (error as? ContactLookupFailure)?.json["code"]?.stringValue
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Kontakte: Suche über Name, Firma und E-Mail, ohne Akzente und Groß/Klein") {
        try expectEqual(ContactSearch.search(all, query: "muster").map(\.id), ["c1"], "Firma")
        try expectEqual(ContactSearch.search(all, query: "MULLER").map(\.id), ["c2"], "Akzent und Groß/Klein")
        try expectEqual(ContactSearch.search(all, query: "example.org").map(\.id), ["c2"], "E-Mail")
        try expectEqual(ContactSearch.search(all, query: "   ").map(\.id), [], "leere Suche")
      },
      CheckCase("Kontakte: höchstens 10 Treffer") {
        let many = (1...12).map { ContactCard(id: "t\($0)", name: "Test \($0)") }
        try expectEqual(ContactSearch.search(many, query: "test").count, 10)
      },
      CheckCase("Kontakte: ohne Freigabe ACCESS-Fehler mit dem Hinweis für den Nutzer") {
        let denied = FakeContactsBackend(contacts: all, granted: false)
        let r = await ContactLookup.search(denied, "Anna")
        try expectEqual(r.errorMessage, "Kein Zugriff auf Kontakte – Systemeinstellungen → Datenschutz → Kontakte.")
        if case .failure(let code, _) = r { try expectEqual(code, "ACCESS") } else { throw fail("kein Fehler") }
      },
      CheckCase("find_contact: ohne Freigabe leer mit Hinweis, mit Freigabe Treffer mit Kurzform") {
        let clock = ControllableClock("2026-10-15T08:00")
        let store = try Store.inMemory(clock: clock)
        let denied = ContactsFakeServices(backend: FakeContactsBackend(contacts: all, granted: false))
        let off = await ToolRegistry.execute(name: "find_contact", args: ["query": "Anna"],
                                             ctx: ToolContext(store: store, services: denied))
        try expectEqual(off["ok"]?.boolValue, true, "ohne Freigabe ist die Abfrage ok, nur leer")
        try expectEqual(off["hinweis"]?.stringValue, ContactTools.noAccessHint)
        if case .array(let none)? = off["contacts"] { try expectEqual(none.count, 0) } else { throw fail("contacts fehlt") }

        let granted = ContactsFakeServices(backend: FakeContactsBackend(contacts: all))
        let on = await ToolRegistry.execute(name: "find_contact", args: ["query": "Anna"],
                                            ctx: ToolContext(store: store, services: granted))
        try expectEqual(on["ok"]?.boolValue, true)
        if case .array(let found)? = on["contacts"] {
          try expectEqual(found.count, 2)
          try expect(found.allSatisfy { $0["emails"] == nil && $0["phones"] == nil },
                     "Datenschutz: keine Adressen und Telefonnummern an das Modell")
        } else { throw fail("contacts fehlt") }
      },
      CheckCase("Geburtstage: nur der heutige Tag, MM-TT und JJJJ-MM-TT") {
        try expectEqual(ContactSearch.birthdays(all, day: "2026-10-15").map(\.id), ["c1"])
        try expectEqual(ContactSearch.birthdays(all, day: "2024-03-02").map(\.id), ["c2"])
        try expectEqual(ContactSearch.birthdays(all, day: "2026-10-16").map(\.id), [])
      },
      CheckCase("Geburtstage: höchstens einmal am Tag gelesen, am nächsten Tag neu") {
        let clock = ControllableClock("2026-10-15T08:00")
        let backend = FakeContactsBackend(contacts: all)
        let today = BirthdayToday(backend: backend, clock: clock)
        let got1 = (await today.cards()).map(\.id)
        try expectEqual(got1, ["c1"])
        let got2 = (await today.cards()).map(\.id)
        try expectEqual(got2, ["c1"])
        try expectEqual(backend.readCount, 1, "zweiter Aufruf am selben Tag liest nicht erneut")
        clock.advance(seconds: 86_400)
        let got3 = (await today.cards()).map(\.id)
        try expectEqual(got3, [])
        try expectEqual(backend.readCount, 2, "neuer Tag liest neu")
      },
      CheckCase("Geburtstage: ohne Freigabe nichts und nichts gemerkt, spätere Freigabe wirkt sofort") {
        let clock = ControllableClock("2026-10-15T08:00")
        let backend = FakeContactsBackend(contacts: all, granted: false)
        let today = BirthdayToday(backend: backend, clock: clock)
        let got4 = (await today.cards()).map(\.id)
        try expectEqual(got4, [])
        try expectEqual(backend.readCount, 0, "ohne Freigabe wird nicht gelesen")
        backend.setGranted(true)
        let got5 = (await today.cards()).map(\.id)
        try expectEqual(got5, ["c1"])
      },
      CheckCase("send_mail: Name wird zur Adresse, Adressen bleiben, Mehrdeutigkeit gibt Auswahl") {
        let services = ContactsFakeServices(backend: FakeContactsBackend(contacts: all))
        let resolved = try await ContactTools.resolve(
          "send_mail", ["to": ["Anna Beispiel", "x@y.de"], "subject": "Hi", "body": "Text"], services: services)
        try expectEqual(resolved["to"], .array([.string("anna@example.com"), .string("x@y.de")]))

        do {
          _ = try await ContactTools.resolve("send_mail", ["to": ["Anna"], "subject": "Hi", "body": "x"],
                                             services: services)
          throw fail("Mehrdeutigkeit wurde nicht gemeldet")
        } catch let f as ContactLookupFailure {
          try expectEqual(f.json["code"]?.stringValue, "AMBIGUOUS")
          if case .array(let candidates)? = f.json["candidates"] { try expectEqual(candidates.count, 2) }
          else { throw fail("Auswahl fehlt") }
        }
        do {
          _ = try await ContactTools.resolve("send_mail", ["to": ["Niemand"], "subject": "Hi", "body": "x"],
                                             services: services)
          throw fail("unbekannter Name wurde nicht gemeldet")
        } catch let f as ContactLookupFailure {
          try expectEqual(f.json["code"]?.stringValue, "NOT_FOUND")
        }
        do {
          _ = try await ContactTools.resolve("send_mail", ["to": ["Bruno Ohne Mail"], "subject": "Hi", "body": "x"],
                                             services: services)
          throw fail("Kontakt ohne Adresse wurde nicht gemeldet")
        } catch let f as ContactLookupFailure {
          try expectEqual(f.json["code"]?.stringValue, "NO_EMAIL")
        }
      },
      CheckCase("send_mail: ohne Freigabe kommt der Hinweis zurück, nichts wird aufgelöst") {
        let services = ContactsFakeServices(backend: FakeContactsBackend(contacts: all, granted: false))
        do {
          _ = try await ContactTools.resolve("send_mail", ["to": ["Anna Beispiel"], "subject": "Hi", "body": "x"],
                                             services: services)
          throw fail("ohne Freigabe kam kein Fehler")
        } catch let f as ContactLookupFailure {
          try expectEqual(f.json["code"]?.stringValue, "ACCESS")
          try expectEqual(f.json["error"]?.stringValue, ContactTools.noAccessHint)
        }
      },
      CheckCase("send_message: Name wird zur Unterhaltung, bekannte IDs bleiben") {
        let services = ContactsFakeServices(backend: FakeContactsBackend(contacts: all),
                                            conversations: [convAnna, convMueller])
        let byName = try await ContactTools.resolve("send_message", ["conversation_id": "Anna Beispiel", "text": "Hi"],
                                                    services: services)
        try expectEqual(byName["conversation_id"], .string("acc|r1"))
        let byId = try await ContactTools.resolve("send_message", ["conversation_id": "acc|r2", "text": "Hi"],
                                                  services: services)
        try expectEqual(byId["conversation_id"], .string("acc|r2"))
        do {
          _ = try await ContactTools.resolve("send_message", ["conversation_id": "Bruno Ohne Mail", "text": "Hi"],
                                             services: services)
          throw fail("Kontakt ohne Unterhaltung wurde nicht gemeldet")
        } catch let f as ContactLookupFailure {
          try expectEqual(f.json["code"]?.stringValue, "NOT_FOUND")
        }
      },
      CheckCase("Telefon-Links: Ziffern und führendes Plus, ohne Ziffern kein Link") {
        try expectEqual(ContactSearch.link(scheme: "tel", phone: "+49 30 1234-56")?.absoluteString, "tel:+4930123456")
        try expectEqual(ContactSearch.link(scheme: "facetime", phone: "(030) 99")?.absoluteString, "facetime:03099")
        try expect(ContactSearch.link(scheme: "tel", phone: "abc") == nil, "ohne Ziffern darf kein Link entstehen")
      },
      CheckCase("Briefing: Geburtstag steht in den Stichpunkten und im Ersatztext") {
        let facts = BriefingBuilder.facts(Overview.empty, birthdays: ["Anna Beispiel"])
        try expect(facts.contains("Geburtstag: Anna Beispiel"), "Stichpunkt fehlt: \(facts)")
        let fallback = BriefingBuilder.fallbackText(Overview.empty, birthdays: ["Anna Beispiel"])
        try expect(fallback.contains("Geburtstag: Anna Beispiel."), "Ersatztext fehlt: \(fallback)")
        let offline = try await BriefingBuilder.build(Overview.empty, llm: nil, birthdays: ["Anna Beispiel"])
        try expect(!offline.generatedByModel && offline.text.contains("Geburtstag: Anna Beispiel."), "ohne Modell fehlt die Zeile")
        try expect(!BriefingBuilder.facts(Overview.empty).contains("Geburtstag"), "ohne Geburtstag keine Zeile")
      },
      CheckCase("Datenschutz: Geburtstage gehen nicht in den Cloud-Prompt, nur ins lokale Modell") {
        let cloud = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "Briefing: Ok."))])
        _ = try await BriefingBuilder.build(Overview.empty, llm: cloud, birthdays: ["Anna Beispiel"])
        let sent = cloud.requests.flatMap { $0.messages }.compactMap(\.content).joined()
        try expect(!sent.contains("Anna Beispiel"), "Geburtstag im Cloud-Prompt: \(sent)")
        let local = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "Briefing: Ok."))])
        _ = try await BriefingBuilder.build(Overview.empty, llm: local, birthdays: ["Anna Beispiel"], birthdaysToModel: true)
        let localSent = local.requests.flatMap { $0.messages }.compactMap(\.content).joined()
        try expect(localSent.contains("Geburtstag: Anna Beispiel"), "lokales Modell bekommt die Zeile")
      },
    ]
  }
}
