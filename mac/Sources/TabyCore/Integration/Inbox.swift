// Eingang („Eingang-Runde“): Punkte aus Mail und Chats nach festen Regeln, ohne Modell.
// Mail: nur Kopfzeilen, kein Inhalt. Chats: nur die letzte Nachricht je Unterhaltung.
// Lumi sendet nie selbst; „Antworten“ öffnet nur einen Entwurf bzw. den Chat.
import Foundation

/// Reine Regeln: der Zeitpunkt kommt herein (Uhr injiziert), es wird nichts gelesen.
public enum InboxRules {
  /// Mail: letzte 3 Tage.
  public static let mailDays = 3
  /// Chats: „Antwort nötig“ ab 30 Minuten, „wartet“ ab 24 Stunden, nur innerhalb von 14 Tagen.
  public static let replyAfter: TimeInterval = 30 * 60
  public static let waitAfter: TimeInterval = 24 * 60 * 60
  public static let chatDays = 14
  /// Höchstens so viele Chats werden je Aufbau einzeln abgefragt.
  // shortcut: je Chat ein Abruf (nur bei geändertem Stand gecacht), upgrade auf Sammelabruf, wenn Dienste das anbieten
  public static let chatLimit = 12

  static func stamp(_ now: Date, back seconds: TimeInterval) -> String {
    LocalTime.format(now.addingTimeInterval(-seconds))
  }

  /// Anzeigename des Dienstes für die Zeile („Slack“, „Element“, „iMessage“).
  public static func channelName(_ service: MessengerService) -> String {
    switch service {
    case .matrix: "Element"
    case .slack: "Slack"
    case .teams: "Teams"
    case .imessage: "iMessage"
    }
  }

  /// Mails, die auf eine Antwort warten: letzte 3 Tage, kein Newsletter, ungelesen oder markiert,
  /// dazu Frage (Betreff mit „?“), wichtig oder markiert. Empfänger liegen nicht vor, daher wird
  /// „an mich“ nicht geprüft; „unbeantwortet“ ist ungelesen oder markiert (Antworten sieht Lumi nicht).
  public static func mailItems(_ messages: [MailMessage], now: Date) -> [InboxItem] {
    let since = stamp(now, back: TimeInterval(mailDays) * 86_400)
    return messages.filter { m in
      m.date >= since
        && m.category != .newsletter
        && (!m.read || m.flagged)
        && (m.subject.contains("?") || m.category == .important || m.flagged)
    }.map { m in
      InboxItem(id: m.id, kind: .needsReply, channel: "Mail",
                title: m.subject.isEmpty ? "(ohne Betreff)" : m.subject,
                from: m.senderName.isEmpty ? m.senderAddress : m.senderName, at: m.date)
    }
  }

  /// Direktchats, die die Oberfläche genauer prüfen muss: letzte Nachricht innerhalb von 14 Tagen
  /// und älter als 30 Minuten. Neueste zuerst, höchstens `chatLimit`.
  public static func chatCandidates(_ conversations: [MessengerConversation], now: Date) -> [MessengerConversation] {
    let since = stamp(now, back: TimeInterval(chatDays) * 86_400)
    let replyCut = stamp(now, back: replyAfter)
    return conversations
      .filter { c in c.isDirect && (c.lastAt.map { $0 >= since && $0 <= replyCut } ?? false) }
      .sorted { ($0.lastAt ?? "") > ($1.lastAt ?? "") }
      .prefix(chatLimit).map { $0 }
  }

