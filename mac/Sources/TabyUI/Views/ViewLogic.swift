// Reine Anzeige-Logik der Ansichten (ohne SwiftUI), damit sie in
// ViewChecks geprüft werden kann: Aktionszeilen im Chat, Fehlertexte,
// Fälligkeits-Chips, Agenda-Gruppierung, Konflikttext, Formularprüfung.
import Foundation
import TabyCore

// MARK: - Chat

struct DisplayMessage: Equatable, Identifiable {
  let id: Int
  let role: ChatRole
  let text: String
  var isAction = false
  var isFailure = false
}

enum ChatLogic {
  /// Wandelt tool-Nachrichten in kleine, lesbare Aktionszeilen um
  /// ("Aufgabe angelegt:…"), ohne die rohe JSON-Nutzlast zu zeigen.
  /// Port von `toActionLine` (Chat.tsx), um weitere Werkzeuge ergänzt.
  static func actionLine(_ msg: ChatMessage) -> String? {
    guard msg.role == .tool else { return nil }
    guard let result = JSONValue.parse(ForeignContent.unwrap(msg.content ?? "{}")), case .object = result else { return nil }
    let ok = result["ok"]?.boolValue ?? false
    // Wartet auf Bestätigung ist kein Fehler: neutral zeigen, die Antwort folgt nach „Erlauben“.
    if !ok, result["code"]?.stringValue == "NEEDS_CONFIRMATION" {
      return "Bitte in der Notch bestätigen: \(result["summary"]?.stringValue ?? "Aktion")"
    }
    if !ok {
      return "Aktion fehlgeschlagen: \(result["error"]?.stringValue ?? "unbekannter Fehler")"
    }
    func title(_ key: String, _ field: String = "title") -> String? { result[key]?[field]?.stringValue }
    switch msg.name {
    case "add_task": return title("task").map { "Aufgabe angelegt: \($0)" }
    case "complete_task": return title("task").map { "Aufgabe erledigt: \($0)" }
    case "reopen_task": return title("task").map { "Aufgabe wieder geöffnet: \($0)" }
    case "update_task": return title("task").map { "Aufgabe geändert: \($0)" }
    case "delete_task": return "Aufgabe gelöscht"
    case "add_note": return title("note").map { "Notiz angelegt: \($0)" }
    case "update_note": return title("note").map { "Notiz geändert: \($0)" }
    case "delete_note": return "Notiz gelöscht"
    case "add_event": return title("event").map { "Termin eingetragen: \($0)" }
    case "move_event": return title("event").map { "Termin verschoben: \($0)" }
    case "delete_event": return "Termin gelöscht"
    case "schedule_job": return title("job", "name").map { "Auftrag geplant: \($0)" }
    case "cancel_job": return "Auftrag gestoppt"
    default: return nil
    }
  }

  static func display(_ messages: [ChatMessage]) -> [DisplayMessage] {
    var out: [DisplayMessage] = []
    for m in messages {
      if m.role == .system { continue }
      if let line = actionLine(m) {
        out.append(DisplayMessage(id: out.count, role: m.role, text: line, isAction: true,
                                  isFailure: line.hasPrefix("Aktion fehlgeschlagen")))
        continue
      }
      if m.role == .tool { continue }
      if let c = m.content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out.append(DisplayMessage(id: out.count, role: m.role, text: c))
      }
    }
    return out
  }

  /// Wie `errorToGerman` in Chat.tsx. nil bei Abbruch (dann zeigt der Chat
  /// "Abgebrochen." statt eines Fehlers).
  static func errorToGerman(_ error: Error) -> String? {
    if error is CancellationError { return nil }
    guard let e = error as? LlmError else { return errorText(.unknown) }
    if e.code == .cancelled { return nil }
    // Eigenes Kostenlimit (Lumi) ist kein Problem beim Anbieter – Meldung durchreichen.
    if e.code == .quota, e.message.hasPrefix("Kostenlimit") { return e.message }
    // Apple Intelligence meldet konkret, was fehlt (aus, zu lang) – durchreichen.
    if e.message.hasPrefix("Apple Intelligence") { return e.message }
    return errorText(e.code)
  }

  static func errorText(_ code: LlmErrorCode) -> String {
    switch code {
    case .auth: "Anmeldung beim Modell fehlgeschlagen. Prüfe den API-Schlüssel in den Einstellungen."
    case .quota: "Kontingent beim Modell aufgebraucht. Prüfe dein Guthaben beim Anbieter."
    case .rateLimit: "Zu viele Anfragen in kurzer Zeit. Warte kurz und versuche es erneut."
    case .network: "Keine Verbindung zum Modell. Prüfe deine Internetverbindung und die Adresse des Anbieters."
    case .noTools: "Das Modell unterstützt keine Werkzeuge. Wähle ein anderes Modell in den Einstellungen."
    case .badResponse: "Unerwartete Antwort vom Modell. Versuche es erneut."
    case .cancelled, .unknown: "Unbekannter Fehler beim Chat. Versuche es erneut oder prüfe die Einstellungen."
    }
  }

  /// Anzeigename des Modells für die Kapsel oben ("claude-sonnet-4.5").
  static func modelLabel(_ model: String) -> String {
    let trimmed = model.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "Kein Modell" }
    return String(trimmed.split(separator: "/").last ?? Substring(trimmed))
  }
}

// MARK: - Datum und Zeit (Deutsch)

enum GermanDate {
  private static let weekdays = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]
  private static let months = ["Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.",
                               "Nov.", "Dez."]

  /// Tage zwischen zwei "YYYY-MM-DD" (b − a).
  static func dayDiff(_ a: String, _ b: String) -> Int? {
    guard let da = LocalTime.parse(LocalTime.datePart(a)), let db = LocalTime.parse(LocalTime.datePart(b)) else {
      return nil
    }
    return LocalTime.calendar.dateComponents([.day], from: da, to: db).day
  }

  static func addDays(_ date: String, _ n: Int) -> String {
    guard let d = LocalTime.parse(LocalTime.datePart(date)),
          let r = LocalTime.calendar.date(byAdding: .day, value: n, to: d) else { return date }
    return LocalTime.formatDate(r)
  }

  /// "Fr., 9. Okt."
  static func short(_ date: String) -> String {
    guard let d = LocalTime.parse(LocalTime.datePart(date)) else { return date }
    let c = LocalTime.calendar.dateComponents([.weekday, .day, .month], from: d)
    return "\(weekdays[(c.weekday ?? 1) - 1]) \(c.day ?? 0). \(months[(c.month ?? 1) - 1])"
  }

  /// "Heute", "Morgen", "Gestern" oder "Fr., 9. Okt."
  static func dayLabel(_ date: String, today: String) -> String {
    switch dayDiff(today, date) {
    case 0: "Heute"
    case 1: "Morgen"
    case -1: "Gestern"
    default: short(date)
    }
  }

  /// "HH:mm" eines lokalen ISO-Strings oder nil bei reinem Datum.
  static func time(_ s: String) -> String? {
    LocalTime.isDateOnly(s) || s.count < 16 ? nil : String(s.dropFirst(11).prefix(5))
  }
}

// MARK: - Fälligkeit

enum DueKind: Equatable { case overdue, today, soon, later }

struct DueChipInfo: Equatable {
  let kind: DueKind
  let label: String
}

/// Herkunft einer Aufgabe für den Filter in der Aufgabenansicht (nur UI).
enum TaskOrigin: Equatable {
  /// Nur eigene Aufgaben (ohne Notion-Verknüpfung).
  case own
  /// Notion-Aufgaben eines Zugangs (`NotionAccount.id`).
  case account(String)
}

enum TaskLogic {
  /// Fälligkeits-Chip: überfällig (rot), heute (gelb), morgen, später.
  static func dueChip(_ due: String?, now: String) -> DueChipInfo? {
    guard let due, !due.isEmpty else { return nil }
    let today = LocalTime.datePart(now)
    let date = LocalTime.datePart(due)
    let time = GermanDate.time(due)
    let diff = GermanDate.dayDiff(today, date) ?? 0
    let overdue = diff < 0 || (diff == 0 && time != nil && due < now)
    let dayText = GermanDate.dayLabel(date, today: today)
    let label = time.map { "\(dayText) \($0)" } ?? dayText
    if overdue { return DueChipInfo(kind: .overdue, label: diff < 0 ? "Überfällig · \(GermanDate.short(date))" : label) }
    if diff == 0 { return DueChipInfo(kind: .today, label: label) }
    if diff == 1 { return DueChipInfo(kind: .soon, label: label) }
    return DueChipInfo(kind: .later, label: label)
  }

  /// Kategorie-Filter der Aufgabenansicht (Kennung): nil = alle. Zählt die Kategorie, die `TaskCategoryLogic.effective` liefert.
  static func matches(_ t: TabyTask, category: String?, folders: [TaskFolder], defs: [TaskCategoryDef],
                      notionCategories: [String: String]) -> Bool {
    category == nil || TaskCategoryLogic.effective(t, folders: folders, defs: defs, notionCategories: notionCategories) == category
  }

  /// Zahl am Reiter in der Notch: heute (überfällig plus heute fällig) und alle offenen Aufgaben.
  static func sidebarCount(todayOpen: Int, allOpen: Int) -> String { "heute \(todayOpen) · \(allOpen) offen" }

  /// Herkunfts-Filter: nil = alle. Notion-Aufgaben sind die mit einer Quellen-Verknüpfung in `sourceLinks`.
  static func matches(_ t: TabyTask, origin: TaskOrigin?, sourceLinks: [String: String], sources: [NotionSource]) -> Bool {
    switch origin {
    case nil: return true
    case .own?: return sourceLinks[t.id] == nil
    case .account(let id)?: return accountId(of: t, sourceLinks: sourceLinks, sources: sources) == id
    }
  }

