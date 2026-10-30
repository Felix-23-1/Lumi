// Eine TLS-Verbindung (Port 993, Network.framework) für genau einen Vorgang:
// verbinden, anmelden, Befehle, abmelden. Kein IDLE, kein Hintergrundthread.
// Passwörter und Mail-Inhalte werden nie geloggt und nie in Fehlertexte kopiert.
import Foundation
import Network

actor IMAPSession {
  static let port: NWEndpoint.Port = 993
  private static let queue = DispatchQueue(label: "de.felix.taby.imap")

  private let connection: NWConnection
  private var buffer = Data()
  private var counter = 0
  /// Obergrenze für alle Bytes einer Antwort (Schutz vor überlangen Antworten).
  static let maxBuffer = 20 * 1024 * 1024
  private(set) var capabilities: Set<String> = []
  /// UIDVALIDITY des zuletzt gewählten Ordners; zusammen mit der UID eine stabile Mail-Kennung.
  private(set) var uidValidity: String?

  init(host: String) {
    connection = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: .tls)
  }

  // MARK: Verbindung

  /// Baut die TLS-Verbindung auf und liest die Begrüßung.
  func open() async throws {
    let conn = connection
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let gate = OnceGate()
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if gate.open() { cont.resume() }
        case .waiting, .failed:
          // .waiting: Server nicht erreichbar; NWConnection würde sonst endlos neu versuchen.
          conn.cancel()
          if gate.open() { cont.resume(throwing: MailError.scriptFailed("Mail-Server nicht erreichbar.")) }
        case .cancelled:
          if gate.open() { cont.resume(throwing: MailError.scriptFailed("Verbindung zum Mailserver fehlgeschlagen.")) }
        default:
          break
        }
      }
      connection.start(queue: Self.queue)
    }
    while !buffer.contains(0x0A) { try await appendReceived() }
    let end = buffer.firstIndex(of: 0x0A) ?? buffer.endIndex
    let greeting = String(decoding: buffer[..<end], as: UTF8.self).uppercased()
    buffer.removeSubrange(..<min(buffer.endIndex, end + 1))
    guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
      throw MailError.scriptFailed("Der Mailserver hat sich nicht wie ein IMAP-Server gemeldet.")
    }
  }

  /// Schließt die Verbindung sofort (auch wenn gerade gelesen wird).
  nonisolated func close() {
    connection.cancel()
  }

  // MARK: Befehle

  /// Schickt einen Befehl und liefert alle Antwortzeilen bis zur Tag-Antwort.
  @discardableResult
  func command(_ text: String) async throws -> [IMAPResponse] {
    counter += 1
    let tag = "T\(counter)"
    buffer = Data()
    try await send(Data("\(tag) \(text)\r\n".utf8))
    let marker = Data("\(tag) ".utf8)
    let lineEnd = Data("\r\n".utf8)
    while true {
      // Nur parsen, wenn gerade eine Zeile vollständig ankam (sonst quadratisch bei großen Literalen).
      if buffer.suffix(2) == lineEnd, buffer.range(of: marker) != nil {
        do {
          let responses = try IMAPParser.responses(buffer)
          if let done = responses.first(where: { $0.tag == tag }) {
            guard done.keyword == "OK" else {
              throw MailError.scriptFailed("Der Mailserver hat den Befehl abgelehnt.")
            }
            return responses
          }
        } catch IMAPParseError.incomplete {
          // weiterlesen
        } catch IMAPParseError.tooLarge {
          throw MailError.scriptFailed("Antwort des Mailservers ist zu groß.")
        }
      }
      try await appendReceived()
    }
  }

  /// Anmeldung mit Benutzer und Passwort. Das Passwort landet nur im Befehl, nie in einer Meldung.
  func login(user: String, password: String) async throws {
    do {
      try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
    } catch {
      throw MailError.scriptFailed("Anmeldung am Mailserver fehlgeschlagen. Benutzername oder Passwort prüfen.")
    }
    let responses = try await command("CAPABILITY")
    let caps = responses.first { $0.keyword == "CAPABILITY" }?.items.dropFirst() ?? []
    capabilities = Set(caps.compactMap { $0.string?.uppercased() })
  }

  /// Wählt den Posteingang und liefert die Anzahl der Mails darin.
  func selectInbox() async throws -> Int {
    let responses = try await command("SELECT INBOX")
    for r in responses {
      if let first = r.items.first?.string, first.hasPrefix("[UIDVALIDITY") {
        uidValidity = first.dropFirst().dropLast().components(separatedBy: " ").last
      }
    }
    return responses.first { $0.keyword == "EXISTS" }?.number ?? 0
  }

  /// UIDs der Mails, die seit `since` (Datum, lokal) eingegangen sind, aufsteigend.
  func searchSince(_ since: Date) async throws -> [Int] {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "dd-MMM-yyyy"
    let responses = try await command("UID SEARCH SINCE \(f.string(from: since))")
    let uids = responses.first { $0.keyword == "SEARCH" }?.items.dropFirst().compactMap { $0.string.flatMap(Int.init) } ?? []
    return uids.sorted()
  }

  /// Kopfzeilen (UID, Flags, Datum, Umschlag, List-Unsubscribe) für die UIDs. Keine Mail-Körper.
  func fetchHeaders(uids: [Int]) async throws -> [[String: IMAPValue]] {
    guard !uids.isEmpty else { return [] }
    let set = uids.map(String.init).joined(separator: ",")
    let responses = try await command(
      "UID FETCH \(set) (UID FLAGS INTERNALDATE ENVELOPE BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE)])")
    return responses.filter { $0.keyword == "FETCH" }.compactMap { IMAPParser.pairs($0) }
  }

  /// Kopf und Text einer Mail (ohne Markierung als gelesen). Liefert die rohen Bytes.
  func fetchRaw(uid: Int) async throws -> Data? {
    let responses = try await command("UID FETCH \(uid) (BODY.PEEK[HEADER] BODY.PEEK[TEXT])")
    let pairs = responses.filter { $0.keyword == "FETCH" }.compactMap { IMAPParser.pairs($0) }.first ?? [:]
    let header = pairs.first { $0.key.hasPrefix("BODY[HEADER]") }?.value.data ?? Data()
    let text = pairs.first { $0.key.hasPrefix("BODY[TEXT]") }?.value.data ?? Data()
    guard !pairs.isEmpty else { return nil }
    return header + Data("\r\n\r\n".utf8) + text
  }

  /// Umschlag (Absender, Betreff) einer Mail.
  func fetchEnvelope(uid: Int) async throws -> IMAPValue? {
    let responses = try await command("UID FETCH \(uid) (ENVELOPE)")
    let pairs = responses.filter { $0.keyword == "FETCH" }.compactMap { IMAPParser.pairs($0) }.first ?? [:]
    return pairs["ENVELOPE"]
  }

  /// Setzt oder löscht ein Flag (z. B. `\Seen`), ohne Antwort vom Server.
  func setFlag(uid: Int, _ flag: String, on: Bool) async throws {
    try await command("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
  }

  /// Ordner mit Namen und Sonderrolle (`\Archive`, `\Trash`) per LIST.
  func listFolders() async throws -> [IMAPFolder] {
    let responses = try await command("LIST \"\" \"*\"")
    return responses.filter { $0.keyword == "LIST" }.compactMap { r -> IMAPFolder? in
      guard r.items.count >= 4 else { return nil }
      let attrs = (r.items[1].list ?? []).compactMap { $0.string?.uppercased() }
      let delimiter = r.items[2].optionalString ?? "/"
      guard let name = r.items[3].optionalString else { return nil }
      return IMAPFolder(name: name, delimiter: delimiter, attributes: attrs)
    }
  }

  /// Verschiebt eine Mail per UID MOVE (RFC 6851). Ohne MOVE-Fähigkeit: kein Verschieben.
  func move(uid: Int, to folder: String) async throws {
    guard capabilities.contains("MOVE") else {
      throw MailError.scriptFailed("Der Mailserver unterstützt kein Verschieben (MOVE).")
    }
    try await command("UID MOVE \(uid) \(Self.quote(folder))")
  }

  // MARK: Hilfen

  /// Quoted String nach RFC 3501: Anführungszeichen und Backslash werden escaped, Zeilenumbrüche entfallen.
  static func quote(_ s: String) -> String {
    // "\r\n" ist ein einziges Character in Swift, daher über CharacterSet statt über filter.
    let clean = s.components(separatedBy: CharacterSet(charactersIn: "\r\n")).joined()
    return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  private func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if error != nil {
          cont.resume(throwing: MailError.scriptFailed("Verbindung zum Mailserver unterbrochen."))
        } else {
          cont.resume()
        }
      })
    }
  }

  /// Liest einen Teil vom Server in den Puffer; sprengt die Antwort die Obergrenze, bricht der Vorgang ab.
  private func appendReceived() async throws {
    buffer.append(try await receive())
    guard buffer.count <= Self.maxBuffer else {
      throw MailError.scriptFailed("Antwort des Mailservers ist zu groß.")
    }
  }

  private func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
        if error != nil {
          cont.resume(throwing: MailError.scriptFailed("Verbindung zum Mailserver unterbrochen."))
        } else if let data, !data.isEmpty {
          cont.resume(returning: data)
        } else if isComplete {
          cont.resume(throwing: MailError.scriptFailed("Der Mailserver hat die Verbindung beendet."))
        } else {
          cont.resume(returning: Data())
        }
      }
    }
  }
}

