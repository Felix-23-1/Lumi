import Foundation

public struct ContactCard: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var organization: String?
  public var emails: [String]
  public var phones: [String]
  /// "MM-DD" oder "YYYY-MM-DD", nil = keiner eingetragen.
  public var birthday: String?
  public init(id: String, name: String, organization: String? = nil, emails: [String] = [], phones: [String] = [],
              birthday: String? = nil) {
    self.id = id; self.name = name; self.organization = organization; self.emails = emails; self.phones = phones
    self.birthday = birthday
  }
}

public struct FileHit: Codable, Equatable, Identifiable, Sendable {
  public var path: String
  public var name: String
  /// Lokale Zeit der letzten Änderung.
  public var modifiedAt: String?
  /// Art in Worten, z. B. "PDF-Dokument".
  public var kind: String?
  public var id: String { path }
  public init(path: String, name: String, modifiedAt: String? = nil, kind: String? = nil) {
    self.path = path; self.name = name; self.modifiedAt = modifiedAt; self.kind = kind
  }
}

public struct CapturedContext: Codable, Equatable, Sendable {
  /// Name der App, aus der der Kontext kommt ("Safari", "Mail", "Finder" …).
  public var app: String
  public var title: String
  /// Link zurück (https-Seite, message://-Mail, file://-Datei), optional.
  public var url: String?
  /// Markierter Text oder Auszug, optional.
  public var text: String?
  public init(app: String, title: String, url: String? = nil, text: String? = nil) {
    self.app = app; self.title = title; self.url = url; self.text = text
  }
}

public enum CaptureTarget: String, Codable, Sendable { case note, task, readLater }

public struct InboxItem: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case needsReply, waiting }
  public var id: String
  public var kind: Kind
  /// "Mail", "Slack", "Element", "iMessage".
  public var channel: String
  public var title: String
  public var from: String
  /// Lokale Zeit der letzten Nachricht.
  public var at: String
  public init(id: String, kind: Kind, channel: String, title: String, from: String, at: String) {
    self.id = id; self.kind = kind; self.channel = channel; self.title = title; self.from = from; self.at = at
  }
}
