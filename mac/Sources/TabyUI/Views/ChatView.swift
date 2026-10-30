// Reiter "Chat": Modell-Kapsel, Verlauf (Nutzer rechts als graue Kapsel,
// Assistent links als Text, Aktionen als kleine graue Zeilen), Tipp-Punkte,
// Eingabekapsel mit rundem weißem Senden-Knopf, Abbrechen, Verlauf leeren.
import SwiftUI
import TabyCore

struct ChatView: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @StateObject private var chat: ChatController
  @StateObject private var voice = VoiceChat()
  @State private var focusTick = 0
  @Environment(\.tabyNow) private var nowEnv
  @Environment(\.tabySnapshot) private var snapshot

  init(state: AppState, controller: ChatController? = nil) {
    self.state = state
    _chat = StateObject(wrappedValue: controller ?? ChatController.shared)
  }

  /// Beispiele im leeren Chat: ein Tipp schickt sie direkt ab.
  /// Ein Tipp füllt nur das Eingabefeld und setzt den Cursor hinein; abgeschickt wird vom Nutzer.
  static let examplePrompts = [
    "Was steht heute an?",
    "Plan meinen Tag",
    "Verschieb alles Offene auf morgen",
    "Merk dir: Mittagspause von 12 bis 13 Uhr",
    "Neue Aufgabe: Angebot schreiben morgen 10 Uhr",
    "Habe ich heute Konflikte im Kalender?",
  ]

  private var display: [DisplayMessage] {
    var d = ChatLogic.display(state.messages)
    if let p = chat.pendingUserText {
      d.append(DisplayMessage(id: d.count, role: .user, text: p))
    }
    if let partial = chat.partialText, !partial.isEmpty {
      d.append(DisplayMessage(id: d.count, role: .assistant, text: partial))
    }
    for n in chat.notices { d.append(DisplayMessage(id: d.count, role: .assistant, text: n, isAction: true)) }
    return d
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      history
      if let label = model.undoBannerLabel, ViewSupportLogic.undoVisible(label) {
        UndoBanner(label: label).transition(.opacity)
      }
      if let pending = model.state?.pendingConfirmations, !pending.isEmpty {
        ConfirmationCards(pending: pending)
      }
      if let err = chat.error {
        errorBar(err)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      if chat.consentRetry != nil { consentCard }
      if state.settings.localOnly && !state.appleIntelligenceAvailable { localOnlyCard }
      if !skillSuggestions.isEmpty { skillList }
      if !model.droppedFiles.isEmpty { fileCard }
      inputRow
    }
    .animation(Theme.spring, value: display.count)
    .animation(Theme.spring, value: chat.thinking)
    .animation(Theme.spring, value: chat.error)
  }

  /// Roter Balken: Text, Schließen und der Weg in die Einstellungen in einer Fläche.
  private func errorBar(_ err: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.bubble.fill")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
        Text(err)
          .font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button { withAnimation(Theme.snappy) { chat.dismissError() } } label: { Image(systemName: "xmark") }
          .buttonStyle(RoundIconButtonStyle(size: 22))
          .accessibilityLabel("Hinweis schließen")
      }
      Button("Einstellungen öffnen") { model.onOpenTab?(.settings) }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.red.opacity(0.12)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.red.opacity(0.25), lineWidth: 1))
  }

  /// Einwilligung für das Cloud-Modell: vor dem ersten Senden fragen, der Text wartet.
  private var consentCard: some View {
    let host = PrivacyLogic.host(state.settings.llmBaseUrl)
    let target = LlmProviders.preset(forBaseUrl: state.settings.llmBaseUrl).map { "\($0.name) (\(host))" } ?? host
    return VStack(alignment: .leading, spacing: 8) {
      Text("Lumi schickt deine Chat-Nachrichten und dazu Aufgaben/Termine an \(target). Einverstanden?")
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        Button("Einverstanden") { chat.consent(model, localOnly: false, now: NowResolver.now(nowEnv)) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        Button("Nur lokal nutzen") { chat.consent(model, localOnly: true, now: NowResolver.now(nowEnv)) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
    }
    .tabyCard()
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  /// Abgelegte Dateien: Lumi fragt, was damit passieren soll. Eigene Bitte geht über das Eingabefeld.
  private var fileCard: some View {
    let names = model.droppedFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    let events = Array((state.overview.eventsToday + state.overview.eventsUpcoming).prefix(8))
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
        Text("„\(names)“ – was soll ich damit machen?")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button { model.droppedFiles = [] } label: { Image(systemName: "xmark") }
          .buttonStyle(RoundIconButtonStyle(size: 22))
          .accessibilityLabel("Dateien verwerfen")
      }
      WrapLayout(spacing: 4) {
        Button("Zusammenfassen") {
          chat.ask("Fasse sie in 2–4 Sätzen zusammen. Wenn darin klare Aufgaben, Fristen oder Termine stehen, lege sie an und sag, was du angelegt hast.", model)
        }
        Button("Als Notiz") { Task { await model.saveDroppedFilesAsNotes(titlePrefix: nil) } }
        if ObsidianLogic.isConnected(state) {
          Button("In Obsidian") { Task { await ObsidianActions.saveDroppedFiles(model) } }
        }
        if !events.isEmpty {
          // Snapshots: das Menü rendert als gelbes Verbotsschild, dort steht ein Knopf mit demselben Text.
          if snapshot {
            Button("Zu Termin") {}
          } else {
            Menu("Zu Termin") {
              ForEach(events, id: \.id) { e in
                Button(e.title) { Task { await model.saveDroppedFilesAsNotes(titlePrefix: e.title) } }
              }
            }
            .menuStyle(.borderlessButton).fixedSize()
          }
        }
        Button("Mail-Entwurf") {
          chat.ask("Schreib daraus einen kurzen Mail-Entwurf mit draft_mail (nur Entwurf, nichts senden). Fehlt der Empfänger, frag mich danach.", model)
        }
        Button("Aufgaben daraus") {
          chat.ask("Lege für jede klare Aufgabe oder Frist darin eine Aufgabe an und nenne sie kurz.", model)
        }
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      Text("Oder schreib unten, was ich damit tun soll.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
    .tabyCard()
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  /// Nur-lokal ohne Apple Intelligence: Lumi kann nicht antworten, der Knopf führt zum Datenschutz.
  private var localOnlyCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Nur-lokal-Modus – kein Modell verfügbar")
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
      Button("Datenschutz-Einstellungen öffnen") {
        SettingsPage.requested = .privacy
        model.onDetach?(.settings)
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
    .tabyCard()
  }

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        StatusDot(color: chat.error != nil ? Theme.red : (state.settings.hasApiKey ? Theme.green : Theme.amber), size: 6)
        Text(ChatLogic.modelLabel(state.settings.llmModel))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Capsule().fill(Theme.capsule))
      .help(state.settings.llmModel)
      Spacer()
      if chat.thinking {
        Button("Abbrechen") { chat.cancel(model) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .keyboardShortcut(.escape, modifiers: [])
          .transition(.scale.combined(with: .opacity))
      }
      Button {
        Task { await chat.clear(model) }
      } label: {
        Label("Verlauf leeren", systemImage: "trash")
      }
      .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      .disabled(display.isEmpty || chat.thinking)
    }
  }

  private var history: some View {
    ScrollViewReader { proxy in
      CappedScroll(maxHeight: 252) {
        VStack(alignment: .leading, spacing: 8) {
          if display.isEmpty && !chat.thinking {
            VStack(alignment: .leading, spacing: 6) {
              if ChatLogic.modelLabel(state.settings.llmModel) == "Kein Modell" {
                Text("Lumi braucht einen KI-Zugang, z. B. OpenRouter oder Apple Intelligence.")
                  .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                Button("KI-Zugang einrichten") { model.onOpenTab?(.settings) }
                  .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
              }
              Text("Frag mich etwas, zum Beispiel:")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
              ForEach(Self.examplePrompts, id: \.self) { prompt in
                Button { chat.input = prompt; focusTick += 1 } label: { Text(prompt) }
                  .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(display) { m in
            bubble(m).id(m.id)
              .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
          }
          if chat.thinking && chat.partialText == nil {
            TypingDots().id("thinking").transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
          }
        }
        .padding(.vertical, 2)
      }
      .onChange(of: display.count) { _, _ in scrollToEnd(proxy) }
      .onChange(of: chat.thinking) { _, _ in scrollToEnd(proxy) }
      .onChange(of: chat.partialText) { _, _ in scrollToEnd(proxy, animated: false) }
      .onAppear { scrollToEnd(proxy, animated: false) }
    }
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
    let target: AnyHashable = chat.thinking ? AnyHashable("thinking") : AnyHashable(display.last?.id ?? 0)
    if animated {
      withAnimation(Theme.spring) { proxy.scrollTo(target, anchor: .bottom) }
    } else {
      proxy.scrollTo(target, anchor: .bottom)
    }
  }

  @ViewBuilder private func bubble(_ m: DisplayMessage) -> some View {
    if m.isAction {
      HStack(spacing: 5) {
        Image(systemName: m.isFailure ? "xmark.circle" : "checkmark.circle")
          .font(.system(size: 10, weight: .semibold))
        Text(m.text).font(.system(size: 12)).lineLimit(2)
      }
      .foregroundStyle(m.isFailure ? Theme.red.opacity(0.85) : Theme.secondary)
      .padding(.leading, 2)
    } else if m.role == .user {
      HStack {
        Spacer(minLength: 60)
        Text(m.text)
          .font(.system(size: 13))
          .foregroundStyle(Theme.text)
          .textSelection(.enabled)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.capsuleHover))
      }
    } else {
      Text(m.text)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 30)
        .padding(.leading, 2)
    }
  }

  /// Freigegebene Skills, deren Befehl zur „/“-Eingabe passt (ohne Leerzeichen dahinter).
  private var skillSuggestions: [ModInfo] {
    let typed = chat.input.trimmingCharacters(in: .whitespaces)
    guard typed.hasPrefix("/"), !typed.contains(" ") else { return [] }
    let word = typed.dropFirst().lowercased()
    return state.mods.filter { m in
      m.manifest.kind == .skill && m.enabled && m.approved && (m.manifest.command ?? m.id).hasPrefix(word)
    }
  }

  private var skillList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(skillSuggestions, id: \.id) { m in
        Button {
          chat.input = "/\(m.manifest.command ?? m.id) "
          focusTick += 1
        } label: {
          HStack(spacing: 6) {
            Text("/\(m.manifest.command ?? m.id)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Text(m.manifest.name).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skill \(m.manifest.name), Befehl /\(m.manifest.command ?? m.id)")
      }
    }
    .tabyCard(padding: 8)
  }

  private var inputRow: some View {
    InputCapsule(placeholder: display.isEmpty ? "Frag Lumi…" : "Weiterschreiben…", text: $chat.input,
                 focusTick: focusTick) {
      // Diktat: Text landet im Eingabefeld, abgeschickt wird erst mit Senden.
      Button {
        Task {
          if model.listening {
            await model.stopListening(submit: false)
            if let draft = model.captureDraft {
              chat.input = chat.input.isEmpty ? draft : chat.input + " " + draft
              chat.dictated = true
              model.captureDraft = nil
            }
            focusTick += 1
          } else {
            await model.startListening()
          }
        }
      } label: { Image(systemName: model.listening ? "waveform" : "mic.fill") }
        .buttonStyle(RoundIconButtonStyle(size: 26, tint: model.listening ? Theme.red : Theme.secondary))
        .symbolEffect(.variableColor.iterative, isActive: model.listening)
        .help(model.listening ? "Diktat beenden" : "Diktieren")
        .accessibilityLabel(model.listening ? "Diktat beenden" : "Diktieren")
      // Gespräch: Lumi hört zu, antwortet laut und hört danach wieder zu („Stopp“ beendet).
      Button { voice.toggle(chat, model) } label: {
        Image(systemName: voice.active ? "stop.circle.fill" : "person.wave.2.fill")
      }
        .buttonStyle(RoundIconButtonStyle(size: 26, tint: voice.active ? Theme.red : Theme.secondary))
        .symbolEffect(.pulse, isActive: voice.active)
        .help(voice.active ? "Sprachgespräch beenden" : "Sprachgespräch: sprechen und Antwort hören")
        .accessibilityLabel(voice.active ? "Sprachgespräch beenden" : "Sprachgespräch")
      Button { chat.send(model) } label: { Image(systemName: "arrow.up") }
        .buttonStyle(RoundIconButtonStyle(size: 26, filled: true))
        .disabled(!chat.canSend)
        .help("Senden")
        .accessibilityLabel("Senden")
    }
    .frame(minHeight: 34)
    .onSubmit { chat.send(model) }
    .onDisappear { voice.stop(model) }
    .onChange(of: chat.input) { _, new in if new.isEmpty { chat.dictated = false } }
  }
}
