// Tagesplan wählen: Schritt 1 hakt offene Aufgaben ab, Schritt 2 setzt je Aufgabe
// Automatik oder feste Uhrzeit und die Dauer. Läuft inline im Inhaltsbereich.
import SwiftUI
import TabyCore

struct PlanPickerView: View {
  enum Step: Equatable { case select, times }

  /// Offene Aufgaben (Schritt 1).
  let tasks: [TabyTask]
  let plan: DayPlan?
  /// Termine heute, für die Überschneidungs-Warnung.
  let events: [CalendarEvent]
  /// Notion-Zuordnung für die Abschnitte in Schritt 1 (siehe `PlanPickerLogic.sections`).
  var notionSourceLinks: [String: String] = [:]
  var notionSources: [NotionSource] = []
  var notionTaskGroups: [String: String] = [:]
  let onClose: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var step: Step
  @State private var selected: Set<String>
  @State private var items: [PlanPickItem]
  @State private var busy = false
  @State private var error: String?
  /// Abschnitts-Zustand (ID → offen); Startwert aus `PlanSectionMemory`, fehlt ein Eintrag, gilt die Standardregel.
  @State private var sectionOpen: [String: Bool] = PlanSectionMemory.open

  /// `initialItems` nil = aus dem bestehenden Plan. Snapshots und Bearbeiten setzen Schritt und Einträge direkt.
  init(tasks: [TabyTask], plan: DayPlan?, events: [CalendarEvent], initialStep: Step = .select,
       initialItems: [PlanPickItem]? = nil, notionSourceLinks: [String: String] = [:],
       notionSources: [NotionSource] = [], notionTaskGroups: [String: String] = [:],
       onClose: @escaping () -> Void) {
    self.tasks = tasks
    self.plan = plan
    self.events = events
    self.notionSourceLinks = notionSourceLinks
    self.notionSources = notionSources
    self.notionTaskGroups = notionTaskGroups
    self.onClose = onClose
    let start = initialItems ?? PlanPickerLogic.items(from: plan?.blocks ?? [])
    _step = State(initialValue: initialStep)
    _items = State(initialValue: start)
    _selected = State(initialValue: PlanPickerLogic.selection(openIds: Set(tasks.map(\.id)), items: start))
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var today: String { NowResolver.today(nowEnv) }
  private var sections: [PlanPickSection] {
    PlanPickerLogic.sections(tasks, sourceLinks: notionSourceLinks, sources: notionSources,
                             taskGroups: notionTaskGroups, now: now,
                             notionCategories: model.state?.notionTaskCategories ?? [:],
                             categories: model.state?.settings.taskCategories ?? TaskCategoryDef.builtIn,
                             folders: model.state?.taskFolders ?? [])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: step == .select ? "Heute planen" : "Uhrzeiten")
      switch step {
      case .select: selectStep
      case .times: timesStep
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
    }
    .disabled(busy)
  }

  // MARK: Schritt 1

