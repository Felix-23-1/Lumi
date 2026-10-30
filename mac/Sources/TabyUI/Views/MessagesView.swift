// Reiter "Nachrichten": Unterhaltungsliste mit ungelesen-Zählern; Klick öffnet den Verlauf
// mit Eingabe unten. Alles läuft über model.services – Zugangsdaten bleiben im Dienst.
import SwiftUI
import TabyCore

enum MessagesLogic {
  /// "HH:mm" für heute, sonst "dd.MM." (lokale zonenlose Zeit).
  static func timeLabel(_ at: String, today: String) -> String {
    let day = LocalTime.datePart(at)
    if day == today, let t = GermanDate.time(at) { return t }
    let parts = day.split(separator: "-")
    guard parts.count == 3 else { return at }
    return "\(parts[2]).\(parts[1])."
  }

  static func unreadTotal(_ conversations: [MessengerConversation]) -> Int {
    conversations.reduce(0) { $0 + max(0, $1.unread) }
  }
}

struct MessagesView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var selected: String?
  /// Nur Snapshots/Prüfungen: Unterhaltung direkt öffnen und Verlauf vorgeben (`.task` läuft im Renderer nicht).
  private let seed: [String: [MessengerMessage]]

  init(state: AppState, openConversation: String? = nil, seed: [String: [MessengerMessage]] = [:]) {
    self.state = state
    self.seed = seed
    _selected = State(initialValue: openConversation)
  }

  private var today: String { NowResolver.today(nowEnv) }

  var body: some View {
    if let id = selected, let conv = state.messengerConversations.first(where: { $0.id == id }) {
      ThreadView(conversation: conv, today: today, seed: seed[id] ?? []) { selected = nil }
        .id(conv.id)
    } else {
      list
    }
  }

  private var list: some View {
    let conversations = state.messengerConversations
    return VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Nachrichten", subtitle: "\(MessagesLogic.unreadTotal(conversations)) ungelesen")
      if !state.inbox.isEmpty {
        InboxSection(items: state.inbox.filter { $0.channel != "Mail" }, today: today) { selected = $0 }
      }
      if conversations.isEmpty {
        EmptyState(symbol: "bubble.left.and.bubble.right", title: "Keine Unterhaltungen",
                   subtitle: "Verbinde einen Messenger unter Einstellungen → Verbindungen (mit „Erweitert anzeigen“). Danach erscheinen hier deine Chats.")
      } else {
        CappedScroll(maxHeight: 360) {
          VStack(spacing: 6) {
            ForEach(conversations) { conv in
              ConversationRow(conversation: conv, service: service(of: conv), today: today) { selected = conv.id }
            }
          }
        }
      }
    }
  }

  private func service(of conv: MessengerConversation) -> MessengerService? {
    state.messengerAccounts.first { $0.id == conv.accountId }?.service
  }
}

private struct ConversationRow: View {
  let conversation: MessengerConversation
  let service: MessengerService?
  let today: String
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Image(systemName: service?.symbol ?? "bubble.left")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.tertiary)
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          Text(conversation.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
          Text(conversation.lastText ?? "")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 4) {
          if let at = conversation.lastAt {
            Text(MessagesLogic.timeLabel(at, today: today))
              .font(.system(size: 10))
              .foregroundStyle(Theme.tertiary)
          }
          if conversation.unread > 0 {
            Text("\(conversation.unread)")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Theme.blue))
          }
        }
        .fixedSize()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .tabyCard()
  }
}

private struct ThreadView: View {
  let conversation: MessengerConversation
  let today: String
  let onBack: () -> Void
  @EnvironmentObject private var model: AppModel
  /// Dienst des Kontos dieser Unterhaltung („Element“, „Slack“ …) für Titel und Notizen der Aufgabe.
  private var serviceLabel: String? {
    model.state?.messengerAccounts.first { $0.id == conversation.accountId }
      .map { TaskFromMessage.serviceName($0.service) }
  }
  @State private var messages: [MessengerMessage]
  @State private var input = ""
  @State private var sending = false
  @State private var failure: String?
  /// Auswahl-Modus: Nachrichten markieren und daraus eine Aufgabe machen.
  @State private var selecting = false
  @State private var picked: Set<String> = []
  /// Markierte Nachrichten, für die die Karte „Daraus Aufgabe“ offen ist.
  @State private var taskMessages: [MessengerMessage]?
  @State private var note: String?
  /// Nachricht, auf die die nächste Antwort geht (bei Element bleibt sie im Thread).
  @State private var replyTarget: MessengerMessage?
  /// Nachricht unter dem Mauszeiger; der Antwort-Knopf erscheint nur dort.
  @State private var hoverId: String?
  @Environment(\.tabySnapshot) private var snapshot
  @Environment(\.tabyNow) private var nowEnv

