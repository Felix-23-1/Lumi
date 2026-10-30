// Bausteine der dritten Runde: Rückgängig-Leiste, Wiederholen-Menü, Suchfeld mit Treffern,
// Kurzzeit-Timer (Menü, eigene Minuten, laufende Timer). Logik dazu steht in ViewSupportLogic.swift.
import AppKit
import SwiftUI
import TabyCore

/// Leiste unten in Heute und Aufgaben, solange es eine rückgängig machbare Aktion gibt.
struct UndoBanner: View {
  /// Bezeichnung des neuesten Schritts.
  let label: String
  @EnvironmentObject private var model: AppModel
  @State private var busy = false
  @State private var error: String?

  /// Ältere Schritte (neueste zuerst ohne den ersten); „Rückgängig“ nimmt immer den obersten.
  private var older: [String] { Array((model.state?.undoLabels ?? []).dropFirst()) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.uturn.backward")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.secondary)
        Text(label)
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .lineLimit(1)
        if !older.isEmpty {
          Menu {
            Text("Rückgängig nimmt jeweils den obersten Schritt.")
            ForEach(Array(older.enumerated()), id: \.offset) { _, item in Text(item) }
          } label: {
            Text("+\(older.count)")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(Theme.secondary)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .accessibilityLabel("\(older.count) ältere Schritte")
        }
        Spacer(minLength: 4)
        Button("Rückgängig", action: undo)
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(busy)
          .accessibilityLabel("\(label) rückgängig machen")
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
  }

  private func undo() {
    busy = true
    error = nil
    Task {
      let r = await model.services.undoLast()
      // Nach Erfolg hat der Kern das Rückgängig-Etikett gelöscht; die Leiste verschwindet mit dem Neuladen.
      await model.refresh()
      busy = false
      error = r.errorMessage
    }
  }
}

/// Wiederholen-Menü: Nie / Täglich / Werktags / Wöchentlich / Monatlich.
struct RecurrenceMenu: View {
  @Binding var recurrence: TaskRecurrence?
  var showsTitle = false
  /// In Vorschauen (Snapshots) nur die Anzeige: das Menü zeichnet der Renderer als Platzhalter.
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if snapshot {
      label
    } else {
      Menu {
        option(nil)
        ForEach(TaskRecurrence.allCases, id: \.self) { option($0) }
      } label: {
        label
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Wiederholen")
      .accessibilityLabel("Wiederholen, \(ViewSupportLogic.recurrenceTitle(recurrence))")
    }
  }

  @ViewBuilder private var label: some View {
    if showsTitle {
      Label("Wiederholen: \(ViewSupportLogic.recurrenceTitle(recurrence))", systemImage: "arrow.triangle.2.circlepath")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(recurrence == nil ? Theme.secondary : Theme.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.capsule))
    } else {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(recurrence == nil ? Theme.secondary : Theme.blue)
        .frame(width: 22, height: 22)
        .background(Circle().fill(Theme.capsule))
    }
  }

  @ViewBuilder private func option(_ r: TaskRecurrence?) -> some View {
    Button { recurrence = r } label: {
      if recurrence == r {
        Label(ViewSupportLogic.recurrenceTitle(r), systemImage: "checkmark")
      } else {
        Text(ViewSupportLogic.recurrenceTitle(r))
      }
    }
  }
}

/// Suchfeld mit Treffern, gruppiert nach Art. Die Suche selbst (Verzögerung, Abfrage) macht die Ansicht, die sie zeigt.
struct SearchPanel: View {
  @Binding var query: String
  let hits: [SearchHit]
  /// Dateien (Spotlight, lokal). Zusammenfassen gibt es nur mit Apple Intelligence.
  let files: [FileHit]
  let appleOn: Bool
  /// Zusammenfassung oder Hinweis je Dateipfad, zeigt die Zeile darunter.
  let fileNotes: [String: String]
  let onSummarize: (FileHit) -> Void
  /// Treffer antippen: öffnet den Reiter des Treffers (Aufgabe, Notiz, Termin).
  let onOpen: (SearchHit) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      InputCapsule(placeholder: "Aufgaben, Notizen, Termine suchen…", text: $query) {
        Button(action: onClose) { Image(systemName: "xmark") }
          .buttonStyle(RoundIconButtonStyle(size: 22))
          .help("Suche schließen")
          .accessibilityLabel("Suche schließen")
      }
      CappedScroll(maxHeight: 260) {
        VStack(alignment: .leading, spacing: 6) {
          let groups = ViewSupportLogic.searchGroups(hits)
          if !query.trimmingCharacters(in: .whitespaces).isEmpty && groups.isEmpty && files.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "Keine Treffer")
          }
          ForEach(groups) { group in
            SectionHeader(symbol: symbol(group.kind), title: group.title, count: group.hits.count)
              .padding(.horizontal, 4)
              .padding(.top, 4)
            ForEach(group.hits) { hit in hitRow(hit) }
          }
          if !files.isEmpty {
            SectionHeader(symbol: "doc", title: "Dateien", count: files.count)
              .padding(.horizontal, 4)
              .padding(.top, 4)
            ForEach(files) { file in fileRow(file) }
          }
        }
      }
    }
  }

  private func fileRow(_ file: FileHit) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Button { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) } label: {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "doc")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .frame(width: 16)
          Text(file.name)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
          Spacer(minLength: 4)
          if let date = ViewSupportLogic.searchDate(file.modifiedAt) {
            Text(date)
              .font(.system(size: 11))
              .foregroundStyle(Theme.tertiary)
              .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Öffnen")
      .accessibilityLabel("\(file.name) öffnen")
      HStack(spacing: 12) {
        Button("Im Finder zeigen") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        }
        if appleOn {
          Button("Zusammenfassen") { onSummarize(file) }
        }
      }
      .buttonStyle(.plain)
      .font(.system(size: 11))
      .foregroundStyle(Theme.secondary)
      .padding(.leading, 24)
      if let note = fileNotes[file.path] {
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(Theme.text)
          .padding(.leading, 24)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  @ViewBuilder
  private func hitRow(_ hit: SearchHit) -> some View {
    if ViewSupportLogic.tab(for: hit.kind) != nil {
      Button { onOpen(hit) } label: { hitContent(hit) }
        .buttonStyle(.plain)
        .help("Öffnen")
    } else {
      hitContent(hit)
    }
  }

  private func hitContent(_ hit: SearchHit) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol(hit.kind))
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(hit.title)
          .font(.system(size: 13))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        if let snippet = hit.snippet, !snippet.isEmpty {
          Text(snippet)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let date = ViewSupportLogic.searchDate(hit.date) {
        Text(date)
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
  }

  private func symbol(_ kind: SearchHit.Kind) -> String {
    switch kind {
    case .task: "checkmark.circle"
    case .note: "note.text"
    case .event: "calendar"
    case .memory: "brain"
    }
  }
}

