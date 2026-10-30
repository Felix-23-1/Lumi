// Paket 12: Drehscheibe für alle Chat-Konten. Hält je Konto einen Connector,
// speichert Konten (ohne Geheimnis) in SQLite und Geheimnisse im Schlüsselbund,
// cached die Unterhaltungen und meldet neue eingehende Nachrichten als Insel-Hinweis.
// Blockierende Arbeit steckt in den Connectoren (Blocking.run), nicht hier.
import Foundation

/// Connectoren, deren Status sich nach dem Anmelden noch ändert (Element: gesperrt ↔ verbunden).
/// Der Takt fragt ihn ab; nil = nichts Neues.
protocol MessengerStatusReporting {
  func currentStatus() async -> MessengerStatus?
}

/// Connectoren, die sich über ein anderes eigenes Gerät bestätigen lassen (Element: Emoji-Vergleich).
/// `report` meldet jede Phasenänderung, auch aus fremden Threads; der Hub übernimmt sie auf dem Hauptakteur.
protocol MessengerVerifying: AnyObject {
  func startVerification(report: @escaping @Sendable (MessengerVerification) -> Void) async throws
  func answerVerification(matches: Bool) async throws
  func cancelVerification() async
}

/// Abfrage-Takt der Nachrichten. Basis (60 s), solange die Insel in den letzten 5 Minuten
/// benutzt wurde oder neue Nachrichten kamen; sonst 300 s (Insel zu, nichts Neues).
/// Fehler gelten je Konto (siehe `AccountBackoff`): dessen Abstand verdoppelt sich, höchstens 5 Minuten (auch 429).
enum MessengerPollPolicy {
  static let activeWindow: TimeInterval = 300
  static let idleInterval: TimeInterval = 300
  static let maxBackoff: TimeInterval = 300

  static func delay(base: TimeInterval, now: Date, lastIslandUse: Date?, lastNewMessage: Date?) -> TimeInterval {
    let recent = [lastIslandUse, lastNewMessage].contains { last in
      guard let last else { return false }
      return now.timeIntervalSince(last) < activeWindow
    }
    return recent ? base : max(base, idleInterval)
  }

  /// Wartezeit eines Kontos nach `errorStreak` Fehlern in Folge.
  static func backoff(base: TimeInterval, errorStreak: Int) -> TimeInterval {
    min(maxBackoff, base * pow(2, Double(min(errorStreak, 10))))
  }
}

/// Fehler-Takt je Konto: ein Dienst mit Fehlern wartet, die anderen Konten bleiben im normalen Takt.
struct AccountBackoff {
  private(set) var streaks: [String: Int] = [:]
  private(set) var retryAt: [String: Date] = [:]

  func isWaiting(_ accountId: String, now: Date) -> Bool {
    guard let at = retryAt[accountId] else { return false }
    return now < at
  }

  mutating func failed(_ accountId: String, now: Date, base: TimeInterval) {
    let streak = (streaks[accountId] ?? 0) + 1
    streaks[accountId] = streak
    retryAt[accountId] = now.addingTimeInterval(MessengerPollPolicy.backoff(base: base, errorStreak: streak))
  }

  /// Nach Erfolg oder Trennung: das Konto ist wieder im normalen Takt.
  mutating func clear(_ accountId: String) {
    streaks[accountId] = nil
    retryAt[accountId] = nil
  }
}

@MainActor
final class MessengerHub {
  /// Höchstens so viele Unterhaltungen im Zustand (über alle Konten).
  static let conversationLimit = 50

  private let store: Store
  private let secrets: (String) -> ApiKeyStore
  private let chatDbPath: String
  private let runScript: @Sendable (String) throws -> ProcessOutput
  private let clock: Clock
  /// Microsoft-Anmeldung für Teams (nil = Teams nicht verfügbar).
  private let microsoft: MicrosoftAuth?
  /// Letzte Bedienung der Insel und letzte neue eingehende Nachricht (steuern den Takt).
  private var lastIslandUse: Date?
  private var lastNewMessage: Date?
  /// Fehler-Takt je Konto; Basisabstand des Takts (Grundlage der Wartezeit nach Fehlern).
  private var backoff = AccountBackoff()
  private var baseInterval: TimeInterval = 20
  /// Ereignisse an die Oberfläche (CoreServices setzt das nach dem Start).
  var emit: (AppEvent) -> Void = { _ in }

