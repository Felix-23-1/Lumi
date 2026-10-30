import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  func toolContext(actor: ActionActor, mode: JobMode = .standard) -> ToolContext {
    ToolContext(store: store, calendar: calendarAccess, mode: mode, actor: actor, clock: clock, services: self)
  }

  func tool(_ name: String, _ args: [String: JSONValue]) async -> JSONValue {
    await runUndoable(name, .object(args), ctx: toolContext(actor: .user))
  }

  func mutate<T: Decodable>(_ name: String, _ args: [String: JSONValue], key: String) async -> ToolResult<T> {
    let result: ToolResult<T> = ToolRegistry.typed(await tool(name, args), key: key)
    if result.isOk { changed() }
    return result
  }

  func mutateEmpty(_ name: String, _ args: [String: JSONValue]) async -> ToolResult<Empty> {
    let result = ToolRegistry.empty(await tool(name, args))
    if result.isOk { changed() }
    return result
  }

  public func chatSend(_ text: String) async throws -> [ChatMessage] {
    if let call = skillCall(text) { return try await runSkill(call.id, input: call.input, onPartial: nil) }
    messenger.noteIslandUse()
    return try await chatTurn(text, systemNote: nil)
  }

  public func chatSendStreaming(_ text: String, onPartial: @escaping @MainActor (String) -> Void) async throws -> [ChatMessage] {
    if let call = skillCall(text) { return try await runSkill(call.id, input: call.input, onPartial: onPartial) }
    messenger.noteIslandUse()
    return try await chatTurn(text, systemNote: nil, onPartial: onPartial)
  }

  /// Ein Nutzer-Turn. `systemNote` geht nur in den Systemprompt, nicht in den Verlauf.
  /// `toolFilter` schränkt die Werkzeuge ein (Skills); nil = alle.
  func chatTurn(_ text: String, systemNote: String?, toolFilter: ((String) -> Bool)? = nil,
                onPartial: (@MainActor (String) -> Void)? = nil) async throws -> [ChatMessage] {
    guard !chatInFlight else {
      throw LlmError(.unknown, "Es läuft noch eine Anfrage. Bitte kurz warten oder abbrechen.")
    }
    chatInFlight = true
    defer { chatInFlight = false }
    let user = ChatMessage(role: .user, content: text)
    if limitReached { throw LlmError(.quota, Self.limitMessage) }
    guard let llm = llmClient() else {
      // Ohne Einwilligung kommt nichts an den Chat-Verlauf: die Nachricht wird erst nach „Einverstanden“ gesendet.
      if PrivacyGate.needsConsent(settings, model: settings.llmModel) {
        throw LlmError(.unknown, PrivacyGate.consentCode)
      }
      let reply = ChatMessage(
        role: .assistant,
        content: settings.localOnly
          ? "Nur-lokal-Modus – kein Modell verfügbar. Mit Apple Intelligence geht es auch ohne Internet."
          : "Kein Modell konfiguriert. Du kannst Aufgaben, Notizen und Termine auch direkt in den Reitern bearbeiten, oder in den Einstellungen einen Modell-Zugang eintragen."
      )
      appendMessages([user, reply])
      emit(.stateChanged)
      return [user, reply]
    }
    // Verlauf mit Dateinamen (find_files) geht nur an Apple Intelligence, nie an ein Cloud-Modell.
    let stored = (try? store.messages.list(limit: Self.historyLimit)) ?? []
    let history = llm is AppleIntelligenceClient ? stored : FileSearch.cloudHistory(stored)
    let s = settings
    let ctx = toolContext(actor: .assistant)
    let mcpRoutes = await mcpRoutesForTurn(s.mcpServers)
    let offered = ToolRegistry.definitions + modToolDefs() + [ModRuntime.createModTool] + mailToolDefs()
      + CoreServices.timerSearchToolDefs + filesToolDefs() + PrivateListTools.definitions + mcpToolDefs(mcpRoutes)
      + vaultToolDefs + secretToolDefs
    let deps = AgentDeps(
      llm: llm, tools: offered.filter { toolFilter?($0.name) ?? true },
      executeTool: { [weak self] name, argsJson in
        if name.hasPrefix(MCPToolPolicy.prefix), let self, let route = MCPManager.shared.route(named: name) {
          // Schreibende MCP-Werkzeuge nur nach Bestätigung in der Insel.
          if route.isWrite { return await self.requestConfirmation(name: name, argumentsJSON: argsJson).jsonString() }
          return await self.mcpCall(route, argumentsJSON: argsJson).jsonString()
        }
        if let self, let out = await self.privateListTool(name, argsJson) { return out.jsonString() }
        if let self, let out = await self.timerSearchTool(name, argsJson) { return out.jsonString() }
        if let self, let out = self.vaultTool(name, argsJson) { return out.jsonString() }
        if let self, let out = await self.filesTool(name, argsJson) { return out.jsonString() }
        if let self, MailTools.definitions.contains(where: { $0.name == name }) {
          guard self.mailToolsAllowed else {
            return JSONValue.object(["ok": false, "code": "MAIL_OFF",
                                     "error": "Mail ist aus oder nur lokal erlaubt."]).jsonString()
          }
          if MailTools.confirmationRequired.contains(name) {
            return await self.requestConfirmation(name: name, argumentsJSON: argsJson).jsonString()
          }
          let out = await MailTools.execute(name: name, argumentsJSON: argsJson, backend: self.mailBackend)
          self.audit(actor: AuditActor.model, tool: name, confirmed: false, ok: out["ok"]?.boolValue == true)
          return out.jsonString()
        }
        if ToolRegistry.confirmationRequired.contains(name), let self {
          return await self.requestConfirmation(name: name, argumentsJSON: argsJson).jsonString()
        }
        if name == ModRuntime.createModTool.name, let self {
          return await self.createModFromChat(argsJson).jsonString()
        }
        if ModRuntime.modId(fromTool: name) != nil, let self {
          // Jeder Mod, den das Modell aufruft, braucht die Bestätigung des Nutzers
          // (Kurzbefehle haben keine Rechte und bekommen trotzdem die Eingabe).
          return await self.requestConfirmation(name: name, argumentsJSON: argsJson).jsonString()
        }
        if let self, let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) {
          return await self.runUndoable(name, args, ctx: ctx).jsonString()
        }
        return await ToolRegistry.execute(name: name, argumentsJSON: argsJson, ctx: ctx).jsonString()
      },
      personality: s.personality,
      customInstructions: [s.customInstructions, systemNote ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n"),
      getOverview: { [weak self] in await self?.overview() ?? .empty }, clock: clock,
      // Jede Nachricht sofort speichern: bricht die Schleife später ab (Fehler,
      // Abbruch), bleiben bereits ausgeführte Werkzeuge im Verlauf sichtbar –
      // sonst würde der Nutzer es nochmal versuchen und Duplikate erzeugen.
      onMessage: { [store] m in _ = try? store.messages.add(m) },
      getMemories: { [store] in (try? store.memories.list()) ?? [] }, workSettings: s)
    // Werkzeuge können gelaufen sein – in jedem Fall neu abgleichen.
    defer { changed() }
    do {
      // Teiltexte springen vom Hintergrund zum Hauptakteur; die Schleife bündelt sie schon.
      let partial: (@Sendable (String) -> Void)? = onPartial.map { cb in
        { @Sendable (s: String) in Task { @MainActor in cb(s) } }
      }
      return try await AgentLoop.run(deps, history: history, userText: text, onPartial: partial)
    } catch let e as LlmError {
      throw e
    } catch {
      throw LlmError(.unknown, "Unbekannter Fehler beim Aufruf des Modells.")
    }
  }

  public func chatClear() async {
    let rows = ((try? store.db.query("SELECT id, json, created_at FROM messages ORDER BY created_at, rowid")) ?? [])
      .map { (id: $0.text("id"), json: $0.text("json"), createdAt: $0.text("created_at")) }
    do {
      try store.messages.clear()
      if !rows.isEmpty { pushUndo(.clearedChat(rows), "Verlauf geleert") }
    } catch {
      TabyLog.info(.core, "chat: Verlauf leeren fehlgeschlagen")
    }
    emit(.stateChanged)
  }
}