  /// Zugang einer Notion-Aufgabe (über ihre Quelle); nil für eigene Aufgaben.
  static func accountId(of t: TabyTask, sourceLinks: [String: String], sources: [NotionSource]) -> String? {
    guard let sid = sourceLinks[t.id] else { return nil }
    return sources.first { $0.id == sid }?.accountId
  }

  /// Zugänge, die die Herkunfts-Zeile zeigt: nur bei einer gewählten Kategorie, und nur Zugänge dieser
  /// Kategorie mit Quellen oder Aufgaben. Unter „Alle“ gibt es keine Zeile.
  static func originAccounts(category: String?, accounts: [NotionAccount], tasks: [TabyTask],
                             sourceLinks: [String: String], sources: [NotionSource]) -> [NotionAccount] {
    guard let category else { return [] }
    let inUse = Set(tasks.compactMap { accountId(of: $0, sourceLinks: sourceLinks, sources: sources) })
    return accounts.filter { a in
      a.categoryId == category && (inUse.contains(a.id) || sources.contains { $0.accountId == a.id })
    }
  }


  /// Offene zuerst nach Fälligkeit (ohne Datum zuletzt), dann nach Anlage.
  static func sortOpen(_ tasks: [TabyTask]) -> [TabyTask] {
    // "" (entfernte Fälligkeit im Fake) zählt wie kein Datum.
    tasks.filter { !$0.done }.sorted { a, b in
      if a.priority != b.priority { return a.priority.sortRank < b.priority.sortRank }
      switch (a.due.flatMap { $0.isEmpty ? nil : $0 }, b.due.flatMap { $0.isEmpty ? nil : $0 }) {
      case let (x?, y?) where x != y: return x < y
      case (nil, _?): return false
      case (_?, nil): return true
      default: return a.createdAt < b.createdAt
      }
    }
  }

  static func sortDone(_ tasks: [TabyTask]) -> [TabyTask] {
    tasks.filter(\.done).sorted { ($0.doneAt ?? "") > ($1.doneAt ?? "") }
  }

  /// Fälligkeit aus Datum ("YYYY-MM-DD") und optionaler Uhrzeit ("HH:mm").
  static func composeDue(date: String?, time: String?) -> String? {
    guard let date, !date.isEmpty else { return nil }
    guard let time, !time.isEmpty else { return date }
    return "\(date)T\(time)"
  }

  /// Fälligkeits-Auswahl: Ohne, Heute, Morgen oder Datum (mit optionaler Uhrzeit).
  enum DueMode: Equatable { case none, today, tomorrow, custom }

  /// Vorbelegung der Auswahl aus einem gespeicherten Wert (Bearbeiten). Leer = ohne Fälligkeit.
  static func dueDraft(_ due: String?, today: String) -> (mode: DueMode, date: String?, time: String?) {
    guard let due, !due.isEmpty else { return (.none, nil, nil) }
    let date = LocalTime.datePart(due)
    let mode: DueMode = date == today ? .today : date == GermanDate.addDays(today, 1) ? .tomorrow : .custom
    return (mode, date, GermanDate.time(due))
  }

  /// Gespeicherter Wert aus Auswahl und Uhrzeit; nil = ohne Fälligkeit.
  static func dueString(_ mode: DueMode, today: String, custom: String?, time: String?) -> String? {
    let date: String?
    switch mode {
    case .none: date = nil
    case .today: date = today
    case .tomorrow: date = GermanDate.addDays(today, 1)
    case .custom: date = custom
    }
    return composeDue(date: date, time: time)
  }

  /// nil = gültig, sonst deutsche Meldung.
  static func validateTitle(_ title: String) -> String? {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bitte einen Titel eingeben." : nil
  }
}

// MARK: - Aufgaben-Ordner

enum TaskFolderLogic {
  /// Eine Gruppe in "Alle": ein Ordner, oder nil = "Ohne Ordner".
  struct Group: Equatable, Identifiable {
    let folder: TaskFolder?
    let tasks: [TabyTask]
    var id: String { folder?.id ?? "" }
    var name: String { folder?.name ?? "Ohne Ordner" }
  }

  /// Ordner-Filter: nil = alle.
  static func matches(_ t: TabyTask, folder: String?) -> Bool {
    folder == nil || t.folderId == folder
  }

  /// Offene Aufgaben im Ordner (für die Zahl am Chip).
  static func openCount(_ tasks: [TabyTask], folder: String) -> Int {
    tasks.filter { !$0.done && $0.folderId == folder }.count
  }

  /// Gruppen für "Alle": je Ordner in Ordnerreihenfolge (auch leer), zuletzt "Ohne Ordner" – nur wenn
  /// dort etwas liegt. Aufgaben mit unbekannter Ordner-ID zählen als "Ohne Ordner". Reihenfolge innen bleibt.
  static func groups(_ open: [TabyTask], folders: [TaskFolder]) -> [Group] {
    let ids = Set(folders.map(\.id))
    var result = folders.map { f in Group(folder: f, tasks: open.filter { $0.folderId == f.id }) }
    let loose = open.filter { $0.folderId == nil || !ids.contains($0.folderId ?? "") }
    if !loose.isEmpty { result.append(Group(folder: nil, tasks: loose)) }
    return result
  }
}

/// Aufgaben-Kategorien aus den Einstellungen: Zugehörigkeit, Ordner je Kategorie, Anlegen und Pflege.
/// Unbekannte Kennungen zählen als „keine Kategorie“.
enum TaskCategoryLogic {
  /// Feste Auswahl an SF-Symbolen für neue Kategorien.
  static let symbols = ["tag.fill", "briefcase.fill", "house.fill", "figure.run", "heart.fill", "book.fill",
                        "cart.fill", "star.fill", "bolt.fill", "leaf.fill", "music.note", "hammer.fill"]

  /// Namen und Kennungen höchstens so lang (wie `TaskCategoryRules.sanitize`).
  static let nameLimit = 24

  /// Kennung aus dem Namen: klein, Umlaute ausgeschrieben, sonst nur a–z, 0–9 und „-“ (höchstens 24).
  static func id(from name: String) -> String {
    let mapped = name.lowercased()
      .replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
      .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
    let plain = mapped.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let dashes = CharacterSet(charactersIn: "-")
    return String(plain.trimmingCharacters(in: dashes).prefix(nameLimit)).trimmingCharacters(in: dashes)
  }

  /// Kennung, wenn sie zu den Einstellungen gehört; sonst nil (= keine Kategorie).
  static func known(_ id: String?, defs: [TaskCategoryDef]) -> String? {
    guard let id, defs.contains(where: { $0.id == id }) else { return nil }
    return id
  }

  static func folderCategory(_ f: TaskFolder, defs: [TaskCategoryDef]) -> String? { known(f.categoryId, defs: defs) }

  /// Ordner-Name unter „Alle“, mit Kategorie in Klammern („Reise (Privat)“). Nur für die Anzeige.
  static func labelled(_ f: TaskFolder, defs: [TaskCategoryDef]) -> TaskFolder {
    guard let cat = folderCategory(f, defs: defs), let catName = defs.first(where: { $0.id == cat })?.name else { return f }
    var copy = f
    copy.name = "\(f.name) (\(catName))"
    return copy
  }

  /// Kategorie, unter der eine Aufgabe zählt. Notion-Aufgaben (Eintrag in `notionCategories`) haben nur die
  /// Kategorie ihres Zugangs, nie eine eigene. Sonst: die eigene, wenn bekannt, sonst die ihres Ordners.
  static func effective(_ t: TabyTask, folders: [TaskFolder], defs: [TaskCategoryDef],
                        notionCategories: [String: String]) -> String? {
    if let notion = notionCategories[t.id] { return known(notion, defs: defs) }
    if let own = known(t.category?.rawValue, defs: defs) { return own }
    guard let fid = t.folderId, let f = folders.first(where: { $0.id == fid }) else { return nil }
    return folderCategory(f, defs: defs)
  }

  /// Ordner einer Kategorie in Ordnerreihenfolge; nil = Ordner ohne Kategorie.
  static func folders(_ folders: [TaskFolder], in category: String?, defs: [TaskCategoryDef]) -> [TaskFolder] {
    folders.filter { folderCategory($0, defs: defs) == category }
  }

  /// Abschnitte der Aufgabenliste für eine Kategorie (nil = Alle). Je Ordner der Kategorie, zuletzt „Ohne Ordner“
  /// für den Rest. Bei Alle: alle Ordner, Rest unter „Ohne Ordner“. Aufgaben in fremden Ordnern
  /// fallen so unter „Ohne Ordner“ dieser Kategorie.
  static func groups(_ open: [TabyTask], category: String?, folders: [TaskFolder],
                     defs: [TaskCategoryDef], notionCategories: [String: String]) -> [TaskFolderLogic.Group] {
    if category == nil { return overview(open, folders: folders, defs: defs, notionCategories: notionCategories) }
    let own = self.folders(folders, in: category, defs: defs)
    let ids = Set(own.map(\.id))
    let inCat = open.filter {
      TaskLogic.matches($0, category: category, folders: folders, defs: defs, notionCategories: notionCategories)
    }
    var result = own.map { f in TaskFolderLogic.Group(folder: f, tasks: inCat.filter { $0.folderId == f.id }) }
    let loose = inCat.filter { !ids.contains($0.folderId ?? "") }
    if !loose.isEmpty { result.append(TaskFolderLogic.Group(folder: nil, tasks: loose)) }
    return result
  }

