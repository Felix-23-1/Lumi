// Paket „Privat nebenbei“ im Integrator: Einkauf/Privates als Apple-Erinnerungen
// (Chat-Werkzeuge) und die Nachbereitung nach einem Termin als Mail-Entwurf.
// Logik in Private/, hier nur die Verdrahtung mit Speicher, Kalender und Mail.
import EventKit
import Foundation

/// Teilnehmer eines Termins aus EventKit (ohne den eigenen Nutzer).
enum FollowUpAttendees {
  static func emails(eventId: String) async -> [String] {
    let urls: [String] = (try? await EventKitStore.shared.run { store -> [String] in
      guard let event = AppleCalendarProvider.occurrence(eventId, in: store) else { return [] }
      return (event.attendees ?? []).filter { !$0.isCurrentUser }.map { $0.url.absoluteString }
    }) ?? []
    return MeetingFollowUp.addresses(from: urls)
  }
}

extension CoreServices {
  /// Chat-Werkzeug „Privates“. nil, wenn der Name nicht dazugehört.
  func privateListTool(_ name: String, _ argsJson: String) async -> JSONValue? {
    guard PrivateListTools.definitions.contains(where: { $0.name == name }) else { return nil }
    return await PrivateListTools.execute(name: name, argumentsJSON: argsJson,
                                          listId: settings.privateListId, backend: remindersBackend)
  }

  /// Öffnet die Nachbereitung als sichtbaren Mail-Entwurf. Sendet nie.
  /// `eventId` ist der Schlüssel des Termins (MeetingBrief.id) oder die Termin-id.
  public func draftMeetingFollowUp(eventId: String) async -> ToolResult<Empty> {
    guard let event = await todaysEvents().first(where: { $0.id == eventId || MeetingCompanion.key($0) == eventId }) else {
      return .failure(code: "NOT_FOUND", error: "Termin nicht gefunden.")
    }
    let attendees = await FollowUpAttendees.emails(eventId: event.id)
    let note = MeetingFollowUp.meetingNote((try? store.notes.list()) ?? [], title: event.title, start: event.start)
    let open = MeetingFollowUp.openTasks((try? store.tasks.list()) ?? [], title: event.title)
    let draft = MeetingFollowUp.draft(title: event.title, start: event.start, to: attendees,
                                      notes: note?.content, openTasks: open)
    do {
      try await mailBackend.openNewDraft(draft)
      return .ok(Empty())
    } catch {
      return .failure(code: "MAIL", error: (error as? MailError)?.errorDescription ?? "Apple Mail hat nicht geantwortet.")
    }
  }
}
