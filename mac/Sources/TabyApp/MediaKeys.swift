// Mediatasten des Systems (Play/Pause, Weiter, Zurück): steuern, was gerade abspielt – auch YouTube im Browser.
// Braucht die Bedienungshilfen-Freigabe, sonst kommen die Tasten nicht an.
import AppKit
import ApplicationServices
import TabyCore

enum MediaKeys {
  static func send(_ command: MediaCommand) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    // NX_KEYTYPE_PLAY = 16, NEXT = 17, PREVIOUS = 18
    let key: Int = command == .playPause ? 16 : command == .next ? 17 : 18
    for down in [true, false] {
      let flags = down ? 0xA00 : 0xB00
      let event = NSEvent.otherEvent(
        with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | flags, data2: -1)
      event?.cgEvent?.post(tap: .cghidEventTap)
    }
    return true
  }
}