  /// „Alle“ ist eine reine Übersicht nach Kategorie (Einstellungsreihenfolge); Ordner erscheinen hier nicht.
  /// Nur Alt-Ordner ohne Kategorie behalten ihren Abschnitt, damit man sie zuordnen kann; der Rest steht unter „Ohne Kategorie“.
  static func overview(_ open: [TabyTask], folders: [TaskFolder], defs: [TaskCategoryDef],
                       notionCategories: [String: String]) -> [TaskFolderLogic.Group] {
    var result: [TaskFolderLogic.Group] = []
    var used = Set<String>()
    for d in defs {
      let tasks = open.filter { effective($0, folders: folders, defs: defs, notionCategories: notionCategories) == d.id }
      used.formUnion(tasks.map(\.id))
      if !tasks.isEmpty {
        result.append(TaskFolderLogic.Group(folder: TaskFolder(id: "cat:\(d.id)", name: d.name, createdAt: ""), tasks: tasks))
      }
    }
    for f in self.folders(folders, in: nil, defs: defs) {
      let tasks = open.filter { !used.contains($0.id) && $0.folderId == f.id }
      used.formUnion(tasks.map(\.id))
      if !tasks.isEmpty { result.append(TaskFolderLogic.Group(folder: f, tasks: tasks)) }
    }
    let rest = open.filter { !used.contains($0.id) }
    if !rest.isEmpty {
      result.append(TaskFolderLogic.Group(folder: TaskFolder(id: "cat:none", name: "Ohne Kategorie", createdAt: ""), tasks: rest))
    }
    return result
  }

  /// `TaskPatch.category` nach der Wahl im Menü: nil = schon so (nichts tun), "" = keine Kategorie.
  /// Eine unbekannte Kennung zählt als keine.
  static func categoryPatch(choice: String?, current: String?, defs: [TaskCategoryDef]) -> String? {
    if known(current, defs: defs) == choice { return nil }
    return choice ?? ""
  }

  /// Notion-Aufgabe: ihre Kategorie kommt vom Zugang und ist hier nur anzuzeigen, nicht zu ändern.
  static func isNotionTask(_ id: String, notionCategories: [String: String]) -> Bool { notionCategories[id] != nil }

  /// Fällt die Aufgabe durch das Einordnen (nach `categoryId`) aus dem gewählten Filter? Dann erscheint der Hinweis.
  static func movesOut(_ t: TabyTask, to categoryId: String?, filter: String?, folders: [TaskFolder],
                       defs: [TaskCategoryDef], notionCategories: [String: String]) -> Bool {
    guard let filter else { return false }
    var moved = t
    moved.category = categoryId.map { TaskCategory(rawValue: $0) }
    return effective(moved, folders: folders, defs: defs, notionCategories: notionCategories) != filter
  }

  /// Bezeichnung der Rückgängig-Leiste nach dem Einordnen.
  static func moveLabel(_ id: String?, defs: [TaskCategoryDef]) -> String {
    guard let id, let d = defs.first(where: { $0.id == id }) else { return "Kategorie entfernt" }
    return "In \(d.name) verschoben"
  }

  /// Neue Kategorie anhängen. Gibt den Fehlertext zurück oder nil, wenn `defs` geändert wurde.
  static func add(name: String, symbol: String, to defs: inout [TaskCategoryDef]) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let err = nameError(n) { return err }
    let newId = id(from: n)
    guard !newId.isEmpty else { return "Der Name braucht mindestens einen Buchstaben oder eine Ziffer." }
    guard !defs.contains(where: { $0.id == newId }) else { return "Die Kategorie \(n) gibt es schon." }
    guard defs.count < TaskCategoryRules.maxCount else {
      return "Höchstens \(TaskCategoryRules.maxCount) Kategorien. Lösche erst eine, um eine neue anzulegen."
    }
    defs.append(TaskCategoryDef(id: newId, name: n, symbol: symbols.contains(symbol) ? symbol : "tag.fill"))
    return nil
  }

  /// Umbenennen: die Kennung bleibt, damit Aufgaben und Ordner zugeordnet bleiben.
  static func rename(_ id: String, to name: String, in defs: inout [TaskCategoryDef]) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let err = nameError(n) { return err }
    guard let i = defs.firstIndex(where: { $0.id == id }) else { return nil }
    defs[i].name = n
    return nil
  }

  /// Nur eigene Kategorien lassen sich löschen; die eingebauten bleiben und lassen sich nur umbenennen.
  /// Eine Kategorie, zu der noch ein Notion-Zugang gehört, bleibt: erst umstellen, dann löschen.
  static func delete(_ id: String, in defs: inout [TaskCategoryDef], notionAccounts: [NotionAccount] = []) -> String? {
    guard !TaskCategoryDef.builtIn.contains(where: { $0.id == id }) else { return "Arbeit und Privat bleiben erhalten." }
    if let account = notionAccounts.first(where: { $0.categoryId == id }) {
      return "Notion-Zugang „\(account.name)“ gehört zu dieser Kategorie – stelle ihn erst um."
    }
    defs.removeAll { $0.id == id }
    return nil
  }

  /// Notion-Zugänge, deren Kategorie in der Liste fehlt: sie zählen als „ohne Kategorie“ (Hinweis in den Einstellungen).
  static func accountsWithoutCategory(_ accounts: [NotionAccount], defs: [TaskCategoryDef]) -> [NotionAccount] {
    accounts.filter { a in !defs.contains { $0.id == a.categoryId } }
  }

  /// Eigene Kategorie eine Stelle nach oben oder unten; eingebaute bleiben vorn.
  static func move(_ id: String, up: Bool, in defs: inout [TaskCategoryDef]) {
    guard let i = defs.firstIndex(where: { $0.id == id }),
          !TaskCategoryDef.builtIn.contains(where: { $0.id == id }) else { return }
    let j = up ? i - 1 : i + 1
    guard defs.indices.contains(j), !TaskCategoryDef.builtIn.contains(where: { $0.id == defs[j].id }) else { return }
    defs.swapAt(i, j)
  }

  private static func nameError(_ n: String) -> String? {
    if n.isEmpty { return "Gib der Kategorie einen Namen." }
    if n.count > nameLimit { return "Der Name darf höchstens \(nameLimit) Zeichen haben." }
    return nil
  }
}

// MARK: - Kalender

struct AgendaDay: Equatable, Identifiable {
  let date: String
  let label: String
  let events: [CalendarEvent]
  var id: String { date }
}

enum CalendarLogic {
  /// Art der Quelle aus der Quell-ID ("apple", "notion:abc", "ics-3", "local").
  static func kind(of sourceId: String, sources: [CalendarSourceConfig] = []) -> CalendarSourceKind {
    if let s = sources.first(where: { $0.id == sourceId }) { return s.kind }
    for k in CalendarSourceKind.allCases where sourceId.hasPrefix(k.rawValue) { return k }
    return .local
  }

  /// Gruppiert Termine nach Tag (aufsteigend); ganztägige zuerst, dann nach Start.
  static func agenda(_ events: [CalendarEvent], today: String) -> [AgendaDay] {
    let grouped = Dictionary(grouping: events) { LocalTime.datePart($0.start) }
    return grouped.keys.sorted().map { date in
      let sorted = grouped[date]!.sorted { a, b in
        if a.allDay != b.allDay { return a.allDay }
        if a.start != b.start { return a.start < b.start }
        return a.title < b.title
      }
      return AgendaDay(date: date, label: GermanDate.dayLabel(date, today: today), events: sorted)
    }
  }

  /// "09:30–09:45", "09:30" oder "ganztägig".
  static func timeRange(_ e: CalendarEvent) -> String {
    if e.allDay || LocalTime.isDateOnly(e.start) { return "ganztägig" }
    let s = GermanDate.time(e.start) ?? e.start
    guard let end = e.end, let t = GermanDate.time(end) else { return s }
    if LocalTime.datePart(end) != LocalTime.datePart(e.start) {
      return "\(s)–\(GermanDate.short(end)) \(t)"
    }
    return "\(s)–\(t)"
  }

  /// "„Standup“ (Heute 09:30–09:45)"
  static func describe(_ e: CalendarEvent, today: String) -> String {
    "„\(e.title)“ (\(GermanDate.dayLabel(e.start, today: today)) \(timeRange(e)))"
  }

  /// Warntext bei Konflikt (Szenario A): nennt Titel und Zeit jedes
  /// Konflikttermins; der Termin ist noch NICHT gespeichert.
  /// Nur Abstand unter dem Puffer, keine echte Überschneidung.
  static func onlyTooClose(_ conflicts: [Conflict]) -> Bool {
    !conflicts.isEmpty && conflicts.allSatisfy { $0.kind == .tooClose }
  }

  static func conflictMessage(error: String, conflicts: [Conflict], today: String, bufferMinutes: Int = 0) -> String {
    let names = conflicts.map { describe($0.with, today: today) }.joined(separator: ", ")
    // Nur "zu knapp" (Puffer), keine echte Überschneidung: eigener, klarer Satz.
    if onlyTooClose(conflicts) {
      let n = bufferMinutes > 0 ? "\(bufferMinutes)" : "dem eingestellten"
      return "Zu knapp an \(names) – weniger als \(n) Minuten Abstand."
    }
    let lead = error.trimmingCharacters(in: .whitespaces)
    let base = lead.isEmpty ? "Der Termin überschneidet sich." : lead
    return names.isEmpty ? base : "Überschneidet sich mit \(names)."
  }

  static func infoMessage(_ info: [CalendarEvent], today: String) -> String? {
    guard !info.isEmpty else { return nil }
    return "Am selben Tag ganztägig: " + info.map { "„\($0.title)“" }.joined(separator: ", ") + "."
  }

