// Einstellungen: Gerüst mit Seitenleiste, Speichern und Meldungen. Jede Seite
// liegt in Views/Settings/Settings<Seite>Page.swift als Erweiterung dieser View.
// Im eigenen Fenster (layout: .window) mit Seitenleiste; speichert automatisch.
// Der gespeicherte Schlüssel wird nie angezeigt.
import AppKit
import SwiftUI
import TabyCore

struct SettingsView: View {
  let settings: TabySettings
  let sources: [CalendarSourceConfig]
  let jobs: [Job]
  let layout: SettingsLayout
  @EnvironmentObject var model: AppModel

  @State var form: TabySettings
  @State var apiKey = ""
  /// Notion-Quelle, deren Entfernen bestätigt werden muss.
  @State var notionRemoval: NotionSource?
  @State var notionError: String?
  @State var models: [String] = []
  /// Modellliste wird nur geladen, wenn der Nutzer die Auswahl öffnet oder „Modelle laden“ drückt.
  @State var loadingModels = false
  @State var modelsNote: String?
  @State var testResult: LlmTestResult?
  @State var testing = false
  @State var status: String?
  @State var error: String?
  @State var health: [String: HealthResult] = [:]
  @State var addKind: CalendarSourceKind?
  @State var icsUrl = ""
  @State var imapPassword = ""
  @State var imapHasPassword = false
  @State var imapNote: String?
  @State var imapTesting = false
  @State var notionToken = ""
  @State var notionDatabaseId = ""
  @State var caldavUrl = ""
  @State var caldavUser = ""
  @State var caldavPassword = ""
  @State var caldavTest: HealthResult?
  @State var notionTitleField = "Name"
  @State var notionStartField = "Datum"
  @State var notionEndField = ""
  @State var reminderLists: [ReminderListInfo] = []
  @State var remindersMessage: (ok: Bool, text: String)?
  @State var syncingReminders = false
  @State var notionTasksToken = ""
  @State var notionOAuthPaste = ""
  @State var notionTasksConnecting = false
  @State var notionTasksSyncing = false
  @State var notionTasksMessage: (ok: Bool, text: String)?
  @State var newMemory = ""
  @State var exportMessage: (ok: Bool, text: String)?
  @State var exporting = false
  @State var updateChecking = false
  @State var updateInstalling = false
  @State var updateMessage: (ok: Bool, text: String)?
  @State var mcpPath: String?
  @State var mcpTesting: String?
  @State var mcpTestResults: [String: String] = [:]
  @State var copied: String?
  @State var voices: [VoiceInfo] = []
  @State var page: SettingsPage = .model
  @State var shortcutNames: [String] = []
  @State var apps: [AppInfo] = []
  @State var appSearch = ""
  /// Geburtstag wie getippt (nur gültige Eingaben gehen in `form.birthday`).
  @State var birthdayDraft: String?
  /// Automatisch speichern: offene Änderung (Debounce) und Anzeige „Gespeichert“.
  @State var saveTask: Task<Void, Never>?
  @State var saveScheduled = false
  /// Ungültige Endpunkt-URL nach dem Bestätigen (rot unter dem Feld; wird nicht gespeichert).
  @State var urlError: String?
  @State var statusTask: Task<Void, Never>?
  @State var showAdvanced = false
  /// „Eigener Anbieter“ gewählt: keine Voreinstellung markieren, auch wenn die URL eine trifft.
  @State var customProvider = false
  /// Erweiterte Seiten in der Seitenleiste zeigen (bleibt über Starts hinweg).
  @AppStorage("taby.settings.advanced") var advancedPages = false

