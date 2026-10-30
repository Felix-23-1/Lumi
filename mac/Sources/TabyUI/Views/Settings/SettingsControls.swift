// Bausteine der Einstellungen: Felder, Schalter, Notion-Quellen und die Seitenleiste.
import AppKit
import SwiftUI
import TabyCore

/// Beschriftung über einem Feld.
struct FieldRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.leading, 4)
      content()
    }
  }
}

struct SourceRow: View {
  let source: CalendarSourceConfig
  /// Tatsächliches Schreibziel (nicht nur die gespeicherte Markierung).
  var isDefault: Bool
  let health: HealthResult?
  let onEnabled: (Bool) -> Void
  let onDefault: () -> Void
  let onCheck: () -> Void

  var body: some View {
    HoverRow { _ in
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Image(systemName: source.kind.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(source.kind.color)
            .frame(width: 24, height: 24)
            .background(Circle().fill(source.kind.color.opacity(0.15)))
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
              Text(source.kind.germanName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
              if isDefault { Chip(text: "Standard", symbol: "pencil", tint: Theme.blue) }
            }
            Text(SettingsLogic.sourceDetail(source)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
              .lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 4)
          Button(action: onCheck) { Image(systemName: "stethoscope") }
            .buttonStyle(RoundIconButtonStyle(size: 24))
            .help("Prüfen")
          if !isDefault && source.kind != .ics {
            Button("Hier eintragen", action: onDefault)
              .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
              .help("Neue Termine landen künftig in diesem Kalender")
          }
          MiniSwitch(isOn: source.enabled) { onEnabled(!source.enabled) }
            .help(source.enabled ? "An" : "Aus")
        }
        if let h = health {
          HStack(spacing: 5) {
            StatusDot(color: h.ok ? Theme.green : Theme.red, size: 6)
            Text(h.message ?? (h.ok ? "Erreichbar" : "Fehler")).font(.system(size: 11))
              .foregroundStyle(h.ok ? Theme.green : Theme.red)
          }
          .padding(.leading, 32)
          .transition(.opacity)
        }
      }
    }
  }
}

struct MiniSwitch: View {
  let isOn: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      ZStack(alignment: isOn ? .trailing : .leading) {
        Capsule().fill(isOn ? Theme.green : Theme.capsuleHover).frame(width: 30, height: 18)
        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
      }
      .animation(Theme.snappy, value: isOn)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isOn ? "An" : "Aus")
  }
}

/// Vorschlagsliste der Modelle (im Snapshot nur das Symbol).
struct ModelMenu: View {
  let models: [String]
  /// Beim Öffnen der Auswahl: lädt die Modellliste (nie vorab).
  var onOpen: () -> Void = {}
  let pick: (String) -> Void
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    let icon = Image(systemName: "chevron.down.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.secondary)
    Group {
      if snapshot {
        icon
      } else {
        Menu {
          if models.isEmpty { Text("Keine Vorschläge") }
          ForEach(models, id: \.self) { m in Button(m) { pick(m) } }
        } label: { icon }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .simultaneousGesture(TapGesture().onEnded { onOpen() })
      }
    }
    .padding(.trailing, 6)
    .help("Modell auswählen")
  }
}


/// Eine Notion-Quelle in der Einstellungsliste: Name, Kategorie, Link (sofort gespeichert).
struct NotionSourceRow: View {
  let source: NotionSource
  let onUpdate: (_ name: String?, _ category: NotionSourceCategory?, _ link: String?) -> Void
  let onRemove: () -> Void
  @State private var name: String
  @State private var link: String
  @Environment(\.tabySnapshot) private var snapshot

