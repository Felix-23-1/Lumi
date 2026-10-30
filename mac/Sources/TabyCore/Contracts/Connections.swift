import Foundation

/// Netzlaufwerk (SMB) auf einem NAS oder Server. Das Passwort liegt nur im Schlüsselbund.
public struct NetworkShare: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  /// Adresse, z. B. "smb://nas.local/Dokumente".
  public var url: String
  public var user: String
  /// Beim Start von Lumi automatisch verbinden.
  public var autoMount: Bool
  /// Unterordner der Freigabe (relativ zum Einhängepunkt), die Lumi durchsuchen darf. Leer = nichts.
  public var searchFolders: [String]
  public init(id: String, name: String, url: String, user: String = "", autoMount: Bool = false,
              searchFolders: [String] = []) {
    self.id = id; self.name = name; self.url = url; self.user = user
    self.autoMount = autoMount; self.searchFolders = searchFolders
  }
}

/// Zustand eines Netzlaufwerks.
public struct ShareState: Codable, Equatable, Sendable {
  public var mounted: Bool
  /// Einhängepunkt, z. B. "/Volumes/Dokumente".
  public var mountPath: String?
  /// Letzter Fehler in Alltagssprache.
  public var error: String?
  public init(mounted: Bool = false, mountPath: String? = nil, error: String? = nil) {
    self.mounted = mounted; self.mountPath = mountPath; self.error = error
  }
}

/// Ergebnis der Geheimnis-Suche („such mir das Passwort von …“). Der Wert selbst steht nie hier:
/// er geht in die Zwischenablage (löscht sich nach 60 s), im Chat und Protokoll steht nur die Fundstelle.
public struct SecretLookup: Codable, Equatable, Sendable {
  /// Datei, in der es steht (Anzeigename).
  public var source: String
  public var line: Int
  /// In die Zwischenablage kopiert.
  public var copied: Bool
  public init(source: String, line: Int, copied: Bool) { self.source = source; self.line = line; self.copied = copied }
}

/// Gerätecode-Anmeldung bei Microsoft: Der Nutzer öffnet `verificationUrl` und gibt `userCode` ein.
public struct MicrosoftSignIn: Codable, Equatable, Sendable {
  public var userCode: String
  public var verificationUrl: String
  public var expiresInSeconds: Int
  public init(userCode: String, verificationUrl: String, expiresInSeconds: Int) {
    self.userCode = userCode; self.verificationUrl = verificationUrl; self.expiresInSeconds = expiresInSeconds
  }
}
