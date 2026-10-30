// Seite „Export & Schnittstellen“ (erweitert): Markdown-Export, MCP und fremde MCP-Server.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Export

  var exportSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "square.and.arrow.up", title: "Export (Markdown, z. B. Obsidian)")
      HStack(spacing: 6) {
        Image(systemName: "folder").foregroundStyle(Theme.tertiary)
        Text(form.exportFolder.isEmpty ? "Kein Ordner gewählt" : form.exportFolder)
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Button("Ordner wählen…", action: chooseFolder)
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      HStack(spacing: 8) {
        Button {
          exporting = true
          exportMessage = nil
          Task {
            let r = await model.services.exportMarkdown(to: form.exportFolder.isEmpty ? nil : form.exportFolder)
            withAnimation(Theme.spring) {
              exporting = false
              switch r {
              case .ok(let out):
                let before = out.backupFolder.map { " Vorherige Dateien liegen in \($0)." } ?? ""
                exportMessage = (true, "\(out.files) Dateien nach \(out.folder) exportiert.\(before)")
              case .failure(_, let e): exportMessage = (false, e)
              }
            }
          }
        } label: {
          HStack(spacing: 5) {
            if exporting { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.down.doc") }
            Text("Jetzt exportieren")
          }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(exporting || form.exportFolder.isEmpty)
        if let m = exportMessage {
          Text(m.text).font(.system(size: 12)).foregroundStyle(m.ok ? Theme.green : Theme.red).lineLimit(2)
            .transition(.opacity)
        }
        Spacer(minLength: 0)
      }
    }
    .tabyCard()
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Wählen"
    panel.message = "Ordner für den Markdown-Export (Lumi legt darin einen Unterordner „Lumi“ an)."
    if panel.runModal() == .OK, let url = panel.url { form.exportFolder = url.path }
  }

  // MARK: Fremde MCP-Server

  var externalServersSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "server.rack", title: "Fremde MCP-Server")
      Text("Lumi startet einen Server nur, wenn ein Chat seine Werkzeuge braucht, und beendet ihn nach 5 Minuten ohne Nutzung. "
        + "Der Server kann selbst auf das Internet zugreifen, auch im Nur-lokal-Modus. "
        + "Schreibende Werkzeuge brauchen immer deine Bestätigung.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(form.mcpServers.indices, id: \.self) { index in
        externalServerRow(index)
      }
      Button("Server hinzufügen") {
        form.mcpServers.append(MCPServerConfig(id: UUID().uuidString, name: "Neuer Server", command: ""))
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
    .tabyCard()
  }

  func externalServerRow(_ index: Int) -> some View {
    let server = $form.mcpServers[index]
    let id = server.wrappedValue.id
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TextField("Name", text: server.name).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
        PillToggle(title: "Aktiv", isOn: server.enabled)
        PillToggle(title: "Schreiben erlauben", isOn: server.allowWrite)
      }
      HStack(spacing: 8) {
        TextField("Befehl, absoluter Pfad", text: server.command)
          .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
        Button("Wählen…") { chooseMCPCommand(index) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      TextField("Argumente, durch Leerzeichen getrennt", text: Binding(
        get: { server.wrappedValue.args.joined(separator: " ") },
        set: { server.wrappedValue.args = $0.split(separator: " ").map(String.init) }))
        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
      if MCPToolPolicy.redactArgs(server.wrappedValue.args) != server.wrappedValue.args {
        // Nur Anzeige: das Feld oben bleibt roh, damit eine maskierte Fassung nie zurückgeschrieben wird.
        Text("Start: " + MCPToolPolicy.redactArgs(server.wrappedValue.args).joined(separator: " "))
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(2)
      }
      HStack(spacing: 8) {
        Button(mcpTesting == id ? "Teste …" : "Testen") { testMCPServer(id) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(mcpTesting != nil)
        if let text = mcpTestResults[id] {
          Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
        }
        Spacer(minLength: 0)
        Button("Entfernen") { pendingMcpId = id }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
    }
    .padding(.vertical, 4)
  }

  /// Nach Bestätigung: den gewählten Server aus der Liste nehmen (wird beim Speichern wirksam).
  func removeMCPServer() {
    guard let id = pendingMcpId else { return }
    pendingMcpId = nil
    mcpTestResults[id] = nil
    form.mcpServers.removeAll { $0.id == id }
    notify(nil, success: "Server entfernt")
  }

  func chooseMCPCommand(_ index: Int) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Wählen"
    panel.message = "Programm für den MCP-Server (wird ohne Shell gestartet)."
    if panel.runModal() == .OK, let url = panel.url, form.mcpServers.indices.contains(index) {
      form.mcpServers[index].command = url.path
    }
  }

  func testMCPServer(_ id: String) {
    guard let server = form.mcpServers.first(where: { $0.id == id }) else { return }
    mcpTesting = id
    Task {
      switch await model.services.testMCPServer(server) {
      case .ok(let names):
        mcpTestResults[id] = names.isEmpty ? "Keine Werkzeuge gefunden." : "Werkzeuge: " + names.joined(separator: ", ")
      case .failure(_, let error):
        mcpTestResults[id] = error
      }
      mcpTesting = nil
    }
  }

  // MARK: MCP

  var mcpSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "point.3.connected.trianglepath.dotted", title: "MCP (Schnittstelle für andere KI-Programme)")
      PillToggle(title: "Externe Agenten dürfen Lumi nutzen", isOn: $form.mcpEnabled)
      Text("Sie können deinen Tag lesen und Aufgaben, Notizen und Termine anlegen – löschen können sie nichts. "
        + "Nur auf diesem Mac, nur solange Lumi läuft.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if form.mcpEnabled {
        if let path = mcpPath {
          snippet(title: "Claude Code (Terminal)", text: SettingsLogic.claudeSnippet(path))
          snippet(title: "Andere KI-Programme (YAML)", text: SettingsLogic.yamlSnippet(path))
          if !settings.mcpEnabled {
            Text("Wird gleich gespeichert – dann ist die Schnittstelle aktiv.").font(.system(size: 11)).foregroundStyle(Theme.amber)
          }
        } else {
          Text("Nur in der installierten App verfügbar (Lumi.app).").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
      }
    }
    .animation(Theme.spring, value: form.mcpEnabled)
    .task { mcpPath = await model.services.mcpCommandPath() }
    .tabyCard()
  }

  func snippet(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
      HStack(alignment: .top, spacing: 6) {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(copied == title ? "Kopiert" : "Kopieren") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          withAnimation(Theme.spring) { copied = title }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    }
  }

}
