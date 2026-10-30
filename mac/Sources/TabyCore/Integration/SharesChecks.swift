// Prüfungen für Netzlaufwerke und die Geheimnis-Suche. Keine echten Einhängungen, kein Netz,
// kein echter Schlüsselbund und keine echte Zwischenablage: alles läuft über Attrappen.
import Foundation

/// Attrappe für das System der Netzlaufwerke: Mount-Tabelle, Ergebnis und Aufrufe werden gemerkt.
final class FakeShares: @unchecked Sendable {
  private let lock = NSLock()
  private var _volumes: [MountedVolume] = []
  private var _mountStatus: Int32?
  private var _mounts: [(url: String, user: String?, password: String?)] = []
  private var _unmounts: [String] = []

  var volumes: [MountedVolume] {
    get { lock.lock(); defer { lock.unlock() }; return _volumes }
    set { lock.lock(); _volumes = newValue; lock.unlock() }
  }
  /// Wenn gesetzt, schlägt das Einhängen mit diesem Status fehl.
  var mountStatus: Int32? {
    get { lock.lock(); defer { lock.unlock() }; return _mountStatus }
    set { lock.lock(); _mountStatus = newValue; lock.unlock() }
  }
  var mounts: [(url: String, user: String?, password: String?)] { lock.lock(); defer { lock.unlock() }; return _mounts }
  var unmounts: [String] { lock.lock(); defer { lock.unlock() }; return _unmounts }

  var system: ShareSystem {
    ShareSystem(
      mountedVolumes: { [self] in self.volumes },
      mount: { [self] url, user, password in
        self.lock.lock()
        self._mounts.append((url, user, password))
        let status = self._mountStatus
        if status == nil {
          self._volumes.append(MountedVolume(path: "/Volumes/Dokumente", fsType: "smbfs",
                                             source: "//\(user ?? "gast")@nas.local/Dokumente"))
        }
        self.lock.unlock()
        if let status { throw ShareMountError(status: status) }
        return "/Volumes/Dokumente"
      },
      unmount: { [self] path in
        self.lock.lock()
        self._unmounts.append(path)
        self._volumes.removeAll { $0.path == path }
        self.lock.unlock()
      })
  }
}

/// Sammelt Flash-Meldungen aus `subscribe`.
@MainActor
final class FlashBox {
  var items: [TabyNotification] = []
}

/// Uhr, die bei jedem Lesen eine Sekunde weiterläuft (für das Zeitlimit des Scans).
final class TickingClock: Clock {
  private let lock = NSLock()
  private var current: Date
  init(_ start: Date) { current = start }
  func now() -> Date { lock.lock(); defer { lock.unlock() }; current = current.addingTimeInterval(1); return current }
}

/// Attrappe für die Zwischenablage: merkt sich Inhalt und changeCount.
final class FakeBoard: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: String?
  private var _count = 0

  var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
  var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
  private let hold = SecretClipboardHold()

  var clipboard: SecretClipboard {
    SecretClipboard(
      copy: { [self] v in self.lock.lock(); self._value = v; self._count += 1; let c = self._count; self.lock.unlock(); return c },
      changeCount: { [self] in self.count },
      clear: { [self] in self.lock.lock(); self._value = nil; self._count += 1; self.lock.unlock() },
      hold: hold)
  }
}

@MainActor
enum SharesChecks {
  static let dokumente = NetworkShare(id: "nas", name: "Dokumente", url: "smb://nas.local/Dokumente", user: "felix",
                                      autoMount: false, searchFolders: ["Unterlagen"])

  /// Dienst mit Attrappen; Modell-Antworten über `llm`, Schlüssel im Arbeitsspeicher je Freigabe.
  static func rig(shares: FakeShares = FakeShares(), llm: ScriptedLlmClient? = nil, board: FakeBoard = FakeBoard(),
                  appleAvailable: Bool = true) throws -> (CoreServices, FakeShares, ScriptedLlmClient, FakeBoard) {
    let model = llm ?? ScriptedLlmClient([])
    var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-18T10:00"),
                                    keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
    opts.shares = shares.system
    let stores = SecretStores()
    opts.shareSecrets = { stores.store(for: $0) }
    opts.secretModel = { model }
    opts.secretClipboard = board.clipboard
    opts.appleIntelligence = appleAvailable
    return (try CoreServices(options: opts), shares, model, board)
  }

