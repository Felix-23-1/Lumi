// Microsoft (Outlook & Teams) auf der Seite „Verbindungen“: Client-ID mit Anleitung, Anmelden
// per Gerätecode (Code groß, „Öffnen“, „Code kopieren“) und Trennen. Die Client-ID ist öffentlich,
// der Nutzer trägt sie selbst ein. Tokens liegen nur im Schlüsselbund, nie in den Einstellungen.
import AppKit
import SwiftUI
import TabyCore

/// Zustand der Anmeldung in der Karte (nur Oberfläche).
enum MicrosoftCardPhase: Equatable {
  case idle
  case starting
  case waiting(MicrosoftSignIn)
  case failed(String)
}

/// Texte und Regeln der Microsoft-Karte (rein, ohne Ansicht).
enum MicrosoftCardLogic {
  static let title = "Microsoft (Outlook & Teams)"
  static let clientIdFormat = "Die Client-ID hat 36 Zeichen mit Bindestrichen, z. B. 11111111-2222-3333-4444-555555555555."
  static let note = "Im Firmenkonto muss deine IT Lumi einmal freigeben (Kalender, Chats lesen/schreiben, Status). Mit einem privaten Konto geht nur der Kalender, kein Teams."
  static let steps = [
    "„portal.azure.com“ öffnen, dann „App-Registrierungen“ → „Neue Registrierung“.",
    "Name „Lumi“. Bei den Kontotypen „Konten in jedem Organisationsverzeichnis und persönliche Microsoft-Konten“ wählen.",
    "Umleitungs-URI: Plattform „Öffentlicher Client“, Adresse „http://localhost“. Dann „Registrieren“.",
    "Unter „Authentifizierung“ die Option „Öffentliche Clientflows zulassen“ auf Ja setzen und speichern.",
    "Auf der Übersicht die „Anwendungs-(Client-)ID“ kopieren und hier einfügen.",
  ]

  /// Fehlertext zur Client-ID-Eingabe; nil = leer oder gültig.
  static func clientIdProblem(_ draft: String) -> String? {
    let t = draft.trimmingCharacters(in: .whitespaces)
    return t.isEmpty || MicrosoftAuth.isClientId(t) ? nil : clientIdFormat
  }

  static let codeWarning = "Gib den Code nur ein, wenn du ihn gerade in Lumi mit „Anmelden“ angefordert hast."
  static let allowedHosts = ["microsoft.com", "microsoftonline.com", "microsoft.de"]

  /// Nur https-Adressen auf Microsoft-Domains werden im Browser geöffnet (die Adresse kommt von Microsoft).
  static func openURL(_ text: String) -> URL? {
    guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
      return nil
    }
    guard allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
    return url
  }

  /// Host der Anmeldeseite als Text, damit man sieht, wohin der Code gehört.
  static func host(_ text: String) -> String {
    URL(string: text)?.host ?? "unbekannt"
  }
}

struct SettingsMicrosoftCard: View {
  @Binding var form: TabySettings
  /// Angemeldetes Konto (Mail-Adresse); leer = nicht angemeldet.
  let account: String
  @EnvironmentObject private var model: AppModel
  @State private var phase: MicrosoftCardPhase
  @State private var draft: String
  @State private var helpOpen: Bool
  @State private var confirmDisconnect = false
  /// Teams-Chats und Status mit anfordern (standardmäßig aus: nur der Kalender).
  @State private var includeTeams = false
  /// Zählt die Anmeldeläufe: ein abgebrochener Lauf darf kein Ergebnis mehr setzen.
  @State private var run = 0

  init(form: Binding<TabySettings>, account: String, previewPhase: MicrosoftCardPhase? = nil,
       previewHelpOpen: Bool = false) {
    _form = form
    self.account = account
    _phase = State(initialValue: previewPhase ?? .idle)
    _helpOpen = State(initialValue: previewHelpOpen)
    _draft = State(initialValue: form.wrappedValue.microsoftClientId)
  }

