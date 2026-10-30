// Paket-Mitschnitt mit tcpdump. Jeder Mitschnitt fragt einmal mit dem normalen
// macOS-Dialog nach Administratorrechten; danach gibt es keine dauerhaften Rechte.
// Die Anzeige zeigt eine Zusammenfassung je Paket (Zeitabstand, Adressen,
// Protokoll, Länge, Kurzinfo). Die .pcap daneben enthält dagegen die Pakete
// vollständig, also auch den Inhalt. Sie liegt im Arbeitsordner, bis der nächste
// Mitschnitt startet; dann wird der alte Ordner gelöscht.
import Foundation

/// Arbeitsordner des letzten Mitschnitts. Ein neuer Start löscht den alten Ordner samt .pcap.
/// Ordner früherer Läufe (z. B. nach einem Absturz), die älter als einen Tag sind, räumt der Start weg.
enum CaptureLeftovers {
  static func removeStale(now: Date) {
    Leftovers.removeOlder(in: URL(fileURLWithPath: "/private/var/tmp", isDirectory: true), now: now,
                          prefix: "taby-capture.")
  }
}

enum CaptureWorkDirs {
  private static let lock = NSLock()
  private static var last: String?

  static func replace(with path: String) {
    let old: String? = lock.withLock {
      defer { last = path }
      return last
    }
    if let old, old != path { try? FileManager.default.removeItem(atPath: old) }
  }
}

/// Zeilen-Quelle eines laufenden tcpdump-Mitschnitts: `lines` liefert eine Zeile je Paket
/// (Format `tcpdump -nttt -l`), `stop` beendet den Mitschnitt.
public struct CaptureFeed: Sendable {
  public let lines: AsyncStream<String>
  public let stop: @Sendable () -> Void
  /// Pfad der mitgeschriebenen .pcap (für Wireshark); nil, wenn nicht verfügbar.
  public let pcapPath: String?
  public init(lines: AsyncStream<String>, stop: @escaping @Sendable () -> Void, pcapPath: String? = nil) {
    self.lines = lines
    self.stop = stop
    self.pcapPath = pcapPath
  }
}

/// Grenze zu macOS. `runAdmin` startet tcpdump mit `args` (ohne Programmnamen) als
/// Administrator und liefert die Zeilen. nil bei Abbruch im Dialog oder Startfehler.
public protocol CaptureSystem: Sendable {
  func runAdmin(_ args: [String], prompt: String) async -> CaptureFeed?
}

/// Ein laufender Mitschnitt: Pakete als Strom, `stop()` beendet ihn.
public final class RunningCapture: @unchecked Sendable {
  public let packets: AsyncStream<CapturePacket>
  public let pcapPath: String?
  private let stopFeed: @Sendable () -> Void

  init(packets: AsyncStream<CapturePacket>, stop: @escaping @Sendable () -> Void, pcapPath: String? = nil) {
    self.packets = packets
    self.stopFeed = stop
    self.pcapPath = pcapPath
  }

  public func stop() {
    stopFeed()
  }

  /// Übersetzt die tcpdump-Zeilen in Pakete. `t` wird zur laufenden Zeit seit Start (die
  /// Zeilen tragen nur den Abstand zum Vorpaket), `id` zählt ab 1.
  static func pump(_ feed: CaptureFeed) -> RunningCapture {
    let (stream, continuation) = AsyncStream<CapturePacket>.makeStream()
    let task = Task {
      var elapsed = 0.0
      var id = 0
      for await line in feed.lines {
        guard let parsed = TcpdumpParser.parseLine(line) else { continue }
        elapsed += parsed.t
        id += 1
        continuation.yield(CapturePacket(id: id, t: elapsed, proto: parsed.proto, source: parsed.source,
                                         dest: parsed.dest, length: parsed.length, info: parsed.info))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in
      task.cancel()
      feed.stop()
    }
    return RunningCapture(packets: stream, stop: feed.stop, pcapPath: feed.pcapPath)
  }
}

public final class PacketCapture: @unchecked Sendable {
  public static let maxPackets = 2000
  public static let defaultPackets = 500

  let system: CaptureSystem
  let net: NetworkSystem

  public init(system: CaptureSystem, net: NetworkSystem) {
    self.system = system
    self.net = net
  }

