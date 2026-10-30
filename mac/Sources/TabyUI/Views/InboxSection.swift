// Abschnitt „Eingang“ im Reiter „Nachrichten“: Mails und Chats, die auf eine Antwort warten.
// „Antworten“ öffnet nur einen Entwurf (Mail) bzw. den Chat mit leerem Feld; Lumi sendet nie selbst.
// „Erledigt“ blendet den Punkt aus, bis eine neuere Nachricht kommt.
import SwiftUI
import TabyCore

struct InboxSection: View {
  let items: [InboxItem]
  let today: String
  /// Öffnet den Chat (Kennung = Unterhaltung) mit dem Verlauf.
  let onOpenChat: (String) -> Void
  @EnvironmentObject private var model: AppModel
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Eingang")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 2)
      if let failure { Banner(symbol: "exclamationmark.triangle.fill", text: failure, tint: Theme.red) }
      ForEach(items) { row($0) }
    }
  }

  private func row(_ item: InboxItem) -> some View {
    let needs = item.kind == .needsReply
    return HStack(alignment: .center, spacing: 10) {
      Image(systemName: needs ? "arrowshape.turn.up.left.fill" : "clock")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(needs ? Theme.blue : Theme.tertiary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Text("\(needs ? "Antwort nötig" : "wartet") · \(item.from) · \(item.channel) · \(MessagesLogic.timeLabel(item.at, today: today))")
          .font(.system(size: 11))
          .foregroundStyle(Theme.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      Button("Antworten") { reply(item) }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.blue)
      Button("Erledigt") { done(item) }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondary)
    }
    .tabyCard()
  }

  private func reply(_ item: InboxItem) {
    Task {
      let r = await model.services.draftReply(item.id)
      guard r.isOk else { failure = r.errorMessage; return }
      failure = nil
      if item.channel != "Mail" { onOpenChat(item.id) }
    }
  }

  private func done(_ item: InboxItem) {
    Task {
      await model.services.markInboxDone(item.id)
      await model.refresh()
    }
  }
}
