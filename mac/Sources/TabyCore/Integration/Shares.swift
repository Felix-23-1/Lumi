// Netzlaufwerke (SMB) wie im Finder: Adresse prüfen, einhängen (NetFS, ohne Shell),
// trennen, Passwort im Schlüsselbund unter `share-<id>`. Der Zustand kommt aus der
// Mount-Tabelle des Kerns – ohne Zugriff auf die Freigabe selbst.
import AppKit
import Darwin
import Foundation
import NetFS

/// Eine eingehängte Freigabe aus der Mount-Tabelle.
public struct MountedVolume: Equatable, Sendable {
  public var path: String
  public var fsType: String
  /// Quelle wie im Mount, z. B. "//user@nas.local/Dokumente".
  public var source: String
  public init(path: String, fsType: String, source: String) {
    self.path = path; self.fsType = fsType; self.source = source
  }
}

/// Fehler beim Einhängen; `status` ist der Rückgabewert von NetFS (errno-artig) oder `timeoutStatus`.
public struct ShareMountError: Error, Equatable, Sendable {
  public var status: Int32
  public init(status: Int32) { self.status = status }
  public static let timeoutStatus: Int32 = -1001
}

/// Das System hinter den Netzlaufwerken. Prüfungen setzen Attrappen; die App nutzt `.live`.
public struct ShareSystem: Sendable {
  public var mountedVolumes: @Sendable () -> [MountedVolume]
  /// Hängt `url` (smb://host/share) ein und liefert den Einhängepunkt.
  public var mount: @Sendable (_ url: String, _ user: String?, _ password: String?) throws -> String
  public var unmount: @Sendable (_ path: String) throws -> Void

  public init(mountedVolumes: @escaping @Sendable () -> [MountedVolume],
              mount: @escaping @Sendable (String, String?, String?) throws -> String,
              unmount: @escaping @Sendable (String) throws -> Void) {
    self.mountedVolumes = mountedVolumes; self.mount = mount; self.unmount = unmount
  }

  public static let live = ShareSystem(
    mountedVolumes: { liveMountedVolumes() },
    mount: { url, user, password in try netFSMount(url: url, user: user, password: password) },
    unmount: { path in try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path)) }
  )

  /// Mount-Tabelle des Kerns (kein Zugriff auf die Freigabe selbst; MNT_NOWAIT blockiert nicht).
  static func liveMountedVolumes() -> [MountedVolume] {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&table, MNT_NOWAIT)
    guard count > 0, let table else { return [] }
    return (0..<Int(count)).map { i in
      var entry = table[i]
      return MountedVolume(path: cString(&entry.f_mntonname), fsType: cString(&entry.f_fstypename),
                           source: cString(&entry.f_mntfromname))
    }
  }

  private static func cString<T>(_ field: inout T) -> String {
    withUnsafeBytes(of: &field) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
  }

  /// NetFS synchron: ohne Shell, Passwort nur als Parameter. Einhängepunkt unter /Volumes (vom System gewählt).
  static func netFSMount(url: String, user: String?, password: String?) throws -> String {
    guard let target = URL(string: url) else { throw ShareMountError(status: EINVAL) }
    var mountpoints: Unmanaged<CFArray>?
    // Nie ein Anmeldefenster von Lumi aus; falsches oder fehlendes Passwort wird zum Fehlertext.
    let openOptions = NSMutableDictionary()
    openOptions["UIOption"] = "NoUI"
    // Schlüssel wie kNetFSAllowSubMountsKey ("AllowSubMounts"); die Konstante selbst lässt sich nicht importieren.
    let mountOptions = NSMutableDictionary()
    mountOptions["AllowSubMounts"] = true
    let status = NetFSMountURLSync(target as CFURL, nil, user.map { $0 as CFString }, password.map { $0 as CFString },
                                   openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary, &mountpoints)
    guard status == 0 else { throw ShareMountError(status: status) }
    guard let path = (mountpoints?.takeRetainedValue() as? [String])?.first else { throw ShareMountError(status: ENOENT) }
    return path
  }
}

