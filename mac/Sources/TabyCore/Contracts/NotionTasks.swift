// VERTRAG (nur Orchestrator ändert). Paket 9: Notion-Aufgaben-Import.
//
// Regel (docs/decisions/0009-notion-tasks.md): Lumi liest aus Notion nur mit
// GET bzw. Abfrage-POST (lesend); es gibt KEINEN Aufruf, der etwas in Notion
// ändert. Importierte Zeilen/To-dos werden als eigene Lumi-Aufgaben kopiert,
// damit Planung (Paket 4) und Löschen normal funktionieren, ohne je nach
// Notion zurückzuschreiben.
import Foundation

/// Stand des letzten Notion-Aufgaben-Abgleichs.
public struct NotionTaskSync: Codable, Equatable, Sendable {
  public var lastSyncAt: String?
  public var lastError: String?
  public var importedCount: Int
  public init(lastSyncAt: String? = nil, lastError: String? = nil, importedCount: Int = 0) {
    self.lastSyncAt = lastSyncAt; self.lastError = lastError; self.importedCount = importedCount
  }
}

/// Paket 11: Art einer Notion-Quelle – bestimmt sowohl den Unterreiter im
/// Notion-Reiter als auch, ob `link` als Datenbank (Zeilen) oder Seite
/// (To-do-Blöcke) gelesen wird. "weekly": mehrere Quellen dieser Kategorie
/// sind normal (eine Seite je Woche) – keine eigene Mehrfach-Logik nötig,
/// der Nutzer legt pro Woche einfach eine weitere Quelle an.
public enum NotionSourceCategory: String, Codable, Equatable, Sendable, CaseIterable {
  case tickets, todos, weekly

  public var title: String {
    switch self {
    case .tickets: "Tickets"
    case .todos: "To-dos"
    case .weekly: "Weekly"
    }
  }

  /// Datenbank (Zeilen) nur für Tickets; alles andere ist eine Seite (To-do-Blöcke).
  public var isDatabase: Bool { self == .tickets }
}

/// Eine benannte, vom Nutzer eingerichtete Notion-Quelle (Paket 11, löst die
/// alten Einzelfelder `notionTasksDatabaseId`/`notionTasksPageId` ab).
/// Ein Notion-Zugang (Arbeitsbereich) mit eigenem Zugangscode im Schlüsselbund (`notion-<id>`).
/// Er gehört zu genau einer Aufgaben-Kategorie: alle Aufgaben seiner Quellen zählen dorthin und
/// erscheinen in keiner anderen (Arbeit und Privat bleiben getrennt).
public struct NotionAccount: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// Anzeigename, z. B. „Geschäftlich“ oder „Privat“.
  public var name: String
  /// `TaskCategoryDef.id`, z. B. "arbeit".
  public var categoryId: String
  public init(id: String, name: String, categoryId: String) {
    self.id = id; self.name = name; self.categoryId = categoryId
  }
  /// Der bisherige einzelne Zugang (Altbestand und Standard), Kategorie Arbeit.
  public static let legacyId = "notion"
  public static let legacy = NotionAccount(id: legacyId, name: "Notion", categoryId: "arbeit")
}

public struct NotionSource: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var category: NotionSourceCategory
  /// Roh-Eingabe des Nutzers: reine ID oder komplette eingefügte Notion-URL.
  public var link: String
  /// `NotionAccount.id`; ältere Quellen gehören zum Zugang "notion".
  public var accountId: String
  public init(id: String, name: String, category: NotionSourceCategory, link: String,
              accountId: String = NotionAccount.legacyId) {
    self.id = id; self.name = name; self.category = category; self.link = link; self.accountId = accountId
  }

  enum CodingKeys: String, CodingKey { case id, name, category, link, accountId }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    category = try c.decode(NotionSourceCategory.self, forKey: .category)
    link = try c.decode(String.self, forKey: .link)
    accountId = try c.decodeIfPresent(String.self, forKey: .accountId) ?? NotionAccount.legacyId
  }
}

/// Paket 11: Ticket-Metadaten aus Notion für die Listenzeile. Fehlende Werte = nil
/// (z. B. ohne Integrations-Berechtigung „Benutzerinformationen lesen“ kein Name).
public struct NotionTaskMeta: Codable, Equatable, Sendable {
  /// Erstellzeit der Notion-Seite, lokal zonenlos ("YYYY-MM-DDTHH:mm").
  public var createdAt: String?
  /// Anzeigename des Erstellers.
  public var createdBy: String?
  /// Wert der ersten Status-Eigenschaft (z. B. "In Bearbeitung").
  public var status: String?
  public init(createdAt: String? = nil, createdBy: String? = nil, status: String? = nil) {
    self.createdAt = createdAt; self.createdBy = createdBy; self.status = status
  }
  public var isEmpty: Bool { createdAt == nil && createdBy == nil && status == nil }
}

/// Paket 11: Textformat des importierten Notion-Seiteninhalts (in `TabyTask.notes`),
/// gemeinsame Absprache zwischen Kern (Erzeugen) und Oberfläche (Darstellen).
/// Eine Zeile je Block; zwei Leerzeichen Einzug je Verschachtelungsebene, dann:
/// - Überschrift: `# ` (heading_1), `## ` (heading_2), `### ` (heading_3 und heading_4)
/// - Aufzählung `• `, Nummerierung `<n>. `, To-do `☐ ` / `☑ `, Zitat `> `,
///   Trenner `—`, Unterseite `↳ `, Toggle `▸ ` (Kinder folgen eingerückt)
/// - sonst Fließtext (paragraph, callout, code)
public enum NotionBodyFormat {
  public static let indent = "  "
}
