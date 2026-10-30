// Seite „Sprache & Assistent“: Stimme, Persönlichkeit, Vorgaben, Gedächtnis.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Assistent

  var assistantSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "person.wave.2", title: "Assistent")
      FieldRow(label: "Persönlichkeit") {
        HStack(spacing: 4) {
          ForEach(SettingsLogic.personalities, id: \.0) { p, label in
            ChoiceChip(text: label, selected: form.personality == p) { form.personality = p }
          }
          Spacer(minLength: 0)
        }
      }
      FieldRow(label: "Vorgabe fürs Briefing") {
        VStack(alignment: .leading, spacing: 6) {
          TextArea(placeholder: "leer = eingebaute Vorgabe (kurz, wie im Gespräch, ohne Aufzählungen)",
                   text: $form.briefingPrompt, minHeight: 56)
            .frame(maxHeight: 160)
          HStack(spacing: 8) {
            Button { form.briefingPrompt = BriefingBuilder.defaultPrompt } label: {
              Label("Eingebaute Vorgabe zum Anpassen laden", systemImage: "text.badge.plus")
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            if !form.briefingPrompt.isEmpty {
              Button("Zurücksetzen") { form.briefingPrompt = "" }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            }
            Spacer(minLength: 0)
          }
          Text("Das Modell bekommt diese Vorgabe und dazu nur Stichpunkte ohne IDs. Ein Muster-Briefing darin zeigt ihm Ton und Länge.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      FieldRow(label: "Eigene Anweisungen") {
        TextArea(placeholder: "z. B. „Antworte kurz. Ich arbeite von 9 bis 17 Uhr.“", text: $form.customInstructions,
                 minHeight: 56)
          .frame(maxHeight: 100)
      }
      PillToggle(title: "Feiertags-Deko für Lumi", isOn: $form.seasonalDecor)
      Text("Weihnachtsmütze, Kürbis und Geburtstagshut am Maskottchen, wenn es passt.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      FieldRow(label: BirthdayLogic.hint) {
        InputCapsule(placeholder: BirthdayLogic.placeholder, text: birthdayBinding)
        if let message = birthdayMessage {
          Text(message).font(.system(size: 11)).foregroundStyle(Theme.red)
        }
      }
      Text("Kontakte: Cloud-Modelle sehen nur Namen und Firmen; Adressen setzt Lumi beim Senden lokal ein.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .tabyCard()
  }

  /// Anzeige "TT.MM."; gespeichert wird nur eine gültige Eingabe (leer = kein Geburtstag).
  var birthdayBinding: Binding<String> {
    Binding(
      get: { birthdayDraft ?? BirthdayLogic.displayValue(form.birthday) },
      set: { text in
        birthdayDraft = text
        if let stored = BirthdayLogic.storedValue(text) { form.birthday = stored }
      })
  }

  var birthdayMessage: String? {
    birthdayDraft.flatMap { BirthdayLogic.validationMessage($0) }
  }

  // MARK: Sprache

  var voiceSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "speaker.wave.2", title: "Sprache & Vorlesen")
      PillToggle(title: "Lumi spricht", isOn: $form.voiceEnabled)
      ExplainSpeakToggle()
      DraftSignatureField()
      if form.voiceEnabled {
        PillToggle(title: "Briefing morgens und Tagesabschluss abends vorlesen", isOn: $form.voiceBriefings)
        PillToggle(title: "Hinweise, Termine und doppelte Termine ansagen", isOn: $form.voiceAlerts)
        FieldRow(label: "Stimme") {
          VStack(alignment: .leading, spacing: 4) {
            WrapLayout(spacing: 4) {
              ChoiceChip(text: "Automatisch", selected: form.voiceName.isEmpty) { form.voiceName = "" }
              ForEach(voices) { v in
                ChoiceChip(text: v.quality == "Standard" || v.quality == "System" ? v.name : "\(v.name) · \(v.quality)",
                           selected: form.voiceName == v.id) {
                  form.voiceName = v.id
                  Task { await model.services.previewVoice(v.id) }
                }
              }
            }
            HStack(spacing: 8) {
              Button { Task { await model.services.previewVoice(form.voiceName.isEmpty ? nil : form.voiceName) } } label: {
                Label("Probe hören", systemImage: "play.fill")
              }
              .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
              Button { Task { await model.services.stopSpeaking() } } label: { Label("Stopp", systemImage: "stop.fill") }
                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
              Spacer(minLength: 0)
            }
            if form.voiceName == "system" {
              Text("Siri-Stimmen (z. B. „Stimme 2“) gibt macOS nur als Systemstimme frei: Systemeinstellungen → Bedienungshilfen → Gesprochene Inhalte → Systemstimme → Siri-Stimme wählen. Lumi spricht dann damit.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Schönere Stimmen: Systemeinstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen verwalten (z. B. „Anna (Premium)“ laden).")
              .font(.system(size: 11)).foregroundStyle(Theme.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      FieldRow(label: "Vorlesen-Knopf") {
        VStack(alignment: .leading, spacing: 4) {
          WrapLayout(spacing: 4) {
            ForEach([15, 30, 60, 120], id: \.self) { m in
              ChoiceChip(text: m < 60 ? "\(m) Min" : "\(m / 60) Std", selected: form.readAloudMinutes == m) {
                form.readAloudMinutes = m
              }
            }
            NumberStepper(value: $form.readAloudMinutes, step: 5, range: 5...1440, unit: " Min")
          }
          Text("Der Knopf in „Heute“ liest die Termine dieses Zeitraums und offene Aufgaben vor – auch wenn „Lumi spricht“ aus ist.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .animation(Theme.spring, value: form.voiceEnabled)
    .task { voices = await model.services.availableVoices() }
    .tabyCard()
  }

  // MARK: Gedächtnis

  var memorySection: some View {
    let memories = model.state?.memories ?? []
    return VStack(alignment: .leading, spacing: 6) {
      SectionHeader(symbol: "brain", title: "Gedächtnis", count: memories.count)
      ForEach(memories) { m in
        HoverRow { hover in
          HStack(spacing: 8) {
            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            Text(m.text).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer(minLength: 4)
            if hover {
              Button {
                Task {
                  let r = await model.services.deleteMemory(m.id)
                  await done(r.errorMessage, success: "Vergessen")
                }
              } label: { Image(systemName: "trash") }
                .buttonStyle(RoundIconButtonStyle(size: 22, tint: Theme.red.opacity(0.8)))
                .help("Vergessen")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
          }
        }
        .transition(Theme.rowTransition)
      }
      InputCapsule(placeholder: "Etwas merken …", text: $newMemory)
        .onSubmit(addMemory)
      Text("Im Chat geht auch: „Merk dir, dass…“. Gemerktes fließt in jede Antwort ein.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      if let label = model.undoBannerLabel, ViewSupportLogic.undoVisible(label) {
        UndoBanner(label: label).transition(.opacity)
      }
    }
    .animation(Theme.spring, value: memories)
    .tabyCard()
  }

  func addMemory() {
    let t = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    newMemory = ""
    Task {
      let r = await model.services.addMemory(t)
      // finish lädt neu und lässt das Maskottchen auf „hinzugefügt“ reagieren.
      notify(await ViewActions.finish(model, r.errorMessage, success: .itemAdded), success: "Gemerkt")
    }
  }
}