  /// Schnittstellen, die man mitschneiden kann (en*, utun*, bridge*, lo*).
  public func interfaces() async -> [String] {
    let out = await net.run("/sbin/ifconfig", ["-l"], timeout: 5)
    guard out.status == 0 else { return [] }
    return InterfaceParser.parse(out.stdout)
  }

  /// Startet einen Mitschnitt. Schnittstelle muss vorhanden, Filter erlaubt sein; Anzahl wird begrenzt.
  public func start(interface: String, filter: String, maxPackets: Int = PacketCapture.defaultPackets) async
    -> ToolResult<RunningCapture>
  {
    let iface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
    guard await interfaces().contains(iface) else {
      return .failure(code: "CAPTURE_BAD_INTERFACE", error: "Diese Schnittstelle gibt es hier nicht.")
    }
    let expression = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ScanTargets.isValidTcpdumpFilter(expression) else {
      return .failure(code: "CAPTURE_BAD_FILTER", error: "Dieser Filter ist nicht erlaubt (nur Adressen, Ports und Protokolle).")
    }
    let count = min(max(maxPackets, 1), Self.maxPackets)
    var args = ["-i", iface, "-nttt", "-l", "-c", String(count)]
    if !expression.isEmpty { args.append(expression) }
    let shownFilter = expression.isEmpty ? "ohne Filter" : "Filter „\(expression)“"
    let prompt = "Lumi möchte einen Paket-Mitschnitt auf „\(iface)“ (\(shownFilter)) starten."
    guard let feed = await system.runAdmin(args, prompt: prompt) else {
      return .failure(code: "CAPTURE_DENIED", error: "Der Mitschnitt wurde nicht gestartet (Administrator-Abfrage abgebrochen oder fehlgeschlagen).")
    }
    return .ok(RunningCapture.pump(feed))
  }
}

/// Echte macOS-Umsetzung. Ablauf je Mitschnitt:
/// 1. Die root-Shell legt einen Arbeitsordner per `mktemp` unter /private/var/tmp an (root-eigen,
///    0711; der Nutzer kann darin nichts anlegen oder verlinken). Lumi legt nur seinen Steuerordner
///    unter $TMPDIR an, in dem es die `stop`-Datei schreibt.
/// 2. Ein `osascript`-Aufruf mit `do shell script … with administrator privileges`
///    startet eine Hintergrund-Shell als root (ein Dialog). Der Aufruf kehrt sofort zurück und
///    gibt den Ordnerpfad aus.
/// 3. Die Shell startet tcpdump mit `> out.txt`, wartet, und beendet tcpdump bei
///    `stop`-Datei, nach `maxSeconds` oder nach Ende von tcpdump (`-c`). Danach legt sie `done` an
///    und übergibt den Ordner dem Nutzer.
/// 4. Lumi liest `out.txt` im Takt von 0,3 s nach, gibt vollständige Zeilen weiter und
///    räumt den Ordner auf. Das Stoppen geschieht über die `stop`-Datei, ohne zweiten Dialog.
/// Schreibt zugleich eine echte .pcap (für Wireshark) über `-w … --print`.
/// Grenzen: Latenz bis zu ca. 0,3 s; wird Lumi
/// beendet, läuft tcpdump bis Paketgrenze oder Zeitlimit weiter; tcpdump-Fehler (z. B.
/// fehlende Rechte am Gerät) erscheinen nur in err.txt, nicht als Fehlermeldung.
public struct TcpdumpCaptureSystem: CaptureSystem {
  public static let tcpdumpPath = "/usr/sbin/tcpdump"
  public static let maxSeconds = 900

  public init() {}

  /// Vorbereitung in der root-Shell: Arbeitsordner, Dateien nur für root (umask 077, 0600),
  /// dann dem Nutzer übergeben. Gibt den Ordnerpfad aus.
  static func setupScript(uid: String) -> String {
    "umask 077; D=$(mktemp -d /private/var/tmp/taby-capture.XXXXXX) || exit 1; chmod 711 \"$D\" || exit 1; "
      + "for f in out.txt err.txt mitschnitt.pcap; do : > \"$D/$f\" && chmod 600 \"$D/$f\" || exit 1; done; "
      + "chown \(uid) \"$D/out.txt\" \"$D/err.txt\" \"$D/mitschnitt.pcap\" || exit 1; echo \"$D\"; "
  }

