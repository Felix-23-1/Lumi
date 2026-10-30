// Netzlaufwerke (SMB) auf der Seite „Verbindungen“: Liste mit Status, Verbinden/Trennen,
// Bearbeiten, Löschen und das Formular „+ Netzlaufwerk“. Passwörter gehen direkt in den
// Schlüsselbund und nie in die Einstellungen.
import SwiftUI
import TabyCore

/// Adresse aus der Geräteliste (Netzwerk-Seite) für das Formular. Nur eine Bequemlichkeit im Gerät.
enum ShareDraft {
  static let key = "shareDraftHost"

  static func suggest(host: String) {
    UserDefaults.standard.set("smb://\(host)/", forKey: key)
  }

  /// Liefert den vorgeschlagenen Adresswert einmal und vergisst ihn danach.
  static func take() -> String? {
    let value = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    return value
  }
}

/// Entwurf des Formulars (nur in der Oberfläche, nie gespeichert).
struct ShareForm: Equatable {
  var id: String?
  var name = ""
  var address = ""
  var user = ""
  var password = ""
  /// Gespeichertes Passwort beim Speichern entfernen.
  var clearPassword = false
  var autoMount = false
  var folders: [String] = []
  var folderDraft = ""

  init(id: String? = nil, name: String = "", address: String = "", user: String = "",
       autoMount: Bool = false, folders: [String] = []) {
    self.id = id; self.name = name; self.address = address; self.user = user
    self.autoMount = autoMount; self.folders = folders
  }

  init(share: NetworkShare) {
    self.init(id: share.id, name: share.name, address: share.url, user: share.user,
              autoMount: share.autoMount, folders: share.searchFolders)
  }
}

/// Regeln und Texte der Netzlaufwerk-Maske (rein, ohne Ansicht).
enum ShareFormLogic {
  static let explanation = "Lumi sucht nur in diesen Ordnern, und nur mit Apple Intelligence auf deinem Mac."

  /// Erster Fehler des Formulars; nil = speicherbar.
  static func problem(_ f: ShareForm) -> String? {
    if f.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Gib dem Netzlaufwerk einen Namen." }
    return ShareURL.problem(f.address)
  }

  static func cleanFolder(_ folder: String) -> String {
    folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
  }

  /// nil = Ordner passt (relativ zur Freigabe, ohne „..“).
  static func folderProblem(_ folder: String) -> String? {
    let t = cleanFolder(folder)
    if t.isEmpty { return "Ordnername fehlt." }
    if t.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
      return "Nur Ordner innerhalb der Freigabe, ohne „..“."
    }
    return nil
  }

  /// Statuszeile je Zustand: (Text, verbunden, Fehler).
  static func status(_ state: ShareState?) -> (text: String, connected: Bool, failed: Bool) {
    if state?.mounted == true { return ("verbunden", true, false) }
    if let error = state?.error, !error.isEmpty { return (error, false, true) }
    return ("nicht verbunden", false, false)
  }

  static func share(_ f: ShareForm, id: String) -> NetworkShare {
    NetworkShare(id: id, name: f.name.trimmingCharacters(in: .whitespaces),
                 url: f.address.trimmingCharacters(in: .whitespacesAndNewlines),
                 user: f.user.trimmingCharacters(in: .whitespaces), autoMount: f.autoMount,
                 searchFolders: f.folders.map(cleanFolder).filter { !$0.isEmpty })
  }
}

/// Karte „Netzlaufwerke“. Die Aktionen kommen von außen (Einstellungen → Verbindungen).
struct ShareCard: View {
  let shares: [NetworkShare]
  let states: [String: ShareState]
  var onToggle: (String, Bool) async -> Void
  var onSave: (ShareForm) -> Void
  var onDelete: (String) async -> Void
  @State private var form: ShareForm?
  @State private var busy: Set<String> = []
  @State private var confirmDelete: NetworkShare?

