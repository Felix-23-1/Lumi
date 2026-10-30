// Paket 12: Element / Matrix über die Matrix Rust SDK (uniffi-Bindings in Vendor/MatrixSDK).
// Oben stehen die reinen Teile (Adresse, Kennung, Geheimnis-Format, Status): ohne SDK,
// immer gebaut und geprüft. Alles, was das SDK braucht, steht in `#if TABY_MATRIX`.
// Das Geheimnis (Sitzung + Speicher-Passphrase, nie das Passwort) geht in den Schlüsselbund.
import Foundation
#if TABY_MATRIX
import MatrixSDK
#endif

// MARK: - Reine Teile (ohne SDK)

/// Eingaben aus dem Anmeldeformular.
public enum MatrixLoginInput {
  /// Server als Name ("matrix.org") oder URL; Leerraum und abschließende "/" fallen weg.
  public static func homeserver(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  /// Benutzer: Kurzname oder vollständige Kennung ("@name:server"), ohne Leerraum am Rand.
  public static func user(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Vollständige Kennung "@name:server" (ohne Leerzeichen im Namen und Server).
  public static func isUserId(_ raw: String) -> Bool {
    let s = user(raw)
    guard s.hasPrefix("@"), !s.contains(where: \.isWhitespace), let colon = s.firstIndex(of: ":") else { return false }
    let name = s[s.index(after: s.startIndex)..<colon]
    let server = s[s.index(after: colon)...]
    return !name.isEmpty && !server.isEmpty
  }

  /// Sicherheitsschlüssel: Leerzeichen und Zeilenumbrüche weg (Gruppen von 4 Zeichen beim Abschreiben).
  public static func recoveryKey(_ raw: String) -> String {
    String(raw.filter { !$0.isWhitespace })
  }

  /// Anmelden erst, wenn alle drei Felder gefüllt sind.
  public static func canSubmit(server: String, user name: String, password: String) -> Bool {
    !homeserver(server).isEmpty && !user(name).isEmpty && !password.isEmpty
  }
}

/// Abbildung von Matrix-Zuständen auf Lumi-Status.
public enum MatrixStatusMap {
  public static let wrongKeyText = "Sicherheitsschlüssel passt nicht."
  public static let unlockFailedText = "Entsperren fehlgeschlagen. Verbindung zum Element-Server prüfen und erneut versuchen."

  /// Nur wenn der Schlüssel diesem Gerät noch fehlt (Wiederherstellung „unvollständig“) ist das Konto gesperrt.
  /// Ohne eingerichtete Wiederherstellung hilft kein Schlüssel; noch unbekannt gilt vorerst als verbunden.
  public static func status(keyMissing: Bool) -> MessengerStatus {
    keyMissing ? .locked : .connected
  }

  /// Fehlertext, wenn der Sicherheitsschlüssel nicht passt. "MAC check" heißt: der Schlüssel gehört
  /// zu einer anderen Sicherung (Element hat sie neu erzeugt), nicht zu einem Tippfehler.
  public static func keyMismatchText(detail: String) -> String {
    guard !detail.isEmpty else { return wrongKeyText }
    if detail.contains("MAC check") {
      return "Dieser Schlüssel gehört nicht zur aktuellen Sicherung (vermutlich wurde er in Element neu erzeugt). "
        + "Nimm den neuesten Schlüssel oder bestätige Lumi über ein anderes Gerät. (\(detail))"
    }
    return "\(wrongKeyText) (\(detail))"
  }
}

/// Geräte-Bestätigung (Emoji-Vergleich): SDK-Namen der 64 Emojis auf Deutsch.
public enum MatrixVerificationText {
  public static func emoji(symbol: String, name: String) -> MessengerEmoji {
    MessengerEmoji(symbol: symbol, name: germanNames[name.lowercased()] ?? name)
  }

  /// Englische Namen (Kleinschreibung) aus der Matrix-Spezifikation → deutsch. Unbekannte bleiben englisch.
  static let germanNames: [String: String] = [
    "dog": "Hund", "cat": "Katze", "lion": "Löwe", "horse": "Pferd", "unicorn": "Einhorn", "pig": "Schwein",
    "elephant": "Elefant", "rabbit": "Hase", "panda": "Panda", "rooster": "Hahn", "penguin": "Pinguin",
    "turtle": "Schildkröte", "fish": "Fisch", "octopus": "Oktopus", "butterfly": "Schmetterling",
    "flower": "Blume", "tree": "Baum", "cactus": "Kaktus", "mushroom": "Pilz", "globe": "Weltkugel",
    "moon": "Mond", "cloud": "Wolke", "fire": "Feuer", "banana": "Banane", "apple": "Apfel",
    "strawberry": "Erdbeere", "corn": "Mais", "pizza": "Pizza", "cake": "Kuchen", "heart": "Herz",
    "smiley": "Smiley", "robot": "Roboter", "hat": "Hut", "glasses": "Brille", "spanner": "Schraubenschlüssel",
    "santa claus": "Weihnachtsmann", "santa": "Weihnachtsmann", "thumbs up": "Daumen hoch",
    "umbrella": "Regenschirm", "hourglass": "Sanduhr", "clock": "Uhr", "gift": "Geschenk",
    "light bulb": "Glühbirne", "book": "Buch", "pencil": "Bleistift", "paperclip": "Büroklammer",
    "scissors": "Schere", "lock": "Schloss", "key": "Schlüssel", "hammer": "Hammer", "telephone": "Telefon",
    "flag": "Flagge", "train": "Zug", "bicycle": "Fahrrad", "aeroplane": "Flugzeug", "airplane": "Flugzeug",
    "rocket": "Rakete", "trophy": "Pokal", "ball": "Ball", "guitar": "Gitarre", "trumpet": "Trompete",
    "bell": "Glocke", "anchor": "Anker", "headphones": "Kopfhörer", "folder": "Ordner", "pin": "Stecknadel",
  ]
}

/// Speicherort je Konto (Sitzungs- und Cache-Datenbank).
public enum MatrixStorage {
  /// Wie `AppDelegate.dataDirectory` (Application Support/de.felix.taby) plus "Matrix".
  public static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("de.felix.taby/Matrix").path

  public static func root(accountId: String, base: String = MatrixStorage.base) -> String {
    (base as NSString).appendingPathComponent(accountId)
  }
}

/// Was im Schlüsselbund liegt: Sitzung und Speicher-Passphrase. Kein Passwort.
public struct MatrixSecret: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var userId: String
  public var deviceId: String
  public var homeserverUrl: String
  public var oauthData: String?
  public var passphrase: String

  public init(accessToken: String, refreshToken: String?, userId: String, deviceId: String,
              homeserverUrl: String, oauthData: String?, passphrase: String) {
    self.accessToken = accessToken; self.refreshToken = refreshToken; self.userId = userId
    self.deviceId = deviceId; self.homeserverUrl = homeserverUrl; self.oauthData = oauthData
    self.passphrase = passphrase
  }

  /// Zufällige 32 Byte als Hex je Konto (verschlüsselt den lokalen Speicher).
  public static func newPassphrase() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  public func json() throws -> String {
    let data = try JSONEncoder().encode(self)
    return String(decoding: data, as: UTF8.self)
  }

  public static func parse(_ json: String) throws -> MatrixSecret {
    do {
      return try JSONDecoder().decode(MatrixSecret.self, from: Data(json.utf8))
    } catch {
      // Bewusst ohne Inhalt: die Zeichenkette enthält Zugangsdaten.
      throw MessengerFailure(message: "Die gespeicherte Anmeldung ist beschädigt. Bitte neu verbinden.")
    }
  }
}

// MARK: - Connector (Matrix Rust SDK)

#if TABY_MATRIX

/// Zählt Ereignisse aus SDK-Listenern; `wait` wartet ohne zu blockieren auf das nächste (mit Zeitlimit).
private final class MatrixPulse: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  var current: Int { lock.lock(); defer { lock.unlock() }; return count }

