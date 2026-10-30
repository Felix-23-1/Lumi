// Reiter "Agenten": Claude-Code-Hook einrichten/entfernen und offene
// Freigabe-Anfrage als Karte mit "Ablehnen" (N) / "Erlauben" (Y).
// docs/decisions/0005-agents-hooks.md
import SwiftUI
import TabyCore

struct AgentsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var installed: Bool?
  @State private var busy = false
  @State private var error: String?
  @State private var showDisconnect = false
  @State private var showPath = false

  init(installed: Bool? = nil) {
    _installed = State(initialValue: installed)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Agenten", subtitle: "Claude Code") {
        installButton
      }
      Text("Hier bestätigst du Aktionen deiner KI-Programmierer (z. B. Claude Code), ohne das Terminal zu öffnen.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 2)
      if let req = model.agentRequests.first {
        AgentRequestCard(request: req) { decision in
          Task { await model.resolveAgentRequest(req.id, decision) }
        }
        .id(req.id)
        .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))))
      } else {
        idleCard.transition(.opacity)
      }
      noticeCard
      if let error { Banner(symbol: "exclamationmark.triangle.fill", text: error, tint: Theme.red) }
    }
    .animation(Theme.spring, value: model.agentRequests)
    .animation(Theme.spring, value: installed)
    .task {
      if installed == nil { installed = await model.services.agentsInstalled() }
    }
    .confirmationDialog("Verbindung zu Claude Code trennen?", isPresented: $showDisconnect, titleVisibility: .visible) {
      Button("Verbindung trennen", role: .destructive) { toggle() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Lumi entfernt seine Zeile aus den Einstellungen von Claude Code. Freigaben fragt Claude Code dann wieder im Terminal.")
    }
  }

  private var installButton: some View {
    Button {
      if installed == true { showDisconnect = true } else { toggle() }
    } label: {
      if installed == true {
        Label("Verbindung trennen", systemImage: "minus.circle")
      } else {
        Label("Einrichten", systemImage: "plus.circle.fill")
      }
    }
    .buttonStyle(PillButtonStyle(kind: installed == true ? .ghost : .primary, compact: true))
    .disabled(busy || installed == nil)
  }

  private var idleCard: some View {
    HStack(alignment: .top, spacing: 10) {
      StatusDot(color: installed == true ? Theme.green : Theme.tertiary)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 4) {
        Text(installed == true ? "Bereit – keine offenen Anfragen" : "Noch nicht eingerichtet")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.text)
        Text(installed == true
          ? "Lumi wird bei Claude-Code-Freigaben (alle Sitzungen) gefragt. Ist Lumi zu, fragt Claude Code wie gewohnt im Terminal."
          : "Nach dem Einrichten fragt Claude Code bei jeder Freigabe zuerst hier nach. Lumi ergänzt dafür eine Zeile in den Einstellungen von Claude Code. Du kannst sie jederzeit wieder entfernen.")
          .font(.system(size: 12))
          .foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if installed != true {
          Button {
            showPath.toggle()
          } label: {
            Label(showPath ? "Details ausblenden" : "Details", systemImage: showPath ? "chevron.up" : "chevron.down")
              .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
          }
          .buttonStyle(.plain)
          if showPath {
            Text("Datei: ~/.claude/settings.json")
              .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .tabyCard()
  }

  private var noticeCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      PillToggle(title: "Meldungen aus Claude Code", isOn: noticeBinding)
      Text("Lumi poppt auf, wenn Claude auf dich wartet oder fertig ist." + (installed == false ? " Dafür oben „Einrichten“ wählen." : ""))
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .tabyCard()
  }

  private var noticeBinding: Binding<Bool> {
    Binding(
      get: { model.state?.settings.claudeNotify ?? true },
      set: { value in
        Task {
          _ = await model.services.updateSettings(SettingsPatch(claudeNotify: value), apiKey: nil)
          await model.refresh()
        }
      }
    )
  }

  private func toggle() {
    busy = true
    error = nil
    Task {
      if installed == true {
        await model.services.agentsUninstall()
        installed = false
      } else {
        let r = await model.services.agentsInstall()
        if r.isOk {
          installed = true
          model.react(.celebrate)
        } else {
          error = r.errorMessage
          model.react(.failed(r.errorMessage ?? ""))
        }
      }
      busy = false
    }
  }
}

/// Freigabe-Karte im Stil der Insel: Status-Punkt, Werkzeug, Befehl in
/// Mono-Kapsel, Arbeitsordner, graues "Ablehnen" und weißes "Erlauben".
struct AgentRequestCard: View {
  let request: AgentPermissionRequest
  let onDecide: (AgentPermissionDecision) -> Void
  @State private var pulse = false

  var body: some View {
    let preview = AgentLogic.preview(request.toolInput)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 7) {
        StatusDot(color: Theme.red)
          .scaleEffect(pulse ? 1.25 : 0.9)
          .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        Text(request.toolName).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
        Text(AgentLogic.headline(request.toolName)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
          .lineLimit(1)
      }
      HStack(alignment: .top, spacing: 6) {
        if preview.isCommand {
          Text("$").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.tertiary)
        }
        Text(preview.text)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Theme.text)
          .lineLimit(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.capsule))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
      if let cwd = AgentLogic.shortPath(request.cwd) {
        Label(cwd, systemImage: "folder")
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      HStack(spacing: 8) {
        Button {
          onDecide(AgentPermissionDecision(behavior: .deny, message: AgentLogic.denyMessage))
        } label: {
          HStack(spacing: 6) { Text("Ablehnen"); shortcutHint("⌘.") }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
        // Mit ⌘: einzelne Buchstaben lösten beim Tippen in anderen Apps versehentlich aus.
        .keyboardShortcut(".", modifiers: [.command])
        Button {
          onDecide(AgentPermissionDecision(behavior: .allow))
        } label: {
          HStack(spacing: 6) { Text("Erlauben"); shortcutHint("⌘⏎", dark: true) }
        }
        .buttonStyle(PillButtonStyle(kind: .primary))
        .keyboardShortcut(.return, modifiers: [.command])
        Spacer()
      }
    }
    .tabyCard(tint: Theme.amber, padding: 14)
    .onAppear { pulse = true }
  }

  /// Tastenkürzel als lesbare Kapsel (größer als die KeyCap-Vorlage).
  private func shortcutHint(_ key: String, dark: Bool = false) -> some View {
    Text(key)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(dark ? Color.black.opacity(0.7) : Theme.text.opacity(0.85))
      .padding(.horizontal, 4)
      .frame(minWidth: 18, minHeight: 16)
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(dark ? Color.black.opacity(0.3) : Color.white.opacity(0.3), lineWidth: 1))
  }
}
