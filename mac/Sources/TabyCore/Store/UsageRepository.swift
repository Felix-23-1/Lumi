// Verbrauch der Modell-Antworten (Paket 1): Speicherung je Antwort und Summen
// für heute und den laufenden Monat (lokale Zeit aus der injizierten Uhr).
// Tokens = Prompt + Antwort; fehlende Kosten zählen als 0.
import Foundation

public final class UsageRepository: @unchecked Sendable {
  let db: Database
  let clock: Clock

  public init(db: Database, clock: Clock) {
    self.db = db; self.clock = clock
  }

  /// Protokolliert den Verbrauch einer Antwort; Zeitpunkt aus der Uhr.
  public func record(_ u: LlmUsage) throws {
    let cost: SQLValue = u.costUsd.map { SQLValue.double($0) } ?? .null
    try db.run(
      "INSERT INTO llm_usage (id, at, model, prompt_tokens, completion_tokens, cost_usd) VALUES (?, ?, ?, ?, ?, ?)",
      [.text(StoreIds.make()), .text(StoreDates.now(clock)), .text(u.model), .of(u.promptTokens),
       .of(u.completionTokens), cost])
  }

  /// Verbrauch heute und im laufenden Monat. Ein Limit gilt nur, wenn es > 0 ist.
  /// `limitReached`: Tages- oder Monatskosten erreichen ihr Limit. `nearLimit`:
  /// mindestens 80 % eines Limits sind verbraucht.
  public func summary(dailyLimit: Double, monthlyLimit: Double) throws -> UsageSummary {
    let today = StoreDates.today(clock)
    // Bereichsabfrage über den Index auf `at` (statt substr je Zeile): [1. des Monats, 1. des Folgemonats).
    let monthStart = String(today.prefix(7)) + "-01"
    let nextMonthStart = String(StoreDates.shiftDateOnly(monthStart, 31).prefix(7)) + "-01"
    let rows = try db.query(
      "SELECT at, prompt_tokens, completion_tokens, cost_usd FROM llm_usage WHERE at >= ? AND at < ?",
      [.text(monthStart), .text(nextMonthStart)])
    var s = UsageSummary()
    for r in rows {
      let cost = Self.costUsd(r)
      let tokens = Int(r.int("prompt_tokens") ?? 0) + Int(r.int("completion_tokens") ?? 0)
      s.monthUsd += cost
      s.monthTokens += tokens
      if LocalTime.datePart(r.text("at")) == today {
        s.todayUsd += cost
        s.todayTokens += tokens
      }
    }
    s.limitReached = (dailyLimit > 0 && s.todayUsd >= dailyLimit) || (monthlyLimit > 0 && s.monthUsd >= monthlyLimit)
    s.nearLimit = (dailyLimit > 0 && s.todayUsd >= 0.8 * dailyLimit)
      || (monthlyLimit > 0 && s.monthUsd >= 0.8 * monthlyLimit)
    return s
  }

  /// Löscht Verbrauchszeilen vor den letzten `keepDays` Tagen (0 = nie löschen).
  public func prune(keepDays: Int) throws {
    guard keepDays > 0 else { return }
    let cutoff = StoreDates.shiftDateOnly(StoreDates.today(clock), -(keepDays - 1))
    try db.run("DELETE FROM llm_usage WHERE at < ?", [.text(cutoff)])
  }

  /// NULL-Kosten zählen als 0.
  private static func costUsd(_ r: SQLRow) -> Double {
    switch r.values["cost_usd"] {
    case .double(let d)?: return d
    case .int(let i)?: return Double(i)
    default: return 0
    }
  }
}
