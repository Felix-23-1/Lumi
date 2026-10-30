// Meeting-Vorbereitung und Zusammenfassung (Verdrahtung mit Speicher, Kalender und
// Modell). Den Rahmen und die Regeln liefert Productivity/MeetingPrep.swift.
// Ohne Modell oder bei Fehler greift immer der Code-Fallback.
import Foundation

extension CoreServices {
  /// Titel und Startzeit des Termins zum Schlüssel: aus der Karte oder dem heutigen Kalender.
  func meetingEvent(_ id: String) async -> (title: String, start: String)? {
    if let a = Self.adhoc(id) { return a }
    if let meeting = p4.meeting, meeting.id == id { return (meeting.title, meeting.start) }
    guard let event = await todaysEvents().first(where: { MeetingCompanion.key($0) == id }) else { return nil }
    return (event.title, event.start)
  }

  /// Spontanes Gespräch ohne Kalendertermin: Schlüssel "adhoc|<Start>".
  static func adhoc(_ id: String) -> (title: String, start: String)? {
    guard id.hasPrefix("adhoc|") else { return nil }
    let start = String(id.dropFirst(6))
    return ("Gespräch \(String(start.suffix(5)))", start)
  }

  /// Gewählte Elemente in der gewünschten Reihenfolge; unbekannte IDs und Dubletten fallen weg.
  private func picked<T: Identifiable>(_ ids: [String], from all: [T]) -> [T] where T.ID == String {
    let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
  }

  /// Agenda vom Modell (günstiges Modell). nil = nichts zu formulieren, kein Modell oder Fehler.
  private func meetingAgendaByModel(title: String, notes: [Note]) async -> [String]? {
    guard !notes.isEmpty, !limitReached, let llm = cheapLlmClient() else { return nil }
    let material = notes.map { "\($0.title)\n\($0.content)" }.joined(separator: "\n\n")
    let maxChars = llm is AppleIntelligenceClient ? MeetingPrep.appleModelChars : MeetingPrep.modelChars
    let prompt = MeetingPrep.agendaPrompt(title: title, material: material, maxChars: maxChars)
    let reply = try? await llm.chat(messages: [ChatMessage(role: .user, content: prompt)], tools: nil)
    let lines = MeetingPrep.agendaLines(fromModel: reply?.content ?? "")
    return lines.isEmpty ? nil : lines
  }

  /// Zusammenfassung und Aufgaben vom Modell. nil = kein Modell, Fehler oder leere Antwort.
  private func meetingSummaryByModel(title: String, minutes: String) async
    -> (summary: String, tasks: [String])? {
    guard !limitReached, let llm = cheapLlmClient() else { return nil }
    let maxChars = llm is AppleIntelligenceClient ? MeetingPrep.appleModelChars : MeetingPrep.modelChars
    let prompt = MeetingPrep.summaryPrompt(title: title, minutes: minutes, maxChars: maxChars)
    let reply = try? await llm.chat(messages: [ChatMessage(role: .user, content: prompt)], tools: nil)
    guard let text = reply?.content else { return nil }
    let parsed = MeetingPrep.parseSummary(text)
    return parsed.summary.isEmpty ? nil : parsed
  }

  /// Notiz-Rahmen zum Termin mit Agenda aus den gewählten Notizen; eine Termin-Notiz pro Termin.
  public func prepareMeeting(_ id: String, noteIds: [String], taskIds: [String]) async -> ToolResult<Note> {
    guard let meeting = await meetingEvent(id) else {
      return .failure(code: "NOT_FOUND", error: "Termin nicht gefunden.")
    }
    let notes = picked(noteIds, from: (try? store.notes.list()) ?? [])
    let tasks = picked(taskIds, from: (try? store.tasks.list()) ?? [])
    let agenda = await meetingAgendaByModel(title: meeting.title, notes: notes)
      ?? MeetingPrep.fallbackAgenda(notes: notes)
    let frame = MeetingPrep.frame(title: meeting.title, date: MeetingPrep.germanDate(meeting.start),
                                  agenda: agenda, tasks: tasks)
    let note: Note
    do {
      if let existing = try store.notes.get(meetingKey: id) {
        // Agenda neu, Mitschrift und Zusammenfassung bleiben.
        let content = MeetingPrep.refreshed(frame, keeping: existing.content)
        guard let updated = try store.notes.update(existing.id, content: content) else {
          return .failure(code: "ERROR", error: "Die Notiz konnte nicht gespeichert werden.")
        }
        note = updated
      } else {
        note = try store.notes.add(title: "\(meeting.title) – Agenda", content: frame, tags: ["meeting"],
                                   meetingKey: id)
      }
    } catch {
      return .failure(code: "ERROR", error: "Die Notiz konnte nicht gespeichert werden.")
    }
    if p4.meeting?.id == id { p4.meeting?.prepNoteId = note.id }
    emit(.stateChanged)
    return .ok(note)
  }

  /// Zusammenfassung aus der Mitschrift an die Termin-Notiz hängen, Aufgaben anlegen,
  /// Karte schließen (wie submitMeetingNotes).
  public func summarizeMeeting(_ id: String) async -> ToolResult<MeetingNotesResult> {
    guard let note = try? store.notes.get(meetingKey: id) else {
      return .failure(code: "EMPTY", error: "Zu diesem Termin gibt es noch keine Notiz. Bereite den Termin zuerst vor.")
    }
    let minutes = MeetingPrep.mitschrift(in: note.content)
    guard !minutes.isEmpty else {
      return .failure(code: "EMPTY", error: "Die Mitschrift ist leer. Schreib zuerst Stichpunkte in die Termin-Notiz.")
    }
    let title = (await meetingEvent(id))?.title ?? "Termin"
    // Ohne Modell: die Mitschrift selbst ist die Zusammenfassung, ihre Aufzählungspunkte die Aufgaben.
    let model = await meetingSummaryByModel(title: title, minutes: minutes)
    let summary = model?.summary ?? minutes
    let tasks = MeetingPrep.mergedTasks(MeetingCompanion.tasksFromNotes(minutes), model?.tasks ?? [])
    let updated: Note
    do {
      updated = try store.notes.update(note.id, content: MeetingPrep.withSummary(summary, in: note.content)) ?? note
    } catch {
      return .failure(code: "ERROR", error: "Die Zusammenfassung konnte nicht gespeichert werden.")
    }
    var created: [TabyTask] = []
    for t in tasks {
      if case .ok(let task) = await addTask(title: t, notes: "Aus: \(title)", due: nil) {
        created.append(task)
      }
    }
    if p4.meeting?.id == id { p4.meeting = nil }
    emit(.stateChanged)
    return .ok(MeetingNotesResult(note: updated, tasks: created))
  }
}
