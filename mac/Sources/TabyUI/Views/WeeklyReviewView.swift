// Wochenplanung (Paket 4): Rückblick auf die Woche (Fokus, erledigt, Termine,
// Habits, Ziele von damals) und drei Ziele für die nächste Woche. Die Hülle
// zeigt diese Karte, solange `state.weeklyReviewPrompt` gesetzt ist.
import SwiftUI
import TabyCore

struct WeeklyReviewView: View {
  let review: WeeklyReview
  @EnvironmentObject private var model: AppModel
  @State private var goals = ["", "", ""]
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "calendar.badge.clock")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.amber)
        Text("Deine Woche")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Theme.text)
        Text("seit \(GermanDate.short(review.weekStart))")
          .font(.system(size: 12))
          .foregroundStyle(Theme.tertiary)
        Spacer(minLength: 0)
      }
      CappedScroll(maxHeight: 270) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            Chip(text: "\(DurationText.hm(review.focusMinutes)) Fokus", symbol: "scope", tint: Theme.blue)
            Chip(text: "\(review.tasksDone) erledigt", symbol: "checkmark.circle", tint: Theme.green)
            Chip(text: "\(review.events) Termine", symbol: "calendar", tint: Theme.purple)
            Spacer(minLength: 0)
          }
          if !review.goals.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              SectionHeader(symbol: "target", title: "Ziele dieser Woche")
              ForEach(review.goals) { g in
                HStack(spacing: 8) {
                  Image(systemName: g.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(g.done ? Theme.green : Theme.tertiary)
                  Text(g.text)
                    .font(.system(size: 13))
                    .foregroundStyle(g.done ? Theme.secondary : Theme.text)
                    .lineLimit(1)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
              }
            }
          }
          VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "arrow.forward.circle", title: "Ziele für nächste Woche", tint: Theme.amber)
            HStack(alignment: .top, spacing: 6) {
              ForEach(0..<3, id: \.self) { i in
                InputCapsule(placeholder: "Ziel \(i + 1)", text: $goals[i])
                  .frame(maxWidth: .infinity)
              }
            }
          }
        }
      }
      HStack(spacing: 8) {
        Button("Diese Woche nicht") { answer(.skip) }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        Button("Später") { answer(.later) }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Button("Speichern") { answer(.save(WeeklyLogic.goals(goals))) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .keyboardShortcut(.return, modifiers: [])
      }
      .disabled(busy)
    }
    .tabyCard(tint: Theme.amber, padding: 14)
  }

  private func answer(_ a: WeeklyReviewAnswer) {
    busy = true
    Task {
      await model.services.answerWeeklyReview(a)
      if case .save = a { model.react(.celebrate) }
      await model.refresh()
      busy = false
    }
  }
}
