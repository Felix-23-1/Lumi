// Auswahl „Aufgabe zuordnen“ als Popover an der Notiz: Suche über Titel und Kennzeichen,
// Chips Alle · Arbeit · Privat, Schalter „Erledigte zeigen“, Zeile mit Kategorie-Punkt und Fälligkeit.
// Die Logik steht in NoteFilterLogic (NoteTaskPickLogic).
import SwiftUI
import TabyCore

/// Chips Alle · Arbeit · Privat (nil = Alle). Für die Notizliste und die Aufgaben-Auswahl.
struct NoteCategoryChips: View {
  @Binding var selected: String?

  var body: some View {
    HStack(spacing: 6) {
      ChoiceChip(text: "Alle", selected: selected == nil) { selected = nil }.fixedSize()
      ForEach(NoteCategoryLogic.categories, id: \.rawValue) { c in
        ChoiceChip(text: c.title, selected: selected == c.rawValue) { selected = c.rawValue }
          .fixedSize()
          .accessibilityLabel("Kategorie \(c.title)")
      }
    }
  }
}

struct NoteTaskPicker: View {
  let tasks: [TabyTask]
  /// Aktuell zugeordnete Aufgabe (markiert); nil = keine.
  let current: String?
  /// Gewählte Aufgabenkennung, "" löst die Zuordnung.
  let onPick: (String) -> Void
  @State private var query = ""
  @State private var category: String?
  @State private var showDone = false
  @Environment(\.tabyNow) private var nowEnv
  /// Snapshots zeichnen Eingabefelder gelb; dort ohne Suchfeld und ohne Scroll-Container.
  @Environment(\.tabySnapshot) private var snapshot

  init(tasks: [TabyTask], current: String?, onPick: @escaping (String) -> Void) {
    self.tasks = tasks
    self.current = current
    self.onPick = onPick
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var rows: [TabyTask] {
    NoteTaskPickLogic.rows(tasks, query: query, category: category, showDone: showDone, keep: current)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Aufgabe zuordnen").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
      if !snapshot {
        TextField("Titel oder #Kennzeichen suchen", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(Capsule().fill(Theme.capsule))
          .accessibilityLabel("Aufgabe suchen")
      }
      NoteCategoryChips(selected: $category)
      Toggle("Erledigte zeigen", isOn: $showDone)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
      Divider()
      if snapshot {
        list
      } else {
        ScrollView(.vertical, showsIndicators: false) { list }.frame(maxHeight: 240)
      }
      if current != nil {
        Divider()
        Button("Zuordnung entfernen") { onPick("") }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      }
    }
    .padding(12)
    .frame(width: 300)
  }

  @ViewBuilder private var list: some View {
    VStack(alignment: .leading, spacing: 2) {
      if tasks.isEmpty {
        Text("Keine Aufgaben").font(.system(size: 11)).foregroundStyle(Theme.secondary)
      } else if rows.isEmpty {
        Text("Keine passenden Aufgaben").font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      ForEach(rows) { row($0) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ t: TabyTask) -> some View {
    let isCurrent = t.id == current
    return Button { onPick(t.id) } label: {
      HStack(spacing: 8) {
        Circle().fill(Self.dotColor(t.category?.rawValue)).frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(t.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(t.done ? Theme.secondary : Theme.text)
            .lineLimit(1)
          if let meta = meta(t) {
            Text(meta).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        if isCurrent {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.blue)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isCurrent ? Theme.capsuleHover : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(t.title)\(isCurrent ? ", zugeordnet" : "")")
  }

  /// Fälligkeit („Heute 09:00“) und Stand „Erledigt“ als Zeile unter dem Titel.
  private func meta(_ t: TabyTask) -> String? {
    var parts: [String] = []
    if t.done { parts.append("Erledigt") }
    if let due = TaskLogic.dueChip(t.due, now: now)?.label { parts.append(due) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func dotColor(_ category: String?) -> Color {
    switch category {
    case "arbeit"?: Theme.blue
    case "privat"?: Theme.orange
    default: Color.clear
    }
  }
}
