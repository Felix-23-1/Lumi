// Paket „Dateien“ im Integrator: Spotlight-Suche (ohne Modell) und Zusammenfassung
// (nur Apple Intelligence). Die Logik steht in Files/FileSearch.swift.
import Foundation

extension CoreServices {
  static let findFilesToolDef = ToolDef(
    name: "find_files",
    description: "Sucht Dateien auf diesem Mac nach Name und Inhalt (höchstens 20, neueste zuerst). Läuft lokal.",
    parameters: ToolSchema.object(["query": ToolSchema.string("Suchbegriff")], required: ["query"]))

  /// Dateiwerkzeug für den Chat: nur, wenn Apple Intelligence das aktive Modell ist.
  var filesToolsAllowed: Bool {
    FileSearch.chatToolAllowed(model: settings.llmModel, available: appleIntelligenceAvailable)
  }

  func filesToolDefs() -> [ToolDef] { filesToolsAllowed ? [Self.findFilesToolDef] : [] }

  /// Führt `find_files` aus; nil, wenn der Name nicht zu diesem Paket gehört.
  func filesTool(_ name: String, _ argsJson: String) async -> JSONValue? {
    guard name == Self.findFilesToolDef.name else { return nil }
    guard filesToolsAllowed else {
      return ToolJSON.failure(code: "FILES_OFF", error: "Dateisuche gibt es nur mit Apple Intelligence.")
    }
    let args = JSONValue.parse(argsJson.isEmpty ? "{}" : argsJson) ?? .object([:])
    let hits = await findFiles(args["query"]?.stringValue ?? "")
    return ToolJSON.ok(["files": ToolJSON.encode(hits)])
  }

  public func findFiles(_ query: String) async -> [FileHit] {
    let home = options.fileSearchHome ?? NSHomeDirectory()
    let run = options.fileSearchRunner ?? FileSearch.defaultRunner
    return await Task.detached { FileSearch.find(query, home: home, run: run) }.value
  }

  public func summarizeFile(_ path: String) async -> ToolResult<String> {
    let model = settings.llmModel
    guard model == TabySettings.appleIntelligenceModel else {
      return .failure(code: "APPLE_ONLY", error: FileSearch.summaryOnlyMessage)
    }
    guard appleIntelligenceAvailable else {
      return .failure(code: "APPLE_OFF", error: "Apple Intelligence ist auf diesem Mac nicht verfügbar oder ausgeschaltet.")
    }
    let url = URL(fileURLWithPath: path)
    guard FileSearch.summaryTypes.contains(url.pathExtension.lowercased()) else {
      return .failure(code: "UNSUPPORTED", error: "Diesen Dateityp kann Lumi nicht zusammenfassen (txt, md, rtf, pdf, docx).")
    }
    let text: String
    do {
      text = try await Task.detached { try FileTextExtractor.extract(url, maxChars: FileSearch.summaryTextLimit) }.value
    } catch {
      let message = (error as? FileTextError)?.errorDescription ?? "Die Datei kann nicht gelesen werden."
      return .failure(code: "READ", error: message)
    }
    do {
      let reply = try await AppleIntelligenceClient().chat(
        messages: FileSearch.summaryMessages(text: text, name: url.lastPathComponent), tools: nil)
      let summary = (reply.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return summary.isEmpty ? .failure(code: "EMPTY", error: "Keine Zusammenfassung erhalten.") : .ok(summary)
    } catch let e as LlmError {
      return .failure(code: "APPLE", error: e.message)
    } catch {
      return .failure(code: "APPLE", error: "Apple Intelligence konnte nicht antworten.")
    }
  }
}
