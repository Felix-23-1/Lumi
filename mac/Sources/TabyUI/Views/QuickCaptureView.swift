// Schnellerfassung (Paket 1): ein Gedanke rein, das Modell sortiert ihn als
// Aufgabe, Notiz oder Termin ein. Die Hülle zeigt diese Ansicht, wenn der
// Kurzbefehl gedrückt wird, und klappt nach `onDone` wieder zu.
import SwiftUI
import TabyCore

/// Testbare Logik der Schnellerfassung (ohne Fenster).
@MainActor
final class QuickCaptureModel: ObservableObject {
  enum Phase: Equatable { case editing, sending, done(String), failed(String) }

  @Published var text = ""
  @Published private(set) var phase: Phase = .editing
  private let services: TabyServices

  init(services: TabyServices) { self.services = services }

  var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .sending }

  /// Schickt den Gedanken ab. true bei Erfolg (Text der Antwort steht in `phase`).
  @discardableResult
  func submit() async -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, phase != .sending else { return false }
    phase = .sending
    do {
      let messages = try await services.quickCapture(t)
      let reply = messages.last(where: { $0.role == .assistant && ($0.content?.isEmpty == false) })?.content
      phase = .done(reply ?? "Erfasst.")
      text = ""
      return true
    } catch {
      phase = .failed(ChatLogic.errorToGerman(error) ?? "Abgebrochen.")
      return false
    }
  }
}

public struct QuickCaptureView: View {
  let onDone: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot

  public init(onDone: @escaping () -> Void) { self.onDone = onDone }

  public var body: some View {
    QuickCaptureContent(services: model.services, onDone: onDone)
  }
}

private struct QuickCaptureContent: View {
  let onDone: () -> Void
  @EnvironmentObject private var model: AppModel
  @StateObject private var capture: QuickCaptureModel
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  init(services: TabyServices, onDone: @escaping () -> Void) {
    self.onDone = onDone
    _capture = StateObject(wrappedValue: QuickCaptureModel(services: services))
  }

  /// Feld zeigt beim Sprechen den Live-Text, sonst den eigenen Entwurf.
  private var fieldText: Binding<String> {
    Binding(get: { model.listening ? model.transcript : capture.text },
            set: { capture.text = $0 })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(Theme.amber)
        field
        micButton
        Button { send() } label: {
          Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
            .frame(width: 26, height: 26)
            .background(Circle().fill(capture.canSend ? Color.white : Color.white.opacity(0.25)))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .disabled(!capture.canSend)
      }
      .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
      .background(Capsule().fill(Theme.raised))
      statusLine
    }
    .padding(12)
    .frame(width: TabLayout.contentWidth, alignment: .leading)
    .animation(Theme.spring, value: capture.phase)
    .onAppear {
      consumeDraft()
      focused = true
    }
    .onChange(of: model.captureDraft) { _, _ in consumeDraft() }
    .onExitCommand { onDone() }
  }

  /// Diktat-Knopf: Sprechen starten bzw. beenden (Text ins Feld, nicht gleich senden).
  private var micButton: some View {
    Button { toggleMic() } label: {
      Image(systemName: model.listening ? "waveform" : "mic.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(model.listening ? Theme.red : Theme.secondary)
        .symbolEffect(.variableColor.iterative, isActive: model.listening)
        .frame(width: 26, height: 26)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(model.listening ? "Diktat beenden" : "Diktieren")
    .accessibilityLabel(model.listening ? "Diktat beenden" : "Diktieren")
  }

  @ViewBuilder private var field: some View {
    if snapshot {
      Text(fieldText.wrappedValue.isEmpty ? "Was geht dir durch den Kopf?" : fieldText.wrappedValue)
        .font(.system(size: 15)).foregroundStyle(fieldText.wrappedValue.isEmpty ? Theme.tertiary : Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      TextField("Was geht dir durch den Kopf?", text: fieldText)
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .foregroundStyle(Theme.text)
        .focused($focused)
        .onSubmit { send() }
        .disabled(capture.phase == .sending)
    }
  }

  private func consumeDraft() {
    guard let draft = model.captureDraft else { return }
    capture.text = draft
    model.captureDraft = nil
  }

  private func toggleMic() {
    Task {
      if model.listening {
        await model.stopListening(submit: false)
        focused = true
      } else {
        await model.startListening()
      }
    }
  }

  @ViewBuilder private var statusLine: some View {
    switch capture.phase {
    case .editing:
      Text("Ich sortiere es als Aufgabe, Notiz oder Termin ein. Esc schließt.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    case .sending:
      HStack(spacing: 6) {
        TypingDots()
        Text("Sortiere ein…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
    case .done(let reply):
      Label(reply, systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green).lineLimit(2)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    case .failed(let error):
      Label(error, systemImage: "exclamationmark.circle.fill")
        .font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(3)
    }
  }

  private func send() {
    guard capture.canSend else { return }
    model.isThinking = true
    Task {
      let ok = await capture.submit()
      model.isThinking = false
      if ok {
        model.react(.itemAdded)
        await model.refresh()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        onDone()
      } else {
        focused = true
      }
    }
  }
}
