// Einstellungen im eigenen Fenster (ToolWindow) und das Feld für den API-Schlüssel.
// Das Fenster zeigt SettingsView mit Seitenleiste; gespeichert wird automatisch.
import SwiftUI
import TabyCore

/// Einstellungen im eigenen Fenster: Seitenleiste mit allen Themen, Inhalt rechts.
public struct SettingsWindowView: View {
  @EnvironmentObject private var model: AppModel

  public init() {}

  public var body: some View {
    let state = model.state ?? AppState()
    SettingsView(settings: state.settings, sources: state.calendarSources, jobs: state.jobs, layout: .window)
  }
}

/// Scrollbereich fürs Fenster; im Snapshot erscheint der Inhalt direkt (ScrollView rendert dort leer).
struct SettingsScroll<Content: View>: View {
  @ViewBuilder var content: () -> Content
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    if snapshot {
      // Vorschau: Seite oben bündig, was über den Platz hinausragt, wird abgeschnitten (wie im Scrollbereich).
      content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
    } else {
      ScrollView(.vertical, showsIndicators: false) { content() }
    }
  }
}

/// API-Schlüssel: speichert nur bei Enter oder wenn das Feld den Fokus verliert (nie pro Tastendruck).
struct KeyField: View {
  let placeholder: String
  @Binding var text: String
  let onCommit: () -> Void
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    ZStack(alignment: .leading) {
      if text.isEmpty {
        Text(placeholder).foregroundStyle(Theme.tertiary).lineLimit(1).allowsHitTesting(false)
      }
      if snapshot {
        Text(String(repeating: "•", count: text.count)).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        SecureField("", text: $text)
          .textFieldStyle(.plain)
          .focused($focused)
          .onSubmit(onCommit)
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(Theme.text)
    .padding(.horizontal, 12)
    .frame(minHeight: 32)
    .background(Capsule().fill(focused ? Theme.capsuleHover : Theme.capsule))
    .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.22 : 0), lineWidth: 1))
    .animation(Theme.snappy, value: focused)
    .onChange(of: focused) { _, now in if !now { onCommit() } }
  }
}
