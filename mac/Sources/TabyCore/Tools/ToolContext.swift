// Kontext eines Werkzeugaufrufs (Port von src/main/tools/context.ts) und
// JSON-Hilfen für Ergebnisse.
import Foundation

public struct ToolContext {
  public var store: Store
  public var clock: Clock
  /// `.readOnly` sperrt update_*, delete_*, add_event usw. im Code (ToolRegistry).
  public var mode: JobMode
  public var actor: ActionActor
  public var calendar: ToolCalendarAccess
  /// Dienste außerhalb des Speichers (Nachrichten, Fokus, Tagesplan). nil = nicht verbunden.
  public var services: AssistantToolServices?

  /// Ohne `calendar` nur das lokale Modul; ohne `clock` die Uhr des Speichers.
  public init(store: Store, calendar: ToolCalendarAccess? = nil, mode: JobMode = .standard,
              actor: ActionActor = .assistant, clock: Clock? = nil, services: AssistantToolServices? = nil) {
    self.store = store
    self.clock = clock ?? store.clock
    self.mode = mode
    self.actor = actor
    self.calendar = calendar ?? ProviderCalendarAccess.localOnly(store)
    self.services = services
  }
}

public enum ToolJSON {
  /// Codable-Wert → JSONValue (nil-Felder entfallen wie `undefined` in TS).
  public static func encode<T: Encodable>(_ value: T) -> JSONValue {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(value),
          let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
    return v
  }

  /// JSONValue → Codable-Wert (nil bei unpassender Form).
  public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  public static func ok(_ fields: [String: JSONValue] = [:]) -> JSONValue {
    var o = fields
    o["ok"] = true
    return .object(o)
  }

  public static func failure(code: String, error: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    var o = extra
    o["ok"] = false
    o["code"] = .string(code)
    o["error"] = .string(error)
    return .object(o)
  }
}
