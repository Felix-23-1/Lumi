// Seite „Aufgaben“: die Kategorien für Aufgaben und Ordner. Änderungen gehen über das Formular der
// Einstellungen und werden automatisch gespeichert (wie die anderen Karten).
import SwiftUI
import TabyCore

struct TaskCategoriesCard: View {
  @Binding var categories: [TaskCategoryDef]
  @State private var adding = false
  @State private var newName = ""
  @State private var newSymbol = "tag.fill"
  @State private var renaming: String?
  @State private var renameDraft = ""
  @State private var error: String?

  @EnvironmentObject private var model: AppModel

  private var builtInIds: Set<String> { Set(TaskCategoryDef.builtIn.map(\.id)) }
  /// Notion-Zugänge aus dem gespeicherten Stand (für den Schutz beim Löschen und den Hinweis).
  private var notionAccounts: [NotionAccount] { model.state?.settings.notionAccounts ?? [] }

  /// „Notion: Geschäftlich“ bzw. „kein Notion“ für die Kategorie.
  private func notionText(_ categoryId: String) -> String {
    let names = (model.state?.settings.notionAccounts ?? []).filter { $0.categoryId == categoryId }.map(\.name)
    return names.isEmpty ? "kein Notion" : "Notion: " + names.joined(separator: ", ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "tag", title: "Kategorien")
      Text("Arbeit und Privat bleiben immer vorn und lassen sich nur umbenennen. Eigene Kategorien kannst du "
        + "sortieren, umbenennen und löschen. Aufgaben und Ordner behalten ihre Kategorie, auch wenn sie gelöscht wird; "
        + "dann zählen sie als ohne Kategorie. Höchstens \(TaskCategoryRules.maxCount) Kategorien.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(categories.enumerated()), id: \.element.id) { i, def in
          row(i, def)
        }
        // Zugang mit fehlender Kategorie: seine Aufgaben zählen als „ohne Kategorie“.
        ForEach(TaskCategoryLogic.accountsWithoutCategory(notionAccounts, defs: categories), id: \.id) { account in
          Label("Notion-Zugang „\(account.name)“: Kategorie fehlt, seine Aufgaben zählen als ohne Kategorie.",
                systemImage: "exclamationmark.triangle")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if adding {
        addForm
      } else {
        Button { adding = true; error = nil } label: { Label("Kategorie", systemImage: "plus") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(categories.count >= TaskCategoryRules.maxCount)
      }
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .tabyCard()
  }

  @ViewBuilder private func row(_ i: Int, _ def: TaskCategoryDef) -> some View {
    let custom = !builtInIds.contains(def.id)
    HStack(spacing: 8) {
      Image(systemName: def.symbol).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18)
      if renaming == def.id {
        TextField("Name", text: $renameDraft)
          .textFieldStyle(.plain).font(.system(size: 12))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Capsule().fill(Theme.capsule))
          .onSubmit { rename(def) }
          .onExitCommand { renaming = nil }
          .accessibilityLabel("Kategorie umbenennen")
        Button("Speichern") { rename(def) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      } else {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(def.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            Text(def.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
          }
          // Welche Notion-Zugänge zu dieser Kategorie gehören (nur Anzeige); die Einrichtung liegt bei Kalender & Konten.
          HStack(spacing: 6) {
            Text(notionText(def.id)).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            Button { SettingsEntry.show(.accounts) } label: {
              Text("Zugang einrichten").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.blue)
            }
            .buttonStyle(.plain)
          }
        }
        Spacer(minLength: 0)
        if custom {
          Button { move(def.id, up: true) } label: { Image(systemName: "chevron.up") }
            .buttonStyle(RoundIconButtonStyle(size: 22))
            .disabled(i <= TaskCategoryDef.builtIn.count)
            .help("Nach oben")
            .accessibilityLabel("Nach oben")
          Button { move(def.id, up: false) } label: { Image(systemName: "chevron.down") }
            .buttonStyle(RoundIconButtonStyle(size: 22))
            .disabled(i + 1 >= categories.count)
            .help("Nach unten")
            .accessibilityLabel("Nach unten")
        }
        Button { renameDraft = def.name; renaming = def.id; error = nil } label: { Image(systemName: "pencil") }
          .buttonStyle(RoundIconButtonStyle(size: 22))
          .help("Umbenennen")
          .accessibilityLabel("Umbenennen")
        if custom {
          Button { delete(def.id) } label: { Image(systemName: "trash") }
            .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.red.opacity(0.8)))
            .help("Löschen")
            .accessibilityLabel("Löschen")
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var addForm: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField("Name, z. B. Sport", text: $newName)
          .textFieldStyle(.plain).font(.system(size: 12))
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(Capsule().fill(Theme.capsule))
          .onSubmit(add)
          .onExitCommand { adding = false; newName = ""; error = nil }
          .accessibilityLabel("Name der neuen Kategorie")
        Button("Anlegen", action: add)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Abbrechen") { adding = false; newName = ""; error = nil }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      WrapLayout(spacing: 4) {
        ForEach(TaskCategoryLogic.symbols, id: \.self) { s in
          Button { newSymbol = s } label: { Image(systemName: s).font(.system(size: 11)) }
            .buttonStyle(RoundIconButtonStyle(size: 22, filled: newSymbol == s))
            .accessibilityLabel("Symbol \(s)")
        }
      }
    }
  }

  private func add() {
    var list = categories
    if let err = TaskCategoryLogic.add(name: newName, symbol: newSymbol, to: &list) { error = err; return }
    categories = list
    adding = false
    newName = ""
    newSymbol = "tag.fill"
    error = nil
  }

  private func rename(_ def: TaskCategoryDef) {
    var list = categories
    if let err = TaskCategoryLogic.rename(def.id, to: renameDraft, in: &list) { error = err; return }
    categories = list
    renaming = nil
    error = nil
  }

  private func move(_ id: String, up: Bool) {
    var list = categories
    TaskCategoryLogic.move(id, up: up, in: &list)
    categories = list
  }

  private func delete(_ id: String) {
    var list = categories
    if let err = TaskCategoryLogic.delete(id, in: &list, notionAccounts: notionAccounts) { error = err; return }
    categories = list
    error = nil
  }
}
