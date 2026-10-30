// VERTRAG (nur Orchestrator ändert): Schnittstelle Hülle (Shell/) ↔ Ansichten (Views/).
//
// Die Hülle zeigt die Reiterleiste, das Maskottchen und den Inhaltsbereich.
// In den Inhaltsbereich setzt sie `TabContentView(tab:)` bzw. bei offener
// Tagesstart-Frage `DayStartView()` — beide liefert Views/.
//
// Regeln für den Inhaltsbereich:
// - Breite: fest `TabLayout.contentWidth` (die Hülle setzt sie).
// - Höhe: natürliche Höhe der Ansicht. Die Hülle misst sie und federt die
//   Insel auf diese Höhe (Coucou-Prinzip), begrenzt auf
//   `TabLayout.minContentHeight ... TabLayout.maxContentHeight`.
//   Längere Listen scrollen daher *innerhalb* der Ansicht
//   (ScrollView mit `.frame(maxHeight:)`), Eingabefelder bleiben sichtbar.
// - Zustand/Aktionen über `@EnvironmentObject var model: AppModel`.
// - Rückmeldungen ans Maskottchen über `model.react(...)` bzw. `model.isThinking`.
import SwiftUI
import TabyCore

public enum TabyTab: String, CaseIterable, Identifiable, Sendable {
  case today, chat, messages, mail, agents, tasks, notes, calendar, music, mods, network, notion, settings

  public var id: String { rawValue }

  /// Deutscher Titel (Seitenspalte, Barrierefreiheit).
  public var title: String {
    switch self {
    case .today: "Heute"
    case .chat: "Chat"
    case .messages: "Nachrichten"
    case .mail: "Mail"
    case .agents: "Agenten"
    case .tasks: "Aufgaben"
    case .notes: "Notizen"
    case .calendar: "Kalender"
    case .music: "Musik"
    case .mods: "Mods"
    case .network: "Netzwerk"
    case .notion: "Notion"
    case .settings: "Einstellungen"
    }
  }

  /// SF-Symbol für die Reiterleiste.
  public var symbol: String {
    switch self {
    case .today: "house.fill"
    case .chat: "bubble.left.fill"
    case .messages: "bubble.left.and.bubble.right"
    case .mail: "envelope"
    case .agents: "cpu"
    case .tasks: "checkmark.circle"
    case .notes: "note.text"
    case .calendar: "calendar"
    case .music: "music.note"
    case .mods: "puzzlepiece.extension"
    case .network: "network"
    case .notion: "doc.richtext"
    case .settings: "gearshape"
    }
  }
}

public enum TabLayout {
  public static let contentWidth: CGFloat = 470
  public static let minContentHeight: CGFloat = 130
  public static let maxContentHeight: CGFloat = 380
}

extension TabyTab {
  /// Optionale Module erscheinen erst, wenn sie in den Einstellungen an sind.
  public func isVisible(_ settings: TabySettings?) -> Bool {
    switch self {
    case .network: settings?.networkToolsEnabled == true
    case .messages: settings?.messengerEnabled == true
    case .notion: settings?.notionTasksEnabled == true
    case .mail: settings?.mailEnabled == true
    default: true
    }
  }
}
