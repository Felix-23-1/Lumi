// Aufgaben aus der Mitschrift: erkennen (nichts anlegen) und nach deiner Auswahl anlegen.
// Erkennung und Prüfungen liegen in Productivity/ActionItems.swift; das Modell formuliert nur.
import Foundation

extension CoreServices {
  public func extractMeetingActions(_ id: String) async -> ToolResult<[ActionCandidate]> {
    guard let note = try? store.notes.get(meetingKey: id) else {
      return .failure(code: "EMPTY", error: "Zu diesem Termin gibt es noch keine Notiz.")
    }
    let lines = ActionItems.parse(MeetingPrep.mitschrift(in: note.content))
    guard !lines.isEmpty else {
      return .failure(code: "EMPTY", error: "Die Mitschrift ist leer. Es gibt nichts zu prüfen.")
    }
    let reference = (await meetingEvent(id)).flatMap { LocalTime.parse($0.start) } ?? clock.now()
    let llm = limitReached ? nil : cheapLlmClient()
    let maxChars = llm is AppleIntelligenceClient ? MeetingPrep.appleModelChars : MeetingPrep.modelChars

    var found: [ActionCandidate] = []
    for (marker, context) in ActionItems.markerContexts(lines: lines) {
      var text: String?
      if let llm, !context.isEmpty {
        let reply = try? await llm.chat(messages: [ChatMessage(role: .user, content: ActionItems.markerPrompt(context: context))], tools: nil)
        text = (reply?.content ?? "").components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
          .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t\"„“")) }
      }
      found.append(ActionItems.markedCandidate(marker: marker, context: context, modelText: text, today: reference))
    }
    var fromModel: [ActionCandidate] = []
    if let llm {
      let prompt = ActionItems.prompt(lines: lines, maxChars: maxChars)
      let reply = try? await llm.chat(messages: [ChatMessage(role: .user, content: prompt)], tools: nil)
      if let raws = reply?.content.flatMap { ActionItems.parseReply($0) } {
        fromModel = ActionItems.candidates(from: raws, lines: lines, today: reference)
      }
    }
    found += fromModel.isEmpty ? ActionItems.fallbackCandidates(lines: lines, today: reference) : fromModel
    return .ok(ActionItems.merged(found))
  }

  public func acceptMeetingActions(_ id: String, _ items: [ActionCandidate]) async -> ToolResult<[TabyTask]> {
    let noteTitle = (try? store.notes.get(meetingKey: id))??.title ?? "Termin-Notiz"
    var open = Set(((try? store.tasks.list()) ?? []).filter { !$0.done }.map { $0.title.lowercased() })
    var created: [TabyTask] = []
    for item in items {
      let waiting = item.owner.flatMap { $0.lowercased() == "ich" || $0.isEmpty ? nil : $0 }
      let title = waiting.map { "Warten auf \($0): \(item.text)" } ?? item.text
      guard open.insert(title.lowercased()).inserted else { continue }
      var notes = item.evidence.isEmpty ? "" : "„\(item.evidence)“ "
      notes += "[\(ActionItems.stamp(item.atSeconds))]\nAus: \(noteTitle)"
      guard case .ok(var task) = await addTask(title: title, notes: notes, due: item.due) else { continue }
      let patch = TaskPatch(status: waiting == nil ? nil : TaskStatus.needsInfo.rawValue,
                            tags: waiting == nil ? ["meeting"] : ["meeting", "wartet-auf"])
      if case .ok(let updated) = await updateTask(task.id, patch) { task = updated }
      created.append(task)
    }
    emit(.stateChanged)
    return .ok(created)
  }
}
