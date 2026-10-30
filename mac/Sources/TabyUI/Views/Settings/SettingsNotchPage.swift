// Seite „Notch“: Wohnort, Notch-Text, Countdown und Zeilen, die in der Notch durchrollen.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Notch

  var notchSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      tabsCard
      VStack(alignment: .leading, spacing: 10) {
        SectionHeader(symbol: "menubar.rectangle", title: "Notch")
        homeCityGroup
        notchTextGroup
        tickerGroup
      }
      .tabyCard()
    }
  }

  /// Reiter in der Leiste ein- und ausschalten, Reihenfolge zurücksetzen (ganz oben auf der Seite).
  var tabsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "rectangle.3.group", title: "Reiter in der Notch")
      Text("Schalte Reiter ein/aus; ausgeschaltete liegen unter „Mehr“. Reihenfolge per Ziehen in der Notch.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      WrapLayout(spacing: 6) {
        ForEach((OpenBoardTabs.left + OpenBoardTabs.right).filter { $0 != .settings }) { t in
          ChoiceChip(text: t.title, selected: !form.hiddenTabs.contains(t.rawValue)) {
            if let i = form.hiddenTabs.firstIndex(of: t.rawValue) { form.hiddenTabs.remove(at: i) }
            else { form.hiddenTabs.append(t.rawValue) }
          }
        }
      }
      Button {
        Task {
          _ = await model.services.updateSettings(SettingsPatch(tabOrder: []), apiKey: nil)
          await model.refresh()
          notify(model.state?.saveError, success: "Reihenfolge zurückgesetzt")
        }
      } label: {
        Label("Reiter-Reihenfolge zurücksetzen", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
    .tabyCard()
  }

  /// Welche Zeilen in der geschlossenen Notch durchrollen (angehakt = nicht ausgeblendet).
  var tickerGroup: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("In der Notch durchrollen").font(.system(size: 13)).foregroundStyle(Theme.text)
      ForEach(TickerKind.allCases, id: \.self) { kind in
        let on = !form.hiddenTickerKinds.contains(kind.rawValue)
        Button {
          if on { form.hiddenTickerKinds.append(kind.rawValue) } else { form.hiddenTickerKinds.removeAll { $0 == kind.rawValue } }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
              .foregroundStyle(on ? Theme.green : Theme.tertiary)
            Text(kind == .timer ? "Timer" : kind.title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Wohnort für das Wetter-Mod in der Notch.
  var homeCityGroup: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Wohnort").font(.system(size: 13)).foregroundStyle(Theme.text)
      InputCapsule(placeholder: "z. B. Köln", text: $form.homeCity)
      Text("Für das Wetter in der Notch (Mod „Wetter in der Notch“).")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
    }
  }

  /// Eigener Text und optionaler Countdown für die geschlossene Notch.
  var notchTextGroup: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Notch-Text").font(.system(size: 13)).foregroundStyle(Theme.text)
      InputCapsule(placeholder: "Eigener Text (max. 40 Zeichen)", text: Binding(
        get: { form.notchText },
        set: { form.notchText = String($0.prefix(40)) }))
      PillToggle(title: "Countdown", isOn: Binding(
        get: { !form.notchCountdown.isEmpty },
        set: { on in form.notchCountdown = on ? NowResolver.today(nowEnv) : "" }))
      if !form.notchCountdown.isEmpty {
        HStack {
          Text("Countdown bis").font(.system(size: 13)).foregroundStyle(Theme.text)
          Spacer()
          DatePicker("", selection: Binding(
            get: { Self.notchDayFormatter.date(from: form.notchCountdown) ?? Date() },
            set: { form.notchCountdown = Self.notchDayFormatter.string(from: $0) }),
            displayedComponents: .date)
            .labelsHidden()
        }
      }
      Text("Erscheint in der geschlossenen Notch, wenn gerade nichts Wichtigeres ansteht.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
    }
  }


  /// Speicherformat des Countdowns: "YYYY-MM-DD".
  static let notchDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

}
