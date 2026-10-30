// Wächter: meldet Internet-Abbrüche, Rückkehr und neue unbekannte Geräte.
// Reine Zustandsmaschine ohne Systemaufrufe. Die erste Momentaufnahme ist nur
// Ausgangspunkt und löst nichts aus.
import Foundation

public struct NetworkWatch: Sendable {
  /// Letzter bekannter Online-Zustand; nil vor der ersten Momentaufnahme.
  public private(set) var lastOnline: Bool?
  /// true, sobald die Verbindung nach dem Ausgangspunkt einmal weg war.
  public private(set) var hasDropped = false

  public init() {}

  /// Bewertet eine Momentaufnahme. `newUnknown` sind neu entdeckte, unbekannte Geräte.
  /// Beim ersten Aufruf keine Benachrichtigungen (Ausgangspunkt).
  public mutating func evaluate(online: Bool, newUnknown: [NetworkDevice]) -> [TabyNotification] {
    defer { lastOnline = online }
    guard let previous = lastOnline else { return [] }

    var out: [TabyNotification] = []
    if previous && !online {
      hasDropped = true
      out.append(TabyNotification(title: "Internet weg",
                                  body: "Dieser Mac hat gerade keine Verbindung ins Internet."))
    } else if !previous && online && hasDropped {
      out.append(TabyNotification(title: "Internet wieder da",
                                  body: "Die Verbindung ins Internet steht wieder."))
    }

    for device in newUnknown {
      out.append(TabyNotification(title: "Neues Gerät im WLAN", body: Self.deviceLine(device)))
    }
    return out
  }

  /// "Raspberry Pi (192.168.178.40)"; ohne Namen zählt der Hersteller, sonst "Unbekanntes Gerät".
  static func deviceLine(_ device: NetworkDevice) -> String {
    let label = [device.name, device.vendor].compactMap { $0 }.first { !$0.isEmpty } ?? "Unbekanntes Gerät"
    return "\(label) (\(device.ip))"
  }
}
