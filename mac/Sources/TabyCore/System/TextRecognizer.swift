// Texterkennung im Bildschirmausschnitt (Vision, Deutsch und Englisch). Läuft
// außerhalb des Hauptthreads; das Ergebnis ist reiner Text für die Fragen-/Erklär-Wege.
import CoreGraphics
import Foundation
import Vision

public enum TextRecognizer {
  /// Obergrenze für den erkannten Text (Zeichen).
  static let maxChars = 4000

  public static func recognize(_ image: CGImage) async -> ToolResult<String> {
    await Task.detached(priority: .userInitiated) { () -> ToolResult<String> in
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["de-DE", "en-US"]
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = true
      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      } catch {
        return .failure(code: "ERROR", error: "Der Text im Ausschnitt konnte nicht gelesen werden.")
      }
      // Vision liefert Zeilen mit normierten Rahmen (Ursprung unten links): oben nach unten, bei gleicher Höhe links nach rechts.
      let observations = (request.results ?? []).sorted { a, b in
        abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
          ? a.boundingBox.midY > b.boundingBox.midY
          : a.boundingBox.minX < b.boundingBox.minX
      }
      let lines = observations.compactMap { $0.topCandidates(1).first?.string }
      let text = String(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
      guard !text.isEmpty else {
        return .failure(code: "NO_TEXT", error: "Im Ausschnitt habe ich keinen Text erkannt.")
      }
      return .ok(text)
    }.value
  }
}
