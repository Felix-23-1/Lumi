// VERTRAG (nur Orchestrator ändert): Mods (Paket 3, docs/ROADMAP.md).
//
// Ein Mod ist ein Ordner `<Mods>/<id>/` mit `mod.json` (ModManifest) und bei
// Skript-Mods einer JavaScript-Datei. Zwei Arten:
// - shortcut: ruft einen Kurzbefehl der Apple-App „Kurzbefehle“ auf.
// - script:   JavaScript, eingesperrt (JavaScriptCore), nur mit den Rechten aus `permissions`.
// Ein Mod läuft nur, wenn der Nutzer ihn eingeschaltet und seine Rechte für
// genau diesen Inhalt (Hash von mod.json + Skript) freigegeben hat. Ändert sich
// der Inhalt, muss neu freigegeben werden.
import Foundation

public enum ModKind: String, Codable, Sendable {
  case shortcut, script
  /// Skill: Anleitung (`prompt`) + erlaubte Werkzeuge (`tools`), läuft als eingeschränkter Chat-Durchgang.
  case skill
}

/// Rechte für Skript-Mods. Format: "tasks.read", "tasks.write", "notes.read",
/// "notes.write", "calendar.read", "notify", "http:<domain>" (z. B. "http:api.open-meteo.com",
/// gilt für die Domain und ihre Subdomains, nur https).
public enum ModPermission {
  public static let known: Set<String> = ["tasks.read", "tasks.write", "notes.read", "notes.write", "calendar.read", "notify",
                                         "island.text", "habits.read", "habits.write", "focus", "timer",
                                         "messages.read", "mail.draft", "storage"]

  /// Deutsche Beschreibung für die Freigabe.
  public static func describe(_ p: String) -> String {
    switch p {
    case "tasks.read": return "Aufgaben lesen"
    case "tasks.write": return "Aufgaben anlegen und abhaken"
    case "notes.read": return "Notizen lesen"
    case "notes.write": return "Notizen anlegen"
    case "calendar.read": return "Termine lesen"
    case "notify": return "Benachrichtigungen zeigen"
    case "island.text": return "Kurztext in der Notch anzeigen (z. B. Countdown)"
    case "habits.read": return "Gewohnheiten lesen"
    case "habits.write": return "Gewohnheiten abhaken"
    case "focus": return "Fokus starten und beenden"
    case "timer": return "Wecker stellen"
    case "messages.read": return "Nachrichten lesen (Slack, Element, iMessage)"
    case "mail.draft": return "Mail-Entwürfe öffnen (senden nie selbst)"
    case "storage": return "Eigenen kleinen Speicher nutzen (max. 64 KB)"
    default:
      if p.hasPrefix("http:") { return "Internet: \(p.dropFirst(5)) abrufen" }
      return p
    }
  }
}

/// Wann ein Mod ohne Chat von selbst läuft.
public enum ModTrigger: String, Codable, Sendable, CaseIterable {
  case focusStarted, focusFinished, dayStarted, dayEnded
  /// Einmal pro Stunde (für Countdown-Anzeigen, Aufräum-Prüfungen).
  case hourly

  /// Deutsche Bezeichnung für die Oberfläche.
  public var label: String {
    switch self {
    case .focusStarted: "Fokus-Start"
    case .focusFinished: "Fokus-Ende"
    case .dayStarted: "Tagesstart"
    case .dayEnded: "Tagesabschluss"
    case .hourly: "Stündlich"
    }
  }
}

/// Werkzeug, das ein Mod dem Modell anbietet (Name im Modell: "mod_<id>").
public struct ModTool: Codable, Equatable, Sendable {
  public var description: String
  /// JSON-Schema der Argumente (Objekt).
  public var parameters: JSONValue
  public init(description: String, parameters: JSONValue = ["type": "object", "properties": [:]]) {
    self.description = description; self.parameters = parameters
  }
}

/// Zeitplan-Auslöser: jeden Tag (oder an bestimmten Wochentagen) zu einer Uhrzeit.
public struct ModSchedule: Codable, Equatable, Sendable {
  /// "HH:mm"
  public var time: String
  /// ISO-Wochentage 1 (Mo) … 7 (So); nil = jeden Tag.
  public var weekdays: [Int]?
  public init(time: String, weekdays: [Int]? = nil) { self.time = time; self.weekdays = weekdays }
}

/// Einstellung, die ein Mod deklariert; die Oberfläche zeigt sie, das Skript bekommt sie als `input.settings`.
public struct ModSetting: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case text, number, toggle }
  public var key: String
  public var label: String
  public var kind: Kind
  public var defaultValue: String?
  public init(key: String, label: String, kind: Kind = .text, defaultValue: String? = nil) {
    self.key = key; self.label = label; self.kind = kind; self.defaultValue = defaultValue
  }
}

