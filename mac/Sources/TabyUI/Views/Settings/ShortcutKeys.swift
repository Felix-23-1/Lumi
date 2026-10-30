// Tastennamen für Kurzbefehle: dieselbe Tabelle für die Aufnahme in den Einstellungen und für die
// Registrierung (TabyApp/HotKeys). Die Codes sind die Tastenpositionen (ANSI), unabhängig vom Layout:
// eine QWERTZ-Taste landet darum auf derselben Position wie ihr Code in der Tabelle.
import Carbon
import Foundation

public enum ShortcutKeys {
  /// Name → virtueller Tastencode.
  public static let codes: [String: UInt32] = {
    var m: [String: UInt32] = [
      "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
      "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape),
    ]
    let letters: [(String, Int)] = [
      ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
      ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
      ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
      ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
      ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
      ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
      ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
      ("9", kVK_ANSI_9),
    ]
    for (k, v) in letters { m[k] = UInt32(v) }
    return m
  }()

  /// Umkehrung: Tastencode → Name. nil, wenn die Taste keinen Namen hat (dann nimmt die Aufnahme sie nicht).
  /// „enter“ und „return“ teilen sich einen Code; es gilt „return“.
  public static func name(forKeyCode code: UInt16) -> String? {
    names[UInt32(code)]
  }

  private static let names: [UInt32: String] = {
    var m: [UInt32: String] = [:]
    for (name, code) in codes {
      if let existing = m[code], existing == "return" { continue }
      m[code] = name == "enter" ? "return" : name
    }
    return m
  }()
}