  static func unreachableMessage(_ problems: [SourceProblem]) -> String? {
    guard !problems.isEmpty else { return nil }
    return "Nicht erreichbar: " + problems.map { "\($0.id) (\($0.message))" }.joined(separator: ", ")
      + ". Termine daraus fehlen eventuell."
  }

  /// Dauer-Auswahl im Formular.
  enum Duration: Int, CaseIterable, Identifiable {
    case m30 = 30, h1 = 60, h2 = 120, allDay = 0
    var id: Int { rawValue }
    var label: String {
      switch self {
      case .m30: "30 Min"
      case .h1: "1 Std"
      case .h2: "2 Std"
      case .allDay: "Ganztägig"
      }
    }
  }

  /// Baut den neuen Termin aus Formularwerten oder liefert eine deutsche Fehlermeldung.
  static func makeEvent(title: String, date: String, time: String, duration: Duration) -> Result<NewEvent, FormError> {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return .failure(FormError("Bitte einen Titel eingeben.")) }
    guard LocalTime.parse(date) != nil, LocalTime.isDateOnly(date) else {
      return .failure(FormError("Bitte ein gültiges Datum wählen."))
    }
    if duration == .allDay { return .success(NewEvent(title: t, start: date)) }
    let start = "\(date)T\(time)"
    guard time.count == 5, let s = LocalTime.parse(start) else {
      return .failure(FormError("Bitte eine gültige Uhrzeit wählen (HH:mm)."))
    }
    let end = LocalTime.format(s.addingTimeInterval(TimeInterval(duration.rawValue * 60)))
    return .success(NewEvent(title: t, start: start, end: end))
  }
}

struct FormError: Error, Equatable {
  let message: String
  init(_ m: String) { message = m }
}

// MARK: - Einstellungen

enum SettingsLogic {
  /// Quelle, in die neue Termine tatsächlich landen (wie `CalendarRegistry.pickDefaultWrite`):
  /// markiert und an → Apple an → nil (lokaler Kalender). ICS ist nie beschreibbar.
  static func effectiveDefaultWriteId(_ sources: [CalendarSourceConfig]) -> String? {
    let on = sources.filter { $0.enabled && $0.kind != .ics }
    return (on.first { $0.isDefaultWrite } ?? on.first { $0.kind == .apple } ?? on.first { $0.kind == .local })?.id
  }

  static let personalities: [(Personality, String)] = [
    (.direkt, "Direkt"), (.ruhig, "Ruhig"), (.coach, "Coach"), (.locker, "Locker"),
  ]

  /// Nur geänderte Felder (nil = unverändert).
  static func patch(from old: TabySettings, to new: TabySettings) -> SettingsPatch {
    SettingsPatch(
      llmBaseUrl: new.llmBaseUrl != old.llmBaseUrl ? new.llmBaseUrl : nil,
      llmModel: new.llmModel != old.llmModel ? new.llmModel : nil,
      personality: new.personality != old.personality ? new.personality : nil,
      customInstructions: new.customInstructions != old.customInstructions ? new.customInstructions : nil,
      reminderLeadMinutes: new.reminderLeadMinutes != old.reminderLeadMinutes ? new.reminderLeadMinutes : nil,
      startOnLogin: new.startOnLogin != old.startOnLogin ? new.startOnLogin : nil,
      globalShortcut: new.globalShortcut != old.globalShortcut ? new.globalShortcut : nil,
      askAfterUnlock: new.askAfterUnlock != old.askAfterUnlock ? new.askAfterUnlock : nil,
      briefingModel: new.briefingModel != old.briefingModel ? new.briefingModel : nil,
      bufferMinutes: new.bufferMinutes != old.bufferMinutes ? new.bufferMinutes : nil,
      dailyCostLimitUsd: new.dailyCostLimitUsd != old.dailyCostLimitUsd ? new.dailyCostLimitUsd : nil,
      monthlyCostLimitUsd: new.monthlyCostLimitUsd != old.monthlyCostLimitUsd ? new.monthlyCostLimitUsd : nil,
      quickCaptureShortcut: new.quickCaptureShortcut != old.quickCaptureShortcut ? new.quickCaptureShortcut : nil,
      appleRemindersSync: new.appleRemindersSync != old.appleRemindersSync ? new.appleRemindersSync : nil,
      appleRemindersListId: new.appleRemindersListId != old.appleRemindersListId ? new.appleRemindersListId : nil,
      dayEndEnabled: new.dayEndEnabled != old.dayEndEnabled ? new.dayEndEnabled : nil,
      dayEndTime: new.dayEndTime != old.dayEndTime ? new.dayEndTime : nil,
      focusMinutes: new.focusMinutes != old.focusMinutes ? new.focusMinutes : nil,
      breakMinutes: new.breakMinutes != old.breakMinutes ? new.breakMinutes : nil,
      exportFolder: new.exportFolder != old.exportFolder ? new.exportFolder : nil,
      mcpEnabled: new.mcpEnabled != old.mcpEnabled ? new.mcpEnabled : nil,
      voiceEnabled: new.voiceEnabled != old.voiceEnabled ? new.voiceEnabled : nil,
      voiceBriefings: new.voiceBriefings != old.voiceBriefings ? new.voiceBriefings : nil,
      voiceAlerts: new.voiceAlerts != old.voiceAlerts ? new.voiceAlerts : nil,
      voiceName: new.voiceName != old.voiceName ? new.voiceName : nil,
      planBlockMinutes: new.planBlockMinutes != old.planBlockMinutes ? new.planBlockMinutes : nil,
      meetingCompanion: new.meetingCompanion != old.meetingCompanion ? new.meetingCompanion : nil,
      meetingLeadMinutes: new.meetingLeadMinutes != old.meetingLeadMinutes ? new.meetingLeadMinutes : nil,
      readAloudMinutes: new.readAloudMinutes != old.readAloudMinutes ? new.readAloudMinutes : nil,
      briefingPrompt: new.briefingPrompt != old.briefingPrompt ? new.briefingPrompt : nil,
      captureSelectionShortcut: new.captureSelectionShortcut != old.captureSelectionShortcut
        ? new.captureSelectionShortcut : nil,
      voiceInputShortcut: new.voiceInputShortcut != old.voiceInputShortcut ? new.voiceInputShortcut : nil,
      weeklyReviewEnabled: new.weeklyReviewEnabled != old.weeklyReviewEnabled ? new.weeklyReviewEnabled : nil,
      weeklyReviewDay: new.weeklyReviewDay != old.weeklyReviewDay ? new.weeklyReviewDay : nil,
      weeklyReviewTime: new.weeklyReviewTime != old.weeklyReviewTime ? new.weeklyReviewTime : nil,
      focusShortcutOn: new.focusShortcutOn != old.focusShortcutOn ? new.focusShortcutOn : nil,
      focusShortcutOff: new.focusShortcutOff != old.focusShortcutOff ? new.focusShortcutOff : nil,
      focusHideApps: new.focusHideApps != old.focusHideApps ? new.focusHideApps : nil,
      tabOrder: new.tabOrder != old.tabOrder ? new.tabOrder : nil,
      hiddenTabs: new.hiddenTabs != old.hiddenTabs ? new.hiddenTabs : nil,
      workHours: new.workHours != old.workHours ? new.workHours : nil,
      taskCategories: new.taskCategories != old.taskCategories ? new.taskCategories : nil,
      hiddenTickerKinds: new.hiddenTickerKinds != old.hiddenTickerKinds ? new.hiddenTickerKinds : nil,
      messengerEnabled: new.messengerEnabled != old.messengerEnabled ? new.messengerEnabled : nil,
      notchText: new.notchText != old.notchText ? new.notchText : nil,
      captureContextShortcut: new.captureContextShortcut != old.captureContextShortcut ? new.captureContextShortcut : nil,
      explainShortcut: new.explainShortcut != old.explainShortcut ? new.explainShortcut : nil,
      circleShortcut: new.circleShortcut != old.circleShortcut ? new.circleShortcut : nil,
      notionStatusMap: new.notionStatusMap != old.notionStatusMap ? new.notionStatusMap : nil,
      autoStatus: new.autoStatus != old.autoStatus ? new.autoStatus : nil,
      privateListId: new.privateListId != old.privateListId ? new.privateListId : nil,
      localOnly: new.localOnly != old.localOnly ? new.localOnly : nil,
      cloudConsentAt: new.cloudConsentAt != old.cloudConsentAt ? new.cloudConsentAt : nil,
      chatHistoryDays: new.chatHistoryDays != old.chatHistoryDays ? new.chatHistoryDays : nil,
      backupRetentionDays: new.backupRetentionDays != old.backupRetentionDays ? new.backupRetentionDays : nil,
      auditRetentionDays: new.auditRetentionDays != old.auditRetentionDays ? new.auditRetentionDays : nil,
      mcpServers: new.mcpServers != old.mcpServers ? new.mcpServers : nil,
      markdownVaultPath: new.markdownVaultPath != old.markdownVaultPath ? new.markdownVaultPath : nil,
      vaultWriteFolder: new.vaultWriteFolder != old.vaultWriteFolder ? new.vaultWriteFolder : nil,
      networkShares: new.networkShares != old.networkShares ? new.networkShares : nil,
      notionAccounts: new.notionAccounts != old.notionAccounts ? new.notionAccounts : nil,
      microsoftClientId: new.microsoftClientId != old.microsoftClientId ? new.microsoftClientId : nil,
      microsoftAccount: new.microsoftAccount != old.microsoftAccount ? new.microsoftAccount : nil,
      mailBackend: new.mailBackend != old.mailBackend ? new.mailBackend : nil,
      imapHost: new.imapHost != old.imapHost ? new.imapHost : nil,
      imapUser: new.imapUser != old.imapUser ? new.imapUser : nil,
      homeCity: new.homeCity != old.homeCity ? new.homeCity : nil,
      updateSource: new.updateSource != old.updateSource ? new.updateSource : nil,
      notchCountdown: new.notchCountdown != old.notchCountdown ? new.notchCountdown : nil,
      notionTasksEnabled: new.notionTasksEnabled != old.notionTasksEnabled ? new.notionTasksEnabled : nil,
      notionTasksDatabaseId: new.notionTasksDatabaseId != old.notionTasksDatabaseId ? new.notionTasksDatabaseId : nil,
      notionTasksPageId: new.notionTasksPageId != old.notionTasksPageId ? new.notionTasksPageId : nil,
      mailEnabled: new.mailEnabled != old.mailEnabled ? new.mailEnabled : nil,
      mailLocalOnly: new.mailLocalOnly != old.mailLocalOnly ? new.mailLocalOnly : nil,
      mailBriefing: new.mailBriefing != old.mailBriefing ? new.mailBriefing : nil,
      claudeNotify: new.claudeNotify != old.claudeNotify ? new.claudeNotify : nil,
      networkToolsEnabled: new.networkToolsEnabled != old.networkToolsEnabled ? new.networkToolsEnabled : nil,
      networkWatch: new.networkWatch != old.networkWatch ? new.networkWatch : nil,
      seasonalDecor: new.seasonalDecor != old.seasonalDecor ? new.seasonalDecor : nil,
      birthday: new.birthday != old.birthday ? new.birthday : nil
    )
  }

