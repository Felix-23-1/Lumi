// Kleine eingebaute Herstellerliste (OUI = erste drei Bytes der MAC). Bewusst
// nur eine Auswahl gängiger Präfixe fürs Heimnetz; unbekannte MACs bleiben ohne
// Hersteller. Zufällige (private) MACs werden erkannt, nicht nachgeschlagen.
import Foundation

public enum OUIVendors {
  static let randomizedLabel = "Private Adresse (zufällig)"

  static let entries: [(String, String)] = [
    // Apple
    ("00:03:93", "Apple"), ("00:0a:27", "Apple"), ("00:0a:95", "Apple"), ("00:11:24", "Apple"),
    ("00:14:51", "Apple"), ("00:16:cb", "Apple"), ("00:17:f2", "Apple"), ("00:1b:63", "Apple"),
    ("00:1c:b3", "Apple"), ("00:1e:c2", "Apple"), ("00:1f:5b", "Apple"), ("00:21:e9", "Apple"),
    ("00:25:00", "Apple"), ("00:26:b0", "Apple"), ("3c:07:54", "Apple"), ("40:a6:d9", "Apple"),
    ("58:b0:35", "Apple"), ("64:20:0c", "Apple"), ("70:56:81", "Apple"), ("88:66:a5", "Apple"),
    ("a4:5e:60", "Apple"), ("a8:5b:78", "Apple"), ("bc:52:b7", "Apple"), ("d0:03:4b", "Apple"),
    ("f0:18:98", "Apple"), ("f4:f1:5a", "Apple"), ("f8:1e:df", "Apple"),
    // AVM / FRITZ!
    ("00:04:0e", "AVM (FRITZ!)"), ("3c:37:86", "AVM (FRITZ!)"), ("1c:ed:6f", "AVM (FRITZ!)"),
    ("9c:c7:a6", "AVM (FRITZ!)"), ("c8:0e:14", "AVM (FRITZ!)"), ("2c:91:ab", "AVM (FRITZ!)"),
    // Samsung
    ("00:07:ab", "Samsung"), ("00:12:fb", "Samsung"), ("00:15:99", "Samsung"), ("08:d4:2b", "Samsung"),
    ("34:23:ba", "Samsung"), ("5c:0a:5b", "Samsung"), ("78:47:1d", "Samsung"), ("8c:77:12", "Samsung"),
    ("f4:7b:5e", "Samsung"),
    // Google / Nest
    ("3c:5a:b4", "Google"), ("f4:f5:d8", "Google"), ("54:60:09", "Google"), ("18:b4:30", "Google Nest"),
    ("64:16:66", "Google Nest"),
    // Amazon
    ("44:65:0d", "Amazon"), ("74:c2:46", "Amazon"), ("0c:47:c9", "Amazon"), ("f0:27:2d", "Amazon"),
    ("68:37:e9", "Amazon"), ("40:b4:cd", "Amazon"), ("84:d6:d0", "Amazon"),
    // Sonos
    ("00:0e:58", "Sonos"), ("48:a6:b8", "Sonos"), ("54:2a:1b", "Sonos"), ("94:9f:3e", "Sonos"),
    ("b8:e9:37", "Sonos"),
    // Raspberry Pi
    ("b8:27:eb", "Raspberry Pi"), ("dc:a6:32", "Raspberry Pi"), ("e4:5f:01", "Raspberry Pi"),
    ("d8:3a:dd", "Raspberry Pi"), ("2c:cf:67", "Raspberry Pi"),
    // Espressif (ESP8266/ESP32, viele Smart-Home-Geräte)
    ("24:0a:c4", "Espressif"), ("30:ae:a4", "Espressif"), ("7c:9e:bd", "Espressif"),
    ("84:f3:eb", "Espressif"), ("a4:cf:12", "Espressif"), ("24:6f:28", "Espressif"),
    ("3c:61:05", "Espressif"),
    // Intel
    ("00:1b:21", "Intel"), ("3c:97:0e", "Intel"), ("7c:7a:91", "Intel"),
    // TP-Link
    ("14:cc:20", "TP-Link"), ("50:c7:bf", "TP-Link"), ("98:da:c4", "TP-Link"), ("a0:f3:c1", "TP-Link"),
    ("f4:f2:6d", "TP-Link"), ("ec:08:6b", "TP-Link"),
    // Netgear
    ("00:1b:2f", "Netgear"), ("20:e5:2a", "Netgear"), ("9c:3d:cf", "Netgear"), ("a4:2b:b0", "Netgear"),
    ("c4:04:15", "Netgear"), ("2c:b0:5d", "Netgear"),
    // Ubiquiti
    ("00:15:6d", "Ubiquiti"), ("24:a4:3c", "Ubiquiti"), ("78:8a:20", "Ubiquiti"), ("dc:9f:db", "Ubiquiti"),
    ("fc:ec:da", "Ubiquiti"),
    // Xiaomi
    ("34:ce:00", "Xiaomi"), ("64:09:80", "Xiaomi"), ("78:11:dc", "Xiaomi"), ("28:6c:07", "Xiaomi"),
    ("f8:a4:5f", "Xiaomi"),
    // Huawei
    ("00:e0:fc", "Huawei"), ("48:46:fb", "Huawei"), ("70:72:3c", "Huawei"), ("ac:cf:85", "Huawei"),
    ("00:18:82", "Huawei"),
    // LG
    ("00:1c:62", "LG"), ("10:f1:f2", "LG"), ("64:99:5d", "LG"), ("a8:23:fe", "LG"), ("00:1e:75", "LG"),
    // Sony
    ("00:01:4a", "Sony"), ("00:24:be", "Sony"), ("04:5d:4b", "Sony"), ("28:0d:fc", "Sony"),
    ("f8:46:1c", "Sony"),
    // Philips Hue (Signify)
    ("00:17:88", "Philips Hue (Signify)"), ("ec:b5:fa", "Philips Hue (Signify)"),
    // Nintendo
    ("00:09:bf", "Nintendo"), ("00:17:ab", "Nintendo"), ("00:1f:32", "Nintendo"), ("98:b6:e9", "Nintendo"),
    ("e8:4e:ce", "Nintendo"),
    // Microsoft
    ("00:03:ff", "Microsoft"), ("00:12:5a", "Microsoft"), ("28:18:78", "Microsoft"), ("7c:1e:52", "Microsoft"),
    ("00:50:f2", "Microsoft"),
    // Dell
    ("00:14:22", "Dell"), ("00:1a:a0", "Dell"), ("f8:bc:12", "Dell"), ("18:03:73", "Dell"),
    ("b8:ca:3a", "Dell"),
    // HP
    ("00:01:e6", "HP"), ("00:0b:cd", "HP"), ("3c:d9:2b", "HP"), ("9c:b6:54", "HP"), ("10:60:4b", "HP"),
    // Brother
    ("00:80:77", "Brother"), ("30:05:5c", "Brother"), ("00:1b:a9", "Brother"),
    // Canon
    ("00:1e:8f", "Canon"), ("00:bb:c1", "Canon"),
    // Synology / QNAP
    ("00:11:32", "Synology"), ("90:09:d0", "Synology"), ("00:08:9b", "QNAP"), ("24:5e:be", "QNAP"),
    // Tuya / Shelly (Smart-Home)
    ("50:8a:06", "Tuya"), ("84:e3:27", "Tuya"), ("34:94:54", "Shelly"), ("e8:db:84", "Shelly"),
    ("98:cd:ac", "Shelly"),
  ]

  static let table: [String: String] = Dictionary(entries, uniquingKeysWith: { first, _ in first })

  /// Hersteller zur MAC; nil bei ungültiger oder unbekannter MAC.
  /// Zufällige (locally administered) MACs liefern "Private Adresse (zufällig)".
  public static func vendor(forMAC mac: String) -> String? {
    guard let n = NetworkAddress.normalizeMAC(mac) else { return nil }
    let parts = n.split(separator: ":")
    // Zweite Hex-Ziffer des ersten Bytes: 2, 6, a oder e = lokal verwaltet (zufällig).
    if let second = parts[0].last, "26ae".contains(second) {
      return randomizedLabel
    }
    return table[parts.prefix(3).joined(separator: ":")]
  }
}
