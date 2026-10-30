// Seite „Verbindungen“: Statusübersicht aller Dienste und die Obsidian-Karte.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  var connectionsSection: some View {
    let state = privacyState ?? model.state ?? AppState()
    return VStack(alignment: .leading, spacing: 10) {
      ConnectionsView(cards: ConnectionLogic.cards(state), onOpen: { p in
        withAnimation(Theme.spring) { page = p }
      }, onObsidian: { chooseVaultFolder() })
      ObsidianCard(form: $form, noteCount: state.vaultNoteCount, onChoose: { chooseVaultFolder() }, onSave: { commit() })
      ShareCard(shares: form.networkShares, states: state.shareStates, onToggle: { id, mounted in await toggleShare(id, mounted: mounted) },
                onSave: { saveShare($0) }, onDelete: { id in await deleteShare(id) })
      SettingsMicrosoftCard(form: $form, account: state.settings.microsoftAccount)
    }
  }

  func chooseVaultFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Wählen"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    form.markdownVaultPath = url.path
    commit()
  }
}

/// Obsidian: verbunden = Vault-Ordner gewählt. Lumi schreibt nur in den Unterordner `vaultWriteFolder`.
struct ObsidianCard: View {
  @Binding var form: TabySettings
  let noteCount: Int
  let onChoose: () -> Void
  let onSave: () -> Void
  @State private var folderDraft = ""
  @State private var folderError: String?
  @State private var confirmDisconnect = false

  private var connected: Bool { ObsidianLogic.isConnected(path: form.markdownVaultPath) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "book.closed", title: "Obsidian")
      if connected {
        connectedContent
      } else {
        Text("Verbinde deinen Obsidian-Ordner (Vault). Lumi kann dann in deinen Notizen suchen und auf Wunsch Notizen dort ablegen.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Ordner wählen…", action: onChoose)
            .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
      }
    }
    .tabyCard()
    .onAppear { folderDraft = form.vaultWriteFolder }
    .confirmationDialog("Obsidian trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
      Button("Trennen", role: .destructive) {
        form.markdownVaultPath = ""
        onSave()
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Lumi vergisst den Ordner. Deine Notizen in Obsidian bleiben unverändert.")
    }
  }

  private var connectedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "folder").foregroundStyle(Theme.secondary)
        Text((form.markdownVaultPath as NSString).lastPathComponent)
          .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        Spacer(minLength: 4)
        Text(ObsidianLogic.noteCountText(noteCount))
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      Text(form.markdownVaultPath)
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
        .lineLimit(1).truncationMode(.middle)
      VStack(alignment: .leading, spacing: 4) {
        Text("Lumi schreibt in Unterordner")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        InputCapsule(placeholder: "Lumi", text: $folderDraft) {
          Button("Übernehmen", action: applyFolder)
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(folderDraft.trimmingCharacters(in: .whitespaces) == form.vaultWriteFolder)
        }
        if let folderError {
          Banner(symbol: "exclamationmark.triangle.fill", text: folderError, tint: Theme.red)
        }
      }
      HStack(spacing: 8) {
        Button("Ordner ändern", action: onChoose)
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Spacer(minLength: 0)
        Button("Trennen") { confirmDisconnect = true }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      }
    }
  }

  private func applyFolder() {
    if let error = ObsidianLogic.writeFolderError(folderDraft) {
      folderError = error
      return
    }
    folderError = nil
    form.vaultWriteFolder = folderDraft.trimmingCharacters(in: .whitespaces)
    onSave()
  }
}
