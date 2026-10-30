// Markierten Text holen: Cmd+C über CGEvent, Zwischenablage lesen und den
// vorherigen Inhalt wiederherstellen. Braucht die Bedienungshilfen-Freigabe.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
enum SelectionGrabber {
  /// Prüft die Bedienungshilfen-Freigabe; mit `prompt` zeigt macOS den Dialog.
  static func isTrusted(prompt: Bool) -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Kopiert die aktuelle Auswahl und liefert sie getrimmt, sonst nil.
  static func grab() async -> String? {
    guard isTrusted(prompt: false) else { return nil }
    let pasteboard = NSPasteboard.general
    let saved = snapshot(pasteboard)
    let before = pasteboard.changeCount

    postCopy()
    // Bis zu 400 ms auf die Kopie warten.
    var waited = 0
    while pasteboard.changeCount == before && waited < 40 {
      try? await Task.sleep(nanoseconds: 10_000_000)
      waited += 1
    }
    let copied = pasteboard.changeCount != before
      ? pasteboard.string(forType: .string)
      : nil

    restore(pasteboard, saved)

    guard let text = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }

  /// Alle Einträge samt Daten je Typ sichern.
  private static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
    (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
  }

  private static func restore(_ pasteboard: NSPasteboard, _ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
    pasteboard.clearContents()
    let items = saved.map { entries -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in entries { item.setData(data, forType: type) }
      return item
    }
    if !items.isEmpty { pasteboard.writeObjects(items) }
  }

  private static func postCopy() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyCode = CGKeyCode(kVK_ANSI_C)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }
}
