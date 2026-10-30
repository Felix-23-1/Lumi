// Seite „Kalender & Konten“: Apple Erinnerungen, Aufgaben aus Notion und Mail.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Mail (Paket 5)

  var mailSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "envelope", title: "Mail")
      PillToggle(title: "Mail einschalten", isOn: $form.mailEnabled)
      Group {
        FieldRow(label: "Zugang") {
          HStack(spacing: 6) {
            Button { form.mailBackend = "apple" } label: { Text("Apple Mail") }
              .buttonStyle(PillButtonStyle(kind: form.mailBackend == "imap" ? .ghost : .primary, compact: true))
            Button { form.mailBackend = "imap" } label: { Text("IMAP (direkter Mail-Abruf)") }
              .buttonStyle(PillButtonStyle(kind: form.mailBackend == "imap" ? .primary : .ghost, compact: true))
          }
        }
        if form.mailBackend == "imap" {
          FieldRow(label: "Server (Port 993, verschlüsselt)") {
            InputCapsule(placeholder: "imap.example.com", text: $form.imapHost, mono: true)
          }
          FieldRow(label: "Benutzer") {
            InputCapsule(placeholder: "name@example.com", text: $form.imapUser, mono: true)
          }
          FieldRow(label: "Passwort") {
            KeyField(placeholder: imapHasPassword ? "Gespeichert (zum Ändern neu eingeben)" : "Kein Passwort gespeichert",
                     text: $imapPassword, onCommit: saveImapPassword)
          }
          HStack(spacing: 8) {
            Button { testImap() } label: { Label("Verbindung testen", systemImage: "bolt.horizontal") }
              .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
              .disabled(imapTesting)
            if let imapNote {
              Text(imapNote).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
          }
          Text("Das Passwort liegt nur im Schlüsselbund. Lumi liest Kopfzeilen der letzten 7 Tage; "
            + "Entwürfe öffnen sich in Apple Mail, gesendet wird dort von dir.")
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Button {
            Task {
              let granted = await model.services.requestPermission(.mail)
              await model.refresh()
              notify(granted ? nil : "Mail-Zugriff wurde nicht erlaubt. Systemeinstellungen → Datenschutz prüfen.",
                     success: "Mail-Zugriff erlaubt")
            }
          } label: {
            Label("Zugriff auf Mail erlauben", systemImage: "lock.open")
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
        PillToggle(title: "Nur lokal verarbeiten (empfohlen)", isOn: $form.mailLocalOnly)
        Text("Mail-Inhalte gehen dann nur an Apple Intelligence auf deinem Mac, nie an OpenRouter. "
          + "Ohne Apple Intelligence kann Lumi dann keine Antworten formulieren.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        PillToggle(title: "Im Briefing nennen", isOn: $form.mailBriefing)
        Text("Nur Anzahl und Absender.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      }
      .disabled(!form.mailEnabled)
      .opacity(form.mailEnabled ? 1 : 0.4)
    }
    .tabyCard()
    .onAppear { imapHasPassword = IMAPBackend.hasPassword() }
  }

  /// Passwort nur bei Enter oder beim Test in den Schlüsselbund – nie pro Tastendruck.
  func saveImapPassword() {
    let typed = imapPassword
    guard !typed.isEmpty else { return }
    imapPassword = ""
    do {
      try IMAPBackend.savePassword(typed)
      imapHasPassword = true
      imapNote = "Passwort gespeichert."
    } catch {
      imapNote = "Passwort konnte nicht im Schlüsselbund gespeichert werden."
    }
  }

  /// Prüft Anmeldung und Posteingang mit den eingetragenen Werten (oder dem gespeicherten Passwort).
  func testImap() {
    Task {
      imapTesting = true
      let typed = imapPassword
      saveImapPassword()
      let password = typed.isEmpty ? ((try? IMAPBackend.keychainPassword()) ?? "") : typed
      do {
        imapNote = try await IMAPBackend.testConnection(host: form.imapHost, user: form.imapUser, password: password)
      } catch {
        imapNote = (error as? LocalizedError)?.errorDescription ?? "Verbindung fehlgeschlagen."
      }
      imapTesting = false
    }
  }

  // MARK: Apple Erinnerungen

  var remindersSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "checklist", title: "Apple Erinnerungen")
      PillToggle(title: "Mit Apple Erinnerungen abgleichen", isOn: $form.appleRemindersSync)
      Text("Aufgaben erscheinen auf iPhone, iPad und Watch – Abhaken und Löschen gilt auf beiden Seiten.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
      if form.appleRemindersSync, let err = model.state?.remindersError {
        VStack(alignment: .leading, spacing: 6) {
          Label(err, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(Theme.red)
            .fixedSize(horizontal: false, vertical: true)
          if model.state?.remindersAccessDenied == true {
            Button("Systemeinstellungen öffnen") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          }
        }
        .transition(.opacity)
      }
      if form.appleRemindersSync {
        FieldRow(label: "Liste für neue Aufgaben") {
          HStack(spacing: 4) {
            ChoiceChip(text: "Standardliste", selected: form.appleRemindersListId.isEmpty) {
              form.appleRemindersListId = ""
            }
            ForEach(reminderLists) { l in
              ChoiceChip(text: l.title, selected: form.appleRemindersListId == l.id) {
                form.appleRemindersListId = l.id
              }
            }
            Spacer(minLength: 0)
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        HStack(spacing: 8) {
          Button {
            syncingReminders = true
            remindersMessage = nil
            Task {
              let r = await model.services.syncAppleReminders()
              await model.refresh()
              withAnimation(Theme.spring) {
                syncingReminders = false
                remindersMessage = r.isOk ? (true, "Abgeglichen.") : (false, r.errorMessage ?? "Fehlgeschlagen.")
              }
            }
          } label: {
            HStack(spacing: 5) {
              if syncingReminders { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
              Text("Jetzt abgleichen")
            }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(syncingReminders || !settings.appleRemindersSync)
          if let m = remindersMessage {
            HStack(spacing: 5) {
              StatusDot(color: m.ok ? Theme.green : Theme.red, size: 6)
              Text(m.text).font(.system(size: 12)).foregroundStyle(m.ok ? Theme.green : Theme.red).lineLimit(2)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
          }
          Spacer()
        }
        if !settings.appleRemindersSync {
          Text("Wird gleich gespeichert, dann abgleichen.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
      FieldRow(label: "Liste für Einkauf/Privates") {
        HStack(spacing: 4) {
          ChoiceChip(text: "Keine", selected: form.privateListId.isEmpty) {
            form.privateListId = ""
          }
          ForEach(reminderLists) { l in
            ChoiceChip(text: l.title, selected: form.privateListId == l.id) {
              form.privateListId = l.id
            }
          }
          Spacer(minLength: 0)
        }
      }
    }
    .animation(Theme.spring, value: form.appleRemindersSync)
    .task(id: form.appleRemindersSync) {
      guard reminderLists.isEmpty else { return }
      switch await model.services.appleReminderLists() {
      case .ok(let lists): reminderLists = lists
      case .failure(_, let e): remindersMessage = (false, e)
      }
    }
    .tabyCard()
  }

  // MARK: Notion-Zugänge

  /// Je Notion-Zugang ein Block (Name, Kategorie, Zugangscode, eigene Quellen); darunter Anlegen und Abgleich.
  var notionTasksSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "list.bullet.clipboard", title: "Notion-Zugänge")
      Text("Tickets sind eine Notion-Datenbank, To-dos und Weekly eine Seite. Pro Woche kannst du eine eigene Weekly-Seite anlegen. "
        + "Lumi ändert in Notion nur den Erledigt-Haken, wenn du in Lumi abhakst. "
        + "Jeder Notion-Zugang hat seinen eigenen Zugangscode und gehört zu genau einer Kategorie.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      PillToggle(title: "Einschalten", isOn: $form.notionTasksEnabled)
      ForEach(notionAccounts) { account in
        NotionAccountBlock(account: account, accounts: notionAccounts, categories: notionCategories,
                           connected: notionIsConnected(account),
                           legacyControls: account.id == NotionAccount.legacyId ? AnyView(notionLegacyControls) : nil,
                           sources: AnyView(Group {
                             if form.notionTasksEnabled { notionSourceList(for: account.id) }
                           }))
      }
      NotionAccountAdder(accounts: notionAccounts, categories: notionCategories)
      if let notionError { Banner(symbol: "exclamationmark.circle.fill", text: notionError, tint: Theme.red) }
      if form.notionTasksEnabled {
        HStack(spacing: 8) {
          Button {
            notionTasksSyncing = true
            notionTasksMessage = nil
            Task {
              let r = await model.services.syncNotionTasks()
              await model.refresh()
              withAnimation(Theme.spring) {
                notionTasksSyncing = false
                switch r {
                case .ok(let n): notionTasksMessage = (true, "\(n) gefunden.")
                case .failure(_, let e): notionTasksMessage = (false, e)
                }
              }
            }
          } label: {
            HStack(spacing: 5) {
              if notionTasksSyncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
              Text("Jetzt abgleichen")
            }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(notionTasksSyncing || !settings.notionTasksEnabled || dirty)
          if let m = notionTasksMessage {
            HStack(spacing: 5) {
              StatusDot(color: m.ok ? Theme.green : Theme.red, size: 6)
              Text(m.text).font(.system(size: 12)).foregroundStyle(m.ok ? Theme.green : Theme.red).lineLimit(2)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
          } else if let sync = model.state?.notionTasksSync {
            Text(sync.lastError ?? "\(sync.importedCount) zuletzt um \(String(sync.lastSyncAt?.suffix(5) ?? "")) Uhr.")
              .font(.system(size: 11)).foregroundStyle(sync.lastError == nil ? Theme.tertiary : Theme.red).lineLimit(2)
          }
          Spacer()
        }
        if dirty {
          Text("Wird gleich gespeichert, dann abgleichen.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
      }
    }
    .animation(Theme.spring, value: form.notionTasksEnabled)
    // Quellen-Entfernen einmal für alle Zugänge. „Behalten“ trennt nur die Verbindung zu Notion, „Aufgaben löschen“ auch die Aufgaben.
    .confirmationDialog("Notion-Quelle entfernen?",
                        isPresented: Binding(get: { notionRemoval != nil }, set: { if !$0 { notionRemoval = nil } }),
                        titleVisibility: .visible) {
      Button("Behalten") { removeNotionSource(deleteTasks: false) }
      Button("Aufgaben löschen", role: .destructive) { removeNotionSource(deleteTasks: true) }
      Button("Abbrechen", role: .cancel) { notionRemoval = nil }
    } message: {
      Text("Behalten: Die Aufgaben bleiben in Lumi, nur die Verbindung zu Notion fällt weg. "
        + "Aufgaben löschen: Die Aufgaben dieser Quelle werden auch gelöscht. Rückgängig ist kurz möglich.")
    }
    .tabyCard()
  }

  /// Je Notion-Stand eine Auswahl (Automatisch, Offen, In Bearbeitung, Info fehlt, Nicht ändern); nur bei Notion mit Ständen.
  @ViewBuilder var notionStatusMapSection: some View {
    let rows = NotionStatusMapLogic.rows(meta: model.state?.notionTaskMeta ?? [:], map: form.notionStatusMap)
    if NotionStatusMapLogic.showsSection(notionEnabled: form.notionTasksEnabled, rows: rows) {
      VStack(alignment: .leading, spacing: 8) {
        SectionHeader(symbol: "arrow.left.arrow.right", title: "Notion-Stände zuordnen")
        Text(NotionStatusMapLogic.helper)
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(rows) { row in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(row.text).font(.system(size: 12, weight: .medium)).lineLimit(1)
              if let caption = NotionStatusMapLogic.caption(row) {
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
              }
            }
            Spacer(minLength: 8)
            Picker("Stand in Lumi", selection: notionStatusBinding(row)) {
              ForEach(NotionStatusChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
          }
        }
      }
      .tabyCard()
    }
  }

  private func notionStatusBinding(_ row: NotionStatusRow) -> Binding<NotionStatusChoice> {
    Binding(get: { row.choice },
            set: { form.notionStatusMap = NotionStatusMapLogic.setting(form.notionStatusMap, text: row.text, to: $0) })
  }

  /// Zugänge aus dem Modell (Standard-Zugang immer dabei); Kategorien aus den gespeicherten Einstellungen.
  var notionAccounts: [NotionAccount] { model.state?.settings.notionAccounts ?? [NotionAccount.legacy] }
  var notionCategories: [TaskCategoryDef] { model.state?.settings.taskCategories ?? form.taskCategories }

  func notionIsConnected(_ account: NotionAccount) -> Bool {
    if account.id == NotionAccount.legacyId, model.state?.notionTasksConnected == true { return true }
    return model.state?.notionConnectedAccounts.contains(account.id) == true
  }

  /// Der Standard-Zugang behält seine Wege: Zugangscode eintragen, als Gast anmelden, trennen.
  var notionLegacyControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.state?.notionTasksConnected == true {
        HStack(spacing: 6) {
          Spacer()
          Button("Trennen") { confirmNotionDisconnect = true }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      } else {
        HStack(spacing: 8) {
          InputCapsule(placeholder: "Notion-Zugangscode", text: $notionTasksToken, secure: true)
          Button {
            notionTasksConnecting = true
            notionTasksMessage = nil
            Task {
              let r = await model.services.connectNotionTasks(token: notionTasksToken)
              await model.refresh()
              withAnimation(Theme.spring) {
                notionTasksConnecting = false
                if r.isOk { notionTasksToken = "" }
                notionTasksMessage = r.isOk ? (true, "Verbunden.") : (false, r.errorMessage ?? "Fehlgeschlagen.")
              }
            }
          } label: {
            if notionTasksConnecting { ProgressView().controlSize(.mini) } else { Text("Verbinden") }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(notionTasksConnecting || notionTasksToken.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        HStack(spacing: 6) {
          Text("oder, z. B. als Gast ohne eigenen Admin-Zugang:").font(.system(size: 11)).foregroundStyle(Theme.secondary)
          Button("Mit Notion anmelden") { NSWorkspace.shared.open(NotionOAuthConfig.makeAuthorizeURL()) }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
        Text("Nach der Freigabe zeigt der Browser „Seite nicht erreichbar“ – die Adresse oben kopieren und hier einfügen.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        HStack(spacing: 8) {
          InputCapsule(placeholder: "https://notion-callback?code=…", text: $notionOAuthPaste)
          Button {
            let code: String
            do { code = try NotionOAuthConfig.verifiedCode(fromPasted: notionOAuthPaste) } catch {
              notionTasksMessage = (false, (error as? NotionOAuthError)?.message ?? "Fehlgeschlagen.")
              return
            }
            notionTasksConnecting = true
            notionTasksMessage = nil
            Task {
              let r = await model.services.completeNotionOAuth(code: code)
              await model.refresh()
              withAnimation(Theme.spring) {
                notionTasksConnecting = false
                if r.isOk { notionOAuthPaste = "" }
                notionTasksMessage = r.isOk ? (true, "Verbunden.") : (false, r.errorMessage ?? "Fehlgeschlagen.")
              }
            }
          } label: {
            if notionTasksConnecting { ProgressView().controlSize(.mini) } else { Text("Übernehmen") }
          }
          .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
          .disabled(notionTasksConnecting || NotionOAuthConfig.code(fromPasted: notionOAuthPaste) == nil)
        }
      }
    }
  }

  /// Quellen eines Zugangs: Änderungen gehen sofort an den Kern (kein Speichern nötig).
  func notionSourceList(for accountId: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach((model.state?.notionSources ?? []).filter { $0.accountId == accountId }) { s in
        NotionSourceRow(source: s,
                        onUpdate: { name, category, link in
                          Task {
                            let r = await model.services.updateNotionSource(s.id, name: name, category: category, link: link)
                            await done(r.errorMessage, success: "Quelle gespeichert")
                          }
                        },
                        onRemove: { notionRemoval = s })
      }
      Button {
        Task {
          let r = await model.services.addNotionSource(name: "Neue Quelle", category: .tickets, link: "", accountId: accountId)
          await done(r.errorMessage, success: "Quelle hinzugefügt")
        }
      } label: {
        Text("+ Quelle hinzufügen")
      }
      .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
    }
  }

  /// Entfernt die gewählte Notion-Quelle; `deleteTasks` nimmt auch ihre Aufgaben mit.
  func removeNotionSource(deleteTasks: Bool) {
    guard let s = notionRemoval else { return }
    notionRemoval = nil
    Task {
      let r = await model.services.removeNotionSource(s.id, deleteTasks: deleteTasks)
      notionError = r.isOk ? nil : (r.errorMessage ?? "Die Notion-Quelle konnte nicht entfernt werden.")
      await done(r.errorMessage, success: deleteTasks ? "Quelle und Aufgaben entfernt" : "Quelle entfernt")
    }
  }

  /// Notion trennen (nach Bestätigung): Der Zugang geht weg, Notion-Quellen werden ausgeschaltet.
  func disconnectNotion() {
    Task {
      await model.services.disconnectNotionTasks()
      form.notionTasksEnabled = false
      await done(nil, success: "Notion getrennt")
    }
  }

}
