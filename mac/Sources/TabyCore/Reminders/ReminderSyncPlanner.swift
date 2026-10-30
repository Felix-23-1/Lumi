// Reine Planung des Abgleichs (ohne Seiteneffekte, ohne Uhr).
//
// Drei-Wege-Zusammenführung gegen den Snapshot der Verknüpfung:
// - verknüpftes Paar: Apple geändert → pullToTask (auch wenn beide geändert: Apple gewinnt),
//   nur Lumi geändert → pushToExternal, sonst nichts.
// - Verknüpfung, Erinnerung fehlt → deleteTask: die Aufgabe bleibt in Lumi offen, und auch die
//   Verknüpfung bleibt. Nur so wird die Erinnerung nie neu angelegt. Ist die Aufgabe schon erledigt → nur unlink.
// - Verknüpfung, Aufgabe fehlt → deleteExternal. Ist die Erinnerung schon erledigt → nur unlink.
// - beide fehlen → unlink.
// - ohne Verknüpfung: offene Aufgabe → createExternal, offene Erinnerung → createTask.
//   Ein Lösch-Ergebnis erzeugt nie neu, weil die fehlende Seite nicht mehr in den Listen steht.
import Foundation

public enum ReminderSyncPlanner {
  /// Massenlöschung erkannt: leere Liste bei vorhandenen Verknüpfungen, oder mehr als 3
  /// fehlende Erinnerungen und mehr als 30 % aller Verknüpfungen. Gezählt werden nur Löschungen in Apple
  /// (`deleteExternal`), nicht fehlende Erinnerungen (`deleteTask` löscht nichts). Dann wird nichts gelöscht.
  public static func isMassDeletion(missing: Int, linked: Int, externalCount: Int) -> Bool {
    if externalCount == 0 && linked > 0 { return true }
    return missing > 3 && Double(missing) > 0.3 * Double(linked)
  }

  /// Eine Liste, in der früher mehrere verknüpfte Erinnerungen standen, ist jetzt ganz verschwunden
  /// (alle ihre Verknüpfungen fehlen in Apple). Verknüpfungen ohne Listenangabe zählen nicht.
  /// Listen mit nur einer verknüpften Erinnerung zählen nicht: sonst pausiert der Abgleich jedes Mal,
  /// wenn man die einzige Erinnerung einer kleinen Liste löscht.
  public static func isListVanished(links: [ReminderLink], externalIds: Set<String>) -> Bool {
    var perList: [String: (linked: Int, missing: Int)] = [:]
    for link in links {
      guard let list = link.listId else { continue }
      var entry = perList[list] ?? (0, 0)
      entry.linked += 1
      if !externalIds.contains(link.externalId) { entry.missing += 1 }
      perList[list] = entry
    }
    return perList.values.contains { $0.linked >= 2 && $0.missing == $0.linked }
  }

  /// importListId: nur unverknüpfte offene Erinnerungen aus dieser Liste werden Aufgaben
  /// (nil = aus allen Listen). Verknüpfte Paare und Löschungen sind davon nicht betroffen:
  /// ein Listenwechsel löscht nie etwas.
  public static func plan(tasks: [TabyTask], external: [ExternalReminder], links: [ReminderLink],
                          importListId: String? = nil, excludedTaskIds: Set<String> = []) -> [SyncAction] {
    var taskById: [String: TabyTask] = [:]
    for t in tasks where taskById[t.id] == nil { taskById[t.id] = t }
    var extById: [String: ExternalReminder] = [:]
    for r in external where extById[r.id] == nil { extById[r.id] = r }

    var linkedTaskIds = Set<String>()
    var linkedExtIds = Set<String>()
    var actions: [SyncAction] = []

    for link in links {
      linkedTaskIds.insert(link.taskId)
      linkedExtIds.insert(link.externalId)
      guard let task = taskById[link.taskId] else {
        // Aufgabe in Lumi gelöscht: Erinnerung löschen, außer sie ist schon erledigt.
        if let ext = extById[link.externalId], !ext.done {
          actions.append(.deleteExternal(externalId: ext.id))
        } else {
          actions.append(.unlink(taskId: link.taskId))
        }
        continue
      }
      guard let ext = extById[link.externalId] else {
        // Erinnerung in Apple gelöscht: Aufgabe bleibt in Lumi (offen). Die Verknüpfung bleibt stehen,
        // damit sie nie wieder nach Apple geschrieben wird (sonst kehrt die Erinnerung zurück).
        if !task.done {
          actions.append(.deleteTask(taskId: task.id))
        } else {
          actions.append(.unlink(taskId: task.id))
        }
        continue
      }
      let taskChanged = task.title != link.snapTitle || task.due != link.snapDue || task.done != link.snapDone
      let extChanged = ext.title != link.snapTitle || ext.due != link.snapDue || ext.done != link.snapDone
      if extChanged {
        // Apple gewinnt, auch wenn Lumi ebenfalls geändert wurde.
        actions.append(.pullToTask(externalId: ext.id))
      } else if taskChanged {
        actions.append(.pushToExternal(taskId: task.id))
      }
    }

    // Ausgeschlossene Aufgaben (z. B. aus Notion) gehen nie nach Apple.
    for t in tasks where !t.done && !linkedTaskIds.contains(t.id) && !excludedTaskIds.contains(t.id) {
      actions.append(.createExternal(taskId: t.id))
    }
    for r in external where !r.done && !linkedExtIds.contains(r.id)
      && (importListId == nil || r.listId == importListId) {
      actions.append(.createTask(externalId: r.id))
    }
    return actions
  }
}
