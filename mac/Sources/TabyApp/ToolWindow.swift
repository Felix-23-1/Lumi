// Ablösbares Werkzeug-Fenster (Paket 7): zeigt den Inhalt eines Reiters in
// einem normalen, frei vergrößerbaren macOS-Fenster. Gedacht für Scans,
// Mitschnitte und Verbindungen, wo die Insel zu klein wird. Je Reiter ein
// Fenster; die Größe merkt sich macOS (frameAutosaveName).
import AppKit
import SwiftUI
import TabyCore
import TabyUI

@MainActor
final class ToolWindowController {
  private let model: AppModel
  private var windows: [TabyTab: NSWindow] = [:]

  init(model: AppModel) { self.model = model }

  func open(_ tab: TabyTab) {
    if let existing = windows[tab] {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let root = ToolWindowRoot(tab: tab).environmentObject(model)
    let hosting = NSHostingView(rootView: root)
    // Einstellungen: Seitenleiste braucht mehr Breite als ein Werkzeugfenster.
    let size = tab == .settings ? NSSize(width: 760, height: 580) : NSSize(width: 620, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.title = "Lumi – \(tab.title)"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
    window.minSize = tab == .settings ? NSSize(width: 720, height: 520) : NSSize(width: 460, height: 360)
    window.contentView = hosting
    window.setFrameAutosaveName("taby.tool.\(tab.rawValue)")
    if window.frame.origin == .zero { window.center() }
    window.delegate = WindowCloser.shared
    WindowCloser.shared.onClose = { [weak self] closed in
      self?.windows = self?.windows.filter { $0.value !== closed } ?? [:]
    }
    windows[tab] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// Schließen-Rückmeldung (ein NSWindowDelegate reicht für alle Fenster).
private final class WindowCloser: NSObject, NSWindowDelegate {
  static let shared = WindowCloser()
  var onClose: ((NSWindow) -> Void)?
  func windowWillClose(_ notification: Notification) {
    if let w = notification.object as? NSWindow { onClose?(w) }
  }
}

/// Fensterinhalt: derselbe Reiterinhalt wie in der Insel, dunkel, mit Polster.
private struct ToolWindowRoot: View {
  let tab: TabyTab
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      if tab == .notes {
        // Notizen füllen die Fensterfläche (TabContentView hat eine feste Breite).
        DetachedNotesView(notes: model.state?.notes ?? [], tasks: model.state?.tasks ?? [])
      } else if tab == .settings {
        SettingsWindowView()
      } else {
        // Der Deckel wird auf die Fensterhöhe gesetzt, damit die Listen IM Fenster
        // scrollen (ein fester Riesen-Deckel würde den Scrollbereich größer als das
        // Fenster machen – dann ließe sich nichts bewegen).
        GeometryReader { geo in
          TabContentView(tab: tab)
            .tabyContentCap(max(360, geo.size.height - 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)
        }
      }
    }
    .background(Color(red: 0.055, green: 0.055, blue: 0.065))
    .environment(\.colorScheme, .dark)
    .task { if model.state == nil { await model.refresh() } }
  }
}
