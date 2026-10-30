// Merk dir das: kleine Karte in der Insel. Zeigt App, Titel und Link/Auszug der vorigen App
// und speichert auf Knopfdruck als Notiz, Aufgabe oder „Später lesen“.
import SwiftUI
import TabyCore

struct ContextCaptureView: View {
  let context: CapturedContext
  let onDone: () -> Void
  @EnvironmentObject private var model: AppModel
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(context.app)
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
      Text(context.title)
        .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
      if let detail = detailLine {
        Text(detail)
          .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
      }
      HStack(spacing: 8) {
        target("Notiz", .note)
        target("Aufgabe", .task)
        target("Später lesen", .readLater)
        Button { onDone() } label: {
          Text("Abbrechen").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
      }
      .disabled(busy)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Link zuerst, sonst der Auszug.
  private var detailLine: String? {
    [context.url, context.text].compactMap { $0 }.first { !$0.isEmpty }
  }

  private func target(_ title: String, _ kind: CaptureTarget) -> some View {
    Button { save(kind) } label: {
      Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised))
    }
    .buttonStyle(.plain)
  }

  private func save(_ kind: CaptureTarget) {
    busy = true
    Task {
      let r = await model.services.saveCapture(context, as: kind)
      busy = false
      if let error = r.errorMessage {
        model.showFlash(TabyNotification(title: "Merk dir das", body: error))
      }
      onDone()
    }
  }
}
