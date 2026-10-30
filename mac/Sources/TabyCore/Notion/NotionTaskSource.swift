// Notion-Aufgaben-Import (Paket 9, docs/decisions/0009-notion-tasks.md):
// liest read-only aus einer Notion-Datenbank (jede Zeile eine Aufgabe) oder
// einer Notion-Seite (To-do-Blöcke, z. B. eine 1:1-Seite) und liefert sie als
// `Item`. Eine Seite kann eingebettete Datenbanken enthalten: deren Zeilen werden
// wie Datenbank-Zeilen importiert (child_database-Blöcke). NUR GET und lesende Abfrage-POSTs (Notions Query-Endpunkte ändern
// nichts) – kein PATCH/POST, das etwas in Notion schreibt oder löscht.
//
// API-Version wie NotionCalendarProvider (2026-03-11). Eigenschaften werden
// nicht per Namen konfiguriert, sondern per Notion-Typ erkannt: die erste
// "title"-Eigenschaft ist der Titel, die erste "checkbox" ist erledigt/offen,
// die Fälligkeit ist die "date"-Eigenschaft mit bevorzugtem Namen (dueDateName) – das braucht keine Feldnamen-Einstellung
// und funktioniert mit jeder Datenbank.
import Foundation

/// Erkennt eine Notion-ID in dem, was der Nutzer einfügt: die reine ID, mit
/// oder ohne Bindestriche, oder eine komplette Notion-URL (Seiten-/Datenbank-
/// Link, auch mit Arbeitsbereich-Name und „?v=…“ für eine Datenbank-Ansicht –
/// dieser View-Teil gehört NICHT zur ID und wird verworfen).
public enum NotionId {
  /// 32 Hex-Zeichen, egal ob mit Bindestrichen oder als ein Block, irgendwo im Text.
  private static let pattern = try! NSRegularExpression(
    pattern: #"(?i)\b([0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12})\b"#)

  /// Die reine ID ohne Bindestriche, oder nil, wenn im Text keine zu finden ist.
  public static func extract(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return text[range].replacingOccurrences(of: "-", with: "")
  }
}

public final class NotionTaskSource {
  public static let apiVersion = "2026-03-11"
  static let baseURL = "https://api.notion.com/v1"

  /// Eine gelesene Notion-Zeile/-To-do, bereit zum Import als Lumi-Aufgabe.
  /// Wohin Lumi Titel/Fälligkeit zurückschreiben kann: Datenbank-Zeile (Seiten-Eigenschaften),
  /// To-do-Block (nur Titel) oder anderes (nichts, z. B. Wochen-Unterseite).
  public enum WriteKind: Equatable, Sendable { case none, page, block }

  public struct Item: Equatable, Sendable {
    public var id: String
    public var writeKind: WriteKind = .none
    public var title: String
    public var done: Bool
    public var due: String?
    /// Woche (Titel der Wochen-Unterseite bzw. Datenbank-Zeile); nil ohne Woche.
    public var group: String?
    /// Inhalt der Notion-Seite der Zeile (Ticket-Text); nil, wenn nicht gelesen oder leer.
    public var body: String?
    /// Ticket-Metadaten (Erstellzeit, Ersteller, Status); nur Datenbank-Zeilen füllen sie.
    public var meta: NotionTaskMeta
    /// Name der Datums-Eigenschaft, aus der `due` gelesen wurde; nil = keine (To-dos, Wochen). Nur dorthin schreibt Lumi.
    public var dueProperty: String?
    public init(id: String, title: String, done: Bool, due: String? = nil, group: String? = nil, body: String? = nil,
                meta: NotionTaskMeta = NotionTaskMeta()) {
      self.id = id; self.title = title; self.done = done; self.due = due; self.group = group; self.body = body
      self.meta = meta
    }
  }

  /// Maximale Verschachtelung beim Lesen des Seiteninhalts (Ebenen 0, 1, 2).
  static let maxBodyLevels = 3
  /// Obergrenze für den Ticket-Text in Zeichen.
  static let maxBodyLength = 4000

