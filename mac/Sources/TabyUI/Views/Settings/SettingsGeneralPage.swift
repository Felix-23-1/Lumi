// Seite „Allgemein“: Anmeldung, Chatverlauf, Reiter in der Notch, Bedienungshilfen.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  var generalSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "slider.horizontal.3", title: "Allgemein")
      VStack(alignment: .leading, spacing: 4) {
        Button { model.onOpenOnboarding?() } label: {
          Label("Einrichtung öffnen", systemImage: "wand.and.stars")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .accessibilityLabel("Einrichtungs-Assistent öffnen")
        Text("Führt noch einmal durch Zugang, Kalender, Mitteilungen und Kurzbefehle.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      PillToggle(title: "Start bei Anmeldung", isOn: $form.startOnLogin)
      PillToggle(title: "Auch nach Entsperren fragen", isOn: $form.askAfterUnlock)
      VStack(alignment: .leading, spacing: 4) {
        Text("Chatverlauf behalten").font(.system(size: 13)).foregroundStyle(Theme.text)
        WrapLayout(spacing: 4) {
          ForEach([(7, "7 Tage"), (30, "30 Tage"), (90, "90 Tage"), (0, "immer")], id: \.0) { days, label in
            ChoiceChip(text: label, selected: form.chatHistoryDays == days) { form.chatHistoryDays = days }
          }
        }
        Text("Ältere Nachrichten löscht Lumi automatisch, einmal am Tag.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      VStack(alignment: .leading, spacing: 4) {
        Button {
          Task {
            let granted = await model.services.requestPermission(.accessibility)
            notify(granted ? nil : "Bedienungshilfen sind noch nicht erlaubt. Systemeinstellungen → Datenschutz prüfen.",
                   success: "Bedienungshilfen erlaubt")
          }
        } label: {
          Label("Bedienungshilfen erlauben", systemImage: "accessibility")
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        Text("Nötig, damit Lumi markierten Text kopieren darf.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
    }
    .tabyCard()
  }

  /// Hinweise vor Terminen und Aufgaben (früher „Erinnerungsvorlauf“). Apple Erinnerungen heißt die Funktion dort nicht.
  var reminderLeadSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "bell", title: "Hinweise")
      HStack {
        Text("Hinweis vorher").font(.system(size: 13)).foregroundStyle(Theme.text)
        Spacer()
        NumberStepper(value: $form.reminderLeadMinutes, step: 5, range: 0...240, unit: " Min")
      }
      Text("Wie viele Minuten vor einem Termin oder einer Aufgabe Lumi dich erinnert.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .tabyCard()
  }
}