  init(source: NotionSource, onUpdate: @escaping (String?, NotionSourceCategory?, String?) -> Void,
       onRemove: @escaping () -> Void) {
    self.source = source
    self.onUpdate = onUpdate
    self.onRemove = onRemove
    _name = State(initialValue: source.name)
    _link = State(initialValue: source.link)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        field($name, placeholder: "Name", size: 12, mono: false)
          .onChange(of: name) { _, v in onUpdate(v, nil, nil) }
        Button("✕", action: onRemove)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      HStack(spacing: 4) {
        ForEach(NotionSourceCategory.allCases, id: \.self) { c in
          ChoiceChip(text: c.title, selected: source.category == c) { onUpdate(nil, c, nil) }
        }
      }
      field($link, placeholder: "Notion-Link oder ID", size: 12, mono: true)
        .onChange(of: link) { _, v in onUpdate(nil, nil, v) }
    }
    .padding(.vertical, 4)
  }

  /// Snapshots zeigen Text statt des nativen Feldes (wie InputCapsule).
  @ViewBuilder
  private func field(_ text: Binding<String>, placeholder: String, size: CGFloat, mono: Bool) -> some View {
    let font = Font.system(size: size, weight: mono ? .regular : .medium, design: mono ? .monospaced : .default)
    if snapshot {
      Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
        .font(font).foregroundStyle(text.wrappedValue.isEmpty ? Theme.tertiary : Theme.text)
        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
    } else {
      TextField(placeholder, text: text)
        .textFieldStyle(.plain).font(font).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Zeile der Seitenleiste im eigenen Fenster.
struct SidebarRow: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Theme.text : Theme.secondary)
          .frame(width: 18)
        Text(title)
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Theme.text : Theme.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.capsuleHover : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Notion-Zugänge

/// Regeln der Zugangs-Karten (rein, ohne Dienst). Die Grenzen selbst kommen aus dem Kern (`NotionAccountRules`).
enum NotionAccountLogic {
  /// Neuer Zugang nur, solange der Kern noch Platz hat (höchstens 8).
  static func canAdd(count: Int) -> Bool { count < NotionAccountRules.maxCount }

  /// Der Standard-Zugang ("notion") bleibt immer bestehen.
  static func canRemove(_ account: NotionAccount) -> Bool { account.id != NotionAccount.legacyId }

  /// Name des Zugangs: leer zuerst, dann die Regeln des Kerns (Länge, Steuerzeichen, Doppelte).
  static func nameProblem(_ name: String, others: [String]) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Gib dem Notion-Zugang einen Namen." }
    return NotionAccountRules.nameProblem(trimmed, others: others)
  }

  /// Umbenennen: die anderen Zugänge (ohne diesen) dürfen den Namen nicht schon haben.
  static func renameProblem(_ name: String, account: NotionAccount, accounts: [NotionAccount]) -> String? {
    nameProblem(name, others: accounts.filter { $0.id != account.id }.map(\.name))
  }

  /// Anlegen: Platz, Name, Kategorie aus den Einstellungen und ein nicht leerer Zugangscode.
  /// nil = gilt. Der Code wird hier nur geprüft, nie gespeichert.
  static func addProblem(name: String, categoryId: String, token: String,
                         accounts: [NotionAccount], defs: [TaskCategoryDef]) -> String? {
    guard canAdd(count: accounts.count) else {
      return "Höchstens \(NotionAccountRules.maxCount) Notion-Zugänge. Lösche erst einen, um einen neuen anzulegen."
    }
    if let problem = nameProblem(name, others: accounts.map(\.name)) { return problem }
    if categoryId.isEmpty { return "Wähle eine Kategorie, zu der der Zugang gehören soll." }
    if let problem = NotionAccountRules.categoryProblem(categoryId, defs: defs) { return problem }
    if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Der Zugangscode fehlt." }
    return nil
  }
}

