// Spotify-Anmeldung: Authorization Code mit PKCE (ohne Client-Secret).
// Der Browser schickt die Antwort an einen Loopback-Listener auf 127.0.0.1:8898 (genau eine Anfrage).
// Die Tokens selbst liegen in SpotifyProvider; hier nur PKCE, Formulare und der Listener.
import CryptoKit
import Foundation
import Network

/// Fehler mit Code und deutscher Meldung. Die Meldung enthält nie Token, Codes oder Verifier.
struct SpotifyFailure: Error, CustomStringConvertible {
  let code: String
  let message: String
  init(_ code: String, _ message: String) { self.code = code; self.message = message }
  var description: String { message }
}

/// Antwort des Browsers auf /callback.
struct SpotifyCallback: Sendable {
  let code: String
  let state: String
}

enum SpotifyPKCE {
  static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// Zufälliger Text aus `bytes` Zufallsbytes, base64url ohne Auffüllung.
  static func randomToken(bytes: Int) -> String {
    base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }))
  }

  /// S256-Challenge: base64url(SHA-256(verifier)).
  static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  /// Kodiert einen Formularwert streng (nur unreservierte Zeichen bleiben stehen).
  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  static func formBody(_ pairs: [(String, String)]) -> Data {
    Data(pairs.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&").utf8)
  }
}

/// Loopback-Listener: wartet auf genau eine Anfrage an /callback und antwortet mit einer Seite.
enum SpotifyLoopback {
  static let port: NWEndpoint.Port = 8898
  static let timeout: TimeInterval = 180

  static let successPage = "Lumi ist verbunden – du kannst das Fenster schließen."
  static let deniedPage = "Anmeldung abgebrochen – du kannst das Fenster schließen."

  /// Startet den Listener, ruft `onReady` (Browser öffnen) und wartet auf die Antwort.
  static func receive(onReady: @escaping @Sendable () -> Void) async throws -> SpotifyCallback {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SpotifyCallback, Error>) in
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
      guard let listener = try? NWListener(using: params, on: port) else {
        cont.resume(throwing: SpotifyFailure("port", "Der Anmelde-Port 8898 ist belegt. Schließe das Programm, das ihn nutzt, und versuch es erneut."))
        return
      }
      let once = SpotifyOnceGate()
      let finish: @Sendable (Result<SpotifyCallback, Error>) -> Void = { result in
        guard once.take() else { return }
        listener.cancel()
        cont.resume(with: result)
      }
      listener.newConnectionHandler = { conn in
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
          let target = requestTarget(data)
          guard let (path, query) = target, path == "/callback" else {
            // Fremde Anfragen (z. B. /favicon.ico) zählen nicht als Antwort.
            send(conn, status: "404 Not Found", body: "Nicht gefunden.")
            return
          }
          let items = query
          if items.contains(where: { $0.name == "error" }) {
            send(conn, status: "200 OK", body: deniedPage) { finish(.failure(SpotifyFailure("denied", "Die Anmeldung bei Spotify wurde abgebrochen."))) }
            return
          }
          guard let code = items.first(where: { $0.name == "code" })?.value,
                let state = items.first(where: { $0.name == "state" })?.value else {
            send(conn, status: "400 Bad Request", body: deniedPage) { finish(.failure(SpotifyFailure("callback", "Die Antwort von Spotify ist unvollständig."))) }
            return
          }
          send(conn, status: "200 OK", body: successPage) { finish(.success(SpotifyCallback(code: code, state: state))) }
        }
      }
      listener.stateUpdateHandler = { state in
        if case .failed = state {
          finish(.failure(SpotifyFailure("port", "Der Anmelde-Port 8898 konnte nicht geöffnet werden.")))
        }
      }
      listener.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        finish(.failure(SpotifyFailure("timeout", "Die Anmeldung hat zu lange gedauert. Bitte erneut versuchen.")))
      }
      onReady()
    }
  }

  /// Pfad und Abfrage aus der ersten Zeile („GET /callback?code=…&state=… HTTP/1.1“).
  static func requestTarget(_ data: Data?) -> (String, [URLQueryItem])? {
    guard let data, let text = String(data: data, encoding: .utf8),
          let line = text.components(separatedBy: "\r\n").first else { return nil }
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
          let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
    return (comps.path, comps.queryItems ?? [])
  }

  private static func send(_ conn: NWConnection, status: String, body: String, then: (@Sendable () -> Void)? = nil) {
    let html = "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><title>Lumi</title></head>"
      + "<body style=\"font-family:-apple-system,sans-serif;padding:40px\"><p>\(body)</p></body></html>"
    let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
      conn.cancel()
      then?()
    })
  }
}

/// Genau einmal durchlassen (Antwort, Zeitablauf und Fehler können gleichzeitig eintreffen).
final class SpotifyOnceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false
  func take() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}