  private let token: String
  private let session: URLSession
  /// Benutzer-ID → Anzeigename (nil = nicht lesbar). Eine Instanz je Abgleich, damit jeder Ersteller nur einmal abgefragt wird.
  private var userNames: [String: String?] = [:]

  public init(token: String, session: URLSession = .shared) {
    self.token = token
    self.session = session
  }

  private func request(_ path: String, method: String = "GET", body: JSONValue? = nil) -> URLRequest {
    var req = URLRequest(url: URL(string: Self.baseURL + path)!)
    req.httpMethod = method
    req.timeoutInterval = 20
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { req.httpBody = Data(body.jsonString().utf8) }
    return req
  }

  private func call(_ req: URLRequest, label: String) async throws -> JSONValue {
    let (data, http) = try await CalendarSupport.send(session, req, label: label)
    let body = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    if !(200..<300).contains(http.statusCode) || body["object"]?.stringValue == "error" {
      let detail = body["message"]?.stringValue ?? "\(http.statusCode)"
      throw CalendarError.unreachable("\(label): \(detail)")
    }
    return body
  }

  private func pathComponent(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
  }

  /// Liest den Datenbank-Namen bzw. Seitentitel – für den automatischen
  /// Quellen-Namen (Paket 11: der Unterreiter im Notion-Reiter heißt dann
  /// wie die Notion-Seite/-Datenbank selbst, ohne dass der Nutzer ihn eintippt).
  public func fetchTitle(_ id: String, isDatabase: Bool) async throws -> String? {
    if isDatabase {
      let body = try await call(request("/databases/\(pathComponent(id))"), label: "Notion-Titel lesen fehlgeschlagen")
      guard let parts = body["title"]?.arrayValue else { return nil }
      return parts.compactMap { $0["plain_text"]?.stringValue }.joined()
    }
    let body = try await call(request("/pages/\(pathComponent(id))"), label: "Notion-Titel lesen fehlgeschlagen")
    guard let props = body["properties"]?.objectValue, let titleProp = Self.firstProperty(props, type: "title") else {
      return nil
    }
    return Self.plainText(titleProp)
  }

  // MARK: Datenbank (Zeilen)

  func fetchDataSourceId(_ databaseId: String) async throws -> String {
    let body = try await call(request("/databases/\(pathComponent(databaseId))"), label: "Notion-Discovery fehlgeschlagen")
    guard let ds = body["data_sources"]?.arrayValue?.first?["id"]?.stringValue else {
      throw CalendarError.unreachable("Notion-Datenbank ohne Datenquelle – vermutlich eine verknüpfte Ansicht. Gib der Verbindung Zugriff auf die Originaldatenbank (dort ••• → Verbindungen).")
    }
    return ds
  }

  /// Liest alle (nicht archivierten) Zeilen einer Datenbank als Aufgaben. Mit `bodies` wird
  /// bei offenen Zeilen der Seiteninhalt mitgelesen (Ticket-Text); Wochen/To-dos nicht.
  public func fetchDatabase(_ databaseId: String, bodies: Bool = true) async throws -> [Item] {
    let ds = try await fetchDataSourceId(databaseId)
    // Status-Optionen einmal je Abfrage lesen; nicht lesbar → toItem erkennt den Optionsnamen.
    let status = (try? await dataSourceProperties(ds)).flatMap { Self.statusSchema($0) }
    var items: [Item] = []
    var cursor: String?
    repeat {
      var body: [String: JSONValue] = ["page_size": 100]
      if let cursor { body["start_cursor"] = .string(cursor) }
      let page = try await call(
        request("/data_sources/\(pathComponent(ds))/query", method: "POST", body: .object(body)),
        label: "Notion-Abfrage fehlgeschlagen")
      for row in page["results"]?.arrayValue ?? [] {
        guard var item = Self.toItem(row, status: status) else { continue }
        if let userId = row["created_by"]?["id"]?.stringValue {
          if userNames[userId] == nil {
            let name = await fetchUserName(userId)
            userNames[userId] = .some(name)
          }
          item.meta.createdBy = userNames[userId] ?? nil
        }
        if bodies, !item.done, let text = try? await fetchPageText(item.id), !text.isEmpty {
          item.body = text
        }
        items.append(item)
      }
      cursor = page["has_more"]?.boolValue == true ? page["next_cursor"]?.stringValue : nil
    } while cursor != nil
    return items
  }

