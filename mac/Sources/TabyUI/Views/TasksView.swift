// Reiter "Aufgaben": Eingabekapsel mit optionaler Fälligkeit, offene und
// (einklappbare) erledigte Aufgaben, federnde Häkchen, Titel inline ändern,
// Papierkorb beim Überfahren.
import SwiftUI
import TabyCore

/// Gruppierung der offenen Aufgaben. „Keine“ ist eine flache Liste.
enum TaskGrouping: String, CaseIterable {
  case none, category, status, tag

  var title: String {
    switch self {
    case .none: "Keine"
    case .category: "Kategorie"
    case .status: "Stand"
    case .tag: "Kennzeichen"
    }
  }
}

/// Gruppierung und Filter der Aufgabenliste, gemerkt in UserDefaults. Kaputte Werte fallen auf den Standard zurück.
struct TaskViewPrefs: Equatable {
  var grouping: TaskGrouping = .category
  var statuses: Set<TaskStatus> = []
  var tags: [String] = []
  var sources: Set<TaskSourceChoice> = []
  var due: Set<TaskDueChoice> = []

  static let groupingKey = "tasks.view.grouping"
  static let statusKey = "tasks.view.statuses"
  static let tagKey = "tasks.view.tags"
  static let sourceKey = "tasks.view.sources"
  static let dueKey = "tasks.view.due"

  static func parse(grouping: String?, statuses: String?, tags: String?,
                    sources: String? = nil, due: String? = nil) -> TaskViewPrefs {
    var p = TaskViewPrefs()
    if let g = grouping.flatMap(TaskGrouping.init(rawValue:)) { p.grouping = g }
    if let s = decode([TaskStatus].self, statuses) { p.statuses = Set(s) }
    if let t = decode([String].self, tags) { p.tags = t }
    if let s = decode([TaskSourceChoice].self, sources) { p.sources = Set(s) }
    if let d = decode([TaskDueChoice].self, due) { p.due = Set(d) }
    return p
  }

  static func stored(_ defaults: UserDefaults = .standard) -> TaskViewPrefs {
    parse(grouping: defaults.string(forKey: groupingKey), statuses: defaults.string(forKey: statusKey),
          tags: defaults.string(forKey: tagKey), sources: defaults.string(forKey: sourceKey),
          due: defaults.string(forKey: dueKey))
  }