  func fire() {
    lock.lock()
    count += 1
    let ready = Array(waiters.values); waiters = [:]
    lock.unlock()
    ready.forEach { $0.resume() }
  }

  /// Kehrt zurück, sobald seit `seen` ein Ereignis kam oder `seconds` vergangen sind.
  func wait(after seen: Int, seconds: Double) async {
    let id = UUID()
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      lock.lock()
      if count != seen { lock.unlock(); k.resume(); return }
      waiters[id] = k
      lock.unlock()
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        self?.timeout(id)
      }
    }
  }

  private func timeout(_ id: UUID) {
    lock.lock(); let k = waiters.removeValue(forKey: id); lock.unlock()
    k?.resume()
  }
}

/// Beobachtet den Wiederherstellungs-Zustand (er ist nach dem Start erst `.unknown`).
private final class MatrixRecoveryWatch: RecoveryStateListener, @unchecked Sendable {
  let pulse = MatrixPulse()
  func onUpdate(status: RecoveryState) { pulse.fire() }
}

/// Hält den Zustand einer Unterhaltung: Timeline und die bisher gesammelten Einträge.
private final class MatrixRoomTimeline: TimelineListener, @unchecked Sendable {
  let timeline: Timeline
  private let lock = NSLock()
  private var items: [TimelineItem] = []
  private var handle: TaskHandle?
  let pulse = MatrixPulse()