  /// Eine Datenbank-Zeile → Aufgabe; nil, wenn keine Titel-Eigenschaft gefunden wird.
  /// Erledigt: die Checkbox, sonst die Status-Option der Gruppe „Complete“ (ohne Schema der Optionsname).
  static func toItem(_ page: JSONValue, status schema: StatusSchema? = nil) -> Item? {
    guard let pageId = page["id"]?.stringValue, let props = page["properties"]?.objectValue else { return nil }
    guard let title = firstProperty(props, type: "title").flatMap(plainText), !title.isEmpty else { return nil }
    let done: Bool
    if let checkbox = firstProperty(props, type: "checkbox") {
      done = checkbox["checkbox"]?.boolValue ?? false
    } else if let status = firstProperty(props, type: "status")?["status"] {
      let id = status["id"]?.stringValue ?? ""
      let name = (status["name"]?.stringValue ?? "").lowercased()
      done = schema.map { $0.completeIds.contains(id) } ?? StatusSchema.completeNames.contains(name)
    } else {
      done = false
    }
    // Der Name wandert ins Item, damit das Zurückschreiben genau diese Eigenschaft trifft.
    let dueName = dueDateName(props)
    let due = dueName.flatMap { props[$0]?["date"]?["start"]?.stringValue }.map(CalendarSupport.localFromISO)
    let meta = NotionTaskMeta(
      createdAt: page["created_time"]?.stringValue.map(CalendarSupport.localFromISO),
      status: firstProperty(props, type: "status")?["status"]?["name"]?.stringValue)
    var item = Item(id: pageId, title: title, done: done, due: due, meta: meta)
    item.writeKind = .page
    item.dueProperty = dueName
    return item
  }

  /// Anzeigename eines Notion-Benutzers (`GET /users/{id}`). nil bei jedem Fehler, etwa ohne
  /// Integrations-Berechtigung „Benutzerinformationen lesen“ – die Zeile bleibt dann ohne Namen.
  public func fetchUserName(_ id: String) async -> String? {
    guard let body = try? await call(request("/users/\(pathComponent(id))"), label: "Notion-Benutzer lesen fehlgeschlagen")
    else { return nil }
    return body["name"]?.stringValue
  }

  private static func firstProperty(_ props: [String: JSONValue], type: String) -> JSONValue? {
    props.values.first { $0["type"]?.stringValue == type }
  }

  private static func firstPropertyName(_ props: [String: JSONValue], type: String) -> String? {
    props.first { $0.value["type"]?.stringValue == type }?.key
  }

  /// Fälligkeits-Eigenschaft: bevorzugte Namen zuerst (ohne Groß-/Kleinschreibung), sonst alphabetisch.
  /// Nebendaten wie „Erledigt am“ oder „Created“ sind nie die Fälligkeit.
  static func dueDateName(_ props: [String: JSONValue]) -> String? {
    let preferred = ["fällig", "fälligkeit", "due", "due date", "deadline", "datum", "date", "termin"]
    let skipped = ["erledigt am", "created", "erstellt", "last edited", "abgeschlossen"]
    let names = props.filter { $0.value["type"]?.stringValue == "date" }.map(\.key)
      .filter { !skipped.contains($0.lowercased()) }
    func rank(_ name: String) -> Int { preferred.firstIndex(of: name.lowercased()) ?? preferred.count }
    return names.min { (rank($0), $0) < (rank($1), $1) }
  }

  private static func plainText(_ prop: JSONValue) -> String? {
    guard let parts = prop["title"]?.arrayValue ?? prop["rich_text"]?.arrayValue else { return nil }
    return parts.compactMap { $0["plain_text"]?.stringValue }.joined()
  }

