import Foundation

/// Aufgaben-Ordner (lokal, nicht mit Notion synchronisiert). Der Name ist
/// getrimmt, 1…60 Zeichen lang und je Kategorie eindeutig ohne Groß/Klein.
/// Die Kategorie (Kennung aus den Einstellungen, nil = keine) gehört zum Ordner.
extension CoreServices {
  public func addTaskFolder(name: String) async -> ToolResult<TaskFolder> {
    await addTaskFolder(name: name, categoryId: nil)
  }

  public func addTaskFolder(name: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    guard let n = Self.validFolderName(name) else { return .failure(code: "VALIDATION", error: Self.folderNameError) }
    let cat = TaskCategoryRules.normalize(categoryId)
    if let cat, let fail = unknownCategory(cat) { return fail }
    if (try? store.taskFolders.find(name: n, categoryId: cat)) ?? nil != nil {
      return .failure(code: "DUPLICATE", error: "Diesen Ordner gibt es schon.")
    }
    guard let folder = try? store.taskFolders.add(name: n, categoryId: cat) else {
      return .failure(code: "ERROR", error: "Ordner konnte nicht angelegt werden.")
    }
    audit(actor: AuditActor.user, tool: "add_task_folder", confirmed: false, ok: true, summary: "Ordner angelegt")
    emit(.stateChanged)
    return .ok(folder)
  }

  /// Kategorie eines Ordners setzen (nil oder "" = keine). Der Name muss in der neuen Kategorie frei sein.
  public func setTaskFolderCategory(_ id: String, categoryId: String?) async -> ToolResult<TaskFolder> {
    guard let current = (try? store.taskFolders.get(id)) ?? nil else {
      return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
    }
    let cat = TaskCategoryRules.normalize(categoryId)
    if let cat, let fail = unknownCategory(cat) { return fail }
    if let other = (try? store.taskFolders.find(name: current.name, categoryId: cat)) ?? nil, other.id != id {
      return .failure(code: "DUPLICATE", error: "Diesen Ordner gibt es schon.")
    }
    guard let folder = (try? store.taskFolders.setCategory(id, categoryId: cat)) ?? nil else {
      return .failure(code: "ERROR", error: "Kategorie konnte nicht gesetzt werden.")
    }
    if folder.categoryId != current.categoryId { recordFolderCategory(current) }
    audit(actor: AuditActor.user, tool: "set_task_folder_category", confirmed: false, ok: true,
          summary: "Ordner-Kategorie geändert")
    emit(.stateChanged)
    return .ok(folder)
  }

  /// Fehler, wenn die Kennung nicht zu den Kategorien in den Einstellungen gehört; sonst nil.
  private func unknownCategory(_ id: String) -> ToolResult<TaskFolder>? {
    let defs = settings.taskCategories
    guard defs.contains(where: { $0.id == id }) else {
      return .failure(code: "VALIDATION", error: TaskCategoryRules.unknownMessage(id, in: defs))
    }
    return nil
  }

  public func renameTaskFolder(_ id: String, name: String) async -> ToolResult<TaskFolder> {
    guard let n = Self.validFolderName(name) else { return .failure(code: "VALIDATION", error: Self.folderNameError) }
    guard let current = (try? store.taskFolders.get(id)) ?? nil else {
      return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
    }
    if let other = (try? store.taskFolders.find(name: n, categoryId: current.categoryId)) ?? nil, other.id != current.id {
      return .failure(code: "DUPLICATE", error: "Diesen Ordner gibt es schon.")
    }
    guard let folder = try? store.taskFolders.rename(id, name: n) ?? nil else {
      return .failure(code: "ERROR", error: "Ordner konnte nicht umbenannt werden.")
    }
    emit(.stateChanged)
    return .ok(folder)
  }

  /// Löscht nur den Ordner; seine Aufgaben bleiben erhalten (ohne Ordner).
  public func deleteTaskFolder(_ id: String) async -> ToolResult<Empty> {
    let folder = (try? store.taskFolders.get(id)) ?? nil
    let taskIds = ((try? store.tasks.list()) ?? []).filter { $0.folderId == id }.map(\.id)
    guard let deleted = try? store.taskFolders.delete(id), deleted else {
      return .failure(code: "NOT_FOUND", error: "Ordner nicht gefunden.")
    }
    if let folder { recordFolderDeletion(folder, taskIds: taskIds) }
    emit(.stateChanged)
    return .ok(Empty())
  }

  static let folderNameError = "Ordnername fehlt oder ist zu lang."

  /// Getrimmter Name mit 1…60 Zeichen, sonst nil.
  static func validFolderName(_ raw: String) -> String? {
    let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return (1...60).contains(n.count) ? n : nil
  }
}