  init(conversation: MessengerConversation, today: String, seed: [MessengerMessage], onBack: @escaping () -> Void) {
    self.conversation = conversation
    self.today = today
    self.onBack = onBack
    _messages = State(initialValue: seed)
  }

  private var canSend: Bool { !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var now: String { NowResolver.now(nowEnv) }
  private var categories: [TaskCategoryDef] {
    model.state?.settings.taskCategories ?? TaskCategoryDef.builtIn
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button("‹ Alle", action: onBack)
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.secondary)
        Text(conversation.title)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(selecting ? "Abbrechen" : "Aufgabe aus Nachrichten") {
          withAnimation(Theme.spring) { selecting.toggle(); picked = [] }
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        .help("Nachrichten markieren und daraus eine Aufgabe machen")
      }
      .padding(.horizontal, 2)
      // ScrollViewReader bleibt im Renderer leer; Snapshots zeigen daher den Verlauf ohne Reader.
      if snapshot {
        history(nil)
      } else {
        ScrollViewReader { proxy in history(proxy) }
      }
      if let failure {
        Banner(symbol: "exclamationmark.triangle.fill", text: failure, tint: Theme.red)
      }
      if let note {
        Banner(symbol: "checkmark.circle.fill", text: note, tint: Theme.green)
      }
      if let picks = taskMessages {
        TaskFromMessageCard(title: TaskFromMessage.chat(picks, in: conversation, service: serviceLabel).title,
                            notes: TaskFromMessage.chat(picks, in: conversation, service: serviceLabel).notes,
                            categories: categories, seed: TaskCardSeed(), now: now,
                            onCreated: { title in
                              withAnimation(Theme.spring) { taskMessages = nil; selecting = false; picked = [] }
                              note = "Aufgabe angelegt: \(title)"
                            },
                            onCancel: { withAnimation(Theme.spring) { taskMessages = nil } })
      } else if selecting {
        HStack {
          Text(picked.isEmpty ? "Nachrichten antippen zum Markieren" : "\(picked.count) markiert")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
          Spacer()
          Button { openTaskCard(messages.filter { picked.contains($0.id) }) } label: {
            Label("Daraus Aufgabe", systemImage: "checkmark.circle")
          }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(picked.isEmpty)
        }
      } else {
        composer
      }
    }
    .task(id: conversation.lastAt) { await load() }
  }

  private func history(_ proxy: ScrollViewProxy?) -> some View {
    // Mit offener Karte kürzer, damit der Verlauf und die Karte zusammen in die 380 pt der Insel passen.
    // Mit gewählter Antwort kommt eine Zeile über das Eingabefeld dazu; der Verlauf gibt sie ab, sonst rutscht das Feld aus der Insel.
    CappedScroll(maxHeight: taskMessages != nil ? 110 : (replyTarget == nil ? 300 : 266)) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(messages) { bubble($0).id($0.id) }
      }
      .padding(.vertical, 2)
      .onChange(of: messages.last?.id) { _, id in
        if let id, let proxy { proxy.scrollTo(id, anchor: .bottom) }
      }
    }
  }

  private var nowDate: Date { LocalTime.parse(NowResolver.now(nowEnv)) ?? Date() }

  /// Öffnet die Karte für die markierten Nachrichten; angelegt wird erst nach „Anlegen“.
  private func openTaskCard(_ ms: [MessengerMessage]) {
    failure = nil
    withAnimation(Theme.spring) { taskMessages = ms }
  }

  private func bubble(_ m: MessengerMessage) -> some View {
    VStack(alignment: m.mine ? .trailing : .leading, spacing: 2) {
      if !m.mine && !conversation.isDirect {
        Text(m.sender)
          .font(.system(size: 10))
          .foregroundStyle(Theme.tertiary)
          .padding(.leading, 4)
      }
      HStack(alignment: .top, spacing: 6) {
        if selecting {
          Image(systemName: picked.contains(m.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14))
            .foregroundStyle(picked.contains(m.id) ? Theme.blue : Theme.tertiary)
            .padding(.top, 7)
        }
        Text(m.text)
          .font(.system(size: 13))
          .foregroundStyle(Theme.text)
          .lineSpacing(2)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(m.mine ? Theme.blue.opacity(0.30) : Theme.raised)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Theme.blue, lineWidth: selecting && picked.contains(m.id) ? 1.5 : 0)
          )
      }
      .contentShape(Rectangle())
      .onTapGesture {
        guard selecting else {
          if !m.mine { withAnimation(Theme.pop) { replyTarget = replyTarget?.id == m.id ? nil : m } }
          return
        }
        if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) }
      }
      .accessibilityAddTraits(selecting && picked.contains(m.id) ? .isSelected : [])
      HStack(spacing: 8) {
        Text((m.threadRoot == nil ? "" : "Thread · ") + MessagesLogic.timeLabel(m.at, today: today))
          .font(.system(size: 10))
          .foregroundStyle(Theme.tertiary)
        if !m.mine && !selecting && (hoverId == m.id || replyTarget?.id == m.id) {
          Button { withAnimation(Theme.pop) { replyTarget = replyTarget?.id == m.id ? nil : m } } label: {
            Label(replyTarget?.id == m.id ? "Antwort gewählt" : "Auf diese Nachricht antworten",
                  systemImage: "arrowshape.turn.up.left")
              .font(.system(size: 10, weight: .medium))
          }
          .buttonStyle(.plain)
          .foregroundStyle(replyTarget?.id == m.id ? Theme.blue : Theme.secondary)
        }
      }
      .padding(.horizontal, 4)
      if let detected = EventDetector.detect(m.text, now: nowDate) {
        EventSuggestion(detected: detected, today: today)
      }
    }
    .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
    .padding(.leading, m.mine ? 40 : 0)
    .padding(.trailing, m.mine ? 0 : 40)
    .onHover { inside in
      if inside { hoverId = m.id } else if hoverId == m.id { hoverId = nil }
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let r = replyTarget {
        HStack(spacing: 6) {
          Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
          Text("Im Thread antworten auf \(r.sender): \(r.text)")
            .font(.system(size: 11)).lineLimit(1)
          Spacer(minLength: 4)
          Button { withAnimation(Theme.pop) { replyTarget = nil } } label: { Image(systemName: "xmark") }
            .buttonStyle(RoundIconButtonStyle(size: 18))
            .accessibilityLabel("Antwort abbrechen")
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 6)
      }
      composerField
    }
  }

  private var composerField: some View {
    InputCapsule(placeholder: "Nachricht…", text: $input) {
      Button { send() } label: { Image(systemName: "paperplane") }
        .buttonStyle(RoundIconButtonStyle(size: 26, filled: true))
        .disabled(!canSend)
        .accessibilityLabel("Senden")
    }
    .frame(minHeight: 34)
    .onSubmit { send() }
  }

  private func load() async {
    let r = await model.services.messengerMessages(conversation.id, limit: 50)
    guard let v = r.value else { failure = r.errorMessage; return }
    messages = v
    failure = nil
    // Erst als gelesen markieren, wenn der Verlauf wirklich sichtbar ist.
    await model.services.markMessengerRead(conversation.id)
    await model.refresh()
  }

  private func send() {
    guard canSend else { return }
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    sending = true
    Task {
      let r = await model.services.sendMessengerMessage(conversation.id, text: text, replyTo: replyTarget?.id)
      sending = false
      if r.isOk {
        input = ""
        replyTarget = nil
        failure = nil
        await load()
      } else {
        failure = r.errorMessage
      }
    }
  }
}
