import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  private static let captureInstruction = """
    Schnellerfassung – lege den Gedanken aus der Nutzernachricht ohne Rückfrage passend an: \
    als Aufgabe (mit Fälligkeit, falls genannt), als Termin (wenn Datum und Uhrzeit genannt sind) \
    oder als Notiz. Antworte danach in einem kurzen Satz, was du angelegt hast.
    """

  /// Schnellerfassung: der Gedanke geht nie verloren. Mit Modell sortiert ihn der
  /// Agent ein; die Anweisung steht nur im Systemprompt, der Verlauf zeigt den
  /// Originaltext. Ohne Modell, offline oder bei jedem Modellfehler wird er als
  /// Aufgabe gespeichert. Nur was gespeichert ist, gilt als Erfolg.
  public func quickCapture(_ text: String) async throws -> [ChatMessage] {
    messenger.noteIslandUse()
    let savedNote = [ChatMessage(role: .assistant, content: "Als Aufgabe gespeichert (ohne Modell).")]
    guard llmClient() != nil else {
      try saveCaptureAsTask(text)
      return savedNote
    }
    let before = captureItemIds()
    let firstLine = Self.normalizedForMatch(String(text.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(while: { $0 != "\n" })))
    do {
      // Erfasster Text kann fremd sein (markierte Webseite): nur Anlegen erlaubt, nichts Mächtigeres.
      let messages = try await chatTurn(text, systemNote: Self.captureInstruction,
                                        toolFilter: { ["add_task", "add_note", "add_event"].contains($0) })
      // Nur Text geantwortet, nichts angelegt: der Gedanke wird trotzdem als Aufgabe gesichert.
      if captureItemIds().subtracting(before).isEmpty {
        try saveCaptureAsTask(text)
        return messages + [ChatMessage(role: .assistant,
                                       content: "Das Modell hat nichts angelegt, deshalb als Aufgabe gespeichert.")]
      }
      return messages
    } catch {
      // Gespeichert gilt nur, wenn ein NEUES Element den Gedanken enthält (sonst doppelt speichern).
      if capturedItemExists(before: before, firstLine: firstLine) {
        return [ChatMessage(role: .assistant, content: "Gespeichert.")]
      }
      // Modellfehler, Netz, Kontingent oder laufender Chat: Gedanken trotzdem sichern.
      try saveCaptureAsTask(text)
      return savedNote
    }
  }

  /// IDs aller Aufgaben und Notizen, mit Präfix getrennt (für den Vorher-/Nachher-Vergleich).
  private func captureItemIds() -> Set<String> {
    let tasks = ((try? store.tasks.list()) ?? []).map { "t:" + $0.id }
    let notes = ((try? store.notes.list()) ?? []).map { "n:" + $0.id }
    return Set(tasks + notes)
  }

  /// Ob ein seit `before` neu angelegtes Element die erste Zeile des Gedankens enthält.
  private func capturedItemExists(before: Set<String>, firstLine: String) -> Bool {
    guard !firstLine.isEmpty else { return false }
    let tasks = ((try? store.tasks.list()) ?? []).filter { !before.contains("t:" + $0.id) }
      .map { Self.normalizedForMatch($0.title + " " + ($0.notes ?? "")) }
    let notes = ((try? store.notes.list()) ?? []).filter { !before.contains("n:" + $0.id) }
      .map { Self.normalizedForMatch($0.title + " " + $0.content) }
    return (tasks + notes).contains { $0.contains(firstLine) }
  }

  /// Groß-/Kleinschreibung, Akzente und Leerraum egal.
  static func normalizedForMatch(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Erste Zeile wird der Titel (max. 120 Zeichen), der Rest die Notiz.
  private func saveCaptureAsTask(_ text: String) throws {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { throw LlmError(.unknown, "Der Gedanke ist leer.") }
    var title = String(t.prefix(while: { $0 != "\n" }).prefix(120)).trimmingCharacters(in: .whitespaces)
    let rest = String(t.dropFirst(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    // Datum/Uhrzeit aus der ersten Zeile (offline); bleibt der Titel leer, bleibt der Originaltext.
    let parsed = GermanDateParser.parse(title, now: clock.now())
    if !parsed.title.isEmpty { title = parsed.title }
    do {
      _ = try store.tasks.add(title: title, notes: rest.isEmpty ? nil : rest, due: parsed.due)
    } catch {
      throw LlmError(.unknown, "Konnte nicht gespeichert werden. Der Text bleibt im Feld.")
    }
    changed()
  }
}
