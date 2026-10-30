// Inhalt je Reiter (Vertrag mit der Hülle: Contracts/Tabs.swift).
// Feste Breite TabLayout.contentWidth, natürliche Höhe; lange Listen
// scrollen innerhalb der Ansicht.
import SwiftUI
import TabyCore

public struct TabContentView: View {
  public let tab: TabyTab
  /// Nur für Snapshots/Prüfungen: fester Zustand statt `model.state`.
  let preview: AppState?
  @EnvironmentObject private var model: AppModel

  public init(tab: TabyTab) {
    self.tab = tab
    preview = nil
  }

  init(tab: TabyTab, preview: AppState?) {
    self.tab = tab
    self.preview = preview
  }

  public var body: some View {
    let state = preview ?? model.state ?? AppState()
    Group {
      switch tab {
      case .today: TodayView(state: state)
      case .chat: ChatView(state: state)
      case .mail: MailView(mail: state.mail)
      case .agents: AgentsView()
      case .tasks: TasksView(tasks: state.tasks, notionLinks: state.notionSourceLinks, notes: state.notes)
      case .notes: NotesView(notes: state.notes, tasks: state.tasks)
      case .calendar: CalendarView(state: state)
      case .mods: ModsView(state: state)
      case .music: MusicView()
      case .network: NetworkView(network: state.network)
      case .notion: NotionPageView(state: state)
      case .messages: MessagesView(state: state)
      case .settings: SettingsView(settings: state.settings, sources: state.calendarSources, jobs: state.jobs)
      }
    }
    .tabyPage()
    .task {
      if preview == nil && model.state == nil { await model.refresh() }
    }
  }
}

/// Kopfzeile eines Reiters: Titel links, optionale Aktionen rechts.
struct PageHeader<Trailing: View>: View {
  let title: String
  var subtitle: String? = nil
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
      if let subtitle {
        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
          .contentTransition(.numericText())
      }
      Spacer(minLength: 0)
      trailing()
    }
    .padding(.horizontal, 2)
  }
}

extension PageHeader where Trailing == EmptyView {
  init(title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}