  func store(_ defaults: UserDefaults = .standard) {
    defaults.set(grouping.rawValue, forKey: Self.groupingKey)
    defaults.set(Self.encode(TaskStatusLogic.menuOrder.filter(statuses.contains)), forKey: Self.statusKey)
    defaults.set(Self.encode(tags), forKey: Self.tagKey)
    defaults.set(Self.encode(TaskSourceChoice.allCases.filter(sources.contains)), forKey: Self.sourceKey)
    defaults.set(Self.encode(TaskDueChoice.allCases.filter(due.contains)), forKey: Self.dueKey)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
    guard let text, let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func encode<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Zeile im Ansicht-Menü: Häkchen bei Auswahl, optional Anzahl rechts.
struct TaskViewOptionRow: View {
  let text: String
  var count: Int?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 12)
          .opacity(selected ? 1 : 0)
        Text(text).font(.system(size: 12, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text)
        Spacer(minLength: 8)
        if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(count.map { "\(text), \($0)" } ?? text)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct TasksView: View {
  let tasks: [TabyTask]
  /// Nur Snapshots: feste Notion-Verknüpfungen, sonst gilt `model.state`.
  let notionLinks: [String: String]?
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @Environment(\.tabySnapshot) private var snapshot
  @State private var title = ""
  /// Nur Snapshots: Aufgabe, die direkt im Bearbeitungsmodus startet.
  let editingId: String?
  /// Aufgabe, deren Details beim Anzeigen aufgeklappt sind (für die Snapshots).
  let expandedId: String?
  @State private var dueMode: DueMode = .none
  @State private var withTime = false
  @State private var pickedDate = Date()
  @State private var pickedTime = Date()
  @State private var showDue = false
  @State private var showDone = false
  @State private var error: String?
  @State private var completing: Set<String> = []
  /// Kategorie-Kennung aus den Einstellungen; nil = Alle.
  @State private var categoryFilter: String?
  @State private var addingCategory = false
  @State private var newCategoryName = ""
  @State private var newCategorySymbol = "tag.fill"
  @State private var categoryError: String?
  @FocusState private var newCategoryFocused: Bool
  @State private var originFilter: TaskOrigin?
  /// Notion-Bereich (Herkunft „Zugang“): zugeklappte Abschnitte (gemerkt), Suche im Titel, gewählte Quellen (leer = alle).
  @State private var notionCollapsed: Set<String>
  @State private var notionSearch: String
  @State private var notionSourceIds: Set<String>
  /// Gruppierung der offenen Aufgaben (Ansicht-Menü); Standard: Kategorie.
  @State private var grouping: TaskGrouping
  /// Gewählte Stände (Ansicht-Menü); leer = alle.
  @State private var statusFilter: Set<TaskStatus>
  /// Gewählte Kennzeichen (Ansicht-Menü); alle müssen passen.
  @State private var tagFilter: [String]
  /// Gewählte Quellen (Ansicht-Menü: Aus Notion / Eigene); leer = alle.
  @State private var sourceFilter: Set<TaskSourceChoice>
  /// Gewählte Fälligkeiten (Ansicht-Menü); leer = alle.
  @State private var dueFilter: Set<TaskDueChoice>
  /// Ansicht-Menü offen (Popover). In Snapshots zeigt `optionsOpen` das Menü direkt als Liste.
  @State private var optionsOpen: Bool
  /// Hinweis nach dem Einordnen, wenn die Aufgabe aus dem Filter fällt.
  @State private var moveFlash: MoveFlash?
  /// Aus der Suche angesprungene Aufgabe: kurz hervorgehoben; `scrollTarget` löst das Hinscrollen aus.
  @State private var flashTaskId: String?
  @State private var scrollTarget: String?
  @State private var planning = false
  @State private var newRecurrence: TaskRecurrence?
  @State private var newMinutes: Int?
  @State private var folderFilter: String?
  /// Zugeklappte Abschnitte: standardmäßig ist alles offen, damit offene Aufgaben sichtbar sind.
  @State private var collapsed: Set<String> = []
  @State private var addingFolder = false
  @State private var newFolderName = ""
  @State private var renamingFolder: String?
  @State private var renameDraft = ""
  @State private var deletingFolder: TaskFolder?
  @State private var confirmDeleteFolder = false
  @FocusState private var newFolderFocused: Bool
  @FocusState private var renameFocused: Bool
  /// Nur Snapshots: feste Ordnerliste statt `model.state`.
  let folderOverride: [TaskFolder]?
  let notesOverride: [Note]?
  /// Nur Snapshots: feste Kategorienliste statt `model.state`.
  let categoriesOverride: [TaskCategoryDef]?
  /// Nur Snapshots: Notion-Zugänge, Quellen und Kategorien je Aufgabe statt `model.state`.
  let notionOverride: NotionOverride?

  typealias DueMode = TaskLogic.DueMode

  init(tasks: [TabyTask], notionLinks: [String: String]? = nil, showDone: Bool = false, showDue: Bool = false,
       editingId: String? = nil, folders: [TaskFolder]? = nil, selectedFolder: String? = nil,
       notes: [Note]? = nil, expandedId: String? = nil, categories: [TaskCategoryDef]? = nil,
       selectedCategory: String? = nil, notionOverride: NotionOverride? = nil, groupedByStatus: Bool = false,
       groupedByTag: Bool = false, selectedTags: [String] = [], statusFilter: [TaskStatus] = [],
       sourceFilter: [TaskSourceChoice] = [], dueFilter: [TaskDueChoice] = [], optionsOpen: Bool = false,
       selectedOrigin: TaskOrigin? = nil, notionSearch: String = "", notionSourceIds: [String] = [],
       notionCollapsedIds: [String]? = nil) {
    self.tasks = tasks
    self.notionLinks = notionLinks
    self.notionOverride = notionOverride
    self.editingId = editingId
    self.expandedId = expandedId
    folderOverride = folders
    notesOverride = notes
    categoriesOverride = categories
    // Gespeichertes gilt, außer ein Snapshot gibt Gruppierung oder Filter vor (Snapshots bleiben so fest).
    var prefs = TaskViewPrefs.stored()
    if groupedByStatus { prefs.grouping = .status }
    if groupedByTag { prefs.grouping = .tag }
    if !selectedTags.isEmpty { prefs.tags = selectedTags }
    if !statusFilter.isEmpty { prefs.statuses = Set(statusFilter) }
    if !sourceFilter.isEmpty { prefs.sources = Set(sourceFilter) }
    if !dueFilter.isEmpty { prefs.due = Set(dueFilter) }
    _grouping = State(initialValue: prefs.grouping)
    _statusFilter = State(initialValue: prefs.statuses)
    _tagFilter = State(initialValue: prefs.tags)
    _sourceFilter = State(initialValue: prefs.sources)
    _dueFilter = State(initialValue: prefs.due)
    _optionsOpen = State(initialValue: optionsOpen)
    _categoryFilter = State(initialValue: selectedCategory)
    _originFilter = State(initialValue: selectedOrigin)
    _notionSearch = State(initialValue: notionSearch)
    _notionSourceIds = State(initialValue: Set(notionSourceIds))
    _notionCollapsed = State(initialValue: notionCollapsedIds.map { Set($0) } ?? NotionSectionLogic.stored())
    _folderFilter = State(initialValue: selectedFolder)
    _showDone = State(initialValue: showDone)
    _showDue = State(initialValue: showDue)
    _dueMode = State(initialValue: showDue ? .today : .none)
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var links: [String: String] { notionLinks ?? model.state?.notionSourceLinks ?? [:] }
  /// Kategorie je Notion-Aufgabe (aus Quelle → Zugang berechnet); nur diese Aufgaben sind Notion-Aufgaben für die Kategorie.
  private var notionCats: [String: String] { notionOverride?.categories ?? model.state?.notionTaskCategories ?? [:] }
  private var sources: [NotionSource] { notionOverride?.sources ?? model.state?.notionSources ?? [] }
  private var accounts: [NotionAccount] { notionOverride?.accounts ?? model.state?.settings.notionAccounts ?? [] }
  /// Zugang einer Notion-Aufgabe für die Anzeige am Kategorie-Feld; nil für eigene Aufgaben.
  private func accountName(_ t: TabyTask) -> String? {
    let id = TaskLogic.accountId(of: t, sourceLinks: links, sources: sources)
    return accounts.first { $0.id == id }?.name
  }
  /// Zugänge der gewählten Kategorie, die die Herkunfts-Zeile zeigt (leer = keine Zeile, auch unter „Alle“).
  private var originAccounts: [NotionAccount] {
    TaskLogic.originAccounts(category: categoryFilter, accounts: accounts,
                             tasks: tasks, sourceLinks: links, sources: sources)
  }
  /// Einordnen-Hinweis („In Privat verschoben“), solange die letzte Aktion noch dieselbe ist.
  private var undoLabelShown: String? {
    guard let banner = model.undoBannerLabel else { return nil }
    if let f = moveFlash, f.undoLabel == model.state?.undoLabel { return f.label }
    guard ViewSupportLogic.undoVisible(banner) else { return nil }
    let label = banner
    return label
  }
  private var undoShown: Bool { undoLabelShown != nil }
  private var folders: [TaskFolder] { folderOverride ?? model.state?.taskFolders ?? [] }
  private var defs: [TaskCategoryDef] { categoriesOverride ?? model.state?.settings.taskCategories ?? TaskCategoryDef.builtIn }
  /// Ordner, die die Kategorie-Zeile gerade zeigt (Alle: ohne Kategorie).
  private var visibleFolders: [TaskFolder] { TaskCategoryLogic.folders(folders, in: categoryFilter, defs: defs) }
  private var allNotes: [Note] { notesOverride ?? model.state?.notes ?? [] }
  /// Notion-Bereich: nur bei Herkunft „Zugang“ (dort stehen die Notion-Abschnitte).
  private var notionView: Bool {
    if case .account? = originFilter { return true }
    return false
  }
  /// Suche oder Quellenauswahl im Notion-Bereich ist aktiv.
  private var notionFilterActive: Bool {
    NotionSectionLogic.filterActive(search: notionSearch, sourceIds: notionSourceIds)
  }
  /// Irgendein Filter aktiv: dann klappt der Notion-Bereich auf, damit kein Treffer verschwindet.
  private var anyFilterActive: Bool { notionFilterActive || !activeFilters.isEmpty }
  /// Quellen des gewählten Zugangs für die Quellen-Auswahl.
  private var notionSourceList: [NotionSource] {
    guard case .account(let id)? = originFilter else { return [] }
    return sources.filter { $0.accountId == id }
  }
  /// Höhe der Notion-Leisten (Suche, Quellen) für die Begrenzung der Liste.
  private var notionBarHeight: CGFloat { notionView ? (notionSourceList.count > 1 ? 60 : 30) : 0 }

  /// Gefilterte Liste: Kategorie, Ordner und Herkunft wirken zusammen (UND), vor der Sortierung.
  private func filtered() -> [TabyTask] {
    let base = tasks.filter {
      TaskLogic.matches($0, category: categoryFilter, folders: folders, defs: defs, notionCategories: notionCats)
        && TaskFolderLogic.matches($0, folder: folderFilter)
        && TaskLogic.matches($0, origin: originFilter, sourceLinks: links, sources: sources)
    }
    let inNotion = notionView
      ? NotionSectionLogic.filter(base, search: notionSearch, sourceIds: notionSourceIds, sourceLinks: links) : base
    let byStatus = TaskStatusLogic.filter(inNotion, statuses: statusFilter)
    let byFacets = TaskStatusLogic.filter(byStatus, sources: sourceFilter, due: dueFilter, sourceLinks: links, now: now)
    return TagLogic.filter(byFacets, selected: tagFilter, notes: allNotes)
  }
  private var open: [TabyTask] { TaskLogic.sortOpen(filtered()) }
  private var done: [TabyTask] { TaskLogic.sortDone(filtered()) }
  /// Alle Kennzeichen aus Aufgaben und Notizen (Vorschläge, Ansicht-Menü).
  private var tagNames: [String] { TagLogic.allTags(tasks: tasks, notes: allNotes).map(\.name) }
  /// Kennzeichen mit Anzahl für das Ansicht-Menü.
  private var tagCounts: [TagLogic.Count] { TagLogic.allTags(tasks: tasks, notes: allNotes) }
  /// Aktive Filter (Stand, Kennzeichen) für den Zähler am Knopf und die Chip-Zeile.
  private var activeFilters: [TaskViewFilter] {
    TaskStatusLogic.activeFilters(statuses: statusFilter, tags: tagFilter, sources: sourceFilter, due: dueFilter)
  }
  /// Abschnitte: beim Zugang nach Notion-Quelle (Tickets, Quellen, Weekly-Wochen), sonst je Ordner der Kategorie.
  /// „Keine“ ist eine flache Liste, außer beim Zugang (dessen Quellen bleiben Abschnitte).
  private var groups: [(id: String, name: String, tasks: [TabyTask])]? {
    if grouping == .tag { return TagLogic.groups(open, notes: allNotes) }
    if grouping == .status {
      return TaskStatusLogic.groups(filtered())
        .map { (id: "status-\($0.0.rawValue)", name: $0.0.title, tasks: $0.1) }
    }
    if case .account(let accountId)? = originFilter {
      let mine = open.filter { TaskLogic.accountId(of: $0, sourceLinks: links, sources: sources) == accountId }
      return PlanPickerLogic.notionGroups(mine, sourceLinks: links, sources: sources,
                                          taskGroups: model.state?.notionTaskGroups ?? [:], now: now)
        .map { g in
          (id: NotionSectionLogic.sectionId(title: g.title, sourceId: links[g.tasks.first?.id ?? ""]),
           name: g.title, tasks: g.tasks)
        }
    }
    // „Alle“ (ohne Kategorie und Ordner) ist immer die Übersicht nach Kategorie, auch ohne Ordner.
    guard grouping == .category, folderFilter == nil else { return nil }
    if categoryFilter != nil && visibleFolders.isEmpty { return nil }
    return TaskCategoryLogic.groups(open, category: categoryFilter, folders: folders, defs: defs, notionCategories: notionCats)
      .map { (id: $0.id, name: $0.name, tasks: $0.tasks) }
  }

  /// Von „Heute“ gesetzt, bevor der Reiter öffnet: das Eingabefeld für neue Aufgaben bekommt den Fokus.
  @MainActor static var focusInputOnAppear = false
  @State private var focusTick = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Aufgaben", subtitle: openTotal == 0 ? nil : "\(openTotal) offen") {
        if !planning {
          Button { planning = true } label: { Label("Heute planen", systemImage: "sun.max") }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            .fixedSize()
          ansichtButton
        }
      }
      if planning {
        PlanPickerView(tasks: TaskLogic.sortOpen(tasks), plan: model.state?.plan,
                       events: model.state?.overview.eventsToday ?? [], onClose: { planning = false })
      } else {
        // Snapshots zeigen das Ansicht-Menü direkt, weil ein Popover im Renderer nicht erscheint.
        if snapshot && optionsOpen { optionsPanel }
        addRow
        if showDue { dueRow.transition(.move(edge: .top).combined(with: .opacity)) }
        filterRows
        if notionView { notionBar.transition(.opacity) }
        if !activeFilters.isEmpty { activeFilterRow.transition(.opacity) }
        if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
        // Jede zusätzliche Leiste (Ordner, Notion/Eigene, Filter, Rückgängig) macht die Liste kürzer, sonst ragt ihr
        // Ende unten aus der Notch und die letzten Aufgaben sind nicht erreichbar.
        CappedScroll(maxHeight: (showDue ? 194 : 236) - (visibleFolders.isEmpty ? 0 : 32) - (originAccounts.isEmpty ? 0 : 30)
                       - (undoShown ? 40 : 0) - activeRowHeight - notionBarHeight) {
          ScrollViewReader { proxy in
          VStack(alignment: .leading, spacing: 2) {
            if open.isEmpty && done.isEmpty && notionView && anyFilterActive {
              notionNothingFound
            } else if open.isEmpty && done.isEmpty {
              EmptyState(symbol: "checkmark.circle", title: "Keine Aufgaben",
                         subtitle: "Schreib oben etwas rein und drück Enter.")
            } else if open.isEmpty {
              EmptyState(symbol: "party.popper", title: "Alles erledigt!")
            }
            if let groups {
              ForEach(groups, id: \.id) { g in
                if notionView {
                  notionSection(id: g.id, name: g.name, tasks: g.tasks)
                } else {
                  groupSection(id: g.id, name: g.name, tasks: g.tasks)
                }
              }
            } else {
              ForEach(open) { row($0) }
            }
            if !done.isEmpty { doneSection }
          }
          .onAppear { focusTask() }
          .onChange(of: model.focusedTaskId) { _, _ in focusTask() }
          .onChange(of: scrollTarget) { _, id in
            guard let id else { return }
            withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
            scrollTarget = nil
          }
          }
        }
      }
      if let label = undoLabelShown {
        UndoBanner(label: label).transition(.opacity)
      }
    }
    .animation(Theme.spring, value: tasks)
    .animation(Theme.spring, value: planning)
    .animation(Theme.spring, value: showDue)
    .animation(Theme.spring, value: showDone)
    .animation(Theme.spring, value: originAccounts.map(\.id))
    .animation(Theme.spring, value: activeFilters.isEmpty)
    .onChange(of: grouping) { _, _ in savePrefs() }
    .onChange(of: statusFilter) { _, _ in savePrefs() }
    .onChange(of: tagFilter) { _, _ in savePrefs() }
    .onChange(of: sourceFilter) { _, _ in savePrefs() }
    .onChange(of: dueFilter) { _, _ in savePrefs() }
    // Die Herkunft gehört zur Kategorie: beim Wechsel der Kategorie gilt wieder „Alle“.
    .onChange(of: categoryFilter) { _, _ in originFilter = nil; moveFlash = nil }
    // Die Quellenauswahl gehört zu einem Zugang: beim Wechsel wieder „Alle“.
    .onChange(of: originFilter) { _, _ in notionSourceIds = [] }
    // Zugeklappt wird gemerkt (nur in der echten Ansicht, Snapshots schreiben nichts).
    .onChange(of: notionCollapsed) { _, ids in if !snapshot { NotionSectionLogic.store(ids) } }
    .onChange(of: originAccounts.map(\.id)) { _, ids in
      if ids.isEmpty { originFilter = nil }
    }
    .onChange(of: folders) { _, _ in dropHiddenFolderFilter() }
    // Ein gewähltes Kennzeichen, das es nicht mehr gibt, fällt aus der Filterauswahl.
    .onChange(of: tagNames) { _, names in tagFilter = tagFilter.filter { names.contains($0) } }
    .onChange(of: categoryFilter) { _, _ in dropHiddenFolderFilter() }
    // Die Kategorie gibt es nicht mehr: Filter zurück auf „Alle“.
    .onChange(of: defs.map(\.id)) { _, ids in
      if let filter = categoryFilter, !ids.contains(filter) { categoryFilter = nil }
    }
    .confirmationDialog("Ordner löschen? Die Aufgaben bleiben erhalten.", isPresented: $confirmDeleteFolder,
                        titleVisibility: .visible) {
      Button("Löschen", role: .destructive) { if let f = deletingFolder { deleteFolder(f) } }
      Button("Abbrechen", role: .cancel) {}
    }
  }

  private func row(_ t: TabyTask) -> some View {
    TaskRow(task: t, now: now, completing: completing.contains(t.id), onToggle: { toggle(t) },
            autoEdit: t.id == editingId, notes: allNotes, startExpanded: t.id == expandedId, categories: defs,
            notionCategories: notionCats, notionAccountName: accountName(t), onAssigned: { assigned(t, to: $0) },
            knownTags: tagNames)
      .id(t.id)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Theme.blue.opacity(flashTaskId == t.id ? 0.22 : 0)))
      .animation(Theme.spring, value: flashTaskId)
      .transition(Theme.rowTransition)
  }

  /// Von außen gewählte Aufgabe (Suche): Filter und Zuklappen heben, die Aufgabe hervorheben und hinscrollen.
  private func focusTask() {
    guard let id = model.focusedTaskId else { return }
    model.focusedTaskId = nil
    guard let task = model.state?.tasks.first(where: { $0.id == id }) ?? tasks.first(where: { $0.id == id }) else { return }
    categoryFilter = nil; folderFilter = nil; originFilter = nil
    statusFilter = []; tagFilter = []; sourceFilter = []; dueFilter = []
    notionSearch = ""; notionSourceIds = []
    collapsed = []; notionCollapsed = []
    if task.done { showDone = true }
    flashTaskId = id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { scrollTarget = id }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if flashTaskId == id { flashTaskId = nil } }
  }

  /// Nach dem Einordnen: fällt die Aufgabe aus der gewählten Kategorie, erscheint „In … verschoben · Rückgängig“.
  private func assigned(_ t: TabyTask, to categoryId: String?) {
    guard TaskCategoryLogic.movesOut(t, to: categoryId, filter: categoryFilter, folders: folders, defs: defs,
                                     notionCategories: notionCats) else { return }
    moveFlash = MoveFlash(label: TaskCategoryLogic.moveLabel(categoryId, defs: defs), undoLabel: model.state?.undoLabel)
  }

  /// Ordner-Abschnitt in "Alle": Kopf mit Name und Anzahl, einklappbar.
  private func groupSection(id: String, name: String, tasks: [TabyTask]) -> some View {
    let folded = collapsed.contains(id)
    return VStack(alignment: .leading, spacing: 2) {
      sectionHeader(name: name, count: tasks.count, folded: folded) {
        if folded { collapsed.remove(id) } else { collapsed.insert(id) }
      }
      if !folded {
        ForEach(tasks) { row($0) }
      }
    }
  }

  /// Abschnitt im Notion-Bereich: klappt zu und merkt sich das. Ein aktiver Filter klappt ihn immer auf.
  private func notionSection(id: String, name: String, tasks: [TabyTask]) -> some View {
    let folded = NotionSectionLogic.isFolded(id, collapsed: notionCollapsed, filterActive: anyFilterActive)
    return VStack(alignment: .leading, spacing: 2) {
      sectionHeader(name: name, count: tasks.count, folded: folded) {
        if notionCollapsed.contains(id) { notionCollapsed.remove(id) } else { notionCollapsed.insert(id) }
      }
      if !folded {
        ForEach(tasks) { row($0) }
      }
    }
  }

  /// Kopfzeile eines einklappbaren Abschnitts: Chevron, Name, Anzahl.
  private func sectionHeader(name: String, count: Int, folded: Bool, toggle: @escaping () -> Void) -> some View {
    Button {
      withAnimation(Theme.spring) { toggle() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .bold))
          .rotationEffect(.degrees(folded ? 0 : 90))
        Text(name).font(.system(size: 11, weight: .semibold))
        Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded))
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(Capsule().fill(Theme.capsule))
        Spacer()
      }
      .foregroundStyle(Theme.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.top, 6)
    .accessibilityLabel("\(name), \(count) offen, \(folded ? "eingeklappt" : "aufgeklappt")")
  }

  /// Suche im Titel und Quellenauswahl des Notion-Bereichs, „Alle zuklappen“ / „Alle aufklappen“ für dessen Abschnitte.
  private var notionBar: some View {
    let ids = (groups ?? []).map { $0.id }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        HStack(spacing: 5) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
          TextField("Titel suchen", text: $notionSearch)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 150)
            .accessibilityLabel("Notion durchsuchen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.capsule))
        Spacer(minLength: 0)
        if !ids.isEmpty {
          let allFolded = NotionSectionLogic.allFolded(ids, collapsed: notionCollapsed)
          Button(allFolded ? "Alle aufklappen" : "Alle zuklappen") {
            withAnimation(Theme.spring) {
              notionCollapsed = NotionSectionLogic.toggledAll(ids, collapsed: notionCollapsed)
            }
          }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          .fixedSize()
        }
      }
      if notionSourceList.count > 1 { notionSourceRow }
    }
    .padding(.horizontal, 2)
  }

  /// Quellen-Auswahl des Zugangs: „Alle“ oder einzelne Quellen (mehrere möglich).
  private var notionSourceRow: some View {
    let chips = HStack(spacing: 6) {
      ChoiceChip(text: "Alle", selected: notionSourceIds.isEmpty) { notionSourceIds = [] }.fixedSize()
      ForEach(notionSourceList) { s in
        ChoiceChip(text: s.name, selected: notionSourceIds.contains(s.id)) {
          if notionSourceIds.contains(s.id) { notionSourceIds.remove(s.id) } else { notionSourceIds.insert(s.id) }
        }
        .fixedSize()
        .accessibilityLabel("Quelle \(s.name)")
      }
    }
    .padding(.horizontal, 2)
    return Group {
      // Snapshots: ohne Scroll-Container, sonst bleibt die Zeile im Renderer leer.
      if snapshot { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
    }
  }

  /// Leer-Zustand des Notion-Bereichs bei aktivem Filter, mit Rücksetzen aller Filter.
  private var notionNothingFound: some View {
    VStack(spacing: 6) {
      EmptyState(symbol: "magnifyingglass", title: "Nichts gefunden")
      Button("Filter zurücksetzen") {
        resetFilters()
        notionSearch = ""
        notionSourceIds = []
      }
      .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      .fixedSize()
      .frame(maxWidth: .infinity)
    }
  }

  /// Alle offenen Aufgaben, unabhängig vom Filter (wie "N offen" in der Notch).
  private var openTotal: Int { TaskLogic.sortOpen(tasks).count }

  /// Drei Zeilen, eine Logik: Kategorien, Ordner der gewählten Kategorie, nur mit Notion-Aufgaben die Herkunft.
  private var filterRows: some View {
    VStack(alignment: .leading, spacing: 4) {
      categoryRow
      if addingCategory { categoryEditor.transition(.move(edge: .top).combined(with: .opacity)) }
      // Ohne Ordner in dieser Kategorie steht „+ Ordner“ in der Kategorie-Zeile: die Insel bleibt niedrig.
      if !visibleFolders.isEmpty { folderRow }
      if !originAccounts.isEmpty { originRow.transition(.opacity) }
    }
  }

  /// Knopf „Ansicht“ neben „Heute planen“: Gruppierung, Stand und Kennzeichen im Popover. Eine kleine Zahl zeigt
  /// die aktiven Filter.
  private var ansichtButton: some View {
    let count = activeFilters.count
    return Button { optionsOpen.toggle() } label: {
      Label("Ansicht", systemImage: "line.3.horizontal.decrease")
    }
    .buttonStyle(PillButtonStyle(kind: optionsOpen ? .secondary : .ghost, compact: true))
    .fixedSize()
    .overlay(alignment: .topTrailing) {
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 8, weight: .bold, design: .rounded))
          .foregroundStyle(.black)
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Capsule().fill(Theme.blue))
          .offset(x: 5, y: -4)
          .contentTransition(.numericText())
          .accessibilityHidden(true)
      }
    }
    .help("Ansicht")
    .accessibilityLabel("Ansicht")
    .accessibilityValue(count > 0 ? "\(count) aktive Filter" : "")
    .popover(isPresented: Binding(get: { optionsOpen && !snapshot }, set: { optionsOpen = $0 }), arrowEdge: .bottom) {
      optionsPanel
    }
  }

  /// Das Ansicht-Menü: Gruppieren nach, Stand (Mehrfachauswahl), Kennzeichen mit Anzahl (Mehrfachauswahl), Zurücksetzen.
  private var optionsPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      optionSection("Gruppieren nach") {
        ForEach(TaskGrouping.allCases, id: \.self) { g in
          TaskViewOptionRow(text: g.title, selected: grouping == g) { grouping = g }
        }
      }
      optionSection("Stand") {
        ForEach(TaskStatusLogic.menuOrder, id: \.self) { s in
          TaskViewOptionRow(text: s.title, selected: statusFilter.contains(s)) { toggleStatus(s) }
        }
      }
      if !tagCounts.isEmpty {
        optionSection("Kennzeichen") {
          ForEach(tagCounts, id: \.name) { c in
            TaskViewOptionRow(text: "#\(c.name)", count: c.count, selected: TagLogic.contains(tagFilter, name: c.name)) {
              toggleTag(c.name)
            }
          }
        }
      }
      optionSection("Quelle") {
        ForEach(TaskSourceChoice.allCases, id: \.self) { s in
          TaskViewOptionRow(text: s.title, selected: sourceFilter.contains(s)) { toggleSource(s) }
        }
      }
      optionSection("Fällig") {
        ForEach(TaskDueChoice.allCases, id: \.self) { d in
          TaskViewOptionRow(text: d.title, selected: dueFilter.contains(d)) { toggleDue(d) }
        }
      }
      Divider()
      Button("Zurücksetzen") { resetFilters() }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .fixedSize()
        .disabled(activeFilters.isEmpty)
    }
    .padding(12)
    .frame(width: 230, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
  }

  private func optionSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).kerning(0.4)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 6)
      content()
    }
  }

  /// Aktive Filter als eine Zeile entfernbarer Chips mit „Zurücksetzen“. Ohne Filter gar nicht eingeblendet.
  private var activeFilterRow: some View {
    let chips = HStack(spacing: 5) {
      ForEach(activeFilters, id: \.self) { f in
        FilterChip(filter: f, onRemove: { removeFilter(f) })
      }
      Button("Zurücksetzen") { resetFilters() }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .fixedSize()
    }
    .padding(.horizontal, 2)
    return Group {
      // Snapshots: ohne Scroll-Container, sonst bleibt die Zeile im Renderer leer.
      if snapshot { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
    }
  }

  /// Höhe der Filter-Zeile für die Begrenzung der Liste (0, wenn keine Filter aktiv sind).
  private var activeRowHeight: CGFloat { activeFilters.isEmpty ? 0 : 30 }

  private func toggleStatus(_ s: TaskStatus) {
    if statusFilter.contains(s) { statusFilter.remove(s) } else { statusFilter.insert(s) }
  }

  private func toggleTag(_ name: String) {
    if TagLogic.contains(tagFilter, name: name) { tagFilter = TagLogic.removing(name, from: tagFilter) } else { tagFilter.append(name) }
  }

  private func toggleSource(_ s: TaskSourceChoice) {
    if sourceFilter.contains(s) { sourceFilter.remove(s) } else { sourceFilter.insert(s) }
  }

  private func toggleDue(_ d: TaskDueChoice) {
    if dueFilter.contains(d) { dueFilter.remove(d) } else { dueFilter.insert(d) }
  }

  private func removeFilter(_ f: TaskViewFilter) {
    switch f {
    case .status(let s): statusFilter.remove(s)
    case .tag(let name): tagFilter = TagLogic.removing(name, from: tagFilter)
    case .source(let s): sourceFilter.remove(s)
    case .due(let d): dueFilter.remove(d)
    }
  }

  /// Setzt nur die Filter (Stand, Kennzeichen, Quelle, Fälligkeit) zurück; die Gruppierung bleibt.
  private func resetFilters() {
    statusFilter = []
    tagFilter = []
    sourceFilter = []
    dueFilter = []
  }

  /// Merkt Gruppierung und Filter. Snapshots schreiben nichts.
  private func savePrefs() {
    guard !snapshot else { return }
    TaskViewPrefs(grouping: grouping, statuses: statusFilter, tags: tagFilter, sources: sourceFilter, due: dueFilter).store()
  }

  /// Kategorie-Zeile: "Alle", je Kategorie mit Symbol, "+" öffnet die Eingabe für eine neue Kategorie.
  private var categoryRow: some View {
    let chips = HStack(spacing: 6) {
      ChoiceChip(text: "Alle", selected: categoryFilter == nil) { categoryFilter = nil }.fixedSize()
      ForEach(defs) { d in
        ChoiceChip(text: d.name, symbol: d.symbol, selected: categoryFilter == d.id) { categoryFilter = d.id }
          .fixedSize()
          .accessibilityLabel("Kategorie \(d.name)")
      }
      ChoiceChip(text: "+", selected: addingCategory) {
        withAnimation(Theme.spring) { addingCategory.toggle() }
        newCategoryFocused = addingCategory
      }
      .fixedSize()
      .accessibilityLabel("Neue Kategorie")
      if visibleFolders.isEmpty { addFolderControl }
    }
    .padding(.horizontal, 2)
    return Group {
      // Snapshots: ohne Scroll-Container, sonst bleibt die Zeile im Renderer leer.
      if snapshot { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
    }
  }

  /// Eingabe für „Neue Kategorie“: Name, Symbol aus einer festen Auswahl, Anlegen (Enter) oder Abbrechen (Esc).
  private var categoryEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField("Neue Kategorie", text: $newCategoryName)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .frame(width: 140)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(Theme.capsule))
          .focused($newCategoryFocused)
          .onSubmit(addCategory)
          .onExitCommand(perform: cancelCategory)
          .accessibilityLabel("Name der neuen Kategorie")
        Button("Anlegen", action: addCategory)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Abbrechen", action: cancelCategory)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
      }
      WrapLayout(spacing: 4) {
        ForEach(TaskCategoryLogic.symbols, id: \.self) { s in
          Button { newCategorySymbol = s } label: { Image(systemName: s).font(.system(size: 11)) }
            .buttonStyle(RoundIconButtonStyle(size: 22, filled: newCategorySymbol == s))
            .accessibilityLabel("Symbol \(s)")
        }
      }
      if let categoryError { Text(categoryError).font(.system(size: 11)).foregroundStyle(Theme.red) }
    }
    .padding(.horizontal, 2)
  }

  /// Ordner-Zeile: "Alle" und die Ordner der gewählten Kategorie (bei Alle: die ohne Kategorie), "+ Ordner" legt
  /// den neuen Ordner in dieser Kategorie an.
  private var folderRow: some View {
    let chips = HStack(spacing: 6) {
      ChoiceChip(text: "Alle", selected: folderFilter == nil) { folderFilter = nil }.fixedSize()
      ForEach(visibleFolders) { folderChip($0) }
      addFolderControl
    }
    .padding(.horizontal, 2)
    return Group {
      // Snapshots: ohne Scroll-Container, sonst bleibt die Zeile im Renderer leer.
      if snapshot { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
    }
  }

  /// "+ Ordner" oder das Eingabefeld dafür (Enter legt an, Esc bricht ab).
  @ViewBuilder private var addFolderControl: some View {
    if categoryFilter == nil {
      EmptyView()  // Ordner gehören immer zu einer Kategorie: erst Kategorie wählen
    } else if addingFolder {
      TextField("Ordnername", text: $newFolderName)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .frame(width: 120)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.capsule))
        .focused($newFolderFocused)
        .onSubmit(addFolder)
        .onExitCommand { addingFolder = false; newFolderName = "" }
        .accessibilityLabel("Ordnername")
    } else {
      ChoiceChip(text: "+ Ordner", selected: false) {
        addingFolder = true
        newFolderFocused = true
      }
      .fixedSize()
      .accessibilityLabel("Neuer Ordner")
    }
  }

  @ViewBuilder private func folderChip(_ f: TaskFolder) -> some View {
    if renamingFolder == f.id {
      TextField("Ordnername", text: $renameDraft)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .frame(width: 120)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.capsule))
        .focused($renameFocused)
        .onSubmit { rename(f) }
        .onExitCommand { renamingFolder = nil }
        .accessibilityLabel("Ordner umbenennen")
    } else {
      let n = TaskFolderLogic.openCount(tasks, folder: f.id)
      ChoiceChip(text: "\(f.name) (\(n))", symbol: "folder", selected: folderFilter == f.id) { folderFilter = f.id }
        .fixedSize()
        .accessibilityLabel("Ordner \(f.name), \(n) offen")
        .contextMenu {
          Menu("Kategorie ändern…") {
            ForEach(defs) { d in
              Button { setFolderCategory(f, d.id) } label: {
                Label(d.name, systemImage: f.categoryId == d.id ? "checkmark" : d.symbol)
              }
            }
            Divider()
            Button { setFolderCategory(f, nil) } label: {
              Label("Keine", systemImage: f.categoryId == nil ? "checkmark" : "minus")
            }
          }
          Button("Umbenennen") {
            renameDraft = f.name
            renamingFolder = f.id
            renameFocused = true
          }
          Button("Löschen", role: .destructive) {
            deletingFolder = f
            confirmDeleteFolder = true
          }
        }
    }
  }

  /// Ordner in der gewählten Kategorie anlegen (bei Alle ohne Kategorie).
  private func addFolder() {
    let name = newFolderName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { addingFolder = false; return }
    Task {
      let r = await model.services.addTaskFolder(name: name, categoryId: categoryFilter)
      error = await ViewActions.finish(model, r.errorMessage, success: nil)
      if error == nil { newFolderName = ""; addingFolder = false }
    }
  }

  private func rename(_ f: TaskFolder) {
    let name = renameDraft.trimmingCharacters(in: .whitespaces)
    renamingFolder = nil
    guard !name.isEmpty, name != f.name else { return }
    Task { error = await ViewActions.renameFolder(model, id: f.id, name: name) }
  }

  private func deleteFolder(_ f: TaskFolder) {
    if folderFilter == f.id { folderFilter = nil }
    Task { error = await ViewActions.deleteFolder(model, id: f.id) }
  }

  /// Ordner in eine Kategorie verschieben (nil = keine). Die Zeile springt dann in die andere Kategorie.
  private func setFolderCategory(_ f: TaskFolder, _ categoryId: String?) {
    Task {
      let r = await model.services.setTaskFolderCategory(f.id, categoryId: categoryId)
      error = await ViewActions.finish(model, r.errorMessage, success: .itemAdded)
    }
  }

  /// Ein gewählter Ordner, der in der sichtbaren Kategorie nicht mehr liegt, wird abgewählt.
  private func dropHiddenFolderFilter() {
    if let sel = folderFilter, !visibleFolders.contains(where: { $0.id == sel }) { folderFilter = nil }
  }

  /// Neue Kategorie prüfen, speichern (Einstellungen) und gleich auswählen.
  private func addCategory() {
    var list = defs
    if let err = TaskCategoryLogic.add(name: newCategoryName, symbol: newCategorySymbol, to: &list) {
      categoryError = err
      return
    }
    let id = TaskCategoryLogic.id(from: newCategoryName)
    Task {
      _ = await model.services.updateSettings(SettingsPatch(taskCategories: list), apiKey: nil)
      await model.refresh()
      categoryFilter = id
      categoryError = nil
      newCategoryName = ""
      newCategorySymbol = "tag.fill"
      withAnimation(Theme.spring) { addingCategory = false }
    }
  }

  private func cancelCategory() {
    categoryError = nil
    newCategoryName = ""
    withAnimation(Theme.spring) { addingCategory = false }
  }

  /// Herkunfts-Zeile der gewählten Kategorie: „Alle“, „Eigene“, je Notion-Zugang ein Chip mit seinem Namen.
  private var originRow: some View {
    HStack(spacing: 5) {
      OriginChip(text: "Alle", selected: originFilter == nil) { originFilter = nil }
      OriginChip(text: "Eigene", selected: originFilter == .own) {
        originFilter = originFilter == .own ? nil : .own
      }
      ForEach(originAccounts) { a in
        OriginChip(text: a.name, selected: originFilter == .account(a.id)) {
          originFilter = originFilter == .account(a.id) ? nil : .account(a.id)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, 14)
    .padding(.horizontal, 2)
  }

  private var addRow: some View {
    InputCapsule(placeholder: "Neue Aufgabe…", text: $title, focusTick: focusTick) {
      DurationMenu(minutes: $newMinutes)
      RecurrenceMenu(recurrence: $newRecurrence, showsTitle: newRecurrence != nil)
      Button {
        withAnimation(Theme.spring) {
          showDue.toggle()
          if showDue && dueMode == .none { dueMode = .today }
        }
      } label: {
        if let text = dueChipText {
          Label(text, systemImage: "calendar").font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.amber).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.capsule))
        } else {
          Image(systemName: "calendar.badge.plus")
        }
      }
      .buttonStyle(RoundIconButtonStyle(size: 26, tint: dueMode == .none ? Theme.secondary : Theme.amber))
      .help("Fälligkeit")
      .accessibilityLabel("Fälligkeit")
      .accessibilityValue(dueChipText ?? "ohne")
      Button(action: add) { Image(systemName: "plus") }
        .buttonStyle(RoundIconButtonStyle(size: 26, filled: true))
        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        .help("Aufgabe anlegen")
        .accessibilityLabel("Aufgabe anlegen")
    }
    .onSubmit(add)
    .onAppear {
      guard Self.focusInputOnAppear else { return }
      Self.focusInputOnAppear = false
      focusTick += 1
    }
  }

  /// Gesetzte Fälligkeit als kurzer Text neben dem Symbol; ohne Fälligkeit nichts.
  private var dueChipText: String? {
    switch dueMode {
    case .none: nil
    case .today: "heute"
    case .tomorrow: "morgen"
    case .custom: GermanDate.short(LocalTime.formatDate(pickedDate))
    }
  }

  private var dueRow: some View {
    DueChips(mode: $dueMode, withTime: $withTime, pickedDate: $pickedDate, pickedTime: $pickedTime)
  }

  private var dueValue: String? {
    TaskLogic.dueString(dueMode, today: LocalTime.datePart(now), custom: LocalTime.formatDate(pickedDate),
                        time: withTime ? LocalTime.formatTime(pickedTime) : nil)
  }

  private var doneSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      Button {
        showDone.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(showDone ? 90 : 0))
          Text("Erledigt").font(.system(size: 11, weight: .semibold)).textCase(.uppercase).kerning(0.4)
          Text("\(done.count)").font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Theme.capsule))
            .contentTransition(.numericText())
          Spacer()
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.top, 6)
      if showDone {
        ForEach(done) { t in
          TaskRow(task: t, now: now, completing: false, onToggle: { toggle(t) }, notes: allNotes, categories: defs,
                  notionCategories: notionCats, notionAccountName: accountName(t), knownTags: tagNames)
            .id(t.id)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Theme.blue.opacity(flashTaskId == t.id ? 0.22 : 0)))
            .transition(Theme.rowTransition)
        }
      }
    }
  }

  private func add() {
    let due = dueValue
    // „#wort“ im Titel wird Kennzeichen und fällt aus dem Titel.
    let parsed = TagLogic.extractHashtags(from: title)
    let recurrence = newRecurrence
    let minutes = newMinutes
    Task {
      // Eingabe leeren, sobald die Aufgabe existiert: ein Kategorie-Fehler danach
      // zeigt nur die Meldung, ein erneutes Absenden würde sonst doppelt anlegen.
      error = await ViewActions.addTask(model, title: parsed.title, due: due, category: categoryFilter.map { TaskCategory(rawValue: $0) },
                                        folderId: folderFilter,
                                        recurrence: recurrence, minutes: minutes, tags: parsed.tags, onCreated: {
        title = ""
        newRecurrence = nil
        newMinutes = nil
        withAnimation(Theme.spring) { showDue = false; dueMode = .none; withTime = false }
      })
    }
  }

  private func toggle(_ t: TabyTask) {
    if t.done {
      Task { error = await ViewActions.setTaskDone(model, id: t.id, done: false) }
      return
    }
    withAnimation(Theme.pop) { _ = completing.insert(t.id) }
    Task {
      try? await Task.sleep(nanoseconds: 380_000_000)
      error = await ViewActions.setTaskDone(model, id: t.id, done: true)
      completing.remove(t.id)
    }
  }
}

