// Meeting-Begleiter (Paket 4): vor dem Termin Vorbereitung mit Beitritts-Link,
// verknüpften Notizen und offenen Aufgaben, optional eine Termin-Notiz mit Agenda
// („Notizen mitnehmen“); nach dem Termin Stichpunkte, die als Notiz und (Zeilen mit
// „-“) als Aufgaben gespeichert werden, oder mit Termin-Notiz eine Zusammenfassung.
// Die Insel zeigt die Karte; `onSaved`/`onDone` steuert der Hüllen-Zustand.
import AppKit
import SwiftUI
import TabyCore

struct MeetingCardView: View {
  let meeting: MeetingBrief
  /// Rückmeldung nach dem Speichern (solange gesetzt, bleibt die Karte stehen).
  let saved: String?
  let onSaved: (String) -> Void
  /// Karte schließen (Schließen, Überspringen, Fertig).
  let onDone: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var notes = ""
  @State private var busy = false
  @State private var error: String?
  @State private var mailNote: String?
  @State private var mailError: String?
  @State private var showPrep: Bool
  @State private var more: Bool
  @State private var query = ""
  @State private var picked: MeetingPrepLogic.Selection
  @State private var prepError: String?
  /// Einwilligung zum Mitschreiben bzw. Aufgaben-Prüfung nach dem Termin sind offen.
  @State private var listenOpen = false
  @State private var reviewOpen = false
  /// Zählt die Änderungen an „Noch im Meeting“, damit die Karte neu zeichnet.
  @State private var liveTick = 0
  /// Ablage für „Noch im Meeting“ (in Prüfungen eine eigene Suite).
  private let defaults: UserDefaults

  /// `prepOpen`/`prepMore`: Auswahl gleich offen (Snapshots/Prüfungen).
  init(meeting: MeetingBrief, saved: String?, onSaved: @escaping (String) -> Void, onDone: @escaping () -> Void,
       prepOpen: Bool = false, prepMore: Bool = false, listenOpen: Bool = false, defaults: UserDefaults = .standard) {
    self.meeting = meeting; self.saved = saved; self.onSaved = onSaved; self.onDone = onDone; self.defaults = defaults
    _showPrep = State(initialValue: prepOpen)
    _listenOpen = State(initialValue: listenOpen)
    _more = State(initialValue: prepMore)
    _picked = State(initialValue: MeetingPrepLogic.preselected(meeting))
  }

