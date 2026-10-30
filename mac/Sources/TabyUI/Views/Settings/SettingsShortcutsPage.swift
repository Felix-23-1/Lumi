// Seite „Tastenkürzel“: Recorder statt Tippfelder. Gespeichert wird weiter in der Schreibweise
// „Control+Option+Space“, damit die Kurzbefehle (HotKeys) unverändert funktionieren.
import AppKit
import SwiftUI
import TabyCore

extension SettingsView {
  var shortcutsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(symbol: "command", title: "Tastenkürzel")
      Text("Klick auf eine Kombination, dann die neue Tastenfolge drücken. Esc bricht ab. "
        + "Mit „Zurücksetzen“ kommt die Vorgabe zurück.")
        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        .fixedSize(horizontal: false, vertical: true)
      shortcutField("Notch ein- und ausblenden", $form.globalShortcut, defaultValue: "Control+Option+Space")
      shortcutField("Schnellerfassung", $form.quickCaptureShortcut, defaultValue: "Control+Option+N")
      shortcutField("Markierten Text übernehmen", $form.captureSelectionShortcut, defaultValue: "Control+Option+C")
      shortcutField("Merk dir das", $form.captureContextShortcut, defaultValue: "Control+Option+M")
      shortcutField("Sprechen (gedrückt halten)", $form.voiceInputShortcut, defaultValue: "Control+Option+S")
      shortcutField("Markierten Text erklären", $form.explainShortcut, defaultValue: "Control+Option+E")
      shortcutField("Einkreisen und fragen", $form.circleShortcut, defaultValue: "Control+Option+K")
    }
    .tabyCard()
  }

  func shortcutField(_ title: String, _ value: Binding<String>, defaultValue: String) -> some View {
    let text = value.wrappedValue
    let parses = SettingsLogic.shortcutParses(text)
    // Nur was korrekt geschrieben ist, kann „belegt“ sein; alles andere ist schlicht unbekannt.
    let taken = !text.isEmpty && parses && model.shortcutConflicts.contains(text)
    let unknown = !text.isEmpty && !parses
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
        Spacer(minLength: 4)
        ShortcutRecorder(value: value, defaultValue: defaultValue) { commit() }
      }
      if unknown {
        Text("Unbekannte Tastenkombination")
          .font(.system(size: 11)).foregroundStyle(Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      } else if taken {
        Text("Schon von einer anderen App belegt – bitte andere Kombination wählen.")
          .font(.system(size: 11)).foregroundStyle(Theme.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Nimmt die nächste Tastenkombination auf (lokaler Monitor, nur solange die Einstellungen offen sind).
/// Aufgenommen wird nach Tastencode (`ShortcutKeys`), nicht nach dem Zeichen: so stimmt die Taste auch im QWERTZ-Layout.
/// Nur eine Aufnahme ist gleichzeitig aktiv: beginnt eine andere, endet diese.
struct ShortcutRecorder: View {
  @Binding var value: String
  let defaultValue: String
  let onCommit: () -> Void
  @State private var recording = false
  @State private var notice: String?
  @State private var monitor: Any?
  @State private var token = UUID()
  @Environment(\.tabySnapshot) private var snapshot

  /// Ein Recorder meldet hier, dass er beginnt; die anderen hören auf.
  static let startedNotification = Notification.Name("taby.shortcut.recording")

  var body: some View {
    HStack(spacing: 6) {
      Button(action: { recording ? stop() : start() }) {
        Text(recording ? (notice ?? "Tasten drücken…") : (value.isEmpty ? "Keiner" : value))
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .lineLimit(1)
          .frame(width: 190, alignment: .trailing)
      }
      .buttonStyle(PillButtonStyle(kind: recording ? .primary : .secondary, compact: true))
      .disabled(snapshot)
      if value != defaultValue {
        Button("Zurücksetzen") {
          stop()
          value = defaultValue
          onCommit()
        }
        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true))
      }
    }
    .onDisappear { stop() }
    .onReceive(NotificationCenter.default.publisher(for: Self.startedNotification)) { note in
      if let other = note.object as? UUID, other != token { stop() }
    }
  }

  private func start() {
    stop()
    recording = true
    notice = nil
    NotificationCenter.default.post(name: Self.startedNotification, object: token)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event)
      return nil  // die Taste erreicht die Oberfläche nicht, solange aufgenommen wird
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
    notice = nil
  }

  private func handle(_ event: NSEvent) {
    // Esc bricht ab (ohne Zeichen; die Esc-Taste hat einen eigenen Code).
    if event.keyCode == 53 { stop(); return }
    guard let key = ShortcutKeys.name(forKeyCode: event.keyCode) else {
      notice = "Taste nicht unterstützt"
      return
    }
    let flags = event.modifierFlags
    var mods = Set<String>()
    if flags.contains(.control) { mods.insert("Control") }
    if flags.contains(.option) { mods.insert("Option") }
    if flags.contains(.shift) { mods.insert("Shift") }
    if flags.contains(.command) { mods.insert("Command") }
    guard let combo = SettingsLogic.shortcutString(modifiers: mods, key: key) else {
      notice = "Mit Control, Option oder Command kombinieren"
      return
    }
    stop()
    value = combo
    onCommit()
  }
}