/// Nur Snapshots: Notion-Zugänge, Quellen und die Kategorie je Notion-Aufgabe, wenn `model.state` fehlt.
struct NotionOverride {
  let accounts: [NotionAccount]
  let sources: [NotionSource]
  let categories: [String: String]
}

/// Kategorie-Feld einer Aufgabenzeile: ein Menü mit allen Kategorien. Bei Notion nur das Zeichen mit Hinweis,
/// denn die Kategorie kommt vom Zugang. Im Snapshot nur das Zeichen (ein Menü zeichnet sich dort gelb).
struct TaskCategoryButton<Items: View>: View {
  /// Gewählte Kategorie (bei Notion die des Zugangs); nil = keine.
  let current: TaskCategoryDef?
  /// Name des Notion-Zugangs; nil = eigene Aufgabe mit Menü.
  let notionAccount: String?
  @ViewBuilder let items: () -> Items
  @Environment(\.tabySnapshot) private var snapshot

  private var name: String { current?.name ?? "Keine" }

  private var help: String {
    if let notionAccount { return "Kategorie kommt vom Notion-Zugang „\(notionAccount)“ – in den Einstellungen änderbar" }
    return current.map { "Kategorie: \($0.name)" } ?? "Kategorie setzen"
  }

  private var glyph: some View {
    Image(systemName: current?.symbol ?? "tag")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(current == nil ? Theme.secondary : Theme.blue)
      .frame(width: 22, height: 22)
      .background(Circle().fill(Theme.capsule))
  }

