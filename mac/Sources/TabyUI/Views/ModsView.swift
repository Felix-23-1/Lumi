// Reiter "Mods" (Paket 3): Bibliothek mit Kurzbefehl- und Skript-Mods.
// Einschalten = Freigabe der aktuellen Fassung samt Rechten; bei Skript-Mods
// sieht man vorher Rechte und Code. Teilen per `.tabymod`-Datei.
import AppKit
import SwiftUI
import TabyCore

enum ModsLogic {
  enum Status: Equatable { case active, off, needsApproval }

  static func status(_ m: ModInfo) -> Status {
    if m.enabled && m.approved { return .active }
    if m.enabled && !m.approved { return .needsApproval }
    return .off
  }

  static func statusText(_ s: Status) -> String {
    switch s {
    case .active: "Aktiv"
    case .off: "Aus"
    case .needsApproval: "Neue Fassung – Freigabe nötig"
    }
  }

  static func triggerText(_ t: ModTrigger) -> String {
    switch t {
    case .focusStarted: "bei Fokus-Start"
    case .focusFinished: "nach dem Fokus"
    case .dayStarted: "beim Briefing"
    case .dayEnded: "beim Tagesabschluss"
    case .hourly: "stündlich"
    }
  }

  /// Was der Nutzer beim Einschalten freigibt (deutsch, für die Freigabe-Karte).
  static func grants(_ m: ModManifest) -> [String] {
    switch m.kind {
    case .shortcut:
      return ["Kurzbefehl „\(m.shortcutName ?? m.name)“ ausführen (kann alles, was der Kurzbefehl kann)"]
    case .script:
      let warning = ModPermission.exfiltrationWarning(m.permissions).map { [$0] } ?? []
      return (m.permissions.isEmpty ? ["Keine besonderen Rechte"] : m.permissions.map(ModPermission.describe)) + warning
    case .skill:
      let tools = m.tools ?? []
      return ["Anleitung ans Modell schicken"] + (tools.isEmpty ? ["Nur lesende Werkzeuge"] : tools.map { "Werkzeug „\($0)“" })
    }
  }

  /// Ab vier Mods trennt der Reiter „Meine Mods“ und „Bibliothek“.
  static func splitView(_ count: Int) -> Bool { count > 3 }

  /// Frisch hinzugefügt: noch nie freigegeben und aus.
  static func isNew(_ m: ModInfo) -> Bool { !m.approved && !m.enabled }

  static func sorted(_ mods: [ModInfo]) -> [ModInfo] {
    mods.sorted { a, b in
      let ra = rank(status(a)), rb = rank(status(b))
      return ra != rb ? ra < rb : a.manifest.name.localizedCaseInsensitiveCompare(b.manifest.name) == .orderedAscending
    }
  }

  private static func rank(_ s: Status) -> Int {
    switch s {
    case .needsApproval: 0
    case .active: 1
    case .off: 2
    }
  }
}

