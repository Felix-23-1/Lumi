// Reiter "Heute": Briefing, Verpasst, Warnungen, überfällige/heutige
// Aufgaben (abhakbar), Termine als Mini-Zeitleiste.
import AppKit
import SwiftUI
import TabyCore

struct TodayView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var completing: Set<String> = []
  /// Angetippte Aufgabe: zeigt „Fokus starten“ darunter.
  @State private var tappedTask: String?
  @State private var acknowledging = false
  /// Tag, an dem das Briefing als gelesen eingeklappt wurde (nur Bequemlichkeit, pro Mac).
  @AppStorage("taby.briefingReadDay") private var briefingReadDay = ""
  @State private var briefingOpen = false
  @State private var searching = false
  /// Tagesplan-Ansicht im Reiter (ersetzt die Liste, wie die Suche).
  @State private var planOpen: Bool

  /// `startsWithPlan` und `whatNow` nur für Snapshots: Tagesplan offen, „Was jetzt?“-Karte gezeigt.
  private let whatNowPick: WhatNowPick?
  init(state: AppState, startsWithPlan: Bool = false, whatNow: WhatNowPick? = nil) {
    self.state = state
    whatNowPick = whatNow
    _planOpen = State(initialValue: startsWithPlan)
  }
  @State private var query = ""
  @State private var hits: [SearchHit] = []
  @State private var files: [FileHit] = []
  @State private var fileNotes: [String: String] = [:]
  @State private var customTimerOpen = false
  @State private var reading = false
  @AppStorage("taby.today.tasksOpen") private var tasksOpen = false
  @AppStorage("taby.today.eventsOpen") private var eventsOpen = true
  @Environment(\.tabySnapshot) private var snapshot
  @State private var error: String?

  private var overview: Overview { state.overview }
  private var now: String { NowResolver.now(nowEnv) }
  private var today: String { LocalTime.datePart(now) }
  private var appleOn: Bool {
    FileSearch.appleActive(model: state.settings.llmModel, available: state.appleIntelligenceAvailable)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: TodayLogic.greeting(now: now), subtitle: GermanDate.short(today)) {
        let level = UsageLogic.level(state.usage)
        if let text = UsageLogic.chipText(level) {
          Chip(text: text, symbol: level == .reached ? "pause.circle.fill" : "exclamationmark.triangle.fill",
               tint: level == .reached ? Theme.red : Theme.amber)
        }
        Button { withAnimation(Theme.spring) { searching.toggle() } } label: {
          Image(systemName: "magnifyingglass").font(.system(size: 11))
        }
        .buttonStyle(RoundIconButtonStyle(size: 24, filled: searching))
        .help("Suchen in Aufgaben, Notizen und Terminen")
        .accessibilityLabel("Suchen")
        Group {
          if snapshot {
            // Vorschau: das Menü rendert dort mit Verbotssymbol; ein schlichtes Symbol genügt.
            Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 28, height: 28)
          } else {
            moreMenu
          }
        }
        // Der Takt unten holt das Ende der Ansage ab.
        .task(id: reading) {
          guard reading else { return }
          try? await Task.sleep(nanoseconds: 800_000_000)
          while !Task.isCancelled {
            await model.refresh()
            if model.state?.speaking != true { reading = false; break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
          }
        }
      }
      // Beschriftete Auswahl statt Symbol: „Heute“ (Liste) oder „Tagesplan“.
      HStack(spacing: 6) {
        ChoiceChip(text: "Heute", selected: !planOpen) { withAnimation(Theme.spring) { planOpen = false } }
        ChoiceChip(text: plannedCount > 0 ? "Tagesplan · \(plannedCount)" : "Tagesplan", symbol: planSymbol,
                   selected: planOpen) { withAnimation(Theme.spring) { planOpen = true } }
        nowPlayingRow(state.nowPlaying)
      }
      nowPlayingCaption(state.nowPlaying)
      if planOpen {
        planView
      } else if searching {
        SearchPanel(query: $query, hits: hits, files: files, appleOn: appleOn, fileNotes: fileNotes,
                    onSummarize: summarize, onOpen: openHit, onClose: closeSearch)
          .task(id: query) { await runSearch() }
      } else {
        CappedScroll(maxHeight: 280) {
          VStack(alignment: .leading, spacing: 14) {
            if customTimerOpen { CustomTimerRow(onStart: startTimer).transition(Theme.rowTransition) }
            if !state.timers.isEmpty {
              RunningTimersList(timers: state.timers, now: nowEnv, onCancel: cancelTimer)
            }
            if !state.pendingConfirmations.isEmpty { ConfirmationCards(pending: state.pendingConfirmations) }
            FocusCard(state: state, pick: whatNowPick)
            if !state.weeklyGoals.isEmpty { WeeklyGoalsCard(goals: state.weeklyGoals) }
            briefingCard
            ForEach(state.birthdaysToday) { BirthdayRow(card: $0) }
            if !overview.missed.isEmpty { missedCard.transition(Theme.rowTransition) }
            let chatInbox = ViewSupportLogic.hiddenMessagesInbox(settings: state.settings, inbox: state.inbox)
            if !chatInbox.isEmpty { inboxSection(chatInbox) }
            if !overview.conflicts.isEmpty {
              Banner(symbol: "exclamationmark.triangle.fill",
                     text: "Überschneidet sich mit " + overview.conflicts.map { CalendarLogic.describe($0.with, today: today) }
                       .joined(separator: ", "),
                     tint: Theme.red)
            }
            if let msg = CalendarLogic.unreachableMessage(overview.unreachableCalendarSources) {
              Banner(symbol: "wifi.exclamationmark", text: "Kalender " + msg.prefix(1).lowercased() + msg.dropFirst(),
                     tint: Theme.amber)
            }
            MeetingEntrySection(events: overview.eventsToday, now: now)
            if TodayLogic.isEmpty(overview) {
              VStack(spacing: 10) {
                EmptyState(symbol: "sun.max", title: "Alles frei für heute",
                           subtitle: "Keine Aufgaben oder Termine offen. Genieß den Tag!")
                Text("Tipp: Leg eine Aufgabe an, dann plant Lumi sie in freie Zeiten. Oder frag Lumi einfach.")
                  .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                  .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                  Button("Aufgabe anlegen") {
                    TasksView.focusInputOnAppear = true
                    model.onOpenTab?(.tasks)
                  }
                  .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                  Button("Lumi fragen") { model.onOpenTab?(.chat) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
              }
            } else {
              tasksSection
              eventsSection
            }
          }
          .animation(Theme.spring, value: overview)
        }
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if let label = model.undoBannerLabel, ViewSupportLogic.undoVisible(label) {
        UndoBanner(label: label).transition(.opacity)
      }
    }
  }

  // MARK: Kopfzeilen-Menü

  /// Timer, Vorlesen, Pause und Fokus-Statistik: selten gebraucht, darum hinter „…“.
  private var moreMenu: some View {
    let speaking = reading || state.speaking
    return Menu {
      ForEach(TodayLayoutLogic.menuEntries(focusMinutesToday: state.focusMinutesToday), id: \.self) { entry in
        switch entry {
        case .timer:
          Menu("Timer") {
            ForEach(ViewSupportLogic.timerPresets, id: \.self) { m in
              Button("\(m) Min") { startTimer(m) }.accessibilityLabel("\(m) Minuten Timer starten")
            }
            Divider()
            Button("Eigene Dauer…") { withAnimation(Theme.spring) { customTimerOpen.toggle() } }
          }
        case .readAloud:
          Button(TodayLayoutLogic.readAloudTitle(speaking: speaking), action: toggleReading)
        case .pause:
          Menu("Pause machen") {
            ForEach(PauseMenu.steps, id: \.self) { m in
              Button("\(m) Min") {
                Task { _ = await model.services.startBreak(minutes: m); await model.refresh() }
              }
            }
          }
        case .focusStats:
          if let line = FocusLogic.todayLine(state.focusMinutesToday) { Text(line) }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(speaking ? "Mehr: Timer, Vorlesen beenden, Pause" : "Mehr: Timer, Vorlesen, Pause")
    .accessibilityLabel("Mehr")
  }

  /// Während Lumi spricht, wird der Eintrag zum Stopp.
  private func toggleReading() {
    Task {
      if reading || state.speaking {
        await model.services.stopSpeaking()
        reading = false
      } else {
        reading = true
        await model.services.speakOverview()
      }
      await model.refresh()
    }
  }

  // MARK: Tagesplan

  /// Fällt das Symbol auf älteren Systemen aus, nimmt es das Ersatzsymbol.
  private var planSymbol: String {
    NSImage(systemSymbolName: "calendar.day.timeline.left", accessibilityDescription: nil) != nil
      ? "calendar.day.timeline.left" : "list.bullet.rectangle"
  }

  private var plannedCount: Int { state.plan?.blocks.count ?? 0 }

  /// Geplante Uhrzeit je Aufgabe (erster Block gewinnt).
  private var plannedStarts: [String: String] {
    var starts: [String: String] = [:]
    for b in state.plan?.blocks ?? [] where starts[b.taskId] == nil {
      starts[b.taskId] = GermanDate.time(b.start)
    }
    return starts
  }

  private var planView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button { withAnimation(Theme.spring) { planOpen = false } } label: {
          Image(systemName: "chevron.left").font(.system(size: 11))
        }
        .buttonStyle(RoundIconButtonStyle(size: 24))
        .help("Zurück zu Heute")
        .accessibilityLabel("Zurück zu Heute")
        Text("Tagesplan").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
        Spacer(minLength: 0)
      }
      CappedScroll(maxHeight: 316) {
        PlanSection(state: state)
      }
    }
  }

  // MARK: Suche und Timer

  private func runSearch() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { hits = []; files = []; return }
    // Verzögerung: tippt man weiter, wird diese Aufgabe abgebrochen und nicht gesucht.
    try? await Task.sleep(nanoseconds: ViewSupportLogic.debounceNanos)
    guard !Task.isCancelled else { return }
    hits = await model.services.search(q)
    guard !Task.isCancelled else { return }
    files = await model.services.findFiles(q)
  }

  private func summarize(_ file: FileHit) {
    fileNotes[file.path] = "Fasst zusammen…"
    Task {
      let r = await model.services.summarizeFile(file.path)
      fileNotes[file.path] = r.value ?? r.errorMessage ?? "Zusammenfassung nicht möglich."
    }
  }

  private func closeSearch() {
    withAnimation(Theme.spring) { searching = false }
    query = ""
    hits = []
    files = []
    fileNotes = [:]
  }

  /// Suchtreffer öffnet seinen Reiter in der Notch und schließt die Suche.
  private func openHit(_ hit: SearchHit) {
    // Vault-Treffer: die Markdown-Datei in der Standard-App öffnen (id trägt den Pfad).
    if hit.id.hasPrefix(CoreServices.vaultHitPrefix) {
      closeSearch()
      NSWorkspace.shared.open(URL(fileURLWithPath: String(hit.id.dropFirst(CoreServices.vaultHitPrefix.count))))
      return
    }
    // Mail- und Chat-Treffer kommen als Notiz-Art mit Präfix (Vertrag kennt keine eigene Art).
    let tab: TabyTab? = hit.title.hasPrefix("Mail: ") ? .mail
      : hit.title.hasPrefix("Chat: ") ? .messages : ViewSupportLogic.tab(for: hit.kind)
    guard let tab else { return }
    closeSearch()
    // Direkt zur Aufgabe bzw. Notiz springen, nicht nur den Reiter öffnen.
    if tab == .tasks { model.focusedTaskId = hit.id }
    if tab == .notes { model.focusedNoteId = hit.id }
    model.onOpenTab?(tab)
  }

  /// Chat-Eingang kompakt, wenn der Reiter „Nachrichten“ ausgeblendet ist.
  private func inboxSection(_ items: [InboxItem]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      SectionHeader(symbol: "tray", title: "Eingang", count: items.count)
      ForEach(items) { item in
        HStack(spacing: 8) {
          Image(systemName: item.kind == .needsReply ? "arrowshape.turn.up.left.fill" : "clock")
            .font(.system(size: 11))
            .foregroundStyle(item.kind == .needsReply ? Theme.blue : Theme.tertiary)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(item.from) · \(item.channel)").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
          }
          Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func startTimer(_ minutes: Int) {
    customTimerOpen = false
    error = nil
    Task {
      let r = await model.services.startTimer(minutes: minutes, label: ViewSupportLogic.timerLabel)
      await model.refresh()
      error = r.errorMessage
    }
  }

  private func cancelTimer(_ id: String) {
    Task {
      await model.services.cancelTimer(id)
      await model.refresh()
    }
  }

  // MARK: Musik

  /// Läuft nichts Erkanntes, bleibt in der Chip-Zeile nur ein Knopf an die Mediatasten des Systems (z. B. YouTube im Browser).
  @ViewBuilder private func nowPlayingRow(_ np: NowPlaying?) -> some View {
    if np == nil {
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        mediaButton("playpause.fill", "Abspielen/Pause", .playPause)
      }
      .frame(height: 24)
      .task { await model.services.musicRefreshNowPlaying() }
    } else {
      Color.clear.frame(width: 0, height: 24).task { await model.services.musicRefreshNowPlaying() }
    }
  }

  /// Solange etwas läuft: eine schmale Zeile mit Titel, Pause und Weiter; Tipp auf den Titel öffnet den Musik-Reiter.
  @ViewBuilder private func nowPlayingCaption(_ np: NowPlaying?) -> some View {
    if let np {
      HStack(spacing: 6) {
        Button { model.onOpenTab?(.music) } label: {
          HStack(spacing: 6) {
            Image(systemName: np.playing ? "music.note" : "pause.fill").font(.system(size: 10, weight: .semibold))
            Text(np.artist.isEmpty ? np.title : "\(np.title) – \(np.artist)").lineLimit(1)
            Spacer(minLength: 0)
          }
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Musik öffnen")
        mediaButton(np.playing ? "pause.fill" : "play.fill", np.playing ? "Pause" : "Abspielen", .playPause)
        mediaButton("forward.fill", "Weiter", .next)
      }
      .padding(.horizontal, 4)
    }
  }

  private func mediaButton(_ symbol: String, _ label: String, _ command: MediaCommand) -> some View {
    Button {
      Task {
        let r = await model.services.mediaControl(command)
        error = r.errorMessage
        await model.refresh()
      }
    } label: { Image(systemName: symbol).font(.system(size: 10)) }
      .buttonStyle(RoundIconButtonStyle(size: 18))
      .help(label)
      .accessibilityLabel(label)
  }

  // MARK: Briefing

  /// Kompakt und ohne Rahmen: drei Zeilen, Tipp auf den Text klappt auf, Haken = gelesen (dann eine Zeile).
  private var briefingCard: some View {
    let text = model.briefing?.text ?? TodayLogic.fallbackBriefing(overview)
    let read = briefingReadDay == today
    let limit = TodayLayoutLogic.briefingLineLimit(readToday: read, expanded: briefingOpen)
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: model.briefing?.generatedByModel == true ? "sparkles" : "text.alignleft")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.amber)
        .frame(width: 20, height: 24)
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(read && !briefingOpen ? Theme.secondary : Theme.text)
        .lineSpacing(2)
        .lineLimit(limit)
        .fixedSize(horizontal: false, vertical: limit == nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.spring) { briefingOpen.toggle() } }
        .help(briefingOpen ? "Einklappen" : "Ganz lesen")
      Button {
        withAnimation(Theme.spring) {
          if read { briefingReadDay = ""; briefingOpen = true } else { briefingReadDay = today; briefingOpen = false }
        }
      } label: { Image(systemName: read ? "chevron.down" : "checkmark") }
        .buttonStyle(RoundIconButtonStyle(size: 24, tint: Theme.secondary))
        .help(read ? "Briefing wieder anzeigen" : "Gelesen")
        .accessibilityLabel(read ? "Briefing wieder anzeigen" : "Gelesen")
    }
    .padding(.horizontal, 4)
  }

  // MARK: Verpasst

  private var missedCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        StatusDot(color: Theme.amber)
        Text("Verpasst").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
        Text("während der Mac aus war").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        Spacer()
        Button {
          acknowledging = true
          Task {
            await ViewActions.acknowledgeMissed(model, ids: overview.missed.map(\.id))
            acknowledging = false
          }
        } label: {
          Label("Gesehen", systemImage: "checkmark")
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        .disabled(acknowledging)
      }
      ForEach(overview.missed) { r in
        HStack(spacing: 8) {
          Image(systemName: icon(for: r.reminder.source)).font(.system(size: 11)).foregroundStyle(Theme.amber)
          Text(r.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
          Spacer()
          Text(GermanDate.time(r.reminder.dueAt) ?? GermanDate.short(r.reminder.dueAt))
            .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.tertiary)
        }
      }
    }
    .tabyCard()
  }

  private func icon(for s: ReminderSource) -> String {
    switch s {
    case .task: "checkmark.circle"
    case .event: "calendar"
    case .job: "clock.arrow.circlepath"
    }
  }

  // MARK: Aufgaben

  @ViewBuilder private var tasksSection: some View {
    let tasks = overview.overdueTasks + overview.todayTasks
    if !tasks.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        collapsibleHeader(symbol: "checklist", title: "Aufgaben", count: tasks.count,
                          tint: overview.overdueTasks.isEmpty ? Theme.secondary : Theme.red, open: $tasksOpen)
        if tasksOpen {
          let known = TagLogic.allTags(tasks: state.tasks, notes: state.notes).map(\.name)
          ForEach(tasks) { t in
            // Dieselbe Zeile wie im Reiter „Aufgaben“: aufklappen (Stand, Dauer, Kennzeichen, Notizen),
            // Stift = neu planen (Fälligkeit, Wiederholung), Play = Fokus, Stern, Papierkorb.
            TaskRow(task: t, now: now, completing: completing.contains(t.id), onToggle: { complete(t) },
                    notes: state.notes, categories: state.settings.taskCategories,
                    notionCategories: state.notionTaskCategories, onAssigned: { _ in },
                    knownTags: known, plannedTime: plannedStarts[t.id])
              .transition(Theme.rowTransition)
          }
        }
      }
    }
  }

  /// Abschnittskopf, der den Abschnitt ein- und ausklappt; die Wahl bleibt gespeichert.
  private func collapsibleHeader(symbol: String, title: String, count: Int, tint: Color, open: Binding<Bool>) -> some View {
    Button { withAnimation(Theme.spring) { open.wrappedValue.toggle() } } label: {
      HStack(spacing: 6) {
        SectionHeader(symbol: symbol, title: title, count: count, tint: tint)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.tertiary)
          .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
      }
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(open.wrappedValue ? "\(title) einklappen" : "\(title) ausklappen")
    .accessibilityLabel("\(title), \(open.wrappedValue ? "ausgeklappt" : "eingeklappt")")
  }

  private func complete(_ t: TabyTask) {
    withAnimation(Theme.pop) { _ = completing.insert(t.id) }
    Task {
      try? await Task.sleep(nanoseconds: 380_000_000)
      error = await ViewActions.setTaskDone(model, id: t.id, done: true)
      completing.remove(t.id)
    }
  }

  // MARK: Termine

  @ViewBuilder private var eventsSection: some View {
    if !overview.eventsToday.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        collapsibleHeader(symbol: "calendar", title: "Termine", count: overview.eventsToday.count,
                          tint: Theme.secondary, open: $eventsOpen)
        if eventsOpen {
          TimelineList(events: CalendarLogic.agenda(overview.eventsToday, today: today).flatMap(\.events),
                       sources: state.calendarSources, now: now)
            .padding(.horizontal, 8)
        }
      }
    }
  }
}