  static let dayEndTimes = ["18:00", "19:00", "20:00", "21:00", "22:00"]
  static let focusChoices = [15, 25, 45, 60]
  static let breakChoices = [5, 10, 15]

  /// Wochentage für die Wochenplanung (ISO: 1 = Montag … 7 = Sonntag).
  struct WeekdayChoice: Identifiable, Equatable {
    let day: Int
    let label: String
    var id: Int { day }
  }
  static let weekdays: [WeekdayChoice] = [
    WeekdayChoice(day: 1, label: "Mo"), WeekdayChoice(day: 2, label: "Di"), WeekdayChoice(day: 3, label: "Mi"),
    WeekdayChoice(day: 4, label: "Do"), WeekdayChoice(day: 5, label: "Fr"), WeekdayChoice(day: 6, label: "Sa"),
    WeekdayChoice(day: 7, label: "So"),
  ]

  /// Freie Eingabe einer Uhrzeit: "18:30", "18.30", "1830", "9", "9:5" → "HH:mm"; nil bei Unsinn.
  static func normalizeTime(_ raw: String) -> String? {
    let digits = raw.trimmingCharacters(in: .whitespaces)
    let parts = digits.split(whereSeparator: { $0 == ":" || $0 == "." || $0 == " " }).map(String.init)
    var h: Int?, m: Int?
    if parts.count == 2 {
      h = Int(parts[0]); m = Int(parts[1])
      if parts[1].count == 1, let mm = m { m = mm * 10 }
    } else if parts.count == 1, let only = parts.first, only.allSatisfy(\.isNumber) {
      switch only.count {
      case 1, 2: h = Int(only); m = 0
      case 3: h = Int(only.prefix(1)); m = Int(only.suffix(2))
      case 4: h = Int(only.prefix(2)); m = Int(only.suffix(2))
      default: return nil
      }
    }
    guard let hh = h, let mm = m, (0...23).contains(hh), (0...59).contains(mm) else { return nil }
    return String(format: "%02d:%02d", hh, mm)
  }

  /// Uhrzeit um `minutes` verschieben (über Mitternacht herum).
  static func shiftTime(_ time: String, by minutes: Int) -> String {
    let base = normalizeTime(time) ?? "00:00"
    let total = ((Int(base.prefix(2)) ?? 0) * 60 + (Int(base.suffix(2)) ?? 0) + minutes) % 1440
    let t = total < 0 ? total + 1440 : total
    return String(format: "%02d:%02d", t / 60, t % 60)
  }

  /// Uhrzeiten für die Wochenplanung; eine abweichende gespeicherte Zeit bleibt wählbar.
  static func weeklyTimes(current: String) -> [String] {
    var list = dayEndTimes
    if !list.contains(current) { list.append(current); list.sort() }
    return list
  }

  /// Apps nach Suchtext (Name, ohne Groß/Klein), ausgewählte zuerst.
  static func filterApps(_ apps: [AppInfo], search: String, selected: [String]) -> [AppInfo] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    let matching = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
    return matching.sorted { a, b in
      let sa = selected.contains(a.id), sb = selected.contains(b.id)
      if sa != sb { return sa }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }

  /// Konfigurations-Schnipsel für externe Agenten (MCP).
  static func claudeSnippet(_ path: String) -> String { "claude mcp add taby -- \"\(path)\"" }
  static func yamlSnippet(_ path: String) -> String { "mcp_servers:\n  taby:\n    command: \"\(path)\"" }

  /// Auswahl für Mindestabstand und Kostenlimits (Chips statt freier Zahleneingabe).
  static let bufferChoices = [0, 5, 10, 15, 30]
  static let dailyLimitChoices: [Double] = [0, 0.5, 1, 2, 5, 10]
  static let monthlyLimitChoices: [Double] = [0, 5, 10, 20, 50, 100]

  static func isEmpty(_ p: SettingsPatch) -> Bool { p == SettingsPatch() }

  /// https überall; http nur für den eigenen Rechner (localhost, 127.0.0.1, ::1).
  static func validateBaseUrl(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let message = "Adresse: https:// nutzen (http:// nur für localhost, 127.0.0.1 oder ::1)."
    guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(),
          !host.isEmpty else { return message }
    if scheme == "https" { return nil }
    if scheme == "http", ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return nil }
    return message
  }

  /// Riskante Felder (Endpunkt, Modelle, Tastenkürzel) werden nur bestätigt gespeichert, nicht pro Tastendruck.
  /// Übernimmt sie aus `source` in `base`; alles andere bleibt von `base`.
  static func withRiskyFields(from source: TabySettings, into base: TabySettings) -> TabySettings {
    var r = base
    r.llmBaseUrl = source.llmBaseUrl
    r.llmModel = source.llmModel
    r.briefingModel = source.briefingModel
    r.globalShortcut = source.globalShortcut
    r.quickCaptureShortcut = source.quickCaptureShortcut
    r.captureSelectionShortcut = source.captureSelectionShortcut
    r.captureContextShortcut = source.captureContextShortcut
    r.explainShortcut = source.explainShortcut
    r.circleShortcut = source.circleShortcut
    r.notionStatusMap = source.notionStatusMap
    r.voiceInputShortcut = source.voiceInputShortcut
    r.focusShortcutOn = source.focusShortcutOn
    r.focusShortcutOff = source.focusShortcutOff
    return r
  }

  /// Autosave: sichere Felder sofort, riskante bleiben beim zuletzt bestätigten Wert (`committed`).
  static func autosaveTarget(form: TabySettings, committed: TabySettings) -> TabySettings {
    withRiskyFields(from: committed, into: form)
  }

  /// Bestätigung (Enter, Fokus weg, Fenster zu, vor dem Test): alles speichern, außer einer ungültigen
  /// Endpunkt-URL. Die bleibt beim letzten gültigen Wert und bekommt eine Fehlermeldung.
  static func commitTarget(form: TabySettings, committed: TabySettings) -> (target: TabySettings, urlError: String?) {
    let urlError = validateBaseUrl(form.llmBaseUrl)
    var target = form
    if urlError != nil { target.llmBaseUrl = committed.llmBaseUrl }
    return (target, urlError)
  }

  /// Schreibweise wie beim Kurzbefehl-Register (Control+Option+Space): mindestens ein Modifikator,
  /// genau eine bekannte Taste. Unbekanntes führt zu „Unbekannte Tastenkombination“.
  static func shortcutParses(_ s: String) -> Bool {
    let modifiers: Set<String> = ["control", "ctrl", "option", "alt", "command", "cmd", "shift"]
    let keys: Set<String> = Set(["space", "return", "enter", "tab", "escape"]
      + "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) })
    var hasModifier = false
    var hasKey = false
    for raw in s.split(separator: "+") {
      let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
      if modifiers.contains(part) { hasModifier = true } else if keys.contains(part) { hasKey = true } else { return false }
    }
    return hasModifier && hasKey
  }

  /// Schreibweise aus einer aufgenommenen Taste: Modifikatoren in fester Reihenfolge, dann die Taste
  /// („Control+Option+Space“, „Command+N“). Nil, wenn kein Modifikator dabei ist oder die Taste fehlt.
  static func shortcutString(modifiers: Set<String>, key: String) -> String? {
    let mods = ["Control", "Option", "Shift", "Command"].filter { modifiers.contains($0) }
    let k = key.lowercased()
    let name: String
    switch k {
    case "space": name = "Space"
    case "return": name = "Return"
    case "tab": name = "Tab"
    default:
      guard k.count == 1, k.first.map({ $0.isLetter || $0.isNumber }) == true else { return nil }
      name = k.uppercased()
    }
    let s = (mods + [name]).joined(separator: "+")
    return !mods.isEmpty && shortcutParses(s) ? s : nil
  }

  static func validateIcsUrl(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https", "webcal"].contains(scheme),
          u.host != nil else {
      return "Bitte eine gültige ICS-URL eingeben (https:// oder webcal://)."
    }
    return nil
  }

  static func notionConfig(token: String, databaseId: String, titleField: String, startField: String,
                           endField: String) -> Result<[String: JSONValue], FormError> {
    let tok = token.trimmingCharacters(in: .whitespaces)
    let db = databaseId.trimmingCharacters(in: .whitespaces)
    if tok.isEmpty || db.isEmpty { return .failure(FormError("Notion-Zugangscode und Datenbank-ID werden gebraucht.")) }
    var c: [String: JSONValue] = [
      "token": .string(tok),
      "databaseId": .string(db),
      "titleField": .string(titleField.trimmingCharacters(in: .whitespaces).isEmpty ? "Name" : titleField
        .trimmingCharacters(in: .whitespaces)),
      "startField": .string(startField.trimmingCharacters(in: .whitespaces).isEmpty ? "Datum" : startField
        .trimmingCharacters(in: .whitespaces)),
    ]
    let end = endField.trimmingCharacters(in: .whitespaces)
    if !end.isEmpty { c["endField"] = .string(end) }
    return .success(c)
  }

  /// Kurzbeschreibung einer Kalenderquelle, ohne Geheimnisse (kein Token).
  static func sourceDetail(_ s: CalendarSourceConfig) -> String {
    switch s.kind {
    case .ics: s.config["url"]?.stringValue ?? s.id
    case .notion: s.config["databaseId"]?.stringValue.map { "Datenbank \($0.prefix(8))…" } ?? s.id
    case .apple: "Alle Apple-Kalender"
    case .local: "In Lumi gespeichert"
    case .caldav: s.config["url"]?.stringValue ?? s.id
    case .microsoft: "Outlook / Microsoft 365"
    }
  }

  /// "täglich 08:00", "Mo., Mi. 08:00", "einmalig Fr., 9. Okt. 08:00".
  static func ruleText(_ r: JobRule) -> String {
    let names = ["So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa."]
    switch r {
    case .daily(let time): return "täglich \(time)"
    case .weekly(let days, let time):
      let d = days.sorted { (($0 + 6) % 7) < (($1 + 6) % 7) }.compactMap { (0..<7).contains($0) ? names[$0] : nil }
      return "\(d.joined(separator: ", ")) \(time)"
    case .once(let at):
      return "einmalig \(GermanDate.short(at))" + (GermanDate.time(at).map { " \($0)" } ?? "")
    }
  }
}

