// Mail direkt per IMAP (TLS, Port 993). Ein Verbindungsaufbau je Vorgang, danach wieder zu.
// Kopfzeilen nur für die letzten 7 Tage, höchstens 40 Mails; Körper erst beim Öffnen.
// Senden gibt es nicht: Entwürfe öffnen sich in Apple Mail, der Nutzer sendet selbst.
import Foundation

public final class IMAPBackend: MailBackend, @unchecked Sendable {
  /// Schlüsselbund-Konto für das IMAP-Passwort (Dienst: `KeychainApiKeyStore.defaultService`).
  public static let passwordAccount = "mail-imap-password"
  static let maxHeaders = 40
  static let maxHeaderDays = 7
  static let timeoutSeconds: Double = 30

  private let host: String
  private let user: String
  private let password: @Sendable () throws -> String
  private let clock: Clock
  private let drafts: MailBackend

  public init(host: String, user: String, password: @escaping @Sendable () throws -> String,
              clock: Clock = SystemClock(), drafts: MailBackend = AppleMailBackend()) {
    self.host = host.trimmingCharacters(in: .whitespaces)
    self.user = user.trimmingCharacters(in: .whitespaces)
    self.password = password
    self.clock = clock
    self.drafts = drafts
  }

  // MARK: MailBackend

  public func inbox(days: Int, limit: Int) async throws -> [MailMessage] {
    let window = min(max(days, 1), Self.maxHeaderDays)
    let cap = min(max(limit, 1), Self.maxHeaders)
    let since = clock.now().addingTimeInterval(-Double(window) * 86_400)
    let account = user
    return try await withSession { session in
      _ = try await session.selectInbox()
      let validity = await session.uidValidity ?? ""
      let uids = try await session.searchSince(since)
      let rows = try await session.fetchHeaders(uids: Array(uids.suffix(cap)))
      return rows
        .compactMap { Self.message(from: $0, validity: validity, account: account) }
        .sorted { $0.date > $1.date }
    }
  }

  public func body(id: String) async throws -> String {
    let text: String = try await withMessage(id) { session, uid in
      guard let raw = try await session.fetchRaw(uid: uid) else { throw MailError.notFound }
      return String(MailText.plainText(message: raw).prefix(AppleMailBackend.maxBodyCharacters))
    }
    return text
  }

  public func setRead(id: String, _ read: Bool) async throws {
    try await withMessage(id) { session, uid in
      try await session.setFlag(uid: uid, "\\Seen", on: read)
    }
  }

  public func setFlagged(id: String, _ flagged: Bool) async throws {
    try await withMessage(id) { session, uid in
      try await session.setFlag(uid: uid, "\\Flagged", on: flagged)
    }
  }

  /// Verschiebt per UID MOVE in den Archiv-Ordner. Fehlt er, wird nur als gelesen markiert und gemeldet.
  public func archive(id: String) async throws {
    try await withMessage(id) { session, uid in
      let folders = try await session.listFolders()
      guard let target = Self.folder(in: folders, leaves: ["archive", "archiv"], special: "\\ARCHIVE") else {
        try? await session.setFlag(uid: uid, "\\Seen", on: true)
        throw MailError.scriptFailed("Kein Archiv-Ordner gefunden")
      }
      try await session.move(uid: uid, to: target.name)
    }
  }

  /// Verschiebt in den Papierkorb, nie endgültig löschen.
  public func trash(id: String) async throws {
    try await withMessage(id) { session, uid in
      let folders = try await session.listFolders()
      guard let target = Self.folder(in: folders, leaves: ["trash", "papierkorb"], special: "\\TRASH") else {
        throw MailError.scriptFailed("Kein Papierkorb-Ordner gefunden")
      }
      try await session.move(uid: uid, to: target.name)
    }
  }

  /// Antwort-Entwurf: Empfänger und Betreff aus dem Umschlag, im Entwurf in Apple Mail. Sendet nie.
  public func openReplyDraft(id: String) async throws {
    let draft: MailDraft = try await withMessage(id) { session, uid in
      guard let envelope = try await session.fetchEnvelope(uid: uid) else { throw MailError.notFound }
      let parsed = Self.envelope(envelope)
      let subject = parsed.subject.lowercased().hasPrefix("re:") ? parsed.subject : "Re: " + parsed.subject
      return MailDraft(to: [parsed.address], subject: subject, body: "")
    }
    try await drafts.openNewDraft(draft)
  }