  /// accountId → Connector (nur für Konten, die gerade angemeldet sind).
  private var connectors: [String: MessengerConnector] = [:]
  /// accountId → Fehlertext (Anmeldung/Abruf fehlgeschlagen).
  private var failures: [String: String] = [:]
  /// accountId → letzter Status des Connectors (nur im Speicher; die Datenbank kennt ihn nicht).
  private var statuses: [String: MessengerStatus] = [:]
  /// accountId → Hinweis zum automatischen Status (z. B. fehlendes Slack-Recht); bleibt bis zur nächsten Meldung.
  private var statusHints: [String: String] = [:]
  /// Nur für Prüfungen: Connector je Dienst ersetzen.
  var connectorFactory: ((MessengerService) -> MessengerConnector?)?
  /// Laufende Geräte-Bestätigung (höchstens eine; für die Oberfläche).
  private(set) var verification: MessengerVerification?
  /// Konten, deren erste Abfrage schon lief (davor kommen keine Hinweise für alte Nachrichten).
  private var baselined: Set<String> = []
  private var cache: [MessengerConversation] = []
  private var loop: Task<Void, Never>?
  /// Laufende Abfrage; weitere poll()-Aufrufe warten darauf statt parallel zu laufen (sonst doppelte Hinweise).
  private var pollTask: Task<Void, Never>?
  private var pollAgain = false

  init(store: Store, secrets: @escaping (String) -> ApiKeyStore, chatDbPath: String,
       runScript: @escaping @Sendable (String) throws -> ProcessOutput, clock: Clock = SystemClock(),
       microsoft: MicrosoftAuth? = nil) {
    self.store = store
    self.secrets = secrets
    self.chatDbPath = chatDbPath
    self.runScript = runScript
    self.clock = clock
    self.microsoft = microsoft
  }

  // MARK: - Zustand

  func accountList() -> [MessengerAccount] {
    ((try? store.messengerAccounts.list()) ?? []).map { account in
      var a = account
      if let f = failures[account.id] { a.status = .error(f) }
      else if let h = statusHints[account.id] { a.status = .error(h) }
      else if let s = statuses[account.id] { a.status = s }
      return a
    }
  }

  func conversationList() -> [MessengerConversation] { cache }

  /// Angemeldete Konten, die den automatischen Status setzen können.
  func statusTargets() -> [(accountId: String, setting: StatusSetting)] {
    accountList().compactMap { account in
      guard let setting = connectors[account.id] as? StatusSetting else { return nil }
      return (account.id, setting)
    }
  }

  func setStatusHint(_ accountId: String, _ hint: String?) {
    statusHints[accountId] = hint
  }

  // MARK: - Konten

  func connect(_ login: MessengerLogin) async -> ToolResult<MessengerAccount> {
    guard let connector = makeConnector(login.service) else {
      return .failure(code: "UNAVAILABLE", error: "\(login.service.title) ist noch nicht verfügbar.")
    }
    // shortcut: je Dienst nur ein Konto; iMessage liest eine feste Datenbank, zwei Konten gäben Dubletten.
    if (try? store.messengerAccounts.list())?.contains(where: { $0.service == login.service }) == true {
      return .failure(code: "EXISTS", error: "\(login.service.title) ist schon verbunden.")
    }
    let id = StoreIds.make()
    let account: MessengerAccount, secret: String
    do {
      (account, secret) = try await connector.login(login, accountId: id)
    } catch {
      await connector.logout()  // halbe Anmeldung (z. B. Sync startet nicht) nicht liegen lassen
      return .failure(code: "CONNECT", error: Self.errorText(error))
    }
    do {
      if !secret.isEmpty { try secrets(Self.secretId(id)).set(secret) }
      try store.messengerAccounts.add(account)
      _ = try store.settings.update(SettingsPatch(messengerEnabled: true))
    } catch {
      // Angemeldet, aber nicht gespeichert: Sitzung wieder abmelden, sonst bleibt ein verwaistes Gerät.
      await connector.logout()
      try? secrets(Self.secretId(id)).delete()
      try? store.messengerAccounts.delete(id)
      return .failure(code: "CONNECT", error: Self.errorText(error))
    }
    connectors[id] = connector
    statuses[id] = account.status
    await poll()
    emit(.stateChanged)
    return .ok(account)
  }

