// Aktionen der Ansichten: rufen den Kern über `model.services`, laden danach
// den Zustand neu und lassen das Maskottchen reagieren. Getrennt von den
// Ansichten, damit ViewChecks sie gegen FakeServices prüfen kann.
import Foundation
import SwiftUI
import TabyCore

@MainActor
enum ViewActions {
  /// Fehlermeldung oder nil.
  @discardableResult
  /// `category` nil = ohne Kategorie; sonst direkt nach dem Anlegen gesetzt.
  /// `onCreated` läuft, sobald die Aufgabe existiert – auch wenn danach die Kategorie scheitert.
  /// Dann nur die Fehlermeldung zeigen: eine erneute Eingabe würde sonst ein Duplikat anlegen.
  /// `folderId` nil = in keinem Ordner; sonst wie `category` direkt nach dem Anlegen gesetzt.
  static func addTask(_ model: AppModel, title: String, due: String?, category: TaskCategory? = nil,
                      notes: String? = nil, folderId: String? = nil, recurrence: TaskRecurrence? = nil,
                      minutes: Int? = nil, tags: [String] = [], onCreated: () -> Void = {}) async -> String? {
    if let err = TaskLogic.validateTitle(title) { return err }
    let r = await model.services.addTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes,
                                         due: due)
    var error = r.errorMessage
    if error == nil, r.value != nil { onCreated() }
    if error == nil, category != nil || folderId != nil || recurrence != nil || minutes != nil || !tags.isEmpty,
       let id = r.value?.id {
      let patch = TaskPatch(category: category?.rawValue, folderId: folderId,
                            recurrence: recurrence.map { ViewSupportLogic.recurrencePatch($0) }, minutes: minutes,
                            tags: tags.isEmpty ? nil : tags)
      let u = await model.services.updateTask(id, patch)
      error = u.errorMessage.map { "Aufgabe angelegt, aber Kategorie, Ordner, Wiederholung, Dauer oder Kennzeichen fehlt: \($0)" }
    }
    return await finish(model, error, success: .itemAdded)
  }

  /// Kennzeichen einer Aufgabe setzen; [] entfernt alle.
  @discardableResult
  static func setTaskTags(_ model: AppModel, id: String, tags: [String]) async -> String? {
    let r = await model.services.updateTask(id, TaskPatch(tags: tags))
    return await finish(model, r.errorMessage, success: nil)
  }

  /// Kennzeichen einer Notiz setzen; [] entfernt alle.
  @discardableResult
  static func setNoteTags(_ model: AppModel, id: String, tags: [String]) async -> String? {
    let r = await model.services.updateNote(id, NotePatch(tags: tags))
    return await finish(model, r.errorMessage, success: nil)
  }

  /// Fälligkeit setzen; nil entfernt sie (leerer Patch-Wert "", wie bei der Kategorie).
  @discardableResult
  static func setTaskDue(_ model: AppModel, id: String, due: String?) async -> String? {
    let r = await model.services.updateTask(id, TaskPatch(due: due ?? ""))
    return await finish(model, r.errorMessage, success: nil)
  }

  @discardableResult
  static func setTaskDone(_ model: AppModel, id: String, done: Bool) async -> String? {
    let r: ToolResult<TabyTask>
    if done { r = await model.services.completeTask(id) } else { r = await model.services.reopenTask(id) }
    return await finish(model, r.errorMessage, success: done ? .taskCompleted : nil)
  }

  @discardableResult
  static func renameTask(_ model: AppModel, id: String, title: String) async -> String? {
    if let err = TaskLogic.validateTitle(title) { return err }
    let r = await model.services.updateTask(id, TaskPatch(title: title.trimmingCharacters(in: .whitespaces)))
    return await finish(model, r.errorMessage, success: nil)
  }

  @discardableResult
  static func deleteTask(_ model: AppModel, id: String) async -> String? {
    let r = await model.services.deleteTask(id)
    return await finish(model, r.errorMessage, success: .itemDeleted)
  }

  /// Aufgabe in einen Ordner setzen; nil nimmt sie heraus ("" im Patch).
  @discardableResult
  static func setTaskFolder(_ model: AppModel, id: String, folderId: String?) async -> String? {
    let r = await model.services.updateTask(id, TaskPatch(folderId: folderId ?? ""))
    return await finish(model, r.errorMessage, success: nil)
  }

  /// Bearbeitungsstand setzen (`.open` wird als "" gesendet, siehe `TaskStatusLogic.patchValue`).
  @discardableResult
  static func setTaskStatus(_ model: AppModel, id: String, status: TaskStatus) async -> String? {
    let r = await model.services.updateTask(id, TaskPatch(status: TaskStatusLogic.patchValue(status)))
    return await finish(model, r.errorMessage, success: nil)
  }

  @discardableResult
  static func addFolder(_ model: AppModel, name: String) async -> String? {
    let r = await model.services.addTaskFolder(name: name)
    return await finish(model, r.errorMessage, success: nil)
  }

  @discardableResult
  static func renameFolder(_ model: AppModel, id: String, name: String) async -> String? {
    let r = await model.services.renameTaskFolder(id, name: name)
    return await finish(model, r.errorMessage, success: nil)
  }

  /// Löscht nur den Ordner; die Aufgaben bleiben (der Kern nimmt sie heraus).
  @discardableResult
  static func deleteFolder(_ model: AppModel, id: String) async -> String? {
    let r = await model.services.deleteTaskFolder(id)
    return await finish(model, r.errorMessage, success: .itemDeleted)
  }

  @discardableResult
  static func addNote(_ model: AppModel, title: String, content: String) async -> String? {
    if let err = TaskLogic.validateTitle(title) { return err }
    let r = await model.services.addNote(title: title.trimmingCharacters(in: .whitespaces), content: content)
    return await finish(model, r.errorMessage, success: .itemAdded)
  }

  @discardableResult
  static func updateNote(_ model: AppModel, id: String, title: String, content: String) async -> String? {
    if let err = TaskLogic.validateTitle(title) { return err }
    let r = await model.services.updateNote(id, NotePatch(title: title.trimmingCharacters(in: .whitespaces),
                                                          content: content))
    return await finish(model, r.errorMessage, success: nil)
  }

  /// Ordnet eine Notiz einer Aufgabe zu; "" löst die Zuordnung.
  @discardableResult
  static func setNoteTask(_ model: AppModel, id: String, taskId: String) async -> String? {
    let r = await model.services.updateNote(id, NotePatch(taskId: taskId))
    return await finish(model, r.errorMessage, success: nil)
  }

  @discardableResult
  static func deleteNote(_ model: AppModel, id: String) async -> String? {
    let r = await model.services.deleteNote(id)
    return await finish(model, r.errorMessage, success: .itemDeleted)
  }

  static func acknowledgeMissed(_ model: AppModel, ids: [String]) async {
    await model.services.acknowledgeMissed(ids)
    await model.refresh()
  }

  /// Termin-Notiz mit Agenda anlegen (bzw. ergänzen); Fehlermeldung oder nil.
  @discardableResult
  static func prepareMeeting(_ model: AppModel, _ id: String, noteIds: [String], taskIds: [String]) async -> String? {
    let r = await model.services.prepareMeeting(id, noteIds: noteIds, taskIds: taskIds)
    return await finish(model, r.errorMessage, success: .itemAdded)
  }

  /// Zusammenfassung nach dem Termin: Fehlermeldung (oder nil) und Anzahl angelegter Aufgaben.
  static func summarizeMeeting(_ model: AppModel, _ id: String) async -> (error: String?, tasks: Int) {
    let r = await model.services.summarizeMeeting(id)
    let error = await finish(model, r.errorMessage, success: .celebrate)
    return (error, r.value?.tasks.count ?? 0)
  }

  /// Mitschrift starten; Fehlermeldung oder nil. Bei „Alle“ ohne Einwilligung meldet der Kern einen Fehler.
  @discardableResult
  static func startListening(_ model: AppModel, _ id: String, mode: MeetingListenMode, consentGiven: Bool) async -> String? {
    let r = await model.services.startMeetingListening(id, mode: mode, consentGiven: consentGiven)
    return await finish(model, r.errorMessage, success: .itemAdded)
  }

  /// Aufgaben-Kandidaten aus der Mitschrift (nichts wird angelegt): Liste und Fehlermeldung.
  static func extractListenActions(_ model: AppModel, _ id: String) async -> (items: [ActionCandidate], error: String?) {
    let r = await model.services.extractMeetingActions(id)
    let error = await finish(model, r.errorMessage, success: nil)
    return (r.value ?? [], error)
  }

  /// Bestätigte Kandidaten als Aufgaben anlegen: Anzahl und Fehlermeldung.
  static func acceptListenActions(_ model: AppModel, _ id: String, _ items: [ActionCandidate]) async -> (count: Int, error: String?) {
    let r = await model.services.acceptMeetingActions(id, items)
    let error = await finish(model, r.errorMessage, success: .itemAdded)
    return (r.value?.count ?? 0, error)
  }

  enum EventOutcome: Equatable {
    case saved(info: String?, unreachable: String?)
    case conflict(message: String, pending: NewEvent, tight: Bool = false)
    case failed(String)
  }

  /// Termin anlegen. Bei Konflikt wird NICHTS gespeichert; erst
  /// `allowConflict: true` (Knopf "Trotzdem speichern") speichert (Szenario A).
  static func addEvent(_ model: AppModel, _ event: NewEvent, allowConflict: Bool, today: String) async
    -> EventOutcome
  {
    let r = await model.services.addEvent(AddEventRequest(event: event, allowConflict: allowConflict))
    switch r {
    case .ok(_, let info, let unreachable):
      await model.refresh()
      model.react(.itemAdded)
      return .saved(info: CalendarLogic.infoMessage(info, today: today),
                    unreachable: CalendarLogic.unreachableMessage(unreachable))
    case .conflict(let error, let conflicts):
      return .conflict(message: CalendarLogic.conflictMessage(error: error, conflicts: conflicts, today: today,
                                                              bufferMinutes: model.state?.settings.bufferMinutes ?? 0),
                       pending: event, tight: CalendarLogic.onlyTooClose(conflicts))
    case .failure(_, let error):
      model.react(.failed(error))
      return .failed(error)
    }
  }

  /// Gemeinsamer Abschluss einer Aktion: lädt den Zustand neu, meldet Fehler und gibt sie zurück (nil = erledigt).
  static func finish(_ model: AppModel, _ error: String?, success: UIReaction?) async -> String? {
    await model.refresh()
    if let error {
      model.react(.failed(error))
      return error
    }
    if let success { model.react(success) }
    return nil
  }
}