  var body: some View {
    if notionAccount != nil || snapshot {
      glyph
        .help(help)
        .accessibilityLabel(notionAccount == nil ? "Kategorie: \(name), Menü" : "Kategorie: \(name), aus Notion")
    } else {
      Menu { items() } label: { glyph }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel("Kategorie: \(name), Menü")
    }
  }
}

/// Einordnen-Hinweis für die Rückgängig-Leiste; gilt nur, solange der Rückgängig-Stand der Aufgabenliste derselbe ist.
private struct MoveFlash: Equatable {
  let label: String
  let undoLabel: String?
}

/// Kleiner, dezenter Chip für die Herkunfts-Zeile (sonst wie ChoiceChip).
private struct OriginChip: View {
  let text: String
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      Text(text)
        .font(.system(size: 11, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Color.black : Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(selected ? Color.white.opacity(0.92) : (hover ? Theme.capsuleHover : Theme.capsule)))
        .contentShape(Capsule())
    }
    .buttonStyle(PressScaleStyle())
    .onHover { hover = $0 }
    .animation(Theme.snappy, value: selected)
  }
}

/// Eine Aufgabe: Häkchen, Titel (Doppelklick = bearbeiten), Fälligkeit, Papierkorb.
struct TaskRow: View {
  let task: TabyTask
  let now: String
  let completing: Bool
  let onToggle: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot
  @State private var editing: Bool
  @State private var draft: String
  @State private var dueMode: TaskLogic.DueMode
  @State private var withTime: Bool
  @State private var pickedDate: Date
  @State private var pickedTime: Date
  @State private var recurrenceDraft: TaskRecurrence?
  @State private var expanded: Bool
  @FocusState private var focused: Bool
  /// Alle Notizen; die Zeile zeigt die dieser Aufgabe zugeordneten.
  let notes: [Note]
  /// Kategorien aus den Einstellungen (Symbol und Menü).
  let categories: [TaskCategoryDef]
  /// Nach dem Einordnen über das Menü: die neue Kennung (nil = keine).
  let onAssigned: (String?) -> Void
  /// Kategorie je Notion-Aufgabe (Aufgaben-ID → Kategorie) und der Name ihres Zugangs.
  let notionCategories: [String: String]
  let notionAccountName: String?
  /// Alle bekannten Kennzeichen für die Vorschläge im Kennzeichen-Feld.
  let knownTags: [String]
  /// Geplante Uhrzeit aus dem Tagesplan (nur auf „Heute“); sie zeigt sich, wenn sie von der Fälligkeit abweicht.
  let plannedTime: String?

