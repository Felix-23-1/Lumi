// Einrichtungs-Assistent beim ersten Start (vor allem für Freunde, die Lumi per DMG
// bekommen): Einrichtung (Signatur), Modell, Kalender & Erinnerungen, Mitteilungen &
// Stimme, Tastenkürzel, So geht’s, Fertig. Läuft in einem eigenen Fenster (TabyApp),
// jeder Schritt ist überspringbar. Der Schritt wird gemerkt, damit die Einrichtung nach
// dem Neustart der Signatur bei Schritt 2 weitergeht.
import AppKit
import ServiceManagement
import SwiftUI
import TabyCore

enum OnboardingStep: Int, CaseIterable, Identifiable {
  case setup, model, calendar, notify, shortcuts, howTo, done
  var id: Int { rawValue }

  var title: String {
    switch self {
    case .setup: "Einrichtung"
    case .model: "Modell"
    case .calendar: "Kalender"
    case .notify: "Mitteilungen"
    case .shortcuts: "Tastenkürzel"
    case .howTo: "So geht’s"
    case .done: "Fertig"
    }
  }
}

/// Schrittfolge (rein, prüfbar).
enum OnboardingFlow {
  static func next(_ s: OnboardingStep) -> OnboardingStep {
    OnboardingStep(rawValue: s.rawValue + 1) ?? .done
  }
  static func back(_ s: OnboardingStep) -> OnboardingStep {
    OnboardingStep(rawValue: s.rawValue - 1) ?? .setup
  }
  static func progress(_ s: OnboardingStep) -> Double {
    Double(s.rawValue) / Double(OnboardingStep.allCases.count - 1)
  }
  /// Vorschläge für das Chat-Modell, wenn die Liste des Anbieters noch nicht geladen ist.
  static let suggestedModels = ["anthropic/claude-sonnet-4.5", "openai/gpt-5-mini", "google/gemini-2.5-flash"]
}

/// Merkt sich den Schritt über Neustarts (nach der Signatur geht es bei Schritt 2 weiter).
enum OnboardingResume {
  static let key = "onboardingStep"

  static func savedStep(in defaults: UserDefaults = .standard) -> OnboardingStep? {
    guard defaults.object(forKey: key) != nil else { return nil }
    return OnboardingStep(rawValue: defaults.integer(forKey: key))
  }

  static func save(_ step: OnboardingStep, in defaults: UserDefaults = .standard) {
    defaults.set(step.rawValue, forKey: key)
  }

  static func clear(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: signingNoteKey)
  }

  /// Aus der Menüleiste nach erledigter Einrichtung signiert: nach dem Neustart bei den Freigaben starten.
  static let signingNoteKey = "onboardingSigningNote"

  static func markSigningReturn(in defaults: UserDefaults = .standard) {
    save(.calendar, in: defaults)
    defaults.set(true, forKey: signingNoteKey)
  }

  static func isSigningReturn(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: signingNoteKey)
  }
}

/// Einstieg für den App-Start: soll der Assistent nach dem Neustart bei den Freigaben weitermachen?
public enum OnboardingEntry {
  public static func isReturningFromSigning() -> Bool { OnboardingResume.isSigningReturn() }
}

/// Wie die Modell-Seite speichert (rein, prüfbar).
enum ThinkChoice: Equatable {
  case apple, cloud, none
}

enum OnboardingModelPatch {
  /// Apple: Chat und Briefing auf dem Mac. Cloud: Anbieter-Endpunkt; ein leeres Modell wird
  /// zum Vorschlag des Anbieters. Ohne KI: nichts ändern.
  static func patch(choice: ThinkChoice, provider: LlmProvider, model: String) -> SettingsPatch {
    switch choice {
    case .apple:
      return SettingsPatch(llmModel: TabySettings.appleIntelligenceModel, briefingModel: TabySettings.appleIntelligenceModel)
    case .cloud:
      let trimmed = model.trimmingCharacters(in: .whitespaces)
      return SettingsPatch(llmBaseUrl: provider.baseUrl, llmModel: trimmed.isEmpty ? provider.defaultModel : trimmed)
    case .none:
      return SettingsPatch()
    }
  }
}

/// Stand der Freigaben auf der Seite.
enum PermState: Equatable {
  case unasked, pending, granted, denied
}

/// Stand der Einrichtung (Signatur).
enum SetupState: Equatable {
  case idle, running, failed(String)

  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

public struct OnboardingView: View {
  let onFinish: () -> Void
  @EnvironmentObject private var model: AppModel
  @Environment(\.tabySnapshot) private var snapshot
  @State private var step: OnboardingStep = .setup
  @State private var confirmDismiss = false
  @State private var forward = true