// MARK: - Chat

/// Zustand des Chats (Eingabe, Warten, Fehler, Abbruch).
@MainActor
final class ChatController: ObservableObject {
  /// Ein Chat für die ganze App: überlebt Reiterwechsel, damit eine laufende Antwort fertig wird.
  static let shared = ChatController()
  @Published var input = ""
  @Published private(set) var thinking = false
  @Published private(set) var error: String?
  @Published private(set) var notices: [String] = []
  /// Gerade gesendeter Text, bis die Antwort da ist (sofort sichtbar).
  @Published private(set) var pendingUserText: String?
  /// Live-Teil der laufenden Antwort (gebündelt aus dem Strom), bis die fertigen Nachrichten da sind.
  @Published private(set) var partialText: String?
  private var task: Task<Void, Never>?

  init(thinking: Bool = false, error: String? = nil, pendingUserText: String? = nil, consentRetry: String? = nil) {
    self.thinking = thinking; self.error = error; self.pendingUserText = pendingUserText
    self.consentRetry = consentRetry
  }

  var canSend: Bool { !thinking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// Eingabe kam per Mikrofon: die Antwort wird vorgelesen (gesprochen rein → gesprochen raus).
  var dictated = false

  func send(_ model: AppModel) {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !thinking else { return }
    input = ""
    let speak = dictated
    dictated = false
    submit(text, model, speak: speak)
  }

  /// Einwilligung fehlt: der Text wartet, bis der Nutzer im Chat zustimmt (nichts ist gesendet).
  @Published private(set) var consentRetry: String?

  /// Bitte zu den abgelegten Dateien (Knöpfe der Datei-Karte).
  func ask(_ text: String, _ model: AppModel) {
    guard !thinking else { return }
    submit(text, model)
  }

  private func submit(_ text: String, _ model: AppModel, speak: Bool = false) {
    error = nil
    notices = []
    consentRetry = nil
    pendingUserText = text
    setThinking(true, model)
    let files = model.takeDroppedFiles()
    task = Task { [weak self] in
      do {
        if files.isEmpty {
          _ = try await model.services.chatSendStreaming(text) { [weak self] partial in
            self?.showPartial(partial)
          }
        } else {
          for path in files { _ = try await model.services.askAboutFile(path: path, request: text) }
        }
        try Task.checkCancellation()
        self?.partialText = nil
        await model.refresh()
        self?.done(model)
        if speak, let reply = VoiceChat.reply(after: text, in: model.state?.messages ?? []) {
          await model.services.speakReply(reply)
        }
      } catch {
        guard let self else { return }
        if Task.isCancelled { return }
        if (error as? LlmError)?.message == PrivacyGate.consentCode {
          model.droppedFiles = files  // nach „Einverstanden“ gehen die Dateien mit
          self.consentRetry = text
          self.done(model)
          await model.refresh()
          return
        }
        self.error = ChatLogic.errorToGerman(error)
        if let e = self.error { model.react(.failed(e)) }
        self.done(model)
        await model.refresh()
      }
    }
  }

  /// „Einverstanden“ (Zeitpunkt jetzt) oder „Nur lokal nutzen“; danach geht der wartende Text ab.
  func consent(_ model: AppModel, localOnly: Bool, now: String) {
    guard let text = consentRetry else { return }
    Task {
      let consent = PrivacyGate.consentValue(at: now, baseUrl: model.state?.settings.llmBaseUrl ?? "")
      let patch = localOnly ? SettingsPatch(localOnly: true) : SettingsPatch(cloudConsentAt: consent)
      _ = await model.services.updateSettings(patch, apiKey: nil)
      await model.refresh()
      submit(text, model)
    }
  }

  /// Wartet auf die laufende Anfrage (für Prüfungen).
  func wait() async { await task?.value }

  func cancel(_ model: AppModel) {
    guard thinking else { return }
    task?.cancel()
    task = nil
    notices.append("Abgebrochen.")
    done(model)
  }

  func clear(_ model: AppModel) async {
    await model.services.chatClear()
    notices = []
    error = nil
    await model.refresh()
  }

  func dismissError() { error = nil }

  private func showPartial(_ text: String) {
    if thinking { partialText = text }
  }

  private func done(_ model: AppModel) {
    pendingUserText = nil
    partialText = nil
    setThinking(false, model)
  }

  private func setThinking(_ v: Bool, _ model: AppModel) {
    thinking = v
    model.isThinking = v
  }
}

// MARK: - Gespräch

/// Gesprächsmodus: zuhören → nach kurzer Pause senden → Antwort vorlesen → wieder zuhören.
@MainActor
final class VoiceChat: ObservableObject {
  @Published private(set) var active = false
  private var loop: Task<Void, Never>?
  /// So lange Stille (unveränderter Text), dann gilt der Satz als fertig.
  static let pauseSeconds = 1.5
  static let endWords: Set<String> = ["stopp", "stop", "ende", "tschüss", "danke das wars", "gespräch beenden"]

