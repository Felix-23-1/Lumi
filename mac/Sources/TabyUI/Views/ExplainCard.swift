// „Lumi, erklär mir das“: Karte in der Insel. Oben der markierte Text (2 Zeilen), darunter
// Ladezustand, Erklärung, Antwortentwurf oder Fehler; Knöpfe für Vorlesen/Stopp, Entwurf,
// Weiterfragen im Chat und Schließen.
import AppKit
import SwiftUI
import TabyCore

/// Einstellung „Erklärungen vorlesen“ (App-Schicht, UserDefaults; Standard: an).
public enum ExplainSettings {
  public static let speakKey = "taby.explain.speak"
  public static var speak: Bool { UserDefaults.standard.object(forKey: speakKey) as? Bool ?? true }
}

/// Grußformel für Antwortentwürfe (App-Schicht, UserDefaults; Standard: leer).
public enum DraftSettings {
  public static let signatureKey = "taby.draft.signature"
  public static var signature: String { UserDefaults.standard.string(forKey: signatureKey) ?? "" }
}

/// Zustand der Karte: der markierte Text und die Phase (lädt, Antwort, Fehler).
public struct ExplainCardState: Equatable {
  public enum Phase: Equatable {
    case loading
    case answer(String)
    case failure(String)
  }

  public var original: String
  public var phase: Phase

  public init(original: String, phase: Phase = .loading) {
    self.original = original
    self.phase = phase
  }

  /// Fehler, weil kein KI-Zugang eingerichtet ist (Text aus dem Kern); dann bietet die Karte die Einrichtung an.
  public var needsAISetup: Bool {
    if case .failure(let message) = phase { return message.hasPrefix("Erklären braucht ein Modell") }
    return false
  }

  /// Text für das Eingabefeld im Chat, damit der Nutzer weiterfragen kann.
  public static func chatPrompt(for original: String) -> String {
    "Zu diesem Text: „\(original)“ – "
  }

  /// mailto-Link mit dem Entwurf als Text; `+&=` werden mitkodiert, sonst liest der Mailclient sie falsch.
  public static func mailtoURL(for body: String) -> URL? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    guard let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "mailto:?body=\(encoded)")
  }
}

struct ExplainCard: View {
  let state: ExplainCardState
  let onAskInChat: () -> Void
  let onDone: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var followUp = ""
  @State private var draft: String?
  @State private var draftFailure: String?
  @State private var drafting = false
  @State private var copied = false

