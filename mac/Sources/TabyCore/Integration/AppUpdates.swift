import CryptoKit
import Foundation

/// Fehler, deren Text direkt in der Oberfläche steht (auf Deutsch).
struct UpdateFailure: Error {
  let message: String
}

/// Inhalt von `version.json` (neben `Taby.dmg` in der Update-Adresse).
struct UpdateVersion: Decodable {
  let commit: String
  let date: String
  /// Fehlt in alten Versionen (= 0, also kein Update).
  let build: Int?
  /// SHA-256 der `Taby.dmg` (hex). Fehlt bei unsignierten Versionen.
  let sha256: String?
  /// Ed25519-Signatur (base64) über `UpdateSignature.message`. Fehlt bei unsignierten Versionen.
  let signature: String?
  /// Was ist neu (Klartext, nur Anzeige, nicht signiert). Fehlt in alten Versionen.
  let notes: String?
}

/// Signatur-Prüfung für Updates. Der private Schlüssel liegt nur beim Eigentümer im
/// Schlüsselbund (scripts/update-sign.swift); die App kennt nur den öffentlichen.
enum UpdateSignature {
  static let refusal = "Das Update ist nicht von Lumi signiert und wird nicht installiert."

  /// Signierte Nachricht: "<build>\n<commit>\n<sha256>". Muss mit scripts/update-sign.swift übereinstimmen.
  static func message(build: Int, commit: String, sha256: String) -> Data {
    Data("\(build)\n\(commit)\n\(sha256)".utf8)
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Wirft, wenn die DMG nicht zur signierten Version gehört. Fail closed: jede Lücke lehnt ab.
  static func check(_ info: UpdateVersion, dmg: Data, currentBuild: Int, publicKey: String) throws {
    guard let sha = info.sha256, let signature = info.signature, let build = info.build,
          sha.lowercased() == sha256Hex(dmg),
          let keyData = Data(base64Encoded: publicKey),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
          let sig = Data(base64Encoded: signature),
          key.isValidSignature(sig, for: message(build: build, commit: info.commit, sha256: sha.lowercased()))
    else { throw UpdateFailure(message: refusal) }
    guard build > currentBuild else {
      throw UpdateFailure(message: "Das Update ist nicht neuer als die laufende Version.")
    }
  }
}

extension CoreServices {
  /// Öffentlicher Ed25519-Schlüssel (Base64) des Eigentümers. Platzhalter = nichts wird installiert.
  /// Den echten Wert liefert `mac/scripts/make-update-key.sh` (einmal, Schlüssel bleibt im Schlüsselbund).
  static let updatePublicKey = "99Rh2ragLF1JyXK7pwWAywZ5tGKopMwn+7pMmX6xZP4="

  /// Commit der laufenden App aus Info.plist (leer = Entwickler-Build ohne git).
  static func bundleCommit() -> String {
    Bundle.main.object(forInfoDictionaryKey: "TabyCommit") as? String ?? ""
  }

  /// Build der laufenden App aus Info.plist (0 = Entwickler-Build ohne git, nie Update).
  public static func bundleBuild() -> Int {
    Bundle.main.object(forInfoDictionaryKey: "TabyBuild") as? Int ?? 0
  }

  /// Basisadresse (mit "/") für `version.json` und `Taby.dmg`.
  /// GitHub-Repo → dessen Ordner `download/` auf `main`; sonst ein Ordner-Link.
  static func updateBase(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = trimmed.isEmpty ? AppUpdate.defaultSource : trimmed
    guard source.lowercased().hasPrefix("https://"), let url = URL(string: source), let host = url.host?.lowercased()
    else { throw UpdateFailure(message: "Die Update-Adresse muss mit https:// beginnen.") }
    let parts = url.pathComponents.filter { $0 != "/" }
    if host == "github.com", parts.count == 2 {
      let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
      return "https://raw.githubusercontent.com/\(parts[0])/\(repo)/main/download/"
    }
    return source.hasSuffix("/") ? source : source + "/"
  }