// MARK: - Agenten

enum AgentLogic {
  struct Preview: Equatable {
    let text: String
    let isCommand: Bool
  }

  /// Vorschau der Werkzeug-Eingabe: Befehl, Dateipfad oder kompaktes JSON.
  static func preview(_ input: JSONValue, limit: Int = 220) -> Preview {
    if let cmd = input["command"]?.stringValue { return Preview(text: clip(cmd, limit), isCommand: true) }
    for key in ["file_path", "path", "url", "pattern", "query"] {
      if let v = input[key]?.stringValue { return Preview(text: clip(v, limit), isCommand: false) }
    }
    return Preview(text: clip(input.jsonString(), limit), isCommand: false)
  }

  static func headline(_ toolName: String) -> String {
    switch toolName {
    case "Bash": "Claude Code möchte einen Befehl ausführen"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": "Claude Code möchte eine Datei ändern"
    case "WebFetch", "WebSearch": "Claude Code möchte ins Netz"
    default: "\(toolName) braucht eine Freigabe"
    }
  }

  /// "~/Projekte/taby" statt voller Heimatpfad.
  static func shortPath(_ p: String?, home: String = NSHomeDirectory()) -> String? {
    guard let p, !p.isEmpty else { return nil }
    return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
  }

  static let denyMessage = "Vom Nutzer in Lumi abgelehnt."

  private static func clip(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n)) + "…" : s
  }
}

// MARK: - Heute

enum TodayLogic {
  /// Zahl mit richtiger Einzahl/Mehrzahl: „1 Aufgabe“, „2 Aufgaben“.
  static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

  /// Kurztext ohne Modell (wie TodayTab.tsx).
  static func fallbackBriefing(_ o: Overview) -> String {
    if o.overdueTasks.isEmpty && o.todayTasks.isEmpty {
      return o.eventsToday.isEmpty
        ? "Für heute liegt nichts an. Guten Start!"
        : "Keine offenen Aufgaben für heute. \(count(o.eventsToday.count, "Termin im Kalender", "Termine im Kalender"))."
    }
    return "Heute: \(count(o.todayTasks.count, "Aufgabe", "Aufgaben")) offen, \(o.overdueTasks.count) überfällig."
  }

  /// true, wenn der Reiter "Heute" gar nichts zu zeigen hat.
  static func isEmpty(_ o: Overview) -> Bool {
    o.overdueTasks.isEmpty && o.todayTasks.isEmpty && o.eventsToday.isEmpty
      && o.missed.isEmpty && o.conflicts.isEmpty && o.unreachableCalendarSources.isEmpty
  }

  /// Begrüßung nach Tageszeit.
  static func greeting(now: String) -> String {
    let hour = Int(GermanDate.time(now)?.prefix(2) ?? "9") ?? 9
    switch hour {
    case 5..<11: return "Guten Morgen"
    case 11..<17: return "Hallo"
    case 17..<23: return "Guten Abend"
    default: return "Gute Nacht"
    }
  }
}


// MARK: - Verbrauch (Paket 1)

enum UsageLogic {
  enum Level: Equatable { case none, near, reached }

  static func level(_ u: UsageSummary) -> Level {
    u.limitReached ? .reached : u.nearLimit ? .near : .none
  }

  /// "0,04 $" – deutsches Komma; unter einem Cent zwei signifikante Stellen.
  static func dollars(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.numberStyle = .decimal
    if v > 0 && v < 0.01 {
      f.maximumSignificantDigits = 2
    } else {
      f.minimumFractionDigits = 2
      f.maximumFractionDigits = 2
    }
    return (f.string(from: NSNumber(value: v)) ?? "0,00") + " $"
  }

  /// "18,4 Tsd. Tokens", "1,2 Mio. Tokens", "950 Tokens".
  static func tokens(_ n: Int) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.numberStyle = .decimal
    f.maximumFractionDigits = 1
    if n >= 1_000_000 { return (f.string(from: NSNumber(value: Double(n) / 1_000_000)) ?? "") + " Mio. Tokens" }
    if n >= 1_000 { return (f.string(from: NSNumber(value: Double(n) / 1_000)) ?? "") + " Tsd. Tokens" }
    return "\(n) Tokens"
  }

  static func limitLabel(_ v: Double) -> String { v == 0 ? "kein" : dollars(v) }

  static func chipText(_ level: Level) -> String? {
    switch level {
    case .none: nil
    case .near: "Kostenlimit fast erreicht"
    case .reached: "Limit erreicht – das Modell pausiert"
    }
  }
}

// MARK: - Verbindungen

/// `soon`: Dienst noch nicht verfügbar (neutral, kein Schalter).
enum ConnectionStatus: Equatable { case connected, off, problem, soon }

/// Obsidian-Vault: Verbindung, Anzeige und Prüfung des Unterordners (Logik ohne Oberfläche).
enum ObsidianLogic {
  static func isConnected(path: String) -> Bool { !path.trimmingCharacters(in: .whitespaces).isEmpty }

  static func isConnected(_ s: AppState?) -> Bool { isConnected(path: s?.settings.markdownVaultPath ?? "") }

  static func noteCountText(_ n: Int) -> String { n == 1 ? "1 Notiz" : "\(n) Notizen" }

  /// Kurzer Status der Karte: „verbunden · 12 Notizen“ oder „nicht verbunden“.
  static func statusText(_ s: AppState) -> String {
    isConnected(s) ? "verbunden · \(noteCountText(s.vaultNoteCount))" : "nicht verbunden"
  }

  /// Unterordner, in den Lumi schreibt: relativ, ohne „..“ und ohne führendes „/“ oder „~“. nil = gültig.
  static func writeFolderError(_ folder: String) -> String? {
    let f = folder.trimmingCharacters(in: .whitespaces)
    if f.isEmpty { return "Bitte einen Unterordner angeben, z. B. „Lumi“." }
    if f.hasPrefix("/") || f.hasPrefix("~") { return "Nur ein Unterordner im Vault, kein Pfad ab dem Mac-Ordner." }
    if f.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
      return "„..“ ist nicht erlaubt – Lumi bleibt im Vault."
    }
    return nil
  }

  /// Titel für die Besprechungsnotiz: „<Termin> – 11.10.2026“.
  static func meetingNoteTitle(title: String, start: String) -> String {
    let parts = String(start.prefix(10)).split(separator: "-")
    guard parts.count == 3 else { return "\(title) – \(start.prefix(10))" }
    return "\(title) – \(parts[2]).\(parts[1]).\(parts[0])"
  }
}

/// Was der Knopf einer Karte tut (ausgeführt in ConnectionsView).
enum ConnectionAction: Equatable {
  case open(SettingsPage)
  /// Obsidian: Vault-Ordner wählen oder ändern (direkt über den Ordner-Dialog).
  case obsidian
  case connectMessenger(MessengerService)
  case disconnectMessenger(String)
  /// Element/Matrix: noch kein Konto → Formular (Server, Benutzer, Passwort) aufklappen.
  case matrixForm
  /// Element/Matrix angemeldet, Verschlüsselung gesperrt → Sicherheitsschlüssel abfragen.
  case matrixUnlock(String)
  /// Slack: Token-Formular mit Anleitung aufklappen (eigene Slack-App des Nutzers).
  case slackForm
  case unavailable
}

/// Eine Karte der Verbindungen-Seite. Status kommt nur aus vorhandenen Einstellungs- und Zustandsfeldern.
struct ConnectionCard: Equatable, Identifiable {
  let id: String
  let title: String
  let symbol: String
  let detail: String
  let status: ConnectionStatus
  let action: ConnectionAction
}

