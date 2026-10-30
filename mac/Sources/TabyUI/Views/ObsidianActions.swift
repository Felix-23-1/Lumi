// Obsidian-Aktionen: Notizen in den Vault schreiben (Notizen, Datei-Karte im Chat, Besprechung).
// Schreiben geht nur über `services.saveVaultNote` in den Lumi-Unterordner. Ergebnis als Einblendung.
import Foundation
import TabyCore

@MainActor
enum ObsidianActions {
  /// Eine Notiz ablegen. Gibt die Fehlermeldung zurück (nil = erledigt).
  @discardableResult
  static func saveNote(_ model: AppModel, title: String, content: String) async -> String? {
    let r = await model.services.saveVaultNote(title: title, content: content, append: false)
    if let error = r.errorMessage {
      model.showFlash(TabyNotification(title: "Nicht in Obsidian abgelegt", body: error))
      return await ViewActions.finish(model, error, success: nil)
    }
    model.showFlash(TabyNotification(title: "In Obsidian abgelegt: \(r.value?.name ?? title)", body: "Im Ordner „\(folder(model))“ des Vaults"))
    return await ViewActions.finish(model, nil, success: .itemAdded)
  }

  /// Abgelegte Dateien: Text lesen (außerhalb des Hauptthreads), dann als Notiz mit Dateinamen ohne Endung schreiben.
  static func saveDroppedFiles(_ model: AppModel) async {
    var saved: [String] = []
    var firstError: String?
    for path in model.takeDroppedFiles() {
      let url = URL(fileURLWithPath: path)
      let name = url.lastPathComponent
      let extracted = await Task.detached { () -> Result<String, Error> in
        Result { try FileTextExtractor.extract(url) }
      }.value
      switch extracted {
      case .failure:
        if firstError == nil { firstError = "„\(name)“ konnte ich nicht lesen." }
      case .success(let text):
        let title = (name as NSString).deletingPathExtension
        let r = await model.services.saveVaultNote(title: title, content: text, append: false)
        if let error = r.errorMessage {
          if firstError == nil { firstError = error }
        } else {
          saved.append(r.value?.name ?? name)
        }
      }
    }
    if let firstError {
      model.showFlash(TabyNotification(title: "Nicht in Obsidian abgelegt", body: firstError))
      _ = await ViewActions.finish(model, firstError, success: nil)
    } else if !saved.isEmpty {
      let title = saved.count == 1 ? "In Obsidian abgelegt: \(saved[0])" : "\(saved.count) Notizen in Obsidian abgelegt"
      model.showFlash(TabyNotification(title: title, body: "Im Ordner „\(folder(model))“ des Vaults"))
      _ = await ViewActions.finish(model, nil, success: .itemAdded)
    } else {
      await model.refresh()
    }
  }

  /// Name des Lumi-Unterordners im Vault (Standard „Lumi“).
  static func folder(_ model: AppModel) -> String {
    let f = (model.state?.settings.vaultWriteFolder ?? "").trimmingCharacters(in: .whitespaces)
    return f.isEmpty ? "Lumi" : f
  }
}