  // Einrichtung
  @State private var setup: SetupState = .idle
  // Modell
  @State private var apiKey = ""
  @State private var llmModel = ""
  @State private var think: ThinkChoice = .none
  @State private var provider: LlmProvider = LlmProviders.openRouter
  @State private var testing = false
  @State private var testResult: LlmTestResult?
  @State private var models: [String] = []
  // Freigaben
  @State private var perm: [PermissionKind: PermState] = [:]
  @State private var voiceOn = false
  @State private var startOnLogin = false
  @State private var sampleOn = false

  /// Beim ersten Start am Anfang; `resume` setzt dort fort, wo die Einrichtung zuletzt war.
  public init(onFinish: @escaping () -> Void, resume: Bool = false) {
    self.onFinish = onFinish
    _step = State(initialValue: resume ? (OnboardingResume.savedStep() ?? .setup) : .setup)
  }
  /// Für Vorschauen und Prüfungen: Schritt, Modellwahl und Einrichtungsstand vorgeben.
  init(onFinish: @escaping () -> Void, start: OnboardingStep, think: ThinkChoice? = nil, setup: SetupState = .idle) {
    self.onFinish = onFinish
    _step = State(initialValue: start)
    if let think { _think = State(initialValue: think) }
    _setup = State(initialValue: setup)
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      ZStack {
        pageView
        .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.horizontal, 28)
      .padding(.top, 8)
      footer
    }
    .frame(width: 560, height: 520)
    .background(Color(red: 0.05, green: 0.05, blue: 0.06))
    .environment(\.colorScheme, .dark)
    .task { await loadSettings() }
    .onChange(of: step) { _, _ in Task { await refreshPermissions() } }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      recheckAccessibility()
    }
  }

  /// Die Seite. In der Anwendung scrollt sie, wenn sie höher ist als das Fenster (z. B. mit
  /// aufgeklapptem Cloud-Anbieter); Vorschauen zeigen sie ohne Scrollbereich.
  @ViewBuilder private var pageView: some View {
    let content = page(step).frame(maxWidth: .infinity, alignment: .topLeading).id(step)
    if snapshot {
      content
    } else {
      ScrollView(.vertical, showsIndicators: false) { content }
    }
  }

  private func loadSettings() async {
    let s = model.state?.settings
    llmModel = s?.llmModel ?? ""
    provider = LlmProviders.preset(forBaseUrl: s?.llmBaseUrl ?? "") ?? LlmProviders.openRouter
    voiceOn = s?.voiceEnabled ?? false
    // Der echte Systemzustand, nicht nur die gespeicherte Einstellung.
    if Bundle.main.bundleIdentifier != nil {
      startOnLogin = SMAppService.mainApp.status == .enabled
    } else {
      startOnLogin = s?.startOnLogin ?? false
    }
    sampleOn = model.state?.tasks.contains { SampleDay.isSample($0.notes) } ?? false
    // Ohne Apple Intelligence liegt die Cloud-Karte vorn.
    think = model.state?.appleIntelligenceAvailable == true ? .apple : .cloud
    await refreshPermissions()
  }

  /// Stand der Freigaben jetzt lesen (ohne Nachfrage), damit eine erneute Ansicht den echten Stand zeigt.
  private func refreshPermissions() async {
    for kind in [PermissionKind.calendar, .reminders, .notifications, .microphone, .speechRecognition, .accessibility] {
      if await PermissionCheck.isGranted(kind) == true {
        perm[kind] = .granted
      }
    }
  }

  // MARK: Kopf + Fuß

  private var header: some View {
    VStack(spacing: 10) {
      HStack(spacing: 6) {
        ForEach(OnboardingStep.allCases) { s in
          Capsule()
            .fill(s.rawValue <= step.rawValue ? Theme.amber : Color.white.opacity(0.12))
            .frame(height: 4)
        }
      }
      HStack(spacing: 12) {
        Text(step.title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
        Spacer()
        Text("\(step.rawValue + 1) von \(OnboardingStep.allCases.count)")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        // Schließt nur das Fenster: der Schritt bleibt gemerkt, Lumi fragt beim nächsten Start weiter.
        if step != .done {
          Button("Später") { later() }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
            .help("Fenster schließen – die Einrichtung kommt beim nächsten Start wieder, bis sie abgeschlossen ist")
          Button("Nicht mehr anzeigen") { confirmDismiss = true }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      }
    }
    .padding(.horizontal, 28)
    .padding(.top, 22)
    .animation(Theme.spring, value: step)
    .confirmationDialog("Einrichtung nicht mehr anzeigen?", isPresented: $confirmDismiss, titleVisibility: .visible) {
      Button("Nicht mehr anzeigen") { dismissForGood() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Du findest sie jederzeit unter Einstellungen → Allgemein → „Einrichtung öffnen“ und im Lumi-Symbol der Menüleiste → Einrichtung.")
    }
  }

  private var footer: some View {
    HStack {
      if step != .setup && step != .done {
        Button("Zurück") { go(OnboardingFlow.back(step), forward: false) }
          .buttonStyle(PillButtonStyle(kind: .ghost))
      }
      Spacer()
      // Die Signatur überspringt man nur, wenn sie fehlgeschlagen ist (sonst fehlt der Schutz der Freigaben).
      if step != .done && step != .howTo && (step != .setup || setup.isFailed) {
        Button("Überspringen") { go(OnboardingFlow.next(step)) }
          .buttonStyle(PillButtonStyle(kind: .secondary))
      }
      Button(primaryTitle) {
        switch step {
        case .setup: runSetup()
        case .done: finish(celebrate: true)
        default: Task { await saveStep(); go(OnboardingFlow.next(step)) }
        }
      }
      .buttonStyle(PillButtonStyle(kind: .primary))
      .disabled(setup == .running)
      .keyboardShortcut(.return, modifiers: [])
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 20)
  }

  private var primaryTitle: String {
    switch step {
    case .setup: setup == .running ? "Läuft…" : "Einrichtung abschließen"
    case .done: "Lumi starten"
    default: "Weiter"
    }
  }

  /// „Nicht mehr anzeigen“: gilt als erledigt, der Assistent kommt nicht wieder von selbst.
  private func dismissForGood() { finish(celebrate: false) }

  /// „Später“: Fenster zu, ohne die Einrichtung als erledigt zu markieren (wie beim Start gemerkt).
  private func later() {
    OnboardingResume.save(step)
    onFinish()
  }

  private func go(_ s: OnboardingStep, forward f: Bool = true) {
    forward = f
    if s != .done { OnboardingResume.save(s) }
    withAnimation(Theme.spring) { step = s }
  }

  // MARK: Seiten

  @ViewBuilder private func page(_ s: OnboardingStep) -> some View {
    switch s {
    case .setup: setupPage
    case .model: modelPage
    case .calendar: calendarPage
    case .notify: notifyPage
    case .shortcuts: shortcutsPage
    case .howTo: HowToView()
    case .done: donePage
    }
  }

  private var setupPage: some View {
    VStack(spacing: 14) {
      TabyMascot(mood: .happy, size: 84, waving: true, glow: true)
      Text("Hallo! Ich bin Lumi.").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
      Text("Dein Assistent in der Notch: Aufgaben, Termine und Notizen. Ein letzter Schritt, damit macOS dich nicht ständig nach Freigaben fragt:")
        .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Einrichtung abschließen").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
        Text("Lumi legt einmalig ein eigenes Zertifikat auf diesem Mac an und startet nach dem Signieren neu. Beim Schlüsselbund-Dialog auf „Erlauben“ klicken (nicht „Immer erlauben“), dann bleiben Freigaben auch nach Updates erhalten.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        switch setup {
        case .idle:
          EmptyView()
        case .running:
          HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Lumi wird eingerichtet…").font(.system(size: 12)) }
            .foregroundStyle(Theme.secondary)
        case .failed(let reason):
          Text(reason).font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button("Anleitung öffnen") { openInstructions() }
              .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            Text("oder „Überspringen“, dann später über das Lumi-Symbol in der Menüleiste → Einrichtung…")
              .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    }
    .frame(maxWidth: .infinity)
  }

  private var modelPage: some View {
    VStack(alignment: .leading, spacing: 10) {
      pageTitle("Wie soll Lumi denken?", "Für Chat und Briefing braucht Lumi ein Sprachmodell.")
      if model.state?.appleIntelligenceAvailable == true {
        thinkCard(.apple, symbol: "apple.logo", title: "Apple Intelligence (sofort, kostenlos, bleibt auf dem Mac)")
      }
      thinkCard(.cloud, symbol: "cloud", title: "Cloud-Anbieter mit Schlüssel")
      thinkCard(.none, symbol: "square.dashed", title: "Ohne KI (Aufgaben, Notizen, Kalender)")
      if think == .cloud { cloudDetails }
      Text("Beim ersten Chat mit einem Cloud-Anbieter fragt Lumi einmal um Erlaubnis.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  private func thinkCard(_ choice: ThinkChoice, symbol: String, title: String) -> some View {
    let selected = think == choice
    return Button {
      withAnimation(Theme.spring) { think = choice }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.amber)
          .frame(width: 34, height: 34)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
          .multilineTextAlignment(.leading)
        Spacer()
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Theme.amber : Theme.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(selected ? 0.08 : 0.04)))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(selected ? Theme.amber : Color.clear, lineWidth: 1.5))
    }
    .buttonStyle(.plain)
  }

  private var cloudDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
      WrapLayout(spacing: 4) {
        ForEach(LlmProviders.all, id: \.name) { p in
          ChoiceChip(text: p.name, selected: provider == p) {
            provider = p
            llmModel = p.defaultModel
          }
        }
      }
      Button {
        if let url = URL(string: provider.keyUrl) { NSWorkspace.shared.open(url) }
      } label: {
        Label("Schlüssel bei \(provider.name) anlegen", systemImage: "arrow.up.right.square")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.amber)
      FieldRow(label: "API-Schlüssel") {
        HStack(spacing: 8) {
          InputCapsule(placeholder: model.state?.settings.hasApiKey == true ? "Gesetzt (zum Ändern neu eingeben)" : "Schlüssel",
                       text: $apiKey, secure: true)
          Button {
            Task {
              testing = true
              await saveStep()
              let r = await model.services.testLlm()
              if case .ok(let list) = await model.services.listModels() { models = list }
              withAnimation(Theme.spring) { testResult = r; testing = false }
            }
          } label: {
            HStack(spacing: 5) {
              if testing { ProgressView().controlSize(.mini) } else { Image(systemName: "bolt.horizontal") }
              Text("Speichern & testen")
            }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(testing || (apiKey.isEmpty && model.state?.settings.hasApiKey != true))
        }
      }
      FieldRow(label: "Modell") {
        InputCapsule(placeholder: "anbieter/modell", text: $llmModel, mono: true) {
          ModelMenu(models: models.isEmpty ? [provider.defaultModel] : models) { llmModel = $0 }
        }
      }
      if let r = testResult {
        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.system(size: 12)).foregroundStyle(r.ok ? Theme.green : Theme.red).lineLimit(2)
      }
    }
  }

  private var calendarPage: some View {
    VStack(alignment: .leading, spacing: 12) {
      pageTitle("Kalender & Erinnerungen", "Lumi liest deine Termine fürs Briefing und warnt bei Überschneidungen. Aufgaben gleicht Lumi mit Apple Erinnerungen ab – so sind sie auch auf iPhone und Watch.")
      if OnboardingResume.isSigningReturn() {
        Text("Nach dem Signieren fragt macOS die Freigaben noch einmal.")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
      }
      permissionRow(.calendar, symbol: "calendar", title: "Apple Kalender",
                    why: "Wofür: Termine fürs Briefing lesen und Termine eintragen, die du anlegst.")
      permissionRow(.reminders, symbol: "checklist", title: "Apple Erinnerungen",
                    why: "Wofür: Aufgaben in beide Richtungen abgleichen.")
      permissionRow(.mail, symbol: "envelope", title: "Apple Mail (optional)",
                    why: "Wofür: Posteingang lesen. Senden nur nach deinem Klick.")
      Text("macOS fragt beim Klick einmal nach – dort „Erlauben“ wählen.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  private var notifyPage: some View {
    VStack(alignment: .leading, spacing: 12) {
      pageTitle("Mitteilungen & Stimme", "Erinnerungen kommen als Mitteilung und die Notch poppt kurz auf. Auf Wunsch liest Lumi dir das Briefing morgens und abends vor.")
      permissionRow(.notifications, symbol: "bell.badge", title: "Mitteilungen",
                    why: "Wofür: Hinweise zu Terminen und Aufgaben zeigen und das Ende von Fokus-Zeiten melden.")
      permissionRow(.microphone, symbol: "mic.fill", title: "Mikrofon",
                    why: "Wofür: Gedanken in der Schnellerfassung per Diktat aufnehmen.")
      permissionRow(.speechRecognition, symbol: "waveform", title: "Spracherkennung",
                    why: "Wofür: Das Gesprochene in Text umwandeln.")
      PillToggle(title: "Lumi darf sprechen (Briefing, Termine, doppelte Termine)", isOn: $voiceOn)
      Button {
        Task { await model.services.previewVoice(nil) }
      } label: { Label("Stimme probehören", systemImage: "play.fill") }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
  }

  private var shortcutsPage: some View {
    VStack(alignment: .leading, spacing: 12) {
      pageTitle("Tastenkürzel", "Lumi wohnt oben in der Mitte an der Notch. Klick drauf – oder nimm die Tastenkürzel:")
      shortcutRow(keys: ["⌃", "⌥", "Leertaste"], text: "Lumi ein- und ausblenden")
      shortcutRow(keys: ["⌃", "⌥", "N"], text: "Schnellerfassung: Gedanke tippen, Lumi sortiert ihn ein")
      shortcutRow(keys: ["Esc"], text: "Notch schließen")
      permissionRow(.accessibility, symbol: "accessibility", title: "Bedienungshilfen",
                    why: "Wofür: Markierten Text in die Schnellerfassung übernehmen.")
      PillToggle(title: "Lumi bei der Anmeldung starten", isOn: $startOnLogin)
      Text("Das Symbol in der Menüleiste öffnet Lumi, die Einstellungen und diese Einrichtung.")
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
  }

  private var donePage: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 6)
      TabyMascot(mood: .love, size: 90, glow: true)
      HStack(spacing: 8) {
        Text("Alles bereit!").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
        Button { go(.howTo) } label: {
          Text("?").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help("So geht’s")
      }
      VStack(alignment: .leading, spacing: 6) {
        // Nur gehakt, was tatsächlich gespeichert ist (nicht, was gerade ausgewählt ist).
        summary(model.state?.settings.hasApiKey == true || model.state?.settings.llmModel == TabySettings.appleIntelligenceModel,
                "Sprachmodell")
        summary(perm[.calendar] == .granted, "Apple Kalender")
        summary(perm[.reminders] == .granted, "Apple Erinnerungen")
        summary(perm[.notifications] == .granted, "Mitteilungen")
        summary(perm[.microphone] == .granted && perm[.speechRecognition] == .granted, "Sprechen")
        summary(perm[.accessibility] == .granted, "Bedienungshilfen")
        summary(voiceOn, "Lumi spricht")
      }
      VStack(alignment: .leading, spacing: 4) {
        PillToggle(title: "Beispiel-Tag anlegen (3 Aufgaben, 1 Termin)",
                   isOn: Binding(get: { sampleOn }, set: { on in
                     sampleOn = on
                     Task {
                       if on { _ = await model.services.seedSampleDay() } else { _ = await model.services.removeSampleDay() }
                       await model.refresh()
                     }
                   }))
        Text("Lässt sich mit einem Klick entfernen – auch im Menü der Menüleiste.")
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
      }
      Text("Alles lässt sich später in den Einstellungen ändern.")
        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Bausteine

  private func pageTitle(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
      Text(text).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Eine Freigabe-Zeile mit „Wofür?“, bei Ablehnung „Erneut versuchen“ und Link zu den Systemeinstellungen.
  private func permissionRow(_ kind: PermissionKind, symbol: String, title: String, why: String) -> some View {
    let state = perm[kind] ?? .unasked
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.amber)
        .frame(width: 36, height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
        Text(why).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        if state == .denied {
          HStack(spacing: 10) {
            Button("Erneut versuchen") { Task { await request(kind) } }
              .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            Link("Systemeinstellungen öffnen", destination: kind.settingsURL)
              .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
          }
          .padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
      switch state {
      case .unasked:
        Button("Erlauben") { Task { await request(kind) } }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      case .pending:
        Label("Wird gefragt…", systemImage: "hourglass")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
      case .granted:
        Label("Erlaubt", systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
      case .denied:
        Label("Nicht erlaubt", systemImage: "xmark.circle")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.red)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
  }

  private func shortcutRow(keys: [String], text: String) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 4) { ForEach(keys, id: \.self) { KeyCap(key: $0) } }
        .frame(width: 150, alignment: .leading)
      Text(text).font(.system(size: 13)).foregroundStyle(Theme.text)
    }
  }

  private func summary(_ ok: Bool, _ text: String) -> some View {
    Label(text, systemImage: ok ? "checkmark.circle.fill" : "circle")
      .font(.system(size: 13)).foregroundStyle(ok ? Theme.text : Theme.tertiary)
  }

  // MARK: Aktionen

  /// Signatur, Neustart, weiter bei Schritt 2. Ohne Erfolg: der Grund bleibt sichtbar.
  private func runSetup() {
    setup = .running
    let path = Bundle.main.bundlePath
    Task {
      let outcome = await Task.detached(priority: .userInitiated) { SelfSigning.run(appPath: path) }.value
      switch outcome {
      case .alreadySigned:
        setup = .idle
        go(.model)
      case .signed:
        // Der Schritt wird gemerkt, bevor Lumi neu startet: danach geht es bei Schritt 2 weiter.
        // Aus der Menüleiste (Einrichtung war schon fertig): danach bei den Freigaben.
        if model.state?.settings.onboardingDone == true {
          OnboardingResume.markSigningReturn()
        } else {
          OnboardingResume.save(.model)
        }
        do {
          try RestorePlan.relaunchAfterQuit(appPath: path)
          NSApp.terminate(nil)
        } catch {
          setup = .failed("Lumi ist signiert. Bitte Lumi einmal beenden und neu öffnen.")
        }
      case .failed(let reason):
        setup = .failed(reason)
      }
    }
  }

  /// Die Anleitung zur Einrichtung (Textdatei „ANLEITUNG-FREUNDE.txt“ aus dem Programm; das Skript startet sie nicht).
  private func openInstructions() {
    if let url = Bundle.main.url(forResource: "ANLEITUNG-FREUNDE", withExtension: "txt") {
      NSWorkspace.shared.open(url)
    }
  }

  private func request(_ kind: PermissionKind) async {
    let ok = await model.services.requestPermission(kind)
    // Bedienungshilfen: macOS fragt noch – „Wird gefragt…“ bis zur Rückkehr in Lumi.
    if kind == .accessibility && !ok {
      withAnimation(Theme.spring) { perm[kind] = .pending }
      return
    }
    withAnimation(Theme.spring) { perm[kind] = ok ? .granted : .denied }
    guard ok else { return }
    switch kind {
    case .calendar:
      let hasApple = model.state?.calendarSources.contains { $0.kind == .apple } ?? false
      if !hasApple { _ = await model.services.upsertCalendarSource(CalendarSourceDraft(kind: .apple, enabled: true)) }
    case .reminders:
      _ = await model.services.updateSettings(SettingsPatch(appleRemindersSync: true), apiKey: nil)
    case .mail:
      // Erst nach erteilter Freigabe einschalten.
      _ = await model.services.updateSettings(SettingsPatch(mailEnabled: true), apiKey: nil)
    case .notifications, .microphone, .speechRecognition, .accessibility:
      break
    }
    await model.refresh()
  }

  /// Nach dem Wechsel in Lumi (z. B. aus den Systemeinstellungen) den Stand der Bedienungshilfen prüfen.
  private func recheckAccessibility() {
    guard let state = perm[.accessibility], state == .pending || state == .denied else { return }
    if PermissionCheck.accessibilityGranted() {
      perm[.accessibility] = .granted
    } else if state == .pending {
      perm[.accessibility] = .denied
    }
  }

  /// Speichert, was auf der aktuellen Seite eingestellt wurde.
  private func saveStep() async {
    switch step {
    case .model:
      // Ein Schlüssel mit leerem Modell bekommt den Vorschlag des Anbieters (siehe OnboardingModelPatch).
      let key = apiKey.isEmpty ? nil : apiKey
      if think != .none || key != nil {
        _ = await model.services.updateSettings(
          OnboardingModelPatch.patch(choice: think, provider: provider, model: llmModel), apiKey: key)
      }
      apiKey = ""
      if think == .cloud && llmModel.trimmingCharacters(in: .whitespaces).isEmpty { llmModel = provider.defaultModel }
    case .notify:
      _ = await model.services.updateSettings(SettingsPatch(voiceEnabled: voiceOn), apiKey: nil)
    case .shortcuts:
      _ = await model.services.updateSettings(SettingsPatch(startOnLogin: startOnLogin), apiKey: nil)
    default:
      break
    }
    await model.refresh()
  }

  /// „Lumi starten“ oder „Später“: Einrichtung ist erledigt, es kommt keine Erinnerung mehr.
  private func finish(celebrate: Bool) {
    Task {
      _ = await model.services.updateSettings(SettingsPatch(onboardingDone: true), apiKey: nil)
      OnboardingResume.clear()
      await model.refresh()
      if celebrate { model.react(.celebrate) }
      onFinish()
    }
  }
}
