// Reiter "Kalender": Agenda (heute / 7 Tage) aus allen aktiven Quellen,
// farbig je Quelle; Termin anlegen. Bei Konflikt wird nichts gespeichert,
// die Warnung nennt Titel und Zeit; erst "Trotzdem speichern" sendet mit
// allowConflict (Szenario A).
import SwiftUI
import TabyCore

struct CalendarView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv

  enum Range: Int, CaseIterable { case today = 1, week = 7 }
  enum DayChoice: Equatable { case today, tomorrow, custom }

  @State private var range: Range = .week
  @State private var events: [CalendarEvent]?
  @State private var showForm: Bool
  @State private var title = ""
  @State private var day: DayChoice = .today
  @State private var pickedDate = Date()
  @State private var pickedTime: Date
  @State private var duration: CalendarLogic.Duration = .h1
  @State private var outcome: ViewActions.EventOutcome?
  @State private var formError: String?
  @State private var saving = false
  @State private var refreshing = false

  init(state: AppState, showForm: Bool = false, outcome: ViewActions.EventOutcome? = nil, title: String = "") {
    self.state = state
    _showForm = State(initialValue: showForm || outcome != nil)
    _outcome = State(initialValue: outcome)
    _title = State(initialValue: title)
    var c = DateComponents()
    c.hour = 10; c.minute = 0
    _pickedTime = State(initialValue: LocalTime.calendar.date(from: c) ?? Date())
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var isConflict: Bool { if case .conflict = outcome { return true }; return false }
  private var today: String { LocalTime.datePart(now) }
  private var rangeEnd: String { GermanDate.addDays(today, range.rawValue) }

  private var shownEvents: [CalendarEvent] {
    let source = events ?? (state.overview.eventsToday + state.overview.eventsUpcoming)
    return source.filter { LocalTime.datePart($0.start) >= today && LocalTime.datePart($0.start) < rangeEnd }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Kalender") {
        HStack(spacing: 4) {
          ChoiceChip(text: "Heute", selected: range == .today) { range = .today }
          ChoiceChip(text: "7 Tage", selected: range == .week) { range = .week }
          Button { refresh() } label: {
            Image(systemName: "arrow.clockwise")
              .symbolEffect(.variableColor.iterative, isActive: refreshing)
          }
          .buttonStyle(RoundIconButtonStyle(size: 26))
          .disabled(refreshing)
          .help("Aktualisieren")
          .accessibilityLabel("Aktualisieren")
          Button {
            withAnimation(Theme.spring) { showForm.toggle(); if !showForm { outcome = nil } }
          } label: { Image(systemName: showForm ? "xmark" : "plus") }
            .buttonStyle(RoundIconButtonStyle(size: 26, filled: !showForm))
            .help(showForm ? "Schließen" : "Termin eintragen")
            .accessibilityLabel(showForm ? "Schließen" : "Termin eintragen")
        }
      }
      if showForm && !isConflict { form.transition(.move(edge: .top).combined(with: .opacity)) }
      outcomeView
      if let msg = CalendarLogic.unreachableMessage(state.overview.unreachableCalendarSources) {
        Banner(symbol: "wifi.exclamationmark", text: msg, tint: Theme.amber)
      }
      CappedScroll(maxHeight: showForm || outcome != nil ? 150 : 270) { agenda }
    }
    .animation(Theme.spring, value: showForm)
    .animation(Theme.spring, value: outcome)
    .animation(Theme.spring, value: range)
    .animation(Theme.spring, value: shownEvents)
    .task(id: range) { await reload() }
    .onChange(of: state.overview) { _, _ in Task { await reload() } }
  }

  private func reload() async {
    events = await model.services.listEvents(from: today, to: rangeEnd)
  }

  /// Holt alle Kalenderquellen neu und lädt danach die Agenda.
  private func refresh() {
    refreshing = true
    Task {
      await model.services.refreshCalendars()
      await reload()
      refreshing = false
    }
  }

  // MARK: Agenda

  @ViewBuilder private var agenda: some View {
    let days = CalendarLogic.agenda(shownEvents, today: today)
    VStack(alignment: .leading, spacing: 10) {
      if days.isEmpty {
        EmptyState(symbol: "calendar", title: range == .today ? "Heute keine Termine" : "Keine Termine in 7 Tagen",
                   subtitle: "Mit + trägst du einen ein.")
      }
      ForEach(days) { d in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(d.label).font(.system(size: 12, weight: .semibold))
              .foregroundStyle(d.date == today ? Theme.amber : Theme.secondary)
            if d.label == "Heute" || d.label == "Morgen" {
              Text(GermanDate.short(d.date)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
          }
          ForEach(d.events) { e in
            EventRow(event: e, sources: state.calendarSources, now: now, onDeleted: { await reload() })
          }
        }
        .transition(Theme.rowTransition)
      }
      if !state.calendarSources.isEmpty { legend }
    }
  }

  private var legend: some View {
    HStack(spacing: 10) {
      ForEach(Array(Set(state.calendarSources.filter(\.enabled).map(\.kind))).sorted { $0.rawValue < $1.rawValue },
              id: \.self) { k in
        HStack(spacing: 4) {
          Circle().fill(k.color).frame(width: 6, height: 6)
          Text(k.germanName).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
      }
      Spacer()
    }
    .padding(.top, 2)
  }

  // MARK: Formular

  private var form: some View {
    VStack(alignment: .leading, spacing: 8) {
      InputCapsule(placeholder: "Titel des Termins", text: $title)
        .onSubmit { save(allowConflict: false) }
      HStack(spacing: 6) {
        ChoiceChip(text: "Heute", selected: day == .today) { day = .today }
        ChoiceChip(text: "Morgen", selected: day == .tomorrow) { day = .tomorrow }
        if day == .custom {
          CompactDatePicker(date: $pickedDate)
        } else {
          ChoiceChip(text: "Datum…", symbol: "calendar", selected: false) { day = .custom }
        }
        Spacer(minLength: 0)
        if duration != .allDay {
          HStack(spacing: 4) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            CompactDatePicker(date: $pickedTime, time: true)
          }
          .transition(.opacity)
        }
      }
      HStack(spacing: 6) {
        ForEach(CalendarLogic.Duration.allCases) { d in
          ChoiceChip(text: d.label, selected: duration == d) { duration = d }
        }
        Spacer(minLength: 0)
        Button("Eintragen") { save(allowConflict: false) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let formError { Banner(symbol: "exclamationmark.circle.fill", text: formError, tint: Theme.red) }
    }
    .tabyCard(padding: 10)
  }

  private var dateValue: String {
    switch day {
    case .today: today
    case .tomorrow: GermanDate.addDays(today, 1)
    case .custom: LocalTime.formatDate(pickedDate)
    }
  }

  @ViewBuilder private var outcomeView: some View {
    switch outcome {
    case .conflict(let message, _, let tight):
      let tint = tight ? Theme.amber : Theme.red
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
          Text(tight ? "Knapp hintereinander" : "Konflikt – noch nicht gespeichert")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tight ? Theme.amber : Theme.text)
        }
        Text(message).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Abbrechen") { outcome = nil }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          Button("Trotzdem speichern") { save(allowConflict: true) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(saving)
          Spacer()
        }
      }
      .tabyCard(tint: tint)
      .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
    case .saved(let info, let unreachable):
      VStack(alignment: .leading, spacing: 6) {
        Banner(symbol: "checkmark.circle.fill", text: "Termin gespeichert.", tint: Theme.green)
        if let info { Banner(symbol: "info.circle.fill", text: info, tint: Theme.blue) }
        if let unreachable { Banner(symbol: "wifi.exclamationmark", text: unreachable, tint: Theme.amber) }
      }
      .transition(.opacity)
    case .failed(let msg):
      Banner(symbol: "exclamationmark.circle.fill", text: msg, tint: Theme.red)
    case nil:
      EmptyView()
    }
  }

  private func save(allowConflict: Bool) {
    formError = nil
    let event: NewEvent
    if allowConflict, case .conflict(_, let pending, _) = outcome {
      event = pending
    } else {
      switch CalendarLogic.makeEvent(title: title, date: dateValue, time: LocalTime.formatTime(pickedTime),
                                     duration: duration) {
      case .success(let e): event = e
      case .failure(let e):
        formError = e.message
        return
      }
    }
    saving = true
    Task {
      let r = await ViewActions.addEvent(model, event, allowConflict: allowConflict, today: today)
      saving = false
      withAnimation(Theme.spring) {
        outcome = r
        if case .saved(let info, let unreachable) = r {
          title = ""
          showForm = false
          if info == nil && unreachable == nil { outcome = .saved(info: nil, unreachable: nil) }
        }
      }
      await reload()
      if case .saved(nil, nil) = r {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if case .saved = outcome { withAnimation(Theme.spring) { outcome = nil } }
      }
    }
  }
}