  /// `initialDraft` ist nur für Snapshots gedacht: die Karte startet direkt im Entwurf.
  init(state: ExplainCardState, onAskInChat: @escaping () -> Void, onDone: @escaping () -> Void,
       initialDraft: String? = nil) {
    self.state = state
    self.onAskInChat = onAskInChat
    self.onDone = onDone
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(state.original)
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(2)
      content
      if case .answer = state.phase { followUpLine }
      HStack(spacing: 8) {
        actionPills
        if state.needsAISetup {
          pill("KI-Zugang einrichten") { model.onOpenTab?(.settings); onDone() }
        }
        Button { onDone() } label: {
          Text("Schließen").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: state.original) { _, _ in draft = nil; draftFailure = nil; copied = false }
  }

  /// Hauptbereich: Ladezustand, Entwurf, Fehler des Entwurfs oder die Erklärung selbst.
  @ViewBuilder private var content: some View {
    if drafting {
      loadingRow
    } else if let draftFailure {
      Banner(symbol: "exclamationmark.bubble.fill", text: draftFailure, tint: Theme.red)
    } else if let draft {
      answerText(draft)
    } else {
      switch state.phase {
      case .loading: loadingRow
      case .answer(let text): answerText(text)
      case .failure(let message): Banner(symbol: "exclamationmark.bubble.fill", text: message, tint: Theme.red)
      }
    }
  }

  @ViewBuilder private var actionPills: some View {
    if case .answer(let text) = state.phase {
      // Im Entwurf-Modus bleiben nur Kopieren, Mail und Rückweg; die Nachfrage läuft über die Zeile darunter.
      if let draft {
        pill(copied ? "Kopiert" : "Kopieren") { copy(draft) }
        pill("Als Mail-Entwurf") { openMail(draft) }
        pill("Erklärung zeigen") { self.draft = nil }
      } else if draftFailure != nil {
        pill("Erklärung zeigen") { draftFailure = nil }
        pill("Im Chat weiterfragen", action: onAskInChat)
      } else if !drafting {
        pill("Vorlesen") { readAloud(text) }
        pill("Stopp") { Task { await model.services.stopSpeaking() } }
        pill("Antwort entwerfen") { writeDraft() }
        pill("Im Chat weiterfragen", action: onAskInChat)
      }
    }
  }

  private var loadingRow: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Lumi denkt nach…").font(.system(size: 13)).foregroundStyle(Theme.secondary)
    }
  }

  /// Lange Texte scrollen im Rahmen; die Insel wächst bis zu ihrer Obergrenze mit.
  private func answerText(_ text: String) -> some View {
    CappedScroll(maxHeight: 230) {
      Text(text)
        .font(.system(size: 13)).foregroundStyle(Theme.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }

  /// Nachfrage direkt in der Karte: Return schickt sie mit dem markierten Text in den Chat und sendet sie.
  private var followUpLine: some View {
    HStack(spacing: 6) {
      TextField("Nachfragen …", text: $followUp)
        .textFieldStyle(.plain)
        .font(.system(size: 12)).foregroundStyle(Theme.text)
        .onSubmit(askFollowUp)
      Button(action: askFollowUp) { Image(systemName: "arrow.up") }
        .buttonStyle(RoundIconButtonStyle(size: 20, filled: !followUp.trimmingCharacters(in: .whitespaces).isEmpty))
        .disabled(followUp.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityLabel("Nachfrage senden")
    }
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(Capsule().fill(Theme.capsule))
  }

  private func askFollowUp() {
    let q = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    followUp = ""
    ChatController.shared.input = ExplainCardState.chatPrompt(for: state.original) + q
    model.onOpenTab?(.chat)
    ChatController.shared.send(model)
  }

  /// Entwurf zur markierten Stelle; die Grußformel kommt aus den Einstellungen.
  private func writeDraft() {
    drafting = true
    Task {
      let r = await model.services.draftReply(state.original, signature: DraftSettings.signature)
      drafting = false
      if let text = r.value {
        draft = text
      } else {
        draftFailure = r.errorMessage ?? "Der Entwurf ist gerade nicht möglich."
      }
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  /// Öffnet nur den Mailclient mit dem Text; gesendet wird nichts.
  private func openMail(_ text: String) {
    guard let url = ExplainCardState.mailtoURL(for: text) else { return }
    NSWorkspace.shared.open(url)
  }

  private func pill(_ title: String, action: @escaping () -> Void) -> some View {
    Button { action() } label: {
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised))
    }
    .buttonStyle(.plain)
  }

  /// Vorlesen auf Wunsch; während einer Mitschrift bleibt es still (Hinweis statt Stimme).
  private func readAloud(_ text: String) {
    if model.state?.listening != nil {
      model.showFlash(TabyNotification(title: "Stumm", body: "Während der Mitschrift wird nicht vorgelesen."))
      return
    }
    Task { await model.services.speakReply(text) }
  }
}

/// Schalter „Erklärungen vorlesen“ für die Einstellungen (Standard: an).
struct ExplainSpeakToggle: View {
  @AppStorage(ExplainSettings.speakKey) private var speak = true

  var body: some View {
    PillToggle(title: "Erklärungen vorlesen", isOn: $speak)
  }
}

/// Feld „Grußformel für Antwortentwürfe“ für die Einstellungen (Standard: leer).
struct DraftSignatureField: View {
  @AppStorage(DraftSettings.signatureKey) private var signature = ""

  var body: some View {
    FieldRow(label: "Grußformel für Antwortentwürfe") {
      TextField("Freundliche Grüße", text: $signature)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
    }
  }
}
