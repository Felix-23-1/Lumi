// Im Speicher-Ersatz für Apple Mail: für Prüfungen und Integrationstests.
// Protokolliert jeden Aufruf; mit `fail(_:)` wirft jeder Aufruf den Fehler.
import Foundation

public final class FakeMailBackend: MailBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var mails: [MailMessage]
  private var bodies: [String: String]
  private var failure: MailError?
  private var log: [String] = []
  private var sentDrafts: [MailDraft] = []
  private var openedDrafts: [MailDraft] = []

  public init(messages: [MailMessage] = [], bodies: [String: String] = [:]) {
    self.mails = messages
    self.bodies = bodies
  }

  /// Aufrufe in Reihenfolge, z. B. "inbox", "read:<id>:true", "send".
  public var calls: [String] { lock.withLock { log } }
  /// Alle gesendeten Entwürfe in Reihenfolge.
  public var sent: [MailDraft] { lock.withLock { sentDrafts } }
  /// Geöffnete Entwürfe (Nachbereitung), nie gesendet.
  public var opened: [MailDraft] { lock.withLock { openedDrafts } }
  /// Aktueller Bestand (nach Lesen, Archivieren, Löschen).
  public var messages: [MailMessage] { lock.withLock { mails } }

  /// Wirft ab jetzt bei jedem Aufruf `error`; nil schaltet es ab.
  public func fail(_ error: MailError?) {
    lock.withLock { failure = error }
  }

  private func record(_ call: String) throws {
    try lock.withLock {
      log.append(call)
      if let failure { throw failure }
    }
  }

  public func inbox(days: Int, limit: Int) async throws -> [MailMessage] {
    try record("inbox:\(days):\(limit)")
    return lock.withLock { Array(mails.prefix(max(limit, 0))) }
  }

  public func body(id: String) async throws -> String {
    try record("body:\(id)")
    return try lock.withLock {
      if let text = bodies[id] { return text }
      if mails.contains(where: { $0.id == id }) { return "" }
      throw MailError.notFound
    }
  }

  public func openReplyDraft(id: String) async throws {
    try record("reply-draft:\(id)")
    try lock.withLock {
      guard mails.contains(where: { $0.id == id }) else { throw MailError.notFound }
    }
  }

  public func setRead(id: String, _ read: Bool) async throws {
    try record("read:\(id):\(read)")
    try lock.withLock {
      guard let i = mails.firstIndex(where: { $0.id == id }) else { throw MailError.notFound }
      mails[i].read = read
    }
  }

  public func setFlagged(id: String, _ flagged: Bool) async throws {
    try record("flag:\(id):\(flagged)")
    try lock.withLock {
      guard let i = mails.firstIndex(where: { $0.id == id }) else { throw MailError.notFound }
      mails[i].flagged = flagged
    }
  }

  public func archive(id: String) async throws {
    try record("archive:\(id)")
    try removeMessage(id)
  }

  public func trash(id: String) async throws {
    try record("trash:\(id)")
    try removeMessage(id)
  }

  public func openNewDraft(_ draft: MailDraft) async throws {
    try record("newDraft")
    lock.withLock { openedDrafts.append(draft) }
  }

  public func send(_ draft: MailDraft) async throws {
    try record("send")
    lock.withLock { sentDrafts.append(draft) }
  }

  private func removeMessage(_ id: String) throws {
    try lock.withLock {
      guard let i = mails.firstIndex(where: { $0.id == id }) else { throw MailError.notFound }
      mails.remove(at: i)
    }
  }
}