struct ModsView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @State private var adding = false
  @State private var addingSkill = false
  @State private var message: (ok: Bool, text: String)?
  @State private var reviewing: String?
  @State private var catalog: [CatalogMod] = []
  @State private var showLibrary = false

  private var split: Bool { ModsLogic.splitView(state.mods.count) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Mods", subtitle: "\(state.mods.filter { ModsLogic.status($0) == .active }.count) aktiv") {
        Button { importMod() } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .help("Mod importieren (.tabymod)")
        Button { withAnimation(Theme.spring) { addingSkill.toggle() } } label: {
          Label("Skill", systemImage: "plus")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .help("Skill ohne Code anlegen")
        Button { withAnimation(Theme.spring) { adding.toggle() } } label: {
          Label("Mod", systemImage: "plus")
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
      Text("Mods erweitern Lumi um Kurzbefehle und Werkzeuge. Skills sind Anleitungen für das Modell.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if split {
        WrapLayout(spacing: 6) {
          ChoiceChip(text: "Meine Mods", selected: !showLibrary) { showLibrary = false }
          ChoiceChip(text: "Bibliothek", selected: showLibrary) { showLibrary = true }
        }
      }
      if let m = message {
        Banner(symbol: m.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", text: m.text,
               tint: m.ok ? Theme.green : Theme.red)
      }
      CappedScroll(maxHeight: 300) {
        VStack(alignment: .leading, spacing: 8) {
          if adding { AddShortcutModForm { done in withAnimation(Theme.spring) { adding = !done } } }
          if addingSkill { AddSkillForm { done in withAnimation(Theme.spring) { addingSkill = !done } } }
          if state.mods.isEmpty { librarySection }
          if state.mods.isEmpty && !adding {
            EmptyState(symbol: "puzzlepiece.extension", title: "Noch keine Mods",
                       subtitle: "Füge einen Mod aus einem Kurzbefehl hinzu oder sag im Chat: „Bau mir einen Mod, der…“")
          }
          if !(split && showLibrary) {
            ForEach(ModsLogic.sorted(state.mods)) { m in
              ModCard(mod: m, reviewing: reviewing == m.id,
                      onReview: { withAnimation(Theme.spring) { reviewing = reviewing == m.id ? nil : m.id } },
                      onMessage: showMessage)
                .transition(Theme.rowTransition)
            }
          }
          if !state.mods.isEmpty && (!split || showLibrary) { librarySection }
          Text("Tipp: Im Chat „Bau mir einen Mod, der…“ – Lumi schreibt ihn, du prüfst Rechte und Code und schaltest ihn ein.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .animation(Theme.spring, value: state.mods)
    .task { catalog = await model.services.modCatalog() }
    .safeAreaInset(edge: .bottom) {
      if let label = model.undoBannerLabel, ViewSupportLogic.undoVisible(label) {
        UndoBanner(label: label).transition(.opacity)
      }
    }
  }

  /// Fertige Mods zum Hinzufügen; erscheinen installiert in der Liste darüber (ausgeschaltet).
  @ViewBuilder private var librarySection: some View {
    if !catalog.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "books.vertical", title: "Bibliothek", count: catalog.count)
        ForEach(catalog) { entry in
          CatalogRow(entry: entry, installed: state.mods.contains { $0.id == entry.id }, onMessage: showMessage)
        }
      }
    }
  }

  private func showMessage(_ ok: Bool, _ text: String) {
    withAnimation(Theme.spring) { message = (ok, text) }
  }

  private func importMod() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Mod-Datei (.tabymod) wählen"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let r = await model.services.importMod(from: url.path)
      await model.refresh()
      switch r {
      case .ok(let m): message = (true, "„\(m.manifest.name)“ importiert – prüfen und einschalten.")
      case .failure(_, let e): message = (false, e)
      }
    }
  }
}

/// Eintrag der Bibliothek: Name, Beschreibung, Rechte und Auslöser; „Hinzufügen“ legt ihn ausgeschaltet an.
struct CatalogRow: View {
  let entry: CatalogMod
  let installed: Bool
  let onMessage: (Bool, String) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var busy = false

  private var m: ModManifest { entry.manifest }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: m.kind == .shortcut ? "bolt.fill" : "puzzlepiece.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(m.kind == .shortcut ? Theme.amber : Color(red: 0.55, green: 0.7, blue: 1))
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
      VStack(alignment: .leading, spacing: 4) {
        Text(m.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
        Text(m.description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 3) {
          Text("Darf:").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
          WrapLayout(spacing: 4) {
            ForEach(ModsLogic.grants(m), id: \.self) { Chip(text: $0, symbol: "checkmark.shield") }
          }
          if !m.triggers.isEmpty {
            Text("Läuft: " + m.triggers.map(ModsLogic.triggerText).joined(separator: ", "))
              .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
              .padding(.top, 3)
          }
        }
      }
      Spacer(minLength: 4)
      if installed {
        Button("Installiert") {}
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(true)
      } else {
        Button("Hinzufügen") { add() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(busy)
      }
    }
    .tabyCard()
  }

  private func add() {
    busy = true
    Task {
      let r = await model.services.installCatalogMod(entry.id)
      await model.refresh()
      busy = false
      if case .failure(_, let e) = r {
        onMessage(false, e)
      } else {
        onMessage(true, "„\(m.name)“ hinzugefügt – prüfen und freigeben, dann einschalten.")
        model.react(.itemAdded)
      }
    }
  }
}

private struct ModCard: View {
  let mod: ModInfo
  let reviewing: Bool
  let onReview: () -> Void
  let onMessage: (Bool, String) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var busy = false
  @State private var testOutput: String?
  @State private var confirmRemove = false

