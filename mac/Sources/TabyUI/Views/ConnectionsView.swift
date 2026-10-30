// Reiter "Verbindungen" in den Einstellungen: eine Karte je Dienst mit Status.
// "Einrichten"/"Verwalten" springt nur zur bestehenden Einrichtung; iMessage verbindet
// und trennt direkt über model.services (danach Zustand neu laden).
import SwiftUI
import TabyCore

struct ConnectionsView: View {
  let cards: [ConnectionCard]
  var onOpen: (SettingsPage) -> Void = { _ in }
  /// Obsidian-Karte: Ordner-Dialog öffnen.
  var onObsidian: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Dienste, mit denen Lumi verbunden ist.")
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
      ForEach(cards) { card in
        ConnectionRow(card: card, onOpen: onOpen, onObsidian: onObsidian)
      }
    }
  }
}

private struct ConnectionRow: View {
  let card: ConnectionCard
  let onOpen: (SettingsPage) -> Void
  let onObsidian: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var busy = false
  @State private var failure: String?
  @State private var formOpen = false
  @State private var server = ""
  @State private var userName = ""
  @State private var password = ""
  @State private var recoveryKey = ""
  @State private var slackToken = ""

  /// Laufende Geräte-Bestätigung (nur die Element-Karte zeigt sie).
  private var verification: MessengerVerification? { model.state?.messengerVerification }

  private var tint: Color {
    switch card.status {
    case .connected: Theme.green
    case .off, .soon: Theme.tertiary
    case .problem: Theme.red
    }
  }

  private var word: String {
    switch card.status {
    case .connected: "Verbunden"
    case .off: "Aus"
    case .problem: "Problem"
    case .soon: "Bald"
    }
  }

  private var buttonTitle: String {
    switch card.action {
    case .open: card.status == .off ? "Einrichten" : "Verwalten"
    case .obsidian: card.status == .connected ? "Ordner ändern" : "Ordner wählen"
    case .connectMessenger: "Verbinden"
    case .disconnectMessenger, .matrixUnlock: "Trennen"
    case .matrixForm, .slackForm: formOpen ? "Schließen" : "Verbinden"
    case .unavailable: "Bald verfügbar"
    }
  }

  private var buttonKind: PillKind {
    switch card.action {
    case .open: card.status == .off ? .primary : .secondary
    case .obsidian: card.status == .connected ? .secondary : .primary
    case .connectMessenger, .matrixForm, .slackForm: .primary
    case .disconnectMessenger, .matrixUnlock, .unavailable: .secondary
    }
  }

  private func run() {
    switch card.action {
    case .open(let page):
      onOpen(page)
    case .obsidian:
      onObsidian()
    case .matrixForm, .slackForm:
      formOpen.toggle()
    case .connectMessenger(let service):
      Task {
        busy = true
        let r = await model.services.connectMessenger(MessengerLogin(service: service))
        failure = r.errorMessage
        busy = false
        await model.refresh()
      }
    case .disconnectMessenger(let id), .matrixUnlock(let id):
      Task {
        busy = true
        await model.services.disconnectMessenger(id)
        failure = nil
        busy = false
        await model.refresh()
      }
    case .unavailable:
      break
    }
  }

  private func connectMatrix() {
    let login = MessengerLogin(service: .matrix, server: MatrixLoginInput.homeserver(server),
                               user: MatrixLoginInput.user(userName), secret: password)
    password = ""
    Task {
      busy = true
      let r = await model.services.connectMessenger(login)
      failure = r.errorMessage
      busy = false
      if r.isOk { formOpen = false; server = ""; userName = "" }
      await model.refresh()
    }
  }

  private func startVerification(_ accountId: String) {
    Task {
      busy = true
      let r = await model.services.startMessengerVerification(accountId)
      failure = r.errorMessage
      busy = false
      await model.refresh()
    }
  }

  private func answerVerification(_ accountId: String, matches: Bool) {
    Task {
      busy = true
      let r = await model.services.answerMessengerVerification(accountId, matches: matches)
      failure = r.errorMessage
      busy = false
      await model.refresh()
    }
  }

  private func cancelVerification(_ accountId: String) {
    Task {
      await model.services.cancelMessengerVerification(accountId)
      await model.refresh()
    }
  }

  private func connectSlack() {
    let token = slackToken
    slackToken = ""
    Task {
      busy = true
      let r = await model.services.connectMessenger(MessengerLogin(service: .slack, secret: token))
      failure = r.errorMessage
      busy = false
      if r.isOk { formOpen = false }
      await model.refresh()
    }
  }

  private func unlockMatrix(_ accountId: String) {
    let key = recoveryKey
    recoveryKey = ""
    Task {
      busy = true
      let r = await model.services.unlockMessenger(accountId, recoveryKey: key)
      failure = r.errorMessage
      busy = false
      await model.refresh()
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: card.symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 24, height: 24)
          .background(Circle().fill(tint.opacity(0.15)))
        VStack(alignment: .leading, spacing: 1) {
          Text(card.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
          Text(card.detail)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        HStack(spacing: 5) {
          StatusDot(color: tint, size: 6)
          Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
        }
        .fixedSize()
        Button(buttonTitle, action: run)
          .buttonStyle(PillButtonStyle(kind: buttonKind, compact: true))
          .disabled(busy || card.action == .unavailable)
      }
      if card.action == .matrixForm && formOpen {
        matrixLoginForm
      }
      if card.action == .slackForm && formOpen {
        slackLoginForm
      }
      if case .matrixUnlock(let id) = card.action {
        matrixUnlockForm(id)
      }
      if card.id == MessengerService.matrix.rawValue, verification?.phase == .done {
        Label("Bestätigt", systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.green)
      }
      if let failure {
        Banner(symbol: "exclamationmark.triangle.fill", text: failure, tint: Theme.red)
      }
    }
    .tabyCard()
  }

