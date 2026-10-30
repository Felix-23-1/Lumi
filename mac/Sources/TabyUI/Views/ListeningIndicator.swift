// Anzeige einer laufenden Mitschrift: in der geschlossenen Notch rechts ein Punkt mit der Zeit
// (wie der Fokus-Countdown), in der offenen Insel eine Leiste unten mit „Aufgabe!“ und „Stopp“.
// Die Aufnahme läuft nie unsichtbar.
import SwiftUI
import TabyCore

/// Geschlossene Notch: roter Punkt und „mm:ss“.
struct ListeningBadge: View {
  let listening: MeetingListening
  let large: Bool
  @Environment(\.tabyNow) private var nowEnv

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      HStack(spacing: 4) {
        Circle().fill(Theme.red).frame(width: 6, height: 6).shadow(color: Theme.red, radius: 4)
        Text(ListeningLogic.elapsedText(startedAt: listening.startedAt, now: NowResolver.now(nowEnv)))
          .font(.system(size: large ? 13 : 11, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.92))
      }
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(Capsule().fill(Theme.red.opacity(0.18)))
      .fixedSize()
      .help("Mitschrift läuft")
      .accessibilityLabel("Mitschrift läuft")
    }
  }
}

/// Offene Insel, unten: Laufzeit, Zeilen, „Aufgabe!“ (Merker) und „Stopp“.
struct ListeningStrip: View {
  let listening: MeetingListening
  let model: AppModel
  @Environment(\.tabyNow) private var nowEnv
  @State private var feedback: String?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      HStack(spacing: 8) {
        Circle().fill(Theme.red).frame(width: 7, height: 7).shadow(color: Theme.red, radius: 4)
        Text("Mitschrift läuft · \(ListeningLogic.elapsedText(startedAt: listening.startedAt, now: NowResolver.now(nowEnv)))")
          .monospacedDigit()
          .lineLimit(1)
        Text(feedback ?? ListeningLogic.linesText(listening.lines))
          .foregroundStyle(.white.opacity(0.6))
          .lineLimit(1)
        Spacer(minLength: 0)
        Button("Aufgabe!") { markMoment() }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .help("Die letzten Sekunden als Aufgabe merken")
        Button("Stopp") { stop() }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      }
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(.white.opacity(0.92))
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Capsule().fill(Color.black.opacity(0.85)))
      .overlay(Capsule().strokeBorder(Theme.red.opacity(0.35), lineWidth: 1))
      .padding(.horizontal, 14)
    }
  }

  private func markMoment() {
    Task {
      await model.services.markMeetingMoment()
      await model.refresh()
      feedback = "Merker gesetzt"
      try? await Task.sleep(for: .seconds(2))
      feedback = nil
    }
  }

  private func stop() {
    Task {
      await model.services.stopMeetingListening()
      await model.refresh()
    }
  }
}
