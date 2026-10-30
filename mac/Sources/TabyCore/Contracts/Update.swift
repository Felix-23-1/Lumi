import Foundation

/// Veröffentlichte Lumi-Version (aus `download/version.json`).
public struct AppUpdate: Codable, Equatable, Sendable {
  /// Kurzer Git-Commit, aus dem die DMG gebaut wurde.
  public var commit: String
  /// Lokale zonenlose Zeit der Veröffentlichung.
  public var date: String
  /// Commit der laufenden App (leer = unbekannt, z. B. Entwickler-Build).
  public var currentCommit: String
  /// Fortlaufende Build-Nummer (`git rev-list --count HEAD`); nur eine höhere gilt als Update.
  public var build: Int
  public var currentBuild: Int
  /// Fortschritt des laufenden Downloads in Prozent (nil = kein Download).
  public var downloadPercent: Int?
  /// Was ist neu (zwei, drei Sätze aus `version.json`); nil = keine Angabe.
  public var notes: String?
  public init(commit: String, date: String, currentCommit: String, build: Int = 0, currentBuild: Int = 0,
              downloadPercent: Int? = nil, notes: String? = nil) {
    self.commit = commit; self.date = date; self.currentCommit = currentCommit
    self.build = build; self.currentBuild = currentBuild; self.downloadPercent = downloadPercent
    self.notes = notes
  }

  /// Anzeigename der Version: "2.<Build>" (Build = Anzahl der Commits), ohne Build "2.0".
  public static func versionName(build: Int) -> String { build > 0 ? "2.\(build)" : "2.0" }
  public var versionName: String { Self.versionName(build: build) }
  public var currentVersionName: String { Self.versionName(build: currentBuild) }

  public static let defaultSource = "https://github.com/Felix-23-1/Lumi"
}