  private var now: String { NowResolver.now(nowEnv) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch meeting.phase {
      case .upcoming: upcoming
      case .ended: ended
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(busy)
  }

  // MARK: Vorher

  private var upcoming: some View {
    VStack(alignment: .leading, spacing: 10) {
      header(symbol: "calendar.badge.clock", title: "Gleich: \(meeting.title)",
             subtitle: MeetingLogic.countdownLine(meeting, now: now))
      if listenOpen {
        ListeningStartView(meeting: meeting, onClose: { listenOpen = false })
      } else if meeting.prepNoteId != nil {
        prepOutline
      } else if showPrep {
        prepPicker
      } else if !meeting.notes.isEmpty || !meeting.tasks.isEmpty {
        MeetingOutlineView(sections: linkedOutline)
          .tabyCard(padding: 10)
      }
      HStack(spacing: 8) {
        if let link = meeting.link, URL(string: link) != nil {
          Button {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
          } label: {
            Label("Beitreten", systemImage: "video.fill")
          }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        Spacer(minLength: 0)
        if let l = model.state?.listening, l.meetingId == meeting.id {
          Label("Mitschrift läuft", systemImage: "record.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.red)
        } else if model.state?.listening == nil, !listenOpen {
          Button("Mitschreiben") { listenOpen = true }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        if let noteId = meeting.prepNoteId {
          Button("Termin-Notiz öffnen") { openNote(noteId) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        } else if !showPrep {
          Button("Notizen mitnehmen") { showPrep = true }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        Button("Schließen") { dismiss() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
    }
  }

  /// Auswahl für die Agenda: Vorschläge vorgewählt, „Weitere…“ zeigt alle Notizen und offenen Aufgaben.
  private var prepPicker: some View {
    let rows = pickerRows
    return VStack(alignment: .leading, spacing: 6) {
      if more {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          TextField("Notizen und Aufgaben durchsuchen", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
        }
        .tabyCard(padding: 8)
      }
      CappedScroll(maxHeight: 150) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(rows) { row in prepRow(row) }
          if rows.isEmpty {
            Text("Nichts gefunden.")
              .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .tabyCard(padding: 10)
      HStack(spacing: 8) {
        Button(more ? "Weniger" : "Weitere…") { more.toggle() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        Button("Abbrechen") { showPrep = false }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button("Agenda erstellen") { createAgenda() }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
      if let prepError {
        Banner(symbol: "exclamationmark.circle.fill", text: prepError, tint: Theme.red)
      }
    }
  }

  /// Mit Termin-Notiz: Agenda, offene Aufgaben und Mitschrift aus der Notiz, gegliedert.
  private var prepOutline: some View {
    Group {
      if let content = noteContent(meeting.prepNoteId) {
        MeetingOutlineView(sections: MeetingOutline.preparation(MeetingOutline.parse(content)))
          .tabyCard(padding: 10)
      } else {
        Text("Agenda und Mitschrift stehen in der Termin-Notiz.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
    }
  }

  /// Ohne Termin-Notiz: verknüpfte Notizen und offene Aufgaben des Termins.
  private var linkedOutline: [MeetingOutline.Section] {
    var out: [MeetingOutline.Section] = []
    if !meeting.notes.isEmpty {
      out.append(MeetingOutline.Section(heading: "Passende Notizen",
                                        subs: [MeetingOutline.Sub(heading: "", items: meeting.notes.map(\.title))]))
    }
    if !meeting.tasks.isEmpty {
      out.append(MeetingOutline.Section(heading: "Offene Aufgaben",
                                        subs: [MeetingOutline.Sub(heading: "", items: meeting.tasks.map(\.title))]))
    }
    return out
  }

  private func noteContent(_ id: String?) -> String? {
    guard let id else { return nil }
    return model.state?.notes.first { $0.id == id }?.content
  }

  private var isRunning: Bool {
    _ = liveTick
    return MeetingLive.isRunning(meeting.id, now: now, defaults: defaults)
  }

  private var pickerRows: [MeetingPrepLogic.Row] {
    MeetingPrepLogic.rows(meeting: meeting, notes: model.state?.notes ?? [], tasks: model.state?.tasks ?? [],
                          query: query, more: more)
  }

  private func prepRow(_ row: MeetingPrepLogic.Row) -> some View {
    let on = MeetingPrepLogic.isOn(picked, row)
    return Button {
      picked = MeetingPrepLogic.toggled(picked, row)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .font(.system(size: 12))
          .foregroundStyle(on ? Theme.amber : Theme.tertiary)
        Image(systemName: row.isTask ? "checklist" : "note.text")
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
          .frame(width: 14)
        Text(row.title)
          .font(.system(size: 12))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        ForEach(row.tags, id: \.self) { tag in
          Text("#\(tag)")
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Theme.amber.opacity(0.12)))
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Nachher

  private var ended: some View {
    VStack(alignment: .leading, spacing: 10) {
      if reviewOpen {
        ListeningReviewView(meeting: meeting, onClose: { reviewOpen = false })
      } else if isRunning {
        runningContent
      } else {
        endedContent
      }
    }
  }

  /// „Noch im Meeting“: die Karte bleibt in der Meeting-Phase. Beendet wird nur mit „Meeting beendet“
  /// oder wenn die gewählte Zeit abläuft; erst danach gibt es die Nachbereitung.
  private var runningContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      header(symbol: "record.circle", title: "Noch im Meeting: \(meeting.title)",
             subtitle: MeetingLive.line(meeting.id, defaults: defaults))
      if listenOpen {
        ListeningStartView(meeting: meeting, onClose: { listenOpen = false })
      }
      HStack(spacing: 6) {
        Text("Ende automatisch")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        ForEach(MeetingLive.durations, id: \.self) { m in
          Button("+\(m) Min") { stillIn(m) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
      }
      HStack(spacing: 8) {
        if let l = model.state?.listening, l.meetingId == meeting.id {
          Label("Mitschrift läuft", systemImage: "record.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.red)
        } else if model.state?.listening == nil, !listenOpen {
          Button("Mitschreiben") { listenOpen = true }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        Spacer(minLength: 0)
        Button("Meeting beendet") {
          MeetingLive.clear(meeting.id, defaults: defaults)
          liveTick += 1
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
    }
  }

  private func stillIn(_ minutes: Int?) {
    MeetingLive.start(meeting.id, now: now, minutes: minutes, defaults: defaults)
    liveTick += 1
  }

  private var endedContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      header(symbol: "pencil.and.list.clipboard", title: "Wie war „\(meeting.title)“?",
             subtitle: meeting.prepNoteId == nil ? "Ein paar Stichpunkte reichen."
               : "Mitschrift in der Termin-Notiz, dann zusammenfassen.")
      if saved == nil {
        HStack(spacing: 8) {
          Button("Noch im Meeting") { stillIn(nil) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          Spacer(minLength: 0)
        }
      }
      if let noteId = meeting.prepNoteId {
        preparedEnd(noteId)
      } else {
        notesEnd
      }
      followUpRow
      reviewRow
    }
  }

  /// Aufgaben aus der Mitschrift prüfen: Vorschläge abhaken, dann anlegen.
  private var reviewRow: some View {
    HStack(spacing: 8) {
      Button("Aufgaben prüfen") { reviewOpen = true }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      Spacer(minLength: 0)
    }
  }

  /// Mit Termin-Notiz: Zusammenfassung aus der Mitschrift erstellen (Aufgaben werden angelegt).
  private func preparedEnd(_ noteId: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let saved {
        Label(saved, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.green)
        if let content = noteContent(noteId), let summary = MeetingOutline.summary(in: content) {
          MeetingOutlineView(sections: [summary]).tabyCard(padding: 10)
        }
      }
      if let error {
        Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red)
      }
      HStack(spacing: 8) {
        if saved == nil {
          Button("Zusammenfassung erstellen") { summarize() }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        } else {
          Button("Fertig") { onDone() }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        Spacer(minLength: 0)
        Button("Notiz öffnen") { openNote(noteId) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
    }
  }

  /// Ohne Termin-Notiz: Stichpunkte als Notiz und Aufgaben speichern.
  private var notesEnd: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let saved {
        Label(saved, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.green)
        HStack(spacing: 8) {
          if ObsidianLogic.isConnected(model.state) {
            Button("Auch in Obsidian") {
              let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
              let title = ObsidianLogic.meetingNoteTitle(title: meeting.title, start: meeting.start)
              Task { await ObsidianActions.saveNote(model, title: title, content: text) }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          }
          Spacer(minLength: 0)
          Button("Fertig") { onDone() }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
      } else {
        TextArea(placeholder: "- Angebot schicken\n- Folie 3 anpassen", text: $notes, minHeight: 84)
        Text("Zeilen mit „-“ werden Aufgaben")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        if let error {
          Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red)
        }
        HStack(spacing: 8) {
          Button("Überspringen") { dismiss() }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          Spacer(minLength: 0)
          Button("Speichern") { save() }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .keyboardShortcut(.return, modifiers: [.command])
        }
      }
    }
  }

  /// Nachbereitung als Mail-Entwurf: öffnet nur, sendet nie.
  private var followUpRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button("Nachbereitung als Mail-Entwurf") { draftFollowUp() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Spacer(minLength: 0)
      }
      if let mailNote {
        Label(mailNote, systemImage: "envelope")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.green)
      }
      if let mailError {
        Banner(symbol: "exclamationmark.circle.fill", text: mailError, tint: Theme.red)
      }
    }
  }

  // MARK: Bausteine

  private func header(symbol: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 17))
        .foregroundStyle(Theme.amber)
        .frame(width: 36, height: 36)
        .background(Circle().fill(Theme.amber.opacity(0.15)))
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.text)
          .lineLimit(2)
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: Aktionen

  private func dismiss() {
    busy = true
    Task {
      await model.services.dismissMeeting(meeting.id)
      await model.refresh()
      busy = false
      onDone()
    }
  }

  /// Öffnet die Termin-Notiz im Reiter „Notizen“ im eigenen Fenster; die Karte bleibt stehen.
  private func openNote(_ id: String) {
    model.focusedNoteId = id
    model.onDetach?(.notes)
  }

  private func createAgenda() {
    let (noteIds, taskIds) = MeetingPrepLogic.chosen(pickerRows, picked)
    busy = true
    prepError = nil
    Task {
      prepError = await ViewActions.prepareMeeting(model, meeting.id, noteIds: noteIds, taskIds: taskIds)
      busy = false
      if prepError == nil { showPrep = false }
    }
  }

  private func summarize() {
    busy = true
    error = nil
    Task {
      let r = await ViewActions.summarizeMeeting(model, meeting.id)
      busy = false
      if let e = r.error {
        error = e
      } else {
        onSaved(MeetingPrepLogic.summaryText(taskCount: r.tasks))
      }
    }
  }

  private func draftFollowUp() {
    busy = true
    mailError = nil
    Task {
      let r = await model.services.draftMeetingFollowUp(eventId: meeting.id)
      busy = false
      if r.isOk {
        mailNote = "Entwurf in Apple Mail geöffnet. Gesendet wird nichts."
      } else {
        mailError = r.errorMessage
      }
    }
  }

  private func save() {
    let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      error = "Schreib zuerst ein paar Stichpunkte – oder überspring den Termin."
      return
    }
    busy = true
    error = nil
    Task {
      let result = await model.services.submitMeetingNotes(meeting.id, text: text)
      busy = false
      switch result {
      case .ok(let res):
        model.react(.celebrate)
        await model.refresh()
        onSaved(MeetingLogic.savedText(taskCount: res.tasks.count))
      case .failure(_, let e):
        error = e
        model.react(.failed(e))
      }
    }
  }
}
