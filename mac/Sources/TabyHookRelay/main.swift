// taby-hook-relay: wird von Claude Codes PermissionRequest-Hook gestartet
// (Port von resources/taby-hook-relay.cjs, docs/decisions/0005-agents-hooks.md).
//
//   taby-hook-relay <socket-pfad>
//
// Liest das Hook-Eingabe-JSON von stdin, schickt es als eine Zeile an den
// Lumi-Socket, wartet auf Tabys Antwortzeile und gibt sie auf stdout aus.
// Ist Lumi nicht erreichbar oder schließt Lumi ohne Antwort (Timeout,
// verdrängte Anfrage), gibt es KEINE Ausgabe und Exit 0 → Claude Code fragt
// normal im Terminal. Bewusst ohne Abhängigkeit zu TabyCore (kleines Binary).
import Darwin
import Foundation

/// Sicherheitsfrist für Freigabe-Anfragen knapp unter Claude Codes Hook-Timeout (120 s).
let receiveTimeoutSeconds = 118
/// Meldungen (Notification, Stop) bekommen nie eine Antwort; Lumi schließt sofort.
let noticeReceiveTimeoutSeconds = 3

func quietExit() -> Never { exit(0) }

let args = CommandLine.arguments
guard args.count >= 2, !args[1].isEmpty else { quietExit() }
let socketPath = args[1]

let input = FileHandle.standardInput.readDataToEndOfFile()
let trimmed = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { quietExit() }

// hook_event_name bestimmt die Frist; ohne Angabe gilt die Freigabe-Frist.
var timeoutSeconds = receiveTimeoutSeconds
if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
   let event = obj["hook_event_name"] as? String, event != "PermissionRequest" {
  timeoutSeconds = noticeReceiveTimeoutSeconds
}
// Claude Code liefert kompaktes JSON; Zeilenumbrüche innerhalb wären
// Protokollbruch → in Leerzeichen wandeln (in JSON außerhalb von Strings gleichwertig,
// innerhalb von Strings sind sie ohnehin als \n maskiert).
let line = trimmed.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") + "\n"

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { quietExit() }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
  buf.copyBytes(from: pathBytes)
  buf[pathBytes.count] = 0
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { quietExit() }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

let connected = withUnsafePointer(to: &addr) {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { close(fd); quietExit() }  // Lumi läuft nicht

let out = Array(line.utf8)
var sent = 0
while sent < out.count {
  let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  if n <= 0 { if errno == EINTR { continue }; close(fd); quietExit() }
  sent += n
}
// Hinweis: keine Schreibseiten-Halbschließung — Lumi wertet EOF als „Relay beendet“.

var response = [UInt8]()
var buf = [UInt8](repeating: 0, count: 4096)
while true {
  let n = read(fd, &buf, buf.count)
  if n < 0 && errno == EINTR { continue }
  if n <= 0 { break }  // EOF, Fehler oder Zeitüberschreitung
  response.append(contentsOf: buf[0..<n])
  if response.contains(0x0A) { break }
}
close(fd)

guard let nl = response.firstIndex(of: 0x0A) else { quietExit() }  // keine Entscheidung
FileHandle.standardOutput.write(Data(response[..<nl]))
exit(0)
