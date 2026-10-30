// Reine Hilfen der dritten Runde (Tagesplan-Abschnitte, Rückgängig, Suche, Timer, Wiederholung, Sicherungen).
// Ohne Ansicht, damit die Prüfungen sie direkt testen können.
import Foundation
import TabyCore

enum ViewSupportLogic {
  // MARK: Tagesplan-Abschnitte

  /// Offen, sobald darin eine überfällige oder heutige Aufgabe steht; sonst eingeklappt.
  static func sectionOpenByDefault(_ section: PlanPickSection, now: String) -> Bool {
    section.groups.flatMap(\.tasks).contains { t in
      guard let kind = TaskLogic.dueChip(t.due, now: now)?.kind else { return false }
      return kind == .overdue || kind == .today
    }
  }

  // MARK: Rückgängig

  static func undoVisible(_ label: String?) -> Bool {
    !(label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
  }

  // MARK: Suche

  /// Wartezeit, bis aus der Eingabe eine Suche wird.
  static let debounceNanos: UInt64 = 250_000_000

  struct SearchGroup: Equatable, Identifiable {
    let kind: SearchHit.Kind
    let title: String
    let hits: [SearchHit]
    var id: String { kind.rawValue }
  }

  /// Feste Reihenfolge der Gruppen; leere Gruppen fehlen.
  static func searchGroups(_ hits: [SearchHit]) -> [SearchGroup] {
    let order: [SearchHit.Kind] = [.task, .note, .event, .memory]
    return order.compactMap { kind in
      let items = hits.filter { $0.kind == kind }
      return items.isEmpty ? nil : SearchGroup(kind: kind, title: searchTitle(kind), hits: items)
    }
  }

  static func searchTitle(_ kind: SearchHit.Kind) -> String {
    switch kind {
    case .task: "Aufgaben"
    case .note: "Notizen"
    case .event: "Termine"
    case .memory: "Gedächtnis"
    }
  }

  /// "Fr., 9. Okt." bzw. mit Uhrzeit "Fr., 9. Okt. · 09:30"; nil ohne Datum.
  static func searchDate(_ date: String?) -> String? {
    guard let date, !date.isEmpty else { return nil }
    let day = GermanDate.short(date)
    guard let time = GermanDate.time(date) else { return day }
    return "\(day) · \(time)"
  }

  /// Reiter, den ein Treffer öffnet; Gedächtnis hat keinen.
  static func tab(for kind: SearchHit.Kind) -> TabyTab? {
    switch kind {
    case .task: .tasks
    case .note: .notes
    case .event: .calendar
    case .memory: nil
    }
  }

  /// Chat-Eingang für Heute, solange der Reiter „Nachrichten“ nicht zu sehen ist (sonst leer).
  static func hiddenMessagesInbox(settings s: TabySettings, inbox: [InboxItem]) -> [InboxItem] {
    let hidden = !s.messengerEnabled || s.hiddenTabs.contains(TabyTab.messages.rawValue)
    return hidden ? inbox.filter { $0.channel != "Mail" } : []
  }

  // MARK: Kurzzeit-Timer

  static let timerPresets = [5, 10, 15, 25, 45]
  static let timerLabel = "Timer"

  /// Eigene Minuten: nur ganze Zahlen von 1 bis 720 (wie der Kern).
  static func customMinutes(_ text: String) -> Int? {
    guard let m = Int(text.trimmingCharacters(in: .whitespaces)), (1...720).contains(m) else { return nil }
    return m
  }

  /// Restzeit "m:ss" bis zum Ablauf; "abgelaufen", wenn die Zeit vorbei ist.
  static func remainingText(endsAt: String, now: String) -> String {
    guard let end = LocalTime.parse(endsAt), let current = LocalTime.parse(now) else { return "" }
    let secs = Int(end.timeIntervalSince(current).rounded(.down))
    guard secs > 0 else { return "abgelaufen" }
    return String(format: "%d:%02d", secs / 60, secs % 60)
  }

  // MARK: Wiederholung

  /// nil = nie; sonst Titel wie im Kern ("Täglich", "Werktags",…).
  static func recurrenceTitle(_ r: TaskRecurrence?) -> String { r?.title ?? "Nie" }

  /// Patch-Wert für `TaskPatch(recurrence:)`: "" = keine Wiederholung.
  static func recurrencePatch(_ r: TaskRecurrence?) -> String { r?.rawValue ?? "" }

  // MARK: Sicherungen

  /// "Fr., 9. Okt. · 08:30" aus dem lokalen Zeitstempel der Sicherung.
  static func backupTitle(_ b: BackupInfo) -> String {
    let day = GermanDate.short(b.createdAt)
    guard let time = GermanDate.time(b.createdAt) else { return day }
    return "\(day) · \(time)"
  }

  static func backupSize(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

/// Merkt, welche Abschnitte im Tagesplan offen sind, solange die App läuft (pro Abschnitts-ID).
@MainActor
enum PlanSectionMemory {
  static var open: [String: Bool] = [:]
}