  public func openNewDraft(_ draft: MailDraft) async throws {
    try await drafts.openNewDraft(draft)
  }

  /// Kein SMTP. Der Entwurf öffnet sich zum Prüfen und Senden in Apple Mail.
  public func send(_ draft: MailDraft) async throws {
    try await drafts.openNewDraft(draft)
  }

  // MARK: Verbindung

  /// Öffnet eine Verbindung, meldet an, führt `work` aus und meldet ab. Immer wieder geschlossen.
  private func withSession<T: Sendable>(_ work: @escaping @Sendable (IMAPSession) async throws -> T) async throws -> T {
    let pw = try password()
    let host = self.host
    let user = self.user
    let session = IMAPSession(host: host)
    defer { session.close() }
    return try await IMAPTimeout.run(seconds: Self.timeoutSeconds, onTimeout: { session.close() }) {
      try await session.open()
      try await session.login(user: user, password: pw)
      let result = try await work(session)
      _ = try? await session.command("LOGOUT")
      return result
    }
  }

  /// Wie `withSession`, aber für eine Mail-ID aus `inbox`. Prüft, dass der Posteingang sich nicht geändert hat.
  private func withMessage<T: Sendable>(_ id: String, _ work: @escaping @Sendable (IMAPSession, Int) async throws -> T) async throws -> T {
    guard let parsed = Self.parseID(id) else { throw MailError.notFound }
    return try await withSession { session in
      _ = try await session.selectInbox()
      let current = await session.uidValidity ?? ""
      guard current == parsed.validity else {
        throw MailError.scriptFailed("Der Posteingang hat sich geändert. Bitte die Liste neu laden.")
      }
      return try await work(session, parsed.uid)
    }
  }

  /// Passwort aus dem Schlüsselbund. Fehlt es, wird das in der Oberfläche gemeldet.
  public static func keychainPassword() throws -> String {
    guard let pw = try KeychainApiKeyStore(account: passwordAccount).get(), !pw.isEmpty else {
      throw MailError.scriptFailed("Kein IMAP-Passwort gespeichert. Bitte in den Einstellungen eintragen.")
    }
    return pw
  }

  public static func savePassword(_ password: String) throws {
    try KeychainApiKeyStore(account: passwordAccount).set(password)
  }

  public static func hasPassword() -> Bool {
    KeychainApiKeyStore(account: passwordAccount).hasKey()
  }

  /// "Verbindung testen": anmelden, Posteingang wählen, abmelden. Liefert eine Meldung ohne Geheimnisse.
  public static func testConnection(host: String, user: String, password: String) async throws -> String {
    let host = host.trimmingCharacters(in: .whitespaces)
    let user = user.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty, !user.isEmpty, !password.isEmpty else {
      throw MailError.scriptFailed("Server, Benutzer und Passwort eintragen.")
    }
    let session = IMAPSession(host: host)
    defer { session.close() }
    return try await IMAPTimeout.run(seconds: timeoutSeconds, onTimeout: { session.close() }) {
      try await session.open()
      try await session.login(user: user, password: password)
      let count = try await session.selectInbox()
      _ = try? await session.command("LOGOUT")
      return "Verbindung hergestellt. Im Posteingang liegen \(count) Mails."
    }
  }

  // MARK: Umwandlung

  /// Mail-Kennung: `imap:<UIDVALIDITY>:<UID>`. Ändert sich der Ordner, passt die Kennung nicht mehr.
  static func makeID(validity: String, uid: Int) -> String { "imap:\(validity):\(uid)" }

  static func parseID(_ id: String) -> (validity: String, uid: Int)? {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "imap", let uid = Int(parts[2]) else { return nil }
    return (String(parts[1]), uid)
  }