  // MARK: - Slack

  private var slackLoginForm: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Lumi nutzt eine eigene Slack-App in deinem Workspace. Der Zugangscode bleibt im Schlüsselbund des Mac.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      DisclosureGroup("Anleitung") {
        VStack(alignment: .leading, spacing: 4) {
          Text("1. api.slack.com/apps öffnen → „Create New App“ → „From scratch“. Name „Lumi“, eigenen Workspace wählen.")
          Text("2. „OAuth & Permissions“ → „User Token Scopes“: channels:history, channels:read, groups:history, groups:read, im:history, im:read, mpim:history, mpim:read, users:read, chat:write.")
          Text("3. „Install to Workspace“ (je nach Workspace muss ein Admin zustimmen).")
          Text("4. „User OAuth Token“ (xoxp-…) kopieren und hier einfügen.")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Theme.secondary)
      InputCapsule(placeholder: "Slack-Zugangscode (xoxp-…)", text: $slackToken, secure: true) { EmptyView() }
      HStack {
        Spacer()
        Button("Verbinden", action: connectSlack)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || slackToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  // MARK: - Element / Matrix

  private var matrixLoginForm: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Homeserver: steht in Element unter Einstellungen → Hilfe & Info → Erweitert (meist matrix.org). Den Sicherheitsschlüssel fragt Lumi danach ab.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Lumi erscheint als neues Gerät „Lumi (Mac)“ in Elements Sitzungsliste.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
      InputCapsule(placeholder: "matrix.org oder https://matrix.firma.de", text: $server) { EmptyView() }
      InputCapsule(placeholder: "Benutzername oder @name:server", text: $userName) { EmptyView() }
      InputCapsule(placeholder: "Passwort", text: $password, secure: true) { EmptyView() }
      HStack {
        Spacer()
        Button("Verbinden", action: connectMatrix)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || !MatrixLoginInput.canSubmit(server: server, user: userName, password: password))
      }
    }
  }

  private func matrixUnlockForm(_ accountId: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      verificationSection(accountId)
      Text("oder Sicherheitsschlüssel eingeben")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondary)
      Text("Der Sicherheitsschlüssel (auch Wiederherstellungsschlüssel, beginnt meist mit „Es“) entsperrt die verschlüsselten Chats. Element zeigt ihn nicht erneut an: es ist der beim Einrichten der Sicherung gespeicherte Schlüssel. Verloren? In Element unter Einstellungen → Verschlüsselung → Wiederherstellung (ältere Versionen: Sicherheit & Datenschutz → Sicheres Backup) einen neuen erzeugen.")
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      InputCapsule(placeholder: "Sicherheitsschlüssel", text: $recoveryKey, secure: true) { EmptyView() }
      HStack {
        Spacer()
        Button("Entsperren") { unlockMatrix(accountId) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(busy || MatrixLoginInput.recoveryKey(recoveryKey).isEmpty)
      }
    }
  }

  /// Bestätigung von einem anderen Gerät: je nach Phase Knopf, Wartehinweis, Emojis oder Ergebnis.
  @ViewBuilder
  private func verificationSection(_ accountId: String) -> some View {
    if let v = verification, v.accountId == accountId {
      switch v.phase {
      case .waitingForOther:
        verificationText("Öffne Element auf deinem Handy oder PC und nimm die Anfrage von „Lumi (Mac)“ an.")
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Spacer()
          Button("Abbrechen") { cancelVerification(accountId) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
      case .showEmojis:
        verificationText("Siehst du dieselben Symbole auf dem anderen Gerät?")
        HStack(alignment: .top, spacing: 6) {
          ForEach(Array(v.emojis.enumerated()), id: \.offset) { _, emoji in
            VStack(spacing: 2) {
              Text(emoji.symbol).font(.system(size: 24))
              Text(emoji.name)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity)
          }
        }
        HStack {
          Spacer()
          Button("Stimmt nicht") { answerVerification(accountId, matches: false) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          Button("Stimmt überein") { answerVerification(accountId, matches: true) }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
      case .confirming:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Wird abgeschlossen…")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
      case .done:
        EmptyView()  // steht als „Bestätigt“ unter der Karte
      case .cancelled, .failed:
        Banner(symbol: "exclamationmark.triangle.fill", text: v.message ?? "Die Bestätigung ist abgebrochen.", tint: Theme.red)
        HStack {
          Spacer()
          Button("Erneut versuchen") { startVerification(accountId) }
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            .disabled(busy)
        }
      }
    } else {
      HStack {
        Spacer()
        Button { startVerification(accountId) } label: {
          Label("Mit anderem Gerät bestätigen", systemImage: "checkmark.shield")
        }
        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        .disabled(busy)
      }
    }
  }

  private func verificationText(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(Theme.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