  public func checkForUpdate() async -> ToolResult<AppUpdate?> {
    let current = options.appBuild()
    guard current > 0 else {
      availableUpdate = nil
      return .ok(nil)
    }
    do {
      let base = try Self.updateBase(settings.updateSource)
      let info = try JSONDecoder().decode(UpdateVersion.self,
                                          from: try await updateFetch(base, "version.json", limit: Self.maxVersionBytes))
      let remote = info.build ?? 0
      availableUpdate = remote > current
        ? AppUpdate(commit: info.commit, date: info.date, currentCommit: options.appCommit(),
                    build: remote, currentBuild: current, notes: Self.cleanNotes(info.notes))
        : nil
      return .ok(availableUpdate)
    } catch let failure as UpdateFailure {
      return .failure(code: "UPDATE", error: failure.message)
    } catch {
      return .failure(code: "UPDATE", error: "Die Update-Adresse liefert keine gültige version.json.")
    }
  }

  public func installUpdate() async -> ToolResult<Empty> {
    let app = Bundle.main.bundleURL
    guard app.pathExtension == "app" else {
      return .failure(code: "UPDATE", error: "Updates gibt es nur für die installierte App, nicht für einen Entwickler-Lauf.")
    }
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("taby-update-\(UUID().uuidString)", isDirectory: true)
    downloadPercent = 0
    defer { downloadPercent = nil }
    do {
      let base = try Self.updateBase(settings.updateSource)
      guard let info = try? JSONDecoder().decode(UpdateVersion.self,
                                                 from: try await updateFetch(base, "version.json", limit: Self.maxVersionBytes)) else {
        throw UpdateFailure(message: "Die Update-Adresse liefert keine gültige version.json.")
      }
      let dmg = try await updateFetch(base, "Taby.dmg", limit: Self.maxDMGBytes) { [weak self] pct in
        Task { @MainActor in
          self?.downloadPercent = pct
          self?.changed()
          self?.emit(.flash(TabyNotification(title: "Update lädt", body: "\(pct) %")))
        }
      }
      // Vor dem Schreiben prüfen: unsignierte oder fremde DMG landet nicht auf der Platte.
      try UpdateSignature.check(info, dmg: dmg, currentBuild: options.appBuild(), publicKey: Self.updatePublicKey)
      // Die DMG bleibt in `work`; Prüfsumme, Mount, Kopie und Signatur erledigt das Skript nach dem Beenden.
      let image = work.appendingPathComponent("Taby.dmg")
      let script = work.appendingPathComponent("update.sh")
      let pid = ProcessInfo.processInfo.processIdentifier
      try await Blocking.run {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try dmg.write(to: image)
        try CoreServices.updateScript.write(to: script, atomically: true, encoding: .utf8)
      }
      // Bleibt die Merkdatei stehen, hat der Tausch nicht geklappt (der nächste Start meldet das).
      try Self.writeUpdateMarker(Self.updateMarkerURL, build: info.build ?? 0)
      // Läuft getrennt weiter, nachdem Lumi sich beendet hat.
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [script.path, String(pid), work.path, app.path, (info.sha256 ?? "").lowercased()]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      emit(.flash(TabyNotification(title: "Update wird eingespielt",
                                   body: "Beim Schlüsselbund-Dialog auf „Erlauben“ klicken (nicht „Immer erlauben“).")))
      try process.run()
      return .ok(Empty())
    } catch {
      try? FileManager.default.removeItem(at: work)
      if let failure = error as? UpdateFailure {
        return .failure(code: "UPDATE", error: failure.message)
      }
      return .failure(code: "UPDATE", error: "Die Installation ist fehlgeschlagen: \(error.localizedDescription)")
    }
  }

  /// Beim Start leise prüfen; pro neuer Version genau eine Benachrichtigung (auch über Neustarts hinweg).
  func quietUpdateCheck() async {
    if let notice = Self.checkUpdateMarker(Self.updateMarkerURL, currentBuild: options.appBuild()) { emit(.flash(notice)) }
    guard case .ok(let found?) = await checkForUpdate() else { return }
    changed()
    let key = "lastNotifiedUpdate"
    guard found.build > options.updateDefaults.integer(forKey: key) else { return }
    options.updateDefaults.set(found.build, forKey: key)
    options.systemNotifier.send(TabyNotification(title: "Lumi-Update verfügbar",
                                                 body: "Lumi \(found.versionName) ist da – Einstellungen → Updates."))
  }

