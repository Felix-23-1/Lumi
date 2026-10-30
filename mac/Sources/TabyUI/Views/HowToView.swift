// „So geht’s“: sechs Kacheln mit einer kleinen Zeichnung aus SF-Symbolen und einfachen
// Formen (keine Bilddateien). Steht in der Einrichtung und im Menü der Menüleiste.
import SwiftUI

/// Eine Kachel (rein, prüfbar).
public struct HowToTile: Equatable, Sendable {
  public let title: String
  public let text: String
  public let keys: [String]
}

public enum HowToContent {
  public static let tiles: [HowToTile] = [
    HowToTile(title: "Vorschau", text: "Fahr mit der Maus an die Notch: Lumi zeigt kurz, was ansteht.", keys: []),
    HowToTile(title: "Öffnen und schließen", text: "Klick auf die Notch öffnet Lumi. Esc schließt sie wieder.", keys: ["Esc"]),
    HowToTile(title: "Anheften", text: "Ein Tab mit dem Pin öffnet sich in einem eigenen Fenster, das oben bleibt.", keys: []),
    HowToTile(title: "Datei ablegen", text: "Zieh eine Datei auf die Notch. Lumi öffnet den Chat und schaut sie sich an.", keys: []),
    HowToTile(title: "Befehle und Gedächtnis", text: "„/“ im Chat zeigt Befehle. „Merk dir …“ speichert etwas für später.", keys: ["/"]),
    HowToTile(title: "Schnell erfassen", text: "Ctrl+Option+N für die Schnellerfassung, Ctrl+Option+Leertaste öffnet Lumi.", keys: ["⌃", "⌥", "N"]),
  ]
}

public struct HowToView: View {
  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("So geht’s").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(Array(HowToContent.tiles.enumerated()), id: \.offset) { index, tile in
          HowToTileView(index: index, tile: tile)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

private struct HowToTileView: View {
  let index: Int
  let tile: HowToTile

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HowToIllustration(index: index)
        .frame(width: 58, height: 58)
      VStack(alignment: .leading, spacing: 3) {
        Text(tile.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
          .fixedSize(horizontal: false, vertical: true)
        Text(tile.text).font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
  }
}

/// Die kleine Zeichnung je Kachel: Formen und Symbole, passend zum Text.
private struct HowToIllustration: View {
  let index: Int

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised)
      switch index {
      case 0:
        // Notch oben, Mauszeiger darunter.
        VStack(spacing: 4) {
          Capsule().fill(Theme.text.opacity(0.85)).frame(width: 34, height: 8)
          Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(Theme.amber)
        }
      case 1:
        Image(systemName: "hand.tap.fill").font(.system(size: 24)).foregroundStyle(Theme.amber)
          .offset(x: -8, y: 4)
        KeyCap(key: "Esc").scaleEffect(0.8).offset(x: 14, y: -14)
      case 2:
        Image(systemName: "pin.fill").font(.system(size: 20)).foregroundStyle(Theme.amber)
          .offset(x: -10, y: -8)
        RoundedRectangle(cornerRadius: 4).stroke(Theme.text.opacity(0.7), lineWidth: 1.5)
          .frame(width: 26, height: 20).offset(x: 10, y: 10)
      case 3:
        Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(Theme.text.opacity(0.85))
          .offset(x: -6, y: -8)
        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.amber)
          .offset(x: 10, y: 12)
      case 4:
        Image(systemName: "slash.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.amber)
          .offset(x: -10, y: 0)
        Image(systemName: "brain.head.profile").font(.system(size: 20)).foregroundStyle(Theme.text.opacity(0.85))
          .offset(x: 12, y: 8)
      default:
        HStack(spacing: 2) {
          KeyCap(key: "⌃").scaleEffect(0.7)
          KeyCap(key: "⌥").scaleEffect(0.7)
          KeyCap(key: "N").scaleEffect(0.7)
        }
        .offset(y: -10)
        Capsule().fill(Theme.amber.opacity(0.7)).frame(width: 30, height: 5).offset(y: 12)
      }
    }
    .clipped()
  }
}