extension CalendarSourceKind {
  /// Kurzname am Termin: verständlich, ohne die Datenwerte zu ändern.
  var chipLabel: String {
    switch self {
    case .local: "Nur in Lumi"
    case .ics: "Abo (nur lesbar)"
    default: germanName
    }
  }
}

struct EventRow: View {
  let event: CalendarEvent
  let sources: [CalendarSourceConfig]
  let now: String
  var onDeleted: () async -> Void = {}
  @EnvironmentObject private var model: AppModel
  @State private var hover = false
  @State private var confirmDelete = false
  @State private var deleting = false
  @State private var deleteError: String?

  var body: some View {
    let kind = CalendarLogic.kind(of: event.sourceId, sources: sources)
    let past = !event.allDay && (event.end ?? event.start) < now
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 3.5, height: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
          Text(CalendarLogic.timeRange(event)).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.secondary)
        }
        Spacer()
        if event.readOnly {
          Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            .help("Nur lesbar").accessibilityLabel("Nur lesbar")
        } else {
          // Dauerhaft gedämpft sichtbar, beim Überfahren voll.
          Button { confirmDelete = true } label: {
            if deleting { ProgressView().controlSize(.small).scaleEffect(0.6) }
            else { Image(systemName: "trash").font(.system(size: 11)) }
          }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.red.opacity(hover || deleting ? 1 : 0.5))
          .disabled(deleting)
          .help("Termin löschen")
          .accessibilityLabel("Termin löschen")
        }
        Chip(text: kind.chipLabel, tint: kind.color)
      }
      if let deleteError {
        Text(deleteError).font(.system(size: 10)).foregroundStyle(Theme.red).lineLimit(2)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(kind.color.opacity(hover ? 0.12 : 0.06)))
    .opacity(past ? 0.55 : 1)
    .onHover { h in withAnimation(Theme.snappy) { hover = h } }
    .confirmationDialog("Termin „\(event.title)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Löschen", role: .destructive) { delete() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Das entfernt den Termin aus dem Kalender. Das kann nicht rückgängig gemacht werden.")
    }
  }

  private func delete() {
    deleting = true
    deleteError = nil
    Task {
      let r = await model.services.deleteEvent(id: event.id, sourceId: event.sourceId)
      deleting = false
      if r.isOk { await onDeleted() } else { deleteError = r.errorMessage }
    }
  }
}
