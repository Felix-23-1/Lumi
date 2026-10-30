// VERTRAG (nur Orchestrator ändert): Prüfungen der Verträge selbst.
import Foundation

enum ContractChecks {
  static let suite = CheckSuite("Contracts", [
    CheckCase("Arbeitszeiten: Wochentag, Zeiten, Zusammenfassung") {
      var s = TabySettings()
      try expectEqual(WorkWeek.weekdayIndex("2026-10-16"), 4, "Freitag")
      try expectEqual(WorkWeek.weekdayIndex("2026-10-18T09:00"), 6, "Sonntag")
      try expect(WorkWeek.isWorkday(s, date: "2026-10-16") && !WorkWeek.isWorkday(s, date: "2026-10-17"))
      s.workHours[4] = "08:00-13:00"
      try expectEqual(WorkWeek.hours(s, date: "2026-10-16")?.end, "13:00")
      try expect(WorkWeek.parse("17:00-08:00") == nil && WorkWeek.parse("8-17") == nil)
      try expectEqual(WorkWeek.summary(s), "Mo–Do 08:00–17:00, Fr 08:00–13:00, Sa, So frei")
    },
    CheckCase("LocalTime: Rundreise mit und ohne Uhrzeit") {
      let d = try expectNotNil(LocalTime.parse("2026-10-11T09:30"))
      try expectEqual(LocalTime.format(d), "2026-10-11T09:30")
      let day = try expectNotNil(LocalTime.parse("2026-10-11"))
      try expectEqual(LocalTime.formatDate(day), "2026-10-11")
      try expect(LocalTime.isDateOnly("2026-10-11"))
      try expect(!LocalTime.isDateOnly("2026-10-11T09:30"))
    },
    CheckCase("ControllableClock rückt vor") {
      let c = ControllableClock("2026-10-11T08:00")
      c.advance(seconds: 90 * 60)
      try expectEqual(LocalTime.format(c.now()), "2026-10-11T09:30")
    },
    CheckCase("JobRule: JSON wie in TS") {
      let rule = JobRule.weekly(days: [1, 3], time: "08:00")
      let data = try JSONEncoder().encode(rule)
      let back = try JSONDecoder().decode(JobRule.self, from: data)
      try expectEqual(back, rule)
      let fromTs = try JSONDecoder().decode(JobRule.self, from: Data(#"{"type":"daily","time":"07:30"}"#.utf8))
      try expectEqual(fromTs, .daily(time: "07:30"))
    },
    CheckCase("ChatMessage: OpenAI-Schlüssel tool_calls/tool_call_id") {
      let m = ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "c1", name: "add_task", arguments: "{}")])
      let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
      try expect(json.contains("\"tool_calls\""), json)
      let t = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"tool","content":"{}","tool_call_id":"c1","name":"add_task"}"#.utf8))
      try expectEqual(t.toolCallId, "c1")
    },
    CheckCase("JSONValue: Rundreise und Literale") {
      let v: JSONValue = ["a": 1, "b": [true, "x", nil]]
      try expectEqual(JSONValue.parse(v.jsonString()), v)
      try expectEqual(v.jsonString(), #"{"a":1,"b":[true,"x",null]}"#)
    },
  ])
}
