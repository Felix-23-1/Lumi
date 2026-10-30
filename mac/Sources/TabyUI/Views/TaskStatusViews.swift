// Bearbeitungsstand von Aufgaben: Chip (nur wenn nicht offen), Menü zum Setzen,
// und die reine Gruppierung nach Stand (In Bearbeitung, Info fehlt, Offen).
import SwiftUI
import TabyCore

enum TaskStatusLogic {
  /// Reihenfolge im Menü.
  static let menuOrder: [TaskStatus] = [.open, .inProgress, .needsInfo]
  /// Reihenfolge der Abschnitte: was in Arbeit ist, zuerst.
  static let sectionOrder: [TaskStatus] = [.inProgress, .needsInfo, .open]

  static func tint(_ status: TaskStatus) -> Color {
    switch status {
    case .open: Theme.secondary
    case .inProgress: Theme.blue
    case .needsInfo: Theme.orange
    }
  }

  /// Wert für `TaskPatch.status`: "" heißt offen (laut Vertrag), sonst der rawValue.
  static func patchValue(_ status: TaskStatus) -> String {
    status == .open ? "" : status.rawValue
  }

  /// Offene Aufgaben nach Stand; erledigte fehlen, leere Stände entfallen.
  /// Innerhalb eines Standes: Fälligkeit aufsteigend (ohne Fälligkeit zuletzt), dann Titel.
  static func groups(_ tasks: [TabyTask]) -> [(TaskStatus, [TabyTask])] {
    let open = tasks.filter { !$0.done }
    return sectionOrder.compactMap { status in
      let items = open.filter { $0.status == status }.sorted(by: isBefore)
      return items.isEmpty ? nil : (status, items)
    }
  }

  /// Filter „Stand“: ohne Auswahl alle, sonst nur die gewählten Stände.
  static func matches(_ task: TabyTask, statuses: Set<TaskStatus>) -> Bool {
    statuses.isEmpty || statuses.contains(task.status)
  }

  static func filter(_ tasks: [TabyTask], statuses: Set<TaskStatus>) -> [TabyTask] {
    tasks.filter { matches($0, statuses: statuses) }
  }

  /// Filter „Quelle“: Notion-Aufgaben sind die mit einer Quellen-Verknüpfung. Ohne Auswahl alle.
  static func matches(_ task: TabyTask, sources: Set<TaskSourceChoice>, sourceLinks: [String: String]) -> Bool {
    sources.isEmpty || sources.contains(sourceLinks[task.id] == nil ? .own : .notion)
  }

  /// Filter „Fällig“: ohne Auswahl alle, sonst eine der gewählten Fälligkeiten. `now` kommt vom Aufrufer (Uhr).
  static func matches(_ task: TabyTask, due: Set<TaskDueChoice>, now: String) -> Bool {
    due.isEmpty || due.contains { dueMatch(task, choice: $0, now: now) }
  }

  /// Tage bis einschließlich Sonntag (Woche Montag bis Sonntag); heute ist 0.
  static func daysLeftInWeek(_ now: String) -> Int {
    guard let day = LocalTime.parse(LocalTime.datePart(now)) else { return 0 }
    let weekday = LocalTime.calendar.component(.weekday, from: day)  // Sonntag = 1
    return (8 - weekday) % 7
  }

  /// Quelle und Fälligkeit zusammen (UND); Stand wird vorher über `filter(_:statuses:)` gefiltert.
  static func filter(_ tasks: [TabyTask], sources: Set<TaskSourceChoice>, due: Set<TaskDueChoice>,
                     sourceLinks: [String: String], now: String) -> [TabyTask] {
    tasks.filter { matches($0, sources: sources, sourceLinks: sourceLinks) && matches($0, due: due, now: now) }
  }

  /// Aktive Filter in fester Reihenfolge: Stände (Menüreihenfolge), Kennzeichen wie gewählt, dann Quelle und Fälligkeit.
  static func activeFilters(statuses: Set<TaskStatus>, tags: [String], sources: Set<TaskSourceChoice> = [],
                            due: Set<TaskDueChoice> = []) -> [TaskViewFilter] {
    var out: [TaskViewFilter] = menuOrder.filter { statuses.contains($0) }.map { .status($0) }
    out += tags.map { .tag($0) }
    out += TaskSourceChoice.allCases.filter { sources.contains($0) }.map { .source($0) }
    out += TaskDueChoice.allCases.filter { due.contains($0) }.map { .due($0) }
    return out
  }

