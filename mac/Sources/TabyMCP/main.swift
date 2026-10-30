// taby-mcp: MCP-Server über stdio für Hermes und Claude Code.
// Startet der MCP-Client ihn, liest er JSON-RPC-Zeilen von stdin und antwortet
// auf stdout (nur Protokoll). Logs gehen nach stderr. Beendet sich bei EOF.
// Keine Datenbank: Werkzeuge kommen über den Socket aus der laufenden Lumi-App.
//
//   taby-mcp [--socket PFAD]
import Foundation
import TabyCore

func socketPathArgument(_ args: [String]) -> String {
  var i = 1
  while i < args.count {
    let arg = args[i]
    if arg == "--socket", i + 1 < args.count { return args[i + 1] }
    if arg.hasPrefix("--socket=") { return String(arg.dropFirst("--socket=".count)) }
    i += 1
  }
  return MCPPaths.defaultSocketPath
}

let backend = MCPBridgeClient(socketPath: socketPathArgument(CommandLine.arguments))

while let line = readLine(strippingNewline: true) {
  let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !message.isEmpty else { continue }
  if let response = MCPProtocol.handle(message, backend: backend) {
    FileHandle.standardOutput.write(Data((response + "\n").utf8))
  }
}
exit(0)