  private var hasClientId: Bool { MicrosoftAuth.isClientId(form.microsoftClientId) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "building.2", title: MicrosoftCardLogic.title)
      if account.isEmpty {
        setupContent
      } else {
        connectedContent
      }
      if case .failed(let text) = phase {
        Banner(symbol: "exclamationmark.triangle.fill", text: text, tint: Theme.red)
      }
    }
    .tabyCard()
    .confirmationDialog("Microsoft trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
      Button("Trennen", role: .destructive) { disconnect() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Lumi vergisst die Anmeldung, den Outlook-Kalender und das Teams-Konto. Bei Microsoft bleibt alles unverändert.")
    }
  }

  // MARK: - Nicht angemeldet

  private var setupContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Lumi meldet sich mit deinem Microsoft-Konto an: Outlook-Kalender und Teams-Chats.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      InputCapsule(placeholder: "Client-ID", text: $draft, mono: true) {
        Button("Speichern", action: saveClientId)
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(!canSaveClientId)
      }
      if let problem = MicrosoftCardLogic.clientIdProblem(draft) {
        Text(problem).font(.system(size: 11)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup("Wie bekomme ich eine Client-ID?", isExpanded: $helpOpen) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(MicrosoftCardLogic.steps.enumerated()), id: \.offset) { index, step in
            Text("\(index + 1). \(step)")
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Theme.secondary)
      Text(MicrosoftCardLogic.note)
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      signInArea
    }
  }

  @ViewBuilder private var signInArea: some View {
    switch phase {
    case .waiting(let sign):
      codeArea(sign)
    case .starting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Code wird geholt …").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
    case .idle, .failed:
      VStack(alignment: .leading, spacing: 6) {
        // Nur die Rechte, die gebraucht werden: Kalender immer, Teams auf Wunsch.
        scopeCheckbox("Outlook-Kalender", on: true, enabled: false)
        scopeCheckbox("Teams-Chats und Status", on: includeTeams, enabled: true) { includeTeams.toggle() }
        HStack {
          Spacer(minLength: 0)
          Button("Anmelden", action: signIn)
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(!hasClientId)
        }
      }
      .font(.system(size: 12))
      .foregroundStyle(Theme.secondary)
    }
  }

  /// Kästchen mit Text; „Outlook-Kalender“ ist immer an und gesperrt.
  private func scopeCheckbox(_ title: String, on: Bool, enabled: Bool, toggle: @escaping () -> Void = {}) -> some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        Image(systemName: on ? "checkmark.square.fill" : "square")
          .foregroundStyle(on ? Theme.text : Theme.tertiary)
        Text(title).foregroundStyle(enabled ? Theme.text : Theme.secondary)
      }
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  /// Der Gerätecode: groß, mit „Öffnen“ und „Code kopieren“; Lumi wartet im Hintergrund.
  private func codeArea(_ sign: MicrosoftSignIn) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Öffne die Microsoft-Seite und gib diesen Code ein:")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      Text(sign.userCode)
        .font(.system(size: 26, weight: .bold, design: .monospaced))
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
      Text("Seite: \(MicrosoftCardLogic.host(sign.verificationUrl))")
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
        .textSelection(.enabled)
      Text(MicrosoftCardLogic.codeWarning)
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Öffnen") {
          if let url = MicrosoftCardLogic.openURL(sign.verificationUrl) { NSWorkspace.shared.open(url) }
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        .disabled(MicrosoftCardLogic.openURL(sign.verificationUrl) == nil)
        Button("Code kopieren") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(sign.userCode, forType: .string)
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Spacer(minLength: 4)
        ProgressView().controlSize(.small)
        Button("Abbrechen", action: cancelSignIn)
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      Text("Lumi wartet, bis du bestätigt hast.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
    }
  }

  // MARK: - Angemeldet

  private var connectedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.green)
        Text("Angemeldet als \(account)")
          .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
      }
      Text("Der Outlook-Kalender ist verbunden. Teams-Chats verbindest du unter Nachrichten.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer(minLength: 0)
        Button("Trennen") { confirmDisconnect = true }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      }
    }
  }

  // MARK: - Aktionen

  private var canSaveClientId: Bool {
    let value = draft.trimmingCharacters(in: .whitespaces)
    return value != form.microsoftClientId && MicrosoftAuth.isClientId(value)
  }

  private func saveClientId() {
    let value = draft.trimmingCharacters(in: .whitespaces)
    form.microsoftClientId = value
    Task {
      _ = await model.services.updateSettings(SettingsPatch(microsoftClientId: value), apiKey: nil)
      await model.refresh()
    }
  }

  private func signIn() {
    run += 1
    let current = run
    phase = .starting
    Task {
      let start = await model.services.startMicrosoftSignIn(includeTeams: includeTeams)
      guard current == run else { return }
      guard let sign = start.value else {
        phase = .failed(start.errorMessage ?? "Die Anmeldung konnte nicht begonnen werden.")
        return
      }
      phase = .waiting(sign)
      let done = await model.services.finishMicrosoftSignIn()
      guard current == run else { return }
      if let mail = done.value {
        form.microsoftAccount = mail
        phase = .idle
      } else {
        phase = .failed(done.errorMessage ?? "Die Anmeldung ist fehlgeschlagen.")
      }
      await model.refresh()
    }
  }

  /// Bricht die Anmeldung ab: die Abfragen enden, ein Ergebnis wird nicht mehr übernommen.
  private func cancelSignIn() {
    run += 1
    phase = .idle
    Task { await model.services.cancelMicrosoftSignIn() }
  }

  private func disconnect() {
    Task {
      run += 1
      _ = await model.services.disconnectMicrosoft()
      form.microsoftAccount = ""
      phase = .idle
      await model.refresh()
    }
  }
}