  func unlock(_ accountId: String, recoveryKey: String) async -> ToolResult<Empty> {
    guard let connector = connectors[accountId] else { return .failure(code: "NOT_FOUND", error: "Konto nicht gefunden.") }
    do {
      try await connector.unlock(recoveryKey: recoveryKey)
      statuses[accountId] = .connected
      emit(.stateChanged)
      return .ok(Empty())
    } catch {
      return .failure(code: "UNLOCK", error: Self.errorText(error))
    }
  }

  func disconnect(_ accountId: String) async {
    if let connector = connectors.removeValue(forKey: accountId) { await connector.logout() }
    failures[accountId] = nil
    statuses[accountId] = nil
    backoff.clear(accountId)
    baselined.remove(accountId)
    if verification?.accountId == accountId { verification = nil }
    cache.removeAll { $0.accountId == accountId }
    try? store.messengerAccounts.delete(accountId)
    try? secrets(Self.secretId(accountId)).delete()
    if ((try? store.messengerAccounts.list()) ?? []).isEmpty {
      _ = try? store.settings.update(SettingsPatch(messengerEnabled: false))
    }
    emit(.stateChanged)
  }

  /// Verbindungen nach App-Start aus der Datenbank wiederherstellen.
  func restoreAll() async {
    for account in (try? store.messengerAccounts.list()) ?? [] {
      guard let connector = makeConnector(account.service) else {
        failures[account.id] = "\(account.service.title) ist noch nicht verfügbar."
        continue
      }
      connectors[account.id] = connector
      let secret = (try? secrets(Self.secretId(account.id)).get()) ?? ""
      do {
        statuses[account.id] = try await connector.restore(account, secret: secret).status
        failures[account.id] = nil
      } catch {
        failures[account.id] = Self.errorText(error)
      }
    }
  }

  // MARK: - Geräte-Bestätigung

  func startVerification(_ accountId: String) async -> ToolResult<Empty> {
    guard let verifier = verifier(accountId) else {
      return .failure(code: "UNAVAILABLE", error: "Dieses Konto lässt sich nicht per Gerät bestätigen.")
    }
    verification = MessengerVerification(accountId: accountId, phase: .waitingForOther)
    emit(.stateChanged)
    do {
      try await verifier.startVerification { [weak self] update in
        Task { @MainActor in self?.receiveVerification(update) }
      }
      return .ok(Empty())
    } catch {
      verification = MessengerVerification(accountId: accountId, phase: .failed, message: Self.errorText(error))
      emit(.stateChanged)
      return .failure(code: "VERIFY", error: Self.errorText(error))
    }
  }

  /// Ergebnis des Emoji-Vergleichs. Bei Zustimmung wartet der Hub, bis die Schlüssel da sind (höchstens 30 s).
  func answerVerification(_ accountId: String, matches: Bool) async -> ToolResult<Empty> {
    guard let verifier = verifier(accountId) else {
      return .failure(code: "UNAVAILABLE", error: "Dieses Konto lässt sich nicht per Gerät bestätigen.")
    }
    guard verification?.accountId == accountId, verification?.phase == .showEmojis else {
      return .failure(code: "NOT_FOUND", error: "Gerade gibt es keine Symbole zu vergleichen.")
    }
    verification = MessengerVerification(accountId: accountId, phase: .confirming)
    emit(.stateChanged)
    do {
      try await verifier.answerVerification(matches: matches)
    } catch {
      finishVerification(accountId, MessengerVerification(accountId: accountId, phase: .failed, message: Self.errorText(error)))
      return .ok(Empty())
    }
    if !matches {
      finishVerification(accountId, MessengerVerification(accountId: accountId, phase: .cancelled,
                                                          message: "Die Symbole stimmten nicht überein. Die Bestätigung wurde abgebrochen."))
      return .ok(Empty())
    }
    let verified = await awaitVerifiedStatus(accountId)
    finishVerification(accountId, verified
      ? MessengerVerification(accountId: accountId, phase: .done)
      : MessengerVerification(accountId: accountId, phase: .failed,
                              message: "Die Bestätigung ist durch, aber die Schlüssel sind noch nicht da. Gleich erneut versuchen oder den Sicherheitsschlüssel eingeben."))
    return .ok(Empty())
  }

  /// Schreibt das Ergebnis nur, solange genau diese Bestätigung noch wartet (der Nutzer kann während des Wartens abbrechen).
  private func finishVerification(_ accountId: String, _ state: MessengerVerification) {
    guard verification?.accountId == accountId, verification?.phase == .confirming else { return }
    verification = state
    emit(.stateChanged)
  }

