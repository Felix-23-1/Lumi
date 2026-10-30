// VERTRAG (nur Orchestrator ändert).
// Rendert SwiftUI-Ansichten als PNG (ImageRenderer), damit Oberflächen-
// Arbeit ohne Bildschirmaufnahme sichtbar geprüft werden kann:
//   swift run TabyChecks --snapshots /pfad/zum/ordner
import AppKit
import Foundation
import SwiftUI
import TabyCore

public struct SnapshotSpec {
  public let name: String
  public let size: CGSize
  public let make: @MainActor () -> AnyView

  public init(_ name: String, size: CGSize, make: @escaping @MainActor () -> AnyView) {
    self.name = name; self.size = size; self.make = make
  }
}

public enum UISnapshots {
  @MainActor public static var all: [SnapshotSpec] { ShellSnapshots.all + ViewSnapshots.all }

  /// Schreibt alle Snapshots als PNG (2x, dunkler Hintergrund) nach `dir`.
  @MainActor public static func renderAll(to dir: URL, filter: String? = nil) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [URL] = []
    for spec in all where filter == nil || spec.name.contains(filter!) {
      // App-Symbole brauchen Transparenz, alles andere einen dunklen Hintergrund.
      let backdrop = spec.name.hasPrefix("app-icon") ? Color.clear : Color(red: 0.16, green: 0.17, blue: 0.22)
      let view = spec.make()
        .frame(width: spec.size.width, height: spec.size.height)
        .background(backdrop)
        .environment(\.colorScheme, .dark)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      guard let cg = renderer.cgImage else { continue }
      let rep = NSBitmapImageRep(cgImage: cg)
      guard let png = rep.representation(using: .png, properties: [:]) else { continue }
      let url = dir.appendingPathComponent("\(spec.name).png")
      try png.write(to: url)
      out.append(url)
    }
    return out
  }
}

/// Alle UI-Prüfungen (Logik der Hülle und der Ansichten, ohne Fenster).
public enum UIChecks {
  @MainActor public static var all: [CheckSuite] { [ShellChecks.suite, ViewChecks.suite] }
}