/// Fälligkeits-Chip in Farbe der Dringlichkeit.
struct DueChipView: View {
  let info: DueChipInfo
  var body: some View {
    switch info.kind {
    case .overdue: Chip(text: info.label, symbol: "exclamationmark", tint: Theme.red)
    case .today: Chip(text: info.label, symbol: "clock", tint: Theme.amber)
    case .soon: Chip(text: info.label, tint: Theme.blue)
    case .later: Chip(text: info.label, tint: Theme.secondary)
    }
  }
}

/// Senkrechte Mini-Zeitleiste: Uhrzeit, farbiger Punkt je Quelle, Titel.
struct TimelineList: View {
  let events: [CalendarEvent]
  let sources: [CalendarSourceConfig]
  let now: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(events.enumerated()), id: \.element.id) { idx, e in
        let kind = CalendarLogic.kind(of: e.sourceId, sources: sources)
        let past = (e.end ?? e.start) < now && !e.allDay
        HStack(alignment: .top, spacing: 10) {
          Text(e.allDay ? "ganzt." : (GermanDate.time(e.start) ?? ""))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(past ? Theme.tertiary : Theme.secondary)
            .frame(width: 40, alignment: .trailing)
          VStack(spacing: 0) {
            Circle().fill(kind.color).frame(width: 9, height: 9)
              .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
              .padding(.top, 3)
            if idx < events.count - 1 {
              Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1.5).frame(minHeight: 22)
            }
          }
          VStack(alignment: .leading, spacing: 1) {
            Text(e.title).font(.system(size: 13, weight: .medium))
              .foregroundStyle(past ? Theme.secondary : Theme.text).lineLimit(1)
            Text("\(CalendarLogic.timeRange(e)) · \(kind.chipLabel)")
              .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
          }
          .padding(.bottom, idx < events.count - 1 ? 6 : 0)
          Spacer(minLength: 0)
        }
        .opacity(past ? 0.7 : 1)
      }
    }
  }
}

/// Einfacher Umbruch-Layout (Kapseln in Zeilen).
struct WrapLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 400
    var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
    for s in subviews {
      let sz = s.sizeThatFits(.unspecified)
      if x > 0 && x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
      x += sz.width + spacing
      maxX = max(maxX, x - spacing)
      rowH = max(rowH, sz.height)
    }
    return CGSize(width: proposal.width ?? maxX, height: y + rowH)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
    for s in subviews {
      let sz = s.sizeThatFits(.unspecified)
      if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
      x += sz.width + spacing
      rowH = max(rowH, sz.height)
    }
  }
}