  init(timeline: Timeline) { self.timeline = timeline }

  /// Listener anmelden und auf den ersten Stand (Reset-Diff) warten, höchstens 3 s.
  func attach() async {
    let seen = pulse.current
    keep(await timeline.addListener(listener: self))
    await pulse.wait(after: seen, seconds: 3)
  }

  /// Hält den Listener am Leben (sonst endet die Beobachtung sofort).
  private func keep(_ h: TaskHandle) {
    lock.lock(); defer { lock.unlock() }
    handle = h
  }

  /// Beendet die Beobachtung. Nötig: die SDK-Aufgabe hält den Listener (self) fest, sonst ein Kreis.
  func detach() {
    lock.lock(); let h = handle; handle = nil; lock.unlock()
    h?.cancel()
  }

  func snapshot() -> [TimelineItem] {
    lock.lock(); defer { lock.unlock() }
    return items
  }

  func onUpdate(diff: [TimelineDiff]) {
    lock.lock()
    for d in diff { apply(d) }
    lock.unlock()
    pulse.fire()
  }

  // Bounds-Prüfung: ein unerwarteter Index darf die App nicht abstürzen lassen.
  private func apply(_ d: TimelineDiff) {
    switch d {
    case .append(let v): items += v
    case .clear: items.removeAll()
    case .pushFront(let v): items.insert(v, at: 0)
    case .pushBack(let v): items.append(v)
    case .popFront: if !items.isEmpty { items.removeFirst() }
    case .popBack: if !items.isEmpty { items.removeLast() }
    case .insert(let i, let v): if Int(i) <= items.count { items.insert(v, at: Int(i)) }
    case .set(let i, let v): if Int(i) < items.count { items[Int(i)] = v }
    case .remove(let i): if Int(i) < items.count { items.remove(at: Int(i)) }
    case .truncate(let n): items = Array(items.prefix(Int(n)))
    case .reset(let v): items = v
    }
  }
}

/// Ereignisse der SDK-Bestätigung (Element-X-Ablauf) als Lumi-Phasen.
private final class MatrixVerificationListener: SessionVerificationControllerDelegate, @unchecked Sendable {
  let accountId: String
  let report: @Sendable (MessengerVerification) -> Void
  /// Schwach: die Sitzung hält den Controller ohnehin, der Listener soll keinen Kreis bilden.
  weak var controller: SessionVerificationController?
  /// Abgelöste Abläufe melden nichts mehr, damit späte Abbrüche den neuen Ablauf nicht überschreiben.
  var active = true

  init(accountId: String, report: @escaping @Sendable (MessengerVerification) -> Void) {
    self.accountId = accountId
    self.report = report
  }

  private func send(_ phase: MessengerVerification.Phase, emojis: [MessengerEmoji] = [], message: String? = nil) {
    guard active else { return }
    report(MessengerVerification(accountId: accountId, phase: phase, emojis: emojis, message: message))
  }

  func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {}

  func didAcceptVerificationRequest() {
    // Das andere Gerät hat angenommen: jetzt den Emoji-Vergleich starten.
    let controller = self.controller
    Task {
      do {
        try await controller?.startSasVerification()
      } catch {
        send(.failed, message: "Der Emoji-Vergleich konnte nicht starten. Erneut versuchen.")
      }
    }
  }

  func didStartSasVerification() {}

