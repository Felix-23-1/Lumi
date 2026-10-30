// Seite „Updates“: Version, verfügbares Update mit Notizen und ein Knopf. Die Update-Adresse liegt
// eingeklappt unter „Erweitert: andere Quelle“; ohne Eingabe gilt die GitHub-Adresse von Lumi.
import AppKit
import SwiftUI
import TabyCore

/// Anzeige-Logik der Updates-Seite (ohne Ansicht, in den Prüfungen abgedeckt).
enum UpdatesPageLogic {
  /// „Lumi Version 2.527“ (ohne Build: „Lumi Version 2.0“).
  static func currentLine(build: Int) -> String { "Lumi Version \(AppUpdate.versionName(build: build))" }

  /// „Update verfügbar – Version 2.531 (vom 18.10.)“.
  static func availableTitle(_ u: AppUpdate) -> String {
    "Update verfügbar – Version \(u.versionName) (vom \(shortDate(u.date)))"
  }

  /// „2026-10-18T10:42“ → „18.10.“; ein anderes Format bleibt unverändert.
  static func shortDate(_ iso: String) -> String {
    let parts = iso.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return iso }
    return "\(parts[2]).\(parts[1])."
  }

  /// Notizen zum Anzeigen; fehlen sie oder sind leer, nil.
  static func notesText(_ notes: String?) -> String? {
    guard let text = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }

  /// Die Quelle, die wirklich benutzt wird: das Feld oder, wenn es leer ist, die GitHub-Adresse.
  static func effectiveSource(_ field: String) -> String {
    let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppUpdate.defaultSource : trimmed
  }
}

/// Inhalt der Updates-Seite. Bekommt alle Werte als Parameter, damit Vorschauen ohne Modell auskommen.
struct UpdatesPanel: View {
  let currentBuild: Int
  let update: AppUpdate?
  @Binding var source: String
  var dirty = false
  var checking = false
  var installing = false
  var percent = 0
  var message: (ok: Bool, text: String)?
  var onCheck: () -> Void = {}
  var onInstall: () -> Void = {}
  @State private var advancedOpen: Bool
  /// „Lumi ist aktuell.“ erst nach einer Prüfung, die in diesem Fenster erfolgreich war.
  @State private var checked = false

  init(currentBuild: Int, update: AppUpdate?, source: Binding<String>, advancedOpen: Bool = false,
       dirty: Bool = false, checking: Bool = false, installing: Bool = false, percent: Int = 0,
       message: (ok: Bool, text: String)? = nil, onCheck: @escaping () -> Void = {},
       onInstall: @escaping () -> Void = {}) {
    self.currentBuild = currentBuild; self.update = update; self._source = source
    self.dirty = dirty; self.checking = checking; self.installing = installing; self.percent = percent
    self.message = message; self.onCheck = onCheck; self.onInstall = onInstall
    self._advancedOpen = State(initialValue: advancedOpen)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(symbol: "arrow.down.circle", title: "Updates")
      Text(UpdatesPageLogic.currentLine(build: currentBuild))
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
      if let u = update {
        availableBlock(u)
      } else {
        Text(checked ? "Lumi ist aktuell." : "Noch nicht geprüft.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        Button(action: onCheck) {
          HStack(spacing: 5) {
            if checking { ProgressView().controlSize(.mini) } else { Image(systemName: "magnifyingglass") }
            Text("Nach Updates suchen")
          }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(checking || installing || dirty)
      }
      if let m = message {
        Text(m.text).font(.system(size: 12)).foregroundStyle(m.ok ? Theme.green : Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      advanced
      .onChange(of: checking) { wasChecking, isChecking in
        // Erfolgreich beendet (ohne Fehlermeldung): ab jetzt „aktuell“, sonst bleibt es offen.
        if wasChecking && !isChecking && message == nil && update == nil { checked = true }
      }
      if dirty {
        Text("Wird gleich gespeichert, dann suchen.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
    }
    .tabyCard()
  }

  private func availableBlock(_ u: AppUpdate) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(UpdatesPageLogic.availableTitle(u)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
      if let notes = UpdatesPageLogic.notesText(u.notes) {
        Text(notes).font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(action: onInstall) {
        HStack(spacing: 5) {
          if installing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.to.line") }
          Text(installing ? "Lädt…" : "Jetzt aktualisieren")
        }
      }
      .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      .disabled(installing || dirty)
      if installing {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: Double(percent), total: 100)
          Text("Lädt herunter … \(percent) %").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.blue.opacity(0.14)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.blue.opacity(0.5), lineWidth: 1))
  }

  private var advanced: some View {
    DisclosureGroup(isExpanded: $advancedOpen) {
      VStack(alignment: .leading, spacing: 6) {
        InputCapsule(placeholder: AppUpdate.defaultSource, text: $source, mono: true)
        Text("GitHub-Adresse von Lumi (oder Ordner mit version.json und Taby.dmg). Leer = Standard.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 4)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Erweitert: andere Quelle").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        Text("Quelle: \(UpdatesPageLogic.effectiveSource(source))")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
  }
}

extension SettingsView {
  var updateSection: some View {
    UpdatesPanel(
      currentBuild: CoreServices.bundleBuild(), update: model.state?.update, source: $form.updateSource,
      dirty: dirty, checking: updateChecking, installing: updateInstalling,
      percent: model.state?.update?.downloadPercent ?? 0, message: updateMessage,
      onCheck: {
        updateChecking = true
        updateMessage = nil
        Task {
          let r = await model.services.checkForUpdate()
          await model.refresh()
          // Meldung vor dem Ende der Prüfung setzen: die Ansicht wertet „fertig ohne Fehler“ dann richtig aus.
          if case .failure(_, let e) = r { updateMessage = (false, e) }
          updateChecking = false
        }
      },
      onInstall: {
        updateInstalling = true
        updateMessage = nil
        Task {
          let r = await model.services.installUpdate()
          switch r {
          case .ok: NSApplication.shared.terminate(nil)
          case .failure(_, let e):
            updateInstalling = false
            updateMessage = (false, e)
          }
        }
      })
  }
}
