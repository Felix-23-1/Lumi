import EventKit
import Foundation
import UserNotifications

/// Server und Werkzeug eines MCP-Aufrufs zur Zeit der Anfrage. Beim Bestätigen muss der Name noch
/// dorthin zeigen; sonst hat sich die Werkzeugliste geändert.
struct MCPPin: Equatable {
  let serverId: String
  let toolName: String

  init(_ route: MCPRoute) {
    serverId = route.server.id
    toolName = route.tool.name
  }
}

extension CoreServices {
  /// Merkt sich die Aktion und meldet dem Modell, dass der Nutzer bestätigen muss.
  func requestConfirmation(name: String, argumentsJSON: String) async -> JSONValue {
    var args = JSONValue.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON) ?? .object([:])
    // Personennamen werden vor der Karte zu Adresse bzw. Unterhaltung, damit die Karte zeigt, was gesendet wird.
    if name == "send_mail" || name == "send_message" {
      do {
        args = try await ContactTools.resolve(name, args, services: self)
      } catch let failure as ContactLookupFailure {
        return failure.json
      } catch {
        return ToolJSON.failure(code: "ERROR", error: error.localizedDescription)
      }
    }
    let summary: String
    var mcpPin: MCPPin?
    if MailTools.confirmationRequired.contains(name) {
      do {
        summary = try await MailTools.confirmationSummary(name: name, argumentsJSON: args.jsonString(), backend: mailBackend)
      } catch {
        return MailTools.failureJSON(error)
      }
    } else if name.hasPrefix(MCPToolPolicy.prefix), let route = MCPManager.shared.route(named: name) {
      summary = mcpConfirmationSummary(route, argumentsJSON: args)
      mcpPin = MCPPin(route)
    } else if name == "delete_event" || name == "move_event" {
      summary = await describeEventChange(name: name, args: args)
    } else if name == "send_message" {
      // Der Nutzer muss Empfänger und Text sehen, sonst wird nichts gesendet.
      guard let text = await AssistantTools.confirmationSummary(args, services: self) else {
        return .object(["ok": false, "code": "NOT_FOUND", "error": "Unterhaltung nicht gefunden oder Text fehlt."])
      }
      summary = text
    } else {
      summary = describeDestructive(name: name, args: args)
    }
    // Nach dem await, damit zwei gleiche Anfragen nicht beide eingetragen werden.
    if let existing = pending.first(where: { $0.name == name && $0.args == args && $0.mcp == mcpPin }) {
      return Self.needsConfirmation(existing.confirmation.summary)
    }
    let c = PendingConfirmation(id: UUID().uuidString, tool: name, summary: summary,
                                createdAt: LocalTime.format(clock.now()), detail: Self.confirmationDetail(name, args))
    pending.append((c, name, args, mcpPin))
    emit(.confirmationRequested(c))
    emit(.stateChanged)
    return Self.needsConfirmation(summary)
  }

  /// Vollständige, geschwärzte Werte für „Alles anzeigen“: nur bei MCP-Werkzeugen und Mod-Läufen.
  static func confirmationDetail(_ name: String, _ args: JSONValue) -> String? {
    if name == "save_vault_note" {
      return String(MarkdownVault.defuse(args["content"]?.stringValue ?? "").prefix(300))
    }
    guard name.hasPrefix(MCPToolPolicy.prefix) || ModRuntime.modId(fromTool: name) != nil else { return nil }
    guard args != .object([:]) else { return nil }
    return MCPToolPolicy.fullArgumentsText(args)
  }

  static func needsConfirmation(_ summary: String) -> JSONValue {
    .object([
      "ok": false,
      "code": "NEEDS_CONFIRMATION",
      "summary": .string(summary),
      "error": .string("Noch nicht ausgeführt – wartet auf Bestätigung durch den Nutzer in der Notch: \(summary). Sag dem Nutzer kurz, dass er bestätigen muss."),
    ])
  }

  /// Text für delete_event/move_event mit dem Titel aus der Quelle (Suche ±1 Jahr um heute bzw. das Ziel).
  private func describeEventChange(name: String, args: JSONValue) async -> String {
    let id = args["id"]?.stringValue ?? ""
    let start = args["start"]?.stringValue ?? ""
    let around = start.isEmpty ? LocalTime.formatDate(clock.now()) : LocalTime.datePart(start)
    var title: String?
    if let source = calendarAccess.activeProviders().first(where: { $0.id == args["source_id"]?.stringValue }),
       let events = try? await source.listEvents(from: StoreDates.shiftDateOnly(around, -366),
                                                 to: StoreDates.shiftDateOnly(around, 367)) {
      title = events.first(where: { $0.id == id })?.title
    }
    let what = title.map { "Termin „\($0)“" } ?? "Termin"
    if name == "delete_event" { return "\(what) löschen" }
    let when = start.isEmpty ? "" : " auf \(start.replacingOccurrences(of: "T", with: " "))"
    return "\(what) verschieben\(when)"
  }

  private func describeDestructive(name: String, args: JSONValue) -> String {
    let id = args["id"]?.stringValue ?? ""
    switch name {
    case "delete_task":
      let t = (try? store.tasks.get(id))??.title
      return t.map { "Aufgabe „\($0)“ löschen" } ?? "Aufgabe löschen"
    case "delete_note":
      let t = (try? store.notes.get(id))??.title
      return t.map { "Notiz „\($0)“ löschen" } ?? "Notiz löschen"
    case "cancel_job":
      let t = (try? store.jobs.get(id))??.name
      return t.map { "Auftrag „\($0)“ stoppen" } ?? "Auftrag stoppen"
    case "save_vault_note":
      // Der Name und der Ordner sind die, die tatsächlich geschrieben werden.
      let file = MarkdownVault.safeFileName(args["title"]?.stringValue ?? "")
      let typed = args["folder"]?.stringValue
      let folder = CoreServices.vaultTargetFolder(configured: settings.vaultWriteFolder, typed: typed)
        ?? (typed ?? settings.vaultWriteFolder)
      let append = args["append"]?.boolValue == true
      return "Notiz „\(file).md“ in Obsidian unter \(folder)" + (append ? " (anhängen)" : "")
    case "find_secret":
      return Self.secretSearchSummary(query: args["query"]?.stringValue ?? "", shares: settings.networkShares)
    case "forget_fact":
      let t = ((try? store.memories.list()) ?? []).first(where: { $0.id == id })?.text
      return t.map { "Gemerkten Fakt „\($0)“ vergessen" } ?? "Gemerkten Fakt vergessen"
    case "remember_fact":
      let text = args["text"]?.stringValue ?? ""
      return text.isEmpty ? "Fakt merken" : "Fakt „\(text)“ merken"
    case _ where ModRuntime.modId(fromTool: name) != nil:
      return describeModRun(name: name, args: args)
    default:
      return name
    }
  }

  public func confirmAction(_ id: String) async -> ToolResult<Empty> {
    guard let i = pending.firstIndex(where: { $0.confirmation.id == id }) else {
      return .failure(code: "NOT_FOUND", error: "Diese Anfrage ist nicht mehr offen.")
    }
    let p = pending.remove(at: i)
    if p.name == "find_secret" { return await confirmedSecretLookup(p.args) }
    let result: ToolResult<Empty>
    if MailTools.confirmationRequired.contains(p.name) {
      let out = await MailTools.executeConfirmed(name: p.name, argumentsJSON: p.args.jsonString(), backend: mailBackend)
      result = out["ok"]?.boolValue == true
        ? .ok(Empty()) : .failure(code: "MAIL", error: out["error"]?.stringValue ?? "Mail-Aktion fehlgeschlagen.")
      audit(actor: AuditActor.model, tool: p.name, confirmed: true, ok: result.isOk)
      mailFetchedAt = nil  // Posteingang hat sich geändert
    } else if p.name.hasPrefix(MCPToolPolicy.prefix) {
      // Der Name muss noch auf denselben Server und dasselbe Werkzeug zeigen wie bei der Anfrage.
      if let route = MCPManager.shared.route(named: p.name), p.mcp == MCPPin(route) {
        let out = await mcpCall(route, argumentsJSON: p.args.jsonString())
        result = out["ok"]?.boolValue == true
          ? .ok(Empty()) : .failure(code: "MCP", error: out["error"]?.stringValue ?? "MCP-Aufruf fehlgeschlagen.")
      } else {
        result = .failure(code: "MCP_CHANGED", error: "Werkzeug hat sich geändert – bitte erneut anfordern")
      }
    } else if let modId = ModRuntime.modId(fromTool: p.name) {
      switch await executeMod(modId, input: p.args, confirmed: true) {
      case .ok: result = .ok(Empty())
      case .failure(let code, let e): result = .failure(code: code, error: e)
      }
    } else if p.name == "save_vault_note" {
      result = await confirmedVaultNote(p.args)
    } else {
      // Anfrage kam vom Modell; der Nutzer hat sie bestätigt.
      result = ToolRegistry.empty(await runUndoable(p.name, p.args, ctx: toolContext(actor: .user),
                                                    auditActor: AuditActor.model, confirmed: true))
    }
    let text = result.isOk ? "Erledigt: \(p.confirmation.summary)." : "Nicht möglich: \(result.errorMessage ?? p.confirmation.summary)"
    appendMessages([ChatMessage(role: .assistant, content: text)])
    changed()
    return result
  }

  public func rejectAction(_ id: String) async {
    guard let i = pending.firstIndex(where: { $0.confirmation.id == id }) else { return }
    let p = pending.remove(at: i)
    appendMessages([ChatMessage(role: .assistant, content: "Abgelehnt: \(p.confirmation.summary).")])
    emit(.stateChanged)
  }
}