  func cancelVerification(_ accountId: String) async {
    if let verifier = verifier(accountId) { await verifier.cancelVerification() }
    if verification?.accountId == accountId {
      verification = nil
      emit(.stateChanged)
    }
  }

  private func receiveVerification(_ update: MessengerVerification) {
    // Abschluss meldet der Hub selbst, sobald die Schlüssel da sind (answerVerification).
    guard update.phase != .done, verification?.accountId == update.accountId else { return }
    verification = update
    emit(.stateChanged)
  }

  /// Fragt den Status bis zu 30 s lang (einmal je Sekunde), bis das Konto verbunden ist.
  private func awaitVerifiedStatus(_ accountId: String) async -> Bool {
    for _ in 0..<30 {
      guard let connector = connectors[accountId] else { return false }
      if let s = await (connector as? MessengerStatusReporting)?.currentStatus() {
        statuses[accountId] = s
        emit(.stateChanged)
        if s == .connected { return true }
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
  }

  // MARK: - Unterhaltungen

  func messages(_ conversationId: String, limit: Int) async -> ToolResult<[MessengerMessage]> {
    guard let target = route(conversationId) else { return .failure(code: "NOT_FOUND", error: "Unterhaltung nicht gefunden.") }
    do {
      return .ok(try await target.connector.messages(roomId: target.roomId, limit: limit))
    } catch {
      return .failure(code: "MESSAGES", error: Self.errorText(error))
    }
  }

  func send(_ conversationId: String, text: String, replyTo: String? = nil) async -> ToolResult<Empty> {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return .failure(code: "EMPTY", error: "Die Nachricht ist leer.") }
    guard let target = route(conversationId) else { return .failure(code: "NOT_FOUND", error: "Unterhaltung nicht gefunden.") }
    do {
      try await target.connector.send(roomId: target.roomId, text: clean, replyTo: replyTo)
    } catch {
      return .failure(code: "SEND", error: Self.errorText(error))
    }
    await poll()
    return .ok(Empty())
  }

  func markRead(_ conversationId: String) async {
    guard let target = route(conversationId) else { return }
    try? await target.connector.markRead(roomId: target.roomId)
    // Kein Takt (Slack bremst bei vielen Abrufen): der Zähler wird hier lokal auf 0 gesetzt.
    guard let i = cache.firstIndex(where: { $0.id == conversationId }) else { return }
    cache[i].unread = 0
    emit(.stateChanged)
  }

  // MARK: - Takt

  /// Startet den Hintergrund-Takt (einmal wiederherstellen, dann nach `interval` als Basis abfragen,
  /// siehe `MessengerPollPolicy`).
  func start(interval: TimeInterval) {
    loop?.cancel()
    baseInterval = interval
    loop = Task { @MainActor [weak self] in
      await self?.restoreAll()
      while !Task.isCancelled {
        guard let self else { return }
        await self.poll()
        try? await Task.sleep(nanoseconds: UInt64(self.pollDelay(base: interval) * 1_000_000_000))
      }
    }
  }

  func stop() { loop?.cancel() }

  /// Die Insel wurde bedient: der Takt bleibt eine Weile schnell.
  func noteIslandUse() { lastIslandUse = clock.now() }

  /// Wartezeit bis zur nächsten Abfrage bei Basis `base` (auch für Prüfungen).
  func pollDelay(base: TimeInterval) -> TimeInterval {
    MessengerPollPolicy.delay(base: base, now: clock.now(), lastIslandUse: lastIslandUse,
                              lastNewMessage: lastNewMessage)
  }

  /// Fragt alle angemeldeten Konten ab. Neue eingehende Nachrichten (Zunahme der
  /// ungelesenen Zahl seit dem letzten Abruf) geben je einen Insel-Hinweis;
  /// das erste Abrufen eines Kontos ist nur Grundlage und meldet nichts.
  func poll() async {
    if let running = pollTask {
      pollAgain = true  // die laufende Abfrage holt danach noch einmal frisch
      await running.value
      return
    }
    let task = Task { @MainActor [weak self] in
      while let self {
        self.pollAgain = false
        await self.pollOnce()
        if !self.pollAgain { self.pollTask = nil; return }
      }
    }
    pollTask = task
    await task.value
  }

  private func pollOnce() async {
    let before = cache
    let beforeFailures = failures
    let beforeStatuses = statuses
    let beforeVerification = verification
    let oldUnread = Dictionary(before.map { ($0.id, $0.unread) }, uniquingKeysWith: { a, _ in a })
    var fresh: [MessengerConversation] = []
    let now = clock.now()
    for account in (try? store.messengerAccounts.list()) ?? [] {
      guard let connector = connectors[account.id] else { continue }
      // Konto wartet nach Fehlern: alte Unterhaltungen behalten, die anderen Konten laufen weiter.
      if backoff.isWaiting(account.id, now: now) {
        fresh += before.filter { $0.accountId == account.id }
        continue
      }
      do {
        let list = try await connector.conversations()
        failures[account.id] = nil
        backoff.clear(account.id)
        if let s = await (connector as? MessengerStatusReporting)?.currentStatus() { statuses[account.id] = s }
        // Abgeschlossene Bestätigung ist nach dem nächsten Takt erledigt.
        if verification?.accountId == account.id, verification?.phase == .done { verification = nil }
        if baselined.contains(account.id) {
          for c in list {
            let added = c.unread - (oldUnread[c.id] ?? 0)
            if added > 0 {
              lastNewMessage = clock.now()
              await flashNewMessages(c, count: added, connector: connector)
            }
          }
        }
        baselined.insert(account.id)
        fresh += list
      } catch {
        failures[account.id] = Self.errorText(error)  // auch 429 (Ratenlimit) landet hier
        backoff.failed(account.id, now: now, base: baseInterval)
      }
    }
    fresh.removeAll { connectors[$0.accountId] == nil }  // während der Abfrage getrennt
    cache = Array(fresh.sorted { ($0.lastAt ?? "") > ($1.lastAt ?? "") }.prefix(Self.conversationLimit))
    if cache != before || failures != beforeFailures || statuses != beforeStatuses || verification != beforeVerification {
      emit(.stateChanged)
    }
  }

  /// Ein Hinweis je neuer eingehender Nachricht (die neuesten `count` Nachrichten von anderen).
  private func flashNewMessages(_ c: MessengerConversation, count: Int, connector: MessengerConnector) async {
    guard let room = Self.split(c.id)?.roomId else { return }
    let recent = (try? await connector.messages(roomId: room, limit: 20)) ?? []
    for m in recent.filter({ !$0.mine }).suffix(count) {
      emit(.flash(TabyNotification(title: c.title, body: String(m.text.prefix(80)))))
    }
  }

  // MARK: - Hilfen

  private func verifier(_ accountId: String) -> MessengerVerifying? {
    connectors[accountId] as? MessengerVerifying
  }

  private func route(_ conversationId: String) -> (connector: MessengerConnector, roomId: String)? {
    guard let parts = Self.split(conversationId), let connector = connectors[parts.accountId] else { return nil }
    return (connector, parts.roomId)
  }

  /// "<accountId>|<roomId>" → beide Teile (Raum-Kennung darf selbst "|" enthalten).
  static func split(_ conversationId: String) -> (accountId: String, roomId: String)? {
    let parts = conversationId.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]))
  }

  private func makeConnector(_ service: MessengerService) -> MessengerConnector? {
    if let connectorFactory { return connectorFactory(service) }
    switch service {
    case .imessage:
      let reads = store.messengerReads
      let markers = MessengerReadMarkers(get: { try? reads.get($0) }, set: { try? reads.set($0, lastRowId: $1) })
      return IMessageConnector(chatDbPath: chatDbPath, readMarkers: markers, runScript: runScript)
    case .matrix:
      #if TABY_MATRIX
      return MatrixConnector()
      #else
      return nil
      #endif
    case .slack:
      let reads = store.messengerReads
      let markers = MessengerReadMarkers(get: { try? reads.get($0) }, set: { try? reads.set($0, lastRowId: $1) })
      return SlackConnector(readMarkers: markers)
    case .teams:
      return microsoft.map { TeamsConnector(auth: $0, clock: clock) }
    }
  }

  private static func secretId(_ accountId: String) -> String { "messenger-\(accountId)" }

  static func errorText(_ error: Error) -> String {
    if let f = error as? MicrosoftFailure { return f.message }
    return (error as? MessengerFailure)?.message ?? "Der Nachrichtendienst meldet einen Fehler: \(error)"
  }
}
