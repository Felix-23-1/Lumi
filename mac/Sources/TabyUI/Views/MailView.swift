// Reiter "Mail" (Apple Mail): Posteingang mit Filter, Aufklappen (Text,
// Aufgabe, Markieren, Archivieren, Papierkorb) und Antwortentwurf. Gesendet
// wird nur nach dem Klick auf „Senden“ in der Vorschau. Mail-Inhalte werden
// nicht gespeichert; nur die Liste liegt im Speicher.
import AppKit
import SwiftUI
import TabyCore

/// Vorbelegung für Snapshots und Prüfungen (ohne Kern).
struct MailPreview {
  var expandedId: String?
  var body: String?
  var draft: MailDraft?
  var filter: MailFilter?
  /// Karte „Daraus Aufgabe“ offen (Snapshots), mit Vorbelegung und Kategorien.
  var taskDraft: MailMessage?
  var taskSeed = TaskCardSeed()
  var categories: [TaskCategoryDef]?
}

/// Zustand des Antwort-Entwurfs unter einer Mail.
struct MailComposeState: Equatable {
  var replyId: String
  var instruction = ""
  var drafting = false
  var error: String?
  var hasDraft = false
  /// Editierbare Vorschau (Empfänger kommagetrennt).
  var to = ""
  var subject = ""
  var body = ""
}

struct MailView: View {
  let mail: MailOverview?
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var local: MailOverview?
  @State private var filter: MailFilter
  @State private var expandedId: String?
  @State private var bodies: [String: String] = [:]
  @State private var bodyErrors: [String: String] = [:]
  @State private var composer: MailComposeState?
  @State private var loading = false
  @State private var error: String?
  @State private var note: String?
  /// Mail, für die die Karte „Daraus Aufgabe“ offen ist; eine zweite Mail ersetzt sie.
  @State private var taskDraft: MailMessage?
  private let cardSeed: TaskCardSeed
  private let categoriesOverride: [TaskCategoryDef]?

  init(mail: MailOverview?, preview: MailPreview = MailPreview()) {
    self.mail = mail
    _local = State(initialValue: mail)
    _filter = State(initialValue: preview.filter ?? MailLogic.defaultFilter(mail?.messages ?? []))
    _expandedId = State(initialValue: preview.expandedId)
    _taskDraft = State(initialValue: preview.taskDraft)
    cardSeed = preview.taskSeed
    categoriesOverride = preview.categories
    if let id = preview.expandedId, let text = preview.body {
      _bodies = State(initialValue: [id: text])
    }
    if let d = preview.draft, let id = preview.expandedId {
      _composer = State(initialValue: MailComposeState(
        replyId: id, hasDraft: true, to: d.to.joined(separator: ", "), subject: d.subject, body: d.body))
    }
  }

  private var now: String { NowResolver.now(nowEnv) }
  private var nowDate: Date { LocalTime.parse(now) ?? Date() }
  private var categories: [TaskCategoryDef] {
    categoriesOverride ?? model.state?.settings.taskCategories ?? TaskCategoryDef.builtIn
  }

  var body: some View {
    Group {
      if let overview = local {
        if let text = overview.error {
          failureView(text, denied: overview.accessDenied)
        } else {
          inbox(overview)
        }
      } else {
        offView
      }
    }
    .animation(Theme.spring, value: local)
    .animation(Theme.spring, value: expandedId)
    .animation(Theme.spring, value: composer)
    .onChange(of: mail) { _, m in local = m }
  }

  // MARK: Mail aus

