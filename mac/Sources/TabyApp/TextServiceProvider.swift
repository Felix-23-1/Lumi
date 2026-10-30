// Dienst „Mit Lumi erfassen“ (Rechtsklick → Dienste). macOS ruft captureText
// mit der Auswahl im Pasteboard auf; der Text geht an onText.
import AppKit

final class TextServiceProvider: NSObject {
  var onText: ((String) -> Void)?
  var onExplain: ((String) -> Void)?

  @objc func captureText(_ pboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    guard let raw = pboard.string(forType: .string) else { return }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    // Dienste laufen auf dem Hauptthread; der Hop macht den Aufruf für den MainActor explizit.
    Task { @MainActor [weak self] in self?.onText?(text) }
  }

  /// Dienst „Mit Lumi erklären“: dieselbe Auswahl, aber als Erklär-Karte statt Schnellerfassung.
  @objc func explainText(_ pboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    guard let raw = pboard.string(forType: .string) else { return }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    Task { @MainActor [weak self] in self?.onExplain?(String(text.prefix(4000))) }
  }
}
