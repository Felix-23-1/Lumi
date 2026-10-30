// Globale Kurzbefehle (Carbon RegisterEventHotKey – braucht keine
// Bedienungshilfen-Freigabe, anders als ein globaler Tastatur-Monitor).
// Format wie in den Einstellungen: "Control+Option+Space", "Control+Option+N".
import Carbon
import Foundation
import TabyUI

@MainActor
final class HotKeyCenter {
  private struct Actions {
    let onPress: () -> Void
    let onRelease: (() -> Void)?
  }

  private var refs: [UInt32: EventHotKeyRef] = [:]
  private var actions: [UInt32: Actions] = [:]
  private var nextId: UInt32 = 1
  private var handler: EventHandlerRef?

  init() {
    var specs = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
      guard let event, let userData else { return noErr }
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
      let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
      let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
      let id = hk.id
      Task { @MainActor in
        guard let entry = center.actions[id] else { return }
        if isRelease { entry.onRelease?() } else { entry.onPress() }
      }
      return noErr
    }, specs.count, &specs, selfPtr, &handler)
  }

  func unregisterAll() {
    for ref in refs.values { UnregisterEventHotKey(ref) }
    refs.removeAll()
    actions.removeAll()
  }

  /// false, wenn das Kürzel ungültig ist oder schon vom System/einer App belegt.
  @discardableResult
  func register(_ shortcut: String, action: @escaping () -> Void) -> Bool {
    register(shortcut, onPress: action, onRelease: nil)
  }

  /// Wie `register(_:action:)`, zusätzlich mit Aktion beim Loslassen (z. B. Sprechen-Taste).
  @discardableResult
  func register(_ shortcut: String, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> Bool {
    register(shortcut, onPress: onPress, onRelease: Optional(onRelease))
  }

  private func register(_ shortcut: String, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> Bool {
    guard let (keyCode, modifiers) = Self.parse(shortcut) else { return false }
    let id = nextId
    nextId += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5442_5959), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else { return false }
    refs[id] = ref
    actions[id] = Actions(onPress: onPress, onRelease: onRelease)
    return true
  }

  static func parse(_ shortcut: String) -> (UInt32, UInt32)? {
    var mods: UInt32 = 0
    var key: UInt32?
    for raw in shortcut.split(separator: "+") {
      let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
      switch part {
      case "control", "ctrl": mods |= UInt32(controlKey)
      case "option", "alt": mods |= UInt32(optionKey)
      case "command", "cmd": mods |= UInt32(cmdKey)
      case "shift": mods |= UInt32(shiftKey)
      default: key = ShortcutKeys.codes[part]
      }
    }
    guard let key, mods != 0 else { return nil }
    return (key, mods)
  }
}