  /// Ein Speicher je Freigabe-ID, so wie der Schlüsselbund je Konto.
  final class SecretStores: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: InMemoryApiKeyStore] = [:]
    func store(for id: String) -> ApiKeyStore {
      lock.lock(); defer { lock.unlock() }
      if let s = stores[id] { return s }
      let s = InMemoryApiKeyStore()
      stores[id] = s
      return s
    }
  }

  /// Ordner mit Dokumenten, eine Datei davon ist ein Zugang; Gegenstücke liegen außerhalb des Suchordners.
  static func share(with files: [String: String]) throws -> String {
    try AuditVaultChecks.tempVault(files)
  }

  static func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  static var cases: [CheckCase] {
    [
      CheckCase("Netzlaufwerk: Adresse smb:// mit Freigabe gültig, andere Adressen abgelehnt") {
        try expect(ShareURL.problem("smb://nas.local/Dokumente") == nil, "gültig")
        try expectEqual(ShareURL.parts("smb://nas.local/Dokumente")?.share, "Dokumente")
        try expectEqual(ShareURL.parts("smb://192.168.1.20/Foto%20Album/Urlaub")?.share, "Foto Album")
        try expectEqual(ShareURL.parts("smb://192.168.1.20/Foto%20Album/Urlaub")?.subPath, "Urlaub")
        try expectEqual(ShareURL.mountAddress(ShareURL.parts("smb://NAS.local/Foto Album")!), "smb://nas.local/Foto%20Album")
        try expect(ShareURL.problem("http://nas.local/Dokumente") != nil, "http abgelehnt")
        try expect(ShareURL.problem("smb://user:pw@nas.local/Dokumente") != nil, "Zugang in der Adresse abgelehnt")
        try expect(ShareURL.problem("smb://felix@nas.local/Dokumente") != nil, "Benutzer in der Adresse abgelehnt")
        try expect(ShareURL.problem("smb://nas.local/../etc") != nil, ".. abgelehnt")
        try expect(ShareURL.problem("smb://nas.local/%2e%2e/etc") != nil, "kodiertes .. abgelehnt")
        try expect(ShareURL.problem("smb://nas.local") != nil, "ohne Freigabe abgelehnt")
        try expect(ShareURL.problem("smb://nas.local:445/Dokumente") != nil, "Port abgelehnt")
        try expect(ShareURL.problem("smb://nas.local/Doku?x=1") != nil, "Abfrage abgelehnt")
        try expect(ShareURL.problem("   ") != nil, "leer abgelehnt")
        try expect(ShareURL.problem("smb://nas local/Dokumente") != nil, "Leerzeichen im Servernamen abgelehnt")
      },
      CheckCase("Netzlaufwerk: Fehlermeldungen in Alltagssprache") {
        try expectEqual(ShareMountMessage.text(status: EAUTH), "Anmeldung abgelehnt – Benutzer oder Passwort prüfen.")
        try expectEqual(ShareMountMessage.text(status: ENOENT), "Freigabe nicht gefunden.")
        try expectEqual(ShareMountMessage.text(status: EHOSTUNREACH), "Server nicht erreichbar.")
        try expectEqual(ShareMountMessage.text(status: ShareMountError.timeoutStatus),
                        "Server nicht erreichbar – keine Antwort innerhalb von 30 Sekunden.")
        try expect(ShareMountMessage.text(status: 999).hasPrefix("Verbindung fehlgeschlagen"), "unbekannter Fehler")
      },
      CheckCase("Netzlaufwerk: Zuordnung zur Mount-Tabelle (Host, Freigabe, smbfs)") {
        let volumes = [
          MountedVolume(path: "/Volumes/Dokumente", fsType: "smbfs", source: "//felix@nas.local/Dokumente"),
          MountedVolume(path: "/Volumes/Fremd", fsType: "smbfs", source: "//felix@other.local/Dokumente"),
          MountedVolume(path: "/Volumes/Lokal", fsType: "apfs", source: "/dev/disk3s5"),
        ]
        try expectEqual(ShareMatch.volume(for: dokumente, in: volumes)?.path, "/Volumes/Dokumente")
        let other = NetworkShare(id: "x", name: "X", url: "smb://nas.local/Musik")
        try expect(ShareMatch.volume(for: other, in: volumes) == nil, "andere Freigabe nicht zugeordnet")
        let apfs = NetworkShare(id: "y", name: "Y", url: "smb://nas.local/Lokal")
        try expect(ShareMatch.volume(for: apfs, in: volumes) == nil, "nur smbfs zählt")
      },
      CheckCase("Netzlaufwerk: einhängen mit Passwort aus dem Schlüsselbund, Zustand und Protokoll ohne Geheimnis") {
        let (svc, shares, _, _) = try rig()
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let saved = await svc.setSharePassword("nas", password: "geheim-42")
        try expectEqual(saved.isOk, true, "Passwort gespeichert")
        let mounted = await svc.mountShare("nas")
        try expect(mounted.isOk, "eingehängt")
        try expectEqual(shares.mounts.first?.url, "smb://nas.local/Dokumente", "Adresse ohne Zugang")
        try expectEqual(shares.mounts.first?.user, "felix")
        try expectEqual(shares.mounts.first?.password, "geheim-42", "Passwort aus dem Schlüsselbund")
        let st = await svc.state()
        try expectEqual(st.shareStates["nas"]?.mounted, true)
        try expectEqual(st.shareStates["nas"]?.mountPath, "/Volumes/Dokumente")
        let audit = await svc.listAudit(limit: 50)
        try expect(audit.contains { $0.tool == "mount_share" && $0.ok }, "Protokoll: Einhängen")
        try expect(!(try json(audit)).contains("geheim-42") && !(try json(audit)).contains("smb://"), "Protokoll ohne Passwort und URL")
      },
      CheckCase("Netzlaufwerk: Fehler landet als deutscher Satz im Zustand, Passwort fehlt nicht im Protokoll") {
        let shares = FakeShares()
        shares.mountStatus = EAUTH
        let (svc, _, _, _) = try rig(shares: shares)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let result = await svc.mountShare("nas")
        try expectEqual(result.errorMessage, "Anmeldung abgelehnt – Benutzer oder Passwort prüfen.")
        let st = await svc.state()
        try expectEqual(st.shareStates["nas"]?.mounted, false)
        try expectEqual(st.shareStates["nas"]?.error, "Anmeldung abgelehnt – Benutzer oder Passwort prüfen.")
      },
      CheckCase("Netzlaufwerk: Zeitüberschreitung beim Einhängen ergibt den Zeitfehler") {
        let slow = ShareSystem(mountedVolumes: { [] }, mount: { _, _, _ in Thread.sleep(forTimeInterval: 1.5); return "/Volumes/X" },
                               unmount: { _ in })
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = await CoreServices.mountWithTimeout(system: slow, url: "smb://nas.local/X", user: nil, password: nil, seconds: 0)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        try expectEqual(outcome, .failure(ShareMountError(status: ShareMountError.timeoutStatus)))
        try expect(elapsedMs < 1000, "kehrt vor dem blockierten Aufruf zurück (\(Int(elapsedMs)) ms)")
        let quick = ShareSystem(mountedVolumes: { [] }, mount: { _, _, _ in "/Volumes/X" }, unmount: { _ in })
        let ok = await CoreServices.mountWithTimeout(system: quick, url: "smb://nas.local/X", user: nil, password: nil)
        try expectEqual(ok, .success("/Volumes/X"))
      },
      CheckCase("Netzlaufwerk: trennen hängt die Freigabe aus und meldet es") {
        let shares = FakeShares()
        shares.volumes = [MountedVolume(path: "/Volumes/Dokumente", fsType: "smbfs", source: "//felix@nas.local/Dokumente")]
        let (svc, _, _, _) = try rig(shares: shares)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let before = await svc.state()
        try expectEqual(before.shareStates["nas"]?.mounted, true, "vor dem Trennen eingehängt")
        let unmounted = await svc.unmountShare("nas")
        try expect(unmounted.isOk, "getrennt")
        try expectEqual(shares.unmounts, ["/Volumes/Dokumente"])
        let after = await svc.state()
        try expectEqual(after.shareStates["nas"]?.mounted, false)
      },
      CheckCase("Netzlaufwerk: Passwort nie im Zustand oder in den Einstellungen; leer löscht") {
        let (svc, _, _, _) = try rig()
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let set = await svc.setSharePassword("nas", password: "geheim-42")
        try expect(set.isOk, "gesetzt")
        let st = await svc.state()
        let settingsText = String(reflecting: st.settings)
        try expect(!String(reflecting: st).contains("geheim-42") && !settingsText.contains("geheim-42"), "weder Zustand noch Einstellungen")
        let unknown = await svc.setSharePassword("unbekannt", password: "x")
        try expect(unknown.errorMessage != nil, "unbekannte Freigabe")
        let cleared = await svc.setSharePassword("nas", password: "")
        try expect(cleared.isOk, "leer löscht")
      },
      CheckCase("Netzlaufwerk: Start-Einhängen versucht nach Anmeldefehler nicht erneut, manuelles Verbinden zählt") {
        let shares = FakeShares()
        shares.mountStatus = EAUTH
        let (svc, _, _, _) = try rig(shares: shares)
        var auto = dokumente
        auto.autoMount = true
        _ = await svc.updateSettings(SettingsPatch(networkShares: [auto]), apiKey: nil)
        await svc.autoMountShares()
        try expectEqual(shares.mounts.count, 1, "erster Versuch beim Start")
        await svc.autoMountShares()
        try expectEqual(shares.mounts.count, 1, "kein erneuter Versuch nach Anmeldefehler")
        shares.mountStatus = nil
        let manual = await svc.mountShare("nas")
        try expect(manual.isOk, "manuell verbunden")
        try expectEqual(shares.mounts.count, 2, "manueller Versuch")
      },
      CheckCase("Netzlaufwerk: Freigabe ohne Passwort wird als Gast eingehängt") {
        let shares = FakeShares()
        let (svc, _, _, _) = try rig(shares: shares)
        var guest = dokumente
        guest.user = ""
        _ = await svc.updateSettings(SettingsPatch(networkShares: [guest]), apiKey: nil)
        let mounted = await svc.mountShare("nas")
        try expect(mounted.isOk, "eingehängt")
        try expect(shares.mounts.first?.user == nil && shares.mounts.first?.password == nil, "ohne Benutzer und Passwort")
      },
      CheckCase("Geheimnis-Suche: Stoppwörter fallen weg, Schlüsselwörter bleiben") {
        try expectEqual(CoreServices.secretKeywords("Such mir das Passwort von Router"), ["router"])
        try expectEqual(CoreServices.secretKeywords("Passwort für NAS Gast"), ["nas", "gast"])
        try expectEqual(CoreServices.secretKeywords("passwort"), [], "nur Stoppwort")
      },
      CheckCase("Geheimnis-Suche: nur durchsuchbare Ordner, Textdateien, Symlinks und Ausbrüche abgewiesen") {
        let root = try share(with: [
          "Unterlagen/router.md": "Name: Router\nWLAN: Gast\nRouter-Passwort: geheim-42\nEnde",
          "Unterlagen/app.exe": "router geheim-99",
          "Privat/router.md": "Router-Passwort: privat-1",
          "Unterlagen/gross.txt": String(repeating: "router-zeile\n", count: 60_000),
        ])
        let outside = try AuditVaultChecks.tempVault(["secret.md": "router passwort: aussen-1"])
        try FileManager.default.createSymbolicLink(atPath: root + "/Unterlagen/link.md", withDestinationPath: outside + "/secret.md")
        try FileManager.default.createSymbolicLink(atPath: root + "/Links", withDestinationPath: outside)
        let material = CoreServices.scanSecrets([SecretRoot(shareName: "Dokumente", mountPath: root, folder: "Unterlagen")],
                                                keywords: ["router"], clock: ControllableClock("2026-10-18T10:00"))
        let files = material.blocks.map(\.file)
        try expectEqual(files, ["router.md"], "nur die passende Textdatei im Suchordner")
        try expect(!material.text.contains("privat-1") && !material.text.contains("aussen-1") && !material.text.contains("geheim-99"),
                   "keine fremden Dateien, Symlinks oder Programme")
        let escaped = CoreServices.scanSecrets([SecretRoot(shareName: "X", mountPath: root, folder: "Links")], keywords: ["router"], clock: ControllableClock("2026-10-18T10:00"))
        try expect(escaped.blocks.isEmpty, "Ordner-Symlink nach außen abgelehnt")
        let dots = CoreServices.scanSecrets([SecretRoot(shareName: "X", mountPath: root, folder: "../")], keywords: ["router"], clock: ControllableClock("2026-10-18T10:00"))
        try expect(dots.blocks.isEmpty, "relativer Ausbruch abgelehnt")
        try expect(CoreServices.secretMaxFiles == 300 && CoreServices.secretMaxFileBytes == 512 * 1024 && CoreServices.secretPromptChars == 2500,
                   "Grenzen wie vorgegeben")
      },
      CheckCase("Geheimnis-Suche: ohne Apple Intelligence nichts gelesen, kein Modell aufgerufen") {
        let llm = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "{\"value\":\"x\",\"line\":1}"))])
        let (svc, _, _, board) = try rig(llm: llm, appleAvailable: false)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let out = await svc.lookupSecret(query: "Router Passwort")
        try expectEqual(out.errorMessage, "Das mache ich nur lokal – Apple Intelligence ist auf diesem Mac nicht verfügbar.")
        try expect(llm.requests.isEmpty, "kein Modellaufruf")
        try expect(board.value == nil, "nichts in die Zwischenablage")
        try expect(!svc.secretToolDefs.contains { $0.name == "find_secret" }, "Werkzeug ohne lokales Modell nicht angeboten")
      },
      CheckCase("Geheimnis-Suche: Fund mit lokalem Modell, Wert nur in der Zwischenablage") {
        let root = try share(with: ["Unterlagen/router.md": "Name: Router\nWLAN: Gast\nRouter-Passwort: geheim-42\nEnde"])
        let shares = FakeShares()
        shares.volumes = [MountedVolume(path: root, fsType: "smbfs", source: "//felix@nas.local/Dokumente")]
        let llm = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "Hier: {\"value\":\"geheim-42\",\"line\":3}"))])
        let (svc, _, _, board) = try rig(shares: shares, llm: llm)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        try expect(!svc.secretToolDefs.isEmpty, "Werkzeug angeboten")
        let out = await svc.lookupSecret(query: "Router Passwort")
        try expectEqual(out.value, SecretLookup(source: "router.md", line: 3, copied: true))
        try expectEqual(llm.requests.count, 1, "ein Modellaufruf")
        try expectEqual(board.value, "geheim-42", "Wert in der Zwischenablage")
        try expect(llm.requests.first?.messages.last?.content?.contains(ForeignContent.open) == true, "fremder Text verpackt")
        let st = await svc.state()
        try expect(!String(reflecting: st).contains("geheim-42"), "nicht im Zustand")
        let audit = await svc.listAudit(limit: 50)
        try expect(audit.contains { $0.tool == "lookup_secret" && $0.summary.contains("router.md") }, "Protokoll mit Datei")
        try expect(!(try json(audit)).contains("geheim-42"), "nicht im Protokoll")
        let settingsNow = await svc.state().settings
        try expect(!String(reflecting: settingsNow).contains("geheim-42"), "nicht in den Einstellungen")
      },
      CheckCase("Geheimnis-Suche: erfundener Wert oder unlesbare Antwort ergeben „Nichts Passendes gefunden.“") {
        let root = try share(with: ["Unterlagen/router.md": "Router-Passwort: geheim-42"])
        let shares = FakeShares()
        shares.volumes = [MountedVolume(path: root, fsType: "smbfs", source: "//felix@nas.local/Dokumente")]
        let invented = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "{\"value\":\"erfunden\",\"line\":1}"))])
        let (svc, _, _, board) = try rig(shares: shares, llm: invented)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let miss1 = await svc.lookupSecret(query: "router")
        try expectEqual(miss1.errorMessage, "Nichts Passendes gefunden.")
        try expect(board.value == nil, "nichts kopiert")
        let garbled = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "kein JSON hier"))])
        let (svc2, _, _, _) = try rig(shares: shares, llm: garbled)
        _ = await svc2.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        let miss2 = await svc2.lookupSecret(query: "router")
        try expectEqual(miss2.errorMessage, "Nichts Passendes gefunden.")
        let none = try share(with: ["Unterlagen/anderes.md": "Nichts hier"])
        shares.volumes = [MountedVolume(path: none, fsType: "smbfs", source: "//felix@nas.local/Dokumente")]
        let miss3 = await svc.lookupSecret(query: "router")
        try expectEqual(miss3.errorMessage, "Nichts Passendes gefunden.", "kein Treffer, kein Modell")
        try expectEqual(invented.requests.count, 1, "ohne Treffer kein Modellaufruf")
      },
      CheckCase("Geheimnis-Suche: Zwischenablage wird nur gelöscht, wenn nichts Neues kopiert wurde") {
        try expect(SecretClipboardRule.shouldClear(recorded: 5, current: 5), "unverändert: löschen")
        try expect(!SecretClipboardRule.shouldClear(recorded: 5, current: 6), "anderes kopiert: nicht löschen")
        try expectEqual(CoreServices.secretSearchSummary(query: "router", shares: [dokumente]),
                        "Ich suche lokal nach „router“ in Dokumente und kopiere den Fund in die Zwischenablage")
      },
      CheckCase("Geheimnis-Suche: find_secret wird nur mit Bestätigung ausgeführt, Gespräch zeigt nur die Fundstelle") {
        let root = try share(with: ["Unterlagen/router.md": "Router-Passwort: geheim-42"])
        let shares = FakeShares()
        shares.volumes = [MountedVolume(path: root, fsType: "smbfs", source: "//felix@nas.local/Dokumente")]
        let llm = ScriptedLlmClient([.message(ChatMessage(role: .assistant, content: "{\"value\":\"geheim-42\",\"line\":1}"))])
        let (svc, _, _, board) = try rig(shares: shares, llm: llm)
        _ = await svc.updateSettings(SettingsPatch(networkShares: [dokumente]), apiKey: nil)
        try expect(ToolRegistry.confirmationRequired.contains("find_secret"), "Bestätigung nötig")
        let asked = await svc.requestConfirmation(name: "find_secret", argumentsJSON: "{\"query\":\"router\"}")
        try expectEqual(asked["code"]?.stringValue, "NEEDS_CONFIRMATION")
        try expect(llm.requests.isEmpty, "vor der Bestätigung kein Modellaufruf")
        let id = try expectNotNil(svc.pending.first?.confirmation.id, "offene Anfrage")
        try expectEqual(svc.pending.first?.confirmation.summary,
                        "Ich suche lokal nach „router“ in Dokumente und kopiere den Fund in die Zwischenablage")
        let flashes = FlashBox()
        svc.subscribe { if case .flash(let n) = $0 { flashes.items.append(n) } }
        let confirmed = await svc.confirmAction(id)
        try expect(confirmed.isOk, "bestätigt")
        try expectEqual(board.value, "geheim-42")
        let reply = try expectNotNil((try? svc.store.messages.list(limit: 5))?.last?.content, "Antwort im Gespräch")
        try expectEqual(reply, "Fund wurde in die Zwischenablage kopiert (60 s).", "neutral im Gespräch")
        try expect(!reply.contains("router.md") && !reply.contains("Zeile"), "keine Datei im Gespräch")
        try expect(!reply.contains("geheim-42"), "Wert nie im Gespräch")
        let shown = flashes.items.map(\.body).joined(separator: " ")
        try expect(shown.contains("Unterlagen/router.md, Zeile 1") && shown.contains("9 Zeichen: g…2"), "Fundstelle und Vorschau in der Notch")
        try expect(!shown.contains("geheim-42"), "Wert auch in der Notch nicht")
      },
      CheckCase("Geheimnis-Suche: zu kurze, Teilwort- oder Steuerzeichen-Werte werden abgelehnt") {
        let m = SecretMaterial(blocks: [.init(shareName: "D", relativePath: "U/a.md", file: "a.md",
                                              body: "1: PIN: abc\n2: Passwort: geheim-42\n3: Token: x\u{7}y\n4: Notiz: ausgedacht-x")])
        try expect(CoreServices.locateSecret("abc", in: m) == nil, "zu kurz")
        try expect(CoreServices.locateSecret("geheim", in: m) == nil, "Teilwort vor Bindestrich")
        try expect(CoreServices.locateSecret("ausgedacht", in: m) == nil, "Teilwort nach Bindestrich")
        try expect(CoreServices.locateSecret("x\u{7}y", in: m) == nil, "Steuerzeichen")
        let ok = CoreServices.locateSecret("geheim-42", in: m)
        try expectEqual(ok?.line, 2)
        try expectEqual(ok?.labelled, true)
        try expectEqual(CoreServices.maskedPreview("geheim-42"), "9 Zeichen: g…2")
      },
      CheckCase("Geheimnis-Suche: Zeile mit Stichwort bevorzugt, sonst Treffer mit labelled false") {
        let m = SecretMaterial(blocks: [.init(shareName: "D", relativePath: "U/a.txt", file: "a.txt",
                                              body: "1: 4711-alt\n2: Notiz 4711\n5: Router-Passwort: 4711")])
        let labelled = CoreServices.locateSecret("4711", in: m)
        try expectEqual(labelled?.line, 5)
        try expectEqual(labelled?.labelled, true)
        let plain = SecretMaterial(blocks: [.init(shareName: "D", relativePath: "U/b.txt", file: "b.txt", body: "3: Netz: 9876")])
        let unlabelled = CoreServices.locateSecret("9876", in: plain)
        try expectEqual(unlabelled?.line, 3)
        try expectEqual(unlabelled?.labelled, false, "ohne Stichwort markiert")
      },
      CheckCase("Geheimnis-Suche: Eintragsgrenze und Zeitlimit beenden den Scan, Geräte- und Symlink-Dateien bleiben draußen") {
        var files: [String: String] = ["Unterlagen/router.md": "Router-Passwort: geheim-42"]
        for i in 0..<20 { files["Unterlagen/notiz\(i).md"] = "nichts hier" }
        let root = try share(with: files)
        try FileManager.default.createSymbolicLink(atPath: root + "/Unterlagen/geraet.md", withDestinationPath: "/dev/zero")
        let roots = [SecretRoot(shareName: "Dokumente", mountPath: root, folder: "Unterlagen")]
        let all = CoreServices.scanSecrets(roots, keywords: ["router", "geraet"], clock: ControllableClock("2026-10-18T10:00"))
        try expectEqual(all.blocks.map(\.file), ["router.md"], "Gerätedatei nicht gelesen")
        try expect(!all.limitHit, "ohne Grenze kein Abbruch")
        let capped = CoreServices.scanSecrets(roots, keywords: ["router"], clock: ControllableClock("2026-10-18T10:00"), maxEntries: 5)
        try expect(capped.limitHit, "Eintragsgrenze greift")
        let slow = CoreServices.scanSecrets(roots, keywords: ["router"], clock: TickingClock(ControllableClock("2026-10-18T10:00").now()), seconds: 3)
        try expect(slow.limitHit, "Zeitlimit greift")
        try expectEqual(CoreServices.secretMaxEntries, 5000)
        try expectEqual(CoreServices.secretMaxSeconds, 5)
        let file = root + "/Unterlagen/router.md"
        let device = try expectNotNil(CoreServices.fileDevice(file), "Gerät der Datei")
        try expect(CoreServices.readSecretFile(file, device: device) != nil, "gleiches Gerät gelesen")
        try expect(CoreServices.readSecretFile(file, device: device &+ 1) == nil, "fremdes Gerät abgelehnt")
        try expect(CoreServices.readSecretFile(root + "/Unterlagen/geraet.md", device: device) == nil, "Symlink abgelehnt")
      },
      CheckCase("Geheimnis-Suche: beim Beenden nur den eigenen, unveränderten Fund leeren") {
        let board = FakeBoard()
        let c = board.clipboard
        _ = c.copySecret("geheim-42")
        c.clearOnShutdown()
        try expect(board.value == nil, "eigener Fund geleert")
        _ = c.copySecret("geheim-43")
        _ = c.copy("anderes")
        c.clearOnShutdown()
        try expectEqual(board.value, "anderes", "fremde Kopie bleibt")
        let late = c.copySecret("x-1234")
        c.clearIfOwned(late - 1)
        try expectEqual(board.value, "x-1234", "anderer Fund bleibt")
        c.clearIfOwned(late)
        try expect(board.value == nil, "eigener Fund nach 60 s geleert")
      },
    ]
  }
}