  /// Zahl am Ansicht-Knopf: jeder gewählte Stand, Kennzeichen, Quelle und Fälligkeit zählt einmal.
  static func activeCount(statuses: Set<TaskStatus>, tags: [String], sources: Set<TaskSourceChoice> = [],
                          due: Set<TaskDueChoice> = []) -> Int {
    activeFilters(statuses: statuses, tags: tags, sources: sources, due: due).count
  }

  /// Ob eine Aufgabe zu einer Fälligkeit passt. Ohne Fälligkeit nur „Ohne Datum“.
  /// Überfällig zählt nur offene Aufgaben: gestern oder heute mit schon vergangener Uhrzeit.
  private static func dueMatch(_ task: TabyTask, choice: TaskDueChoice, now: String) -> Bool {
    let raw = task.due ?? ""
    guard !raw.isEmpty else { return choice == .none }
    guard let diff = GermanDate.dayDiff(now, raw) else { return false }
    switch choice {
    case .none: return false
    case .overdue: return !task.done && (diff < 0 || (diff == 0 && !LocalTime.isDateOnly(raw) && raw < now))
    case .today: return diff == 0
    case .tomorrow: return diff == 1
    case .week: return (0...daysLeftInWeek(now)).contains(diff)
    }
  }

  private static func isBefore(_ a: TabyTask, _ b: TabyTask) -> Bool {
    let x = a.due.flatMap { $0.isEmpty ? nil : $0 }
    let y = b.due.flatMap { $0.isEmpty ? nil : $0 }
    switch (x, y) {
    case let (x?, y?) where x != y: return x < y
    case (nil, _?): return false
    case (_?, nil): return true
    default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
  }
}

/// Kleiner Chip mit Symbol und Titel. Für „Offen“ leer, nur sichtbar bei Stand ≠ offen.
struct TaskStatusChip: View {
  let status: TaskStatus

  var body: some View {
    if status != .open {
      Chip(text: status.title, symbol: status.symbol, tint: TaskStatusLogic.tint(status))
    }
  }
}

/// Quelle einer Aufgabe für den Filter „Quelle“.
enum TaskSourceChoice: String, CaseIterable, Hashable, Codable {
  case notion, own

  var title: String { self == .notion ? "Aus Notion" : "Eigene" }
}

/// Fälligkeit für den Filter „Fällig“.
enum TaskDueChoice: String, CaseIterable, Hashable, Codable {
  case overdue, today, tomorrow, week, none

  var title: String {
    switch self {
    case .overdue: "Überfällig"
    case .today: "Heute"
    case .tomorrow: "Morgen"
    case .week: "Diese Woche"
    case .none: "Ohne Datum"
    }
  }
}

/// Ein aktiver Filter der Ansicht: ein Stand, ein Kennzeichen, eine Quelle oder eine Fälligkeit.
enum TaskViewFilter: Hashable {
  case status(TaskStatus)
  case tag(String)
  case source(TaskSourceChoice)
  case due(TaskDueChoice)

  var title: String {
    switch self {
    case .status(let s): s.title
    case .tag(let name): "#\(name)"
    case .source(let s): s.title
    case .due(let d): d.title
    }
  }
}

/// Entfernbarer Chip für einen aktiven Filter („In Bearbeitung ✕“, „#kunde ✕“).
struct FilterChip: View {
  let filter: TaskViewFilter
  let onRemove: () -> Void

  var body: some View {
    let tint = tintColor
    HStack(spacing: 3) {
      Text(filter.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
      Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title) entfernen")
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill(tint.opacity(0.14)))
    .accessibilityElement(children: .contain)
  }

  private var tintColor: Color {
    switch filter {
    case .status(let s): TaskStatusLogic.tint(s)
    case .due(.overdue): Theme.red
    case .tag, .source, .due: Theme.blue
    }
  }
}

/// Menü zum Setzen des Standes. In Vorschauen (Snapshots) nur die Anzeige, das Menü zeichnet der Renderer nicht.
struct TaskStatusMenu: View {
  let status: TaskStatus
  let onSelect: (TaskStatus) -> Void
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if snapshot {
      label
    } else {
      Menu {
        ForEach(TaskStatusLogic.menuOrder, id: \.self) { s in
          Button { onSelect(s) } label: {
            Label(s.title, systemImage: s == status ? "checkmark" : s.symbol)
          }
        }
      } label: {
        label
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Bearbeitungsstand setzen")
      .accessibilityLabel("Bearbeitungsstand, \(status.title)")
    }
  }

  private var label: some View {
    Label(status.title, systemImage: status.symbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(status == .open ? Theme.secondary : TaskStatusLogic.tint(status))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(Theme.capsule))
  }
}
