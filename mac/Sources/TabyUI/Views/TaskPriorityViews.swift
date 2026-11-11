// Priorität einer Aufgabe: Anzeige-Chip und Menü zum Setzen.
import SwiftUI
import TabyCore

enum TaskPriorityLogic {
  static let menuOrder: [TaskPriority] = [.high, .medium, .low, .none]

  static func tint(_ p: TaskPriority) -> Color {
    switch p {
    case .high: .red
    case .medium: .orange
    case .low: .blue
    case .none: Theme.secondary
    }
  }

  /// Patch-Wert: `.none` wird als "" gesendet (Priorität entfernen).
  static func patchValue(_ p: TaskPriority) -> String { p == .none ? "" : p.rawValue }
}

/// Kleiner Chip in der Zeile; ohne Priorität unsichtbar.
struct TaskPriorityChip: View {
  let priority: TaskPriority
  var body: some View {
    if priority != .none {
      Chip(text: priority.title, symbol: priority.symbol, tint: TaskPriorityLogic.tint(priority))
    }
  }
}

struct TaskPriorityMenu: View {
  let priority: TaskPriority
  let onSelect: (TaskPriority) -> Void
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if snapshot {
      label
    } else {
      Menu {
        ForEach(TaskPriorityLogic.menuOrder, id: \.self) { p in
          Button { onSelect(p) } label: {
            Label(p.title, systemImage: p == priority ? "checkmark" : p.symbol)
          }
        }
      } label: {
        label
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Priorität setzen")
      .accessibilityLabel("Priorität, \(priority.title)")
    }
  }

  private var label: some View {
    Label(priority == .none ? "Priorität" : priority.title, systemImage: priority.symbol)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(TaskPriorityLogic.tint(priority))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(Theme.capsule))
  }
}
