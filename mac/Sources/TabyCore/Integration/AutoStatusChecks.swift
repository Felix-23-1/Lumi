// Prüfungen „Status automatisch“: Regeln und Abgleich mit einem Fake-Ziel (feste Uhr),
// dazu der Slack-Connector gegen das gestubbte HTTP (Scope-Hinweis, Feldformat).
import Foundation

/// Ziel-Attrappe: merkt sich den Status und jeden Schreibaufruf.
final class FakeStatus: StatusSetting, @unchecked Sendable {
  var text = ""
  var emoji = ""
  private(set) var writes: [(text: String, emoji: String, until: Date?)] = []
  var failRead: Error?

  func readStatus() async throws -> (text: String, emoji: String) {
    if let failRead { throw failRead }
    return (text, emoji)
  }

  func writeStatus(text: String, emoji: String, until: Date?) async throws {
    self.text = text
    self.emoji = emoji
    writes.append((text, emoji, until))
  }
}

/// Sammelt den letzten Hinweis je Konto.
final class HintBox: @unchecked Sendable {
  var values: [String: String] = [:]
}

enum AutoStatusChecks {
  @MainActor
  private static func controller(_ store: Store, _ clock: Clock, _ target: StatusSetting?,
                                 enabled: Bool = true) -> AutoStatusController {
    let targets: [(accountId: String, setting: StatusSetting)] = target.map { [(accountId: "acc", setting: $0)] } ?? []
    return AutoStatusController(repo: store.autoStatus, clock: clock, targets: { targets }, enabled: { enabled })
  }

  private static func at(_ iso: String) -> Date { LocalTime.parse(iso)! }

