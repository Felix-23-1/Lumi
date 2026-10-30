// Selbst-Signatur für Freunde ohne Terminal. Die App macht, was scripts/friend-setup.command
// macht: ein eigenes Zertifikat "Taby Local Signing" im Anmelde-Schlüsselbund anlegen und
// /Applications/Lumi.app damit signieren, damit macOS die Freigaben über Updates behält.
// Alle Befehle laufen über Process mit argv-Listen, nie über eine Shell.
// Der Schlüssel ist nicht exportierbar (-x) und keinem Programm vorab freigegeben: jede
// Signatur fragt im Schlüsselbund einmal nach (Einrichtung und jedes Update: „Erlauben“).
import Foundation

public enum SelfSigning {
  public static let identity = "Taby Local Signing"
  static let applicationsFolder = "/Applications/"
  static let toolTimeout: TimeInterval = 120
  static let dialogHint = "Bitte auf den Dialog von macOS achten – Lumi wartet auf die Freigabe im Schlüsselbund."

  /// Was zu tun ist (rein, prüfbar).
  public enum Plan: Equatable, Sendable {
    case alreadySigned
    case notInApplications
    case sign(needsCertificate: Bool)
  }

  public enum Outcome: Equatable, Sendable {
    case alreadySigned
    case signed
    /// Der Grund steht verständlich im Text (für die Anzeige).
    case failed(String)
  }