  /// Chats: „Antwort nötig“, wenn ungelesen und die letzte Nachricht nicht von mir ist (älter als 30 Min.);
  /// „wartet“, wenn meine Nachricht zuletzt kam und älter als 24 Stunden ist. `last` = letzte Nachricht je Chat.
  public static func chatItems(_ conversations: [MessengerConversation], last: [String: MessengerMessage],
                               channels: [String: String], now: Date) -> [InboxItem] {
    let since = stamp(now, back: TimeInterval(chatDays) * 86_400)
    let replyCut = stamp(now, back: replyAfter)
    let waitCut = stamp(now, back: waitAfter)
    var out: [InboxItem] = []
    for c in conversations where c.isDirect {
      guard let m = last[c.id], m.at >= since else { continue }
      let channel = channels[c.accountId] ?? "Chat"
      let from = m.mine ? "Du" : m.sender
      if !m.mine, c.unread > 0, m.at <= replyCut {
        out.append(InboxItem(id: c.id, kind: .needsReply, channel: channel, title: c.title, from: from, at: m.at))
      } else if m.mine, m.at <= waitCut {
        out.append(InboxItem(id: c.id, kind: .waiting, channel: channel, title: c.title, from: from, at: m.at))
      }
    }
    return out
  }

  /// „Antwort nötig“ zuerst, dann „wartet“; je Gruppe die neueste zuerst.
  public static func ordered(_ items: [InboxItem]) -> [InboxItem] {
    items.sorted { a, b in
      if a.kind != b.kind { return a.kind == .needsReply }
      return a.at > b.at
    }
  }

  /// Erledigte Punkte bleiben weg, bis eine Nachricht kommt, die neuer ist als die erledigte.
  public static func visible(_ items: [InboxItem], dismissed: [String: String]) -> [InboxItem] {
    items.filter { item in dismissed[item.id].map { item.at > $0 } ?? true }
  }

  public static func needsReplyCount(_ items: [InboxItem]) -> Int {
    items.filter { $0.kind == .needsReply }.count
  }
}

extension CoreServices {
  /// Eingang für den Zustand. Erledigte Punkte sind hier schon herausgefiltert.
  func inboxItems() async -> [InboxItem] {
    let now = clock.now()
    let mail = settings.mailEnabled ? InboxRules.mailItems(mailCache?.messages ?? [], now: now) : []
    let candidates = InboxRules.chatCandidates(messenger.conversationList(), now: now)
    var last: [String: MessengerMessage] = [:]
    for c in candidates {
      let stamp = c.lastAt ?? ""
      if let cached = inboxLastMessages[c.id], cached.lastAt == stamp {
        last[c.id] = cached.message
      } else if let v = await messenger.messages(c.id, limit: 5).value, let newest = v.max(by: { $0.at < $1.at }) {
        last[c.id] = newest
        inboxLastMessages[c.id] = (stamp, newest)
      }
    }
    let channels = Dictionary(messenger.accountList().map { ($0.id, InboxRules.channelName($0.service)) },
                              uniquingKeysWith: { a, _ in a })
    let chats = InboxRules.chatItems(candidates, last: last, channels: channels, now: now)
    lastInboxItems = InboxRules.ordered(mail + chats)
    let dismissed = (try? store.inboxDismissed.all()) ?? [:]
    return InboxRules.visible(lastInboxItems, dismissed: dismissed)
  }

  /// Erledigt: gemerkt mit der Zeit der Nachricht; kommt erst mit einer neueren Nachricht zurück.
  public func markInboxDone(_ id: String) async {
    let at = lastInboxItems.first { $0.id == id }?.at ?? LocalTime.format(clock.now())
    try? store.inboxDismissed.set(id, at: at)
    emit(.stateChanged)
  }

  /// Antwort-Entwurf: Mail öffnet ein sichtbares Antwortfenster in Apple Mail; Chats öffnet die Oberfläche
  /// mit leerem Feld. Gesendet wird nie etwas.
  public func draftReply(_ id: String) async -> ToolResult<Empty> {
    guard let item = lastInboxItems.first(where: { $0.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Dieser Punkt ist nicht mehr im Eingang.")
    }
    guard item.channel == "Mail" else { return .ok(Empty()) }
    guard settings.mailEnabled else { return .failure(code: "MAIL_OFF", error: "Mail ist ausgeschaltet.") }
    do {
      try await mailBackend.openReplyDraft(id: id)
      return .ok(Empty())
    } catch {
      return .failure(code: "MAIL", error: (error as? MailError)?.errorDescription ?? "Apple Mail hat nicht geantwortet.")
    }
  }
}
