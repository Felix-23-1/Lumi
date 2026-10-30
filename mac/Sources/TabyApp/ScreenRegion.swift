// „Einkreisen und fragen“: Überlagerung zum freien Einkreisen (eine pro Bildschirm) und Aufnahme des Ausschnitts.
import AppKit
import ScreenCaptureKit
import TabyUI

/// Ergebnis der Auswahl: Rechteck in Punkten (Ursprung oben links) auf dem Bildschirm mit dieser ID.
struct RegionSelection {
  let rect: CGRect
  let displayID: CGDirectDisplayID
}

private final class OverlayWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
  var onFinish: (([CGPoint]?) -> Void)?
  private var path: [CGPoint] = []

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

  override func mouseDown(with event: NSEvent) { path = [convert(event.locationInWindow, from: nil)]; needsDisplay = true }
  override func mouseDragged(with event: NSEvent) { path.append(convert(event.locationInWindow, from: nil)); needsDisplay = true }
  override func mouseUp(with event: NSEvent) {
    path.append(convert(event.locationInWindow, from: nil))
    onFinish?(path)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.25).setFill()
    bounds.fill()
    guard path.count > 1 else { return }
    let line = NSBezierPath()
    line.move(to: path[0])
    path.dropFirst().forEach { line.line(to: $0) }
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.systemPurple
    glow.shadowBlurRadius = 12
    glow.set()
    NSColor.white.setStroke()
    line.lineWidth = 4
    line.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }
}

@MainActor
final class RegionSelector {
  private var windows: [OverlayWindow] = []
  private var continuation: CheckedContinuation<RegionSelection?, Never>?

  /// Zeigt die Überlagerung und liefert die Auswahl, nil bei Esc. Alle Fenster sind danach geschlossen.
  func select() async -> RegionSelection? {
    await withCheckedContinuation { cont in
      continuation = cont
      for screen in NSScreen.screens { addWindow(for: screen) }
      NSApp.activate(ignoringOtherApps: true)
      windows.first?.makeKeyAndOrderFront(nil)
    }
  }

  /// Bricht eine laufende Auswahl ab (z. B. zweiter Tastendruck).
  func cancel() { finish(nil, on: nil) }

  private func addWindow(for screen: NSScreen) {
    let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.onFinish = { [weak self, weak screen] path in self?.finish(path, on: screen) }
    window.contentView = view
    window.makeFirstResponder(view)
    window.orderFrontRegardless()
    windows.append(window)
  }

  private func finish(_ path: [CGPoint]?, on screen: NSScreen?) {
    guard let cont = continuation else { return }
    continuation = nil
    var result: RegionSelection?
    if let path, let screen, let id = screen.displayID,
       let rect = CircleLogic.boundingRect(path: path, padding: 8, minSize: 24,
                                           bounds: CGRect(origin: .zero, size: screen.frame.size)) {
      result = RegionSelection(rect: rect, displayID: id)
    }
    windows.forEach { $0.orderOut(nil); $0.close() }
    windows.removeAll()
    cont.resume(returning: result)
  }
}

private extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

enum ScreenRegionCapture {
  /// Fragt die Bildschirmaufnahme-Freigabe ab; ohne sie wird einmal angefragt und false geliefert.
  static func ensureAccess() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    _ = CGRequestScreenCaptureAccess()
    return false
  }

  /// Nimmt nur den Ausschnitt auf (Retina-genau), nil bei Fehler.
  static func capture(_ selection: RegionSelection) async -> CGImage? {
    guard let content = try? await SCShareableContent.current,
          let display = content.displays.first(where: { $0.displayID == selection.displayID }) else { return nil }
    let config = SCStreamConfiguration()
    config.sourceRect = selection.rect
    let scale = NSScreen.screens.first(where: { $0.displayID == selection.displayID })?.backingScaleFactor ?? 2
    config.width = Int(selection.rect.width * scale)
    config.height = Int(selection.rect.height * scale)
    config.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
}