/// Timer-Knopf in der Kopfzeile: feste Minuten oder "Eigene…".
struct QuickTimerMenu: View {
  let onStart: (Int) -> Void
  let onCustom: () -> Void

  var body: some View {
    Menu {
      ForEach(ViewSupportLogic.timerPresets, id: \.self) { m in
        Button("\(m) Min") { onStart(m) }
          .accessibilityLabel("\(m) Minuten Timer starten")
      }
      Divider()
      Button("Eigene…", action: onCustom)
    } label: {
      Image(systemName: "timer")
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Theme.capsule))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Timer")
    .accessibilityLabel("Timer")
  }
}

/// Eigene Minuten (1 bis 720) per Eingabe; Enter oder der Knopf startet.
struct CustomTimerRow: View {
  let onStart: (Int) -> Void
  @State private var text = ""

  var body: some View {
    InputCapsule(placeholder: "Minuten, 1 bis 720", text: $text) {
      Button(action: start) { Image(systemName: "play.fill") }
        .buttonStyle(RoundIconButtonStyle(size: 26, filled: true))
        .disabled(ViewSupportLogic.customMinutes(text) == nil)
        .accessibilityLabel("Timer starten")
    }
    .onSubmit(start)
  }

  private func start() {
    guard let m = ViewSupportLogic.customMinutes(text) else { return }
    text = ""
    onStart(m)
  }
}

/// Laufende Kurzzeit-Timer mit Restzeit; Restzeit wird alle 15 Sekunden neu berechnet.
struct RunningTimersList: View {
  let timers: [TabyTimer]
  /// Injizierte Uhrzeit (Snapshots); sonst die Zeit des Zeitplans.
  let now: String?
  let onCancel: (String) -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      let current = now ?? LocalTime.format(context.date)
      VStack(alignment: .leading, spacing: 2) {
        SectionHeader(symbol: "timer", title: "Timer", count: timers.count)
          .padding(.horizontal, 4)
        ForEach(timers) { t in
          HStack(spacing: 8) {
            Image(systemName: "timer")
              .font(.system(size: 11))
              .foregroundStyle(Theme.amber)
            Text(t.label)
              .font(.system(size: 13))
              .foregroundStyle(Theme.text)
              .lineLimit(1)
            Spacer(minLength: 4)
            Text(ViewSupportLogic.remainingText(endsAt: t.endsAt, now: current))
              .font(.system(size: 12, weight: .medium, design: .rounded))
              .foregroundStyle(Theme.secondary)
              .monospacedDigit()
            Button { onCancel(t.id) } label: { Image(systemName: "xmark") }
              .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.red.opacity(0.8)))
              .help("Timer abbrechen")
              .accessibilityLabel("Timer \(t.label) abbrechen")
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
        }
      }
    }
  }
}

/// Geschätzte Dauer einer Aufgabe: Menü mit festen Stufen, nil = Standard-Fokuszeit.
struct DurationMenu: View {
  @Binding var minutes: Int?
  var showsTitle = false
  @Environment(\.tabySnapshot) private var snapshot
  static let steps = [15, 30, 45, 60, 90, 120]

  static func title(_ m: Int?) -> String {
    guard let m else { return "Keine Dauer" }
    return m % 60 == 0 ? "\(m / 60) Std" : (m > 60 ? "\(m / 60) Std \(m % 60) Min" : "\(m) Min")
  }

  var body: some View {
    if snapshot {
      label
    } else {
      Menu {
        Button(Self.title(nil)) { minutes = nil }
        ForEach(Self.steps, id: \.self) { m in Button(Self.title(m)) { minutes = m } }
      } label: { label }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dauer")
        .accessibilityLabel("Dauer, \(Self.title(minutes))")
    }
  }

  @ViewBuilder private var label: some View {
    if showsTitle || minutes != nil {
      Label(minutes.map { Self.title($0) } ?? "Dauer", systemImage: "hourglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(minutes == nil ? Theme.secondary : Theme.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    } else {
      Image(systemName: "hourglass").foregroundStyle(Theme.secondary)
    }
  }
}
