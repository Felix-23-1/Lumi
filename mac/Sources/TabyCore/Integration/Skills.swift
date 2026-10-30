// Skills („Mod ohne Code“): ein Mod aus Anleitung (prompt), Chat-Befehl (command) und
// erlaubten Werkzeugen. Ein Skill-Lauf ist ein normaler Chat-Durchgang (chatTurn) mit
// Anleitung im Systemprompt und eingeschränkter Werkzeugliste – keine Hintergrundarbeit.
import Foundation

extension CoreServices {
  /// Ohne eigene Werkzeugliste darf ein Skill nur diese lesenden Werkzeuge sehen.
  static let readOnlyToolPrefixes = ["list_", "get_", "show_", "search_"]

  /// Welche Werkzeuge ein Skill angeboten bekommt: genau seine Liste, sonst nur lesende.
  static func skillToolFilter(_ m: ModManifest) -> (String) -> Bool {
    let allowed = Set(m.tools ?? [])
    if allowed.isEmpty {
      return { name in CoreServices.readOnlyToolPrefixes.contains { name.hasPrefix($0) } }
    }
    return { allowed.contains($0) }
  }

  /// Zusatz für den Systemprompt: die Anleitung des Skills.
  static func skillNote(_ m: ModManifest) -> String {
    "Skill „\(m.name)“: \(m.prompt?.trimmedText ?? "")"
  }

  /// Nachricht des Nutzers im Verlauf: „/<command> <Eingabe>“.
  static func skillUserText(_ m: ModManifest, input: String) -> String {
    "/\(m.command ?? m.id) \(input.trimmedText)".trimmedText
  }

  /// „/befehl Text“ → freigegebener Skill und Eingabe. Unbekannter Befehl oder kein Skill: nil (normaler Chat).
  func skillCall(_ text: String) -> (id: String, input: String)? {
    guard text.hasPrefix("/") else { return nil }
    let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard let word = parts.first.map({ $0.lowercased() }) else { return nil }
    let input = parts.count > 1 ? String(parts[1]) : ""
    let found = ((try? mods.all()) ?? []).first { info in
      info.manifest.kind == .skill && info.enabled && info.approved && (info.manifest.command ?? info.id) == word
    }
    return found.map { ($0.id, input) }
  }

  /// Führt einen eingeschalteten, freigegebenen Skill aus. Ergebnis landet im Chat.
  public func runSkill(_ id: String, input: String) async throws -> [ChatMessage] {
    try await runSkill(id, input: input, onPartial: nil)
  }

  func runSkill(_ id: String, input: String, onPartial: (@MainActor (String) -> Void)?) async throws -> [ChatMessage] {
    guard (try? mods.isRunnable(id)) == true, let m = try? mods.manifest(id), m.kind == .skill else {
      throw LlmError(.unknown, "Dieser Skill ist aus oder noch nicht freigegeben.")
    }
    messenger.noteIslandUse()
    do {
      let msgs = try await chatTurn(Self.skillUserText(m, input: input), systemNote: Self.skillNote(m),
                                    toolFilter: Self.skillToolFilter(m), onPartial: onPartial)
      audit(actor: AuditActor.skill, tool: id, confirmed: false, ok: true, summary: "Skill ausgeführt")
      return msgs
    } catch {
      audit(actor: AuditActor.skill, tool: id, confirmed: false, ok: false, summary: "Skill ausgeführt")
      throw error
    }
  }

  /// Legt einen Skill an – ausgeschaltet, ohne Code; die Freigabe prüft der Nutzer im Reiter „Mods“.
  public func addSkillMod(name: String, command: String, prompt: String, tools: [String]) -> ToolResult<ModInfo> {
    let cmd = command.trimmedText.lowercased()
    guard cmd.range(of: "^[a-z0-9-]{2,30}$", options: .regularExpression) != nil else {
      return .failure(code: "INVALID_MOD", error: "Der Befehl darf nur Kleinbuchstaben, Ziffern und „-“ enthalten (2 bis 30 Zeichen).")
    }
    let installed = ((try? mods.all()) ?? []).filter { $0.manifest.kind == .skill }
    guard !installed.contains(where: { ($0.manifest.command ?? $0.id) == cmd }) else {
      return .failure(code: "INVALID_MOD", error: "Der Befehl /\(cmd) ist schon belegt.")
    }
    let existing = Set(((try? mods.all()) ?? []).map(\.id))
    let base = "skill-" + cmd
    var id = base
    var n = 2
    while existing.contains(id) { id = String("\(base)-\(n)".prefix(40)); n += 1 }
    let m = ModManifest(id: id, name: name.trimmedText, description: "Skill „\(name.trimmedText)“ (/\(cmd))",
                        kind: .skill, prompt: prompt.trimmedText, tools: tools, command: cmd)
    let problems = ModValidation.validate(m)
    guard problems.isEmpty else {
      return .failure(code: "INVALID_MOD", error: problems.joined(separator: " "))
    }
    do {
      let info = try mods.install(m, code: nil)
      emit(.stateChanged)
      return .ok(info)
    } catch {
      return .failure(code: "INVALID_MOD", error: (error as? LocalizedError)?.errorDescription ?? "Skill ungültig.")
    }
  }
}

public extension TabyServices {
  /// Skill aus der Oberfläche anlegen. Nur der Lumi-Kern kann das; andere Dienste melden es.
  func createSkillMod(name: String, command: String, prompt: String, tools: [String]) async -> ToolResult<ModInfo> {
    guard let core = self as? CoreServices else {
      return .failure(code: "UNAVAILABLE", error: "Skills sind hier nicht verfügbar.")
    }
    return core.addSkillMod(name: name, command: command, prompt: prompt, tools: tools)
  }
}
