// Karte „Daraus Aufgabe“ unter Mail und Chat: fragt Titel, Kategorie und Fälligkeit, bevor etwas
// angelegt wird. Ohne Datum bleibt die Aufgabe ohne Termin. Angelegt wird über ViewActions.addTask.
import SwiftUI
import TabyCore

/// Vorbelegung der Karte (Snapshots und Prüfungen). Im Betrieb ist alles leer: „Ohne“, keine Kategorie.
struct TaskCardSeed: Equatable {
  var mode: TaskLogic.DueMode = .none
  var withTime = false
  /// "YYYY-MM-DD"; nil = heute.
  var date: String?
  /// "HH:mm"; nil = jetzt.
  var time: String?
  /// Gewählte Kategorie; nil zusammen mit `categoryPicked` = „Keine“.
  var categoryId: String?
  var categoryPicked = false
}

struct TaskFromMessageCard: View {
  let title: String
  let notes: String
  let categories: [TaskCategoryDef]
  let now: String
  let onCreated: (String) -> Void
  let onCancel: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var name: String
  @State private var mode: TaskLogic.DueMode
  @State private var withTime: Bool
  @State private var pickedDate: Date
  @State private var pickedTime: Date
  @State private var categoryId: String?
  @State private var categoryPicked: Bool
  @State private var saving = false
  @State private var error: String?

  init(title: String, notes: String, categories: [TaskCategoryDef], seed: TaskCardSeed, now: String,
       onCreated: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.title = title
    self.notes = notes
    self.categories = categories
    self.now = now
    self.onCreated = onCreated
    self.onCancel = onCancel
    let base = LocalTime.parse(now) ?? Date()
    _name = State(initialValue: title)
    _mode = State(initialValue: seed.mode)
    _withTime = State(initialValue: seed.withTime)
    _pickedDate = State(initialValue: seed.date.flatMap { LocalTime.parse("\($0)T00:00") } ?? base)
    _pickedTime = State(initialValue: seed.time.flatMap { LocalTime.parse("\(LocalTime.datePart(now))T\($0)") } ?? base)
    _categoryId = State(initialValue: seed.categoryId)
    _categoryPicked = State(initialValue: seed.categoryPicked)
  }

  /// Erste Zeile der Notizen („Mail von …“), grau und gekürzt; nicht änderbar.
  private var noteLine: String {
    notes.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      InputCapsule(placeholder: "Titel", text: $name)
      if !noteLine.isEmpty {
        Text(noteLine)
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      caption("Kategorie")
      WrapLayout(spacing: 6) {
        ChoiceChip(text: "Keine", selected: categoryPicked && categoryId == nil) {
          categoryId = nil
          categoryPicked = true
        }
        .fixedSize()
        ForEach(categories) { c in
          ChoiceChip(text: c.name, symbol: c.symbol, selected: categoryPicked && categoryId == c.id) {
            categoryId = c.id
            categoryPicked = true
          }
          .fixedSize()
        }
      }
      caption("Wann?")
      DueChips(mode: $mode, withTime: $withTime, pickedDate: $pickedDate, pickedTime: $pickedTime)
      if mode == .none {
        Text("Ohne Datum bleibt die Aufgabe ohne Termin.")
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
      }
      if let error {
        Banner(symbol: "exclamationmark.triangle.fill", text: error, tint: Theme.red)
      }
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        Button("Abbrechen", action: onCancel)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button(action: create) { Label("Anlegen", systemImage: "checkmark") }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(saving || TaskLogic.validateTitle(name) != nil)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).kerning(0.4)
      .foregroundStyle(Theme.tertiary)
  }

  private func create() {
    let today = LocalTime.datePart(now)
    guard let d = TaskFromMessage.compose(
      title: name, notes: notes, categoryId: categoryId, categories: categories, mode: mode, today: today,
      date: LocalTime.formatDate(pickedDate), time: withTime ? LocalTime.formatTime(pickedTime) : nil
    ) else {
      error = TaskLogic.validateTitle(name) ?? "Aufgabe nicht angelegt."
      return
    }
    error = nil
    saving = true
    Task {
      let failure = await ViewActions.addTask(model, title: d.title, due: d.due,
                                              category: d.categoryId.map { TaskCategory(rawValue: $0) },
                                              notes: d.notes)
      saving = false
      if let failure { error = failure } else { onCreated(d.title) }
    }
  }
}
