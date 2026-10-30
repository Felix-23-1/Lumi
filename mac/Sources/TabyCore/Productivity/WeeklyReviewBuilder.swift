// Wochenrückblick (Paket 4): Montag einer Woche, Fälligkeit der Wochenfrage und
// der Rückblick aus Aufgaben, Habits, Fokus-Minuten und Terminen. Reiner Code.
import Foundation

public enum WeeklyReviewBuilder {
  /// Höchstens so viele Titel erledigter Aufgaben.
  static let maxDoneTitles = 5

  /// ISO-Wochentag: Montag = 1 … Sonntag = 7.
  static func isoWeekday(_ date: String) -> Int? {
    guard let d = StoreDates.wallClock(date) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let weekday = cal.component(.weekday, from: d)  // 1 = Sonntag
    return (weekday + 5) % 7 + 1
  }

  /// Montag der ISO-Woche, zu der `date` gehört ("YYYY-MM-DD"). Sonntag gehört
  /// zur Woche, die am Montag sechs Tage zuvor begann.
  public static func monday(of date: String) -> String {
    let day = LocalTime.datePart(date)
    guard let weekday = isoWeekday(day) else { return day }
    return StoreDates.shiftDateOnly(day, -(weekday - 1))
  }

  /// true, wenn `now` an Wochentag `day` (Montag = 1 … Sonntag = 7) und ab
  /// Uhrzeit `time` ("HH:mm") liegt.
  public static func isDue(now: String, day: Int, time: String) -> Bool {
    guard now.count >= 16, isoWeekday(now) == day else { return false }
    let hhmm = String(now.dropFirst(11).prefix(5))
    return hhmm >= time
  }

  /// Rückblick für die Woche ab `weekStart` bis einschließlich `today`.
  public static func build(weekStart: String, today: String, focusMinutes: Int, tasks: [TabyTask],
                           habitChecks: [(habit: Habit, dates: [String])], eventCount: Int,
                           goals: [WeeklyGoal]) -> WeeklyReview {
    func inWeek(_ day: String) -> Bool { day >= weekStart && day <= today }
    let done = tasks.filter { task in
      guard task.done, let doneAt = task.doneAt else { return false }
      return inWeek(LocalTime.datePart(doneAt))
    }
    let newestFirst = done.sorted { ($0.doneAt ?? "") > ($1.doneAt ?? "") }
    let habits = habitChecks.map { entry in
      HabitWeek(name: entry.habit.name, days: Set(entry.dates.filter(inWeek)).count, streak: entry.habit.streak)
    }
    return WeeklyReview(weekStart: weekStart, focusMinutes: focusMinutes, tasksDone: done.count,
                        doneTitles: newestFirst.prefix(maxDoneTitles).map(\.title), habits: habits,
                        events: eventCount, goals: goals)
  }
}
