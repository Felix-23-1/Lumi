// Erinnerung an ungelesene Mails: Lumi meldet sich alle 2 Stunden, solange Mails offen sind.
// Die Notch bietet dazu „Mails ansehen“, „Mit Lumi durchgehen“ und „Später“ an.
import Foundation

extension CoreServices {
  /// Abstand zwischen zwei Mail-Erinnerungen.
  static let mailReminderInterval: TimeInterval = 2 * 3600

  /// Prompt für „Mit Lumi durchgehen“ (Chat).
  public static let mailReviewPrompt =
    "Ich habe ungelesene Mails. Geh sie mit mir durch: nenne die wichtigsten zuerst, sag kurz worum es geht "
    + "und frag mich bei jeder, ob ich antworten, eine Aufgabe daraus machen oder sie archivieren will."

  /// Wird im 30-s-Takt aufgerufen. Die erste Sichtung ungelesener Mails startet nur die Uhr
  /// (das Briefing nennt sie ohnehin); danach kommt alle 2 Stunden eine Erinnerung, solange Mails offen sind.
  func mailReminderTick() {
    guard settings.mailEnabled, let overview = mailCache, overview.error == nil, overview.unread > 0 else {
      mailReminderLastAt = nil  // nichts offen: beim nächsten Mal wieder bei null anfangen
      return
    }
    let now = clock.now()
    guard let last = mailReminderLastAt else { mailReminderLastAt = now; return }
    guard now.timeIntervalSince(last) >= Self.mailReminderInterval else { return }
    mailReminderLastAt = now
    let count = overview.unread == 1 ? "1 ungelesene Mail" : "\(overview.unread) ungelesene Mails"
    let line = MailTriage.briefingLine(overview) ?? count
    emit(.flash(TabyNotification(title: "Du hast \(count) offen", body: "\(line). Sollen wir sie durchgehen?",
                                 mailReminder: true)))
  }
}