  public static var defaultKeychain: String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
  }

  // MARK: Reine Entscheidungen

  /// Ist das Bundle schon mit unserem Zertifikat signiert? Liest die Ausgabe von `codesign -dv`
  /// (steht auf stderr), Zeile „Authority=Taby Local Signing“.
  public static func isSigned(codesignOutput: String) -> Bool {
    codesignOutput.split(whereSeparator: \.isNewline).contains {
      String($0).trimmingCharacters(in: .whitespaces) == "Authority=\(identity)"
    }
  }

  /// SHA-1 des Zertifikats mit genau diesem Namen aus `security find-identity -p codesigning`.
  /// Zeile: `  1) <40 Hex-Zeichen> "Taby Local Signing"`. Der Name muss exakt passen (nicht als Teilstring).
  public static func identityHash(findIdentityOutput: String) -> String? {
    for line in findIdentityOutput.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
      guard parts.count >= 3, parts[1] == identity else { continue }
      let hash = parts[0].split(separator: " ").last.map(String.init) ?? ""
      if hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) { return hash }
    }
    return nil
  }

  public static func plan(appPath: String, codesignOutput: String, certificateFound: Bool) -> Plan {
    if isSigned(codesignOutput: codesignOutput) { return .alreadySigned }
    guard appPath.hasPrefix(applicationsFolder), appPath.hasSuffix(".app") else { return .notInApplications }
    return .sign(needsCertificate: !certificateFound)
  }

  // MARK: argv-Listen (rein, prüfbar)

  public static func codesignInfoArgv(app: String) -> [String] { ["-dv", "--verbose=2", app] }

  /// Ohne `-v`: `-v` blendet nicht vertraute selbstsignierte Zertifikate aus, also genau unseres.
  public static func findIdentityArgv(keychain: String) -> [String] {
    ["find-identity", "-p", "codesigning", keychain]
  }

  public static func opensslRequestArgv(key: String, cert: String, config: String) -> [String] {
    ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
     "-keyout", key, "-out", cert, "-config", config]
  }

  /// Leeres Passwort: auf der Argumentliste steht kein Geheimnis. Die Datei liegt nur im temporären Ordner.
  public static func pkcs12Argv(key: String, cert: String, p12: String) -> [String] {
    ["pkcs12", "-export", "-inkey", key, "-in", cert, "-name", identity, "-out", p12, "-passout", "pass:"]
  }

  /// Kein `-T /usr/bin/codesign` (keine Vorfreigabe), `-x` (nicht exportierbar).
  public static func importArgv(p12: String, keychain: String) -> [String] {
    ["import", p12, "-k", keychain, "-P", "", "-x"]
  }

  /// Mit dem SHA-1 des Zertifikats, nie mit dem Namen (Namen könnten doppelt vorkommen). Ohne `--deep`.
  public static func signArgv(target: String, keychain: String, identityHash: String) -> [String] {
    ["--force", "--sign", identityHash, "--keychain", keychain, "--timestamp=none", target]
  }

  public static func verifyArgv(app: String) -> [String] { ["--verify", app] }

  public static func quarantineArgv(app: String) -> [String] { ["-dr", "com.apple.quarantine", app] }

  /// Konfiguration für das Zertifikat (gleich wie im Skript: nur Code-Signierung).
  public static func certificateConfig() -> String {
    """
    [req]
    distinguished_name = dn
    x509_extensions = ext
    prompt = no
    [dn]
    CN = \(identity)
    [ext]
    basicConstraints = critical,CA:false
    keyUsage = critical,digitalSignature
    extendedKeyUsage = critical,codeSigning

    """
  }

  // MARK: Ausführung (blockierend: nicht auf dem Hauptthread aufrufen)

  struct ToolResult { let status: Int32; let output: String }

  /// Läuft das Werkzeug länger als `toolTimeout` (z. B. weil der Schlüsselbund-Dialog offen bleibt),
  /// wird es beendet und der Status ist -2.
  static func runTool(_ path: String, _ args: [String]) -> ToolResult {
    let p = Process()
    let pipe = Pipe()
    let finished = DispatchSemaphore(value: 0)
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = pipe
    p.terminationHandler = { _ in finished.signal() }
    do { try p.run() } catch { return ToolResult(status: -1, output: "\(error)") }
    if finished.wait(timeout: .now() + toolTimeout) == .timedOut {
      p.terminate()
      return ToolResult(status: -2, output: dialogHint)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return ToolResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }

  /// Legt das Zertifikat an (nur wenn es fehlt). Gibt nil bei Erfolg zurück, sonst den Grund.
  static func createCertificate(keychain: String) -> String? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taby-sign-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
      return "Arbeitsordner nicht anlegbar: \(error.localizedDescription)"
    }
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = dir.appendingPathComponent("key.pem").path
    let cert = dir.appendingPathComponent("cert.pem").path
    let config = dir.appendingPathComponent("cert.cnf").path
    let p12 = dir.appendingPathComponent("taby.p12").path
    do { try certificateConfig().write(toFile: config, atomically: true, encoding: .utf8) } catch {
      return "Zertifikat-Vorlage nicht schreibbar: \(error.localizedDescription)"
    }
    let steps: [(String, [String])] = [
      ("openssl", opensslRequestArgv(key: key, cert: cert, config: config)),
      ("openssl", pkcs12Argv(key: key, cert: cert, p12: p12)),
      ("security", importArgv(p12: p12, keychain: keychain)),
    ]
    let tools = ["openssl": "/usr/bin/openssl", "security": "/usr/bin/security"]
    for (tool, args) in steps {
      let r = runTool(tools[tool] ?? tool, args)
      if r.status != 0 {
        let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Zertifikat konnte nicht angelegt werden (\(tool) \(r.status))\(detail.isEmpty ? "" : ": \(detail)")"
      }
    }
    return nil
  }

  private static func certificateHash(keychain: String) -> String? {
    identityHash(findIdentityOutput: runTool("/usr/bin/security", findIdentityArgv(keychain: keychain)).output)
  }

  /// Der komplette Ablauf. `appPath` ist das laufende Bundle (Pfad von `Bundle.main.bundlePath`).
  public static func run(appPath: String, keychain: String = defaultKeychain) -> Outcome {
    let info = runTool("/usr/bin/codesign", codesignInfoArgv(app: appPath))
    let existing = certificateHash(keychain: keychain)
    switch plan(appPath: appPath, codesignOutput: info.output, certificateFound: existing != nil) {
    case .alreadySigned:
      return .alreadySigned
    case .notInApplications:
      return .failed("Lumi liegt nicht im Ordner Programme (\(appPath)). Bitte Lumi aus der DMG nach Programme ziehen und von dort öffnen.")
    case .sign(let needsCertificate):
      if needsCertificate, let problem = createCertificate(keychain: keychain) { return .failed(problem) }
      guard let hash = needsCertificate ? certificateHash(keychain: keychain) : existing else {
        return .failed("Zertifikat „\(identity)“ im Schlüsselbund nicht gefunden.")
      }
      _ = runTool("/usr/bin/xattr", quarantineArgv(app: appPath))
      let helpers = ["taby-hook-relay", "taby-mcp"].map { appPath + "/Contents/MacOS/" + $0 }
      for helper in helpers where FileManager.default.fileExists(atPath: helper) {
        let r = runTool("/usr/bin/codesign", signArgv(target: helper, keychain: keychain, identityHash: hash))
        if r.status != 0 { return .failed(signingFailure(r)) }
      }
      let signed = runTool("/usr/bin/codesign", signArgv(target: appPath, keychain: keychain, identityHash: hash))
      if signed.status != 0 { return .failed(signingFailure(signed)) }
      let verified = runTool("/usr/bin/codesign", verifyArgv(app: appPath))
      if verified.status != 0 { return .failed(signingFailure(verified)) }
      return .signed
    }
  }

  private static func signingFailure(_ r: ToolResult) -> String {
    if r.status == -2 { return "Signieren nicht abgeschlossen (Zeitüberschreitung). \(dialogHint)" }
    let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return "Signieren fehlgeschlagen (codesign \(r.status))\(detail.isEmpty ? "" : ": \(detail)")"
  }
}