  private var status: ModsLogic.Status { ModsLogic.status(mod) }
  private var m: ModManifest { mod.manifest }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: m.kind == .shortcut ? "bolt.fill" : "puzzlepiece.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(m.kind == .shortcut ? Theme.amber : Color(red: 0.55, green: 0.7, blue: 1))
          .frame(width: 30, height: 30)
          .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(m.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if status != .off {
              Chip(text: ModsLogic.statusText(status),
                   tint: status == .active ? Theme.green : Theme.amber)
            }
            if ModsLogic.isNew(mod) {
              Chip(text: "Hinzugefügt – zum Benutzen einschalten", symbol: "sparkles", tint: Theme.blue)
            }
          }
          Text(m.description).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
          HStack(spacing: 4) {
            if m.tool != nil { Chip(text: "Werkzeug fürs Modell", symbol: "wand.and.stars") }
            ForEach(m.triggers, id: \.self) { t in Chip(text: ModsLogic.triggerText(t), symbol: "clock") }
          }
          if let e = mod.lastError {
            Text("Letzter Fehler: \(e)").font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(2)
          }
        }
        Spacer(minLength: 4)
        MiniToggle(isOn: status == .active) { on in
          if on && status != .active { onReview() } else { setEnabled(false) }
        }
      }
      if !(m.settings ?? []).isEmpty { ModSettingsFields(mod: mod, onMessage: onMessage) }
      if reviewing { approval.transition(.move(edge: .top).combined(with: .opacity)) }
      if let out = testOutput {
        Text(out).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
          .lineLimit(4).textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
      }
      HStack(spacing: 6) {
        Spacer()
        Button("Testen") { test() }.buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          .disabled(busy || status != .active)
          .help(status == .active ? "Mod einmal ausführen und die Ausgabe zeigen" : "erst einschalten")
        Button("Teilen") { share() }.buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Menu {
          Button("Löschen", role: .destructive) { confirmRemove = true }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Weitere Optionen")
        .accessibilityLabel("Weitere Optionen")
      }
      .disabled(busy)
    }
    .confirmationDialog("Mod löschen?", isPresented: $confirmRemove, titleVisibility: .visible) {
      Button("Löschen", role: .destructive) { remove() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("„\(mod.manifest.name)“ wird entfernt. Rückgängig geht nicht.")
    }
    .tabyCard(tint: status == .needsApproval ? Theme.amber : nil)
  }

  /// Freigabe-Karte: was der Mod darf, bei Skripten auch der Code.
  private var approval: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Beim Einschalten erlaubst du:").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
      ForEach(ModsLogic.grants(m), id: \.self) { g in
        Label(g, systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      if let code = mod.code {
        Text(code).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.secondary)
          .lineLimit(12).textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
      }
      HStack {
        Spacer()
        Button("Abbrechen", action: onReview).buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button("Freigeben & einschalten") { setEnabled(true) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.amber.opacity(0.08)))
  }

  private func setEnabled(_ on: Bool) {
    busy = true
    Task {
      let r = await model.services.setModEnabled(mod.id, on)
      await model.refresh()
      busy = false
      if case .failure(_, let e) = r { onMessage(false, e) } else if on { onReview(); model.react(.celebrate) }
    }
  }

  private func test() {
    busy = true
    Task {
      let r = await model.services.runMod(mod.id, input: nil)
      busy = false
      withAnimation(Theme.spring) {
        switch r {
        case .ok(let out): testOutput = out.isEmpty ? "(keine Ausgabe)" : out
        case .failure(_, let e): testOutput = "Fehler: \(e)"
        }
      }
      await model.refresh()
    }
  }

  private func share() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Hier speichern"
    panel.message = "Ordner für die Mod-Datei wählen"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let r = await model.services.exportMod(mod.id, to: url.path)
      switch r {
      case .ok(let path):
        onMessage(true, "Gespeichert: \(path)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      case .failure(_, let e): onMessage(false, e)
      }
    }
  }

  private func remove() {
    busy = true
    Task {
      let r = await model.services.deleteMod(mod.id)
      await model.refresh()
      busy = false
      model.react(r.isOk ? .itemDeleted : .failed(r.errorMessage ?? "Löschen fehlgeschlagen."))
      onMessage(r.isOk, r.isOk ? "Mod gelöscht." : (r.errorMessage ?? "Löschen fehlgeschlagen."))
    }
  }
}

