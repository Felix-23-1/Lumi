// Text aus Dateien für die Notch (Paket 4): PDF (PDFKit), Bilder (Vision-OCR),
// Dokumente (NSAttributedString) und Klartext. Reiner Code, kein Netz.
import Foundation
import PDFKit
import Vision

public enum FileTextError: Error, LocalizedError, Equatable {
  /// Binärdatei oder Format ohne Textauszug.
  case unsupported
  /// Kein Text gefunden (leere Datei, Scan ohne erkennbaren Text).
  case empty
  case unreadable(String)
  /// Größer als `FileTextExtractor.maxBytes`: wird gar nicht erst gelesen.
  case tooLarge

  public var errorDescription: String? {
    switch self {
    case .unsupported: return "Dieser Dateityp wird nicht unterstützt."
    case .empty: return "In der Datei steht kein lesbarer Text."
    case .unreadable(let detail): return "Die Datei kann nicht gelesen werden: \(detail)"
    case .tooLarge: return "Die Datei ist größer als 20 MB."
    }
  }
}

public enum FileTextExtractor {
  /// Dateiendungen mit eigener Behandlung (andere werden als Klartext gelesen).
  public static let supportedExtensions: [String] = [
    "txt", "md", "csv", "json", "log", "pdf", "png", "jpg", "jpeg", "heic", "tiff", "gif",
    "rtf", "rtfd", "doc", "docx", "odt", "html", "htm",
  ]

  /// Obergrenze für Dateien, die gelesen werden (vorher geprüft, damit nichts den Speicher füllt).
  public static let maxBytes = 20 * 1024 * 1024

  private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]
  private static let documentTypes: [String: NSAttributedString.DocumentType] = [
    "rtf": .rtf, "rtfd": .rtfd, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument,
    "html": .html, "htm": .html,
  ]

  /// Liest den Text einer Datei. Ergebnis getrimmt und auf `maxChars` Zeichen gekürzt.
  public static func extract(_ url: URL, maxChars: Int = 20000) throws -> String {
    let ext = url.pathExtension.lowercased()
    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes {
      throw FileTextError.tooLarge
    }
    let raw: String
    if ext == "pdf" {
      raw = try pdfText(url)
    } else if imageExtensions.contains(ext) {
      raw = try ocrText(url)
    } else if (ext == "html" || ext == "htm") && !Thread.isMainThread {
      raw = try htmlText(url)
    } else if documentTypes[ext] != nil {
      raw = try documentText(url, ext: ext)
    } else {
      raw = try plainText(url)
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw FileTextError.empty }
    return String(trimmed.prefix(max(0, maxChars)))
  }

  private static func pdfText(_ url: URL) throws -> String {
    guard let document = PDFDocument(url: url) else {
      throw FileTextError.unreadable("PDF lässt sich nicht öffnen")
    }
    return document.string ?? ""
  }

  /// Texterkennung mit Vision (genau, Deutsch und Englisch).
  private static func ocrText(_ url: URL) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["de-DE", "en-US"]
    request.usesLanguageCorrection = true
    do {
      try VNImageRequestHandler(url: url, options: [:]).perform([request])
    } catch {
      throw FileTextError.unreadable(error.localizedDescription)
    }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    return lines.joined(separator: "\n")
  }

  private static func documentText(_ url: URL, ext: String) throws -> String {
    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
    if let type = documentTypes[ext] { options[.documentType] = type }
    do {
      return try NSAttributedString(url: url, options: options, documentAttributes: nil).string
    } catch {
      throw FileTextError.unreadable(error.localizedDescription)
    }
  }

  /// HTML außerhalb des Hauptthreads ohne NSAttributedString (dessen HTML-Import läuft über WebKit).
  /// shortcut: entfernt Skript-/Stil-Blöcke und Tags, kennt nur die gängigsten Entities; komplexes HTML auf dem Hauptthread lesen.
  private static func htmlText(_ url: URL) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw FileTextError.unreadable(error.localizedDescription)
    }
    var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    text = text.replacingOccurrences(of: "<(script|style)\\b.*?</\\1\\s*>", with: " ",
                                     options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
      text = text.replacingOccurrences(of: entity, with: char)
    }
    return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
  }

  /// Klartext: UTF-8, sonst ISO-Latin-1. Dateien mit Null-Bytes gelten als binär.
  private static func plainText(_ url: URL) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw FileTextError.unreadable(error.localizedDescription)
    }
    guard !data.contains(0) else { throw FileTextError.unsupported }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
  }
}
