// Reiter "Notizen": anlegen (Titel, Inhalt klappt auf), Karten mit Titel und
// Vorschau, antippen zum Aufklappen. Aufgeklappt: Lese-Ansicht mit anklickbaren
// Checkboxen ("- [ ]…"), "Bearbeiten" wechselt in den Editor.
// Im eigenen Fenster (DetachedNotesView) füllen Liste und Editor die Fensterfläche.
import SwiftUI
import TabyCore

extension EnvironmentValues {
  /// true im eigenen Werkzeugfenster: Notizen nutzen die volle Höhe statt der Insel-Deckel.
  var tabyDetached: Bool {
    get { self[TabyDetachedKey.self] }
    set { self[TabyDetachedKey.self] = newValue }
  }
}

private struct TabyDetachedKey: EnvironmentKey {
  static let defaultValue = false
}

/// Notizen im eigenen Fenster (ToolWindow): füllt Breite und Höhe der Fensterfläche.
public struct DetachedNotesView: View {
  let notes: [Note]
  let tasks: [TabyTask]
  var expanded: String?

  public init(notes: [Note], expanded: String? = nil, tasks: [TabyTask] = []) {
    self.notes = notes
    self.expanded = expanded
    self.tasks = tasks
  }

  public var body: some View {
    NotesView(notes: notes, expanded: expanded, tasks: tasks)
      .environment(\.tabyDetached, true)
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

struct NotesView: View {
  let notes: [Note]
  /// Aufgaben für Zuordnung und Chip; ohne Liste bleiben Chips und Menü leer.
  let tasks: [TabyTask]
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyDetached) private var detached
  @State private var title = ""
  @State private var content = ""
  @State private var composing = false
  @State private var expanded: String?
  @State private var error: String?
  /// Gewählte Kennzeichen der Filterleiste (alle müssen passen).
  @State private var tagFilter: [String] = []
  /// Aufgeklappte Notiz startet im Bearbeiten-Modus (nur für Snapshots gedacht).
  private let startEditing: Bool

  init(notes: [Note], expanded: String? = nil, composing: Bool = false, tasks: [TabyTask] = [],
       startEditing: Bool = false) {
    self.notes = notes
    self.tasks = tasks
    self.startEditing = startEditing
    _expanded = State(initialValue: expanded)
    _composing = State(initialValue: composing)
  }

  /// Kennzeichen der Notizen (Filterleiste) und die nach dem Filter sichtbaren Notizen.
  private var noteTagNames: [String] { TagLogic.allTags(tasks: [], notes: notes).map(\.name) }
  private var shownNotes: [Note] { notes.filter { TagLogic.matches($0.tags, selected: tagFilter) } }
  /// Kennzeichen aller Notizen und Aufgaben: Vorschläge im Kennzeichen-Feld.
  private var knownTags: [String] { TagLogic.allTags(tasks: tasks, notes: notes).map(\.name) }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 10) {
        PageHeader(title: "Notizen", subtitle: notes.isEmpty ? nil : "\(notes.count)")
        composer
        if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
        if !noteTagNames.isEmpty { TagFilterRow(names: noteTagNames, selected: $tagFilter) }
        if detached {
          detachedList
        } else {
          CappedScroll(maxHeight: (composing ? 170 : 262) - (noteTagNames.isEmpty ? 0 : 30)) { cards(shownNotes) }
        }
        if let label = model.undoBannerLabel, ViewSupportLogic.undoVisible(label) {
          UndoBanner(label: label).transition(.opacity)
        }
      }
      .frame(maxWidth: detached ? .infinity : nil, maxHeight: detached ? .infinity : nil, alignment: .top)
      .animation(Theme.spring, value: notes)
      .animation(Theme.spring, value: composing)
      .onAppear { focus(proxy) }
      .onChange(of: model.focusedNoteId) { _, _ in focus(proxy) }
      .onChange(of: noteTagNames) { _, names in tagFilter = tagFilter.filter { names.contains($0) } }
    }
  }

  /// Von außen gewählte Notiz (z. B. aus einer Aufgabe): aufklappen und in den Blick holen, danach zurücksetzen.
  /// Bearbeiten wird nicht erzwungen. Liegt die Notiz hinter dem Kennzeichen-Filter, fällt der Filter weg.
  private func focus(_ proxy: ScrollViewProxy) {
    guard let id = model.focusedNoteId else { return }
    model.focusedNoteId = nil
    guard let note = notes.first(where: { $0.id == id }) else { return }
    if !TagLogic.matches(note.tags, selected: tagFilter) { tagFilter = [] }
    withAnimation(Theme.spring) { expanded = id }
    DispatchQueue.main.async {
      withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .top) }
    }
  }

  /// Eigenes Fenster: ohne Aufklappen füllt die Liste die Höhe; mit aufgeklappter
  /// Notiz scrollen die übrigen oben (begrenzt), die Notiz füllt den Rest.
  @ViewBuilder private var detachedList: some View {
    if let open = shownNotes.first(where: { $0.id == expanded }) {
      let others = shownNotes.filter { $0.id != open.id }
      VStack(alignment: .leading, spacing: 8) {
        if !others.isEmpty {
          CappedScroll(maxHeight: 150) { cards(others) }
        }
        NoteCard(note: open, expanded: true, tasks: tasks, knownTags: knownTags,
                 onTap: { withAnimation(Theme.spring) { expanded = nil } })
          .frame(maxHeight: .infinity, alignment: .top)
      }
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      NoteFill(fills: true) { cards(shownNotes) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
  }

  private func cards(_ list: [Note]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if notes.isEmpty {
        EmptyState(symbol: "note.text", title: "Noch keine Notizen", subtitle: "Schreib oben einen Titel und tippe +.")
      } else if list.isEmpty {
        EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Keine Treffer",
                   subtitle: "Wähle oben „Alle“ oder entferne einen Kennzeichen-Filter.")
      }
      ForEach(list) { n in
        NoteCard(note: n, expanded: expanded == n.id, tasks: tasks, knownTags: knownTags,
                 startEditing: startEditing && expanded == n.id) {
          withAnimation(Theme.spring) { expanded = expanded == n.id ? nil : n.id }
        }
        .transition(Theme.rowTransition)
        .id(n.id)
      }
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      InputCapsule(placeholder: "Titel der Notiz …", text: $title) {
        Button {
          withAnimation(Theme.spring) { composing.toggle() }
        } label: { Image(systemName: composing ? "chevron.up" : "text.alignleft") }
          .buttonStyle(RoundIconButtonStyle(size: 26))
          .help("Text hinzufügen")
          .accessibilityLabel("Text hinzufügen")
        Button(action: add) { Image(systemName: "plus") }
          .buttonStyle(RoundIconButtonStyle(size: 26, filled: true))
          .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityLabel("Hinzufügen")
      }
      .onSubmit(add)
      if composing {
        TextArea(placeholder: "Inhalt (optional)", text: $content, minHeight: 64)
          .frame(maxHeight: detached ? 200 : 90)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
  }

  private func add() {
    let t = title, c = content
    Task {
      error = await ViewActions.addNote(model, title: t, content: c)
      if error == nil {
        title = ""
        content = ""
        withAnimation(Theme.spring) { composing = false }
      }
    }
  }
}

struct NoteCard: View {
  let note: Note
  let expanded: Bool
  let tasks: [TabyTask]
  let onTap: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var title: String
  @State private var content: String
  @State private var hover = false
  @State private var editing: Bool
  @State private var assignOpen = false
  @Environment(\.tabySnapshot) private var snapshot
  @Environment(\.tabyDetached) private var detached

  /// Kennzeichen aller Notizen und Aufgaben: Vorschläge im Bearbeiten-Modus.
  let knownTags: [String]

  init(note: Note, expanded: Bool, tasks: [TabyTask] = [], knownTags: [String] = [], startEditing: Bool = false,
       onTap: @escaping () -> Void) {
    self.note = note
    self.expanded = expanded
    self.tasks = tasks
    self.knownTags = knownTags
    self.onTap = onTap
    _title = State(initialValue: note.title)
    _content = State(initialValue: note.content)
    _editing = State(initialValue: startEditing)
  }

  private var dirty: Bool { title != note.title || content != note.content }

  /// Vorschau der Karte: Checkboxen als ☐/☑ statt Markdown-Syntax.
  private var preview: String {
    NoteCheckboxes.lines(note.content).map { line in
      line.kind == .checkbox ? (line.checked ? "☑ " : "☐ ") + line.text : line.text
    }.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if expanded {
        titleText
        tagLine
        taskBar
        expandedContent
        buttons
      } else {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            taskChip
            if !note.tags.isEmpty { TagChipList(own: note.tags) }
            if !note.content.isEmpty {
              Text(preview).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
          }
          Spacer(minLength: 6)
          // Immer sichtbar (gedämpft), nicht nur beim Überfahren; „…“ bündelt Groß öffnen und Obsidian.
          HStack(spacing: 4) {
            moreMenu
            Button {
              Task { _ = await ViewActions.deleteNote(model, id: note.id) }
            } label: { Image(systemName: "trash") }
              .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.red.opacity(hover ? 0.9 : 0.55)))
              .help("Notiz löschen")
              .accessibilityLabel("Notiz löschen")
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: expanded && detached ? .infinity : nil, alignment: .top)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover || expanded ? Theme.raisedHover : Theme.raised))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
      .strokeBorder(Color.white.opacity(expanded ? 0.16 : 0.05), lineWidth: 1))
    .scaleEffect(hover && !expanded ? 1.01 : 1)
    .onHover { h in withAnimation(Theme.snappy) { hover = h } }
    .onChange(of: note) { _, n in if !editing { title = n.title; content = n.content } }
    .onChange(of: expanded) { _, e in if !e { editing = false } }
    .contextMenu {
      if !detached, let detach = model.onDetach {
        Button("Groß öffnen") { detach(.notes) }
      }
      if ObsidianLogic.isConnected(model.state) {
        Button("In Obsidian ablegen") {
          Task { await ObsidianActions.saveNote(model, title: note.title, content: note.content) }
        }
      }
      Button("Notiz löschen", role: .destructive) {
        Task { _ = await ViewActions.deleteNote(model, id: note.id) }
      }
    }
  }

  /// Sichtbares „…“ an der Karte: dieselben Befehle wie im Kontextmenü.
  @ViewBuilder private var moreMenu: some View {
    if snapshot {
      // Vorschau: das Menü rendert dort mit Verbotssymbol; ein schlichtes Symbol genügt.
      Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
        .frame(width: 22, height: 22)
    } else {
      menu
    }
  }

  private var menu: some View {
    Menu {
      if !detached, let detach = model.onDetach {
        Button("Groß öffnen") { detach(.notes) }
      }
      if ObsidianLogic.isConnected(model.state) {
        Button("In Obsidian ablegen") {
          Task { await ObsidianActions.saveNote(model, title: note.title, content: note.content) }
        }
      }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
        .frame(width: 22, height: 22)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Weitere Aktionen")
    .accessibilityLabel("Weitere Aktionen")
  }

  @ViewBuilder private var titleText: some View {
    Group {
      if editing && !snapshot {
        TextField("", text: $title).textFieldStyle(.plain)
      } else {
        Text(title)
      }
    }
    .font(.system(size: detached ? 15 : 13, weight: .semibold))
    .foregroundStyle(Theme.text)
  }

  /// Aufgeklappt: im Bearbeiten-Modus der Kennzeichen-Editor, sonst nur die Chips.
  @ViewBuilder private var tagLine: some View {
    if editing {
      TagEditor(tags: note.tags, known: knownTags, onChange: setTags)
    } else if !note.tags.isEmpty {
      TagChipList(own: note.tags)
    }
  }

  private func setTags(_ tags: [String]) {
    Task { _ = await ViewActions.setNoteTags(model, id: note.id, tags: tags) }
  }

  @ViewBuilder private var taskChip: some View {
    if let title = TaskNotesLogic.taskTitle(for: note, in: tasks) {
      NoteTaskChip(title: title)
    }
  }

  /// Aufgeklappt: Stand der zugeordneten Aufgabe mit Menü und "Aufgabe erledigt".
  @ViewBuilder private var taskBar: some View {
    if let id = note.taskId, let task = tasks.first(where: { $0.id == id }) {
      NoteTaskStatusBar(task: task)
    }
  }

  /// Zuordnung zu einer offenen Aufgabe; "" löst sie wieder.
  private func assign(_ taskId: String) {
    Task { _ = await ViewActions.setNoteTask(model, id: note.id, taskId: taskId) }
  }

  @ViewBuilder private var expandedContent: some View {
    if editing {
      VStack(alignment: .leading, spacing: 4) {
        NoteTextEditor(text: $content, fills: detached)
          .frame(maxHeight: detached ? .infinity : nil, alignment: .top)
        editStatus
      }
    } else {
      NoteFill(fills: detached) {
        NoteChecklist(content: content, large: detached, onToggle: toggle)
      }
    }
  }

  /// Wort- und Zeichenzähler sowie der Speicherstand unter dem Editor (dezent).
  private var editStatus: some View {
    let s = NoteFormatting.stats(content)
    return HStack(spacing: 6) {
      Text(NoteFormatting.saveLabel(dirty: dirty))
        .foregroundStyle(dirty ? Theme.orange : Theme.secondary)
      Spacer(minLength: 4)
      Text("\(s.words) Wörter · \(s.chars) Zeichen").foregroundStyle(Theme.tertiary)
    }
    .font(.system(size: 10, weight: .medium))
    .accessibilityElement(children: .combine)
  }

  private var buttons: some View {
    HStack(spacing: 6) {
      Button("Löschen", role: .destructive) {
        Task { _ = await ViewActions.deleteNote(model, id: note.id) }
      }
      .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      .fixedSize()
      if editing {
        Button { content = NoteCheckboxes.appendCheckbox(to: content) } label: {
          Image(systemName: "checklist")
        }
        .help("Checkbox einfügen")
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .keyboardShortcut("c", modifiers: [.command, .shift])
        Button { assignOpen = true } label: {
          Label("Aufgabe zuordnen", systemImage: "link")
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .fixedSize()
        .popover(isPresented: $assignOpen, arrowEdge: .bottom) {
          NoteTaskPicker(tasks: tasks, current: note.taskId) { id in
            assignOpen = false
            assign(id)
          }
        }
      }
      Spacer()
      if editing {
        Button("Abbrechen") {
          title = note.title
          content = note.content
          editing = false
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .fixedSize()
        Button("Sichern", action: save)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!dirty)
      } else {
        Button("Schließen", action: onTap)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        if !detached, let detach = model.onDetach {
          Button { detach(.notes) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            .help("Groß öffnen")
        }
        Button("Bearbeiten") { editing = true }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
    }
  }

  private func save() {
    let t = title, c = content
    Task {
      let error = await ViewActions.updateNote(model, id: note.id, title: t, content: c)
      if error == nil { editing = false }
    }
  }

  /// Checkbox in der Lese-Ansicht umschalten und sofort speichern (übrige Zeilen bleiben gleich).
  private func toggle(_ line: Int) {
    let next = NoteCheckboxes.toggleCheckbox(in: content, line: line)
    guard next != content else { return }
    content = next
    let t = title
    Task { _ = await ViewActions.updateNote(model, id: note.id, title: t, content: next) }
  }
}
