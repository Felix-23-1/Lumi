// Seite „KI-Modell“: Anbieter, Schlüssel, Modell, Test, Verbrauch und Limits.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Erster Start

  /// Einrichtung beim ersten Start (eigener Schlüssel je Nutzer – jeder hat sein eigenes Lumi).
  var welcomeCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "hand.wave.fill").foregroundStyle(Theme.amber)
        Text("Willkommen bei Lumi!").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
      }
      let p = LlmProviders.preset(forBaseUrl: settings.llmBaseUrl)
      let who: String = p.map { " bei \($0.name)" } ?? ""
      let rest = ". Lege ihn an, trag ihn unten ein. Lumi speichert automatisch. Aufgaben, Notizen und Kalender funktionieren auch ohne."
      Text("Für Chat, Schnellerfassung und Briefing brauchst du einen eigenen Schlüssel" + who + rest)
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let p, let url = URL(string: p.keyUrl) {
        Button { NSWorkspace.shared.open(url) } label: {
          Label("Schlüssel bei \(p.name) anlegen", systemImage: "arrow.up.right.square")
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.amber)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.amber.opacity(0.10)))
  }

  // MARK: Modell

  /// Apple Intelligence für Chat und Briefing (läuft auf dem Mac, kein Schlüssel).
  var usesApple: Bool { form.llmModel == TabySettings.appleIntelligenceModel }
  /// Lokaler Server auf diesem Rechner (Ollama oder LM Studio): kein Schlüssel, nichts verlässt den Rechner.
  var usesLocal: Bool { LlmConnection.isLocalEndpoint(form.llmBaseUrl) }
  var usesLmStudio: Bool { form.llmBaseUrl.contains(":1234") }
  /// Voreinstellung des Endpunkts; nil bei lokal, eigenem Anbieter oder wenn „Eigener Anbieter“ gewählt ist.
  var preset: LlmProvider? { customProvider ? nil : LlmProviders.preset(forBaseUrl: form.llmBaseUrl) }
  /// Name für Texte und Schlüssel-Feld: Voreinstellung, sonst der Host der eigenen URL.
  var providerName: String {
    LlmProviders.preset(forBaseUrl: form.llmBaseUrl)?.name ?? (LlmConnection.host(of: form.llmBaseUrl) ?? "deinem Anbieter")
  }
  static let ollamaUrl = "http://localhost:11434/v1"
  static let lmStudioUrl = "http://localhost:1234/v1"

  var lmStudioBinding: Binding<Bool> {
    Binding(get: { usesLmStudio }, set: { on in
      form.llmBaseUrl = on ? Self.lmStudioUrl : Self.ollamaUrl
      commit()
    })
  }

  /// Anbieterwechsel: einen noch nicht gespeicherten Schlüssel zuerst beim alten Host sichern,
  /// dann den Endpunkt setzen und bestätigen (Schlüssel und Modell gehören zum neuen Host).
  func switchEndpoint(_ change: @escaping () -> Void) {
    Task {
      await saveKeyNow()
      change()
      models = []
      modelsNote = nil
      await commitRisky()
    }
  }

  func choose(_ p: LlmProvider) {
    customProvider = false
    switchEndpoint { LlmProviders.apply(p, to: &form) }
  }

  func chooseLocal() {
    customProvider = false
    switchEndpoint {
      if usesApple { form.llmModel = ""; form.briefingModel = "" }
      form.llmBaseUrl = Self.ollamaUrl
    }
  }

  /// „Eigener Anbieter“: nur die freie URL unter Erweitert öffnen; die URL ändert sich erst dort.
  func chooseCustom() {
    if usesApple { form.llmModel = ""; form.briefingModel = "" }
    customProvider = true
    showAdvanced = true
  }

  /// Modellliste laden (`GET /models`). Offene Felder gehen vorher an den Kern, damit der Endpunkt feststeht.
  func loadModels() async {
    loadingModels = true
    await commitRisky()
    let r = await model.services.listModels()
    loadingModels = false
    if let list = r.value {
      models = list
      modelsNote = list.isEmpty ? "Keine Modelle gefunden." : "\(list.count) Modelle gefunden. Wähle eins über das Menü."
    } else {
      models = []
      modelsNote = r.errorMessage
    }
  }

  var modelSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "cpu", title: "Modell")
      FieldRow(label: "Anbieter") {
        WrapLayout(spacing: 4) {
          ForEach(LlmProviders.all, id: \.baseUrl) { p in
            ChoiceChip(text: p.name, symbol: "cloud", selected: !usesLocal && !usesApple && preset == p) { choose(p) }
          }
          ChoiceChip(text: "Lokal (Ollama / LM Studio)", symbol: "desktopcomputer", selected: usesLocal && !usesApple) {
            chooseLocal()
          }
          ChoiceChip(text: "Eigener Anbieter", symbol: "server.rack", selected: !usesLocal && !usesApple && preset == nil) {
            chooseCustom()
          }
          if model.state?.appleIntelligenceAvailable == true {
            ChoiceChip(text: "Apple Intelligence", symbol: "apple.logo", selected: usesApple) {
              form.llmModel = TabySettings.appleIntelligenceModel
              form.briefingModel = TabySettings.appleIntelligenceModel
              commit()
            }
          }
        }
      }
      if usesApple {
        Text("Chat und Briefing laufen auf deinem Mac (Apple Intelligence) – kostenlos, ohne Internet, nichts verlässt den Rechner. Für sehr lange Gespräche ist das Modell zu klein; dann hilft „Verlauf leeren“.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
      Text(usesLocal
           ? "Läuft auf deinem Mac – nichts verlässt den Rechner. Starte Ollama oder LM Studio mit geladenem Modell."
           : "Chat, Schnellerfassung und Briefing laufen über \(providerName). Dafür brauchst du einen eigenen Schlüssel von dort.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if usesLocal {
        PillToggle(title: "LM Studio statt Ollama", isOn: lmStudioBinding)
      } else {
        FieldRow(label: "Schlüssel für \(providerName)") {
          HStack(spacing: 6) {
            KeyField(placeholder: form.hasApiKey ? "Gesetzt (zum Ändern neu eingeben)" : "Kein Schlüssel gesetzt",
                     text: $apiKey, onCommit: saveKey)
            if form.hasApiKey && apiKey.isEmpty {
              Chip(text: "gesetzt", symbol: "checkmark.circle.fill", tint: Theme.green)
            }
          }
        }
        HStack(spacing: 8) {
          if let p = preset, let url = URL(string: p.keyUrl) {
            Button { NSWorkspace.shared.open(url) } label: {
              Label("Schlüssel bei \(p.name) holen", systemImage: "arrow.up.right.square")
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.amber)
          }
          // Der Schlüssel gilt nur für den Host, für den er eingetragen wurde.
          if !form.hasApiKey, LlmConnection.host(of: form.llmBaseUrl) != LlmConnection.defaultHost {
            Text("Für diesen Anbieter einen eigenen Schlüssel eintragen.")
              .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          }
          Spacer(minLength: 0)
        }
      }
      FieldRow(label: "Modell im Chat (Modellname)") {
        CommitField(placeholder: preset?.defaultModel ?? "anbieter/modell", text: $form.llmModel, mono: true,
                    onCommit: commit) {
          ModelMenu(models: models, onOpen: { Task { await loadModels() } }) { form.llmModel = $0; commit() }
        }
      }
      HStack(spacing: 8) {
        Button {
          testing = true
          testResult = nil
          Task {
            // Der Test nimmt die gespeicherten Werte: erst bestätigen, dann prüfen.
            await commitRisky()
            await saveKeyNow()
            let r = await model.services.testLlm()
            withAnimation(Theme.spring) { testResult = r; testing = false }
          }
        } label: {
          HStack(spacing: 5) {
            if testing { ProgressView().controlSize(.mini) } else { Image(systemName: "bolt.horizontal") }
            Text("Verbindung testen")
          }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(testing)
        Button { Task { await loadModels() } } label: {
          HStack(spacing: 5) {
            if loadingModels { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            Text("Modelle laden")
          }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        .disabled(loadingModels)
        if let r = testResult {
          HStack(spacing: 5) {
            StatusDot(color: r.ok ? Theme.green : Theme.red, size: 6)
            Text(r.message).font(.system(size: 12)).foregroundStyle(r.ok ? Theme.green : Theme.red).lineLimit(2)
          }
          .transition(.move(edge: .leading).combined(with: .opacity))
        }
        Spacer(minLength: 0)
      }
      if let note = modelsNote {
        Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup("Erweitert", isExpanded: $showAdvanced) {
        VStack(alignment: .leading, spacing: 8) {
          FieldRow(label: "Adresse") {
            VStack(alignment: .leading, spacing: 4) {
              CommitField(placeholder: LlmProviders.openRouter.baseUrl, text: $form.llmBaseUrl, mono: true, onCommit: commit)
              if let e = urlError {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          if !usesApple {
            FieldRow(label: "Modell für Briefing & Aufträge (Modellname, leer = wie im Chat)") {
              CommitField(placeholder: "leer = gleiches Modell wie im Chat", text: $form.briefingModel, mono: true,
                          onCommit: commit) {
                ModelMenu(models: models, onOpen: { Task { await loadModels() } }) { form.briefingModel = $0; commit() }
              }
            }
          }
        }
        .padding(.top, 6)
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Theme.secondary)
      }
    }
    .tabyCard()
  }

  // MARK: Verbrauch

  var usageSection: some View {
    let usage = model.state?.usage ?? UsageSummary()
    let level = UsageLogic.level(usage)
    let reportsCost = LlmConnection.host(of: form.llmBaseUrl) == LlmConnection.defaultHost
    // Eingeklappt, damit die Seite kurz bleibt; der Warnchip bleibt im Kopf sichtbar.
    return DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        usageDetails(reportsCost: reportsCost, usage: usage)
      }
      .padding(.top, 8)
    } label: {
      HStack {
        SectionHeader(symbol: "dollarsign.circle", title: "Kosten & Limits")
        Spacer()
        if let text = UsageLogic.chipText(level) {
          Chip(text: text, symbol: level == .reached ? "pause.circle.fill" : "exclamationmark.triangle.fill",
               tint: level == .reached ? Theme.red : Theme.amber)
            .transition(.scale.combined(with: .opacity))
        }
      }
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Theme.secondary)
    .animation(Theme.spring, value: level)
    .tabyCard()
  }

  @ViewBuilder func usageDetails(reportsCost: Bool, usage: UsageSummary) -> some View {
    HStack(spacing: 10) {
      // Kosten meldet nur OpenRouter; andere Anbieter liefern Tokens, keine Beträge.
      usageTile(title: "Heute", dollars: reportsCost ? usage.todayUsd : nil, tokens: usage.todayTokens)
      usageTile(title: "Dieser Monat", dollars: reportsCost ? usage.monthUsd : nil, tokens: usage.monthTokens)
    }
    FieldRow(label: "Tageslimit") {
      limitChips(SettingsLogic.dailyLimitChoices, value: $form.dailyCostLimitUsd)
    }
    FieldRow(label: "Monatslimit") {
      limitChips(SettingsLogic.monthlyLimitChoices, value: $form.monthlyCostLimitUsd)
    }
    Text(reportsCost
         ? "Über dem Limit antwortet das Modell nicht mehr; das Briefing kommt dann ohne Modell."
         : "\(providerName) meldet keine Kosten, deshalb zeigt Lumi nur Tokens. Kostenlimits wirken nur mit OpenRouter.")
      .font(.system(size: 11)).foregroundStyle(Theme.secondary)
  }

  func usageTile(title: String, dollars: Double?, tokens: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
      Text(dollars.map { UsageLogic.dollars($0) } ?? "–").font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.text).contentTransition(.numericText())
      Text(UsageLogic.tokens(tokens)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  func limitChips(_ choices: [Double], value: Binding<Double>) -> some View {
    HStack(spacing: 4) {
      ForEach(choices, id: \.self) { c in
        ChoiceChip(text: UsageLogic.limitLabel(c), selected: value.wrappedValue == c) { value.wrappedValue = c }
      }
      Spacer(minLength: 0)
    }
  }

}
