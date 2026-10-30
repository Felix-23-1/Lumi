import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  public func addTask(title: String, notes: String?, due: String?) async -> ToolResult<TabyTask> {
    var args: [String: JSONValue] = ["title": .string(title)]
    if let notes { args["notes"] = .string(notes) }
    if let due { args["due"] = .string(due) }
    return await mutate("add_task", args, key: "task")
  }

  public func updateTask(_ id: String, _ patch: TaskPatch) async -> ToolResult<TabyTask> {
    var args: [String: JSONValue] = ["id": .string(id)]
    if let v = patch.title { args["title"] = .string(v) }
    if let v = patch.notes { args["notes"] = .string(v) }
    if let v = patch.due { args["due"] = v.isEmpty ? .null : .string(v) }  // "" = Fälligkeit entfernen
    if let v = patch.category { args["category"] = .string(v) }
    if let v = patch.recurrence { args["recurrence"] = .string(v) }  // "" = keine Wiederholung
    if let v = patch.tags { args["tags"] = .array(v.map { .string($0) }) }
    if let v = patch.status { args["status"] = .string(v) }  // "" = offen
    if let v = patch.minutes { args["minutes"] = v > 0 ? .number(Double(v)) : .null }
    if let v = patch.folderId {
      if v.isEmpty {
        args["folder"] = .string("")  // "" = aus dem Ordner nehmen
      } else {
        guard let folder = (try? store.taskFolders.get(v)) ?? nil else {
          return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
        }
        args["folder"] = .string(folder.name)
      }
    }
    let r: ToolResult<TabyTask> = await mutate("update_task", args, key: "task")
    if r.isOk, patch.due != nil { await taskDueChanged(id) }
    return r
  }

  public func completeTask(_ id: String) async -> ToolResult<TabyTask> {
    // Notion-Haken: setzt runUndoable (ein Weg für alle Quellen).
    return await mutate("complete_task", ["id": .string(id)], key: "task")
  }

  public func reopenTask(_ id: String) async -> ToolResult<TabyTask> {
    // Notion-Haken: setzt runUndoable (ein Weg für alle Quellen).
    return await mutate("reopen_task", ["id": .string(id)], key: "task")
  }

  public func deleteTask(_ id: String) async -> ToolResult<Empty> {
    await mutateEmpty("delete_task", ["id": .string(id)])
  }

  public func addNote(title: String, content: String) async -> ToolResult<Note> {
    await mutate("add_note", ["title": .string(title), "content": .string(content)], key: "note")
  }

  public func updateNote(_ id: String, _ patch: NotePatch) async -> ToolResult<Note> {
    var args: [String: JSONValue] = ["id": .string(id)]
    if let v = patch.title { args["title"] = .string(v) }
    if let v = patch.content { args["content"] = .string(v) }
    if let v = patch.tags { args["tags"] = .array(v.map { .string($0) }) }
    if let v = patch.taskId {
      // "" löst die Zuordnung; sonst muss die Aufgabe existieren.
      if !v.isEmpty, ((try? store.tasks.get(v)) ?? nil) == nil {
        return .failure(code: "NOT_FOUND", error: "Aufgabe nicht gefunden.")
      }
      args["task"] = .string(v)
    }
    return await mutate("update_note", args, key: "note")
  }

  public func deleteNote(_ id: String) async -> ToolResult<Empty> {
    await mutateEmpty("delete_note", ["id": .string(id)])
  }

  public func addHabit(name: String, description: String?) async -> ToolResult<Habit> {
    var args: [String: JSONValue] = ["name": .string(name)]
    if let description { args["description"] = .string(description) }
    return await mutate("add_habit", args, key: "habit")
  }

  public func checkHabit(_ id: String, date: String) async -> ToolResult<Habit> {
    await mutate("check_habit", ["id": .string(id), "date": .string(date)], key: "habit")
  }

  public func deleteHabit(_ id: String) async -> ToolResult<Empty> {
    await mutateEmpty("delete_habit", ["id": .string(id)])
  }
}