  /// Schreibzugriff auf den Erledigt-Zustand einer importierten Zeile
  /// (docs/decisions/0009-notion-tasks.md, Nachträge „Abhaken synchron“ und „Status-Eigenschaft“):
  /// setzt NUR die Erledigt-Checkbox – oder, ohne Checkbox, NUR die Status-Eigenschaft auf die
  /// Option der Gruppe „Complete“ bzw. „To-do“. Liest zuerst die Seite, um den Feldnamen zu finden
  /// (Lumi merkt sich nur die ID). Ohne beides passiert nichts (kein Fehler).
  public func setPageChecked(_ pageId: String, checked: Bool) async throws {
    let page = try await call(request("/pages/\(pathComponent(pageId))"), label: "Notion-Seite lesen fehlgeschlagen")
    guard let props = page["properties"]?.objectValue else { return }
    if let name = Self.firstPropertyName(props, type: "checkbox") {
      _ = try await call(
        request("/pages/\(pathComponent(pageId))", method: "PATCH",
                body: ["properties": .object([name: ["checkbox": .bool(checked)]])]),
        label: "Notion-Haken setzen fehlgeschlagen")
      return
    }
    guard let name = Self.firstPropertyName(props, type: "status") else { return }
    let ds: String
    if let dataSource = page["parent"]?["data_source_id"]?.stringValue {
      ds = dataSource
    } else if let database = page["parent"]?["database_id"]?.stringValue {
      ds = try await fetchDataSourceId(database)
    } else {
      throw CalendarError.unreachable("Notion-Status: Datenbank der Zeile unbekannt")
    }
    let schema = try await dataSourceProperties(ds)
    guard let status = Self.statusSchema(schema, named: name) else {
      throw CalendarError.unreachable("Notion-Status: Optionen nicht lesbar")
    }
    let option = checked
      ? status.completeIds.first
      : (status.todoIds.first ?? status.optionIds.first { !status.completeIds.contains($0) })
    guard let option else {
      throw CalendarError.unreachable("Notion-Status: keine passende Option (Complete/To-do) gefunden")
    }
    _ = try await call(
      request("/pages/\(pathComponent(pageId))", method: "PATCH",
              body: ["properties": .object([name: ["status": ["id": .string(option)]]])]),
      label: "Notion-Status setzen fehlgeschlagen")
  }

  /// Eigenschaften-Schema der Datenquelle (`GET /data_sources/{id}`).
  private func dataSourceProperties(_ ds: String) async throws -> [String: JSONValue] {
    let body = try await call(request("/data_sources/\(pathComponent(ds))"), label: "Notion-Schema lesen fehlgeschlagen")
    return body["properties"]?.objectValue ?? [:]
  }

  /// Status-Schema der Eigenschaft `name` bzw. (ohne Namen) der ersten Status-Eigenschaft.
  static func statusSchema(_ props: [String: JSONValue], named name: String? = nil) -> StatusSchema? {
    guard let prop = name.flatMap({ props[$0] }) ?? props.values.first(where: { $0["status"] != nil }),
          prop["status"] != nil else { return nil }
    return StatusSchema(property: prop)
  }

  /// Optionen einer Status-Eigenschaft mit ihren Gruppen. Gruppen werden über ihren Namen erkannt
  /// (Notion-Standard „To-do“ / „In progress“ / „Complete“, auch deutsch oder kleingeschrieben).
  struct StatusSchema: Equatable {
    static let completeNames: Set<String> = [
      "complete", "completed", "done", "erledigt", "abgeschlossen", "fertig", "fertiggestellt", "closed", "geschlossen",
    ]
    static let todoNames: Set<String> = ["to-do", "to do", "todo", "not started", "offen", "zu erledigen", "nicht begonnen", "nicht gestartet"]

    /// Optionen der Gruppe „Complete“ in Notion-Reihenfolge; ohne solche Gruppe die Optionen mit Erledigt-Namen.
    var completeIds: [String] = []
    /// Optionen der Gruppe „To-do“ in Notion-Reihenfolge.
    var todoIds: [String] = []
    /// Alle Optionen in Notion-Reihenfolge.
    var optionIds: [String] = []