/// Ein Ordner aus LIST.
struct IMAPFolder: Equatable {
  let name: String
  let delimiter: String
  let attributes: [String]

  /// Letzter Teil des Namens ("INBOX.Archiv" → "Archiv").
  var leaf: String {
    name.components(separatedBy: delimiter.isEmpty ? "/" : delimiter).last ?? name
  }
}

/// Ruft `fire` nur einmal auf (Zustandswechsel können mehrfach kommen).
final class OnceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false

  func open() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if fired { return false }
    fired = true
    return true
  }
}

enum IMAPTimeout {
  /// Bricht den Vorgang nach `seconds` ab. Wartet nicht auf den Vorgang selbst (eine TaskGroup
  /// würde auf einen hängenden Empfang warten): nach Ablauf ruft `onTimeout` auf, etwa die
  /// Verbindung schließen, und der Aufrufer bekommt `MailError.timeout` pünktlich.
  static func run<T: Sendable>(seconds: Double, onTimeout: @escaping @Sendable () -> Void = {},
                               _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
      let gate = OnceGate()
      let work = Task {
        do {
          let value = try await op()
          if gate.open() { cont.resume(returning: value) }
        } catch {
          if gate.open() { cont.resume(throwing: error) }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled, gate.open() else { return }
        work.cancel()
        onTimeout()
        cont.resume(throwing: MailError.timeout)
      }
    }
  }
}