  private var offView: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Mail")
      VStack(spacing: 8) {
        Image(systemName: "envelope")
          .font(.system(size: 26))
          .foregroundStyle(Theme.tertiary)
        Text("Mail ist aus")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Theme.secondary)
        Text("Lumi liest nur Betreff und Absender aus Apple Mail. Nur lokal: Einstellungen → Datenschutz.")
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button(action: enable) { Label("Mail einschalten", systemImage: "envelope.badge") }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .padding(.top, 4)
      }
      .frame(maxWidth: .infinity)
      .tabyCard(padding: 16)
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
    }
  }

  // MARK: Fehler

  private func failureView(_ text: String, denied: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Mail") { refreshButton }
      Banner(symbol: denied ? "lock.fill" : "exclamationmark.triangle.fill", text: text, tint: Theme.red)
      if denied {
        Text("Systemeinstellungen → Datenschutz & Sicherheit → Automation → Lumi → Mail anhaken.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(action: openPrivacySettings) {
          Label("Systemeinstellungen öffnen", systemImage: "gearshape")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
    }
  }

  // MARK: Posteingang

  /// Während einer Antwort ersetzt die Antwortseite die Liste (sie bleibt vollständig sichtbar).
  @ViewBuilder
  private func inbox(_ overview: MailOverview) -> some View {
    if let c = composer, let target = overview.messages.first(where: { $0.id == c.replyId }) {
      composePage(c, target)
    } else {
      listPage(overview)
    }
  }

  private func listPage(_ overview: MailOverview) -> some View {
    let messages = overview.messages
    let shown = MailLogic.filter(messages, filter)
    let unread = MailLogic.unreadCount(messages)
    return VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Mail") {
        if unread > 0 {
          Chip(text: "\(unread) ungelesen", tint: Theme.blue)
            .contentTransition(.numericText())
        }
        refreshButton
      }
      filterRow
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      if let note { Banner(symbol: "checkmark.circle.fill", text: note, tint: Theme.green) }
      // Mit offener Karte wird die Liste kürzer, damit alles in die 380 pt der Insel passt.
      CappedScroll(maxHeight: taskDraft == nil ? 280 : 60) {
        VStack(alignment: .leading, spacing: 2) {
          if shown.isEmpty {
            EmptyState(symbol: "tray", title: messages.isEmpty ? "Keine Mails in den letzten 7 Tagen" : "Hier ist nichts",
                       subtitle: messages.isEmpty ? nil : "Andere Filter zeigen mehr.")
          }
          ForEach(shown) { m in
            VStack(alignment: .leading, spacing: 0) {
              MailRow(message: m, time: MailLogic.relativeTime(m.date, now: now), expanded: expandedId == m.id) {
                toggle(m)
              }
              if expandedId == m.id {
                detail(m)
                  .transition(.opacity.combined(with: .move(edge: .top)))
              }
            }
            .transition(Theme.rowTransition)
          }
        }
      }
      if let m = taskDraft { taskCard(m) }
    }
  }

  private func taskCard(_ m: MailMessage) -> some View {
    let t = TaskFromMessage.mail(m)
    return TaskFromMessageCard(title: t.title, notes: t.notes, categories: categories, seed: cardSeed, now: now,
                               onCreated: { title in
                                 withAnimation(Theme.spring) { taskDraft = nil }
                                 note = "Aufgabe angelegt: \(title)"
                               },
                               onCancel: { withAnimation(Theme.spring) { taskDraft = nil } })
      .id(m.id)
      .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private var refreshButton: some View {
    Button(action: refresh) {
      Image(systemName: "arrow.clockwise")
        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: loading)
    }
    .buttonStyle(RoundIconButtonStyle(size: 26))
    .help("Posteingang neu abrufen")
    .accessibilityLabel("Aktualisieren")
  }

  private var filterRow: some View {
    HStack(spacing: 6) {
      ForEach(MailFilter.allCases) { f in
        ChoiceChip(text: f.title, selected: filter == f) {
          withAnimation(Theme.spring) { filter = f }
        }
        .help(f == .important ? "Wichtig = markiert, Antworten, Rechnungs- oder Fristwörter im Betreff oder Absender mit Vor- und Nachname" : f.title)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 2)
  }

  // MARK: Aufgeklappte Mail

  private func detail(_ m: MailMessage) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let text = bodies[m.id] {
        CappedScroll(maxHeight: 130) {
          Text(MailLogic.previewText(text))
            .font(.system(size: 12))
            .foregroundStyle(Theme.text.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
      } else if let failure = bodyErrors[m.id] {
        Banner(symbol: "exclamationmark.circle.fill", text: failure, tint: Theme.red)
      } else {
        HStack(spacing: 6) {
          TypingDots()
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
      }
      if let detected = EventDetector.detect(m.subject + "\n" + String((bodies[m.id] ?? "").prefix(2000)),
                                             now: nowDate) {
        EventSuggestion(detected: detected, today: LocalTime.datePart(now))
          .padding(.horizontal, 8)
      }
      WrapLayout(spacing: 6) {
        Button { startReply(m.id) } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        if model.state?.inbox.contains(where: { $0.id == m.id }) == true {
          // Aus dem Eingang „Antwort nötig“: hier als erledigt markieren statt im Reiter Nachrichten.
          Button {
            Task { await model.services.markInboxDone(m.id); await model.refresh() }
          } label: { Label("Erledigt", systemImage: "checkmark") }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .help("Antwort nötig – als erledigt markieren")
        }
        Button { makeTask(m) } label: { Label("Daraus Aufgabe", systemImage: "checkmark.circle") }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button { toggleFlag(m) } label: {
          Label(m.flagged ? "Markierung lösen" : "Markieren", systemImage: m.flagged ? "flag.slash" : "flag")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button { remove(m, trash: false) } label: { Label("Archivieren", systemImage: "archivebox") }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button { remove(m, trash: true) } label: { Label("Papierkorb", systemImage: "trash") }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
          .padding(.leading, 12)
          .help("In den Papierkorb verschieben")
      }
      .padding(.horizontal, 8)
    }
    .padding(.bottom, 8)
  }

  // MARK: Antwort-Entwurf

  private func composePage(_ c: MailComposeState, _ target: MailMessage) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Antwort", subtitle: "an \(MailLogic.senderLabel(target))") {
        Button("Zurück") { closeComposer() }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
      CappedScroll(maxHeight: 300) {
        composerView(c)
      }
    }
  }

  private func composerView(_ c: MailComposeState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if c.hasDraft {
        Text("Entwurf von Lumi – bitte prüfen")
          .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
        InputCapsule(placeholder: "An", text: composerBinding(\.to))
        InputCapsule(placeholder: "Betreff", text: composerBinding(\.subject))
        TextArea(placeholder: "Text der Antwort", text: composerBinding(\.body), minHeight: 90)
        if let e = c.error { Banner(symbol: "exclamationmark.circle.fill", text: e, tint: Theme.red) }
        HStack(spacing: 6) {
          Text("Nichts wird gesendet, bevor du „Senden“ drückst.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          Spacer(minLength: 0)
          Button("Verwerfen") { closeComposer() }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          Button { send(c.replyId) } label: { Label("Senden", systemImage: "paperplane.fill") }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(!canSend(c))
        }
      } else {
        InputCapsule(placeholder: "Was soll drinstehen? z. B. Ja, 19 Uhr passt",
                     text: composerBinding(\.instruction))
          .onSubmit { draft(c.replyId) }
        if let e = c.error { Banner(symbol: "exclamationmark.circle.fill", text: e, tint: Theme.red) }
        HStack(spacing: 6) {
          if c.drafting { TypingDots() }
          Spacer(minLength: 0)
          Button("Abbrechen") { closeComposer() }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          Button { draft(c.replyId) } label: { Label("Entwurf schreiben", systemImage: "sparkles") }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(c.drafting || c.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
  }

  private func composerBinding(_ path: WritableKeyPath<MailComposeState, String>) -> Binding<String> {
    Binding(
      get: { composer?[keyPath: path] ?? "" },
      set: { value in composer?[keyPath: path] = value }
    )
  }

  private func canSend(_ c: MailComposeState) -> Bool {
    !recipients(c.to).isEmpty && !c.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func recipients(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  // MARK: Aktionen

  private func enable() {
    error = nil
    Task {
      _ = await model.services.updateSettings(SettingsPatch(mailEnabled: true), apiKey: nil)
      let granted = await model.services.requestPermission(.mail)
      if !granted { error = "Mail-Zugriff wurde nicht erlaubt. Systemeinstellungen → Datenschutz & Sicherheit → Automation → Lumi → Mail anhaken." }
      let r = await model.services.refreshMail()
      if let o = r.value { local = o } else { error = r.errorMessage }
      await model.refresh()
    }
  }

  private func refresh() {
    loading = true
    error = nil
    Task {
      let r = await model.services.refreshMail()
      loading = false
      if let o = r.value { local = o } else { error = r.errorMessage }
      await model.refresh()
    }
  }

  private func openPrivacySettings() {
    if let url = URL(string: MailLogic.privacySettingsURL) { NSWorkspace.shared.open(url) }
  }

  private func toggle(_ m: MailMessage) {
    if expandedId == m.id {
      withAnimation(Theme.spring) {
        expandedId = nil
        composer = nil
      }
      return
    }
    withAnimation(Theme.spring) {
      expandedId = m.id
      composer = nil
    }
    if !m.read { markRead(m.id) }
    if bodies[m.id] == nil { loadBody(m.id) }
  }

  private func loadBody(_ id: String) {
    Task {
      let r = await model.services.mailBody(id)
      if let text = r.value { bodies[id] = text } else { bodyErrors[id] = r.errorMessage ?? "Der Text ist nicht lesbar." }
    }
  }

  private func markRead(_ id: String) {
    updateLocal(id) { $0.read = true }
    Task {
      let r = await model.services.setMailRead(id, true)
      error = await ViewActions.finish(model, r.errorMessage, success: nil)
      await model.refresh()
    }
  }

  private func toggleFlag(_ m: MailMessage) {
    let value = !m.flagged
    updateLocal(m.id) { $0.flagged = value }
    Task {
      let r = await model.services.setMailFlagged(m.id, value)
      if !r.isOk { error = r.errorMessage }
      await model.refresh()
    }
  }

  /// Öffnet die Karte unter der Liste; anlegen erst nach „Anlegen“ in der Karte.
  private func makeTask(_ m: MailMessage) {
    error = nil
    withAnimation(Theme.spring) { taskDraft = m }
  }

  /// Archivieren oder Papierkorb: die Zeile geht weg; bei Fehler wird neu geladen.
  private func remove(_ m: MailMessage, trash: Bool) {
    error = nil
    withAnimation(Theme.spring) {
      expandedId = nil
      composer = nil
      local?.messages.removeAll { $0.id == m.id }
      recount()
    }
    Task {
      let r = trash ? await model.services.trashMail(m.id) : await model.services.archiveMail(m.id)
      if r.isOk {
        model.react(trash ? .itemDeleted : .taskCompleted)
      } else {
        error = r.errorMessage
        await refreshSilently()
      }
      await model.refresh()
    }
  }

  private func refreshSilently() async {
    let r = await model.services.refreshMail()
    if let o = r.value { local = o }
  }

  private func startReply(_ id: String) {
    error = nil
    withAnimation(Theme.spring) { composer = MailComposeState(replyId: id) }
  }

  private func closeComposer() {
    withAnimation(Theme.spring) { composer = nil }
  }

  private func draft(_ id: String) {
    guard let c = composer, c.replyId == id else { return }
    let instruction = c.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else { return }
    composer?.drafting = true
    composer?.error = nil
    model.isThinking = true
    Task {
      do {
        let d = try await model.services.draftMailReply(id, instruction: instruction)
        model.isThinking = false
        guard composer?.replyId == id else { return }
        withAnimation(Theme.spring) {
          composer = MailComposeState(replyId: id, instruction: instruction, drafting: false, error: nil,
                                      hasDraft: true, to: d.to.joined(separator: ", "),
                                      subject: d.subject, body: d.body)
        }
      } catch {
        model.isThinking = false
        guard composer?.replyId == id else { return }
        composer?.drafting = false
        composer?.error = ChatLogic.errorToGerman(error) ?? "Der Entwurf ist fehlgeschlagen."
      }
    }
  }

  private func send(_ id: String) {
    guard let c = composer, c.replyId == id, canSend(c) else { return }
    let outgoing = MailDraft(replyToId: id, to: recipients(c.to), subject: c.subject, body: c.body)
    Task {
      let r = await model.services.sendMail(outgoing)
      if r.isOk {
        model.react(.celebrate)
        withAnimation(Theme.spring) {
          composer = nil
          expandedId = nil
        }
        note = "Gesendet an \(outgoing.to.joined(separator: ", "))"
        await model.refresh()
      } else {
        composer?.error = r.errorMessage ?? "Nicht gesendet."
      }
    }
  }

  // MARK: Hilfen

  private func updateLocal(_ id: String, _ change: (inout MailMessage) -> Void) {
    guard var o = local, let i = o.messages.firstIndex(where: { $0.id == id }) else { return }
    change(&o.messages[i])
    o.unread = MailLogic.unreadCount(o.messages)
    local = o
  }

  private func recount() {
    guard var o = local else { return }
    o.unread = MailLogic.unreadCount(o.messages)
    local = o
  }
}

/// Eine Zeile: ungelesen-Punkt, Absender (fett, wenn ungelesen), Betreff, Zeit, Fahne.
private struct MailRow: View {
  let message: MailMessage
  let time: String
  let expanded: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HoverRow { _ in
        HStack(spacing: 8) {
          Circle()
            .fill(message.read ? Color.clear : Theme.blue)
            .frame(width: 6, height: 6)
          VStack(alignment: .leading, spacing: 1) {
            Text(MailLogic.senderLabel(message))
              .font(.system(size: 13, weight: message.read ? .regular : .semibold))
              .foregroundStyle(Theme.text)
              .lineLimit(1)
            Text(message.subject)
              .font(.system(size: 12))
              .foregroundStyle(message.read ? Theme.tertiary : Theme.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 6)
          if message.flagged {
            Image(systemName: "flag.fill")
              .font(.system(size: 10))
              .foregroundStyle(Theme.amber)
          }
          Text(time)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
        }
      }
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(expanded ? Theme.raised : .clear))
    }
    .buttonStyle(.plain)
    .accessibilityValue(message.read ? "gelesen" : "ungelesen")
  }
}

// MARK: - Daraus wird was (Aufgabe und Termin aus Mail und Chat)

/// Aufgabe aus Mail oder Chat: Titel und Rückverweis in den Notizen. Reine Logik, geprüft in MailChecks.
enum TaskFromMessage {
  static func mail(_ m: MailMessage) -> (title: String, notes: String) {
    let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = subject.isEmpty ? m.senderName : subject
    let sender = "Mail von \(m.senderName) <\(m.senderAddress)>"
    // Apple Mail öffnet die Nachricht über message://%3C<Message-ID>%3E.
    let id = m.id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    guard !id.isEmpty, let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
      return (title, sender)
    }
    return (title, sender + "\nmessage://%3C\(enc)%3E")
  }

  /// Endgültige Werte für „Anlegen“. nil = Titel fehlt. Die Notizen bleiben unverändert (Rückverweis);
  /// ohne gewählte Fälligkeit bleibt `due` nil, unbekannte Kategorien zählen als keine.
  static func compose(title: String, notes: String, categoryId: String?, categories: [TaskCategoryDef],
                      mode: TaskLogic.DueMode, today: String, date: String?, time: String?)
    -> (title: String, notes: String?, due: String?, categoryId: String?)? {
    guard TaskLogic.validateTitle(title) == nil else { return nil }
    return (title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            TaskLogic.dueString(mode, today: today, custom: date, time: time),
            TaskCategoryLogic.known(categoryId, defs: categories))
  }

  /// Kurzname des Chat-Dienstes für Titel und Notizen („Element“, nicht „Element / Matrix“).
  static func serviceName(_ s: MessengerService) -> String {
    switch s {
    case .matrix: "Element"
    case .slack: "Slack"
    case .teams: "Teams"
    case .imessage: "iMessage"
    }
  }

  /// Kurzer Titel aus dem Anfang des Textes: erste Zeile, höchstens 7 Wörter und 48 Zeichen, sonst mit „…“.
  static func shortTitle(_ text: String, maxWords: Int = 7, maxChars: Int = 48) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let words = line.split(separator: " ").map(String.init)
    var out = ""
    var cut = words.count > maxWords
    for w in words.prefix(maxWords) {
      let next = out.isEmpty ? w : out + " " + w
      if next.count > maxChars { cut = true; break }
      out = next
    }
    if out.isEmpty { out = String(line.prefix(maxChars)); cut = line.count > maxChars }
    return cut ? out + "…" : out
  }

  /// „2026-10-22T11:28“ → „22.10. 11:28“ für den Rückverweis in den Notizen.
  static func shortStamp(_ at: String) -> String {
    let date = LocalTime.datePart(at)
    let parts = date.split(separator: "-")
    guard parts.count == 3 else { return at }
    let time = GermanDate.time(at)
    return "\(parts[2]).\(parts[1])." + (time.map { " \($0)" } ?? "")
  }

  /// Aufgabe aus einer Nachricht: kurzer Titel („Antonia (Element): Ich hab auch schon mehrfach …“), der volle
  /// Text in den Notizen, darunter der Rückverweis (Absender, Chat, Dienst, Zeit). Kein Permalink im Konnektor.
  static func chat(_ m: MessengerMessage, in conversation: MessengerConversation,
                   service: String? = nil) -> (title: String, notes: String) {
    let body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = shortTitle(body)
    let label = service.map { "\(m.sender) (\($0))" } ?? m.sender
    let title = head.isEmpty ? "Nachricht von \(label)" : "\(label): \(head)"
    let via = service.map { " (\($0))" } ?? ""
    return (title, body + "\n\nVon \(m.sender) in \(conversation.title)\(via), \(shortStamp(m.at))")
  }

  /// Mehrere markierte Nachrichten → eine Aufgabe: Titel aus der ersten, alle Texte in den Notizen.
  static func chat(_ ms: [MessengerMessage], in conversation: MessengerConversation,
                   service: String? = nil) -> (title: String, notes: String) {
    guard let first = ms.first else { return ("Nachricht", "") }
    if ms.count == 1 { return chat(first, in: conversation, service: service) }
    let lines = ms.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
    let via = service.map { " (\($0))" } ?? ""
    return (chat(first, in: conversation, service: service).title,
            lines + "\n\nAus \(conversation.title)\(via), \(shortStamp(first.at))")
  }
}

/// Chip „Termin erkannt: Fr 10:30“; aufgeklappt die Bestätigungskarte. Angelegt wird erst nach „Anlegen“.
struct EventSuggestion: View {
  let detected: EventDetector.DetectedEvent
  let today: String
  @State private var open = false
  @State private var done = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if done {
        Label("Termin angelegt", systemImage: "checkmark.circle")
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
      } else {
        Button { open.toggle() } label: {
          Label("Termin erkannt: \(EventDetector.chipLabel(detected))", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        if open {
          EventConfirmCard(detected: detected, today: today) {
            done = true
            open = false
          }
        }
      }
    }
  }
}

/// Bestätigungskarte: Titel und Beginn sind änderbar. Gespeichert wird über ViewActions.addEvent,
/// also mit demselben Konfliktcheck wie im Kalender; bei Konflikt nur nach „Trotzdem speichern“.
struct EventConfirmCard: View {
  let detected: EventDetector.DetectedEvent
  let today: String
  let onSaved: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var title: String
  @State private var start: Date
  @State private var saving = false
  @State private var error: String?
  @State private var conflict: (message: String, pending: NewEvent)?

  init(detected: EventDetector.DetectedEvent, today: String, onSaved: @escaping () -> Void) {
    self.detected = detected
    self.today = today
    self.onSaved = onSaved
    _title = State(initialValue: detected.title)
    _start = State(initialValue: LocalTime.parse(detected.start) ?? Date())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Titel", text: $title)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
      DatePicker("Beginn", selection: $start, displayedComponents: [.date, .hourAndMinute])
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
      Text("Dauer \(detected.durationMinutes) Min.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
      if let error {
        Banner(symbol: "exclamationmark.triangle.fill", text: error, tint: Theme.red)
      }
      if let conflict {
        Banner(symbol: "exclamationmark.triangle.fill", text: conflict.message, tint: Theme.red)
        Button { save(conflict.pending, allowConflict: true) } label: {
          Label("Trotzdem speichern", systemImage: "exclamationmark.triangle")
        }
        .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
        .disabled(saving)
      } else {
        HStack {
          Spacer(minLength: 0)
          Button { submit() } label: { Label("Anlegen", systemImage: "calendar.badge.plus") }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(saving)
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private func submit() {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else {
      error = "Bitte einen Titel eingeben."
      return
    }
    let end = start.addingTimeInterval(TimeInterval(detected.durationMinutes * 60))
    save(NewEvent(title: t, start: LocalTime.format(start), end: LocalTime.format(end)), allowConflict: false)
  }

  private func save(_ event: NewEvent, allowConflict: Bool) {
    error = nil
    saving = true
    Task {
      let r = await ViewActions.addEvent(model, event, allowConflict: allowConflict, today: today)
      saving = false
      switch r {
      case .saved:
        onSaved()
      case .conflict(let message, let pending, _):
        conflict = (message, pending)
      case .failed(let message):
        error = message
      }
    }
  }
}