  func didReceiveVerificationData(data: SessionVerificationData) {
    switch data {
    case .emojis(let emojis, _):
      send(.showEmojis, emojis: emojis.map { MatrixVerificationText.emoji(symbol: $0.symbol(), name: $0.description()) })
    case .decimals:
      let controller = self.controller
      Task { try? await controller?.cancelVerification() }
      send(.failed, message: "Der Vergleich mit Zahlen wird nicht unterstützt. Bitte an einem Gerät mit Emojis erneut anfragen.")
    }
  }

  func didFail() { send(.failed, message: "Die Bestätigung ist fehlgeschlagen. Erneut versuchen.") }
  func didCancel() { send(.cancelled, message: "Die Bestätigung wurde abgebrochen.") }
  func didFinish() { send(.done) }
}

public final class MatrixConnector: MessengerConnector, @unchecked Sendable {
  public let service: MessengerService = .matrix

  private let state = NSLock()
  private var accountId = ""
  private var client: Client?
  private var sync: SyncService?
  private var timelines: [String: MatrixRoomTimeline] = [:]
  private let recovery = MatrixRecoveryWatch()
  private var recoveryHandle: TaskHandle?
  private var verifier: (controller: SessionVerificationController, listener: MatrixVerificationListener)?

  public init() {}

  private func guarded<T>(_ body: () -> T) -> T {
    state.lock(); defer { state.unlock() }
    return body()
  }

  private func currentClient() throws -> Client {
    guard let c = guarded({ client }) else { throw MessengerFailure(message: "Nicht angemeldet.") }
    return c
  }

  // MARK: Anmelden / Wiederherstellen

  public func login(_ login: MessengerLogin, accountId: String) async throws -> (account: MessengerAccount, secret: String) {
    let server = MatrixLoginInput.homeserver(login.server)
    let user = MatrixLoginInput.user(login.user)
    guard MatrixLoginInput.canSubmit(server: server, user: user, password: login.secret) else {
      throw MessengerFailure(message: "Server, Benutzername und Passwort eintragen.")
    }
    guarded { self.accountId = accountId }
    let passphrase = MatrixSecret.newPassphrase()
    let c: Client
    do {
      c = try await makeClient(ClientBuilder().serverNameOrHomeserverUrl(serverNameOrUrl: server),
                               accountId: accountId, passphrase: passphrase)
      try await c.login(username: user, password: login.secret, initialDeviceName: "Lumi (Mac)", deviceId: nil)
    } catch {
      // Kein Konto entstanden: den angelegten Speicherordner wieder entfernen.
      try? FileManager.default.removeItem(atPath: MatrixStorage.root(accountId: accountId))
      throw (error as? MessengerFailure)
        ?? MessengerFailure(message: "Anmeldung fehlgeschlagen. Server, Benutzername und Passwort prüfen. (\(error))")
    }
    let session = try c.session()
    let secret = MatrixSecret(accessToken: session.accessToken, refreshToken: session.refreshToken,
                              userId: session.userId, deviceId: session.deviceId,
                              homeserverUrl: session.homeserverUrl, oauthData: session.oauthData,
                              passphrase: passphrase)
    guarded { self.client = c }
    try await startSync(c)
    let account = MessengerAccount(id: accountId, service: .matrix, server: server, user: session.userId,
                                   status: await settledStatus(c))
    return (account, try secret.json())
  }

  public func restore(_ account: MessengerAccount, secret: String) async throws -> MessengerAccount {
    guarded { self.accountId = account.id }  // vor dem Prüfen: Abmelden räumt dann auch hier den Ordner
    let s = try MatrixSecret.parse(secret)
    let c = try await makeClient(ClientBuilder().homeserverUrl(url: s.homeserverUrl),
                                 accountId: account.id, passphrase: s.passphrase)
    let session = Session(accessToken: s.accessToken, refreshToken: s.refreshToken, userId: s.userId,
                          deviceId: s.deviceId, homeserverUrl: s.homeserverUrl, oauthData: s.oauthData,
                          slidingSyncVersion: .native)
    try await c.restoreSession(session: session)
    guarded { self.client = c }
    try await startSync(c)
    var restored = account
    restored.user = s.userId
    restored.status = await settledStatus(c)
    return restored
  }

