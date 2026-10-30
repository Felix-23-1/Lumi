// Liedtext-Panel unter der Now-Playing-Karte: ruhig, gut lesbar, ca. 160 pt hoch.
import SwiftUI

struct MusicLyricsView: View {
  let state: LyricsState

  static let height: CGFloat = 160

  var body: some View {
    Group {
      if case .text(let lines) = state {
        CappedScroll(maxHeight: Self.height) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              if line.isEmpty {
                Color.clear.frame(height: 8)
              } else {
                Text(line).font(.system(size: 13)).foregroundStyle(Theme.text)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(.vertical, 2)
        }
      } else if let message = MusicLogic.lyricsMessage(state) {
        Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tabyCard(padding: 10)
    .accessibilityLabel("Liedtext")
  }
}
