// Markdown-Vault im Chat, in der Suche und beim Ablegen: Werkzeuge `read_vault_note` und
// `save_vault_note` (nur nach Bestätigung) sowie Treffer aus dem Ordner. Fremder Text (Dateiname,
// Inhalt) geht nur verpackt zum Modell.
import Foundation

extension CoreServices {
  /// Kennzeichen der Vault-Treffer in `SearchHit.id` (danach der absolute Pfad der Datei).
  public static let vaultHitPrefix = MarkdownVault.hitPrefix

  static let noVaultMessage = "Kein Obsidian-Ordner verbunden – Einstellungen → Verbindungen (mit „Erweitert anzeigen“) → Obsidian."

  /// Der Lumi-Ordner im Vault (Vorgabe „Lumi“, wenn leer).
  static func vaultLumiFolder(_ configured: String) -> String {
    let t = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "Lumi" : t
  }

  /// Zielordner wie beim Schreiben: der Lumi-Ordner oder ein Unterordner davon. nil, wenn ungültig.
  static func vaultTargetFolder(configured: String, typed: String?) -> String? {
    let lumi = vaultLumiFolder(configured)
    let t = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let target = t.isEmpty ? lumi : t
    guard target == lumi || target.hasPrefix(lumi + "/"), MarkdownVault.isSafeFolder(target) else { return nil }
    return target
  }

  /// Werkzeuge nur, wenn ein Ordner gewählt ist.
  var vaultToolDefs: [ToolDef] {
    guard !settings.markdownVaultPath.isEmpty else { return [] }
    return [ToolDef(name: "read_vault_note",
                    description: "Liest eine Markdown-Notiz aus dem Wissensordner des Nutzers. Pfad relativ zum Ordner (wie aus der Suche).",
                    parameters: ToolSchema.object(["path": ToolSchema.string("Pfad der .md-Datei im Ordner, z. B. \"Projekte/Plan.md\"")],
                                                  required: ["path"])),
            ToolDef(name: "save_vault_note",
                    description: "Legt eine Notiz in Obsidian ab, nur im Lumi-Ordner oder einem Unterordner davon. Der Nutzer bestätigt vorher. append true hängt den Inhalt an eine gleichnamige Notiz an.",
                    parameters: ToolSchema.object(["title": ToolSchema.string("Titel; wird zum Dateinamen"),
                                                   "content": ToolSchema.string("Inhalt in Markdown"),
                                                   "append": .object(["type": .string("boolean"),
                                                                      "description": .string("true: an die gleichnamige Notiz anhängen")]),
                                                   "folder": ToolSchema.string("Unterordner im Lumi-Ordner (optional)")],
                                                  required: ["title", "content"]))]
  }

  /// Führt `read_vault_note` aus. Bei `save_vault_note` nur die Vorprüfung; nil lässt das Werkzeug
  /// zur Bestätigung in der Insel weiterlaufen (ToolRegistry.confirmationRequired).
  func vaultTool(_ name: String, _ argsJson: String) -> JSONValue? {
    if name == "save_vault_note" {
      guard !settings.markdownVaultPath.isEmpty else { return ToolJSON.failure(code: "NO_VAULT", error: Self.noVaultMessage) }
      let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) ?? .object([:])
      if (args["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return ToolJSON.failure(code: "INVALID_ARGS", error: "Titel fehlt.")
      }
      return nil
    }
    guard name == "read_vault_note" else { return nil }
    let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) ?? .object([:])
    guard let note = MarkdownVault.readNote(root: settings.markdownVaultPath, path: args["path"]?.stringValue ?? "")
    else {
      return ToolJSON.failure(code: "NOT_FOUND", error: "Keine Markdown-Notiz im Wissensordner unter diesem Pfad.")
    }
    return ToolJSON.ok(["path": .string(ForeignContent.wrap(note.path)),
                        "content": .string(ForeignContent.wrap(note.text)),
                        "truncated": .bool(note.truncated), "note": .string(ForeignContent.note)])
  }

  /// Treffer aus dem Wissensordner (leer ohne Ordner). Läuft außerhalb des Hauptakteurs.
  func vaultSearch(_ query: String) async -> [SearchHit] {
    let root = settings.markdownVaultPath
    guard !root.isEmpty else { return [] }
    let vault = self.vault
    return await Blocking.run { vault.search(root: root, query: query) }
  }

  /// Notizen im Vault für die Anzeige: nur der letzte Stand. Der Ordner wird im Hintergrund höchstens
  /// alle 60 s neu gelesen, nie beim Aufbau des Zustands.
  func currentVaultNoteCount() -> Int {
    vault.noteCountForState(root: settings.markdownVaultPath, now: clock.now())
  }

  /// Schreibt eine Notiz in den Lumi-Ordner oder einen Unterordner davon und aktualisiert den Index.
  /// Protokolliert als Nutzeraktion; aufgerufen nur nach Bestätigung (oder aus der Oberfläche).
  func writeVaultNote(title: String, content: String, append: Bool, folder: String?) async -> ToolResult<FileHit> {
    let root = settings.markdownVaultPath
    guard !root.isEmpty else { return .failure(code: "NO_VAULT", error: Self.noVaultMessage) }
    let lumi = Self.vaultLumiFolder(settings.vaultWriteFolder)
    guard let target = Self.vaultTargetFolder(configured: settings.vaultWriteFolder, typed: folder) else {
      return .failure(code: "INVALID_ARGS", error: "Notizen gehen nur in den Ordner „\(lumi)“ oder seine Unterordner.")
    }
    let now = clock.now()
    let vault = self.vault
    let result: ToolResult<FileHit>
    do {
      let hit = try await Blocking.run { () throws -> FileHit in
        let hit = try MarkdownVault.write(root: root, title: title, content: content, append: append,
                                          folder: target, now: now)
        vault.rescan(root: root, now: now)
        return hit
      }
      result = .ok(hit)
    } catch let e as MarkdownVault.WriteError {
      result = .failure(code: e == .invalidFolder ? "INVALID_ARGS" : "ERROR", error: e.message)
    } catch {
      result = .failure(code: "ERROR", error: MarkdownVault.WriteError.failed.message)
    }
    audit(actor: AuditActor.user, tool: "save_vault_note", confirmed: true, ok: result.isOk)
    return result
  }

  /// Oberflächen-Weg: Notiz im Lumi-Ordner.
  public func saveVaultNote(title: String, content: String, append: Bool) async -> ToolResult<FileHit> {
    await writeVaultNote(title: title, content: content, append: append, folder: nil)
  }

  /// Führt eine vom Nutzer bestätigte `save_vault_note`-Anfrage aus (Argumente wie gemeldet).
  func confirmedVaultNote(_ args: JSONValue) async -> ToolResult<Empty> {
    let out = await writeVaultNote(title: args["title"]?.stringValue ?? "", content: args["content"]?.stringValue ?? "",
                                   append: args["append"]?.boolValue ?? false, folder: args["folder"]?.stringValue)
    switch out {
    case .ok: return .ok(Empty())
    case .failure(let code, let error): return .failure(code: code, error: error)
    }
  }
}