/// Ein Notion-Zugang in der Einstellungsliste: Name (inline), „Gehört zu“, Verbindung, eigene Quellen.
/// Der Zugangscode liegt nur in einem lokalen Feld und geht direkt an den Dienst.
struct NotionAccountBlock: View {
  let account: NotionAccount
  let accounts: [NotionAccount]
  let categories: [TaskCategoryDef]
  let connected: Bool
  /// Standard-Zugang: seine bisherigen Verbindungs-Wege statt des Code-Feldes.
  let legacyControls: AnyView?
  let sources: AnyView
  @EnvironmentObject var model: AppModel
  @State private var renaming = false
  @State private var nameDraft = ""
  @State private var replacing = false
  @State private var code = ""
  @State private var busy = false
  @State private var removing = false
  @State private var message: (ok: Bool, text: String)?

  private var categoryName: String { categories.first { $0.id == account.categoryId }?.name ?? "ohne Kategorie" }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      FieldRow(label: "Gehört zu:") {
        WrapLayout(spacing: 4) {
          ForEach(categories) { c in
            ChoiceChip(text: c.name, selected: c.id == account.categoryId) { assign(c.id) }
          }
        }
      }
      HStack(spacing: 6) {
        StatusDot(color: connected ? Theme.green : Theme.red, size: 6)
        Text(connected ? "Verbunden" : "Zugangscode fehlt")
          .font(.system(size: 12)).foregroundStyle(connected ? Theme.secondary : Theme.red)
      }
      if let legacyControls {
        legacyControls
      } else {
        codeField
      }
      Text("Aufgaben aus diesem Zugang erscheinen nur in der Kategorie \(categoryName).")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      sources
      if NotionAccountLogic.canRemove(account) {
        HStack {
          Button("Zugang entfernen") { removing = true }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          Spacer(minLength: 0)
        }
      }
      if let message {
        Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(message.ok ? Theme.green : Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.capsule))
    .confirmationDialog("Aufgaben behalten oder löschen?", isPresented: $removing, titleVisibility: .visible) {
      Button("Behalten") { remove(deleteTasks: false) }
      Button("Aufgaben löschen", role: .destructive) { remove(deleteTasks: true) }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Behalten: Die Aufgaben bleiben in Lumi, nur die Verbindung zu Notion fällt weg. "
        + "Aufgaben löschen: Die Aufgaben dieses Zugangs werden auch gelöscht. "
        + "Der Zugangscode und die Quellen gehen in beiden Fällen.")
    }
  }

  @ViewBuilder private var header: some View {
    HStack(spacing: 6) {
      if renaming {
        TextField("Name", text: $nameDraft)
          .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Capsule().fill(Theme.capsuleHover))
          .onSubmit { rename() }
          .onExitCommand { renaming = false }
          .accessibilityLabel("Name des Notion-Zugangs")
        Button("Speichern") { rename() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      } else {
        Text(account.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
        Button { nameDraft = account.name; renaming = true; message = nil } label: { Image(systemName: "pencil") }
          .buttonStyle(RoundIconButtonStyle(size: 22))
          .help("Umbenennen")
          .accessibilityLabel("Umbenennen")
      }
      Spacer(minLength: 0)
    }
  }

  /// Ohne Code: Feld und „Verbinden“. Mit Code: „Code ersetzen“ öffnet dasselbe Feld.
  @ViewBuilder private var codeField: some View {
    if connected && !replacing {
      HStack {
        Button("Code ersetzen") { replacing = true; message = nil }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Spacer(minLength: 0)
      }
    } else {
      HStack(spacing: 8) {
        InputCapsule(placeholder: "Notion-Zugangscode", text: $code, secure: true)
        Button { saveCode() } label: {
          if busy { ProgressView().controlSize(.mini) } else { Text("Verbinden") }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
        if replacing {
          Button("Abbrechen") { replacing = false; code = "" }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      }
    }
  }

  private func rename() {
    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = NotionAccountLogic.renameProblem(name, account: account, accounts: accounts) {
      message = (false, problem)
      return
    }
    renaming = false
    Task {
      let r = await model.services.updateNotionAccount(account.id, name: name, categoryId: nil)
      await model.refresh()
      message = r.isOk ? nil : (false, r.errorMessage ?? "Der Name konnte nicht gespeichert werden.")
    }
  }

  private func assign(_ categoryId: String) {
    guard categoryId != account.categoryId else { return }
    Task {
      let r = await model.services.updateNotionAccount(account.id, name: nil, categoryId: categoryId)
      await model.refresh()
      message = r.isOk ? nil : (false, r.errorMessage ?? "Die Kategorie konnte nicht gespeichert werden.")
    }
  }

  /// Der Code geht nur in den Dienst (Schlüsselbund); danach ist das Feld leer.
  private func saveCode() {
    busy = true
    message = nil
    Task {
      let r = await model.services.setNotionAccountToken(account.id, token: code)
      code = ""
      replacing = false
      await model.refresh()
      busy = false
      message = r.isOk ? (true, "Zugangscode gespeichert.") : (false, r.errorMessage ?? "Fehlgeschlagen.")
    }
  }

  private func remove(deleteTasks: Bool) {
    Task {
      let r = await model.services.removeNotionAccount(account.id, deleteTasks: deleteTasks)
      await model.refresh()
      if !r.isOk { message = (false, r.errorMessage ?? "Der Zugang konnte nicht entfernt werden.") }
    }
  }
}

/// „+ Notion-Zugang“: Formular für einen neuen Zugang mit eigenem Zugangscode (höchstens 8).
struct NotionAccountAdder: View {
  let accounts: [NotionAccount]
  let categories: [TaskCategoryDef]
  @EnvironmentObject var model: AppModel
  @State private var adding: Bool
  @State private var name = ""
  @State private var categoryId = ""
  @State private var code = ""
  @State private var busy = false
  @State private var message: String?

  /// `startOpen` zeigt das Formular gleich (Vorschau und Prüfungen).
  init(accounts: [NotionAccount], categories: [TaskCategoryDef], startOpen: Bool = false) {
    self.accounts = accounts
    self.categories = categories
    _adding = State(initialValue: startOpen)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if adding {
        form
      } else {
        Button { adding = true; message = nil } label: { Text("+ Notion-Zugang") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(!NotionAccountLogic.canAdd(count: accounts.count))
      }
      if !NotionAccountLogic.canAdd(count: accounts.count) {
        Text("Höchstens \(NotionAccountRules.maxCount) Notion-Zugänge.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      if let message {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 8) {
      FieldRow(label: "Name") {
        InputCapsule(placeholder: "z. B. Privat", text: $name)
      }
      FieldRow(label: "Gehört zu:") {
        WrapLayout(spacing: 4) {
          ForEach(categories) { c in
            ChoiceChip(text: c.name, selected: c.id == categoryId) { categoryId = c.id }
          }
        }
      }
      FieldRow(label: "Zugangscode") {
        InputCapsule(placeholder: "Notion-Zugangscode", text: $code, secure: true)
      }
      Text("So geht’s: In Notion unter „Meine Integrationen“ eine neue Integration anlegen und ihren Zugangscode hier einfügen. "
        + "Danach die Datenbank oder Seite in Notion über „Verbindungen“ für diese Integration freigeben.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button { add() } label: {
          if busy { ProgressView().controlSize(.mini) } else { Text("Anlegen") }
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        .disabled(busy)
        Button("Abbrechen") { adding = false; name = ""; categoryId = ""; code = ""; message = nil }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.capsule))
  }

  private func add() {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let problem = NotionAccountLogic.addProblem(name: trimmed, categoryId: categoryId, token: code,
                                                   accounts: accounts, defs: categories) {
      message = problem
      return
    }
    busy = true
    message = nil
    Task {
      let r = await model.services.addNotionAccount(name: trimmed, categoryId: categoryId, token: code)
      code = ""
      busy = false
      await model.refresh()
      if r.isOk {
        adding = false
        name = ""
        categoryId = ""
      } else {
        message = r.errorMessage ?? "Der Zugang konnte nicht angelegt werden."
      }
    }
  }
}
