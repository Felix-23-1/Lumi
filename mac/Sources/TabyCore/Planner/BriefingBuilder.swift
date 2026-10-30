// Port von src/main/planner/briefing.ts. Das deterministische `Overview` (Code) wird per
// einem Modellaufruf formuliert. Schlägt der Aufruf mit `LlmError` fehl, liefert er leeren
// Text oder ist kein Modell da, kommt ein vollständiges regelbasiertes deutsches Briefing —
// ohne Modell und ohne Netz (BAUPLAN 9, CLAUDE.md).
import Foundation

public enum BriefingBuilder {
  /// Formuliert den Briefing-Text aus dem Overview (Integrator: ein Modellaufruf).
  public typealias Formulate = (Overview) async throws -> String

  /// Eingebaute Vorgabe: Regeln plus Muster, an dem sich das Modell orientiert.
  /// In den Einstellungen (Tagesbriefing → Vorgabe) durch eine eigene ersetzbar.
  public static let defaultPrompt = """
    Du bist Lumi und sagst morgens in wenigen Sätzen, was heute ansteht – so, wie ein guter Assistent es \
    im Gespräch sagen würde. Der Text wird auch vorgelesen.

    Regeln:
    - Fließtext, zwei bis fünf kurze Sätze. Keine Überschrift, keine Aufzählung, kein Fettdruck, keine Emojis.
    - Wichtigstes zuerst: Überschneidungen und Überfälliges, dann Termine mit Uhrzeit, dann Aufgaben und Habits.
    - Erwähne nur, was es gibt. Was fehlt (keine Konflikte, keine Aufgaben), lässt du weg.
    - Keine IDs, Datenfelder oder Technik. Nichts erfinden, was nicht in den Stichpunkten steht.
    - Höchstens ein Vorschlag, womit man anfangen sollte, und nur, wenn mehr als eine Sache ansteht.
    - Ist wenig los, reicht ein Satz.

    Muster (nur Ton und Länge übernehmen, nie den Inhalt):
    Stichpunkte: Überfällig: Steuer (fällig 10.10.) / Termine heute: 09:30 Standup; 14:00 Zahnarzt / Aufgaben heute: Einkaufen
    Briefing: Die Steuer ist seit Freitag überfällig – die würde ich als Erstes angehen. Um halb zehn hast du Standup \
    und um zwei den Zahnarzt. Einkaufen passt gut in die Lücke danach.

    Stichpunkte: Ganztägig heute: Katrin Geburtstag / Offene Habits: Pausen machen beim Arbeiten
    Briefing: Heute hat Katrin Geburtstag, denk ans Gratulieren. Sonst ist nichts geplant – ein guter Tag, um \
    bewusst Pausen zu machen.
    """

  /// Die Vorgabe, die ans Modell geht: eigene aus den Einstellungen, sonst die eingebaute.
  public static func prompt(custom: String) -> String {
    custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt : custom
  }

