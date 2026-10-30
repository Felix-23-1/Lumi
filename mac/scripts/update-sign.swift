// Signiert Lumi-Updates mit Ed25519 (CryptoKit). Aufruf (in mac/):
//   swift scripts/update-sign.swift keygen                 public key ausgeben (Schlüssel einmal anlegen)
//   swift scripts/update-sign.swift sign <build> <commit> <datei>   gibt "<sha256> <signatur>" aus
//   swift scripts/update-sign.swift verify <build> <commit> <datei> <signatur>
//   swift scripts/update-sign.swift lock                    bestehenden Schlüssel mit leerer Vertrauensliste neu anlegen
// Der private Schlüssel steht nur im Schlüsselbund, nie in Argumenten, Ausgabe oder Logs.
// Mit -T "" ist keine App vertrauenswürdig: macOS fragt beim Lesen nach (kein stilles Auslesen).
// Test-Override: TABY_UPDATE_KEY_SERVICE (Standard "taby-update-signing-key").
// Die Nachricht "<build>\n<commit>\n<sha256>" muss mit UpdateSignature.message in der App übereinstimmen.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let service = env["TABY_UPDATE_KEY_SERVICE"] ?? "taby-update-signing-key"
let account = "Taby"

func fail(_ text: String) -> Never {
  FileHandle.standardError.write(Data((text + "\n").utf8))
  exit(1)
}

/// Ruft /usr/bin/security auf. Stdin wird nur für `-i` gebraucht; stdout kommt zurück, stderr bleibt stumm.
func security(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String) {
  let process = Process()
  let output = Pipe()
  let input = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
  process.arguments = args
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.standardInput = input
  do { try process.run() } catch { return (1, "") }
  input.fileHandleForWriting.write(Data((stdin ?? "").utf8))
  try? input.fileHandleForWriting.close()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Gespeichertes Geheimnis (base64, nie ausgeben). nil, wenn kein Eintrag da ist.
func readStoredSecret() -> String? {
  let result = security(["find-generic-password", "-s", service, "-a", account, "-w"])
  return result.status == 0 && !result.out.isEmpty ? result.out : nil
}

/// Privater Schlüssel aus dem Schlüsselbund (nil, wenn keiner da ist).
func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
  guard let secret = readStoredSecret(), let raw = Data(base64Encoded: secret) else { return nil }
  return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

/// Legt einen Eintrag mit leerer Vertrauensliste (-T "") an. Das Geheimnis geht über stdin
/// an `security -i`, nie über argv. Ob der Eintrag danach da ist, prüft der Aufrufer.
func addSecret(service: String, secret: String) -> Bool {
  security(["-i"], stdin: "add-generic-password -U -T \"\" -s \(service) -a \(account) -w \(secret)\n").status == 0
}

func hasEntry(_ service: String) -> Bool {
  security(["find-generic-password", "-s", service, "-a", account]).status == 0
}

func message(build: String, commit: String, sha: String) -> Data {
  Data("\(build)\n\(commit)\n\(sha)".utf8)
}

func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Aufruf: keygen | lock | sign <build> <commit> <datei> | verify <build> <commit> <datei> <signatur>") }

switch command {
case "keygen":
  // Idempotent: vorhandenen Schlüssel nur ausgeben.
  if let existing = loadPrivateKey() {
    print(existing.publicKey.rawRepresentation.base64EncodedString())
    break
  }
  let key = Curve25519.Signing.PrivateKey()
  guard addSecret(service: service, secret: key.rawRepresentation.base64EncodedString()), hasEntry(service) else {
    fail("Der Update-Schlüssel konnte nicht im Schlüsselbund gespeichert werden.")
  }
  FileHandle.standardError.write(Data("Schlüssel im Schlüsselbund angelegt (ohne vertrauenswürdige App). Schlüssel sichern, sonst können keine Updates mehr signiert werden.\n".utf8))
  print(key.publicKey.rawRepresentation.base64EncodedString())

case "lock":
  // Bestehenden Eintrag neu anlegen, ohne dass eine App ihn still lesen kann. Reihenfolge:
  // Kopie unter Hilfsnamen, Original löschen, mit -T "" neu anlegen, Kopie entfernen.
  // Der Wert bleibt nur im Speicher und wird nie ausgegeben.
  guard let secret = readStoredSecret(), Data(base64Encoded: secret) != nil else {
    fail("Kein Update-Schlüssel zum Sperren gefunden.")
  }
  let copy = service + ".lock-tmp"
  guard addSecret(service: copy, secret: secret), hasEntry(copy) else {
    fail("Sperren abgebrochen: Kopie konnte nicht angelegt werden. Der Schlüssel ist unverändert.")
  }
  _ = security(["delete-generic-password", "-s", service, "-a", account])
  guard addSecret(service: service, secret: secret), hasEntry(service) else {
    fail("Sperren fehlgeschlagen. Die Kopie liegt noch unter „\(copy)“ im Schlüsselbund und muss von Hand zurückbenannt werden.")
  }
  _ = security(["delete-generic-password", "-s", copy, "-a", account])
  print("Update-Schlüssel gesperrt: macOS fragt jetzt bei jedem Lesen nach.")

case "sign":
  guard args.count == 4 else { fail("Aufruf: sign <build> <commit> <datei>") }
  guard let key = loadPrivateKey() else { fail("Kein Update-Schlüssel – einmal ./scripts/make-update-key.sh ausführen.") }
  guard let data = FileManager.default.contents(atPath: args[3]) else { fail("DMG nicht lesbar: \(args[3])") }
  let sha = sha256Hex(data)
  let signature = try! key.signature(for: message(build: args[1], commit: args[2], sha: sha))
  print("\(sha) \(signature.base64EncodedString())")

case "verify":
  guard args.count == 5 else { fail("Aufruf: verify <build> <commit> <datei> <signatur>") }
  guard let key = loadPrivateKey() else { fail("Kein Update-Schlüssel – einmal ./scripts/make-update-key.sh ausführen.") }
  guard let data = FileManager.default.contents(atPath: args[3]), let sig = Data(base64Encoded: args[4]) else {
    fail("Ungültige Datei oder Signatur")
  }
  let ok = key.publicKey.isValidSignature(sig, for: message(build: args[1], commit: args[2], sha: sha256Hex(data)))
  print(ok ? "OK: Signatur gültig" : "FEHLER: Signatur ungültig")
  exit(ok ? 0 : 1)

default:
  fail("Unbekannter Befehl: \(command)")
}
