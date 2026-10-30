import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  /// Geplanter Auftrag: Agent-Schleife im Lesemodus, Ergebnis in den Chat
  /// (Szenario D), Benachrichtigung übernimmt der Planer.
  func runJob(_ job: Job) async -> JobRunResult {
    if limitReached { return JobRunResult(ok: false, output: Self.limitMessage) }
    guard let llm = cheapLlmClient() else {
      return JobRunResult(ok: false, output: "Kein Modell konfiguriert, Auftrag kann nicht ausgeführt werden.")
    }
    let s = settings
    let ctx = toolContext(actor: .job, mode: .readOnly)
    let deps = AgentDeps(
      llm: llm, tools: ToolRegistry.definitions(for: .readOnly),
      executeTool: { name, argsJson in
        await ToolRegistry.execute(name: name, argumentsJSON: argsJson, ctx: ctx).jsonString()
      },
      personality: s.personality, customInstructions: s.customInstructions,
      getOverview: { [weak self] in await self?.overview() ?? .empty }, clock: clock,
      onMessage: { [store] m in _ = try? store.messages.add(m) },
      getMemories: { [store] in (try? store.memories.list()) ?? [] })
    defer { changed() }
    do {
      let messages = try await AgentLoop.run(deps, history: [], userText: job.prompt)
      let last = messages.last(where: { $0.role == .assistant && ($0.content?.isEmpty == false) })
      return JobRunResult(ok: true, output: last?.content)
    } catch let e as LlmError {
      return JobRunResult(ok: false, output: e.message)
    } catch {
      return JobRunResult(ok: false, output: "Auftrag fehlgeschlagen.")
    }
  }

  public func scheduleJob(_ req: ScheduleJobRequest) async -> ToolResult<Job> {
    await mutate("schedule_job", ["name": .string(req.name), "prompt": .string(req.prompt),
                                  "rule": ToolJSON.encode(req.rule)], key: "job")
  }

  public func cancelJob(_ id: String) async -> ToolResult<Empty> {
    await mutateEmpty("cancel_job", ["id": .string(id)])
  }
}