  /// Wirft nur Fehler, die kein `LlmError` sind (Programmierfehler, wie in TS).
  public static func build(_ overview: Overview, formulate: Formulate?, birthdays: [String] = []) async throws -> Briefing {
    if let formulate {
      do {
        let text = try await formulate(overview)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          return Briefing(overview: overview, text: text, generatedByModel: true)
        }
      } catch is LlmError {
        // Fallback unten.
      }
    }
    return Briefing(overview: overview, text: fallbackText(overview, birthdays: birthdays), generatedByModel: false)
  }

  /// Bequemlichkeit: Formulierung über einen `LlmClient` (nil = sofort Fallback).
  /// `customPrompt` ist die eigene Vorgabe aus den Einstellungen (leer = eingebaute).
  /// Geburtstage gehen nur mit `birthdaysToModel` (lokales Modell) ans Modell; sonst nur in den Fallback.
  public static func build(_ overview: Overview, llm: LlmClient?, customPrompt: String = "",
                           birthdays: [String] = [], birthdaysToModel: Bool = false) async throws -> Briefing {
    guard let llm else { return try await build(overview, formulate: nil, birthdays: birthdays) }
    return try await build(overview, formulate: { o in
      try await askModel(o, llm: llm, customPrompt: customPrompt, birthdays: birthdaysToModel ? birthdays : [])
    }, birthdays: birthdays)
  }

  static func askModel(_ overview: Overview, llm: LlmClient, customPrompt: String = "",
                       birthdays: [String] = []) async throws -> String {
    let reply = try await llm.chat(
      messages: [
        ChatMessage(role: .system, content: prompt(custom: customPrompt)),
        ChatMessage(role: .user, content: facts(overview, birthdays: birthdays)),
      ],
      tools: nil
    )
    guard let content = reply.content.map(cleanReply), !content.isEmpty else {
      throw LlmError(.badResponse, "Leere Antwort vom Modell")
    }
    return content
  }

  /// Manche Modelle wiederholen das Muster („Stichpunkte: … Briefing: …“): nur den Briefing-Teil behalten.
  static func cleanReply(_ reply: String) -> String {
    var text = reply
    if let r = text.range(of: "Briefing:", options: .backwards) { text = String(text[r.upperBound...]) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Stichpunkte:") }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Stichpunkte für das Modell: nur, was ansteht, ohne IDs, Notizen oder leere Bereiche.
  /// Erledigte/quittierte Erinnerungen und solche ohne Titel fallen weg; Erinnerungen zu
  /// Aufgaben, die ohnehin genannt werden, auch. Schickt dabei weniger Daten ins Netz.
  /// `birthdays`: Namen, deren Geburtstag heute ist (eine Zeile je Name).
  public static func facts(_ o: Overview, birthdays: [String] = []) -> String {
    var lines: [String] = []
    func add(_ label: String, _ items: [String]) {
      if !items.isEmpty { lines.append("\(label): \(items.joined(separator: "; "))") }
    }
    add("Überschneidung", o.conflicts.map { "„\($0.with.title)“ \(when($0.with))" })
    add("Kalender nicht erreichbar", o.unreachableCalendarSources.map(\.message))
    add("Überfällig", o.overdueTasks.map { t in t.due.map { "\(t.title) (fällig \(shortDate($0)))" } ?? t.title })
    add("Ganztägig heute", o.eventsToday.filter(\.allDay).map(\.title))
    lines += birthdays.map { "Geburtstag: \($0)" }
    add("Termine heute", o.eventsToday.filter { !$0.allDay }.map { "\(time($0.start)) \($0.title)" })
    add("Aufgaben heute", o.todayTasks.filter { !$0.done }.map(\.title))
    let named = Set((o.overdueTasks + o.todayTasks).map(\.id))
    let reminders = o.remindersToday.filter { r in
      r.reminder.firedAt == nil && r.reminder.acknowledgedAt == nil && !named.contains(r.reminder.sourceRef)
        && !r.title.trimmingCharacters(in: .whitespaces).isEmpty
    }
    add("Erinnerungen", reminders.map { "\(time($0.reminder.dueAt)) \($0.title)" })
    add("Verpasste Erinnerungen", o.missed.map(\.title).filter { !$0.isEmpty })
    add("Offene Habits", o.habitsToday.filter { !$0.checkedToday }.map(\.name))
    add("Demnächst", o.eventsUpcoming.prefix(3).map { "„\($0.title)“ \(when($0))" })
    return lines.isEmpty ? "Heute steht nichts an." : lines.joined(separator: "\n")
  }

  private static func time(_ s: String) -> String { LocalTime.isDateOnly(s) ? "" : String(s.suffix(5)) }

  private static func shortDate(_ s: String) -> String {
    let p = LocalTime.datePart(s).split(separator: "-")
    guard p.count == 3, let d = Int(p[2]), let m = Int(p[1]) else { return s }
    return "\(d).\(m)."
  }

  private static func when(_ e: CalendarEvent) -> String {
    e.allDay ? "am \(shortDate(e.start))" : "am \(shortDate(e.start)) um \(time(e.start))"
  }

  /// Regelbasierter Text aus denselben Daten; nie leer.
  public static func fallbackText(_ o: Overview, birthdays: [String] = []) -> String {
    var lines: [String] = []
    if !o.missed.isEmpty { lines.append("Verpasst: \(o.missed.count) Erinnerung(en) wurden nicht ausgelöst.") }
    for s in o.unreachableCalendarSources { lines.append("Kalenderquelle nicht erreichbar: \(s.message)") }
    if !o.conflicts.isEmpty { lines.append("Achtung: \(o.conflicts.count) Terminkonflikt(e) heute.") }
    lines.append(o.eventsToday.isEmpty
      ? "Heute keine Termine."
      : "Termine heute: \(o.eventsToday.map(\.title).joined(separator: ", ")).")
    lines += birthdays.map { "Geburtstag: \($0)." }
    if !o.eventsUpcoming.isEmpty {
      lines.append("Demnächst: \(o.eventsUpcoming.map(\.title).joined(separator: ", ")).")
    }
    if !o.overdueTasks.isEmpty {
      lines.append("Überfällige Aufgaben: \(o.overdueTasks.map(\.title).joined(separator: ", ")).")
    }
    if !o.todayTasks.isEmpty { lines.append("Aufgaben heute: \(o.todayTasks.map(\.title).joined(separator: ", ")).") }
    if !o.habitsToday.isEmpty {
      lines.append("Noch offene Habits: \(o.habitsToday.map(\.name).joined(separator: ", ")).")
    }
    if !o.remindersToday.isEmpty { lines.append("\(o.remindersToday.count) Erinnerung(en) heute geplant.") }
    return lines.joined(separator: "\n")
  }
}