  /// `autoEdit` startet direkt im Bearbeitungsmodus, `startExpanded` klappt die Details auf (für die Snapshots).
  init(task: TabyTask, now: String, completing: Bool, onToggle: @escaping () -> Void, autoEdit: Bool = false,
       notes: [Note] = [], startExpanded: Bool = false, categories: [TaskCategoryDef] = TaskCategoryDef.builtIn,
       notionCategories: [String: String] = [:], notionAccountName: String? = nil,
       onAssigned: @escaping (String?) -> Void = { _ in }, knownTags: [String] = [], plannedTime: String? = nil) {
    self.task = task
    self.now = now
    self.completing = completing
    self.onToggle = onToggle
    self.notes = notes
    self.categories = categories
    self.notionCategories = notionCategories
    self.notionAccountName = notionAccountName
    self.onAssigned = onAssigned
    self.knownTags = knownTags
    self.plannedTime = plannedTime
    let s = Self.dueState(task, now: now)
    _expanded = State(initialValue: startExpanded)
    _editing = State(initialValue: autoEdit)
    _draft = State(initialValue: task.title)
    _dueMode = State(initialValue: s.mode)
    _withTime = State(initialValue: s.withTime)
    _pickedDate = State(initialValue: s.date)
    _pickedTime = State(initialValue: s.time)
    _recurrenceDraft = State(initialValue: task.recurrence)
  }