  private var selectStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      CappedScroll(maxHeight: 300) {
        VStack(alignment: .leading, spacing: 2) {
          if tasks.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Keine offenen Aufgaben")
          }
          ForEach(sections) { section in
            sectionHeader(section)
            if isOpen(section) {
              ForEach(section.groups, id: \.title) { group in
                if !group.title.isEmpty {
                  Text(group.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                }
                ForEach(group.tasks) { t in taskRow(t) }
              }
            }
          }
        }
      }
      HStack(spacing: 8) {
        Text(PlanPickerLogic.selectedText(selected.count))
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        Spacer(minLength: 4)
        Button("Abbrechen", action: onClose)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button("Weiter", action: next)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(selected.isEmpty)
      }
    }
  }

  /// Abschnittskopf zum Auf- und Zuklappen; der Zustand merkt sich die Sitzung.
  private func sectionHeader(_ section: PlanPickSection) -> some View {
    let open = isOpen(section)
    return Button {
      withAnimation(Theme.spring) {
        sectionOpen[section.id] = !open
        PlanSectionMemory.open = sectionOpen
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .bold))
          .rotationEffect(.degrees(open ? 90 : 0))
        SectionHeader(symbol: "square.stack", title: section.title, count: section.count)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 4)
    .padding(.top, 4)
    .accessibilityLabel("\(section.title), \(section.count) Aufgaben, \(open ? "aufgeklappt" : "eingeklappt")")
    .accessibilityHint("Tippen zum Auf- und Zuklappen")
  }

  private func isOpen(_ section: PlanPickSection) -> Bool {
    sectionOpen[section.id] ?? ViewSupportLogic.sectionOpenByDefault(section, now: now)
  }

  private func taskRow(_ t: TabyTask) -> some View {
    HStack(spacing: 10) {
      CheckCircle(checked: selected.contains(t.id)) { toggle(t.id) }
      Text(t.title)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let chip = TaskLogic.dueChip(t.due, now: now) { DueChipView(info: chip) }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  private func toggle(_ id: String) {
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
  }

  private func next() {
    let chosen = tasks.filter { selected.contains($0.id) }
    items = PlanPickerLogic.build(selected: chosen, known: items, now: now, events: events, today: today)
    step = .times
  }

  // MARK: Schritt 2

  private var timesStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Dauer in Minuten. Automatisch sucht eine freie Lücke, eine feste Uhrzeit bleibt beim Neu-Planen stehen.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      CappedScroll(maxHeight: 230) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach($items) { $item in timeRow($item) }
        }
      }
      HStack(spacing: 8) {
        Button("Zurück") { step = .select }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 4)
        Button("Einplanen", action: save)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(items.isEmpty)
      }
    }
  }

  private func timeRow(_ item: Binding<PlanPickItem>) -> some View {
    let warning = PlanPickerLogic.conflictText(item.wrappedValue, events: events, today: today)
    return VStack(alignment: .leading, spacing: 5) {
      Text(item.wrappedValue.title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
      HStack(spacing: 8) {
        modeControl(item)
        if item.wrappedValue.pinned {
          CompactDatePicker(date: timeBinding(item), time: true)
        }
        Spacer(minLength: 4)
        ForEach(PlanPickerLogic.durations, id: \.self) { d in
          ChoiceChip(text: "\(d)", selected: item.wrappedValue.minutes == d) { item.wrappedValue.minutes = d }
        }
      }
      if let warning {
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
          Text(warning).font(.system(size: 11))
        }
        .foregroundStyle(Theme.amber)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
  }

  private func modeControl(_ item: Binding<PlanPickItem>) -> some View {
    HStack(spacing: 2) {
      segment("Automatisch", selected: !item.wrappedValue.pinned) { item.wrappedValue.pinned = false }
      segment("Uhrzeit", selected: item.wrappedValue.pinned) { item.wrappedValue.pinned = true }
    }
    .padding(2)
    .background(Capsule().fill(Theme.capsule))
  }

  private func segment(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(text)
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Color.black : Theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.clear))
        .contentShape(Capsule())
    }
    .buttonStyle(PressScaleStyle())
    .animation(Theme.snappy, value: selected)
  }

  /// Verbindet den "HH:mm"-Eintrag mit dem Datumswähler (Datum des heutigen Tages).
  private func timeBinding(_ item: Binding<PlanPickItem>) -> Binding<Date> {
    Binding(
      get: { LocalTime.parse("\(today)T\(item.wrappedValue.time)") ?? Date.distantPast },
      set: { item.wrappedValue.time = LocalTime.formatTime($0) })
  }

  private func save() {
    busy = true
    error = nil
    Task {
      let result = await model.services.planTasks(PlanPickerLogic.planItems(items))
      if result.isOk {
        await model.refresh()
        model.react(.celebrate)
        busy = false
        onClose()
      } else {
        error = result.errorMessage ?? "Einplanen hat nicht geklappt."
        busy = false
      }
    }
  }
}
