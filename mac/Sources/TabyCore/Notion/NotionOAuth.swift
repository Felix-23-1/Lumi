// Paket 11: Notion-Anmeldung per OAuth (öffentliche Verbindung), als
// Alternative zum manuell eingefügten Internal-Token – nötig für Gäste, die
// selbst keinen Workspace-Admin um ein Token bitten können/wollen. Der Nutzer
// meldet sich im Browser mit seinem eigenen Notion-Account an und wählt dort
// selbst, welche Seiten er freigibt. Die Verbindung ist bei Notion mit der
// Weiterleitungs-URI `https://notion-callback` registriert; diese Seite gibt es
// nicht, der Browser zeigt nach der Freigabe „Seite nicht erreichbar“. Der Nutzer
// kopiert dann die Adresse aus der Browserzeile und fügt sie in Lumi ein
// (Paste-Flow, `verifiedCode(fromPasted:)`). Der `state` wird je Anmeldung zufällig
// erzeugt und beim Einfügen geprüft (Schutz gegen untergeschobene Rückrufe).
import Foundation

/// Fehler der Anmeldung mit deutscher Meldung für die Oberfläche.
public struct NotionOAuthError: Error, Equatable {
  public let message: String
  public init(message: String) { self.message = message }
}

public enum NotionOAuthConfig {
  /// Nicht geheim (steht ohnehin offen in der Anmelde-URL).
  public static let clientId = "3f8d872b-594c-81d4-9459-003791f2ff80"
  public static let redirectUri = "https://notion-callback"

  /// Das Client-Secret liegt NUR im Schlüsselbund – der Nutzer trägt es selbst
  /// per `security add-generic-password` ein, es läuft nie durch Lumi-Code,
  /// Logs oder Einstellungen.
  public static func clientSecretStore() -> ApiKeyStore {
    KeychainApiKeyStore(service: "notion-oauth-client-secret", account: "Taby")
  }

  /// `state` der laufenden Anmeldung (Zufallswert, nur im Speicher). Der Rückruf muss ihn zurückgeben.
  private static let pendingState = LockedBox<String?>(nil)

  /// Neue Anmelde-URL mit frischem `state`. Ein früherer Versuch wird damit ungültig.
  public static func makeAuthorizeURL() -> URL {
    let state = UUID().uuidString
    pendingState.value = state
    var c = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
    c.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectUri),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "owner", value: "user"),
      URLQueryItem(name: "state", value: state),
    ]
    return c.url!
  }

  /// Zieht den Code aus dem eingefügten Text: entweder die ganze Adresse
  /// (`https://notion-callback?code=…`) oder der nackte Code. Fehlt er, bei
  /// einem Fehler (`error=…`) oder bei Freitext liefert es nil.
  public static func code(fromPasted raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if let url = URL(string: text), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let items = comps.queryItems {
      if let item = items.first(where: { $0.name == "code" }) {
        let value = item.value ?? ""
        return value.isEmpty ? nil : value
      }
      if items.contains(where: { $0.name == "error" }) { return nil }
    }
    if text.contains(where: \.isWhitespace) || text.contains("://") { return nil }
    return text
  }

  /// Wie `code(fromPasted:)`, aber nur für den Rückruf dieser Anmeldung: der `state` der
  /// eingefügten Adresse muss zum gemerkten Wert passen. Verbraucht den `state` (einmalig).
  public static func verifiedCode(fromPasted raw: String) throws -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let code = code(fromPasted: text) else {
      throw NotionOAuthError(message: "Keine gültige Adresse eingefügt. Bitte die Adresse aus der Browserzeile kopieren.")
    }
    let items = URL(string: text).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    let returned = items.first(where: { $0.name == "state" })?.value
    guard let expected = pendingState.value, let returned, returned == expected else {
      throw NotionOAuthError(message: "Die eingefügte Adresse gehört nicht zu dieser Anmeldung. Bitte „Mit Notion anmelden“ erneut tippen.")
    }
    pendingState.value = nil
    return code
  }

  /// Tauscht den Code aus dem Rückruf gegen ein Zugriffs-Token. `secrets` ist
  /// injizierbar (wie `CoreServices.Options.calendarSecrets`), damit Prüfungen
  /// nicht den echten Schlüsselbund anfassen müssen.
  public static func exchangeCode(_ code: String, secrets: ApiKeyStore = NotionOAuthConfig.clientSecretStore(),
                                  session: URLSession = .shared) async throws -> String {
    guard let secret = (try? secrets.get()) ?? nil, !secret.isEmpty else {
      throw CalendarError.unreachable("Kein Notion-OAuth-Client-Secret im Schlüsselbund hinterlegt.")
    }
    let basic = Data("\(clientId):\(secret)".utf8).base64EncodedString()
    var req = URLRequest(url: URL(string: "\(NotionTaskSource.baseURL)/oauth/token")!)
    req.httpMethod = "POST"
    req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    req.setValue(NotionTaskSource.apiVersion, forHTTPHeaderField: "Notion-Version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: JSONValue = ["grant_type": "authorization_code", "code": .string(code), "redirect_uri": .string(redirectUri)]
    req.httpBody = Data(body.jsonString().utf8)
    let (data, http) = try await CalendarSupport.send(session, req, label: "Notion-Anmeldung fehlgeschlagen")
    let responseBody = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    guard (200..<300).contains(http.statusCode), let token = responseBody["access_token"]?.stringValue else {
      let detail = responseBody["message"]?.stringValue ?? "\(http.statusCode)"
      throw CalendarError.unreachable("Notion-Anmeldung fehlgeschlagen: \(detail)")
    }
    return token
  }
}