enum ConnectionLogic {
  static func cards(_ s: AppState) -> [ConnectionCard] {
    let set = s.settings
    let apple = set.llmModel == TabySettings.appleIntelligenceModel
    // Ein Endpunkt auf diesem Mac (Ollama, LM Studio) braucht keinen Schlüssel.
    let local = LlmConnection.isLocalEndpoint(set.llmBaseUrl)
    let modelOn = set.hasApiKey || apple || local
    let modelDetail = apple ? "Apple Intelligence"
      : !set.hasApiKey && !local ? "Kein Schlüssel"
      : set.llmModel.isEmpty ? (local ? "Lokal" : "Schlüssel gesetzt") : set.llmModel

    var seen = Set<String>()
    let kinds = s.calendarSources.filter(\.enabled).map { $0.kind.germanName }.filter { seen.insert($0).inserted }

    let remindersOn = set.appleRemindersSync
    let remindersStatus: ConnectionStatus = !remindersOn ? .off : s.remindersError == nil ? .connected : .problem

    let notionOn = s.notionTasksConnected && set.notionTasksEnabled
    let notionError = s.notionTasksSync?.lastError
    let n = s.notionSources.count
    let notionDetail = !notionOn ? "Nicht eingeschaltet"
      : notionError ?? (n == 1 ? "1 Quelle" : "\(n) Quellen")
    let notionStatus: ConnectionStatus = !notionOn ? .off : notionError == nil ? .connected : .problem

    return [
      ConnectionCard(id: "model", title: "Modell", symbol: "cpu", detail: modelDetail,
                     status: modelOn ? .connected : .off, action: .open(.model)),
      ConnectionCard(id: "calendar", title: "Kalender", symbol: "calendar",
                     detail: kinds.isEmpty ? "Keine Quelle aktiv" : kinds.joined(separator: ", "),
                     status: kinds.isEmpty ? .off : .connected, action: .open(.accounts)),
      ConnectionCard(id: "reminders", title: "Apple Erinnerungen", symbol: "checklist",
                     detail: !remindersOn ? "Abgleich aus" : s.remindersError ?? "Abgleich aktiv",
                     status: remindersStatus, action: .open(.accounts)),
      ConnectionCard(id: "mail", title: "Mail", symbol: "envelope",
                     detail: set.mailEnabled ? (set.mailBackend == "imap" ? "IMAP direkt" : "Apple Mail") : "Nicht eingeschaltet",
                     status: set.mailEnabled ? .connected : .off, action: .open(.accounts)),
      ConnectionCard(id: "notion", title: "Notion-Aufgaben", symbol: "doc.text",
                     detail: notionDetail, status: notionStatus, action: .open(.accounts)),
      ConnectionCard(id: "claude", title: "Claude Code", symbol: "terminal",
                     detail: set.claudeNotify ? "Meldungen aus Claude Code" : "Nicht eingeschaltet",
                     status: set.claudeNotify ? .connected : .off, action: .open(.connect)),
      ConnectionCard(id: "mcp", title: "MCP (Schnittstelle für andere KI-Programme)", symbol: "point.3.connected.trianglepath.dotted",
                     detail: set.mcpEnabled ? "Externe Agenten dürfen Lumi nutzen" : "Nicht eingeschaltet",
                     status: set.mcpEnabled ? .connected : .off, action: .open(.connect)),
    ] + messengerCards(s.messengerAccounts, microsoftSignedIn: !set.microsoftAccount.isEmpty) + [obsidianCard(s)]
  }

  /// Obsidian (Markdown-Vault): verbunden, sobald ein Ordner gewählt ist.
  static func obsidianCard(_ s: AppState) -> ConnectionCard {
    let on = ObsidianLogic.isConnected(s)
    return ConnectionCard(id: "obsidian", title: "Obsidian", symbol: "book.closed",
                          detail: ObsidianLogic.statusText(s), status: on ? .connected : .off, action: .obsidian)
  }

  /// Chat-Dienste in fester Reihenfolge: iMessage (verbindbar), Slack, Element/Matrix.
  static func messengerCards(_ accounts: [MessengerAccount], microsoftSignedIn: Bool = false) -> [ConnectionCard] {
    let account = accounts.first { $0.service == .imessage }
    let imessage: ConnectionCard
    if let account {
      let (status, detail): (ConnectionStatus, String) = switch account.status {
      case .connected: (.connected, account.user.isEmpty ? "Nachrichten-App" : account.user)
      case .locked: (.problem, "Gesperrt – Sicherheitsschlüssel fehlt")
      case .error(let e): (.problem, e)
      }
      imessage = ConnectionCard(id: "imessage", title: MessengerService.imessage.title, symbol: MessengerService.imessage.symbol,
                                detail: detail, status: status, action: .disconnectMessenger(account.id))
    } else {
      imessage = ConnectionCard(id: "imessage", title: MessengerService.imessage.title, symbol: MessengerService.imessage.symbol,
                                detail: "Liest und sendet über die Nachrichten-App (Festplattenvollzugriff nötig)",
                                status: .off, action: .connectMessenger(.imessage))
    }
    return [
      imessage,
      slackCard(accounts.first { $0.service == .slack }),
      teamsCard(accounts.first { $0.service == .teams }, microsoftSignedIn: microsoftSignedIn),
      matrixCard(accounts.first { $0.service == .matrix }),
    ]
  }

  /// Teams: die Anmeldung läuft über Microsoft (Karte auf dieser Seite). Ohne sie meldet der Verbinden-Knopf das.
  static func teamsCard(_ account: MessengerAccount?, microsoftSignedIn: Bool) -> ConnectionCard {
    let service = MessengerService.teams
    guard let account else {
      return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol,
                            detail: microsoftSignedIn ? "Chats über dein Microsoft-Konto"
                              : "Erst bei Microsoft anmelden: Verbindungen → Microsoft",
                            status: .off, action: .connectMessenger(.teams))
    }
    let (status, detail): (ConnectionStatus, String) = switch account.status {
    case .connected: (.connected, account.user.isEmpty ? "Microsoft Teams" : account.user)
    case .locked: (.problem, "Gesperrt")
    case .error(let e): (.problem, e)
    }
    return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol, detail: detail,
                          status: status, action: .disconnectMessenger(account.id))
  }

  /// Slack: ohne Konto Token-Formular; sonst Status und Trennen.
  static func slackCard(_ account: MessengerAccount?) -> ConnectionCard {
    let service = MessengerService.slack
    guard let account else {
      return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol,
                            detail: "Eigene Slack-App im Workspace mit einem Zugangscode (xoxp-…)",
                            status: .off, action: .slackForm)
    }
    let (status, detail): (ConnectionStatus, String) = switch account.status {
    case .connected: (.connected, account.user.isEmpty ? "Slack" : account.user)
    case .locked: (.problem, "Gesperrt")
    case .error(let e): (.problem, e)
    }
    return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol, detail: detail,
                          status: status, action: .disconnectMessenger(account.id))
  }

  /// Element/Matrix: ohne eingebaute SDK bleibt es "Bald"; sonst Formular bzw. Status des Kontos.
  static func matrixCard(_ account: MessengerAccount?, available: Bool = MatrixAvailability.isAvailable) -> ConnectionCard {
    let service = MessengerService.matrix
    guard available else {
      return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol,
                            detail: "Verschlüsselte Chats – in Vorbereitung", status: .soon, action: .unavailable)
    }
    guard let account else {
      return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol,
                            detail: "Verschlüsselte Chats über einen Element-Server (Matrix)",
                            status: .off, action: .matrixForm)
    }
    let (status, detail, action): (ConnectionStatus, String, ConnectionAction) = switch account.status {
    case .connected: (.connected, account.user.isEmpty ? "Element-Konto" : account.user, .disconnectMessenger(account.id))
    case .locked: (.problem, "Gesperrt – Sicherheitsschlüssel fehlt", .matrixUnlock(account.id))
    case .error(let e): (.problem, e, .disconnectMessenger(account.id))
    }
    return ConnectionCard(id: service.rawValue, title: service.title, symbol: service.symbol,
                          detail: detail, status: status, action: action)
  }
}

// MARK: - Tagesplan: Aufgaben wählen und Uhrzeiten (Paket 13)

/// Eine Aufgabe im Uhrzeiten-Schritt: Dauer in Minuten, feste Uhrzeit nur wenn `pinned`.
struct PlanPickItem: Equatable, Identifiable {
  var taskId: String
  var title: String
  var pinned: Bool
  /// "HH:mm"
  var time: String
  var minutes: Int
  var id: String { taskId }
}

enum PlanPickerLogic {
  static let durations = [15, 30, 60, 90]
  static let defaultMinutes = 30
  static let dayEnd = 23 * 60 + 30

  /// "HH:mm" aus "YYYY-MM-DDTHH:mm" oder "HH:mm".
  static func clock(_ iso: String) -> String { String(iso.suffix(5)) }

  /// Minuten seit Mitternacht aus "HH:mm"; nil bei Unsinn.
  static func minutes(of hhmm: String) -> Int? {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
          (0...23).contains(h), (0...59).contains(m) else { return nil }
    return h * 60 + m
  }

