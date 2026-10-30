// Microsoft Teams über Microsoft Graph: die Chats der angemeldeten Person.
// Anmeldung ist die Microsoft-Anmeldung (MicrosoftAuth); der Connector speichert nichts dauerhaft.
// Lesen: GET /me/chats (mit letzter Nachricht und Mitgliedern) und /me/chats/{id}/messages.
// Senden: POST /me/chats/{id}/messages. Ungelesen = neuere Nachricht eines anderen als der
// Lesestand (nur im Speicher; beim ersten Abruf gilt alles als gelesen).
// Status: Teams „Nicht stören“ während Fokus und Termin; der Ablauf folgt dem geplanten Ende
// (PT5M bis PT8H, Verlängerung im Takt). Ohne „Teams-Chats und Status“ geht nichts (Rechte-Prüfung).
// Nachrichtentext ist fremder Inhalt; die Werkzeuge verpacken ihn wie bei Slack (ForeignContent).
import Foundation

public actor TeamsConnector: MessengerConnector, StatusSetting {
  public let service: MessengerService = .teams

  static let chatLimit = 30
  static let messageLimit = 50
  /// Ablauf, wenn kein Ende bekannt ist.
  static let presenceLifetime = "PT1H"
  /// Anzeige, die Teams für einen gesetzten „Nicht stören“-Status liefert (ohne Lumi-Eintrag).
  static let userDndText = "Teams: Nicht stören"

  private struct Chat {
    let id: String
    let title: String
    let isDirect: Bool
    let previewAt: Date?
    let previewText: String?
    let previewIsMessage: Bool
    let previewFromOwn: Bool
  }

  private let auth: MicrosoftAuth
  private let clock: Clock
  private var accountId = ""
  private var ownId = ""
  private var chats: [String: Chat] = [:]
  /// Chat-ID → Zeitpunkt der zuletzt gelesenen Nachricht (nur im Speicher).
  private var lastRead: [String: Date] = [:]
  /// Status, den Lumi zuletzt gesetzt hat (Text, Emoji); nil = keiner.
  private var lumiStatus: (text: String, emoji: String)?
  /// Bis wann der gesetzte Status läuft (nur im Speicher; für die Verlängerung im Takt).
  private var writtenUntil: Date?

  public init(auth: MicrosoftAuth, clock: Clock = SystemClock()) {
    self.auth = auth
    self.clock = clock
  }

  // MARK: - Anmeldung

  public func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
    guard auth.isSignedIn() else {
      throw MessengerFailure(message: "Erst bei Microsoft anmelden: Verbindungen → Microsoft.")
    }
    return try await mapped {
      self.accountId = accountId
      let me = try await self.loadMe()
      return (MessengerAccount(id: accountId, service: .teams, user: me.label), "")
    }
  }

  public func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount {
    guard auth.isSignedIn() else {
      throw MessengerFailure(message: "Microsoft-Anmeldung fehlt. Bitte unter Verbindungen → Microsoft neu anmelden.")
    }
    accountId = account.id
    return account
  }

  /// Teams braucht keinen Schlüssel zum Entsperren.
  public func unlock(recoveryKey: String) async throws {}

  public func logout() async {
    accountId = ""
    ownId = ""
    chats = [:]
    lastRead = [:]
    lumiStatus = nil
    writtenUntil = nil
  }

  // MARK: - Lesen und Senden

  public func conversations() async throws -> [MessengerConversation] {
    try await mapped {
      try await self.ensureMe()
      let url = MicrosoftAuth.graphURL("me/chats", query: [
        URLQueryItem(name: "$top", value: "\(Self.chatLimit)"),
        URLQueryItem(name: "$expand", value: "lastMessagePreview,members"),
      ])
      let (data, _) = try await self.auth.graph("GET", url)
      let raw = (MicrosoftHTTP.json(data)?["value"] as? [[String: Any]]) ?? []
      var fresh: [String: Chat] = [:]
      for item in raw {
        if let chat = self.chat(item) { fresh[chat.id] = chat }
      }
      // Erster Blick: alles Bisherige gilt als gelesen (wie bei Slack).
      for chat in fresh.values where self.lastRead[chat.id] == nil {
        self.lastRead[chat.id] = chat.previewAt ?? self.clock.now()
      }
      self.chats = fresh
      return self.output()
    }
  }

  public func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] {
    try await mapped {
      try await self.ensureMe()
      let url = MicrosoftAuth.graphURL("me/chats/" + MicrosoftAuth.segment(roomId) + "/messages", query: [
        URLQueryItem(name: "$top", value: "\(min(max(limit, 1), Self.messageLimit))"),
      ])
      let (data, _) = try await self.auth.graph("GET", url)
      let raw = (MicrosoftHTTP.json(data)?["value"] as? [[String: Any]]) ?? []
      var out: [MessengerMessage] = []
      // Graph liefert die neueste zuerst; die Anzeige will die älteste zuerst.
      for m in raw.reversed() {
        guard let mid = m["id"] as? String, let created = (m["createdDateTime"] as? String).flatMap(Self.instant) else {
          continue
        }
        // Systemmeldungen (Teilnehmer ein- und ausgetreten, Umbenennung) und gelöschte Nachrichten fallen weg.
        guard (m["messageType"] as? String ?? "message") == "message", (m["deletedDateTime"] as? String) == nil else {
          continue
        }
        let from = Self.user(m["from"])
        let fromId = from?["id"] as? String
        let mine = fromId != nil && fromId == self.ownId
        let name = Self.nonEmpty(from?["displayName"] as? String) ?? "Unbekannt"
        out.append(MessengerMessage(id: mid, conversationId: "\(self.accountId)|\(roomId)", sender: mine ? "Ich" : name,
                                    text: Self.messageText(m), at: LocalTime.format(created), mine: mine))
      }
      return out
    }
  }

  public func send(roomId: String, text: String) async throws {
    try await mapped {
      let body = try JSONSerialization.data(withJSONObject: ["body": ["contentType": "text", "content": text]])
      _ = try await self.auth.graph("POST", MicrosoftAuth.graphURL("me/chats/" + MicrosoftAuth.segment(roomId) + "/messages"),
                                    body: body)
    }
  }

  /// Lesestand lokal: die neueste bekannte Nachricht gilt als gelesen. Kein Graph-Aufruf.
  public func markRead(roomId: String) async throws {
    lastRead[roomId] = chats[roomId]?.previewAt ?? clock.now()
  }

  // MARK: - Status (Teams „Nicht stören“)

  /// Eigener Teams-Status. Hat Lumi „Nicht stören“ gesetzt, kommt dessen Text zurück; sonst der Teams-Anzeigetext.
  public func readStatus() async throws -> (text: String, emoji: String) {
    try await mapped(MicrosoftAuth.presenceScope) {
      let (data, _) = try await self.auth.graph("GET", MicrosoftAuth.graphURL("me/presence"))
      guard (MicrosoftHTTP.json(data)?["activity"] as? String) == "DoNotDisturb" else { return ("", "") }
      if let mine = self.lumiStatus { return mine }
      return (Self.userDndText, "")
    }
  }

  /// Setzt „Nicht stören“ bis zum Ende (`until`) oder löscht den Lumi-Status (leerer Text).
  public func writeStatus(text: String, emoji: String, until: Date?) async throws {
    try await mapped(MicrosoftAuth.presenceScope) {
      if text.isEmpty {
        _ = try await self.auth.graph("POST", MicrosoftAuth.graphURL("me/presence/clearUserPreferredPresence"))
        self.lumiStatus = nil
        self.writtenUntil = nil
      } else {
        let window = Self.presenceWindow(until: until, now: self.clock.now())
        let body = try JSONSerialization.data(withJSONObject: [
          "availability": "DoNotDisturb", "activity": "DoNotDisturb", "expirationDuration": window.duration,
        ])
        _ = try await self.auth.graph("POST", MicrosoftAuth.graphURL("me/presence/setUserPreferredPresence"), body: body)
        self.lumiStatus = (text, emoji)
        self.writtenUntil = window.end
      }
    }
  }

  /// Verlängert den Lumi-Status im Takt, wenn das Ende über die Obergrenze (PT8H) hinausliegt und die Frist näher rückt.
  public func refreshStatus(until: Date?) async throws {
    guard let mine = lumiStatus, let until, let written = writtenUntil else { return }
    guard until > written, clock.now() >= written.addingTimeInterval(-600) else { return }
    try await writeStatus(text: mine.text, emoji: mine.emoji, until: until)
  }

  /// Teams-Status gehört Lumi, wenn Teams „Nicht stören“ meldet und der Status-Eintrag von Lumi steht.
  /// Der Text kommt nach einem Neustart nicht mehr zurück; deshalb zählt der Eintrag, nicht der Text.
  /// shortcut: ein manuelles „Nicht stören“ während eines Lumi-Eintrags wird mit geräumt (Graph kennt keinen Urheber), Upgrade bei Bedarf.
  public nonisolated func ownsStatus(_ current: (text: String, emoji: String), record: AutoStatusRecord) -> Bool {
    current.text == Self.userDndText || (current.text == record.text && current.emoji == record.emoji)
  }

  /// Dauer für Graph (ISO 8601, mindestens PT5M, höchstens PT8H) und Ende des Status.
  static func presenceWindow(until: Date?, now: Date) -> (duration: String, end: Date) {
    guard let until else { return (presenceLifetime, now.addingTimeInterval(3_600)) }
    let minutes = min(max(Int((until.timeIntervalSince(now) / 60).rounded(.up)), 5), 480)
    let hours = minutes / 60, rest = minutes % 60
    let duration = "PT" + (hours > 0 ? "\(hours)H" : "") + (rest > 0 ? "\(rest)M" : "")
    return (duration, now.addingTimeInterval(TimeInterval(minutes * 60)))
  }

  // MARK: - Chats und Konto

  private func loadMe() async throws -> (id: String, label: String) {
    let (data, _) = try await auth.graph("GET", MicrosoftAuth.graphURL("me", query: [
      URLQueryItem(name: "$select", value: "id,displayName,mail,userPrincipalName"),
    ]))
    let json = MicrosoftHTTP.json(data)
    let id = (json?["id"] as? String) ?? ""
    guard !id.isEmpty else { throw MessengerFailure(message: "Microsoft hat das Konto nicht genannt.") }
    ownId = id
    let label = Self.nonEmpty(json?["mail"] as? String) ?? Self.nonEmpty(json?["userPrincipalName"] as? String)
      ?? Self.nonEmpty(json?["displayName"] as? String) ?? "Microsoft Teams"
    return (id, label)
  }

  private func ensureMe() async throws {
    if ownId.isEmpty { _ = try await loadMe() }
  }

  private func chat(_ c: [String: Any]) -> Chat? {
    guard let cid = c["id"] as? String else { return nil }
    let topic = Self.nonEmpty(c["topic"] as? String)
    let others = ((c["members"] as? [[String: Any]]) ?? [])
      .filter { ($0["userId"] as? String) != ownId }
      .compactMap { Self.nonEmpty($0["displayName"] as? String) }
    let title = topic ?? (others.isEmpty ? "Chat" : others.joined(separator: ", "))
    let preview = c["lastMessagePreview"] as? [String: Any]
    let at = (preview?["createdDateTime"] as? String).flatMap(Self.instant)
    let isMessage = ((preview?["messageType"] as? String) ?? "message") == "message"
    let fromId = Self.user(preview?["from"])?["id"] as? String
    return Chat(id: cid, title: title, isDirect: (c["chatType"] as? String) == "oneOnOne", previewAt: at,
                previewText: preview.flatMap { isMessage ? Self.messageText($0) : nil }, previewIsMessage: isMessage,
                previewFromOwn: fromId == ownId)
  }

  /// Neue Nachricht eines anderen seit dem Lesestand = 1 ungelesen (Graph gibt keinen Zähler).
  private func unread(_ chat: Chat) -> Int {
    guard let at = chat.previewAt, chat.previewIsMessage, !chat.previewFromOwn, let seen = lastRead[chat.id] else { return 0 }
    return at > seen ? 1 : 0
  }

  private func output() -> [MessengerConversation] {
    chats.values.map { c in
      MessengerConversation(id: "\(accountId)|\(c.id)", accountId: accountId, title: c.title, unread: unread(c),
                            lastText: c.previewText, lastAt: c.previewAt.map { LocalTime.format($0) }, isDirect: c.isDirect)
    }
    .sorted { ($0.lastAt ?? "") > ($1.lastAt ?? "") }
  }

  /// Fehler der Microsoft-Schicht werden zu den Fehlern des Nachrichtenhubs (mit demselben deutschen Text).
  /// Prüft vorher das Recht (Chats: Chat.ReadWrite, Status: Presence.ReadWrite), sonst der Hinweis zur Anmeldung.
  private func mapped<T>(_ scope: String = MicrosoftAuth.chatScope, _ body: () async throws -> T) async throws -> T {
    do {
      try await auth.requireScope(scope)
      return try await body()
    } catch let f as MicrosoftFailure {
      throw MessengerFailure(message: f.message)
    }
  }

  // MARK: - Hilfen

  static func user(_ from: Any?) -> [String: Any]? {
    ((from as? [String: Any])?["user"]) as? [String: Any]
  }

  /// Nachrichtentext als Klartext. HTML wird entfernt; leer = "(Anhang)".
  static func messageText(_ m: [String: Any]) -> String {
    let body = m["body"] as? [String: Any]
    let text = plainText((body?["content"] as? String) ?? "", contentType: (body?["contentType"] as? String) ?? "text")
    return text.isEmpty ? "(Anhang)" : text
  }

  static func plainText(_ raw: String, contentType: String) -> String {
    var s = raw
    if contentType.lowercased() == "html" {
      s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
      s = s.replacingOccurrences(of: #"(?i)</(p|div|li)>"#, with: "\n", options: .regularExpression)
      s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
      // &amp; zuletzt, sonst würde „&amp;lt;“ doppelt entschlüsselt.
      for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                             ("&#x27;", "'"), ("&amp;", "&")] {
        s = s.replacingOccurrences(of: entity, with: char)
      }
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func instant(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)
  }

  static func nonEmpty(_ s: String?) -> String? {
    let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty ?? true) ? nil : t
  }
}
