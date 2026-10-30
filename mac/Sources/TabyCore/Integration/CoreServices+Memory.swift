import EventKit
import Foundation
import UserNotifications

extension CoreServices {
  public func addMemory(_ text: String) async -> ToolResult<Memory> {
    do {
      let m = try store.memories.add(text)
      emit(.stateChanged)
      return .ok(m)
    } catch {
      return .failure(code: "INVALID", error: "Bitte etwas eingeben, das ich mir merken soll.")
    }
  }

  public func deleteMemory(_ id: String) async -> ToolResult<Empty> {
    let memory = ((try? store.memories.list()) ?? []).first { $0.id == id }
    do {
      _ = try store.memories.delete(id)
      if let memory { pushUndo(.deletedMemory(memory), "Fakt vergessen") }
      emit(.stateChanged)
      return .ok(Empty())
    } catch {
      return .failure(code: "ERROR", error: "Konnte den Fakt nicht löschen.")
    }
  }

  public func exportMarkdown(to folder: String?) async -> ToolResult<ExportResult> {
    let target = folder ?? settings.exportFolder
    guard !target.isEmpty else {
      return .failure(code: "NO_FOLDER", error: "Bitte zuerst einen Export-Ordner wählen.")
    }
    do {
      return .ok(try MarkdownExporter.export(store: store, folder: target, clock: clock))
    } catch {
      return .failure(code: "EXPORT", error: "Export fehlgeschlagen: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
  }
}