/// Kleiner Schalter, der nur meldet – der Zustand kommt immer vom Kern.
/// Vom Mod deklarierte Einstellungen (Text, Zahl, Ja/Nein). Ändern braucht keine neue Freigabe.
private struct ModSettingsFields: View {
  let mod: ModInfo
  let onMessage: (Bool, String) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var values: [String: String] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(mod.manifest.settings ?? [], id: \.key) { setting in
        HStack(spacing: 8) {
          Text(setting.label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
          Spacer(minLength: 4)
          if setting.kind == .toggle {
            Toggle("", isOn: Binding(get: { values[setting.key] == "true" },
                                     set: { save(setting.key, $0 ? "true" : "false") }))
              .labelsHidden()
          } else {
            TextField("", text: Binding(get: { values[setting.key] ?? "" }, set: { values[setting.key] = $0 }))
              .textFieldStyle(.roundedBorder)
              .frame(width: 150)
              .onSubmit { save(setting.key, values[setting.key] ?? "") }
          }
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    .onAppear {
      for setting in mod.manifest.settings ?? [] {
        values[setting.key] = mod.settingValues[setting.key] ?? setting.defaultValue ?? ""
      }
    }
  }

  private func save(_ key: String, _ value: String) {
    values[key] = value
    Task {
      let r = await model.services.setModSetting(mod.id, key: key, value: value)
      if case .failure(_, let e) = r { onMessage(false, e) }
      await model.refresh()
    }
  }
}

private struct MiniToggle: View {
  let isOn: Bool
  let onChange: (Bool) -> Void
  var body: some View {
    Button { onChange(!isOn) } label: {
      Capsule().fill(isOn ? Theme.green : Theme.raised)
        .frame(width: 34, height: 20)
        .overlay(alignment: isOn ? .trailing : .leading) {
          Circle().fill(.white).frame(width: 16, height: 16).padding(2)
        }
        .animation(Theme.spring, value: isOn)
    }
    .buttonStyle(.plain)
    .help(isOn ? "Ausschalten" : "Prüfen & einschalten")
    .accessibilityLabel(isOn ? "Ausschalten" : "Prüfen und einschalten")
  }
}

/// Neuer Kurzbefehl-Mod: Kurzbefehl wählen, Beschreibung, wann er läuft.
private struct AddSkillForm: View {
  let onDone: (Bool) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var name = ""
  @State private var command = ""
  @State private var prompt = ""
  @State private var tools: Set<String> = []
  @State private var error: String?

  /// Werkzeuge aus der Registry (Chat-Werkzeuge und Mail/Kontakte); der Skill bekommt nur die angehakten.
  private static let toolNames: [String] =
    (ToolRegistry.definitions + MailTools.definitions + ContactTools.defs).map(\.name).sorted()

  private var canAdd: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "text.badge.star", title: "Skill ohne Code")
      InputCapsule(placeholder: "Name (z. B. „Wochenplanung“)", text: $name)
      InputCapsule(placeholder: "Befehl im Chat ohne „/“ (z. B. „wochenplan“)", text: $command)
      NoteTextEditor(text: $prompt)
      Text("Werkzeuge, die der Skill nutzen darf (ohne Auswahl: nur lesende)")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      CappedScroll(maxHeight: 96) {
        WrapLayout(spacing: 4) {
          ForEach(Self.toolNames, id: \.self) { t in
            ChoiceChip(text: t, selected: tools.contains(t)) {
              if tools.contains(t) { tools.remove(t) } else { tools.insert(t) }
            }
          }
        }
      }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
      HStack {
        Spacer()
        Button("Abbrechen") { onDone(true) }.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button("Hinzufügen") { add() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(!canAdd)
      }
    }
    .tabyCard()
  }

  private func add() {
    Task {
      let r = await model.services.createSkillMod(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines), command: command.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt,
        tools: Self.toolNames.filter { tools.contains($0) })
      await model.refresh()
      if case .failure(_, let e) = r { error = e } else { model.react(.itemAdded); onDone(true) }
    }
  }
}

private struct AddShortcutModForm: View {
  let onDone: (Bool) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var shortcuts: [String] = []
  @State private var selected = ""
  @State private var description = ""
  @State private var asTool = true
  @State private var triggers: Set<ModTrigger> = []
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "bolt", title: "Kurzbefehl als Mod")
      if shortcuts.isEmpty {
        Text(error ?? "Lade Kurzbefehle…").font(.system(size: 12)).foregroundStyle(error == nil ? Theme.tertiary : Theme.red)
      } else {
        CappedScroll(maxHeight: 96) {
          WrapLayout(spacing: 4) {
            ForEach(shortcuts, id: \.self) { s in
              ChoiceChip(text: s, selected: selected == s) {
                selected = s
                if description.isEmpty { description = s }
              }
            }
          }
        }
      }
      InputCapsule(placeholder: "Was macht er? (z. B. „Schaltet Nicht stören ein“)", text: $description)
      PillToggle(title: "Lumi darf ihn im Chat benutzen", isOn: $asTool)
      HStack(spacing: 4) {
        Text("Automatisch:").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        ForEach(ModTrigger.allCases, id: \.self) { t in
          ChoiceChip(text: ModsLogic.triggerText(t), selected: triggers.contains(t)) {
            if triggers.contains(t) { triggers.remove(t) } else { triggers.insert(t) }
          }
        }
      }
      HStack {
        Spacer()
        Button("Abbrechen") { onDone(true) }.buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button("Hinzufügen") { add() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(selected.isEmpty)
      }
    }
    .tabyCard()
    .task {
      switch await model.services.listShortcuts() {
      case .ok(let list): shortcuts = list; if list.isEmpty { error = "Keine Kurzbefehle gefunden. Leg einen in der App „Kurzbefehle“ an." }
      case .failure(_, let e): error = e
      }
    }
  }

  private func add() {
    Task {
      let r = await model.services.createShortcutMod(
        shortcutName: selected, description: description.isEmpty ? selected : description, asTool: asTool,
        triggers: ModTrigger.allCases.filter { triggers.contains($0) })
      await model.refresh()
      if case .failure(_, let e) = r { error = e } else { model.react(.itemAdded); onDone(true) }
    }
  }
}