  /// Auswahl-Zustand aus der gespeicherten Fälligkeit (Ohne/Heute/Morgen/Datum, optional Uhrzeit).
  private static func dueState(_ task: TabyTask, now: String) -> (mode: TaskLogic.DueMode, withTime: Bool,
                                                                 date: Date, time: Date) {
    let d = TaskLogic.dueDraft(task.due, today: LocalTime.datePart(now))
    let date = LocalTime.parse(d.date ?? now) ?? Date()
    let time = LocalTime.parse(d.time.map { "\(LocalTime.datePart(now))T\($0)" } ?? now) ?? Date()
    return (d.mode, d.time != nil, date, time)
  }

  private var checked: Bool { task.done || completing }
  private var linkedNotes: [Note] { TaskNotesLogic.notes(of: task.id, in: notes) }

  /// Doppelklick bearbeitet, einfacher Klick auf die Zeile klappt die Details auf (nicht im Bearbeitungsmodus).
  private var rowTap: some Gesture {
    TapGesture(count: 2).onEnded { startEdit() }
      .exclusively(before: TapGesture().onEnded { withAnimation(Theme.spring) { expanded.toggle() } })
  }
  private var prioritized: Bool { model.state?.taskPriority.contains(task.id) ?? false }
  private var folderList: [TaskFolder] { model.state?.taskFolders ?? [] }

