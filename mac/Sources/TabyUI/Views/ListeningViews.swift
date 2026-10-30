// Mitschrift in der Meeting-Karte: Einwilligung vor dem Start (Nur ich / Alle mit Häkchen und
// kopierbarem Ankündigungssatz) und die Aufgaben-Prüfung nach dem Termin (Sicher / Unklar).
import AppKit
import SwiftUI
import TabyCore

struct ListeningStartView: View {
  let meeting: MeetingBrief
  let onClose: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var mode: MeetingListenMode
  @State private var consent = false
  @State private var busy = false
  @State private var error: String?
  @State private var copied = false

  /// `initialMode`: Startauswahl (Snapshots/Prüfungen).
  init(meeting: MeetingBrief, initialMode: MeetingListenMode = .onlyMe, onClose: @escaping () -> Void) {
    self.meeting = meeting; self.onClose = onClose
    _mode = State(initialValue: initialMode)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header(symbol: "record.circle", title: "Mitschreiben: \(meeting.title)",
             subtitle: "Lokal, nur Text – es wird kein Ton gespeichert.")
      VStack(alignment: .leading, spacing: 6) {
        ForEach(MeetingListenMode.allCases, id: \.self) { m in modeRow(m) }
      }
      .tabyCard(padding: 10)
      if mode == .everyone {
        Text(ListeningLogic.allHint)
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(ListeningLogic.announcement)
          .font(.system(size: 12)).foregroundStyle(Theme.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .tabyCard(padding: 10)
        HStack(spacing: 8) {
          Button(copied ? "Kopiert" : "Satz kopieren") { copy() }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          Spacer(minLength: 0)
        }
        Toggle(ListeningLogic.consentLabel, isOn: $consent)
          .toggleStyle(.checkbox)
          .font(.system(size: 12))
          .foregroundStyle(Theme.text)
      }
      if let error {
        Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red)
      }
      HStack(spacing: 8) {
        Button("Abbrechen") { onClose() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        Button(mode == .onlyMe ? "Starten" : "Alle haben zugestimmt – starten") { start() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(!ListeningLogic.canStart(mode: mode, consent: consent))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(busy)
  }

  private func modeRow(_ m: MeetingListenMode) -> some View {
    let on = mode == m
    return Button {
      mode = m
    } label: {
      HStack(spacing: 8) {
        Image(systemName: on ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 12))
          .foregroundStyle(on ? Theme.amber : Theme.tertiary)
        Text(ListeningLogic.modeTitle(m))
          .font(.system(size: 12, weight: on ? .semibold : .regular))
          .foregroundStyle(Theme.text)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ListeningLogic.announcement, forType: .string)
    copied = true
  }

  private func start() {
    busy = true
    error = nil
    Task {
      let err = await ViewActions.startListening(model, meeting.id, mode: mode,
                                                 consentGiven: ListeningLogic.consentGiven(mode: mode, consent: consent))
      busy = false
      if let err { error = err } else { onClose() }
    }
  }

  private func header(symbol: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 17))
        .foregroundStyle(Theme.red)
        .frame(width: 36, height: 36)
        .background(Circle().fill(Theme.red.opacity(0.15)))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.text)
          .lineLimit(2)
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
  }
}

/// Nach dem Termin: Kandidaten in „Sicher“ (vorgewählt) und „Unklar – bitte entscheiden“.
struct ListeningReviewView: View {
  let meeting: MeetingBrief
  let onClose: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var items: [ActionCandidate]
  @State private var selected: Set<String>
  @State private var loaded: Bool
  @State private var busy = false
  @State private var error: String?
  @State private var doneText: String?

  /// `initialItems`: fertige Liste ohne Laden (Snapshots/Prüfungen).
  init(meeting: MeetingBrief, onClose: @escaping () -> Void, initialItems: [ActionCandidate]? = nil) {
    self.meeting = meeting; self.onClose = onClose
    _items = State(initialValue: initialItems ?? [])
    _selected = State(initialValue: ListeningLogic.preselected(initialItems ?? []))
    _loaded = State(initialValue: initialItems != nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Aufgaben aus „\(meeting.title)“")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Theme.text)
        .lineLimit(2)
      if !loaded {
        Text("Mitschrift wird geprüft …")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      } else if items.isEmpty {
        Text("Keine Aufgaben erkannt.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      } else {
        CappedScroll(maxHeight: 260) {
          VStack(alignment: .leading, spacing: 10) {
            group("Sicher", ListeningLogic.sure(items))
            group("Unklar – bitte entscheiden", ListeningLogic.unclear(items))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let doneText {
        Label(doneText, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.green)
      }
      if let error {
        Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red)
      }
      HStack(spacing: 8) {
        Button("Schließen") { onClose() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        if doneText == nil {
          Button(ListeningLogic.acceptLabel(acceptCount)) { accept() }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(acceptCount == 0)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(busy)
    .task { if !loaded { await load() } }
  }

  private var acceptCount: Int { ListeningLogic.chosen(items, selected).count }

  private func group(_ title: String, _ rows: [ActionCandidate]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if !rows.isEmpty {
        Text(title.uppercased())
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.tertiary)
        ForEach(rows) { c in row(c) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ c: ActionCandidate) -> some View {
    let on = selected.contains(c.id)
    let today = NowResolver.today(nowEnv)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        Button {
          selected = ListeningLogic.toggled(selected, c.id)
        } label: {
          Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 13))
            .foregroundStyle(on ? Theme.amber : Theme.tertiary)
        }
        .buttonStyle(.plain)
        TextField("Aufgabe", text: Binding(
          get: { c.text },
          set: { value in update(c.id) { $0.text = value } }))
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(Theme.text)
      }
      HStack(spacing: 10) {
        Menu {
          ForEach(ListeningLogic.ownerOptions(items), id: \.self) { option in
            Button(ListeningLogic.ownerLabel(option)) { update(c.id) { $0.owner = option } }
          }
        } label: {
          Label(ListeningLogic.ownerLabel(c.owner), systemImage: "person")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        if c.due != nil {
          DatePicker("", selection: Binding(
            get: { ListeningLogic.dueDate(c.due, today: today) },
            set: { value in update(c.id) { $0.due = ListeningLogic.dueString(value) } }),
                     displayedComponents: .date)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
          Button("Ohne Datum") { update(c.id) { $0.due = nil } }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        } else {
          Button("Datum setzen") { update(c.id) { $0.due = today } }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
        Spacer(minLength: 0)
      }
      Text("„\(c.evidence)“")
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.tertiary)
        .lineLimit(2)
    }
    .padding(.leading, 21)
  }

  private func update(_ id: String, _ change: (inout ActionCandidate) -> Void) {
    items = ListeningLogic.edit(items, id: id, change)
  }

  private func load() async {
    busy = true
    let r = await ViewActions.extractListenActions(model, meeting.id)
    busy = false
    items = r.items
    selected = ListeningLogic.preselected(r.items)
    error = r.error
    loaded = true
  }

  private func accept() {
    busy = true
    error = nil
    Task {
      let r = await ViewActions.acceptListenActions(model, meeting.id, ListeningLogic.chosen(items, selected))
      busy = false
      if let e = r.error { error = e } else { doneText = ListeningLogic.acceptedText(r.count) }
    }
  }
}