  static func format(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

  /// Dauer eines bestehenden Blocks; ungültig oder leer → Standard.
  static func duration(_ b: PlannedBlock) -> Int {
    guard let s = minutes(of: clock(b.start)), let e = minutes(of: clock(b.end)), e > s else { return defaultMinutes }
    return min(max(e - s, 5), 480)
  }

  static func items(from blocks: [PlannedBlock]) -> [PlanPickItem] {
    blocks.map { PlanPickItem(taskId: $0.taskId, title: $0.title, pinned: $0.isPinned,
                              time: clock($0.start), minutes: duration($0)) }
  }

  /// Vorauswahl: Aufgaben aus dem Plan, die noch offen sind.
  static func selection(openIds: Set<String>, items: [PlanPickItem]) -> Set<String> {
    Set(items.map(\.taskId)).intersection(openIds)
  }

  /// Nächste halbe Stunde nach "now", in Minuten seit Mitternacht.
  static func nextHalfHour(after now: String) -> Int {
    let cur = minutes(of: clock(now)) ?? 0
    return min((cur / 30 + 1) * 30, dayEnd)
  }

  /// Termine, die den Zeitraum (heute) überschneiden. Ganztägige zählen nicht.
  static func overlapping(start: Int, minutes: Int, events: [CalendarEvent], today: String) -> [CalendarEvent] {
    events.filter { e in
      guard !e.allDay, LocalTime.datePart(e.start) == today, let eStart = Self.minutes(of: clock(e.start)) else { return false }
      let eEnd = e.end.flatMap { LocalTime.datePart($0) == today ? Self.minutes(of: clock($0)) : 1440 } ?? eStart + 30
      return start < eEnd && eStart < start + minutes
    }
  }

  /// Frühester Start ab `from`, der kein Termin überschneidet (in halben Stunden weitergeschoben).
  static func nextFreeStart(from: Int, minutes: Int, events: [CalendarEvent], today: String) -> Int {
    var s = from
    while s < dayEnd, !overlapping(start: s, minutes: minutes, events: events, today: today).isEmpty { s += 30 }
    return min(s, dayEnd)
  }

  /// Warnung für eine feste Uhrzeit: "überschneidet „Termin“"; nil bei Automatik oder ohne Überschneidung.
  static func conflictText(_ item: PlanPickItem, events: [CalendarEvent], today: String) -> String? {
    guard item.pinned, let start = minutes(of: item.time) else { return nil }
    let hits = overlapping(start: start, minutes: item.minutes, events: events, today: today)
    var parts: [String] = []
    if !hits.isEmpty { parts.append("Überschneidet sich mit " + hits.map { "„\($0.title)“" }.joined(separator: ", ")) }
    // Der Kern kürzt feste Blöcke auf 23:59 (kein Ende am nächsten Tag).
    if start + item.minutes > 23 * 60 + 59 { parts.append("Endet nach Mitternacht, wird bis 23:59 gekürzt") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// Auswahl → Schritt 2: bekannte Einträge bleiben (Zeit, Dauer), neue bekommen die nächste freie Zeit nach der letzten.
  static func build(selected: [TabyTask], known: [PlanPickItem], now: String,
                    events: [CalendarEvent], today: String) -> [PlanPickItem] {
    var out: [PlanPickItem] = []
    for t in selected {
      if var old = known.first(where: { $0.taskId == t.id }) {
        old.title = t.title
        out.append(old)
        continue
      }
      let from = out.last.flatMap { last in minutes(of: last.time).map { $0 + last.minutes } } ?? nextHalfHour(after: now)
      let start = nextFreeStart(from: from, minutes: defaultMinutes, events: events, today: today)
      out.append(PlanPickItem(taskId: t.id, title: t.title, pinned: false, time: format(start), minutes: defaultMinutes))
    }
    return out
  }

  /// Zum Speichern: feste Uhrzeit nur bei gesetztem Schalter, sonst freie Lücke.
  static func planItems(_ items: [PlanPickItem]) -> [PlanItem] {
    items.map { PlanItem(taskId: $0.taskId, start: $0.pinned ? $0.time : nil, minutes: $0.minutes) }
  }

  static func selectedText(_ n: Int) -> String { "\(n) ausgewählt" }
}

// MARK: - Tagesplan: Ziehen zum Umordnen

enum PlanReorderLogic {
  /// Verschiebt das Element an `from` vor die Lücke `slot` (0…count; count = ganz unten).
  /// Ungültige Eingaben und Verschieben auf sich selbst (oder direkt darunter) ändern nichts.
  static func moved<T>(_ items: [T], from: Int, before slot: Int) -> [T] {
    guard items.indices.contains(from), (0...items.count).contains(slot),
          slot != from, slot != from + 1 else { return items }
    var out = items
    let item = out.remove(at: from)
    out.insert(item, at: slot > from ? slot - 1 : slot)
    return out
  }

  /// Lücke beim Überfahren der Zeile `index` während des Ziehens von `from`:
  /// nach oben → Lücke über der Zeile, nach unten → darunter.
  /// shortcut: Zeilenhälfte wird nicht gemessen, Lücke wechselt beim Zeilenwechsel; upgrade mit GeometryReader.
  static func slot(dragging from: Int, over index: Int) -> Int {
    from < index ? index + 1 : index
  }
}

// MARK: - Tagesplan-Auswahl: Abschnitte nach Quelle und Kategorie

/// Gruppe innerhalb eines Abschnitts; `title` leer = ohne Zwischenüberschrift.
struct PlanPickGroup: Equatable {
  let title: String
  let tasks: [TabyTask]
}

/// Abschnitt der Aufgaben-Auswahl mit Kopfzeile und Anzahl.
struct PlanPickSection: Equatable, Identifiable {
  let id: String
  let title: String
  let groups: [PlanPickGroup]
  var count: Int { groups.reduce(0) { $0 + $1.tasks.count } }
}

extension PlanPickerLogic {
  /// Überfällig zuerst, dann nach Fälligkeit (ohne Datum zuletzt), dann nach Titel.
  static func pickOrder(_ a: TabyTask, _ b: TabyTask, now: String) -> Bool {
    func key(_ t: TabyTask) -> (Int, Int, String) {
      let overdue = TaskLogic.dueChip(t.due, now: now)?.kind == .overdue
      let due = t.due ?? ""
      return (overdue ? 0 : 1, due.isEmpty ? 1 : 0, due)
    }
    let ka = key(a), kb = key(b)
    if ka.0 != kb.0 { return ka.0 < kb.0 }
    if ka.1 != kb.1 { return ka.1 < kb.1 }
    if ka.2 != kb.2 { return ka.2 < kb.2 }
    return a.title.localizedStandardCompare(b.title) == .orderedAscending
  }

  /// Abschnitte je Kategorie in Einstellungsreihenfolge, zuletzt „Ohne Kategorie“. Notion-Aufgaben stehen unter
  /// der Kategorie ihres Zugangs (`notionCategories`). Innen zuerst die Ordner der eigenen Aufgaben, dann je
  /// Notion-Quelle „Notion · <Name>“. Leere Abschnitte fehlen. Aufgaben ohne bekannte Quelle zählen als eigene.
  static func sections(_ tasks: [TabyTask], sourceLinks: [String: String], sources: [NotionSource],
                       taskGroups: [String: String], now: String, notionCategories: [String: String],
                       categories: [TaskCategoryDef] = TaskCategoryDef.builtIn,
                       folders: [TaskFolder] = []) -> [PlanPickSection] {
    let open = tasks.filter { !$0.done }
    let defs = categories
    let byId = Set(sources.map(\.id))
    var out: [PlanPickSection] = []
    let cats: [String?] = defs.map(\.id) + [nil]
    for c in cats {
      let members = open.filter {
        TaskCategoryLogic.effective($0, folders: folders, defs: defs, notionCategories: notionCategories) == c
      }
      let own = members.filter { sourceLinks[$0.id].map { !byId.contains($0) } ?? true }
      // Ohne Kategorie: eine flache Gruppe (die Übersicht von „Alle“ wäre hier doppelt gemoppelt).
      let ownGroups = (c == nil ? [TaskFolderLogic.Group(folder: nil, tasks: own)]
                                : TaskCategoryLogic.groups(own, category: c, folders: folders, defs: defs,
                                                           notionCategories: notionCategories))
        .filter { !$0.tasks.isEmpty }
      let hasFolders = ownGroups.contains { $0.folder != nil }
      var groups = ownGroups.map { g in
        PlanPickGroup(title: g.folder?.name ?? (hasFolders ? "Ohne Ordner" : ""), tasks: sortedPick(g.tasks, now: now))
      }
      groups += notionGroups(members, sourceLinks: sourceLinks, sources: sources, taskGroups: taskGroups, now: now)
      guard !groups.isEmpty else { continue }
      let title = c.flatMap { id in defs.first { $0.id == id }?.name } ?? "Ohne Kategorie"
      out.append(PlanPickSection(id: c.map { "cat-\($0)" } ?? "none", title: title, groups: groups))
    }
    return out
  }

  /// Notion-Gruppen in Quellenreihenfolge: „Notion · <Name>“; Wochen-Quellen je Woche. Aufgaben ohne Quelle fehlen.
  static func notionGroups(_ tasks: [TabyTask], sourceLinks: [String: String], sources: [NotionSource],
                           taskGroups: [String: String], now: String) -> [PlanPickGroup] {
    var out: [PlanPickGroup] = []
    for s in sources {
      let members = tasks.filter { sourceLinks[$0.id] == s.id }
      guard !members.isEmpty else { continue }
      if s.category == .weekly {
        out += NotionPageView.weekGroups(members, groups: taskGroups).map {
          PlanPickGroup(title: "Notion · \($0.name)", tasks: sortedPick($0.tasks, now: now))
        }
      } else {
        out.append(PlanPickGroup(title: "Notion · \(s.name)", tasks: sortedPick(members, now: now)))
      }
    }
    return out
  }

  static func sortedPick(_ ts: [TabyTask], now: String) -> [TabyTask] { ts.sorted { pickOrder($0, $1, now: now) } }
}