  private func setFolder(_ id: String?) {
    Task { _ = await ViewActions.setTaskFolder(model, id: task.id, folderId: id) }
  }

  /// Kategorie aus dem Menü setzen (nil = keine). Unveränderte Wahl tut nichts.
  private func assign(_ categoryId: String?) {
    guard let patch = TaskCategoryLogic.categoryPatch(choice: categoryId, current: task.category?.rawValue,
                                                      defs: categories) else { return }
    Task {
      _ = await ViewActions.finish(model, await model.services.updateTask(task.id, TaskPatch(category: patch)).errorMessage,
                                   success: nil)
      await model.refresh()
      onAssigned(categoryId)
    }
  }

  /// Eigene und geerbte Kennzeichen (von verknüpften Notizen) für die Zeile.
  private var chipOwn: [String] { TagLogic.ownAndInherited(task, notes: notes).own }
  private var chipInherited: [String] { TagLogic.ownAndInherited(task, notes: notes).inherited }
  private var chipTags: [String] { chipOwn + chipInherited }

  private func setTags(_ tags: [String]) {
    Task { _ = await ViewActions.setTaskTags(model, id: task.id, tags: tags) }
  }

  private func togglePriority() {
    let current = model.state?.taskPriority ?? []
    let ids = prioritized ? current.filter { $0 != task.id } : current + [task.id]
    Task {
      _ = await ViewActions.finish(model, await model.services.setTaskPriority(taskIds: ids).errorMessage, success: nil)
      await model.refresh()
    }
  }