  /// Sicherheitsschlüssel einlesen; danach gelten die verschlüsselten Chats als entsperrt.
  public func unlock(recoveryKey: String) async throws {
    let c = try currentClient()
    // Erst unverändert (Sicherheitsphrase enthält Leerzeichen), dann ohne Leerzeichen (Schlüssel in Vierergruppen).
    let raw = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let stripped = MatrixLoginInput.recoveryKey(recoveryKey)
    var lastDetail = ""
    for candidate in raw == stripped ? [raw] : [raw, stripped] {
      do {
        try await c.encryption().recover(recoveryKey: candidate)
        return
      } catch RecoveryError.SecretStorage(let m), RecoveryError.Import(let m) {
        lastDetail = m
      } catch {
        throw MessengerFailure(message: "\(MatrixStatusMap.unlockFailedText) (\(error))")
      }
    }
    throw MessengerFailure(message: MatrixStatusMap.keyMismatchText(detail: lastDetail))
  }

  /// Aktueller Stand für den Takt (der Wiederherstellungs-Zustand kann sich nach dem Start noch klären).
  public func currentStatus() async -> MessengerStatus? {
    guard let c = guarded({ client }) else { return nil }
    return MatrixStatusMap.status(keyMissing: keyMissing(c))
  }

  // MARK: Unterhaltungen

  public func conversations() async throws -> [MessengerConversation] {
    let c = try currentClient()
    let acc = guarded { accountId }
    var out: [MessengerConversation] = []
    for room in c.rooms() {
      guard case .joined = room.membership() else { continue }
      let info = try? await room.roomInfo()
      let roomId = room.id()
      let title = info?.displayName ?? room.displayName() ?? roomId
      let (lastText, lastAt) = Self.latest(await room.latestEvent())
      out.append(MessengerConversation(
        id: "\(acc)|\(roomId)", accountId: acc, title: title,
        unread: Int(info?.numUnreadMessages ?? 0), lastText: lastText, lastAt: lastAt,
        isDirect: info?.isDirect ?? false))
    }
    return out
  }

  public func messages(roomId: String, limit: Int) async throws -> [MessengerMessage] {
    let rt = try await roomTimeline(roomId)
    // Rückwärts blättern, bis genug Textnachrichten da sind oder der Anfang erreicht ist.
    var rounds = 0
    while Self.messages(rt.snapshot(), accountId: guarded { accountId }, roomId: roomId).count < limit, rounds < 8 {
      rounds += 1
      let seen = rt.pulse.current
      let atStart = try await rt.timeline.paginateBackwards(numEvents: 40)
      // Die neuen Einträge kommen danach über den Listener: auf den ersten Diff warten, höchstens 1 s.
      await rt.pulse.wait(after: seen, seconds: 1)
      if atStart { break }
    }
    return Array(Self.messages(rt.snapshot(), accountId: guarded { accountId }, roomId: roomId).suffix(limit))
  }

  public func send(roomId: String, text: String) async throws {
    try await send(roomId: roomId, text: text, replyTo: nil)
  }

  /// Mit `replyTo` geht die Nachricht in den Thread dieser Nachricht (deren Wurzel, sonst sie selbst als neue Wurzel).
  /// Fehlt der Thread-Zugriff, bleibt die einfache Antwort (Zitat) als Rückfall.
  public func send(roomId: String, text: String, replyTo: String?) async throws {
    let rt = try await roomTimeline(roomId)
    do {
      let content = messageEventContentFromMarkdown(md: text)
      guard let replyTo else { _ = try await rt.timeline.send(msg: content); return }
      let root = Self.threadRoot(of: replyTo, in: rt.snapshot()) ?? replyTo
      if let thread = try? await threadTimeline(roomId: roomId, root: root) {
        _ = try await thread.send(msg: content)
      } else {
        _ = try await rt.timeline.sendReply(msg: content, eventId: replyTo)
      }
    } catch {
      throw MessengerFailure(message: "Die Nachricht konnte nicht gesendet werden.")
    }
  }

