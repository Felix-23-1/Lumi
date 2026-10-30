// Führt den Abgleich aus: holt beide Seiten, plant mit `ReminderSyncPlanner`
// und wendet jede Aktion an. Fehler je Aktion werden gesammelt, der Lauf
// geht weiter. Geworfen wird nur, wenn kein Zugriff auf Erinnerungen besteht.
import Foundation

public final class ReminderSyncEngine {
  private let backend: RemindersBackend
  private let taskSide: TaskSide

  public init(backend: RemindersBackend, taskSide: TaskSide) {
    self.backend = backend
    self.taskSide = taskSide
  }

  /// listId: Zielliste. Neue Erinnerungen werden dort angelegt, und nur unverknüpfte Erinnerungen
  /// aus dieser Liste werden zu Aufgaben (nil = Standardliste bzw. alle Listen).
  /// now: lokaler ISO-String ("YYYY-MM-DDTHH:mm"), wird als `syncedAt` gespeichert.
  ///
  /// Ein Listenwechsel löscht nie etwas: Es werden immer alle Listen abgerufen, bestehende
  /// Verknüpfungen bleiben unverändert, und eine verknüpfte Erinnerung in einer anderen Liste
  /// gilt nicht als fehlend.
  /// excludedTaskIds: Aufgaben, die nie nach Apple angelegt werden (z. B. Notion-Aufgaben).
  public func sync(listId: String?, now: String, excludedTaskIds: Set<String> = []) async throws -> SyncReport {
    guard await backend.requestAccess() else { throw RemindersError.accessDenied }
    var report = SyncReport()

    let tasks: [TabyTask]
    let links: [ReminderLink]
    let external: [ExternalReminder]
    do {
      tasks = try taskSide.tasks()
      links = try taskSide.links()
      // Immer alle Listen: Existenz und Löschung werden listenübergreifend beurteilt.
      external = try await backend.fetchAll(listIds: nil)
    } catch {
      report.errors.append("Abgleich abgebrochen: \(error.localizedDescription)")
      return report
    }

    let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let extById = Dictionary(external.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let linkByTask = Dictionary(links.map { ($0.taskId, $0) }, uniquingKeysWith: { first, _ in first })
    let linkByExt = Dictionary(links.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })

    let actions = ReminderSyncPlanner.plan(tasks: tasks, external: external, links: links, importListId: listId,
                                           excludedTaskIds: excludedTaskIds)
    // Schutz gegen Massenlöschung: fehlen Aufgaben in Lumi (Erinnerungen würden gelöscht), oder ist eine
    // ganze Liste verschwunden. Fehlende Erinnerungen in Apple zählen nicht: sie löschen keine Aufgabe.
    let missingInTaby = actions.filter { if case .deleteExternal = $0 { return true } else { return false } }.count
    let massDeletion = ReminderSyncPlanner.isMassDeletion(missing: missingInTaby, linked: links.count, externalCount: external.count)
      || ReminderSyncPlanner.isListVanished(links: links, externalIds: Set(extById.keys))
    if massDeletion {
      report.errors.append(Self.pausedMessage)
      return report
    }
    // Ältere Verknüpfungen ohne Listenangabe nachtragen, damit die Listen-Prüfung greift.
    for link in links where link.listId == nil {
      guard let list = extById[link.externalId]?.listId else { continue }
      try? taskSide.saveLink(ReminderLink(taskId: link.taskId, externalId: link.externalId, snapTitle: link.snapTitle,
                                          snapDue: link.snapDue, snapDone: link.snapDone, syncedAt: link.syncedAt,
                                          listId: list))
    }
    for action in actions {
      do {
        switch action {
        case .createExternal(let taskId):
          guard let t = taskById[taskId] else { continue }
          let newId = try await backend.create(
            ExternalReminder(id: "", title: t.title, notes: t.notes, due: t.due, done: false), listId: listId)
          try taskSide.saveLink(ReminderLink(
            taskId: t.id, externalId: newId, snapTitle: t.title, snapDue: t.due, snapDone: false, syncedAt: now,
            listId: listId))
          report.createdExternal += 1

        case .createTask(let externalId):
          guard let r = extById[externalId] else { continue }
          let t = try taskSide.addTask(title: r.title, notes: r.notes, due: r.due)
          try taskSide.saveLink(ReminderLink(
            taskId: t.id, externalId: r.id, snapTitle: r.title, snapDue: r.due, snapDone: r.done, syncedAt: now,
            listId: r.listId))
          report.createdTask += 1

        case .pushToExternal(let taskId):
          guard let t = taskById[taskId], let link = linkByTask[taskId] else { continue }
          // Notizen werden nur beim Anlegen kopiert: beim Push bleibt die Apple-Notiz stehen.
          let currentNotes = extById[link.externalId]?.notes
          try await backend.update(ExternalReminder(
            id: link.externalId, title: t.title, notes: currentNotes, due: t.due, done: t.done))
          try taskSide.saveLink(ReminderLink(
            taskId: t.id, externalId: link.externalId, snapTitle: t.title, snapDue: t.due, snapDone: t.done,
            syncedAt: now, listId: extById[link.externalId]?.listId ?? link.listId))
          report.pushed += 1

        case .pullToTask(let externalId):
          guard let r = extById[externalId], let link = linkByExt[externalId] else { continue }
          // Notizen werden nur beim Anlegen kopiert: beim Pull bleibt die Lumi-Notiz stehen.
          let currentNotes = taskById[link.taskId]?.notes
          // Hatte Lumi seit dem letzten Abgleich ebenfalls geändert, geht diese Änderung verloren (Apple gewinnt).
          if let t = taskById[link.taskId], t.title != link.snapTitle || t.due != link.snapDue || t.done != link.snapDone {
            report.overwrittenLumiEdits.append(link.taskId)
          }
          try taskSide.updateTask(id: link.taskId, title: r.title, notes: currentNotes, due: r.due)
          try taskSide.setDone(id: link.taskId, done: r.done)
          try taskSide.saveLink(ReminderLink(
            taskId: link.taskId, externalId: r.id, snapTitle: r.title, snapDue: r.due, snapDone: r.done,
            syncedAt: now, listId: r.listId))
          report.pulled += 1

        case .deleteTask(let taskId):
          // Nie löschen und nie neu anlegen: die offene Aufgabe bleibt in Lumi, die Verknüpfung auch.
          report.removedFromApple.append(taskId)

        case .deleteExternal(let externalId):
          try await backend.delete(id: externalId)
          if let link = linkByExt[externalId] {
            try taskSide.deleteLink(taskId: link.taskId)
          }
          report.deletedExternal += 1

        case .unlink(let taskId):
          try taskSide.deleteLink(taskId: taskId)
          report.unlinked += 1
        }
      } catch {
        report.errors.append("\(Self.describe(action, taskById, extById)): \(error.localizedDescription)")
      }
    }
    return report
  }

