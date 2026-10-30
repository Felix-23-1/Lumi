// Apple Mail über osascript (JXA). Skripte in AppleMailScripts.swift. Parameter
// gehen nur als ein JSON-Argument hinein; nie Werte in den Skriptquelltext.
import Foundation

public final class AppleMailBackend: MailBackend {
  static let osascript = "/usr/bin/osascript"
  static let maxBodyCharacters = 20_000

  public init() {}

  public func inbox(days: Int, limit: Int) async throws -> [MailMessage] {
    let params: [String: JSONValue] = [
      "days": .number(Double(min(max(days, 1), 30))),
      "limit": .number(Double(min(max(limit, 1), 100))),
    ]
    let out = try await Self.run(AppleMailScripts.inbox, params, timeout: 30)
    return try AppleMailParser.inbox(out)
  }

  public func body(id: String) async throws -> String {
    let out = try await Self.run(AppleMailScripts.body, ["id": .string(id)], timeout: 15)
    return try AppleMailParser.body(out)
  }

  public func openReplyDraft(id: String) async throws {
    _ = try await Self.run(AppleMailScripts.replyDraft, ["id": .string(id)], timeout: 15)
  }

  public func setRead(id: String, _ read: Bool) async throws {
    _ = try await Self.run(AppleMailScripts.setRead, ["id": .string(id), "read": .bool(read)], timeout: 15)
  }

  public func setFlagged(id: String, _ flagged: Bool) async throws {
    _ = try await Self.run(AppleMailScripts.setFlagged, ["id": .string(id), "flagged": .bool(flagged)], timeout: 15)
  }

  public func archive(id: String) async throws {
    _ = try await Self.run(AppleMailScripts.archive, ["id": .string(id)], timeout: 15)
  }

  public func trash(id: String) async throws {
    _ = try await Self.run(AppleMailScripts.trash, ["id": .string(id)], timeout: 15)
  }

  public func send(_ draft: MailDraft) async throws {
    var params: [String: JSONValue] = [
      "to": .array(draft.to.map { .string($0) }),
      "subject": .string(draft.subject),
      "body": .string(draft.body),
    ]
    if let replyToId = draft.replyToId { params["replyToId"] = .string(replyToId) }
    _ = try await Self.run(AppleMailScripts.send, params, timeout: 15)
  }

  public func openNewDraft(_ draft: MailDraft) async throws {
    _ = try await Self.run(AppleMailScripts.newDraft, Self.draftParams(draft), timeout: 15)
  }

  /// Werte gehen nur als JSON-Argument ins Skript, nie als Text im Skriptquelltext.
  static func draftParams(_ draft: MailDraft) -> [String: JSONValue] {
    [
      "to": .array(draft.to.map { .string($0) }),
      "subject": .string(draft.subject),
      "body": .string(draft.body),
    ]
  }

  /// Startet osascript mit dem festen Skript und einem JSON-Argument. Läuft auf
  /// einer Hintergrund-Warteschlange, nicht auf dem Hauptthread.
  static func run(_ script: String, _ params: [String: JSONValue], timeout: TimeInterval) async throws -> String {
    let argument = JSONValue.object(params).jsonString()
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let r = try ModProcess.run(osascript, ["-l", "JavaScript", "-e", script, argument], timeout: timeout)
          if r.timedOut {
            continuation.resume(throwing: MailError.timeout)
          } else if r.status != 0 {
            continuation.resume(throwing: mapFailure(r.stderr))
          } else {
            continuation.resume(returning: r.stdout)
          }
        } catch {
          continuation.resume(throwing: MailError.scriptFailed("Apple Mail konnte nicht gestartet werden."))
        }
      }
    }
  }

  /// Ordnet die Fehlerausgabe von osascript einem `MailError` zu.
  static func mapFailure(_ stderr: String) -> MailError {
    if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("Not authorized") {
      return .accessDenied
    }
    if stderr.contains("NO_ACCOUNT") { return .notConfigured }
    if stderr.contains("NOT_FOUND") { return .notFound }
    if stderr.contains("NO_ARCHIVE") { return .scriptFailed("Kein Archiv-Ordner gefunden") }
    let firstLine = stderr.split(whereSeparator: \.isNewline).first.map {
      String($0).trimmingCharacters(in: .whitespaces)
    } ?? ""
    return .scriptFailed(firstLine)
  }
}

/// Wandelt die JSON-Ausgabe der Skripte in Vertragstypen um.
enum AppleMailParser {
  struct RawHeader: Decodable {
    let id: String?
    let subject: String?
    let sender: String?
    let date: String?
    let read: Bool?
    let flagged: Bool?
    let account: String?
    let mailbox: String?
  }

  struct RawBody: Decodable {
    let content: String?
  }

  static func inbox(_ stdout: String) throws -> [MailMessage] {
    let rows = try decode([RawHeader].self, stdout)
    return rows.compactMap { r -> MailMessage? in
      guard let id = r.id, !id.isEmpty else { return nil }
      let parsed = MailAddress.parse(r.sender ?? "")
      return MailMessage(
        id: id,
        senderName: parsed.name.isEmpty ? parsed.address : parsed.name,
        senderAddress: parsed.address,
        subject: r.subject ?? "",
        date: localDate(r.date),
        read: r.read ?? false,
        flagged: r.flagged ?? false,
        account: r.account ?? "",
        mailbox: r.mailbox ?? "INBOX",
        category: .normal)
    }
  }

  static func body(_ stdout: String) throws -> String {
    let text = try decode(RawBody.self, stdout).content ?? ""
    return String(text.prefix(AppleMailBackend.maxBodyCharacters))
  }

  /// ISO-Zeit aus JavaScript ("…T08:30:00.000Z") → lokal "YYYY-MM-DDTHH:mm".
  static func localDate(_ iso: String?) -> String {
    guard let iso else { return "" }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }
    return LocalTime.format(date)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: Data(text.utf8))
    } catch {
      throw MailError.scriptFailed("Unerwartete Antwort von Apple Mail.")
    }
  }
}