/// Adresse eines Netzlaufwerks: nur `smb://host/freigabe[/unterordner]`, nie mit Benutzer oder Passwort.
public enum ShareURL {
  public struct Parts: Equatable, Sendable {
    public var host: String
    public var share: String
    public var subPath: String
  }

  /// Gültige Adresse → Bestandteile; sonst nil.
  public static func parts(_ raw: String) -> Parts? { analyze(raw).parts }

  /// Ein Satz für die Oberfläche, wenn die Adresse nicht passt; nil wenn sie gültig ist.
  public static func problem(_ raw: String) -> String? { analyze(raw).problem }

  /// Adresse ohne Unterordner, wie sie an NetFS geht.
  public static func mountAddress(_ parts: Parts) -> String {
    let share = parts.share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parts.share
    return "smb://\(parts.host)/\(share)"
  }

  private static func analyze(_ raw: String) -> (parts: Parts?, problem: String?) {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return (nil, "Die Adresse fehlt.") }
    guard t.lowercased().hasPrefix("smb://") else {
      return (nil, "Die Adresse beginnt mit smb:// – z. B. smb://nas.local/Dokumente.")
    }
    let rest = String(t.dropFirst(6))
    guard !rest.contains("@") else {
      return (nil, "Benutzer und Passwort gehören nicht in die Adresse. Trage sie getrennt ein.")
    }
    guard !rest.contains(where: { "?#\\".contains($0) || $0.unicodeScalars.contains(where: { $0.value < 32 }) }) else {
      return (nil, "Die Adresse enthält ungültige Zeichen.")
    }
    let pieces = rest.split(separator: "/", maxSplits: Int.max, omittingEmptySubsequences: false).map(String.init)
    let host = pieces.first ?? ""
    let hostOK = !host.isEmpty && host.count <= 253 && !host.hasPrefix("-") && !host.hasPrefix(".")
      && host.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }
    guard hostOK else { return (nil, "Der Servername ist ungültig, z. B. nas.local oder 192.168.1.20.") }
    let segments = pieces.dropFirst().filter { !$0.isEmpty }.map { $0.removingPercentEncoding ?? $0 }
    guard let share = segments.first else {
      return (nil, "Die Freigabe fehlt, z. B. smb://nas.local/Dokumente.")
    }
    guard !segments.contains(where: { $0 == ".." || $0 == "." }) else {
      return (nil, "Die Adresse darf keine „..“ enthalten.")
    }
    guard !segments.contains(where: { $0.contains("/") || $0.unicodeScalars.contains(where: { $0.value < 32 }) }),
          share.count <= 255 else {
      return (nil, "Die Freigabe enthält ungültige Zeichen.")
    }
    return (Parts(host: host.lowercased(), share: share, subPath: segments.dropFirst().joined(separator: "/")), nil)
  }
}

/// Deutsche Meldungen zu NetFS-Fehlern. Die Werte sind errno-artig; -6003/-6602 sind NetAuth-Codes.
public enum ShareMountMessage {
  public static func text(status: Int32) -> String {
    switch status {
    case ShareMountError.timeoutStatus:
      return "Server nicht erreichbar – keine Antwort innerhalb von 30 Sekunden."
    case EAUTH, EACCES, EPERM:
      return "Anmeldung abgelehnt – Benutzer oder Passwort prüfen."
    case ENOENT, -6003:
      return "Freigabe nicht gefunden."
    case EHOSTUNREACH, EHOSTDOWN, ETIMEDOUT, ECONNREFUSED, ENETUNREACH, ECONNRESET:
      return "Server nicht erreichbar."
    default:
      return "Verbindung fehlgeschlagen (Fehler \(status))."
    }
  }
}

/// Setzt die Fortsetzung genau einmal fort; ein später eintreffendes zweites Ergebnis wird verworfen.
final class ShareMountOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var cont: CheckedContinuation<Result<String, ShareMountError>, Never>?
  init(_ cont: CheckedContinuation<Result<String, ShareMountError>, Never>) { self.cont = cont }
  func finish(_ value: Result<String, ShareMountError>) {
    lock.lock(); let taken = cont; cont = nil; lock.unlock()
    taken?.resume(returning: value)
  }
}

