// Fokus-Timer in "Heute": laufende Sitzung mit Countdown und Ring, sonst ein
// Start-Knopf. Die Restzeit-Rechnung ist rein (bekommt `now`); nur die
// Anzeige nutzt die echte Uhr (TimelineView, 1 s, nur solange ein Fokus läuft).
import SwiftUI
import TabyCore

enum FocusLogic {
  static func remaining(endsAt: String, now: Date) -> Int {
    guard let end = LocalTime.parse(endsAt) else { return 0 }
    return max(0, Int(end.timeIntervalSince(now).rounded(.down)))
  }

  static func format(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%02d:%02d", s / 60, s % 60)
  }

  static func todayLine(_ minutes: Int) -> String? {
    guard minutes > 0 else { return nil }
    if minutes < 60 { return "Heute fokussiert: \(minutes) Min" }
    return "Heute fokussiert: \(minutes / 60) Std \(minutes % 60) Min"
  }
}

struct FocusCard: View {
  let state: AppState
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot
  /// Ergebnis von „Was jetzt?“ (nur Anzeige, bis zum nächsten Druck).
  @State private var pick: WhatNowPick?
  @State private var pickError: String?

  /// `pick` nur für Snapshots: Ergebnis von „Was jetzt?“ sofort zeigen.
  init(state: AppState, pick: WhatNowPick? = nil) {
    self.state = state
    _pick = State(initialValue: pick)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let f = state.focus {
        running(f)
      } else {
        HStack(spacing: 8) {
          Button {
            Task {
              _ = await model.services.startFocus(taskId: nil, minutes: nil)
              await model.refresh()
            }
          } label: {
            Label("Fokus starten · \(state.settings.focusMinutes) Min", systemImage: "timer").lineLimit(1)
          }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .fixedSize()
          // Zweitknopf: klein, ohne Füllung. Pause und Statistik liegen im „…“-Menü der Kopfzeile.
          Button { whatNow() } label: {
            Label("Was jetzt?", systemImage: "sparkles").lineLimit(1)
          }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          .fixedSize()
          .help("Nächste Aufgabe wählen und Fokus dafür starten")
          Spacer(minLength: 0)
        }
      }
      // Auch nach dem Start sichtbar: „Was jetzt?“ startet den Fokus selbst.
      if let pick {
        (Text("Jetzt: ").foregroundStyle(Theme.secondary)
          + Text(pick.task.title).fontWeight(.semibold).foregroundStyle(Theme.text)
          + Text(" – \(pick.reason)").foregroundStyle(Theme.secondary))
          .font(.system(size: 12))
          .lineLimit(2)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.12)))
      }
      if let pickError {
        Text(pickError).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
      }
    }
  }

  private func whatNow() {
    Task {
      switch await model.services.whatNow() {
      case .ok(let p): pick = p; pickError = nil
      case .failure(_, let error): pick = nil; pickError = error
      }
      await model.refresh()
    }
  }

  private func running(_ f: FocusSession) -> some View {
    let tint = f.phase == .work ? Theme.amber : Theme.green
    return TimelineView(.periodic(from: .now, by: 1)) { ctx in
      // Angehalten: der Countdown steht auf dem Stand vom Anhalten.
      let now = f.pausedAt.flatMap(LocalTime.parse)
        ?? (snapshot ? (LocalTime.parse(f.startedAt) ?? ctx.date).addingTimeInterval(Double(f.minutes) * 24) : ctx.date)
      let left = FocusLogic.remaining(endsAt: f.endsAt, now: now)
      let progress = 1 - Double(left) / Double(max(1, f.minutes * 60))
      HStack(spacing: 12) {
        ZStack {
          Circle().stroke(tint.opacity(0.2), lineWidth: 4)
          Circle().trim(from: 0, to: progress)
            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Image(systemName: f.phase == .work ? "brain.head.profile" : "cup.and.saucer.fill")
            .font(.system(size: 13)).foregroundStyle(tint)
        }
        .frame(width: 40, height: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(f.pausedAt != nil ? "Angehalten" : (f.phase == .work ? "Fokus" : "Pause")).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
          Text(f.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
        }
        Spacer(minLength: 0)
        Text(FocusLogic.format(left))
          .font(.system(size: 22, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Theme.text)
          .contentTransition(.numericText(countsDown: true))
        Button {
          Task {
            if f.pausedAt == nil { await model.services.pauseFocus() } else { await model.services.resumeFocus() }
            await model.refresh()
          }
        } label: { Image(systemName: f.pausedAt == nil ? "pause.fill" : "play.fill") }
          .buttonStyle(RoundIconButtonStyle(size: 28))
          .help(f.pausedAt == nil ? "Anhalten" : "Weiter")
        Button {
          Task {
            await model.services.stopFocus()
            await model.refresh()
          }
        } label: { Image(systemName: "stop.fill") }
          .buttonStyle(RoundIconButtonStyle(size: 28))
          .help("Stopp")
        if f.phase == .work && f.pausedAt == nil { PauseMenu(iconOnly: true) }
      }
    }
    .tabyCard(tint: tint, padding: 12)
  }
}

/// „Pause“: fragt, wie lange; danach rücken die späteren Aufgaben des Tages um die Pause nach.
struct PauseMenu: View {
  var iconOnly = false
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot
  static let steps = [5, 10, 15, 20, 30, 45, 60]

  var body: some View {
    if snapshot {
      label
    } else {
      Menu {
        ForEach(Self.steps, id: \.self) { m in
          Button("\(m) Min") { start(m) }
        }
      } label: { label }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pause machen – Aufgaben rücken nach")
    }
  }

  @ViewBuilder private var label: some View {
    if iconOnly {
      Image(systemName: "cup.and.saucer.fill").foregroundStyle(Theme.green)
    } else {
      Label("Pause", systemImage: "cup.and.saucer.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.green)
    }
  }

  private func start(_ minutes: Int) {
    Task {
      _ = await model.services.startBreak(minutes: minutes)
      await model.refresh()
    }
  }
}
