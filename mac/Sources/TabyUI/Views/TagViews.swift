// Kennzeichen (Tags) an Aufgaben und Notizen: Chips, Eingabe mit Vorschlägen, Filterleiste
// und die reine Logik (sammeln, zählen, vereinigen, filtern, gruppieren, „#wort“ aus Titeln ziehen).
import SwiftUI
import TabyCore

enum TagLogic {
  struct Count: Equatable {
    let name: String
    let count: Int
  }

  /// Vergleichsschlüssel: Groß/Klein egal.
  static func key(_ tag: String) -> String { tag.lowercased() }

  /// Alle Kennzeichen aus Aufgaben und Notizen, je Gegenstand einmal gezählt. Häufigste zuerst, dann nach Name.
  static func allTags(tasks: [TabyTask], notes: [Note]) -> [Count] {
    var counts: [String: (name: String, n: Int)] = [:]
    for tags in tasks.map(\.tags) + notes.map(\.tags) {
      var seen = Set<String>()
      for tag in tags where seen.insert(key(tag)).inserted {
        counts[key(tag), default: (name: tag, n: 0)].n += 1
      }
    }
    return counts.values
      .map { Count(name: $0.name, count: $0.n) }
      .sorted { a, b in
        a.count != b.count ? a.count > b.count : a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
  }

  /// Eigene Kennzeichen der Aufgabe und die ihrer verknüpften Notizen, die sie nicht selbst trägt.
  static func ownAndInherited(_ task: TabyTask, notes: [Note]) -> (own: [String], inherited: [String]) {
    let own = task.tags
    var seen = Set(own.map(key))
    var inherited: [String] = []
    for note in notes where note.taskId == task.id {
      for tag in note.tags where seen.insert(key(tag)).inserted { inherited.append(tag) }
    }
    return (own, inherited)
  }

  /// Vereinigung: eigene Kennzeichen, dann die geerbten der verknüpften Notizen.
  static func taskTags(_ task: TabyTask, notes: [Note]) -> [String] {
    let s = ownAndInherited(task, notes: notes)
    return s.own + s.inherited
  }

  /// Ist `name` (Groß/Klein egal) in `tags` enthalten?
  static func contains(_ tags: [String], name: String) -> Bool {
    tags.contains { key($0) == key(name) }
  }

  /// `tags` ohne `name` (Groß/Klein egal).
  static func removing(_ name: String, from tags: [String]) -> [String] {
    tags.filter { key($0) != key(name) }
  }

  /// Trägt `tags` alle gewählten Kennzeichen? Ohne Auswahl immer ja (Groß/Klein egal).
  static func matches(_ tags: [String], selected: [String]) -> Bool {
    let keys = Set(tags.map(key))
    return selected.allSatisfy { keys.contains(key($0)) }
  }

  /// Aufgaben, die alle gewählten Kennzeichen tragen (eigene oder von Notizen geerbte).
  static func filter(_ tasks: [TabyTask], selected: [String], notes: [Note]) -> [TabyTask] {
    guard !selected.isEmpty else { return tasks }
    return tasks.filter { matches(taskTags($0, notes: notes), selected: selected) }
  }

  /// Abschnitte je Kennzeichen (Reihenfolge wie `allTags`); eine Aufgabe steht unter jedem ihrer Kennzeichen.
  /// Aufgaben ohne Kennzeichen kommen zuletzt.
  static func groups(_ tasks: [TabyTask], notes: [Note]) -> [(id: String, name: String, tasks: [TabyTask])] {
    var out: [(id: String, name: String, tasks: [TabyTask])] = []
    for count in allTags(tasks: tasks, notes: notes) {
      let items = tasks.filter { matches(taskTags($0, notes: notes), selected: [count.name]) }
      if !items.isEmpty { out.append((id: "tag-\(key(count.name))", name: "#\(count.name)", tasks: items)) }
    }
    let untagged = tasks.filter { taskTags($0, notes: notes).isEmpty }
    if !untagged.isEmpty { out.append((id: "tag-none", name: "Ohne Kennzeichen", tasks: untagged)) }
    return out
  }

  /// Zieht „#wort“ aus dem Titel (Buchstaben, Ziffern, „_“, „-“ danach; „#a#b“ ergibt zwei).
  /// Bleibt der Titel leer, bleibt alles wie es war.
  static func extractHashtags(from title: String) -> (title: String, tags: [String]) {
    func starts(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    func inside(_ c: Character) -> Bool { starts(c) || c == "-" }
    let chars = Array(title)
    var tags: [String] = []
    var kept = ""
    var i = 0
    while i < chars.count {
      if chars[i] == "#", i + 1 < chars.count, starts(chars[i + 1]) {
        var j = i + 1
        var name = ""
        while j < chars.count, inside(chars[j]) {
          name.append(chars[j])
          j += 1
        }
        tags.append(name)
        i = j
      } else {
        kept.append(chars[i])
        i += 1
      }
    }
    let cleaned = kept.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    let normalized = TagRules.normalize(tags)
    guard !normalized.isEmpty, !cleaned.isEmpty else { return (title, []) }
    return (cleaned, normalized)
  }
}

/// Kleiner Chip „#name“. Mit `onRemove` zeigt er ein Kreuz zum Entfernen; `dimmed` für geerbte Kennzeichen.
struct TagChip: View {
  let name: String
  var dimmed = false
  var onRemove: (() -> Void)?

  var body: some View {
    let tint = dimmed ? Theme.secondary : Theme.blue
    HStack(spacing: 3) {
      Text("#\(name)").font(.system(size: 10, weight: .medium)).lineLimit(1)
      if let onRemove {
        Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
          .buttonStyle(.plain)
          .accessibilityLabel("Kennzeichen \(name) entfernen")
      }
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Capsule().fill(tint.opacity(0.14)))
    .accessibilityLabel("Kennzeichen \(name)\(dimmed ? ", von einer Notiz" : "")")
  }
}

/// Reihe von Kennzeichen: eigene normal, geerbte gedimmt (nur Anzeige).
struct TagChipList: View {
  let own: [String]
  var inherited: [String] = []

  var body: some View {
    HStack(spacing: 4) {
      ForEach(own, id: \.self) { TagChip(name: $0) }
      ForEach(inherited, id: \.self) { TagChip(name: $0, dimmed: true) }
    }
  }
}

/// Kennzeichen bearbeiten: Chips zum Entfernen, Eingabe (Return fügt hinzu), Vorschläge aus allen bekannten.
struct TagEditor: View {
  let tags: [String]
  /// Alle bekannten Kennzeichen (Aufgaben und Notizen); daraus kommen die Vorschläge.
  let known: [String]
  let onChange: ([String]) -> Void
  @State private var draft = ""
  /// Snapshots zeichnen Eingabefelder gelb; dort nur die Chips.
  @Environment(\.tabySnapshot) private var snapshot

  private var suggestions: [String] {
    let have = Set(tags.map(TagLogic.key))
    let query = TagLogic.key(draft.trimmingCharacters(in: .whitespaces))
    return known
      .filter { !have.contains(TagLogic.key($0)) && (query.isEmpty || TagLogic.key($0).contains(query)) }
      .prefix(8).map { $0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      WrapLayout(spacing: 4) {
        ForEach(tags, id: \.self) { tag in
          TagChip(name: tag, onRemove: { onChange(tags.filter { $0 != tag }) })
        }
        if !snapshot {
          TextField("Kennzeichen hinzufügen…", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .frame(width: 150)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.capsule))
            .onSubmit(commitDraft)
            .onExitCommand { draft = "" }
            .accessibilityLabel("Kennzeichen hinzufügen")
        }
      }
      if !suggestions.isEmpty {
        WrapLayout(spacing: 4) {
          ForEach(suggestions, id: \.self) { s in
            Button { add(s) } label: {
              Text("#\(s)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.capsule))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Kennzeichen \(s) vorschlagen")
          }
        }
      }
    }
  }

  private func commitDraft() {
    add(draft)
  }

  /// Fügt hinzu, bereinigt über `TagRules` (kein „#“, keine Duplikate, Obergrenze); ohne Änderung nichts senden.
  private func add(_ raw: String) {
    draft = ""
    let next = TagRules.normalize(tags + [raw])
    guard next != tags else { return }
    onChange(next)
  }
}

/// Filterleiste: „Alle“ und je Kennzeichen ein Chip; mehrere gewählt wirken zusammen (alle müssen passen).
struct TagFilterRow: View {
  let names: [String]
  @Binding var selected: [String]
  @Environment(\.tabySnapshot) private var snapshot

  private var chips: some View {
    HStack(spacing: 6) {
      ChoiceChip(text: "Alle", selected: selected.isEmpty) { selected = [] }.fixedSize()
      ForEach(names, id: \.self) { n in
        let on = selected.contains(n)
        ChoiceChip(text: "#\(n)", selected: on) {
          selected = on ? selected.filter { $0 != n } : selected + [n]
        }
        .fixedSize()
        .accessibilityLabel("Kennzeichen \(n)")
      }
    }
    .padding(.horizontal, 2)
  }

  var body: some View {
    // Snapshots: ohne Scroll-Container, sonst bleibt die Zeile im Renderer leer.
    if snapshot { chips } else { ScrollView(.horizontal, showsIndicators: false) { chips } }
  }
}