  /// Gewünschte Seite übernehmen; liegt sie unter „Erweitert“, wird der Schalter dafür eingeschaltet.
  private func applyRequestedPage() {
    guard let wanted = SettingsPage.requested else { return }
    page = wanted
    SettingsPage.requested = nil
    if wanted.isAdvanced { advancedPages = true }
  }
  /// Bestätigungen für Aktionen ohne Rückgängig: Auftrag stoppen, MCP-Server entfernen, Notion trennen.
  @State var pendingJob: Job?
  @State var pendingMcpId: String?
  @State var confirmNotionDisconnect = false
  @Environment(\.tabyNow) var nowEnv
  @Environment(\.tabySnapshot) var snapshot
  /// Höhe des scrollbaren Bereichs je Thema (Vorschauen dürfen höher sein).
  /// shortcut: 200 statt 220, damit die 4 Gruppenreihen der Themenleiste unter das 380-pt-Limit passen.
  /// shortcut: 176 statt 200, weil die Gruppe "Verbindungen" jetzt umbricht (+24 pt); bei mehr Platz wieder 200.
  var pageHeight: CGFloat = 200
  /// Zustand für die Datenschutz-Tabelle; nur Vorschau setzt ihn, sonst kommt er aus dem Modell.
  var privacyState: AppState?

  /// `shortcuts`/`apps`: nur Vorschau (Snapshots laden keine Aufgaben); sonst kommen sie vom Kern.
  init(settings: TabySettings, sources: [CalendarSourceConfig], jobs: [Job], addKind: CalendarSourceKind? = nil,
       page: SettingsPage? = nil, shortcuts: [String] = [], apps: [AppInfo] = [],
       layout: SettingsLayout = .compact, privacyState: AppState? = nil) {
    self.settings = settings
    self.sources = sources
    self.jobs = jobs
    self.layout = layout
    self.privacyState = privacyState
    _form = State(initialValue: settings)
    _addKind = State(initialValue: addKind)
    _page = State(initialValue: page ?? (addKind != nil ? .accounts : .model))
    _shortcutNames = State(initialValue: shortcuts)
    _apps = State(initialValue: apps)
  }

  /// Formular weicht von den gespeicherten Einstellungen ab (gespeichert wird automatisch).
  var dirty: Bool { !SettingsLogic.isEmpty(SettingsLogic.patch(from: settings, to: form)) }

  var body: some View {
    Group {
      if layout == .window { windowLayout } else { compactLayout }
    }
    .animation(Theme.spring, value: status)
    .animation(Theme.spring, value: error)
    .animation(Theme.spring, value: addKind)
    .animation(Theme.spring, value: sources)
    .animation(Theme.spring, value: jobs)
    .onChange(of: settings) { _, s in
      // Ein offener Entwurf riskanter Felder bleibt stehen, bis er bestätigt ist.
      if !saveScheduled { form = SettingsLogic.withRiskyFields(from: form, into: s) }
    }
    .onChange(of: form) { _, _ in scheduleSave() }
    .onAppear { applyRequestedPage() }
    .onReceive(NotificationCenter.default.publisher(for: SettingsPage.openNotification)) { _ in applyRequestedPage() }
    .onDisappear {
      // Fenster schließen: offene Änderungen, riskante Felder und der Schlüssel werden jetzt bestätigt.
      Task { await commitRisky(); await saveKeyNow() }
    }
    .task {
      if case .ok(let list) = await model.services.listShortcuts() { shortcutNames = list }
      apps = await model.services.installedApps()
    }
  }

  /// Eigenes Fenster: Seitenleiste mit allen Themen links, Inhalt rechts.
  var windowLayout: some View {
    HStack(spacing: 0) {
      // Seitenleiste aus Zeilen statt List: eine List rendert in den Snapshots nicht.
      SettingsScroll {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(SettingsPage.visibleSections(advanced: advancedPages), id: \.label) { section in
            VStack(alignment: .leading, spacing: 2) {
              Text(section.label)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                .textCase(.uppercase).kerning(0.4).padding(.leading, 10).padding(.bottom, 2)
              ForEach(section.pages) { p in
                SidebarRow(title: p.title, symbol: p.symbol, selected: page == p) {
                  withAnimation(Theme.spring) { page = p }
                }
              }
            }
          }
          PillToggle(title: "Erweitert anzeigen", isOn: $advancedPages)
            .padding(.leading, 6).padding(.top, 4)
        }
        .padding(8)
      }
      .frame(width: 196, alignment: .top).frame(maxHeight: .infinity, alignment: .top)
      .background(Color.white.opacity(0.03))
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        PageHeader(title: page.title) { savedNote }
        if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
        SettingsScroll {
          VStack(alignment: .leading, spacing: 10) { pageContent }
            .id(page)
            .transition(.opacity)
            .padding(.bottom, 12)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 720, minHeight: 520)
  }