  static let pausedMessage = "Abgleich mit Erinnerungen pausiert: Apple meldet viele Erinnerungen als fehlend. Keine Aufgaben gelöscht."

  /// Deutsche Beschreibung einer Aktion für die Fehlerliste.
  private static func describe(_ action: SyncAction, _ tasks: [String: TabyTask],
                               _ ext: [String: ExternalReminder]) -> String {
    switch action {
    case .createExternal(let id):
      return "Aufgabe „\(tasks[id]?.title ?? id)“ konnte nicht zu Apple Erinnerungen übertragen werden"
    case .createTask(let id):
      return "Erinnerung „\(ext[id]?.title ?? id)“ konnte nicht als Aufgabe übernommen werden"
    case .pushToExternal(let id):
      return "Aufgabe „\(tasks[id]?.title ?? id)“ konnte nicht nach Apple Erinnerungen übertragen werden"
    case .pullToTask(let id):
      return "Erinnerung „\(ext[id]?.title ?? id)“ konnte nicht in die Aufgabe übernommen werden"
    case .deleteTask(let id):
      return "Aufgabe „\(tasks[id]?.title ?? id)“ konnte nicht gelöscht werden"
    case .deleteExternal(let id):
      return "Erinnerung „\(ext[id]?.title ?? id)“ konnte nicht in Apple Erinnerungen gelöscht werden"
    case .unlink(let id):
      return "Verknüpfung der Aufgabe „\(tasks[id]?.title ?? id)“ konnte nicht gelöst werden"
    }
  }
}