  init(shares: [NetworkShare], states: [String: ShareState],
       onToggle: @escaping (String, Bool) async -> Void = { _, _ in },
       onSave: @escaping (ShareForm) -> Void = { _ in },
       onDelete: @escaping (String) async -> Void = { _ in },
       previewForm: ShareForm? = nil) {
    self.shares = shares; self.states = states
    self.onToggle = onToggle; self.onSave = onSave; self.onDelete = onDelete
    _form = State(initialValue: previewForm)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        SectionHeader(symbol: "externaldrive.connected.to.line", title: "Netzlaufwerke")
        Spacer(minLength: 0)
        if form == nil {
          Button("+ Netzlaufwerk") { form = ShareForm() }
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        }
      }
      if shares.isEmpty && form == nil {
        Text("Noch kein Netzlaufwerk. Mit „+ Netzlaufwerk“ verbindest du ein NAS oder einen Server per SMB, so wie im Finder.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(shares) { share in row(share) }
      if form != nil {
        ShareFormView(form: Binding(get: { form ?? ShareForm() }, set: { form = $0 }),
                      onCancel: { form = nil },
                      onSave: {
                        if let f = form { onSave(f) }
                        form = nil
                      })
      }
    }
    .tabyCard()
    .onAppear {
      if form == nil, let host = ShareDraft.take() { form = ShareForm(address: host) }
    }
    .confirmationDialog("Netzlaufwerk löschen?",
                        isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                        titleVisibility: .visible) {
      Button("Löschen", role: .destructive) {
        if let share = confirmDelete { Task { await onDelete(share.id) } }
        confirmDelete = nil
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Lumi vergisst Adresse und Passwort. Die Dateien auf dem Server bleiben unverändert.")
    }
  }

  private func row(_ share: NetworkShare) -> some View {
    let state = states[share.id]
    let status = ShareFormLogic.status(state)
    let mounted = state?.mounted == true
    let working = busy.contains(share.id)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        StatusDot(color: status.connected ? Theme.green : (status.failed ? Theme.red : Theme.tertiary), size: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(share.name)
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
          Text(working ? "verbindet …" : status.text)
            .font(.system(size: 11)).foregroundStyle(status.failed ? Theme.red : Theme.tertiary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 4)
        Button(mounted ? "Trennen" : "Verbinden") {
          busy.insert(share.id)
          Task {
            await onToggle(share.id, mounted)
            busy.remove(share.id)
          }
        }
        .buttonStyle(PillButtonStyle(kind: mounted ? .secondary : .primary, compact: true))
        .disabled(working)
      }
      HStack(spacing: 6) {
        Text(share.url)
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        Button("Bearbeiten") { form = ShareForm(share: share) }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Button("Löschen") { confirmDelete = share }
          .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }
}

/// Formular „+ Netzlaufwerk“ bzw. „Bearbeiten“.
struct ShareFormView: View {
  @Binding var form: ShareForm
  let onCancel: () -> Void
  let onSave: () -> Void
  @State private var folderError: String?

  var body: some View {
    let problem = ShareFormLogic.problem(form)
    VStack(alignment: .leading, spacing: 8) {
      Text(form.id == nil ? "Neues Netzlaufwerk" : "Netzlaufwerk bearbeiten")
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
      InputCapsule(placeholder: "Name, z. B. Dokumente", text: $form.name) { EmptyView() }
      InputCapsule(placeholder: "smb://nas.local/Dokumente", text: $form.address, mono: true) { EmptyView() }
      if !form.address.isEmpty, let message = ShareURL.problem(form.address) {
        Banner(symbol: "exclamationmark.triangle.fill", text: message, tint: Theme.red)
      }
      InputCapsule(placeholder: "Benutzer", text: $form.user) { EmptyView() }
      InputCapsule(placeholder: form.id == nil ? "Passwort (nur im Schlüsselbund)" : "Passwort – leer lassen = unverändert",
                   text: $form.password, secure: true) { EmptyView() }
      if form.id != nil {
        HStack(spacing: 6) {
          if form.clearPassword {
            Text("Gespeichertes Passwort wird beim Speichern entfernt.")
              .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          }
          Spacer(minLength: 0)
          Button(form.clearPassword ? "Doch behalten" : "Gespeichertes Passwort entfernen") {
            form.clearPassword.toggle()
            form.password = ""
          }
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        }
      }
      PillToggle(title: "Beim Start verbinden", isOn: $form.autoMount)
      Text("Nur in Netzen, denen du vertraust: Lumi sendet dein Passwort an den Server mit diesem Namen.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Durchsuchbare Ordner")
          .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
        Text(ShareFormLogic.explanation)
          .font(.system(size: 11)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(form.folders, id: \.self) { folder in
          HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(Theme.secondary)
            Text(folder).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Button("Entfernen") { form.folders.removeAll { $0 == folder } }
              .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
          }
        }
        InputCapsule(placeholder: "Unterordner, z. B. Unterlagen", text: $form.folderDraft) {
          Button("Hinzufügen", action: addFolder)
            .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            .disabled(ShareFormLogic.cleanFolder(form.folderDraft).isEmpty)
        }
        if let folderError {
          Banner(symbol: "exclamationmark.triangle.fill", text: folderError, tint: Theme.red)
        }
      }
      HStack(spacing: 8) {
        Button("Abbrechen", action: onCancel)
          .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
        Spacer(minLength: 0)
        Button("Speichern", action: onSave)
          .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
          .disabled(problem != nil)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
  }

  private func addFolder() {
    let folder = ShareFormLogic.cleanFolder(form.folderDraft)
    if let problem = ShareFormLogic.folderProblem(folder) {
      folderError = problem
      return
    }
    folderError = nil
    if !form.folders.contains(folder) { form.folders.append(folder) }
    form.folderDraft = ""
  }
}

extension SettingsView {
  /// Netzlaufwerk speichern: erst die Liste in die Einstellungen, dann das Passwort in den Schlüsselbund.
  func saveShare(_ f: ShareForm) {
    let id = f.id ?? UUID().uuidString
    let share = ShareFormLogic.share(f, id: id)
    var list = form.networkShares
    if let i = list.firstIndex(where: { $0.id == id }) { list[i] = share } else { list.append(share) }
    form.networkShares = list
    let passwordChange = f.clearPassword || !f.password.isEmpty
    Task {
      await commitRisky()
      if passwordChange {
        _ = await model.services.setSharePassword(id, password: f.clearPassword ? "" : f.password)
      }
      await model.refresh()
    }
  }

  /// Verbinden bzw. trennen; das Ergebnis (oder der Fehler) steht danach im Zustand.
  func toggleShare(_ id: String, mounted: Bool) async {
    if mounted {
      _ = await model.services.unmountShare(id)
    } else {
      _ = await model.services.mountShare(id)
    }
    await model.refresh()
  }

  /// Löschen: Passwort aus dem Schlüsselbund, dann Eintrag aus der Liste. Eingehängte Freigaben bleiben stehen.
  func deleteShare(_ id: String) async {
    _ = await model.services.setSharePassword(id, password: "")
    form.networkShares.removeAll { $0.id == id }
    await commitRisky()
    await model.refresh()
  }
}