  func toggle(_ chat: ChatController, _ model: AppModel) {
    if active { stop(model) } else { start(chat, model) }
  }

  func start(_ chat: ChatController, _ model: AppModel) {
    guard !active else { return }
    active = true
    loop = Task { [weak self] in await self?.run(chat, model) }
  }

  func stop(_ model: AppModel) {
    guard active else { return }
    active = false
    loop?.cancel()
    loop = nil
    model.services.stopSpeaking()
    Task {
      await model.stopListening(submit: false)
      model.captureDraft = nil
    }
  }

  /// Antwort auf die eben gesprochene Frage: letzte Assistenten-Nachricht nach der letzten Nutzer-Nachricht.
  /// (Nicht über die Anzahl: der Zustand hält nur die letzten 80 Nachrichten.)
  static func reply(after text: String, in messages: [ChatMessage]) -> String? {
    guard let i = messages.lastIndex(where: { $0.role == .user }), messages[i].content == text else { return nil }
    return messages[(i + 1)...].last(where: { $0.role == .assistant && !($0.content ?? "").isEmpty })?.content
  }

  static func isEnd(_ text: String) -> Bool {
    endWords.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
  }

  private func run(_ chat: ChatController, _ model: AppModel) async {
    while active, !Task.isCancelled {
      await model.startListening()
      guard model.listening else { active = false; return }
      var last = ""
      var still = 0.0
      while active, !Task.isCancelled, still < Self.pauseSeconds {
        try? await Task.sleep(for: .milliseconds(300))
        let t = model.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != last { last = t; still = 0 } else if !t.isEmpty { still += 0.3 }
      }
      guard active, !Task.isCancelled else { return }
      await model.stopListening(submit: false)
      guard let text = model.captureDraft, !text.isEmpty else { continue }
      model.captureDraft = nil
      if Self.isEnd(text) { active = false; return }
      chat.ask(text, model)
      await chat.wait()
      guard active, !Task.isCancelled else { return }
      if let reply = Self.reply(after: text, in: model.state?.messages ?? []) {
        await model.services.speakReply(reply)
      } else if let err = chat.error {
        await model.services.speakReply(err)
      }
    }
  }
}