  var body: some View {
    HoverRow { hover in
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          CheckCircle(checked: checked, action: onToggle)
          if editing && snapshot {
            Text(draft).font(.system(size: 13)).foregroundStyle(Theme.text)
          } else if editing {
            TextField("", text: $draft)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .foregroundStyle(Theme.text)
              .focused($focused)
              .onSubmit(commit)
              .onExitCommand { editing = false }
          } else {
            // Klick nur auf Titel und Leerraum: an der ganzen Zeile schluckte die Geste Haken und Papierkorb.
            HStack(spacing: 0) {
              Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(checked ? Theme.tertiary : Theme.text)
                .strikethrough(checked, color: Theme.tertiary)
                .lineLimit(2)
                .animation(Theme.spring, value: checked)
              Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .gesture(rowTap)
          }
          if editing { Spacer(minLength: 4) }
          if editing {
            // Speichern übernimmt Titel und Fälligkeit. Kein Speichern beim Verlassen des Feldes,
            // sonst würde ein Klick auf einen Fälligkeits-Chip die Bearbeitung beenden.
            Button(action: commit) { Image(systemName: "checkmark") }
              .buttonStyle(RoundIconButtonStyle(size: 22, filled: true))
              .help("Speichern")
              .accessibilityLabel("Speichern")
          } else if !task.done {
            if let planned = plannedTime, planned != GermanDate.time(task.due ?? "") {
              Text("geplant \(planned)").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.tertiary)
            }
            if let chip = TaskLogic.dueChip(task.due, now: now) { DueChipView(info: chip) }
          }
          if !editing && !task.done { TaskStatusChip(status: task.status) }
          if !editing && !linkedNotes.isEmpty {
            Label("\(linkedNotes.count)", systemImage: "note.text")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Theme.secondary)
              .help("\(linkedNotes.count) verknüpfte Notizen")
              .accessibilityLabel("\(linkedNotes.count) verknüpfte Notizen")
          }
          if !editing, let r = task.recurrence {
            Image(systemName: "arrow.triangle.2.circlepath")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(Theme.secondary)
              .help("Wiederholt sich: \(ViewSupportLogic.recurrenceTitle(r))")
              .accessibilityLabel("Wiederholt sich, \(ViewSupportLogic.recurrenceTitle(r))")
          }
          if hover && !editing {
            HStack(spacing: 0) {
              TaskCategoryButton(current: currentCategory, notionAccount: isNotion ? (notionAccountName ?? "Notion") : nil) {
                categoryItems
              }
              Menu {
                ForEach(folderList) { f in
                  Button { setFolder(f.id) } label: {
                    Label(f.name, systemImage: task.folderId == f.id ? "checkmark" : "folder")
                  }
                }
                if folderList.isEmpty { Text("Noch keine Ordner") }
                if task.folderId != nil {
                  Divider()
                  Button("Aus Ordner nehmen") { setFolder(nil) }
                }
              } label: {
                Image(systemName: task.folderId == nil ? "folder" : "folder.fill")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(task.folderId == nil ? Theme.secondary : Theme.blue)
                  .frame(width: 22, height: 22)
                  .background(Circle().fill(Theme.capsule))
              }
              .menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .fixedSize()
              .help("In Ordner verschieben")
              .accessibilityLabel("In Ordner verschieben")
              if !task.done {
                Button {
                  Task {
                    _ = await ViewActions.finish(model, await model.services.startFocus(taskId: task.id, minutes: nil).errorMessage, success: .itemAdded)
                    await model.refresh()
                  }
                } label: { Image(systemName: "play.fill") }
                  .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.amber))
                  .help("Fokus starten")
                Button { togglePriority() } label: { Image(systemName: prioritized ? "star.fill" : "star") }
                  .buttonStyle(RoundIconButtonStyle(size: 22, tint: prioritized ? Theme.amber : Theme.secondary))
                  .help(prioritized ? "Nicht mehr priorisieren" : "Priorisieren")
                Button(action: startEdit) { Image(systemName: "pencil") }
                  .buttonStyle(RoundIconButtonStyle(size: 22))
                  .help("Bearbeiten")
              }
              Button {
                Task { _ = await ViewActions.deleteTask(model, id: task.id) }
              } label: { Image(systemName: "trash") }
                .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.red.opacity(0.8)))
                .help("Löschen")
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
        }
        .contentShape(Rectangle())
        // Aufgeklappt zeigt der Kennzeichen-Editor die eigenen Chips schon; geerbte bleiben hier sichtbar.
        if !editing && !expanded && !chipTags.isEmpty {
          TagChipList(own: chipOwn, inherited: chipInherited)
            .padding(.leading, 28)
        }
        if expanded && !editing {
          if !task.done {
            HStack(spacing: 8) {
              TaskStatusMenu(status: task.status) { s in
                Task { _ = await ViewActions.setTaskStatus(model, id: task.id, status: s) }
              }
              DurationMenu(minutes: Binding(get: { task.minutes }, set: { m in
                Task { _ = await model.services.updateTask(task.id, TaskPatch(minutes: m ?? 0)); await model.refresh() }
              }), showsTitle: true)
              Button(action: startEdit) { Label("Neu planen", systemImage: "calendar.badge.clock").lineLimit(1) }
                .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
              Spacer(minLength: 0)
            }
            .padding(.leading, 28)
          }
          TagEditor(tags: task.tags, known: knownTags, onChange: setTags)
            .padding(.leading, 28)
          TaskNotesDetail(task: task, notes: linkedNotes)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if editing {
          DueChips(mode: $dueMode, withTime: $withTime, pickedDate: $pickedDate, pickedTime: $pickedTime)
            .transition(.move(edge: .top).combined(with: .opacity))
          RecurrenceMenu(recurrence: $recurrenceDraft, showsTitle: true)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
    }
    .contextMenu {
      if !isNotion { Menu("Kategorie") { categoryItems } }
    }
  }

  /// Notion-Aufgaben: die Kategorie kommt vom Zugang (`notionTaskCategories`), nie eigene Kategorie.
  private var isNotion: Bool { TaskCategoryLogic.isNotionTask(task.id, notionCategories: notionCategories) }

  /// Angezeigte Kategorie: bei Notion die des Zugangs, sonst die eigene. Unbekannte Kennung zählt als keine.
  private var currentCategory: TaskCategoryDef? {
    let id = isNotion ? notionCategories[task.id] : task.category?.rawValue
    return categories.first { $0.id == id }
  }

  /// Menüeinträge für Schaltfläche und Kontextmenü.
  @ViewBuilder private var categoryItems: some View {
    ForEach(categories) { d in
      Button { assign(d.id) } label: {
        Label(d.name, systemImage: currentCategory?.id == d.id ? "checkmark" : d.symbol)
      }
    }
    Divider()
    Button { assign(nil) } label: {
      Label("Keine Kategorie", systemImage: currentCategory == nil ? "checkmark" : "minus")
    }
  }

  private func startEdit() {
    let s = Self.dueState(task, now: now)
    draft = task.title
    dueMode = s.mode
    withTime = s.withTime
    pickedDate = s.date
    pickedTime = s.time
    recurrenceDraft = task.recurrence
    editing = true
    focused = true
  }

  /// Titel und Fälligkeit speichern; nur geänderte Felder gehen an den Kern.
  private func commit() {
    guard editing else { return }
    editing = false
    let newTitle = draft
    let newDue = TaskLogic.dueString(dueMode, today: LocalTime.datePart(now), custom: LocalTime.formatDate(pickedDate),
                                     time: withTime ? LocalTime.formatTime(pickedTime) : nil)
    let titleChanged = newTitle != task.title
    let dueChanged = (newDue ?? "") != (task.due ?? "")
    let recurrence = recurrenceDraft
    let recurrenceChanged = recurrence != task.recurrence
    Task {
      if titleChanged { await ViewActions.renameTask(model, id: task.id, title: newTitle) }
      if dueChanged { await ViewActions.setTaskDue(model, id: task.id, due: newDue) }
      if recurrenceChanged {
        _ = await model.services.updateTask(task.id, TaskPatch(recurrence: ViewSupportLogic.recurrencePatch(recurrence)))
        await model.refresh()
      }
    }
  }
}

/// Fälligkeits-Auswahl: Ohne / Heute / Morgen / Datum, optional Uhrzeit. Im Add-Formular und beim Bearbeiten.
struct DueChips: View {
  @Binding var mode: TaskLogic.DueMode
  @Binding var withTime: Bool
  @Binding var pickedDate: Date
  @Binding var pickedTime: Date

  var body: some View {
    HStack(spacing: 6) {
      ChoiceChip(text: "Ohne", selected: mode == .none) { mode = .none }.fixedSize()
      ChoiceChip(text: "Heute", selected: mode == .today) { mode = .today }.fixedSize()
      ChoiceChip(text: "Morgen", selected: mode == .tomorrow) { mode = .tomorrow }.fixedSize()
      if mode == .custom {
        CompactDatePicker(date: $pickedDate)
      } else {
        ChoiceChip(text: "Datum…", symbol: "calendar", selected: false) { mode = .custom }.fixedSize()
      }
      Spacer(minLength: 0)
      if mode != .none {
        ChoiceChip(text: "Uhrzeit", symbol: "clock", selected: withTime) { withTime.toggle() }.fixedSize()
        if withTime {
          CompactDatePicker(date: $pickedTime, time: true)
        }
      }
    }
    .padding(.horizontal, 2)
  }
}