  private func threadTimeline(roomId: String, root: String) async throws -> Timeline {
    let c = try currentClient()
    guard let room = try c.getRoom(roomId: roomId) else { throw MessengerFailure(message: "Unterhaltung nicht gefunden.") }
    return try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
      focus: .thread(rootEventId: root), filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
      trackReadReceipts: .disabled, reportUtds: false))
  }

  /// Thread-Wurzel der Nachricht `eventId`, falls sie selbst in einem Thread steht.
  private static func threadRoot(of eventId: String, in items: [TimelineItem]) -> String? {
    for item in items {
      guard let e = item.asEvent(), case .eventId(let id) = e.eventOrTransactionId, id == eventId,
            case .msgLike(let m) = e.content else { continue }
      return m.threadRoot
    }
    return nil
  }

  public func markRead(roomId: String) async throws {
    let rt = try await roomTimeline(roomId)
    try await rt.timeline.markAsRead(receiptType: .read)
  }

  public func logout() async {
    let (c, s, acc, rts, rh) = guarded { () -> (Client?, SyncService?, String, [MatrixRoomTimeline], TaskHandle?) in
      let r = (client, sync, accountId, Array(timelines.values), recoveryHandle)
      client = nil; sync = nil; timelines = [:]; accountId = ""; recoveryHandle = nil
      return r
    }
    rts.forEach { $0.detach() }
    rh?.cancel()
    await s?.stop()
    try? await c?.logout()
    if !acc.isEmpty { try? FileManager.default.removeItem(atPath: MatrixStorage.root(accountId: acc)) }
  }

  // MARK: Geräte-Bestätigung (Emoji-Vergleich)

  public func startVerification(report: @escaping @Sendable (MessengerVerification) -> Void) async throws {
    let c = try currentClient()
    await cancelVerification()
    let acc = guarded { accountId }
    let controller = try await c.getSessionVerificationController()
    let listener = MatrixVerificationListener(accountId: acc, report: report)
    listener.controller = controller
    controller.setDelegate(delegate: listener)
    guarded { verifier = (controller, listener) }
    do {
      try await controller.requestDeviceVerification()
    } catch {
      throw MessengerFailure(message: "Die Bestätigung ließ sich nicht starten. Ist Element angemeldet? (\(error))")
    }
  }

  public func answerVerification(matches: Bool) async throws {
    guard let controller = guarded({ verifier?.controller }) else {
      throw MessengerFailure(message: "Gerade läuft keine Bestätigung.")
    }
    do {
      if matches { try await controller.approveVerification() } else { try await controller.declineVerification() }
    } catch {
      throw MessengerFailure(message: "Die Bestätigung ließ sich nicht abschließen. (\(error))")
    }
  }

  public func cancelVerification() async {
    let running = guarded { () -> SessionVerificationController? in
      let c = verifier?.controller
      verifier?.listener.active = false
      verifier = nil
      return c
    }
    try? await running?.cancelVerification()
  }

  // MARK: Hilfen

  private func makeClient(_ builder: ClientBuilder, accountId: String, passphrase: String) async throws -> Client {
    let root = MatrixStorage.root(accountId: accountId)
    let data = (root as NSString).appendingPathComponent("data")
    let cache = (root as NSString).appendingPathComponent("cache")
    try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    let store = SqliteStoreBuilder(dataPath: data, cachePath: cache).passphrase(passphrase: passphrase)
    do {
      // Ohne Angabe nutzt das SDK keine Synchronisierung, und der SyncService lässt sich nicht starten.
      return try await builder.slidingSyncVersionBuilder(versionBuilder: .discoverNative)
        .sqliteStore(config: store).build()
    } catch let e as ClientBuildError {
      throw MessengerFailure(message: Self.buildErrorText(e))
    } catch {
      throw MessengerFailure(message: "Der Matrix-Server ist nicht erreichbar. Adresse prüfen. (\(error))")
    }
  }

  static func buildErrorText(_ e: ClientBuildError) -> String {
    switch e {
    case .InvalidServerName: return "Die Server-Adresse ist ungültig."
    case .ServerUnreachable, .WellKnownLookupFailed, .WellKnownDeserializationError:
      return "Der Matrix-Server ist nicht erreichbar. Adresse prüfen."
    case .SlidingSync, .SlidingSyncVersion:
      return "Dieser Matrix-Server unterstützt die nötige Synchronisierung (Sliding Sync) nicht. "
        + "Der Server braucht Synapse ab Version 1.114 bzw. einen Sliding-Sync-Proxy."
    default: return "Element-Fehler: \(e)"
    }
  }

  private func startSync(_ c: Client) async throws {
    do {
      let s = try await c.syncService().finish()
      await s.start()
      guarded { self.sync = s }
    } catch {
      throw MessengerFailure(message: "Die Synchronisierung mit dem Matrix-Server ließ sich nicht starten. (\(error))")
    }
  }

  private func keyMissing(_ c: Client) -> Bool {
    // Von einem anderen Gerät bestätigt: die Schlüssel kamen von dort, kein Sicherheitsschlüssel nötig.
    if c.encryption().verificationState() == .verified { return false }
    if case .incomplete = c.encryption().recoveryState() { return true }
    return false
  }

  /// Wartet (höchstens 10 s, ohne zu blockieren), bis der Wiederherstellungs-Zustand nicht mehr `.unknown` ist.
  /// Bleibt er unbekannt, gilt das Konto vorerst als verbunden; der Takt prüft später über `currentStatus` nach.
  private func settledStatus(_ c: Client) async -> MessengerStatus {
    let enc = c.encryption()
    let handle = enc.recoveryStateListener(listener: recovery)
    guarded { recoveryHandle?.cancel(); recoveryHandle = handle }
    let deadline = Date().addingTimeInterval(10)
    while true {
      let seen = recovery.pulse.current
      if enc.recoveryState() != .unknown { break }
      let left = deadline.timeIntervalSinceNow
      if left <= 0 { break }
      await recovery.pulse.wait(after: seen, seconds: left)
    }
    return MatrixStatusMap.status(keyMissing: keyMissing(c))
  }

  private func roomTimeline(_ roomId: String) async throws -> MatrixRoomTimeline {
    if let known = guarded({ timelines[roomId] }) { return known }
    let c = try currentClient()
    guard let room = try c.getRoom(roomId: roomId) else {
      throw MessengerFailure(message: "Unterhaltung nicht gefunden.")
    }
    let rt = MatrixRoomTimeline(timeline: try await room.timeline())
    await rt.attach()
    // Zwei gleichzeitige Aufrufe: der erste gewinnt, der zweite gibt seinen Listener wieder frei.
    let winner = guarded { () -> MatrixRoomTimeline in
      if let known = timelines[roomId] { return known }
      timelines[roomId] = rt
      return rt
    }
    if winner !== rt { rt.detach() }
    return winner
  }

  /// Text eines Ereignisses: nil = kein Text (Bild, Reaktion, Status …).
  private enum Body { case text(String), encrypted }

  private static func body(_ content: TimelineItemContent) -> Body? {
    guard case .msgLike(let m) = content else { return nil }
    switch m.kind {
    case .message(let mc):
      if case .text(let t) = mc.msgType { return .text(t.body) }
      return nil
    case .unableToDecrypt:
      return .encrypted
    default:
      return nil
    }
  }

  private static func latest(_ v: LatestEventValue) -> (String?, String?) {
    switch v {
    case .remote(let ts, _, _, _, let content), .local(let ts, _, _, let content, _):
      let at = LocalTime.format(Date(timeIntervalSince1970: Double(ts) / 1000))
      switch body(content) {
      case .text(let t)?: return (t, at)
      case .encrypted?: return ("(verschlüsselt)", at)
      case nil: return (nil, at)
      }
    default:
      return (nil, nil)
    }
  }

  /// Textnachrichten der Timeline, älteste zuerst (verschlüsselte als "(verschlüsselt)").
  private static func messages(_ items: [TimelineItem], accountId: String, roomId: String) -> [MessengerMessage] {
    items.compactMap { item -> MessengerMessage? in
      guard let e = item.asEvent(), let b = body(e.content) else { return nil }
      var threadRoot: String?
      if case .msgLike(let m) = e.content { threadRoot = m.threadRoot }
      let text: String
      switch b {
      case .text(let t): text = t
      case .encrypted: text = "(verschlüsselt)"
      }
      let sender: String
      if case .ready(let name, _, _, _, _) = e.senderProfile, let name, !name.isEmpty { sender = name } else { sender = e.sender }
      let id: String
      switch e.eventOrTransactionId {
      case .eventId(let eventId): id = eventId
      case .transactionId(let tx): id = tx
      }
      return MessengerMessage(id: id, conversationId: "\(accountId)|\(roomId)", sender: sender, text: text,
                              at: LocalTime.format(Date(timeIntervalSince1970: Double(e.timestamp) / 1000)),
                              mine: e.isOwn, threadRoot: threadRoot)
    }
  }
}

extension MatrixConnector: MessengerStatusReporting {}
extension MatrixConnector: MessengerVerifying {}

#endif
