// Text der Erinnerungs-Benachrichtigung (wird auch vorgelesen). Rein, prüfbar.
import Foundation

public enum ReminderText {
  /// Aufgaben: schlicht „Erinnerung“. Termine: „Termin bald“ mit Uhrzeit und
  /// „in X Min“, damit die Sprachausgabe klar sagt, dass der Termin ansteht.
  public static func notification(for r: Reminder, title: String, eventStart: String?, now: Date) -> TabyNotification {
    guard r.source == .event, let startISO = eventStart, let start = LocalTime.parse(startISO) else {
      // Aufgaben-Erinnerung trägt die Aufgabe (Notch: „Erledigt“ / „In 10 Min“).
      return TabyNotification(title: "Erinnerung", body: title, taskId: r.source == .task ? r.sourceRef : nil)
    }
    let time = LocalTime.formatTime(start)
    let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
    let soon: String
    if minutes <= 0 { soon = "jetzt" }
    else if minutes == 1 { soon = "in 1 Minute" }
    else { soon = "in \(minutes) Minuten" }
    return TabyNotification(title: "Termin bald", body: "\(title) um \(time) – \(soon)")
  }

  /// „In 10 Min“ aus einer Aufgaben-Benachrichtigung: neue Fälligkeit (lokal, "YYYY-MM-DDTHH:mm").
  public static let snoozeMinutes = 10
  public static func snoozeDue(now: Date) -> String {
    LocalTime.format(now.addingTimeInterval(TimeInterval(snoozeMinutes * 60)))
  }
}
