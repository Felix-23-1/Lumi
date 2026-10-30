// Seiten der Einstellungen. Die Seitenleiste im eigenen Fenster und die Menüs in der Notch nutzen dieselben Seiten.
// „Erweitert“ blendet die zweite Gruppe nur ein, wenn der Schalter in der Seitenleiste an ist.
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
  case general, notch, model, accounts, tasks, rhythm, assistant, privacy
  case connections, music, network, connect, jobs, shortcuts, updates
  var id: String { rawValue }
  /// Seite, die beim Öffnen gewählt wird (z. B. aus dem Chat zum Datenschutz); danach leer.
  @MainActor static var requested: SettingsPage?
  /// Löst aus, wenn Einstellungen schon offen sind und eine Seite gewünscht wird (Menüleiste).
  static let openNotification = Notification.Name("taby.settings.open")
  /// Grundseiten (immer sichtbar), in Anzeigeordnung.
  static let sections: [(label: String, pages: [SettingsPage])] = [
    ("Lumi", [.general, .notch, .model, .accounts, .connections, .music, .tasks, .rhythm, .assistant, .privacy, .updates]),
  ]
  /// Erweiterte Seiten, nur mit „Erweitert anzeigen“.
  static let advancedSections: [(label: String, pages: [SettingsPage])] = [
    ("Erweitert", [.network, .connect, .jobs, .shortcuts]),
  ]
  var isAdvanced: Bool { Self.advancedSections.contains { $0.pages.contains(self) } }
  static func visibleSections(advanced: Bool) -> [(label: String, pages: [SettingsPage])] {
    advanced ? sections + advancedSections : sections
  }

  var title: String {
    switch self {
    case .general: "Allgemein"
    case .notch: "Notch"
    case .model: "KI-Modell"
    case .accounts: "Kalender & Konten"
    case .tasks: "Aufgaben"
    case .rhythm: "Tagesablauf"
    case .assistant: "Stimme & Persönlichkeit"
    case .privacy: "Datenschutz"
    case .connections: "Verbindungen"
    case .music: "Musik"
    case .network: "Netzwerk"
    case .connect: "Export & Schnittstellen"
    case .jobs: "Aufträge"
    case .shortcuts: "Tastenkürzel"
    case .updates: "Updates"
    }
  }

  /// Ein Satz unter der Überschrift jeder Seite.
  var summary: String {
    switch self {
    case .general: "Start, Chatverlauf, Reiter in der Notch und Sicherungen."
    case .notch: "Was die geschlossene Notch zeigt: Wohnort, eigener Text und durchrollende Zeilen."
    case .model: "Welches KI-Modell Lumi nutzt, mit welchem Schlüssel und was es kostet."
    case .accounts: "Kalender, Apple Erinnerungen, Notion-Aufgaben und Mail: woher Lumi Termine und Aufgaben holt."
    case .tasks: "Kategorien für Aufgaben und Ordner: eigene Namen, Symbole und Reihenfolge."
    case .rhythm: "Wann Lumi plant, dich am Abend fragt und wann Fokus und „Nicht stören“ gelten."
    case .assistant: "Stimme, Persönlichkeit, Vorgaben und was Lumi sich merkt."
    case .privacy: "Was Lumi speichert, wohin Daten gehen und was im Protokoll steht."
    case .connections: "Alle Dienste auf einen Blick: verbunden, aus oder mit Problem."
    case .music: "Spotify verbinden, Liedtext und Effekt für die Musikseite."
    case .network: "Netzwerk-Werkzeuge und der Wächter für neue Geräte und Ausfälle."
    case .connect: "Markdown-Export, Schnittstelle für andere KI-Programme und fremde MCP-Server."
    case .jobs: "Geplante Aufträge, die Lumi zu festen Zeiten ausführt."
    case .shortcuts: "Tastenkürzel, mit denen du Lumi von überall bedienst."
    case .updates: "Lumi auf die neueste Version bringen."
    }
  }

  var symbol: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .notch: "menubar.rectangle"
    case .model: "cpu"
    case .accounts: "calendar"
    case .tasks: "checklist"
    case .rhythm: "moon.stars"
    case .assistant: "person.wave.2"
    case .privacy: "hand.raised"
    case .connections: "link"
    case .music: "music.note"
    case .network: "network"
    case .connect: "point.3.connected.trianglepath.dotted"
    case .jobs: "clock.arrow.circlepath"
    case .shortcuts: "command"
    case .updates: "arrow.down.circle"
    }
  }
}

/// Einstieg aus der Menüleiste: wählt die Seite, auch wenn das Einstellungsfenster schon offen ist.
public enum SettingsEntry {
  @MainActor public static func showUpdates() { show(.updates) }

  @MainActor static func show(_ page: SettingsPage) {
    SettingsPage.requested = page
    NotificationCenter.default.post(name: SettingsPage.openNotification, object: nil)
  }
}

/// Wo die Einstellungen stehen: kompakt in der Notch oder im eigenen Fenster mit Seitenleiste.
enum SettingsLayout {
  case compact, window
}
