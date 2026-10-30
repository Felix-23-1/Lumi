// Fokus-Countdown in der eingeklappten Insel (rechter Flügel) und als
// Statuszeile in der offenen Insel. Reine Rechenhilfen bekommen `now`
// übergeben (prüfbar); nur die Ansicht nutzt die echte Uhr (TimelineView,
// 1 s, läuft nur solange ein Fokus aktiv ist).
import SwiftUI
import TabyCore

enum FocusClock {
  /// Verbleibende Sekunden (nie negativ).
  static func remaining(_ f: FocusSession, now: Date) -> Int {
    guard let end = LocalTime.parse(f.endsAt) else { return 0 }
    // Angehalten: die Restzeit bleibt auf dem Stand vom Anhalten stehen.
    let ref = f.pausedAt.flatMap(LocalTime.parse) ?? now
    return max(0, Int(end.timeIntervalSince(ref).rounded(.down)))
  }

  /// Anteil vergangen 0…1.
  static func progress(_ f: FocusSession, now: Date) -> Double {
    let total = Double(max(1, f.minutes * 60))
    return min(1, max(0, 1 - Double(remaining(f, now: now)) / total))
  }

  /// "mm:ss" (ab einer Stunde "h:mm:ss").
  static func format(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
  }

  static func statusLine(_ f: FocusSession, now: Date) -> String {
    (f.phase == .work ? "Fokus · " : "Pause · ") + format(remaining(f, now: now))
  }

  static func color(_ f: FocusSession) -> Color {
    f.phase == .work ? MascotMood.alert.color : MascotMood.happy.color
  }
}

struct FocusCountdown: View {
  let session: FocusSession
  let large: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { ctx in
      let c = FocusClock.color(session)
      HStack(spacing: 4) {
        ZStack {
          Circle().stroke(c.opacity(0.25), lineWidth: 2)
          Circle().trim(from: 0, to: FocusClock.progress(session, now: ctx.date))
            .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        .frame(width: large ? 12 : 10, height: large ? 12 : 10)
        Text(FocusClock.format(FocusClock.remaining(session, now: ctx.date)))
          .font(.system(size: large ? 12 : 10.5, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white.opacity(0.92))
          .contentTransition(.numericText(countsDown: true))
      }
      .fixedSize()
    }
  }
}