  /// Notizen aus `version.json` als Klartext: ohne Steuerzeichen (Zeilenumbrüche bleiben), höchstens 600 Zeichen.
  static func cleanNotes(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let kept = raw.filter { $0.isNewline || !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    let text = String(kept.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Größte DMG, die geladen wird. Größere Antworten brechen ab, bevor sie in den Speicher wachsen.
  static let maxDMGBytes = 300_000_000
  /// `version.json` ist winzig; alles darüber ist keine gültige Versionsangabe.
  static let maxVersionBytes = 64 * 1024

  private func updateFetch(_ base: String, _ file: String, limit: Int = Int.max,
                           progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
    guard let url = URL(string: base + file) else { throw UpdateFailure(message: "Die Update-Adresse ist ungültig.") }
    return try await Self.fetchLimited(urlSession, url, limit: limit, progress: progress)
  }

  /// Lädt eine Antwort als Download-Aufgabe, höchstens `limit` Bytes. Ist die Länge bekannt, bricht sie
  /// schon bei der Ankündigung ab, sonst während des Ladens. `progress` meldet Prozent in 10er-Schritten.
  static func fetchLimited(_ session: URLSession, _ url: URL, limit: Int,
                           progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
    let tooLarge = UpdateFailure(message: "Die Datei der Update-Adresse ist zu groß und wird nicht geladen.")
    let state = DownloadState()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      let task = session.downloadTask(with: url) { file, response, error in
        if state.tooLarge { cont.resume(throwing: tooLarge); return }
        guard error == nil, let file else {
          cont.resume(throwing: UpdateFailure(message: "Keine Verbindung zur Update-Adresse."))
          return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
          cont.resume(throwing: UpdateFailure(message: "Unter der Update-Adresse liegt keine Lumi-Version."))
          return
        }
        guard (200..<300).contains(status) else {
          cont.resume(throwing: UpdateFailure(message: "Die Update-Adresse antwortet mit Fehler \(status)."))
          return
        }
        do {
          let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
          guard size <= limit else { throw tooLarge }
          cont.resume(returning: try Data(contentsOf: file))
        } catch {
          cont.resume(throwing: error)
        }
      }
      state.watch(task, limit: limit, progress: progress)
      task.resume()
    }
  }

  static func runTool(_ path: String, _ args: [String]) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = output
    process.standardError = output
    try process.run()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw UpdateFailure(message: "Die Installation ist fehlgeschlagen (\((path as NSString).lastPathComponent)).")
    }
  }

  /// Merkdatei des laufenden Tauschs: enthält den Build, den das Update bringen soll.
  static var updateMarkerURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Taby/update-pending.txt")
  }

  static func writeUpdateMarker(_ url: URL, build: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "\(build)\n".write(to: url, atomically: true, encoding: .utf8)
  }

