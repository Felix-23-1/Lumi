// Kontakte für das Modell: find_contact, und Personennamen bei send_mail / send_message werden
// vor der Bestätigungskarte in Adresse bzw. Unterhaltung umgesetzt. Mehrdeutig oder unbekannt →
// Fehler mit Auswahl, nichts wird gesendet. Kontaktdaten sind persönlich: Ausgaben bleiben kurz.
import Foundation

/// Ein Auflösungsfehler als fertiges Werkzeug-Ergebnis.
struct ContactLookupFailure: Error {
  let json: JSONValue
}

public enum ContactTools {
  public static let noAccessHint = "Kein Zugriff auf Kontakte – Systemeinstellungen → Datenschutz → Kontakte."

  public static let defs: [ToolDef] = [
    ToolDef(name: "find_contact",
            description: "Sucht Kontakte nach Name, Firma oder E-Mail (höchstens 10). Liefert nur Name und Firma; Adressen setzt Lumi beim Senden lokal ein, du brauchst sie nicht.",
            parameters: ToolSchema.object(["query": ToolSchema.string("Name, Firma oder E-Mail")], required: ["query"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "find_contact": { ctx, args in
      let query = try args.requireString("query")
      guard let s = ctx.services else {
        return ToolJSON.failure(code: "UNAVAILABLE", error: "Dieser Dienst ist in der App gerade nicht verbunden.")
      }
      switch await s.contactSearch(query) {
      case .ok(let cards):
        return ToolJSON.ok(["contacts": .array(cards.map { ContactTools.entry($0) }), "count": .number(Double(cards.count)),
                            "note": .string(ForeignContent.note)])
      case .failure(let code, let error) where code == "ACCESS":
        // Ohne Freigabe leer, mit ehrlichem Hinweis für den Nutzer.
        return ToolJSON.ok(["contacts": .array([]), "count": .number(0), "hinweis": .string(error)])
      case .failure(let code, let error):
        return ToolJSON.failure(code: code, error: error)
      }
    },
  ]

  /// Vor der Bestätigungskarte: Personennamen in `to` (send_mail) bzw. `conversation_id` (send_message)
  /// umsetzen. Adressen und echte Unterhaltungs-IDs bleiben, wie sie sind.
  static func resolve(_ name: String, _ args: JSONValue, services: AssistantToolServices) async throws -> JSONValue {
    guard case .object(var fields) = args else { return args }
    let lookup: (String) async -> ToolResult<[ContactCard]> = { await services.contactSearch($0) }
    switch name {
    case "send_mail":
      guard case .array(let items)? = fields["to"] else { return args }
      let strings = items.compactMap { $0.stringValue }
      guard strings.count == items.count else { return args }  // Validierung übernimmt das Werkzeug
      let addresses = try await resolveRecipients(strings, lookup: lookup)
      fields["to"] = .array(addresses.map { JSONValue.string($0) })
    case "send_message":
      guard let target = fields["conversation_id"]?.stringValue, !target.isEmpty else { return args }
      let conversations = await services.conversations()
      let id = try await resolveConversation(target, conversations: conversations, lookup: lookup)
      fields["conversation_id"] = .string(id)
    default:
      return args
    }
    return .object(fields)
  }

  /// Namen → E-Mail-Adresse des Kontakts; Adressen (mit @) bleiben unverändert.
  static func resolveRecipients(_ to: [String], lookup: (String) async -> ToolResult<[ContactCard]>) async throws -> [String] {
    var out: [String] = []
    for item in to {
      let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.contains("@") {
        out.append(text)
        continue
      }
      let card = try await pick(text, lookup: lookup)
      guard let email = card.emails.first else {
        throw lookupFailure("NO_EMAIL", "„\(card.name)“ hat in den Kontakten keine E-Mail-Adresse.")
      }
      out.append(email)
    }
    return out
  }

  /// Unterhaltung für einen Namen: zuerst ein Titel, der genau so heißt; sonst der Kontakt und seine Unterhaltung.
  static func resolveConversation(_ target: String, conversations: [MessengerConversation],
                                  lookup: (String) async -> ToolResult<[ContactCard]>) async throws -> String {
    if conversations.contains(where: { $0.id == target }) { return target }
    let byTitle = conversations.filter { ContactSearch.sameName($0.title, target) }
    if byTitle.count == 1 { return byTitle[0].id }
    let card = try await pick(target, lookup: lookup)
    let matches = conversations.filter { ContactSearch.sameName($0.title, card.name) }
    switch matches.count {
    case 1:
      return matches[0].id
    case 0:
      throw lookupFailure("NOT_FOUND", "Keine Unterhaltung mit „\(card.name)“ gefunden.")
    default:
      let candidates: [JSONValue] = matches.map { .object(["id": .string($0.id), "title": .string($0.title)]) }
      throw ContactLookupFailure(json: ToolJSON.failure(
        code: "AMBIGUOUS", error: "Mehrere Unterhaltungen heißen „\(card.name)“. Welche meinst du?",
        ["candidates": .array(candidates)]))
    }
  }

  /// Genau ein Kontakt zum Namen, sonst Fehler (keiner oder mehrere mit Auswahl für den Nutzer).
  static func pick(_ query: String, lookup: (String) async -> ToolResult<[ContactCard]>) async throws -> ContactCard {
    switch await lookup(query) {
    case .failure(let code, let error):
      throw ContactLookupFailure(json: ToolJSON.failure(code: code, error: error))
    case .ok(let hits):
      switch ContactSearch.choose(hits, query: query) {
      case .one(let card):
        return card
      case .none:
        throw lookupFailure("NOT_FOUND", "Kein Kontakt „\(query)“ gefunden.")
      case .many(let list):
        let candidates: [JSONValue] = list.map { JSONValue.string(display($0)) }
        throw ContactLookupFailure(json: ToolJSON.failure(
          code: "AMBIGUOUS", error: "Mehrere Kontakte passen zu „\(query)“. Welchen meinst du?",
          ["candidates": .array(candidates)]))
      }
    }
  }

  static func lookupFailure(_ code: String, _ error: String) -> ContactLookupFailure {
    ContactLookupFailure(json: ToolJSON.failure(code: code, error: error))
  }

  /// Auswahl-Text für Rückfragen: Name und Firma, nie Adresse oder Telefon (gehen an das Modell).
  static func display(_ c: ContactCard) -> String {
    c.organization.map { "\(c.name) – \($0)" } ?? c.name
  }

  /// Nur Name und Firma: Adressen und Telefonnummern bleiben lokal (send_mail/send_message lösen Namen auf).
  static func entry(_ c: ContactCard) -> JSONValue {
    .object([
      "name": .string(ForeignContent.wrap(c.name)),
      "organization": c.organization.map { JSONValue.string(ForeignContent.wrap($0)) } ?? .null,
    ])
  }
}