    init(property: JSONValue) {
      let status = property["status"] ?? .null
      var names: [String: String] = [:]
      for option in status["options"]?.arrayValue ?? [] {
        guard let id = option["id"]?.stringValue else { continue }
        optionIds.append(id)
        names[id] = option["name"]?.stringValue ?? ""
      }
      for group in status["groups"]?.arrayValue ?? [] {
        let name = (group["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let ids = (group["option_ids"]?.arrayValue ?? []).compactMap { $0.stringValue }
        if Self.completeNames.contains(name) { completeIds += ids }
        if Self.todoNames.contains(name) { todoIds += ids }
      }
      if completeIds.isEmpty {
        completeIds = optionIds.filter { Self.completeNames.contains((names[$0] ?? "").lowercased()) }
      }
    }
  }

  // MARK: Seite (To-do-Blöcke)

  /// Liest alle To-do-Blöcke einer Seite (z. B. 1:1-Notizen), rekursiv in verschachtelte Blöcke.
  public func fetchPageTodos(_ pageId: String) async throws -> [Item] {
    try await fetchTodoChildren(pageId)
  }

  private func fetchTodoChildren(_ blockId: String, group: String? = nil) async throws -> [Item] {
    var items: [Item] = []
    var cursor: String?
    repeat {
      var path = "/blocks/\(pathComponent(blockId))/children?page_size=100"
      if let cursor { path += "&start_cursor=\(pathComponent(cursor))" }
      let page = try await call(request(path), label: "Notion-Blöcke lesen fehlgeschlagen")
      for block in page["results"]?.arrayValue ?? [] {
        guard let type = block["type"]?.stringValue, let blockId2 = block["id"]?.stringValue else { continue }
        if type == "child_database" {
          // Eingebettete Datenbank auf der Seite: ihre Zeilen sind Aufgaben. Eine nicht
          // zugängliche Datenbank darf die ganze Seite nicht abbrechen.
          items += ((try? await fetchDatabase(blockId2, bodies: false)) ?? []).map { row in
            var row = row; row.group = group; return row
          }
          continue
        }
        if let item = Self.todoItem(block, group: group) { items.append(item) }
        if block["has_children"]?.boolValue == true {
          items += try await fetchTodoChildren(blockId2, group: group)
        }
      }
      cursor = page["has_more"]?.boolValue == true ? page["next_cursor"]?.stringValue : nil
    } while cursor != nil
    return items
  }

  /// Ein To-do-Block → Aufgabe; nil, wenn es kein To-do mit Text ist.
  private static func todoItem(_ block: JSONValue, group: String?) -> Item? {
    guard block["type"]?.stringValue == "to_do", let id = block["id"]?.stringValue, let todo = block["to_do"] else { return nil }
    let title = (todo["rich_text"]?.arrayValue ?? []).compactMap { $0["plain_text"]?.stringValue }.joined()
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var item = Item(id: id, title: title, done: todo["checked"]?.boolValue ?? false, group: group)
    item.writeKind = .block
    return item
  }

  // MARK: Ticket-Inhalt (Blöcke der Zeilen-Seite als Klartext)

  /// Klartext des Seiteninhalts (Blöcke, rekursiv bis `maxBodyLevels`), gekappt auf `maxBodyLength`.
  public func fetchPageText(_ pageId: String) async throws -> String {
    Self.finishText(try await blockText(pageId, level: 0))
  }

  /// Zeilen der Blöcke unterhalb von `blockId`; Unterblöcke eingerückt (zwei Leerzeichen je Ebene).
  private func blockText(_ blockId: String, level: Int) async throws -> String {
    var lines: [String] = []
    var cursor: String?
    var number = 0
    repeat {
      var path = "/blocks/\(pathComponent(blockId))/children?page_size=100"
      if let cursor { path += "&start_cursor=\(pathComponent(cursor))" }
      let page = try await call(request(path), label: "Notion-Inhalt lesen fehlgeschlagen")
      for block in page["results"]?.arrayValue ?? [] {
        guard let type = block["type"]?.stringValue else { continue }
        number = type == "numbered_list_item" ? number + 1 : 0
        guard let line = Self.blockLine(block, number: number) else { continue }
        // Leerzeile vor einer Überschrift (außer am Anfang), die Überschrift selbst beginnt mit ihrer Marke.
        if type.hasPrefix("heading_"), let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(line)
        if level + 1 < Self.maxBodyLevels, type != "child_page", block["has_children"]?.boolValue == true,
           let childId = block["id"]?.stringValue {
          let nested = try await blockText(childId, level: level + 1)
          lines += nested.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : NotionBodyFormat.indent + $0 }
        }
      }
      cursor = page["has_more"]?.boolValue == true ? page["next_cursor"]?.stringValue : nil
    } while cursor != nil
    return lines.joined(separator: "\n")
  }

