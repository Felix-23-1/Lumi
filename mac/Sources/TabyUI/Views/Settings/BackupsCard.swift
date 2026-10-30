// Einstellungen → Allgemein → Sicherungen: vorhandene Datenbank-Sicherungen listen und zurückspielen.
import AppKit
import SwiftUI
import TabyCore

struct BackupsCard: View {
  /// Lumi startet nach dem Zurückspielen nicht neu: der Nutzer öffnet es selbst.
  static let restartNotice = "Lumi startet neu und stellt die Sicherung wieder her."

  @EnvironmentObject private var model: AppModel
  @Binding var retentionDays: Int
  @State private var backups: [BackupInfo] = []
  @State private var confirming: BackupInfo?
  @State private var importing: String?
  @State private var restoring = false
  @State private var message: (ok: Bool, text: String)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "externaldrive", title: "Sicherungen", count: backups.isEmpty ? nil : backups.count)
      VStack(alignment: .leading, spacing: 4) {
        Text("Automatisch löschen nach").font(.system(size: 13)).foregroundStyle(Theme.text)
        HStack(spacing: 4) {
          ForEach([(1, "1 Tag"), (7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (365, "365 Tage")], id: \.0) { days, label in
            ChoiceChip(text: label, selected: retentionDays == days) { retentionDays = days }
          }
          Spacer(minLength: 0)
        }
        Text("Ältere Sicherungen löscht Lumi; die neueste bleibt immer erhalten.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      if backups.isEmpty {
        Text("Noch keine Sicherung vorhanden. Lumi legt sie automatisch an.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      ForEach(backups) { b in
        HStack(spacing: 8) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
          Text(ViewSupportLogic.backupTitle(b))
            .font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
          Text(ViewSupportLogic.backupSize(b.sizeBytes))
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          Spacer(minLength: 4)
          Button("Zurückspielen") { confirming = b }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(restoring)
            .accessibilityLabel("Sicherung vom \(ViewSupportLogic.backupTitle(b)) zurückspielen")
        }
      }
      HStack(spacing: 8) {
        Button("Alles exportieren …") { exportAll() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button("Aus Datei importieren …") { chooseImport() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(restoring)
        Spacer(minLength: 0)
      }
      Text("Für den Umzug auf einen anderen Mac: Export legt eine Datei mit allen Notizen, Aufgaben und Terminen ab. Schlüssel und Anmeldungen (OpenRouter, Notion, Spotify …) bleiben im Schlüsselbund und müssen dort neu verbunden werden.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      if let message {
        Banner(symbol: message.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", text: message.text,
               tint: message.ok ? Theme.green : Theme.red)
      }
    }
    .tabyCard()
    .task { await reload() }
    .confirmationDialog("Diese Sicherung zurückspielen? Lumi sichert vorher den aktuellen Stand. \(Self.restartNotice)",
                        isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                        titleVisibility: .visible) {
      Button("Zurückspielen", role: .destructive) {
        if let b = confirming { restore(b) }
      }
      Button("Abbrechen", role: .cancel) {}
    }
    .confirmationDialog("Diese Datei importieren? Die Daten dieses Macs werden durch die Datei ersetzt (vorher sichert Lumi den aktuellen Stand). \(Self.restartNotice)",
                        isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                        titleVisibility: .visible) {
      Button("Importieren", role: .destructive) {
        if let path = importing { importFile(path) }
      }
      Button("Abbrechen", role: .cancel) {}
    }
  }

  private func exportAll() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Hier speichern"
    panel.message = "Ordner für die Lumi-Sicherung (z. B. ein USB-Stick oder iCloud Drive)."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    message = nil
    Task {
      let r = await model.services.exportBackup(to: url.path)
      if r.isOk, let path = r.value {
        message = (true, "Gespeichert: \((path as NSString).lastPathComponent). Kopiere die Datei auf den anderen Mac und importiere sie dort.")
        await reload()
      } else {
        message = (false, r.errorMessage ?? "Der Export hat nicht geklappt.")
      }
    }
  }

  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Wählen"
    panel.message = "Lumi-Sicherung wählen (Datei „taby-….sqlite“ vom anderen Mac)."
    if panel.runModal() == .OK, let url = panel.url { importing = url.path }
  }

  private func importFile(_ path: String) {
    restoring = true
    message = nil
    Task {
      let imported = await model.services.importBackup(from: path)
      guard imported.isOk, let name = imported.value else {
        restoring = false
        message = (false, imported.errorMessage ?? "Der Import hat nicht geklappt.")
        return
      }
      restoring = false
      await reload()
      if let b = backups.first(where: { $0.name == name }) { restore(b) }
    }
  }

  private func reload() async {
    backups = await model.services.listBackups()
  }

  private func restore(_ b: BackupInfo) {
    restoring = true
    message = nil
    Task {
      let r = await model.services.restoreBackup(b.name)
      restoring = false
      if r.isOk {
        // Der Neustart wird erst jetzt eingeplant, direkt vor dem Beenden; das Skript öffnet Lumi danach neu.
        message = (true, Self.restartNotice)
        try? RestorePlan.relaunchAfterQuit(appPath: Bundle.main.bundlePath)
        NSApplication.shared.terminate(nil)
      } else {
        message = (false, r.errorMessage ?? "Zurückspielen hat nicht geklappt.")
      }
    }
  }
}