  public func runAdmin(_ args: [String], prompt: String) async -> CaptureFeed? {
    let fm = FileManager.default
    // Steuerordner des Nutzers: Lumi legt nur die `stop`-Datei an, root liest sie nur.
    let ctl = fm.temporaryDirectory.appendingPathComponent("taby-capture-\(StoreIds.make())", isDirectory: true)
    guard (try? fm.createDirectory(at: ctl, withIntermediateDirectories: true)) != nil else { return nil }
    let stopPath = ctl.appendingPathComponent("stop").path

    // Die root-Shell legt den Arbeitsordner selbst an (mktemp, 0711, root-eigen): der Nutzer
    // kann dort nichts anlegen, umbenennen oder verlinken. Dateien, die er lesen muss, werden
    // erst nach dem Anlegen an ihn übergeben. Ihr Pfad kommt als Ausgabe der Shell zurück.
    let uid = String(getuid())
    let tcpdump = Self.shellQuote(Self.tcpdumpPath) + " -w \"$D/mitschnitt.pcap\" --print "
      + args.map(Self.shellQuote).joined(separator: " ")
    let setup = Self.setupScript(uid: uid)
    let body = tcpdump + " > \"$D/out.txt\" 2> \"$D/err.txt\" & P=$!; S=0; "
      + "while kill -0 \"$P\" 2>/dev/null; do "
      + "if [ -f \(Self.shellQuote(stopPath)) ] || [ \"$S\" -ge \(Self.maxSeconds) ]; then kill \"$P\" 2>/dev/null; break; fi; "
      + "S=$((S+1)); sleep 1; done; wait \"$P\" 2>/dev/null; touch \"$D/done\"; chown -R \(uid) \"$D\""
    let script = setup + "(\(body)) >/dev/null 2>&1 &"
    let appleScript = "do shell script \"\(Self.appleScriptEscape(script))\" with prompt \"\(Self.appleScriptEscape(prompt))\""
      + " with administrator privileges"

    // Wartet bis zu 120 s auf den Passwortdialog: nicht im Pool-Thread.
    let result: ModProcessResult? = await Blocking.run {
      guard let r = try? ModProcess.run("/usr/bin/osascript", ["-e", appleScript], timeout: 120), !r.timedOut,
            r.status == 0 else { return nil }
      return r
    }
    // Nur der Ordner, den mktemp unter /private/var/tmp angelegt hat, ist gültig.
    let rootDir = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard rootDir.hasPrefix("/private/var/tmp/taby-capture."), !rootDir.contains("\n") else {
      try? fm.removeItem(at: ctl)
      return nil
    }
    CaptureWorkDirs.replace(with: rootDir)
    let dir = URL(fileURLWithPath: rootDir, isDirectory: true)
    let outPath = dir.appendingPathComponent("out.txt").path
    let errPath = dir.appendingPathComponent("err.txt").path
    let donePath = dir.appendingPathComponent("done").path
    let pcapPath = dir.appendingPathComponent("mitschnitt.pcap").path

    let (stream, continuation) = AsyncStream<String>.makeStream()
    let stopFile = { _ = fm.createFile(atPath: stopPath, contents: nil) }
    let reader = Task.detached(priority: .utility) {
      var offset: UInt64 = 0
      var pending = Data()
      while !Task.isCancelled {
        // Erst prüfen, ob tcpdump fertig ist, dann lesen: so geht keine letzte Zeile verloren.
        let finished = fm.fileExists(atPath: donePath)
        if let handle = FileHandle(forReadingAtPath: outPath) {
          try? handle.seek(toOffset: offset)
          let data = handle.readDataToEndOfFile()
          try? handle.close()
          if !data.isEmpty {
            offset += UInt64(data.count)
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
              continuation.yield(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
              pending.removeSubrange(pending.startIndex...nl)
            }
          }
        }
        if finished { break }
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
      continuation.finish()
      // out.txt/err.txt aufräumen, die .pcap bleibt zum Speichern erhalten.
      try? fm.removeItem(atPath: outPath)
      try? fm.removeItem(atPath: errPath)
      try? fm.removeItem(at: ctl)
    }
    continuation.onTermination = { _ in
      reader.cancel()
      stopFile()
    }
    return CaptureFeed(lines: stream, stop: stopFile, pcapPath: pcapPath)
  }

  /// Einfache Anführungszeichen; enthaltene ' werden als '\'' geschrieben.
  static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Escapen für einen AppleScript-Stringliteral.
  static func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
}
