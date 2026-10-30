// Kalenderquellen (Apple, lokal, ICS, CalDAV, Notion) mit Prüfung und Standard-Schreibziel.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  // MARK: Kalenderquellen

  var sourcesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionHeader(symbol: "calendar", title: "Kalenderquellen", count: sources.count)
      // Umbrechend: in der Notch-Breite passen Beschriftung und fünf Chips nicht in eine Zeile.
      FieldRow(label: "Mindestabstand zwischen Terminen") {
        WrapLayout(spacing: 4) {
          ForEach(SettingsLogic.bufferChoices, id: \.self) { m in
            ChoiceChip(text: m == 0 ? "aus" : "\(m) Min", selected: form.bufferMinutes == m) { form.bufferMinutes = m }
          }
        }
      }
      ForEach(sources) { s in
        SourceRow(source: s, isDefault: s.id == SettingsLogic.effectiveDefaultWriteId(sources), health: health[s.id],
                  onEnabled: { on in upsert(CalendarSourceDraft(id: s.id, kind: s.kind, enabled: on)) },
                  onDefault: { makeDefault(s) },
                  onCheck: { check(s) })
          .transition(Theme.rowTransition)
        if s.kind == .apple && s.enabled {
          AppleCalendarPicker(source: s, onChange: { upsert(CalendarSourceDraft(id: s.id, kind: s.kind, config: $0)) })
        }
      }
      FieldRow(label: "Hinzufügen") {
        WrapLayout(spacing: 4) {
          ForEach(CalendarSourceKind.allCases, id: \.self) { k in
            ChoiceChip(text: k.germanName, symbol: k.symbol, selected: addKind == k) {
              addKind = addKind == k ? nil : k
            }
          }
        }
      }
      if let k = addKind { addForm(k).transition(.move(edge: .top).combined(with: .opacity)) }
    }
    .tabyCard()
  }

  @ViewBuilder func addForm(_ k: CalendarSourceKind) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch k {
      case .local:
        Text("Termine, die nur in Lumi gespeichert werden.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      case .apple:
        Text("Liest und schreibt deine Apple-Kalender (macOS fragt einmal nach der Freigabe).")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      case .microsoft:
        Text("Outlook und Microsoft 365: die Anmeldung läuft unter Verbindungen → Microsoft.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      case .ics:
        InputCapsule(placeholder: "https://…/kalender.ics", text: $icsUrl, mono: true)
      case .caldav:
        FieldRow(label: "CalDAV (Kalender-Server, z. B. Nextcloud/iCloud)") { InputCapsule(placeholder: "Adresse (https://…)", text: $caldavUrl, mono: true) }
        InputCapsule(placeholder: "Benutzername", text: $caldavUser)
        InputCapsule(placeholder: "App-Passwort", text: $caldavPassword, secure: true)
        Text("iCloud: https://caldav.icloud.com mit der Apple-ID und einem app-spezifischen Passwort. "
             + "Google: https://apidata.googleusercontent.com/caldav/v2/<deine-mail>/events mit App-Passwort.")
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        HStack(spacing: 8) {
          Button("Verbindung testen") { testCalDAV() }
            .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          if let t = caldavTest {
            Text(t.ok ? "Verbindung klappt" : (t.message ?? "Verbindung fehlgeschlagen"))
              .font(.system(size: 12)).foregroundStyle(t.ok ? Theme.green : Theme.red)
          }
        }
      case .notion:
        InputCapsule(placeholder: "Notion-Zugangscode", text: $notionToken, secure: true)
        InputCapsule(placeholder: "Datenbank-ID", text: $notionDatabaseId, mono: true)
        HStack(spacing: 6) {
          InputCapsule(placeholder: "Titel-Feld (Name)", text: $notionTitleField)
          InputCapsule(placeholder: "Start-Feld (Datum)", text: $notionStartField)
          InputCapsule(placeholder: "Ende-Feld (optional)", text: $notionEndField)
        }
      }
      HStack {
        Spacer()
        Button("\(k.germanName) hinzufügen") { addSource(k) }
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  func upsert(_ draft: CalendarSourceDraft) {
    Task {
      let r = await model.services.upsertCalendarSource(draft)
      await done(r.errorMessage, success: draft.enabled == false ? "Quelle ausgeschaltet" : "Quelle gespeichert")
    }
  }

  func makeDefault(_ s: CalendarSourceConfig) {
    Task {
      for other in sources where other.isDefaultWrite && other.id != s.id {
        _ = await model.services.upsertCalendarSource(CalendarSourceDraft(id: other.id, kind: other.kind,
                                                                          isDefaultWrite: false))
      }
      let r = await model.services.upsertCalendarSource(CalendarSourceDraft(id: s.id, kind: s.kind,
                                                                            isDefaultWrite: true))
      await done(r.errorMessage, success: "Standard-Kalender geändert")
    }
  }

  func check(_ s: CalendarSourceConfig) {
    health[s.id] = nil
    Task {
      let r = await model.services.calendarHealthCheck(s.id)
      withAnimation(Theme.spring) { health[s.id] = r }
    }
  }

  /// Prüft Adresse und Zugang, ohne etwas zu speichern. Das Passwort bleibt im Formular.
  func testCalDAV() {
    let url = caldavUrl.trimmingCharacters(in: .whitespaces)
    let user = caldavUser.trimmingCharacters(in: .whitespaces)
    let password = caldavPassword
    caldavTest = nil
    if let e = CalDAVProvider.addressProblem(url) { caldavTest = HealthResult(ok: false, message: e); return }
    Task {
      let r = await CalDAVProvider.testConnection(url: url, user: user, password: password)
      withAnimation(Theme.spring) { caldavTest = r }
    }
  }

  func addSource(_ k: CalendarSourceKind) {
    error = nil
    var config: [String: JSONValue] = [:]
    switch k {
    case .local, .apple, .microsoft: break
    case .caldav:
      let url = caldavUrl.trimmingCharacters(in: .whitespaces)
      let user = caldavUser.trimmingCharacters(in: .whitespaces)
      if let e = CalDAVProvider.addressProblem(url) { error = e; return }
      guard !user.isEmpty, !caldavPassword.isEmpty else { error = "Benutzername und App-Passwort eingeben."; return }
      config = ["url": .string(url), "user": .string(user), "token": .string(caldavPassword)]
    case .ics:
      if let e = SettingsLogic.validateIcsUrl(icsUrl) { error = e; return }
      config = ["url": .string(icsUrl.trimmingCharacters(in: .whitespaces))]
    case .notion:
      switch SettingsLogic.notionConfig(token: notionToken, databaseId: notionDatabaseId, titleField: notionTitleField,
                                        startField: notionStartField, endField: notionEndField) {
      case .success(let c): config = c
      case .failure(let e): error = e.message; return
      }
    }
    Task {
      let r = await model.services.upsertCalendarSource(
        CalendarSourceDraft(kind: k, config: config, enabled: true, isDefaultWrite: false))
      if let e = r.errorMessage {
        error = e
        model.react(.failed(e))
        return
      }
      icsUrl = ""; notionToken = ""; notionDatabaseId = ""
      caldavUrl = ""; caldavUser = ""; caldavPassword = ""; caldavTest = nil
      addKind = nil
      // Apple Kalender wird Schreibziel, solange noch keine externe Quelle eins ist –
      // sonst landen neue Termine still im lokalen Kalender.
      if k == .apple, case .ok(let created) = r, !sources.contains(where: { $0.isDefaultWrite && $0.kind != .local }) {
        makeDefault(created)
        return
      }
      notify(await ViewActions.finish(model, nil, success: .itemAdded), success: "Kalender hinzugefügt")
    }
  }

}
