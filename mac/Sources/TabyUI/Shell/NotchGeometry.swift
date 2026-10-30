// Notch-Geometrie: welcher Bildschirm trägt die Insel und wie groß ist die
// (echte oder virtuelle) Notch. Der rechnende Teil ist rein (prüfbar), nur
// `NotchScreenLocator` fasst AppKit an.
import AppKit
import Foundation

/// Ruhende Notch-Maße eines Bildschirms (AppKit-Punkte).
struct NotchGeometry: Equatable {
  /// Breite einer virtuellen Notch auf Bildschirmen ohne Kamera-Aussparung
  /// (externer Monitor, Deckel zu).
  static let virtualNotchWidth: CGFloat = 180
  /// Wenn die Menüleiste ausgeblendet ist (Höhe 0), trotzdem eine Pille zeigen.
  static let fallbackHeight: CGFloat = 32
  /// Plausible Notch-Breite, falls macOS keine Hilfsflächen liefert.
  static let fallbackNotchWidth: CGFloat = 200

  let hasNotch: Bool
  let notchWidth: CGFloat
  let notchHeight: CGFloat
  /// Rahmen des Bildschirms im globalen AppKit-Raum (Ursprung unten links).
  let screenFrame: CGRect

  init(hasNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat, screenFrame: CGRect) {
    self.hasNotch = hasNotch
    self.notchWidth = notchWidth
    self.notchHeight = notchHeight
    self.screenFrame = screenFrame
  }

  /// Aus den Rohwerten eines `NSScreen` (rein, damit prüfbar).
  init(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
       menuBarHeight: CGFloat) {
    self.screenFrame = screenFrame
    if safeAreaTop > 0 {
      hasNotch = true
      notchHeight = safeAreaTop
      if let l = auxiliaryLeftWidth, let r = auxiliaryRightWidth {
        let measured = screenFrame.width - l - r
        notchWidth = measured > 40 && measured < screenFrame.width / 2 ? measured : Self.fallbackNotchWidth
      } else {
        notchWidth = Self.fallbackNotchWidth
      }
    } else {
      hasNotch = false
      notchWidth = Self.virtualNotchWidth
      notchHeight = menuBarHeight > 12 ? menuBarHeight : Self.fallbackHeight
    }
  }

  /// MacBook-ähnliche Standardwerte (Vorschauen, Snapshots).
  static let preview = NotchGeometry(hasNotch: true, notchWidth: 200, notchHeight: 34,
                                     screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
  /// Externer Monitor ohne Notch (Vorschauen, Snapshots).
  static let previewNoNotch = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 25)
}

/// Kandidat für die Bildschirmwahl (Reihenfolge wie `NSScreen.screens`).
struct ScreenCandidate: Equatable {
  let hasNotch: Bool
  let isMain: Bool
}

enum ScreenChooser {
  /// Bildschirm mit Notch, sonst der Hauptbildschirm, sonst der erste.
  static func index(in candidates: [ScreenCandidate]) -> Int? {
    if candidates.isEmpty { return nil }
    return candidates.firstIndex { $0.hasNotch } ?? candidates.firstIndex { $0.isMain } ?? 0
  }
}

@MainActor
enum NotchScreenLocator {
  static func geometry(of screen: NSScreen) -> NotchGeometry {
    let frame = screen.frame
    return NotchGeometry(screenFrame: frame, safeAreaTop: screen.safeAreaInsets.top,
                         auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                         auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
                         menuBarHeight: frame.maxY - screen.visibleFrame.maxY)
  }

  /// Der Bildschirm, der die Insel tragen soll, samt Geometrie.
  static func current() -> (NSScreen, NotchGeometry)? {
    let screens = NSScreen.screens
    let candidates = screens.map { ScreenCandidate(hasNotch: $0.safeAreaInsets.top > 0, isMain: $0 == NSScreen.main) }
    guard let i = ScreenChooser.index(in: candidates) else { return nil }
    return (screens[i], geometry(of: screens[i]))
  }
}