  /// Kompakt in der Insel: Chip-Leiste oben, Bereich darunter; ganze Fenster öffnet der Knopf.
  var compactLayout: some View {
    VStack(alignment: .leading, spacing: 10) {
      PageHeader(title: "Einstellungen") {
        savedNote
        if let openWindow = model.onDetach, !snapshot {
          Button("Im Fenster öffnen") { openWindow(.settings) }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
      }
      if let error { Banner(symbol: "exclamationmark.circle.fill", text: error, tint: Theme.red) }
      // Ein Menü statt Chip-Wolke: die Insel bleibt niedrig, alle Themen sind trotzdem da.
      pageMenu
      CappedScroll(maxHeight: pageHeight) {
        VStack(alignment: .leading, spacing: 10) { pageContent }
          .id(page)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }
    }
  }

  var pageMenu: some View {
    let label = HStack(spacing: 6) {
      Image(systemName: page.symbol).font(.system(size: 11, weight: .medium))
      Text(page.title).font(.system(size: 12, weight: .semibold))
      Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(Theme.text)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(Capsule().fill(Theme.capsuleHover))
    return HStack(spacing: 0) {
      if snapshot {
        label
      } else {
        Menu {
          ForEach(SettingsPage.visibleSections(advanced: advancedPages), id: \.label) { section in
            Section(section.label) {
              ForEach(section.pages) { p in
                Button { withAnimation(Theme.spring) { page = p } } label: { Label(p.title, systemImage: p.symbol) }
              }
            }
          }
        } label: { label }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder var savedNote: some View {
    if let error = model.state?.saveError {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.red)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    } else if let status {
      Label(status, systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.green)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
  }

  @ViewBuilder var pageContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(page.summary)
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      switch page {
      case .general:
        generalSection
        BackupsCard(retentionDays: $form.backupRetentionDays)
        DiagnosticsCard()
      case .notch: notchSection
      case .model:
        if !settings.hasApiKey && !LlmConnection.isLocalEndpoint(settings.llmBaseUrl) { welcomeCard }
        modelSection
        usageSection
      case .accounts:
        sourcesSection
        remindersSection
        notionTasksSection
        notionStatusMapSection
        mailSection
      case .tasks:
        TaskCategoriesCard(categories: $form.taskCategories)
      case .rhythm:
        planningSection
        reminderLeadSection
        dayRhythmSection
        WorkHoursCard(hours: $form.workHours)
        focusEnvironmentSection
      case .assistant:
        voiceSection
        assistantSection
        memorySection
      case .privacy:
        privacyRouteBanner
        PrivacyCard(form: $form, state: privacyState ?? model.state ?? AppState(), onRevoke: commit)
        AuditCard(services: model.services, retentionDays: $form.auditRetentionDays)
      case .connections: connectionsSection
      case .music: musicSection
      case .network: networkSection
      case .connect:
        exportSection
        mcpSection
        externalServersSection
      case .jobs: jobsSection
      case .shortcuts: shortcutsSection
      case .updates: updateSection
      }
    }
    .confirmationDialog("Auftrag stoppen?", isPresented: Binding(get: { pendingJob != nil }, set: { if !$0 { pendingJob = nil } }),
                        titleVisibility: .visible, presenting: pendingJob) { job in
      Button(job.enabled ? "Stoppen" : "Entfernen", role: .destructive) { cancelJob(job) }
      Button("Abbrechen", role: .cancel) {}
    } message: { job in
      Text("„\(job.name)“ wird nicht mehr ausgeführt. Rückgängig geht nicht.")
    }
    .confirmationDialog("Notion trennen?", isPresented: $confirmNotionDisconnect, titleVisibility: .visible) {
      Button("Trennen", role: .destructive) { disconnectNotion() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Lumi verliert den Zugang zu Notion. Die Aufgaben bleiben in Lumi; Notion-Quellen werden ausgeschaltet.")
    }
    .confirmationDialog("MCP-Server entfernen?", isPresented: Binding(get: { pendingMcpId != nil }, set: { if !$0 { pendingMcpId = nil } }),
                        titleVisibility: .visible) {
      Button("Entfernen", role: .destructive) { removeMCPServer() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Der Server wird aus der Liste entfernt. Die Programme selbst bleiben auf deinem Mac.")
    }
  }

  /// Schließt einen Dienst-Aufruf ab: Zustand neu laden, dann Erfolg oder Fehler anzeigen (jeder Knopf meldet sich).
  func done(_ error: String?, success: String = "Erledigt") async {
    notify(await ViewActions.finish(model, error, success: nil), success: success)
  }

  /// Flash nach einem Dienst-Aufruf: Fehler bleibt als Banner stehen, Erfolg verschwindet nach kurzer Zeit.
  func notify(_ failure: String?, success: String = "Erledigt") {
    if let failure {
      withAnimation(Theme.spring) { error = failure }
      return
    }
    error = nil
    statusTask?.cancel()
    withAnimation(Theme.spring) { status = success }
    statusTask = Task {
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(Theme.spring) { status = nil }
    }
  }

  // MARK: Automatisch speichern

  /// Nach dem letzten Edit 0,6 s warten, dann sichere Felder speichern. Riskante Felder bleiben
  /// beim letzten bestätigten Wert, bis sie per Enter, Fokuswechsel oder Fenster schließen bestätigt sind.
  func scheduleSave() {
    saveTask?.cancel()
    guard dirty else { saveScheduled = false; return }
    saveScheduled = true
    saveTask = Task {
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard !Task.isCancelled else { return }
      await persist(SettingsLogic.autosaveTarget(form: form, committed: settings))
    }
  }

  /// Bestätigt alle Felder: Enter, Fokus weg, Menüwahl, Fenster schließen, vor „Verbindung testen“.
  /// Eine ungültige URL wird nicht gespeichert; die übrigen Felder schon.
  func commitRisky() async {
    saveTask?.cancel()
    let r = SettingsLogic.commitTarget(form: form, committed: settings)
    urlError = r.urlError
    await persist(r.target)
  }

  /// Fasst `commitRisky` für Eingabefelder und Menüs zusammen (läuft als Task).
  func commit() { Task { await commitRisky() } }

  func persist(_ target: TabySettings) async {
    saveScheduled = false
    let patch = SettingsLogic.patch(from: settings, to: target)
    guard !SettingsLogic.isEmpty(patch) else { return }
    // Scheitert das Speichern, bleibt der Stand gleich; der Kern meldet den Grund per Hinweis.
    let updated = await model.services.updateSettings(patch, apiKey: nil)
    await model.refresh()
    if updated != settings && model.state?.saveError == nil { showSaved() }
  }

  /// Der API-Schlüssel geht nur bei Enter, Fokuswechsel, Fenster schließen oder vor dem Test – nie pro Tastendruck.
  func saveKey() { Task { await saveKeyNow() } }

  func saveKeyNow() async {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    // Der Schlüssel bleibt im Feld, bis er gespeichert ist (hasApiKey nach dem Speichern).
    let updated = await model.services.updateSettings(SettingsPatch(), apiKey: key)
    await model.refresh()
    if updated.hasApiKey && model.state?.saveError == nil {
      apiKey = ""
      showSaved()
    }
  }

  func showSaved() {
    statusTask?.cancel()
    withAnimation(Theme.spring) { status = "Gespeichert" }
    statusTask = Task {
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(Theme.spring) { status = nil }
    }
  }
}