  /// Start-Prüfung: Merkdatei weg und Build neu genug → still gut. Liegt sie noch da, ist der Tausch gescheitert.
  static func checkUpdateMarker(_ url: URL, currentBuild: Int) -> TabyNotification? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: url)
    guard let target = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), target > currentBuild else { return nil }
    return TabyNotification(title: "Update",
                            body: "Update konnte nicht eingespielt werden – Protokoll: ~/Library/Logs/Taby-Update.log")
  }

  /// Wartet, bis Lumi beendet ist, prüft die DMG per SHA-256, kopiert die App daraus, prüft sie
  /// per codesign und tauscht sie aus. Argumente: PID, Arbeitsordner (mit Taby.dmg), App, erwartete SHA-256.
  static let updateScript = #"""
  #!/bin/sh
  # Von Lumi gestartet: tauscht Lumi.app nach dem Beenden aus. Ausgabe steht im Log.
  PID="$1"; WORK="$2"; APP="$3"; SHA="$4"
  DMG="$WORK/Taby.dmg"; MNT="$WORK/mnt"; NEW="$APP.new"
  LOG="$HOME/Library/Logs/Taby-Update.log"
  mkdir -p "$(dirname "$LOG")"
  exec >>"$LOG" 2>&1
  echo "--- $(date '+%Y-%m-%d %H:%M:%S') Update für $APP"
  # Am Ende immer aufräumen: Disk-Image aushängen, Arbeitsordner löschen.
  trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1; rm -rf "$WORK"' EXIT
  # Warten, bis Lumi beendet ist (höchstens 30 Sekunden).
  i=0
  while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
  if kill -0 "$PID" 2>/dev/null; then echo "Lumi läuft noch, kein Austausch"; exit 1; fi
  # Die alte App bleibt bis zum Tausch unberührt.
  fail() { echo "Austausch abgebrochen: $1"; rm -rf "$NEW"; open "$APP"; exit 1; }
  [ -n "$SHA" ] || fail "keine Prüfsumme erwartet"
  [ "$(shasum -a 256 "$DMG" | awk '{print $1}')" = "$SHA" ] || fail "Prüfsumme der DMG stimmt nicht"
  mkdir -p "$MNT"
  hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null || fail "DMG lässt sich nicht öffnen"
  # Neue DMGs enthalten Lumi.app, ältere Taby.app: beides akzeptieren.
  SRC="$MNT/Lumi.app"; [ -d "$SRC" ] || SRC="$MNT/Taby.app"
  [ -d "$SRC" ] || fail "Die Update-DMG enthält keine App"
  rm -rf "$NEW"
  ditto "$SRC" "$NEW" || fail "Kopieren fehlgeschlagen"
  hdiutil detach "$MNT" -quiet >/dev/null 2>&1
  codesign --verify --deep -R='identifier "de.felix.taby"' "$NEW" || fail "Signatur der neuen App ist ungültig"
  # Tausch: alte App in den Papierkorb, neue an ihren Platz.
  mkdir -p "$HOME/.Trash"
  TRASH="$HOME/.Trash/Lumi-$(date +%Y%m%d-%H%M%S).app"
  mv "$APP" "$TRASH" || fail "alte App nicht verschiebbar"
  if ! mv "$NEW" "$APP"; then mv "$TRASH" "$APP"; fail "neue App nicht verschiebbar"; fi
  # Mit dem Zertifikat dieses Macs signieren, damit Freigaben bleiben; sonst ad hoc.
  SETUP="$APP/Contents/Resources/friend-setup.command"
  if [ -f "$SETUP" ] && TABY_NO_OPEN=1 /bin/sh "$SETUP" "$APP"; then
    echo "Einrichtung ok"
  else
    echo "Einrichtung fehlgeschlagen, ad hoc signieren"
    xattr -dr com.apple.quarantine "$APP"
    codesign --force --sign - "$APP"
  fi
  open "$APP"
  echo "fertig"
  """#
}

/// Beobachtet eine Download-Aufgabe: bricht bei zu großer Antwort ab und meldet den Fortschritt.
final class DownloadState: @unchecked Sendable {
  private let lock = NSLock()
  private var observation: NSKeyValueObservation?
  private var reportedStep = 0
  private(set) var tooLarge = false

  /// Grenze erreicht? Mit angekündigter Länge zählt sie; ohne (total unbekannt) die bisher geladene Menge.
  static func exceeds(total: Int64, completed: Int64, limit: Int) -> Bool {
    total > 0 ? total > Int64(limit) : completed > Int64(limit)
  }

  func watch(_ task: URLSessionDownloadTask, limit: Int, progress: (@Sendable (Int) -> Void)?) {
    observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak task] p, _ in
      guard let self else { return }
      if Self.exceeds(total: p.totalUnitCount, completed: p.completedUnitCount, limit: limit) {
        self.lock.lock(); self.tooLarge = true; self.lock.unlock()
        task?.cancel()
        return
      }
      guard let progress, p.totalUnitCount > 0 else { return }
      let step = Int(p.fractionCompleted * 10) * 10
      self.lock.lock()
      let fresh = step > self.reportedStep
      if fresh { self.reportedStep = step }
      self.lock.unlock()
      if fresh { progress(step) }
    }
  }
}
