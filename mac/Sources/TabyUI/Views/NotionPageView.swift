// Reiter "Notion": zeigt die aus Notion importierten Aufgaben/Tickets als
// Liste (Paket 9). Abhaken hier hakt auch in Notion ab (ein Richtung: Lumi →
// Notion, nur die Checkbox, siehe docs/decisions/0009-notion-tasks.md).
// Paket 11: drei feste Kategorien (Tickets, Weekly, To-dos); Quellen innerhalb
// einer Kategorie nur als Unterreiter, wenn es mehr als eine gibt.
// Weekly: Wochen-Chips in einer zweiten Zeile, darunter die Häkchen der gewählten Woche.
import AppKit
import SwiftUI
import TabyCore

struct NotionPageView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @Environment(\.tabySnapshot) private var snapshot
  @State private var syncing = false
  @State private var error: String?
  @State private var completing: Set<String> = []
  /// Gewählte Kategorie; ohne Auswahl die erste sichtbare.
  @State private var selectedCategory: NotionSourceCategory?
  /// Gewählte Quelle je Kategorie; ohne Auswahl die erste der Kategorie.
  @State private var selectedSourceIds: [NotionSourceCategory: String] = [:]
  /// Gewählte Woche (Weekly); ohne Auswahl die neueste. Wird beim Quellenwechsel zurückgesetzt.
  @State private var selectedWeek: String?
  /// Ausklapp-Zustand der Aufgaben-Inhalte; fehlt ein Eintrag, gilt der Standard der Zeile.
  @State private var detailOpen: [String: Bool]
  @State private var todosDoneCollapsed = true
  @State private var ticketsOpenCollapsed = false
  @State private var ticketsDoneCollapsed = true

  init(state: AppState, openTicket: String? = nil) {
    self.state = state
    _detailOpen = State(initialValue: openTicket.map { [$0: true] } ?? [:])
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var tasks: [TabyTask] { state.notionLinkedTasks }
  private var open: [TabyTask] { TaskLogic.sortOpen(tasks) }

  /// Aufgaben einer Quelle (über `notionSourceLinks`).
  private func tasks(from sourceId: String) -> [TabyTask] {
    Self.tasks(tasks, source: sourceId, links: state.notionSourceLinks)
  }
  /// Reine Zuordnung Aufgabe → Quelle, testbar ohne Ansicht.
  static func tasks(_ all: [TabyTask], source sourceId: String, links: [String: String]) -> [TabyTask] {
    all.filter { links[$0.id] == sourceId }
  }

  /// Feste Reihenfolge der Kategorien im Reiter.
  private static let categoryOrder: [NotionSourceCategory] = [.tickets, .weekly, .todos]
  /// Kategorien mit mindestens einer Quelle, in fester Reihenfolge.
  static func visibleCategories(_ sources: [NotionSource]) -> [NotionSourceCategory] {
    categoryOrder.filter { c in sources.contains { $0.category == c } }
  }
  private var categories: [NotionSourceCategory] { Self.visibleCategories(state.notionSources) }
  private var currentCategory: NotionSourceCategory? {
    if let c = selectedCategory, categories.contains(c) { return c }
    return categories.first
  }
  /// Quellen der gewählten Kategorie.
  private var categorySources: [NotionSource] {
    guard let c = currentCategory else { return [] }
    return state.notionSources.filter { $0.category == c }
  }
  /// Gewählte Quelle innerhalb der Kategorie; ohne Quellen: nil (alle Aufgaben, flach).
  private var currentSource: NotionSource? {
    if let id = selectedSourceIds[currentCategory ?? .tickets], let s = categorySources.first(where: { $0.id == id }) {
      return s
    }
    return categorySources.first
  }
  private var shown: [TabyTask] { currentSource.map { tasks(from: $0.id) } ?? tasks }

  /// Offene Aufgaben der Kategorie (Zähler im Reiter).
  private func openCount(_ c: NotionSourceCategory) -> Int { countTasks(c, done: false) }

  private func countTasks(_ c: NotionSourceCategory, done: Bool) -> Int {
    let ids = Set(state.notionSources.filter { $0.category == c }.map(\.id))
    return tasks.filter { $0.done == done && ids.contains(state.notionSourceLinks[$0.id] ?? "") }.count
  }

  /// Chip-Text: offene Zahl, bei nur erledigten Aufgaben zusätzlich die erledigten.
  private func chipLabel(_ c: NotionSourceCategory) -> String {
    let open = openCount(c), done = countTasks(c, done: true)
    return open == 0 && done > 0 ? "\(c.title) 0 (\(done) erledigt)" : "\(c.title) \(open)"
  }

  /// Kopfzahl = Zähler der gewählten Kategorie, damit Kopf und Chip dieselbe Zahl zeigen.
  private var headerOpen: Int { currentCategory.map(openCount) ?? open.count }

  /// Letzte Abholung älter als eine Stunde (Vergleich über lokale Zeitstrings).
  static func syncStale(_ at: String, now: String) -> Bool {
    guard let a = LocalTime.parse(at), let n = LocalTime.parse(now) else { return false }
    return n.timeIntervalSince(a) > 3600
  }

  /// Wochen-Quelle: Aufgaben nach Woche gruppiert (neueste zuerst), sonst nil.
  private var weekGroups: [(name: String, tasks: [TabyTask])]? {
    guard currentCategory == .weekly else { return nil }
    return Self.weekGroups(shown, groups: state.notionTaskGroups)
  }

  /// Reine Gruppierung nach Woche, testbar ohne Ansicht. Wochen absteigend sortiert
  /// („KW 42“ vor „KW 41“, „2026-10-13 · …“ vor „2026-10-08 · …“); „Ohne Woche“ immer zuletzt.
  /// Innerhalb einer Woche: erst Aufgaben mit Inhalt, dann übrige offene, dann erledigte.
  static func weekGroups(_ tasks: [TabyTask], groups: [String: String]) -> [(name: String, tasks: [TabyTask])] {
    let none = "Ohne Woche"
    let byName = Dictionary(grouping: tasks) { groups[$0.id].flatMap { $0.isEmpty ? nil : $0 } ?? none }
    let names = byName.keys.filter { $0 != none }
      .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    return (names + (byName[none] == nil ? [] : [none])).map { name in
      (name: name, tasks: weekOrder(byName[name] ?? []))
    }
  }

  /// Reihenfolge in einer Woche: mit Inhalt zuerst, dann übrige offene, dann erledigte.
  static func weekOrder(_ members: [TabyTask]) -> [TabyTask] {
    let open = TaskLogic.sortOpen(members)
    let withNotes = open.filter { hasContent($0) }
    let rest = open.filter { !hasContent($0) }
    return withNotes + rest + TaskLogic.sortDone(members)
  }

  /// Besprechung = Aufgabe mit Inhalt; ohne Inhalt ist sie ein To-do.
  static func hasContent(_ t: TabyTask) -> Bool { !(t.notes ?? "").isEmpty }

  /// Die To-dos einer Woche (ohne Besprechungen) in gespeicherter Reihenfolge: offene, dann erledigte.
  static func weekTodos(_ members: [TabyTask], all: [TabyTask]) -> [TabyTask] {
    let ids = Set(members.map(\.id))
    let todos = all.filter { ids.contains($0.id) && !hasContent($0) }
    return todos.filter { !$0.done } + todos.filter(\.done)
  }

  /// Ein Eintrag der Woche: Besprechung mit einer Zuordnung je To-do-Zeile ihres Inhalts.
  struct WeekMeeting: Identifiable {
    let task: TabyTask
    /// Je To-do-Zeile (in Reihenfolge) die zugeordnete Wochen-Aufgabe, nil = keine.
    let todos: [TabyTask?]
    var id: String { task.id }
  }
  struct WeekPlan {
    let meetings: [WeekMeeting]
    /// To-dos der Woche, die keine Zeile im Inhalt findet (werden als Zeilen gezeigt).
    let unmatched: [TabyTask]
  }

  /// Aufbau einer Woche: Besprechungen mit ihren To-do-Zeilen, dazu die übrigen To-dos.
  /// `all`: alle verknüpften Aufgaben in gespeicherter Reihenfolge (bestimmt die To-do-Reihenfolge).
  static func weekPlan(_ members: [TabyTask], all: [TabyTask]) -> WeekPlan {
    let ids = Set(members.map(\.id))
    let meetings = weekOrder(members).filter { hasContent($0) }
    let todos = all.filter { ids.contains($0.id) && !hasContent($0) }
    let perMeeting = meetings.map { NotionBodyView.todoTexts($0.notes ?? "") }
    let matched = matchTodos(perMeeting.flatMap { $0 }, todos: todos)
    var offset = 0
    var plan: [WeekMeeting] = []
    for (m, texts) in zip(meetings, perMeeting) {
      plan.append(WeekMeeting(task: m, todos: Array(matched[offset..<offset + texts.count])))
      offset += texts.count
    }
    let used = Set(matched.compactMap { $0?.id })
    return WeekPlan(meetings: plan, unmatched: todos.filter { !used.contains($0.id) })
  }

  /// Ordnet den To-do-Zeilen (in Reihenfolge) Wochen-Aufgaben zu: die n-te Zeile zuerst der
  /// n-ten To-do-Aufgabe, wenn der Titel passt; sonst die erste noch freie mit gleichem Titel; sonst nil.
  static func matchTodos(_ texts: [String], todos: [TabyTask]) -> [TabyTask?] {
    var used = Set<String>()
    return texts.enumerated().map { n, text in
      let want = text.trimmingCharacters(in: .whitespaces)
      let same: (TabyTask) -> Bool = { t in
        !used.contains(t.id) && t.title.trimmingCharacters(in: .whitespaces) == want
      }
      let pick = (n < todos.count && same(todos[n])) ? todos[n] : todos.first(where: same)
      if let pick { used.insert(pick.id) }
      return pick
    }
  }

  /// Gewählte Woche: die gewählte, sofern es sie noch gibt, sonst die neueste (erste).
  static func weekSelection(_ names: [String], selected: String?) -> String? {
    if let selected, names.contains(selected) { return selected }
    return names.first
  }

  /// Datum am Anfang eines Wochennamens („2026-10-13 · …“) als [Jahr, Monat, Tag], sonst nil.
  private static func leadingDate(_ label: String) -> [Substring]? {
    let parts = label.prefix(10).split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
    return parts
  }

  /// Anzeige der Woche: „2026-10-13 · Weekly 1:1“ wird „13.10.2026 · Weekly 1:1“, alles andere bleibt.
  static func weekTitle(_ label: String) -> String {
    let rest = label.dropFirst(10)
    guard rest.hasPrefix(" · "), let parts = leadingDate(label) else { return label }
    return "\(parts[2]).\(parts[1]).\(parts[0])\(rest)"
  }

  /// Kürzt einen Chip-Text auf `limit` Zeichen mit „…“.
  static func clip(_ text: String, limit: Int = 24) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
  }

  /// Chip-Text einer Woche: „13.10.“ im selben Jahr wie `now`, sonst „13.10.25“; ohne Datum der Titel (gekürzt).
  static func weekChipLabel(_ groupLabel: String, now: String) -> String {
    guard let parts = leadingDate(groupLabel) else { return clip(groupLabel) }
    let sameYear = parts[0] == LocalTime.datePart(now).prefix(4)
    return sameYear ? "\(parts[2]).\(parts[1])." : "\(parts[2]).\(parts[1]).\(parts[0].suffix(2))"
  }

  /// Chip-Texte aller Wochen. Haben zwei Wochen dasselbe Datum, hängt der Titel an („13.10. · Weekly 2“).
  static func weekChipLabels(_ names: [String], now: String) -> [String] {
    let short = names.map { weekChipLabel($0, now: now) }
    return zip(names, short).map { name, label in
      guard short.filter({ $0 == label }).count > 1 else { return label }
      guard leadingDate(name) != nil else { return clip(name) }
      var title = name.dropFirst(10)
      if title.hasPrefix(" · ") { title = title.dropFirst(3) }
      return title.isEmpty ? label : clip("\(label) · \(title)")
    }
  }

  /// Ein Teil der Ticket-Zeile; `stale`: Datum älter als 14 Tage (wird bernsteinfarben).
  struct MetaPart: Equatable {
    let text: String
    let stale: Bool
  }

  /// Zeile unter dem Ticket: „Name · 13.10. · Status“. Nur vorhandene Teile; nil, wenn keiner da ist.
  static func metaLine(_ meta: NotionTaskMeta, now: String) -> [MetaPart]? {
    var parts: [MetaPart] = []
    if let by = meta.createdBy, !by.isEmpty { parts.append(MetaPart(text: by, stale: false)) }
    if let created = meta.createdAt, let date = dateLabel(created, now: now) {
      parts.append(MetaPart(text: date, stale: (GermanDate.dayDiff(created, now) ?? 0) > 14))
    }
    if let status = meta.status, !status.isEmpty { parts.append(MetaPart(text: status, stale: false)) }
    return parts.isEmpty ? nil : parts
  }

  /// „13.10.“ im selben Jahr wie `now`, sonst „13.10.25“; nil ohne gültiges Datum.
  static func dateLabel(_ created: String, now: String) -> String? {
    let parts = LocalTime.datePart(created).split(separator: "-")
    guard parts.count == 3 else { return nil }
    let sameYear = String(parts[0]) == String(LocalTime.datePart(now).prefix(4))
    return sameYear ? "\(parts[2]).\(parts[1])." : "\(parts[2]).\(parts[1]).\(parts[0].suffix(2))"
  }

  /// Ein Unterreiter je Kategorie; Quellen einer Kategorie nur bei mehr als einer.
  private var categoryRow: some View {
    HStack(spacing: 4) {
      ForEach(categories, id: \.self) { c in
        ChoiceChip(text: chipLabel(c), selected: currentCategory == c) {
          withAnimation(Theme.spring) { selectedCategory = c }
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var sourceRow: some View {
    HStack(spacing: 4) {
      ForEach(categorySources) { s in
        ChoiceChip(text: s.name.isEmpty ? "Notion-Seite" : s.name, selected: currentSource?.id == s.id) {
          withAnimation(Theme.spring) { selectedSourceIds[currentCategory ?? .tickets] = s.id }
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// Wochen-Chips (nur Weekly): neueste zuerst, „Ohne Woche“ zuletzt; Zähler = offene To-dos (ohne Besprechung).
  private func weekRow(_ groups: [(name: String, tasks: [TabyTask])]) -> some View {
    let labels = Self.weekChipLabels(groups.map(\.name), now: now)
    let current = Self.weekSelection(groups.map(\.name), selected: selectedWeek)
    let chips = HStack(spacing: 5) {
      ForEach(Array(groups.enumerated()), id: \.element.name) { i, g in
        WeekChip(text: labels[i], count: g.tasks.filter { !$0.done && !Self.hasContent($0) }.count, selected: g.name == current) {
          withAnimation(Theme.spring) { selectedWeek = g.name }
        }
      }
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 2)
    // Snapshots: ImageRenderer zeichnet ScrollView nicht, also dort die Reihe direkt (wie CappedScroll).
    return Group {
      if snapshot {
        chips
      } else {
        ScrollView(.horizontal, showsIndicators: false) { chips }
      }
    }
  }

  private func isDetailOpen(_ id: String, defaultOpen: Bool) -> Bool { detailOpen[id] ?? defaultOpen }

  private func toggleDetail(_ id: String, defaultOpen: Bool) {
    withAnimation(Theme.spring) { detailOpen[id] = !(detailOpen[id] ?? defaultOpen) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Notion", subtitle: headerOpen == 0 ? nil : "\(headerOpen) offen") {
        HStack(spacing: 8) {
          if let sync = state.notionTasksSync, let at = sync.lastSyncAt {
            Text("Zuletzt geholt: \(String(at.suffix(5))) Uhr")
              .font(.system(size: 11))
              .foregroundStyle(Self.syncStale(at, now: now) ? Theme.amber : Theme.secondary)
          }
          syncButton
        }
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if !state.notionTasksConnected {
        VStack(spacing: 8) {
          EmptyState(symbol: "doc.richtext", title: "Nicht verbunden",
                     subtitle: "Einstellungen → Kalender & Konten: Notion-Zugang mit Zugangscode, Kategorie und Quellen eintragen.")
          Button("Notion verbinden") { model.onDetach?(.settings) }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
      } else {
        if !categories.isEmpty { categoryRow }
        if categorySources.count > 1 { sourceRow }
        if shown.isEmpty {
          VStack(spacing: 8) {
            if state.notionSources.isEmpty {
              EmptyState(symbol: "doc.richtext", title: "Noch keine Notion-Quelle verbunden.",
                         subtitle: "In den Einstellungen Zugang, Kategorie und Quelle eintragen.")
              Button("Einstellungen öffnen") { model.onOpenTab?(.settings) }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            } else {
              EmptyState(symbol: "checkmark.circle", title: "Keine offenen Aufgaben.",
                         subtitle: syncing ? "Wird gerade geholt…" : "„Aktualisieren“ holt deine Notion-Aufgaben.")
            }
          }
          .frame(maxWidth: .infinity).padding(.vertical, 20)
        } else {
          if let groups = weekGroups { weekRow(groups) }
          CappedScroll(maxHeight: 262) {
            content
          }
        }
      }
    }
    .animation(Theme.spring, value: tasks)
    .onChange(of: currentSource?.id) { _, _ in selectedWeek = nil }
  }

  @ViewBuilder
  private var content: some View {
    if let groups = weekGroups {
      weekPanel(groups)
    } else if currentCategory == .todos {
      todoRows(shown)
    } else {
      ticketRows(shown)
    }
  }

  /// Tickets: offene wie `ticketOrder`, darunter erledigte; beide Abschnitte klappen zu (Erledigt startet zu).
  private func ticketRows(_ items: [TabyTask]) -> some View {
    let open = TaskLogic.sortOpen(items)
    let done = TaskLogic.sortDone(items)
    return VStack(alignment: .leading, spacing: 2) {
      if !open.isEmpty {
        CollapsibleSection(symbol: "circle", title: "Offen", count: open.count, collapsed: $ticketsOpenCollapsed) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(open) { t in ticketRow(t).transition(Theme.rowTransition) }
          }
        }
      }
      if !done.isEmpty {
        CollapsibleSection(symbol: "checkmark.circle", title: "Erledigt", count: done.count, collapsed: $ticketsDoneCollapsed) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(done) { t in ticketRow(t) }
          }
        }
        .padding(.top, 6)
      }
    }
  }

  /// Eine Ticket-Zeile: Titel mit Chevron, darunter Meta-Zeile und (aufgeklappt) der Inhalt.
  private func ticketRow(_ t: TabyTask) -> some View {
    let isOpen = isDetailOpen(t.id, defaultOpen: false)
    let meta = state.notionTaskMeta[t.id].flatMap { Self.metaLine($0, now: now) }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        taskRow(t)
        chevron(t.id, open: isOpen, defaultOpen: false)
      }
      .contentShape(Rectangle())
      .onTapGesture { toggleDetail(t.id, defaultOpen: false) }
      if let meta { metaText(meta).padding(.leading, 32) }
      if isOpen {
        detailBody(t.notes ?? "", pageId: state.notionTaskPages[t.id], checkTask: { _, _ in nil })
          .padding(.leading, 32)
      }
    }
  }

  /// To-dos: offene flach, erledigte eingeklappt.
  private func todoRows(_ items: [TabyTask]) -> some View {
    let openItems = TaskLogic.sortOpen(items)
    let doneItems = TaskLogic.sortDone(items)
    return VStack(alignment: .leading, spacing: 2) {
      ForEach(openItems) { t in taskRow(t).transition(Theme.rowTransition) }
      if !doneItems.isEmpty {
        CollapsibleSection(symbol: "checkmark.circle", title: "Erledigt", count: doneItems.count,
                           collapsed: $todosDoneCollapsed) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(doneItems) { t in taskRow(t) }
          }
        }
        .padding(.top, 6)
      }
    }
  }

  /// Gewählte Woche: Besprechung(en) als Kopfzeile, darunter die To-do-Häkchen der Woche,
  /// zuletzt je Besprechung „Ganze Seite“ (eingeklappt) mit dem Notion-Inhalt.
  @ViewBuilder
  private func weekPanel(_ groups: [(name: String, tasks: [TabyTask])]) -> some View {
    if let name = Self.weekSelection(groups.map(\.name), selected: selectedWeek),
       let members = groups.first(where: { $0.name == name })?.tasks {
      let plan = Self.weekPlan(members, all: tasks)
      let todos = Self.weekTodos(members, all: tasks)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(plan.meetings) { m in meetingHeader(m) }
        if todos.isEmpty {
          Text("Keine Aufgaben in diesem Weekly.")
            .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            .padding(.vertical, 6)
        } else {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(todos) { t in taskRow(t).transition(Theme.rowTransition) }
          }
        }
        ForEach(plan.meetings) { m in wholePage(m) }
      }
    }
  }

  /// Kopfzeile einer Besprechung: Häkchen und Titel (wie jede Aufgabe), darunter die Meta-Zeile.
  private func meetingHeader(_ m: WeekMeeting) -> some View {
    let meta = state.notionTaskMeta[m.task.id].flatMap { Self.metaLine($0, now: now) }
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "calendar").font(.system(size: 11))
        Text(m.task.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
      }
      .foregroundStyle(Theme.secondary)
      .padding(.horizontal, 8)
      if let meta { metaText(meta).padding(.leading, 25) }
    }
  }

  /// „Ganze Seite“: eingeklappt standardmäßig; aufgeklappt der Notion-Inhalt mit den To-do-Häkchen.
  private func wholePage(_ m: WeekMeeting) -> some View {
    let id = m.task.id
    let isOpen = isDetailOpen(id, defaultOpen: false)
    return VStack(alignment: .leading, spacing: 4) {
      Button { toggleDetail(id, defaultOpen: false) } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
          Text("Ganze Seite").font(.system(size: 12, weight: .semibold))
          Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isOpen {
        detailBody(m.task.notes ?? "", pageId: state.notionTaskPages[id],
                   checkTask: { n, _ in n < m.todos.count ? m.todos[n] : nil })
          .padding(.leading, 8)
      }
    }
  }

  private func taskRow(_ t: TabyTask) -> some View {
    TaskRow(task: t, now: now, completing: completing.contains(t.id), onToggle: { toggle(t) })
  }

  private func chevron(_ id: String, open: Bool, defaultOpen: Bool) -> some View {
    Button { toggleDetail(id, defaultOpen: defaultOpen) } label: {
      Image(systemName: open ? "chevron.up" : "chevron.down")
    }
    .buttonStyle(RoundIconButtonStyle(size: 22))
    .help(open ? "Inhalt einklappen" : "Inhalt aufklappen")
    .accessibilityLabel(open ? "Inhalt einklappen" : "Inhalt aufklappen")
  }

  /// Inhalt einer Aufgabe (Notion-Text) und, falls bekannt, der Link in Notion.
  private func detailBody(_ notes: String, pageId: String?,
                          checkTask: @escaping (Int, String) -> TabyTask?) -> some View {
    // Kein eigener Scroll-Container: langer Text scrollt mit der umgebenden CappedScroll-Liste.
    VStack(alignment: .leading, spacing: 8) {
      if notes.isEmpty {
        Text("Kein Inhalt in Notion.")
          .font(.system(size: 12))
          .foregroundStyle(Theme.tertiary)
      } else {
        NotionBodyView(text: notes, checkTask: checkTask, onToggle: { toggle($0) }, completing: completing)
      }
      if let pageId {
        Button { openInNotion(pageId) } label: {
          HStack(spacing: 5) { Image(systemName: "arrow.up.forward.square"); Text("In Notion öffnen") }
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Meta-Zeile unter dem Ticket; veraltete Datumsteile in Bernstein.
  private func metaText(_ parts: [MetaPart]) -> Text {
    parts.enumerated().reduce(Text("")) { acc, item in
      let separator = item.offset == 0 ? Text("") : Text(" · ").foregroundColor(Theme.tertiary)
      return acc + separator + Text(item.element.text).foregroundColor(item.element.stale ? Theme.amber : Theme.tertiary)
    }
    .font(.system(size: 11))
  }

  /// Öffnet die Notion-Seite im Browser (ID ohne Bindestriche, wie Notion-Links sie haben).
  private func openInNotion(_ pageId: String) {
    guard let url = URL(string: "https://www.notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))") else { return }
    NSWorkspace.shared.open(url)
  }

  private var syncButton: some View {
    Button(action: sync) {
      HStack(spacing: 5) {
        if syncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
        Text("Aktualisieren")
      }
    }
    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    .disabled(syncing || !state.notionTasksConnected)
  }

  private func sync() {
    syncing = true
    error = nil
    Task {
      let r = await model.services.syncNotionTasks()
      await model.refresh()
      syncing = false
      if case .failure(_, let e) = r { error = e }
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

/// Wochen-Chip im Unterreiter: kompakt wie der Herkunfts-Chip im Aufgaben-Reiter, mit Zähler offener Aufgaben.
private struct WeekChip: View {
  let text: String
  let count: Int
  let selected: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(text)
          .font(.system(size: 11, weight: selected ? .semibold : .medium))
          .lineLimit(1)
        if count > 0 {
          Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(selected ? Color.black.opacity(0.12) : Theme.capsule))
            .contentTransition(.numericText())
        }
      }
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