public struct ModManifest: Codable, Equatable, Sendable {
  /// Kleinbuchstaben, Ziffern, "-" (3…40 Zeichen); auch Ordnername.
  public var id: String
  public var name: String
  public var description: String
  public var version: String
  public var author: String?
  public var kind: ModKind
  /// Nur shortcut: Name des Kurzbefehls.
  public var shortcutName: String?
  /// Nur script: Dateiname des Skripts im Mod-Ordner (Standard "main.js").
  /// Das Skript definiert `function run(input)`; Rückgabe (auch Promise) wird als Text/JSON übernommen.
  public var entry: String?
  public var tool: ModTool?
  public var triggers: [ModTrigger]
  public var permissions: [String]
  /// Zeitpläne (zusätzlich zu `triggers`).
  public var schedule: [ModSchedule]?
  /// Vom Nutzer einstellbare Werte.
  public var settings: [ModSetting]?
  /// Nur skill: Anleitung fürs Modell (Markdown).
  public var prompt: String?
  /// Nur skill: erlaubte Lumi-Werkzeuge (Namen); leer = nur lesende.
  public var tools: [String]?
  /// Nur skill: Chat-Befehl ohne „/“, z. B. "wochenplan".
  public var command: String?

  public init(id: String, name: String, description: String, version: String = "1.0", author: String? = nil,
              kind: ModKind, shortcutName: String? = nil, entry: String? = nil, tool: ModTool? = nil,
              triggers: [ModTrigger] = [], permissions: [String] = [], schedule: [ModSchedule]? = nil,
              settings: [ModSetting]? = nil, prompt: String? = nil, tools: [String]? = nil, command: String? = nil) {
    self.id = id; self.name = name; self.description = description; self.version = version
    self.author = author; self.kind = kind; self.shortcutName = shortcutName; self.entry = entry
    self.tool = tool; self.triggers = triggers; self.permissions = permissions
    self.schedule = schedule; self.settings = settings; self.prompt = prompt; self.tools = tools; self.command = command
  }
}

/// Ein Mod in der Bibliothek, wie die Oberfläche ihn sieht.
public struct ModInfo: Codable, Equatable, Identifiable, Sendable {
  public var manifest: ModManifest
  public var enabled: Bool
  /// true, wenn die aktuelle Fassung (Hash) freigegeben ist. Eingeschaltet + nicht freigegeben = läuft nicht.
  public var approved: Bool
  /// Skript-Inhalt (nur script) zur Ansicht vor der Freigabe.
  public var code: String?
  public var lastRunAt: String?
  public var lastError: String?
  public var id: String { manifest.id }

  /// Werte der Mod-Einstellungen (key → Wert); fehlende nehmen `defaultValue`.
  public var settingValues: [String: String]
  public init(manifest: ModManifest, enabled: Bool = false, approved: Bool = false, code: String? = nil,
              lastRunAt: String? = nil, lastError: String? = nil, settingValues: [String: String] = [:]) {
    self.manifest = manifest; self.enabled = enabled; self.approved = approved; self.code = code
    self.lastRunAt = lastRunAt; self.lastError = lastError; self.settingValues = settingValues
  }
}

/// Kurztext eines Mods für die Notch-Insel (z. B. Countdown), mit Ablaufzeit.
/// Lumi-eigene Hinweise (Termin, Fokus, Anzahl) haben Vorrang; es gilt immer
/// nur ein Mod-Text gleichzeitig (der zuletzt gesetzte).
public struct IslandMessage: Codable, Equatable, Sendable {
  /// Höchstens 40 Zeichen (wird gekürzt).
  public var text: String
  /// Lokale ISO-Zeit, bis zu der der Text gilt.
  public var until: String
  public var modId: String
  public init(text: String, until: String, modId: String) {
    self.text = String(text.prefix(40)); self.until = until; self.modId = modId
  }
}

/// Fertiger Mod aus der eingebauten Bibliothek (in Lumi mitgeliefert). Wird wie ein
/// Import installiert: ausgeschaltet und ungeprüft, bis der Nutzer ihn freigibt.
public struct CatalogMod: Equatable, Sendable, Identifiable {
  public var manifest: ModManifest
  /// JavaScript bei `.script`, sonst nil.
  public var code: String?
  public var id: String { manifest.id }
  public init(manifest: ModManifest, code: String? = nil) {
    self.manifest = manifest; self.code = code
  }
}