  /// Ein Block → eine Textzeile (ohne Unterblöcke); nil für Blocktypen, die nichts zum Ticket beitragen.
  /// `number` ist die laufende Nummer einer Reihe nummerierter Listenpunkte.
  static func blockLine(_ block: JSONValue, number: Int) -> String? {
    guard let type = block["type"]?.stringValue else { return nil }
    if type == "divider" { return "—" }
    let payload = block[type]
    if type == "child_page" { return "↳ " + (payload?["title"]?.stringValue ?? "") }
    let text = (payload?["rich_text"]?.arrayValue ?? []).compactMap { $0["plain_text"]?.stringValue }.joined()
    switch type {
    case "paragraph", "callout", "code": return text
    case "toggle": return "▸ " + text
    case "heading_1": return "# " + text
    case "heading_2": return "## " + text
    case "heading_3", "heading_4": return "### " + text
    case "bulleted_list_item": return "• " + text
    case "numbered_list_item": return "\(number). " + text
    // Leere (auch nur leerzeichen-) To-dos sind Platzhalter in Notion; Import und Text überspringen sie gleich.
    case "to_do":
      guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      return (payload?["checked"]?.boolValue == true ? "☑ " : "☐ ") + text
    case "quote": return "> " + text
    default: return nil
    }
  }

  /// Mehr als zwei Leerzeilen am Stück werden auf eine Leerzeile reduziert, dann getrimmt und gekappt.
  static func finishText(_ raw: String) -> String {
    var text = raw
    while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > maxBodyLength else { return text }
    return String(text.prefix(maxBodyLength)) + "…"
  }

  // MARK: Wochen-Seite (Paket 11, Kategorie „Weekly“)

  /// Wochen-Seite: jede Unterseite (child_page) bzw. jede Zeile einer eingebetteten Datenbank
  /// ist eine Woche; deren To-dos bekommen den Titel als `group`. To-dos direkt auf der Seite
  /// haben keine Woche. Verschachtelte Blöcke (Umschalter, Spalten) werden ebenso durchsucht.
  public func fetchWeekly(_ pageId: String) async throws -> [Item] {
    try await weeklyChildren(pageId)
  }

  /// Wochen-Liste als Datenbank: je Zeile eine Woche (Zeilen-Titel), To-dos auf der Zeilen-Seite.
  public func fetchWeeklyDatabase(_ databaseId: String) async throws -> [Item] {
    await weeklyRowItems(try await fetchDatabase(databaseId, bodies: false))
  }

  private func weeklyChildren(_ blockId: String) async throws -> [Item] {
    var items: [Item] = []
    var cursor: String?
    repeat {
      var path = "/blocks/\(pathComponent(blockId))/children?page_size=100"
      if let cursor { path += "&start_cursor=\(pathComponent(cursor))" }
      let page = try await call(request(path), label: "Notion-Blöcke lesen fehlgeschlagen")
      for block in page["results"]?.arrayValue ?? [] {
        guard let type = block["type"]?.stringValue, let id = block["id"]?.stringValue else { continue }
        switch type {
        case "child_page":
          let week = block["child_page"]?["title"]?.stringValue
          if let week, !week.isEmpty {
            // Die Wochen-Unterseite selbst ist eine Aufgabe; ihr Inhalt ist der Ticket-Text.
            let body = (try? await fetchPageText(id)).flatMap { $0.isEmpty ? nil : $0 }
            items.append(Item(id: id, title: week, done: false, group: week, body: body))
          }
          items += (try? await fetchTodoChildren(id, group: week)) ?? []
        case "child_database":
          items += await weeklyRowItems((try? await fetchDatabase(id, bodies: false)) ?? [])
        default:
          if let item = Self.todoItem(block, group: nil) { items.append(item) }
          if block["has_children"]?.boolValue == true {
            items += try await weeklyChildren(id)
          }
        }
      }
      cursor = page["has_more"]?.boolValue == true ? page["next_cursor"]?.stringValue : nil
    } while cursor != nil
    return items
  }

