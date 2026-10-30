// Seite „Tagesablauf“: Planung, Tagesabschluss, Fokus und „Nicht stören“.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Planung (Paket 4)

  var planningSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "wand.and.stars", title: "Tagesplan")
        HStack {
          Text("Block-Länge").font(.system(size: 13)).foregroundStyle(Theme.text)
          Spacer()
          NumberStepper(value: $form.planBlockMinutes, step: 5, range: 5...240, unit: " Min")
        }
        Text("Aufgaben kommen in Blöcke dieser Länge in die freien Lücken bis Feierabend.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .tabyCard()

      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "person.2", title: "Meeting-Begleiter")
        PillToggle(title: "Vorbereitung vor Terminen, Stichpunkte danach", isOn: $form.meetingCompanion)
        if form.meetingCompanion {
          HStack {
            Text("Vorlauf").font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer()
            NumberStepper(value: $form.meetingLeadMinutes, step: 1, range: 1...60, unit: " Min")
          }
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(Theme.spring, value: form.meetingCompanion)
      .tabyCard()

      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "calendar.badge.clock", title: "Wochenplanung")
        PillToggle(title: "Rückblick und 3 Ziele für die Woche fragen", isOn: $form.weeklyReviewEnabled)
        if form.weeklyReviewEnabled {
          FieldRow(label: "Wochentag") {
            HStack(spacing: 4) {
              ForEach(SettingsLogic.weekdays) { w in
                ChoiceChip(text: w.label, selected: form.weeklyReviewDay == w.day) { form.weeklyReviewDay = w.day }
              }
              Spacer(minLength: 0)
            }
          }
          FieldRow(label: "Uhrzeit") {
            HStack(spacing: 4) {
              TimeOfDayField(time: $form.weeklyReviewTime)
              Spacer(minLength: 0)
            }
          }
        }
      }
      .animation(Theme.spring, value: form.weeklyReviewEnabled)
      .tabyCard()
    }
  }

  // MARK: macOS-Fokus (Paket 4)

  var focusEnvironmentSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "moon.circle", title: "Nicht stören")
      Text("Wenn du in Lumi einen Fokus startest, kann Lumi deinen Mac und deine Chats mit umstellen: Nicht stören an, Status „Im Fokus“, ablenkende Apps weg. Am Ende stellt Lumi alles zurück. Alles hier ist freiwillig.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      PillToggle(title: "Chat-Status automatisch setzen", isOn: $form.autoStatus)
      Text("Setzt in Slack den Status „Im Fokus“ bzw. „Im Termin“ und löscht ihn danach. Gilt nur, wenn Slack unter „Verbindungen“ verbunden ist.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      shortcutRow("Kurzbefehl beim Start", $form.focusShortcutOn)
      shortcutRow("Kurzbefehl beim Ende", $form.focusShortcutOff)
      Text("So schaltet Lumi „Nicht stören“ am Mac: Lege in der App „Kurzbefehle“ zwei Kurzbefehle mit der Aktion „Fokus festlegen“ an (einen für an, einen für aus) und trag ihre Namen hier ein.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      FieldRow(label: "Während Fokus ausblenden") {
        VStack(alignment: .leading, spacing: 6) {
          InputCapsule(placeholder: "App suchen…", text: $appSearch)
          CappedScroll(maxHeight: 130) {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(filteredApps) { app in
                PillToggle(title: app.name, isOn: hideBinding(app.id))
                  .padding(.horizontal, 8).padding(.vertical, 4)
              }
            }
          }
        }
      }
    }
    .tabyCard()
  }

  func shortcutRow(_ title: String, _ value: Binding<String>) -> some View {
    let label = Text(value.wrappedValue.isEmpty ? "Keiner" : value.wrappedValue)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Theme.text)
      .lineLimit(1)
    return HStack {
      Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
      Spacer()
      if snapshot {
        label
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(Capsule().fill(Theme.capsule))
          .frame(width: 210, alignment: .trailing)
      } else {
        Menu {
          Button("Keiner") { value.wrappedValue = ""; commit() }
          ForEach(shortcutChoices(value.wrappedValue), id: \.self) { name in
            Button(name) { value.wrappedValue = name; commit() }
          }
        } label: {
          label
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 210, alignment: .trailing)
      }
    }
  }

  /// Kurzbefehle aus der App; ein gespeicherter, inzwischen fehlender Name bleibt wählbar.
  func shortcutChoices(_ current: String) -> [String] {
    var list = shortcutNames
    if !current.isEmpty && !list.contains(current) { list.insert(current, at: 0) }
    return list
  }

  var filteredApps: [AppInfo] {
    SettingsLogic.filterApps(apps, search: appSearch, selected: form.focusHideApps)
  }

  func hideBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { form.focusHideApps.contains(id) },
      set: { on in
        if on {
          if !form.focusHideApps.contains(id) { form.focusHideApps.append(id) }
        } else {
          form.focusHideApps.removeAll { $0 == id }
        }
      })
  }

  // MARK: Tagesabschluss + Fokus

  var dayRhythmSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "moon.stars", title: "Tagesabschluss & Fokus")
      PillToggle(title: "Am Abend nach Offenem fragen", isOn: $form.dayEndEnabled)
      if form.dayEndEnabled {
        FieldRow(label: "Uhrzeit") {
          HStack(spacing: 4) {
            TimeOfDayField(time: $form.dayEndTime)
            Spacer(minLength: 0)
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      FieldRow(label: "Fokus-Länge") {
        HStack(spacing: 4) {
          ForEach(SettingsLogic.focusChoices, id: \.self) { m in
            ChoiceChip(text: "\(m) Min", selected: form.focusMinutes == m) { form.focusMinutes = m }
          }
          Spacer(minLength: 0)
        }
      }
      FieldRow(label: "Pause danach") {
        HStack(spacing: 4) {
          ForEach(SettingsLogic.breakChoices, id: \.self) { m in
            ChoiceChip(text: "\(m) Min", selected: form.breakMinutes == m) { form.breakMinutes = m }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .animation(Theme.spring, value: form.dayEndEnabled)
    .tabyCard()
  }

}
