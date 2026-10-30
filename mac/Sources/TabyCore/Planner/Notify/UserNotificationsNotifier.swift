// macOS-Benachrichtigungen über UserNotifications (ersetzt Electron `Notification`).
// `UNUserNotificationCenter.current()` stürzt ohne App-Bundle ab (z. B. `swift run`,
// TabyChecks). Dann wird nur protokolliert — nie abgestürzt.
import Foundation
import UserNotifications

/// Aktionen unter einer Aufgaben-Benachrichtigung (gleiche Knöpfe wie in der Notch).
public enum TaskNotificationAction: String, Sendable {
  case done = "TABY_TASK_DONE"
  case snooze = "TABY_TASK_SNOOZE"
  /// „Ich arbeite daran“: startet den Fokus mit dieser Aufgabe.
  case working = "TABY_TASK_WORKING"
  /// Fokuszeit um: „Brauche noch 15 / 30 Min“.
  case more15 = "TABY_TASK_MORE15"
  case more30 = "TABY_TASK_MORE30"
}

/// Nimmt die Knopf-Antworten entgegen und reicht sie als (Aktion, Aufgaben-Id) weiter.
private final class TaskResponseHandler: NSObject, UNUserNotificationCenterDelegate {
  var onAction: ((TaskNotificationAction, String) -> Void)?

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    if let action = TaskNotificationAction(rawValue: response.actionIdentifier),
       let taskId = info["taskId"] as? String {
      onAction?(action, taskId)
    }
    completionHandler()
  }
}

public final class UserNotificationsNotifier: Notifier {
  static let taskCategory = "TABY_TASK"
  static let overrunCategory = "TABY_TASK_OVERRUN"

  private let log: (String) -> Void
  private let center: UNUserNotificationCenter?
  private let lock = NSLock()
  private var authorizationRequested = false
  private let responses = TaskResponseHandler()

  /// Knopfdruck auf „Ich arbeite daran“ / „Erledigt“ / „In 10 Min“ in einer Aufgaben-Benachrichtigung.
  public var onTaskAction: ((TaskNotificationAction, String) -> Void)? {
    get { responses.onAction }
    set { responses.onAction = newValue }
  }

  /// true, wenn der Prozess als App-Bundle läuft und das System-Center nutzbar ist.
  public static var systemAvailable: Bool {
    Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
  }

  /// - requestAuthorizationNow: Freigabe sofort anfragen. Standard aus: nie beim Start fragen,
  ///   sondern in der Einrichtung oder beim ersten Senden einer Mitteilung.
  public init(requestAuthorizationNow: Bool = false,
              log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
    self.log = log
    center = Self.systemAvailable ? UNUserNotificationCenter.current() : nil
    if let center {
      center.delegate = responses
      center.setNotificationCategories([UNNotificationCategory(
        identifier: Self.overrunCategory,
        actions: [UNNotificationAction(identifier: TaskNotificationAction.done.rawValue, title: "Fertig", options: []),
                  UNNotificationAction(identifier: TaskNotificationAction.more15.rawValue, title: "Noch 15 Min", options: []),
                  UNNotificationAction(identifier: TaskNotificationAction.more30.rawValue, title: "Noch 30 Min", options: [])],
        intentIdentifiers: []), UNNotificationCategory(
        identifier: Self.taskCategory,
        actions: [UNNotificationAction(identifier: TaskNotificationAction.working.rawValue, title: "Ich arbeite daran", options: []),
                  UNNotificationAction(identifier: TaskNotificationAction.done.rawValue, title: "Erledigt", options: []),
                  UNNotificationAction(identifier: TaskNotificationAction.snooze.rawValue, title: "In 10 Min", options: [])],
        intentIdentifiers: [])])
    }
    if requestAuthorizationNow { requestAuthorization() }
  }

  /// true = echte Systembenachrichtigungen, false = nur Protokoll.
  public var usesSystem: Bool { center != nil }

  /// Fragt die Benachrichtigungs-Freigabe genau einmal an.
  public func requestAuthorization() {
    guard let center else { return }
    lock.lock()
    let already = authorizationRequested
    authorizationRequested = true
    lock.unlock()
    if already { return }
    let log = log
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error { log("[notify] Freigabe fehlgeschlagen: \(error.localizedDescription)") }
      else if !granted { log("[notify] Benachrichtigungen nicht freigegeben") }
    }
  }

  public func send(_ n: TabyNotification) {
    guard let center else {
      log("[notify] \(n.title): \(n.body)")
      return
    }
    requestAuthorization()
    let content = UNMutableNotificationContent()
    content.title = n.title
    content.body = n.body
    content.sound = .default
    if let taskId = n.taskId {
      content.categoryIdentifier = n.overrun ? Self.overrunCategory : Self.taskCategory
      content.userInfo = ["taskId": taskId]
    }
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    let log = log
    center.add(request) { error in
      if let error { log("[notify] Senden fehlgeschlagen: \(error.localizedDescription)") }
    }
  }
}
