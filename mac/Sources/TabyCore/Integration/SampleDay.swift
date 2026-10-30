// Beispiel-Tag für neue Nutzer: drei Aufgaben, eine Notiz und ein Termin heute.
// Die angelegten Einträge merkt sich Lumi in `app_settings` (Schlüssel `sampleDayIds`). Das Entfernen
// löscht nur diese Ids und nur, wenn der Eintrag noch den Marker trägt – echte Einträge mit „[Beispiel]“
// bleiben also stehen.
import Foundation

public enum SampleDay {
  public static let marker = "[Beispiel]"
  public static let taskTitles = ["Angebot an Müller schicken (30 min)", "Rückruf Frau Weber", "Wochenplan prüfen"]
  public static let noteTitle = "Beispiel: Ideen für diese Woche"
  public static let noteContent = "Kleine Gedanken landen hier. Einfach „Merk dir …“ im Chat schreiben."
  public static let eventTitle = "Beispiel: Kurze Abstimmung"
  public static let eventStart = "14:00"
  public static let eventEnd = "14:30"
  public static let idsKey = "sampleDayIds"

  /// Die Ids der angelegten Beispiel-Einträge (in `app_settings` als JSON).
  public struct Ids: Codable, Equatable, Sendable {
    public var tasks: [String] = []
    public var notes: [String] = []
    public var events: [EventRef] = []
    public var isEmpty: Bool { tasks.isEmpty && notes.isEmpty && events.isEmpty }

    public struct EventRef: Codable, Equatable, Sendable {
      public var id: String
      public var sourceId: String
    }
  }

  /// Ist dieser Text ein Beispiel-Eintrag?
  public static func isSample(_ text: String?) -> Bool {
    text?.contains(marker) == true
  }

  /// Termin heute: "YYYY-MM-DDT14:00" bis "YYYY-MM-DDT14:30" (lokale Zeit, zonenlos).
  public static func eventWindow(day: String) -> (start: String, end: String) {
    ("\(day)T\(eventStart)", "\(day)T\(eventEnd)")
  }

  static func encode(_ ids: Ids) -> String {
    (try? JSONEncoder().encode(ids)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  static func decode(_ text: String?) -> Ids {
    guard let text, let data = text.data(using: .utf8), let ids = try? JSONDecoder().decode(Ids.self, from: data) else {
      return Ids()
    }
    return ids
  }
}

extension CoreServices {
  /// Gemerkte Beispiel-Ids (leer, wenn keine Beispiel-Einträge angelegt wurden).
  func sampleDayIds() -> SampleDay.Ids {
    let rows = (try? store.db.query("SELECT value FROM app_settings WHERE key = ?", [.text(SampleDay.idsKey)])) ?? []
    return SampleDay.decode(rows.first?.string("value"))
  }

  /// Speichert die Ids; leer heißt: Schlüssel entfernen.
  private func saveSampleDayIds(_ ids: SampleDay.Ids) {
    if ids.isEmpty {
      _ = try? store.db.run("DELETE FROM app_settings WHERE key = ?", [.text(SampleDay.idsKey)])
    } else {
      _ = try? store.db.run("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                            [.text(SampleDay.idsKey), .text(SampleDay.encode(ids))])
    }
  }

  /// Legt den Beispiel-Tag an. Hat er schon Einträge, passiert nichts (kein Doppeln).
  /// Jeder angelegte Eintrag wird sofort gemerkt, damit ein Abbruch trotzdem entfernbar bleibt.
  public func seedSampleDay() async -> ToolResult<Empty> {
    let day = LocalTime.formatDate(clock.now())
    if await hasSampleDay(day: day) { return .ok(Empty()) }
    var ids = SampleDay.Ids()
    for title in SampleDay.taskTitles {
      let r = await addTask(title: title, notes: SampleDay.marker, due: day)
      guard case .ok(let task) = r else {
        if case .failure(_, let error) = r { saveSampleDayIds(ids); return .failure(code: "SAMPLE", error: error) }
        return .failure(code: "SAMPLE", error: "Die Beispiel-Aufgabe konnte nicht angelegt werden.")
      }
      ids.tasks.append(task.id)
      saveSampleDayIds(ids)
    }
    let note = await addNote(title: SampleDay.noteTitle, content: "\(SampleDay.marker) \(SampleDay.noteContent)")
    guard case .ok(let created) = note else {
      saveSampleDayIds(ids)
      if case .failure(_, let error) = note { return .failure(code: "SAMPLE", error: error) }
      return .failure(code: "SAMPLE", error: "Die Beispiel-Notiz konnte nicht angelegt werden.")
    }
    ids.notes.append(created.id)
    saveSampleDayIds(ids)
    let window = SampleDay.eventWindow(day: day)
    let event = await addEvent(AddEventRequest(event: NewEvent(
      title: SampleDay.eventTitle, start: window.start, end: window.end, notes: SampleDay.marker)))
    guard case .ok(let placed, _, _) = event else {
      saveSampleDayIds(ids)
      return .failure(code: "SAMPLE", error: "Der Beispiel-Termin konnte nicht angelegt werden.")
    }
    ids.events.append(.init(id: placed.id, sourceId: placed.sourceId))
    saveSampleDayIds(ids)
    return .ok(Empty())
  }

  /// Entfernt genau die gemerkten Beispiel-Einträge, die noch den Marker tragen, und vergisst die Ids.
  public func removeSampleDay() async -> ToolResult<Empty> {
    let day = LocalTime.formatDate(clock.now())
    let ids = sampleDayIds()
    for id in ids.tasks {
      if let task = try? store.tasks.get(id), SampleDay.isSample(task.notes) { _ = await deleteTask(id) }
    }
    for id in ids.notes {
      if let note = try? store.notes.get(id), SampleDay.isSample(note.content) { _ = await deleteNote(id) }
    }
    let next = LocalTime.formatDate(clock.now().addingTimeInterval(86_400))
    for event in await listEvents(from: day, to: next) where SampleDay.isSample(event.notes) {
      guard ids.events.contains(where: { $0.id == event.id && $0.sourceId == event.sourceId }) else { continue }
      _ = await deleteEvent(id: event.id, sourceId: event.sourceId)
    }
    saveSampleDayIds(SampleDay.Ids())
    return .ok(Empty())
  }

  /// Gibt es gemerkte Beispiel-Einträge (für Menü „Beispiel-Tag entfernen“)?
  public func hasSampleDay(day: String? = nil) async -> Bool {
    !sampleDayIds().isEmpty
  }
}
