// Werkzeuge für gemerkte Fakten (Paket 2): remember_fact, list_memories,
// forget_fact. list_memories ist auch im Lesemodus erlaubt (ToolRegistry).
import Foundation

enum MemoryTools {
  static let defs: [ToolDef] = [
    ToolDef(name: "remember_fact",
            description: "Merkt sich einen Fakt über den Nutzer (z. B. \"Zahnarzt ist Dr. Müller\"), der in künftige Gespräche einfließt.",
            parameters: ToolSchema.object(["text": ToolSchema.string("Der Fakt in einem kurzen Satz")], required: ["text"])),
    ToolDef(name: "list_memories", description: "Listet alle gemerkten Fakten mit ihrer ID.",
            parameters: ToolSchema.object()),
    ToolDef(name: "forget_fact", description: "Vergisst einen gemerkten Fakt.",
            parameters: ToolSchema.object(["id": ToolSchema.string("Fakt-ID")], required: ["id"])),
  ]

  static let handlers: [String: ToolHandler] = [
    "remember_fact": { ctx, args in
      let text = try args.requireString("text")
      return ToolJSON.ok(["memory": ToolJSON.encode(try ctx.store.memories.add(text))])
    },
    "list_memories": { ctx, _ in
      ToolJSON.ok(["memories": ToolJSON.encode(try ctx.store.memories.list())])
    },
    "forget_fact": { ctx, args in
      let id = try args.requireId()
      guard try ctx.store.memories.delete(id) else {
        return ToolJSON.failure(code: "NOT_FOUND", error: "Fakt \"\(id)\" nicht gefunden")
      }
      return ToolJSON.ok()
    },
  ]
}