  static let cases: [CheckCase] = [
    CheckCase("Status: Fokus setzt „Im Fokus“ mit Kopfhörer bis Fokus-Ende") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "Im Fokus")
      try expectEqual(fake.emoji, ":headphones:")
      try expectEqual(fake.writes.last?.until, LocalTime.parse(f.endsAt), "Ablauf = Fokus-Ende")
      try expectEqual(try store.autoStatus.list().map(\.kind), ["focus"], "Lumi-Status wird gemerkt")
    },

    CheckCase("Status: Fokus-Ende stellt den Status wieder her und vergisst ihn") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      clock.set(at("2026-10-14T10:26"))
      await ctl.reconcile(focus: nil, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "", "Status gelöscht")
      try expect(try store.autoStatus.list().isEmpty, "Eintrag entfernt")
    },

    CheckCase("Status: Pause (Rest-Phase) setzt keinen Fokus-Status") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let r = try store.focus.start(taskId: nil, title: "Pause", phase: .rest, minutes: 5)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: r, meeting: nil, dayEnded: false)
      try expect(fake.writes.isEmpty, "Pause ist kein Fokus")
    },

    CheckCase("Status: laufender Termin „Im Termin“ bis Ende, ganztägig zählt nicht") {
      let clock = ControllableClock("2026-10-14T10:30")
      let store = try Store.inMemory(clock: clock)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      let allDay = CalendarEvent(id: "a", sourceId: "s", title: "Urlaubstag", start: "2026-10-14", end: nil, allDay: true)
      await ctl.reconcile(focus: nil, meeting: allDay, dayEnded: false)
      try expect(fake.writes.isEmpty, "ganztägig setzt nichts")
      let meeting = CalendarEvent(id: "m", sourceId: "s", title: "Review", start: "2026-10-14T10:00",
                                  end: "2026-10-14T11:00")
      await ctl.reconcile(focus: nil, meeting: meeting, dayEnded: false)
      try expectEqual(fake.text, "Im Termin")
      try expectEqual(fake.emoji, ":calendar:")
      try expectEqual(fake.writes.last?.until, at("2026-10-14T11:00"))
      clock.set(at("2026-10-14T11:00"))
      await ctl.reconcile(focus: nil, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "", "Termin-Ende stellt wieder her")
    },

    CheckCase("Status: Feierabend löscht den Lumi-Status und setzt danach nichts neu") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: true)
      try expectEqual(fake.text, "", "Feierabend löscht")
      let writes = fake.writes.count
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: true)
      try expectEqual(fake.writes.count, writes, "kein neuer Status nach Feierabend")
    },

    CheckCase("Status: ein Status des Nutzers wird nie überschrieben") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      fake.text = "Urlaub"
      fake.emoji = ":palm_tree:"
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      try expect(fake.writes.isEmpty, "eigener Status bleibt")
      clock.set(at("2026-10-14T10:26"))
      await ctl.reconcile(focus: nil, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "Urlaub", "Ende löscht fremden Status nicht")
    },

    CheckCase("Status: hat der Nutzer während Fokus selbst geändert, bleibt seiner stehen") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      fake.text = "Mittagspause"
      fake.emoji = ""
      clock.set(at("2026-10-14T10:26"))
      await ctl.reconcile(focus: nil, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "Mittagspause", "Lumi löscht nur den eigenen Status")
      try expect(try store.autoStatus.list().isEmpty, "Eintrag trotzdem aufgeräumt")
    },

    CheckCase("Status: ausgeschaltet setzt nichts") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let ctl = await controller(store, clock, fake, enabled: false)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      try expect(fake.writes.isEmpty, "aus = kein Schreibaufruf")
    },

    CheckCase("Status: Neustart räumt abgelaufenen Lumi-Status auf") {
      let clock = ControllableClock("2026-10-14T10:00")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let fake = FakeStatus()
      let before = await controller(store, clock, fake)
      await before.reconcile(focus: f, meeting: nil, dayEnded: false)
      // Absturz vor dem Ende; nach dem Neustart ist der Ablauf vorbei.
      clock.set(at("2026-10-14T12:00"))
      let after = await controller(store, clock, fake)
      await after.reconcile(focus: nil, meeting: nil, dayEnded: false)
      try expectEqual(fake.text, "", "Neustart löscht den Rest")
      try expect(try store.autoStatus.list().isEmpty, "Eintrag weg")
    },

    CheckCase("Status Slack: fehlendes Recht users.profile:write gibt den deutschen Hinweis") {
      let fake = SlackFake()
      fake.overrides["users.profile.get"] = .init(body: ["ok": true, "profile": ["status_text": "", "status_emoji": ""]])
      fake.overrides["users.profile.set"] = .init(body: ["ok": false, "error": "missing_scope", "needed": "users.profile:write"])
      let clock = ControllableClock("2026-10-14T10:00")
      let slack = SlackConnector(session: fake.session(), clock: clock)
      _ = try await slack.login(MessengerLogin(service: .slack, secret: "xoxp-test"), accountId: "acc")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let hints = HintBox()
      let ctl = await controller(store, clock, slack)
      await MainActor.run { ctl.onHint = { id, h in hints.values[id] = h } }
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      try expectEqual(hints.values["acc"], "Slack-App braucht das Recht users.profile:write")
      try expect(try store.autoStatus.list().isEmpty, "ohne Erfolg kein Eintrag")
    },

    CheckCase("Status Slack: Fokus schickt Text, Emoji und Ablauf als Profil") {
      let fake = SlackFake()
      fake.overrides["users.profile.get"] = .init(body: ["ok": true, "profile": ["status_text": "", "status_emoji": ""]])
      fake.overrides["users.profile.set"] = .init(body: ["ok": true, "profile": [:]])
      let clock = ControllableClock("2026-10-14T10:00")
      let slack = SlackConnector(session: fake.session(), clock: clock)
      _ = try await slack.login(MessengerLogin(service: .slack, secret: "xoxp-test"), accountId: "acc")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let ctl = await controller(store, clock, slack)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      let body = try JSONSerialization.jsonObject(with: try expectNotNil(fake.lastBody)) as? [String: Any]
      let profile = body?["profile"] as? [String: Any]
      try expectEqual(profile?["status_text"] as? String, "Im Fokus")
      try expectEqual(profile?["status_emoji"] as? String, ":headphones:")
      try expectEqual(profile?["status_expiration"] as? Int, Int(at(f.endsAt).timeIntervalSince1970))
      try expectEqual(fake.lastRequest?.httpMethod, "POST")
    },

    CheckCase("Status Slack: fremder Status wird nicht gesetzt") {
      let fake = SlackFake()
      fake.overrides["users.profile.get"] = .init(body: ["ok": true, "profile": ["status_text": "Urlaub", "status_emoji": ":palm_tree:"]])
      let clock = ControllableClock("2026-10-14T10:00")
      let slack = SlackConnector(session: fake.session(), clock: clock)
      _ = try await slack.login(MessengerLogin(service: .slack, secret: "xoxp-test"), accountId: "acc")
      let store = try Store.inMemory(clock: clock)
      let f = try store.focus.start(taskId: nil, title: "Test", phase: .work, minutes: 25)
      let ctl = await controller(store, clock, slack)
      await ctl.reconcile(focus: f, meeting: nil, dayEnded: false)
      try expectEqual(fake.count("users.profile.set"), 0, "Nutzer-Status bleibt")
    },
  ]
}