  /// Eine Kopfzeile aus FETCH-Schlüssel-Werten. nil, wenn die UID fehlt.
  static func message(from pairs: [String: IMAPValue], validity: String, account: String) -> MailMessage? {
    guard let uid = pairs["UID"]?.string.flatMap(Int.init) else { return nil }
    let flags = (pairs["FLAGS"]?.list ?? []).compactMap { $0.string?.uppercased() }
    let envelope = Self.envelope(pairs["ENVELOPE"] ?? .nilValue)
    return MailMessage(
      id: makeID(validity: validity, uid: uid),
      senderName: envelope.name.isEmpty ? envelope.address : envelope.name,
      senderAddress: envelope.address,
      subject: envelope.subject,
      date: internalDate(pairs["INTERNALDATE"]?.string),
      read: flags.contains("\\SEEN"),
      flagged: flags.contains("\\FLAGGED"),
      account: account,
      mailbox: "INBOX",
      category: .normal)
  }

  /// Betreff, Name und Adresse des Absenders aus ENVELOPE:
  /// (date subject from sender reply-to to cc bcc in-reply-to message-id).
  static func envelope(_ value: IMAPValue) -> (subject: String, name: String, address: String) {
    let fields = value.list ?? []
    let subject = MailText.decodeWords(fields.count > 1 ? (fields[1].optionalString ?? "") : "")
    let sender = fields.count > 2 ? (fields[2].list?.first?.list ?? []) : []
    let name = MailText.decodeWords(sender.count > 0 ? (sender[0].optionalString ?? "") : "")
    let mailbox = sender.count > 2 ? (sender[2].optionalString ?? "") : ""
    let host = sender.count > 3 ? (sender[3].optionalString ?? "") : ""
    return (subject, name, host.isEmpty ? mailbox : "\(mailbox)@\(host)")
  }

  /// INTERNALDATE "17-Jul-1996 02:44:25 -0700" → lokal "YYYY-MM-DDTHH:mm".
  static func internalDate(_ raw: String?) -> String {
    guard let raw else { return "" }
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
    guard let date = f.date(from: raw.replacingOccurrences(of: "  ", with: " ")) else { return "" }
    return LocalTime.format(date)
  }

  /// Ordner mit Sonderrolle (RFC 6154) oder passendem Namen. Die Rolle hat Vorrang.
  static func folder(in folders: [IMAPFolder], leaves: [String], special: String) -> IMAPFolder? {
    if let byRole = folders.first(where: { $0.attributes.contains { $0.uppercased() == special } }) { return byRole }
    return folders.first { leaves.contains($0.leaf.lowercased()) }
  }
}

/// Wählt bei jedem Aufruf den Mail-Zugang aus den aktuellen Einstellungen: "imap" → IMAP, sonst Apple Mail.
/// So greifen Änderungen in den Einstellungen ohne Neustart.
public final class SwitchingMailBackend: MailBackend, @unchecked Sendable {
  private let settings: @Sendable () -> TabySettings
  private let clock: Clock
  private let apple = AppleMailBackend()

  public init(settings: @escaping @Sendable () -> TabySettings, clock: Clock = SystemClock()) {
    self.settings = settings
    self.clock = clock
  }

  /// Der Zugang für die jetzigen Einstellungen.
  public func current() -> MailBackend {
    let s = settings()
    guard s.mailBackend == "imap" else { return apple }
    return IMAPBackend(host: s.imapHost, user: s.imapUser, password: { try IMAPBackend.keychainPassword() }, clock: clock)
  }

  public func inbox(days: Int, limit: Int) async throws -> [MailMessage] { try await current().inbox(days: days, limit: limit) }
  public func body(id: String) async throws -> String { try await current().body(id: id) }
  public func setRead(id: String, _ read: Bool) async throws { try await current().setRead(id: id, read) }
  public func openReplyDraft(id: String) async throws { try await current().openReplyDraft(id: id) }
  public func setFlagged(id: String, _ flagged: Bool) async throws { try await current().setFlagged(id: id, flagged) }
  public func archive(id: String) async throws { try await current().archive(id: id) }
  public func trash(id: String) async throws { try await current().trash(id: id) }
  public func openNewDraft(_ draft: MailDraft) async throws { try await current().openNewDraft(draft) }
  public func send(_ draft: MailDraft) async throws { try await current().send(draft) }
}