/// Zuordnung Netzlaufwerk → eingehängte Freigabe (Mount-Tabelle).
public enum ShareMatch {
  public static func volume(for share: NetworkShare, in volumes: [MountedVolume]) -> MountedVolume? {
    guard let parts = ShareURL.parts(share.url) else { return nil }
    return volumes.first { v in
      guard v.fsType == "smbfs", v.source.hasPrefix("//") else { return false }
      let body = v.source.dropFirst(2)
      guard let slash = body.firstIndex(of: "/") else { return false }
      var host = String(body[..<slash])
      if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
      let name = String(body[body.index(after: slash)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return host.lowercased() == parts.host && (name.removingPercentEncoding ?? name).lowercased() == parts.share.lowercased()
    }
  }
}

extension CoreServices {
  /// Zustand je Netzlaufwerk für `AppState`. Liest nur die Mount-Tabelle, nie die Freigabe.
  func shareStatesNow(_ shares: [NetworkShare]) -> [String: ShareState] {
    let volumes = options.shares.mountedVolumes()
    var out: [String: ShareState] = [:]
    for share in shares {
      if let v = ShareMatch.volume(for: share, in: volumes) {
        out[share.id] = ShareState(mounted: true, mountPath: v.path, error: nil)
      } else {
        out[share.id] = ShareState(mounted: false, mountPath: nil, error: shareErrors[share.id])
      }
    }
    return out
  }

  func share(_ id: String) -> NetworkShare? { settings.networkShares.first { $0.id == id } }

  public func mountShare(_ id: String) async -> ToolResult<Empty> {
    guard let share = share(id) else { return .failure(code: "NOT_FOUND", error: "Netzlaufwerk nicht gefunden.") }
    return await mountNow(share, automatic: false)
  }

  /// Einhängen mit Passwort aus dem Schlüsselbund; Ergebnis und Fehler stehen danach im Zustand.
  func mountNow(_ share: NetworkShare, automatic: Bool) async -> ToolResult<Empty> {
    guard let parts = ShareURL.parts(share.url) else {
      let message = ShareURL.problem(share.url) ?? "Die Adresse ist ungültig."
      shareErrors[share.id] = message
      changed()
      return .failure(code: "INVALID_ARGS", error: message)
    }
    let password: String?
    do {
      password = try options.shareSecrets(share.id).get()
    } catch {
      TabyLog.error(.core, "Netzlaufwerk: Passwort nicht aus dem Schlüsselbund gelesen (\(TabyLog.code(error)))")
      let message = "Das Passwort konnte nicht aus dem Schlüsselbund gelesen werden."
      shareErrors[share.id] = message
      changed()
      return .failure(code: "KEYCHAIN", error: message)
    }
    let outcome = await Self.mountWithTimeout(
      system: options.shares, url: ShareURL.mountAddress(parts),
      user: share.user.isEmpty ? nil : share.user, password: password?.isEmpty == false ? password : nil)
    let suffix = automatic ? " (beim Start)" : ""
    switch outcome {
    case .success:
      shareErrors[share.id] = nil
      audit(actor: AuditActor.user, tool: "mount_share", confirmed: false, ok: true,
            summary: "Netzlaufwerk „\(share.name)“ verbunden\(suffix)")
      changed()
      return .ok(Empty())
    case .failure(let error):
      let message = ShareMountMessage.text(status: error.status)
      shareErrors[share.id] = message
      audit(actor: AuditActor.user, tool: "mount_share", confirmed: false, ok: false,
            summary: "Netzlaufwerk „\(share.name)“ nicht verbunden\(suffix)")
      changed()
      return .failure(code: "MOUNT", error: message)
    }
  }

  /// NetFS blockiert; deshalb auf einer Hintergrund-Warteschlange. Gewinnt der Timer, kommt das
  /// spätere NetFS-Ergebnis nicht mehr an. Ein Einhängen, das doch noch gelingt, bleibt bestehen;
  /// der Zustand kommt ohnehin aus der Mount-Tabelle.
  static func mountWithTimeout(system: ShareSystem, url: String, user: String?, password: String?,
                               seconds: UInt64 = 30) async -> Result<String, ShareMountError> {
    await withCheckedContinuation { (cont: CheckedContinuation<Result<String, ShareMountError>, Never>) in
      let once = ShareMountOnce(cont)
      DispatchQueue.global(qos: .userInitiated).async {
        do { once.finish(.success(try system.mount(url, user, password))) }
        catch let e as ShareMountError { once.finish(.failure(e)) }
        catch { once.finish(.failure(ShareMountError(status: EIO))) }
      }
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(Int(seconds))) {
        once.finish(.failure(ShareMountError(status: ShareMountError.timeoutStatus)))
      }
    }
  }

  public func unmountShare(_ id: String) async -> ToolResult<Empty> {
    guard let share = share(id) else { return .failure(code: "NOT_FOUND", error: "Netzlaufwerk nicht gefunden.") }
    guard let volume = ShareMatch.volume(for: share, in: options.shares.mountedVolumes()) else {
      shareErrors[id] = nil
      changed()
      return .ok(Empty())
    }
    let system = options.shares
    do {
      try await Blocking.run(qos: .userInitiated) { try system.unmount(volume.path) }
    } catch {
      TabyLog.error(.core, "Netzlaufwerk nicht getrennt (\(TabyLog.code(error)))")
      let message = "Trennen hat nicht geklappt. Schließe die Dateien von „\(share.name)“ und versuche es erneut."
      shareErrors[id] = message
      audit(actor: AuditActor.user, tool: "unmount_share", confirmed: false, ok: false,
            summary: "Netzlaufwerk „\(share.name)“ nicht getrennt")
      changed()
      return .failure(code: "UNMOUNT", error: message)
    }
    shareErrors[id] = nil
    audit(actor: AuditActor.user, tool: "unmount_share", confirmed: false, ok: true,
          summary: "Netzlaufwerk „\(share.name)“ getrennt")
    changed()
    return .ok(Empty())
  }

  /// Passwort ins Schlüsselbund (leer = entfernen). Der Wert erscheint nirgends sonst.
  public func setSharePassword(_ id: String, password: String) async -> ToolResult<Empty> {
    guard share(id) != nil else { return .failure(code: "NOT_FOUND", error: "Netzlaufwerk nicht gefunden.") }
    let store = options.shareSecrets(id)
    do {
      if password.isEmpty { try store.delete() } else { try store.set(password) }
    } catch {
      TabyLog.error(.core, "Netzlaufwerk: Passwort nicht im Schlüsselbund gespeichert (\(TabyLog.code(error)))")
      return .failure(code: "KEYCHAIN", error: "Das Passwort konnte nicht im Schlüsselbund gespeichert werden.")
    }
    audit(actor: AuditActor.user, tool: "set_share_password", confirmed: false, ok: true,
          summary: password.isEmpty ? "Netzlaufwerk-Passwort entfernt" : "Netzlaufwerk-Passwort gespeichert")
    changed()
    return .ok(Empty())
  }

  /// Beim Start (nach 10 s) die Netzlaufwerke mit „Beim Start verbinden“ einhängen; danach auf Einhänge-Meldungen reagieren.
  func startShareWatch() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      shareObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.changed() }
      })
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      await self?.autoMountShares()
    }
  }

  /// „Beim Start verbinden“. Nach einem Anmeldefehler (falsches Passwort) kein erneuter Versuch, bis
  /// der Nutzer selbst verbindet; diese Merkung steht nur im Speicher (`shareErrors`).
  func autoMountShares() async {
    for share in settings.networkShares where share.autoMount {
      guard ShareMatch.volume(for: share, in: options.shares.mountedVolumes()) == nil else { continue }
      guard shareErrors[share.id] != ShareMountMessage.text(status: EAUTH) else { continue }
      _ = await mountNow(share, automatic: true)
    }
    changed()
  }
}