  /// Zeilen einer Wochen-Datenbank. Woche = „<yyyy-MM-dd> · <Titel>“ mit Datum (Zeilen-Titel
  /// wiederholen sich oft), sonst der Titel. Die Zeile selbst ist immer eine Aufgabe (offene mit
  /// Seiteninhalt als Text), dazu ihre To-dos – alles in derselben Woche.
  private func weeklyRowItems(_ rows: [Item]) async -> [Item] {
    var items: [Item] = []
    for row in rows {
      let week = row.due.map { "\(LocalTime.datePart($0)) · \(row.title)" } ?? row.title
      var rowItem = row
      rowItem.group = week
      if !row.done, let text = try? await fetchPageText(row.id), !text.isEmpty { rowItem.body = text }
      items.append(rowItem)
      items += (try? await fetchTodoChildren(row.id, group: week)) ?? []
    }
    return items
  }

  /// Titel und/oder Fälligkeit einer importierten Datenbank-Zeile zurückschreiben (PATCH der Seite).
  /// Der Titel wird per Typ `title` gefunden (Notion hat nur eine). Das Datum geht NUR an
  /// `dueProperty`, die Eigenschaft, die der Import gelesen hat; ohne sie (nil) wird nichts gesendet.
  /// `setDue` true schreibt `due` (nil löscht die Fälligkeit).
  /// shortcut: Titel-Schreiben ersetzt Rich-Text-Formatierung und Erwähnungen des Titels durch Klartext.
  public func writePage(_ pageId: String, title: String?, setDue: Bool, due: String?, dueProperty: String?) async throws {
    let page = try await call(request("/pages/\(pathComponent(pageId))"), label: "Notion-Seite lesen fehlgeschlagen")
    guard let props = page["properties"]?.objectValue else { return }
    var patch: [String: JSONValue] = [:]
    if let title {
      guard let name = Self.firstPropertyName(props, type: "title") else {
        throw CalendarError.unreachable("Notion: keine Titel-Eigenschaft – Titel bleibt nur in Lumi")
      }
      patch[name] = ["title": [["type": "text", "text": ["content": .string(title)]]]]
    }
    if setDue, let dueProperty {
      guard let current = props[dueProperty], current["type"]?.stringValue == "date" else {
        throw CalendarError.unreachable("Notion: Datums-Eigenschaft nicht mehr vorhanden – Fälligkeit bleibt nur in Lumi")
      }
      patch[dueProperty] = ["date": Self.dateValue(due, existing: current["date"] ?? .null)]
    }
    guard !patch.isEmpty else { return }
    _ = try await call(
      request("/pages/\(pathComponent(pageId))", method: "PATCH", body: ["properties": .object(patch)]),
      label: "Notion-Titel/-Datum setzen fehlgeschlagen")
  }

  /// Datum-Wert für den PATCH: neuer Start; ein bestehendes Ende bleibt nur, wenn es nach dem neuen
  /// Start liegt (sonst ausdrücklich null, damit kein altes Ende stehen bleibt); `time_zone` bleibt.
  /// Mit `time_zone` geht der Start ohne Versatz (lokale Zeit in dieser Zone), sonst mit Versatz.
  static func dateValue(_ due: String?, existing: JSONValue) -> JSONValue {
    guard let due else { return .null }
    let zone = existing["time_zone"]?.stringValue
    let start = zone != nil && due.count > 10 ? String(due.prefix(16)) + ":00" : notionDate(due)
    var date: [String: JSONValue] = ["start": .string(start), "end": .null]
    if let end = existing["end"]?.stringValue, let s = isoDate(start), let e = isoDate(end), e > s {
      date["end"] = .string(end)
    }
    if let zone { date["time_zone"] = .string(zone) }
    return .object(date)
  }

