// Textfeld für riskante Werte (Endpunkt, Modell, Tastenkürzel): der Wert geht erst bei Enter
// oder wenn das Feld den Fokus verliert an `onCommit`, nie pro Tastendruck.
import SwiftUI
import TabyCore

struct CommitField<Trailing: View>: View {
  let placeholder: String
  @Binding var text: String
  var mono = false
  let onCommit: () -> Void
  @ViewBuilder var trailing: () -> Trailing
  @FocusState private var focused: Bool
  @Environment(\.tabySnapshot) private var snapshot

  var body: some View {
    HStack(spacing: 6) {
      ZStack(alignment: .leading) {
        if text.isEmpty {
          Text(placeholder).foregroundStyle(Theme.tertiary).lineLimit(1).allowsHitTesting(false)
        }
        if snapshot {
          Text(text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        } else {
          TextField("", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(onCommit)
        }
      }
      .font(.system(size: 13, design: mono ? .monospaced : .default))
      .foregroundStyle(Theme.text)
      trailing()
    }
    .padding(.leading, 12)
    .padding(.trailing, 4)
    .frame(minHeight: 32)
    .background(Capsule().fill(focused ? Theme.capsuleHover : Theme.capsule))
    .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.22 : 0.0), lineWidth: 1))
    .animation(Theme.snappy, value: focused)
    .onChange(of: focused) { _, now in if !now { onCommit() } }
  }
}

extension CommitField where Trailing == EmptyView {
  init(placeholder: String, text: Binding<String>, mono: Bool = false, onCommit: @escaping () -> Void) {
    self.init(placeholder: placeholder, text: text, mono: mono, onCommit: onCommit) { EmptyView() }
  }
}
