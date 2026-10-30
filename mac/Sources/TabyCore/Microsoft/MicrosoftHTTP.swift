// Microsoft (Outlook, Teams): die einzige Stelle, die Netz zu Microsoft öffnet.
// Erlaubt sind nur HTTPS-Adressen auf login.microsoftonline.com und graph.microsoft.com;
// alles andere wird abgewiesen, auch Weiterleitungen. Fehlertexte sind deutsch und
// enthalten nie Tokens oder Codes außer dem Fehlercode von Microsoft.
import Foundation

/// Fehler mit fertigem deutschen Text für die Oberfläche.
public struct MicrosoftFailure: Error, LocalizedError, Equatable, Sendable {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

enum MicrosoftHTTP {
  static let loginHost = "login.microsoftonline.com"
  static let graphHost = "graph.microsoft.com"
  /// Obergrenze für eine Antwort von Graph oder Anmeldung.
  static let maxAnswerBytes = 5_000_000
  static let consentText = "Deine IT muss Lumi einmal freigeben: Kalender, Chats und Status."

  static func allowed(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
    return host == loginHost || host == graphHost
  }

  static func checkedURL(_ url: URL?) throws -> URL {
    guard let url, allowed(url) else {
      throw MicrosoftFailure(message: "Microsoft: Die Adresse wird nicht erlaubt. Abgebrochen.")
    }
    return url
  }

  /// Weiterleitungen nur auf erlaubte Hosts; sonst bleibt die Weiterleitung die Antwort.
  private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
      completionHandler(MicrosoftHTTP.allowed(request.url) ? request : nil)
    }
  }
  private static let redirects = RedirectGuard()

  /// Einzige HTTP-Funktion für Microsoft. Gibt jede Antwort zurück (auch 4xx); der Aufrufer wertet den Status aus.
  static func send(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var req = request
    req.url = try checkedURL(request.url)
    req.timeoutInterval = 20
    let data: Data, response: URLResponse
    do {
      (data, response) = try await session.data(for: req, delegate: redirects)
    } catch let e as URLError {
      // Abgebrochen (Abmeldung, Abbrechen): kein Fehlertext, der Aufrufer wertet den Abbruch aus.
      if e.code == .cancelled { throw CancellationError() }
      if e.code == .timedOut { throw MicrosoftFailure(message: "Microsoft antwortet nicht (Zeitüberschreitung).") }
      throw MicrosoftFailure(message: "Microsoft ist gerade nicht erreichbar. Prüfe die Internetverbindung.")
    }
    guard let http = response as? HTTPURLResponse else {
      throw MicrosoftFailure(message: "Microsoft hat keine Antwort geschickt.")
    }
    guard data.count <= maxAnswerBytes else {
      throw MicrosoftFailure(message: "Microsoft hat eine zu große Antwort geschickt (mehr als 5 MB). Abgebrochen.")
    }
    return (data, http)
  }

  /// Graph-Fehler nach HTTP-Status (ohne Antworttext).
  static func graphFailure(_ status: Int) -> MicrosoftFailure {
    switch status {
    case 401: return MicrosoftFailure(message: "Die Microsoft-Anmeldung ist abgelaufen. Bitte unter Verbindungen → Microsoft neu anmelden.")
    case 403: return MicrosoftFailure(message: "Microsoft verweigert den Zugriff (403). \(consentText)")
    case 404: return MicrosoftFailure(message: "Microsoft kennt diesen Eintrag nicht (404).")
    case 429: return MicrosoftFailure(message: "Microsoft bremst gerade. Bitte gleich erneut versuchen.")
    default: return MicrosoftFailure(message: "Microsoft meldet einen Fehler (\(status)).")
    }
  }

  /// Fehler des Anmelde-Endpunkts. Nur der Fehlercode von Microsoft geht in den Text.
  static func oauthFailure(_ json: [String: Any]?) -> MicrosoftFailure {
    let code = (json?["error"] as? String) ?? ""
    let desc = (json?["error_description"] as? String) ?? ""
    if desc.contains("AADSTS65001") { return MicrosoftFailure(message: consentText) }
    if code == "invalid_client" || desc.contains("AADSTS700016") {
      return MicrosoftFailure(message: "Die Client-ID passt nicht. Prüfe sie unter Verbindungen → Microsoft.")
    }
    return MicrosoftFailure(message: "Microsoft-Anmeldung fehlgeschlagen (\(code.isEmpty ? "unbekannt" : code)).")
  }

  static func json(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// Formularkodierte Anfrage (für den Anmelde-Endpunkt). Strikt kodiert: `+`, `&`, `=` werden escaped.
  static func form(_ url: URL, _ pairs: [(String, String)]) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let body = pairs.map { key, value in
      "\(key.addingPercentEncoding(withAllowedCharacters: safe) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: safe) ?? value)"
    }.joined(separator: "&")
    req.httpBody = Data(body.utf8)
    return req
  }
}