  /// Notion-Datum (mit Versatz, ohne Versatz oder nur Datum) → Zeitpunkt; nil, wenn unlesbar.
  static func isoDate(_ value: String) -> Date? {
    let iso = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
      iso.formatOptions = options
      if let d = iso.date(from: value) { return d }
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    // Mit time_zone liefert/erwartet Notion lokale Zeit ohne Versatz, auch mit Sekunden.
    for format in ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                   "yyyy-MM-dd"] {
      f.dateFormat = format
      if let d = f.date(from: value) { return d }
    }
    return nil
  }

  /// Titel eines To-do-Blocks zurückschreiben (`to_do.rich_text`, Klartext).
  public func writeBlockTitle(_ blockId: String, title: String) async throws {
    _ = try await call(
      request("/blocks/\(pathComponent(blockId))", method: "PATCH",
              body: ["to_do": ["rich_text": [["type": "text", "text": ["content": .string(title)]]]]]),
      label: "Notion-Aufgabe setzen fehlgeschlagen")
  }

  /// Lokale Zeit "YYYY-MM-DDTHH:mm" → ISO 8601 mit Versatz der lokalen Zone; reine Daten bleiben Daten.
  static func notionDate(_ local: String) -> String {
    guard local.count > 10 else { return local }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    guard let date = f.date(from: String(local.prefix(16))) else { return local }
    f.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
    return f.string(from: date)
  }

  /// Einziger Schreibzugriff im Seiten-Modus: setzt `checked` an einem To-do-Block.
  public func setBlockChecked(_ blockId: String, checked: Bool) async throws {
    _ = try await call(
      request("/blocks/\(pathComponent(blockId))", method: "PATCH", body: ["to_do": ["checked": .bool(checked)]]),
      label: "Notion-Haken setzen fehlgeschlagen")
  }

  // MARK: Abgleich (rein, prüfbar)

  public struct ToUpdate: Equatable, Sendable {
    public var notionId: String
    public var taskId: String
    public var item: Item
    /// Notizen aus dem Notion-Text übernehmen? Nur wenn der Text seit dem letzten Abgleich geändert wurde.
    public var takeNotes: Bool = false
  }

  /// Stabiler Hash eines Seitentexts (FNV-1a, 64 Bit, hex): merkt, welcher Text zuletzt gelesen wurde.
  public static func textHash(_ text: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return String(h, radix: 16)
  }

  public struct Plan: Equatable, Sendable {
    public var create: [Item]
    public var update: [ToUpdate]
  }

  /// Welche Notion-Einträge neu angelegt bzw. aktualisiert werden müssen. `linked` bildet
  /// Notion-ID auf Lumi-Aufgaben-ID ab; `existingTasks` die bereits verknüpften Aufgaben.
  /// Einträge, deren Aufgabe lokal fehlt, werden neu angelegt – außer ihre Notion-ID steht in der Liste
  /// der lokal gelöschten (siehe CoreServices), die übergibt der Aufrufer bereits herausgefiltert.
  /// Notizen: Lokale Notizen bleiben stehen, außer der Notion-Text hat sich seit `lastBodyHash` geändert.
  /// Ohne gemerkten Hash gilt: nur übernehmen, wenn lokal noch keine Notiz steht.
  public static func plan(items: [Item], linked: [String: String], existingTasks: [String: TabyTask],
                          lastBodyHash: [String: String] = [:]) -> Plan {
    var create: [Item] = []
    var update: [ToUpdate] = []
    for item in items {
      guard let taskId = linked[item.id], let existing = existingTasks[taskId] else {
        create.append(item)
        continue
      }
      // Ohne gelesenen Inhalt (body nil, z. B. erledigte Zeilen) bleiben die Notizen unberührt.
      var takeNotes = false
      if let body = item.body {
        if let known = lastBodyHash[item.id] {
          takeNotes = known != textHash(body)
        } else {
          takeNotes = (existing.notes ?? "").isEmpty
        }
      }
      if existing.title != item.title || existing.due != item.due || existing.done != item.done
          || (takeNotes && existing.notes != item.body) {
        update.append(ToUpdate(notionId: item.id, taskId: taskId, item: item, takeNotes: takeNotes))
      }
    }
    return Plan(create: create, update: update)
  }
}
