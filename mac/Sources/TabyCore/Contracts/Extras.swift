import Foundation

public struct TabyTimer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  /// Lokale zonenlose Zeit des Ablaufs.
  public var endsAt: String
  public init(id: String, label: String, endsAt: String) { self.id = id; self.label = label; self.endsAt = endsAt }
}

public struct NowPlaying: Codable, Equatable, Sendable {
  public var title: String
  public var artist: String
  /// "Musik" oder "Spotify".
  public var app: String
  public var playing: Bool
  public init(title: String, artist: String, app: String, playing: Bool) {
    self.title = title; self.artist = artist; self.app = app; self.playing = playing
  }
}

public enum MediaCommand: String, Codable, Sendable { case playPause, next, previous }

public struct SearchHit: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case task, note, event, memory }
  public var id: String
  public var kind: Kind
  public var title: String
  /// Kurzer Ausschnitt mit dem Treffer, optional.
  public var snippet: String?
  /// Datum/Zeit (Fälligkeit, Termin), optional.
  public var date: String?
  public init(id: String, kind: Kind, title: String, snippet: String? = nil, date: String? = nil) {
    self.id = id; self.kind = kind; self.title = title; self.snippet = snippet; self.date = date
  }
}

public struct BackupInfo: Codable, Equatable, Identifiable, Sendable {
  /// Dateiname, z. B. "taby-2026-10-15-0830.sqlite".
  public var name: String
  public var createdAt: String
  public var sizeBytes: Int
  public var id: String { name }
  public init(name: String, createdAt: String, sizeBytes: Int) {
    self.name = name; self.createdAt = createdAt; self.sizeBytes = sizeBytes
  }
}
