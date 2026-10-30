// Prüfungen und Snapshots für Sources/TabyUI/Shell (gehört dem Shell-Agenten).
import AppKit
import Foundation
import SwiftUI
import TabyCore

/// Nur die Texte der Laufbandzeilen (ohne Symbol und Art).
private func tickerTexts(state: AppState?, today: String, now: Date) -> [String] {
  StatusRules.tickerLines(state: state, today: today, now: now).map(\.text)
}

/// Fester Zeitpunkt für Prüfungen der Anzeige (14:52 am 11.10.2026).
let fixedNow = LocalTime.parse("2026-10-11T14:52")!

/// Manuelle Uhr für Prüfungen.
@MainActor
final class ManualClock {
  var t: Double = 1000
  func advance(_ s: Double) { t += s }
}

enum ShellChecks {
  @MainActor static var suite: CheckSuite {
    CheckSuite("Shell", machineCases + sizeCases + moodCases + storeCases + miscCases + packageTwoCases
               + expansionCases + tabBarCases + liveCases + hotPathCases + MascotChecks.cases)
  }

  // MARK: - Leerlauf und Zwischenspeicher (Takt, Konferenzlink, ruhendes Maskottchen)

  /// Zählt die Uhrabfragen des Stores (je Takt eine, Lesen keine).
  @MainActor final class ReadCounter { var n = 0 }

  @MainActor static var hotPathCases: [CheckCase] {
    [
      CheckCase("Insel: Laufband, Beitreten und Bedienzeile werden je Takt einmal berechnet, Lesen nutzt den Stand") {
        try await MainActor.run {
          let fake = FakeServices(sample: true)
          let model = AppModel(services: fake)
          let clock = ManualClock()
          let reads = ReadCounter()
          let store = IslandStore(model: model, geometry: .preview, expansion: .memory(), now: { clock.t })
          store.wallClock = { reads.n += 1; return fixedNow }
          store.tick()
          let before = reads.n
          store.tick()
          try expectEqual(reads.n - before, 1, "ein Takt = eine Uhrabfrage")
          let lines = store.tickerLines, join = store.meetingJoin, peek = store.peekActions
          let size = store.targetSize
          _ = (store.tickerLines, store.meetingJoin, store.peekActions, store.targetSize)
          try expectEqual(reads.n - before, 1, "Lesen rechnet nicht neu")
          try expectEqual(store.tickerLines, lines)
          try expectEqual(store.meetingJoin, join)
          try expectEqual(store.peekActions, peek)
          try expectEqual(store.targetSize, size)
        }
      },
      CheckCase("Konferenzlink: gleicher Text, gleiches Ergebnis; fremder Host bleibt draußen") {
        let text = "Termin https://meet.google.com/abc-defg-hij."
        let a = StatusRules.meetingLink(in: text), b = StatusRules.meetingLink(in: text)
        try expect(a != nil, "Link gefunden")
        try expectEqual(a, b, "zweiter Aufruf liefert dasselbe")
        try expectEqual(a?.host, "meet.google.com")
        try expectEqual(StatusRules.meetingLink(in: "https://example.com/x"), nil, "fremder Host")
      },
      CheckCase("Maskottchen ruht: offene Insel ohne Bedienung 10 s; Mausbewegung oder Klick weckt es") {
        try await MainActor.run {
          let (store, _, _, clock) = makeStore()
          store.open(tab: nil)
          try expectEqual(store.mode, .open)
          try expect(!store.mascotStill, "frisch geöffnet: wach")
          clock.advance(9.5); store.tick()
          try expect(!store.mascotStill, "nach 9,5 s noch wach")
          clock.advance(1); store.tick()
          try expect(store.mascotStill, "nach 10,5 s ruht es")
          store.noteMouseMoved()
          try expect(!store.mascotStill, "Mausbewegung weckt es sofort")
          clock.advance(10.5); store.tick()
          try expect(store.mascotStill, "wieder ruhig nach 10 s ohne Bewegung")
          store.click()
          try expect(!store.mascotStill, "Klick weckt es")
          store.close()
          clock.advance(20); store.tick()
          try expect(!store.mascotStill, "geschlossen: nie ruhend im Sinne der offenen Insel")
        }
      },
    ]
  }

  // MARK: - Zeitabhängige Anzeigen (Timer, Musik, Termin mit Beitreten)

  @MainActor static var liveCases: [CheckCase] {
    [
      CheckCase("Timer im rechten Flügel: nach Fokus, vor Aufgaben; nächster Timer, abgelaufene fallen heraus") {
        let now = LocalTime.parse("2026-10-11T14:52")!
        var s = AppState()
        s.timers = [TabyTimer(id: "a", label: "Tee", endsAt: "2026-10-11T14:55"),
                    TabyTimer(id: "b", label: "Pause", endsAt: "2026-10-11T14:54:30"),
                    TabyTimer(id: "c", label: "alt", endsAt: "2026-10-11T14:50")]
        try expectEqual(StatusRules.indicator(state: s, agentPending: false, isThinking: false, now: now),
                        .timer(remaining: 150), "nächster Timer: 2:30 min")
        s.overview.overdueTasks = [TabyTask(id: "t", title: "x", createdAt: "2026-10-10")]
        try expectEqual(StatusRules.indicator(state: s, agentPending: false, isThinking: false, now: now),
                        .timer(remaining: 150), "Timer vor Aufgabenzähler")
        try expectEqual(StatusRules.indicator(state: s, agentPending: true, isThinking: false, now: now), .attention)
        try expectEqual(StatusRules.indicator(state: s, agentPending: false, isThinking: true, now: now), .thinking)
        s.focus = FocusSession(id: "f", title: "Fokus", startedAt: "2026-10-11T14:00", endsAt: "2026-10-11T15:00", minutes: 60)
        try expectEqual(StatusRules.indicator(state: s, agentPending: false, isThinking: false, now: now),
                        .focus(s.focus!), "Fokus vor Timer")
        var old = AppState()
        old.timers = [TabyTimer(id: "c", label: "alt", endsAt: "2026-10-11T14:50")]
        try expectEqual(StatusRules.indicator(state: old, agentPending: false, isThinking: false, now: now), .calm,
                        "abgelaufener Timer fällt heraus")
        try expectEqual(FocusClock.format(150), "02:30")
      },
      CheckCase("Laufband: Musik läuft (♪) oder pausiert (⏸), Knöpfe bleiben, Zeile höchstens 48 Zeichen") {
        let now = LocalTime.parse("2026-10-11T14:52")!
        var s = AppState()
        s.nowPlaying = NowPlaying(title: "Ruhige Musik", artist: "Beispielband", app: "Musik", playing: true)
        try expectEqual(tickerTexts(state: s, today: "2026-10-11", now: now), ["Ruhige Musik – Beispielband"])
        s.nowPlaying = NowPlaying(title: String(repeating: "T", count: 60), artist: "B", app: "Musik", playing: true)
        let long = tickerTexts(state: s, today: "2026-10-11", now: now)
        try expect(long.first?.count == 48 && long.first?.hasSuffix("…") == true, "gekürzt auf 48 mit …")
        s.nowPlaying = NowPlaying(title: "Ruhige Musik", artist: "", app: "Musik", playing: false)
        try expectEqual(tickerTexts(state: s, today: "2026-10-11", now: now), ["Ruhige Musik"])
        try expectEqual(StatusRules.peekActions(state: s, now: now)?.media, true, "pausiert: Knöpfe zum Weiterspielen")
        s.nowPlaying = nil
        try expectEqual(StatusRules.peekActions(state: s, now: now), nil, "ohne Musik und Termin keine Bedienzeile")
      },
      CheckCase("Laufband: SF-Symbole statt Emoji, Timer-Zeile, ausgeblendete Arten fallen weg") {
        let now = LocalTime.parse("2026-10-11T14:52")!
        var s = AppState()
        s.nowPlaying = NowPlaying(title: "Lied", artist: "", app: "Musik", playing: true)
        s.timers = [TabyTimer(id: "t", label: "Tee", endsAt: "2026-10-11T14:55")]
        s.messengerConversations = [MessengerConversation(id: "a|1", accountId: "a", title: "Mama", unread: 1,
                                                          lastText: "Hallo", lastAt: "2026-10-11T09:00")]
        let lines = StatusRules.tickerLines(state: s, today: "2026-10-11", now: now)
        try expectEqual(lines.map(\.symbol), ["music.note", "timer", "bubble.left.fill"])
        try expectEqual(lines.map(\.kind), [.music, .timer, .messages])
        try expectEqual(lines[1].text, "Tee · 03:00", "Timer mit Name und m:ss")
        try expectEqual(lines[1].kind, .timer)
        s.settings.hiddenTickerKinds = ["messages", "timer"]
        try expectEqual(tickerTexts(state: s, today: "2026-10-11", now: now), ["Lied"], "ausgeblendete Arten fehlen")
        s.settings.hiddenTickerKinds = []
        s.islandMessages = [IslandMessage(text: "⛅️ Köln 14 °C", until: "2026-10-11T23:59", modId: "w")]
        let mods = StatusRules.tickerLines(state: s, today: "2026-10-11", now: now).filter { $0.kind == .mods }
        try expectEqual(mods.map(\.symbol), [nil], "Mod-Texte ohne Symbol, Inhalt unverändert")
        try expectEqual(mods.map(\.text), ["⛅️ Köln 14 °C"])
      },
      CheckCase("Konferenzlink: nur https auf den vier Hosts (auch Subdomains), erster Treffer") {
        try expectEqual(StatusRules.meetingLink(in: "Einwahl: https://teams.microsoft.com/l/meetup-join/abc.")?.absoluteString,
                        "https://teams.microsoft.com/l/meetup-join/abc")
        try expectEqual(StatusRules.meetingLink(in: "http://zoom.us/j/1"), nil, "nur https")
        try expectEqual(StatusRules.meetingLink(in: "https://teams.microsoft.com.evil.example/x"), nil, "fremder Host")
        try expectEqual(StatusRules.meetingLink(in: "https://evilwebex.com/x"), nil, "kein Subdomain-Trick")
        try expectEqual(StatusRules.meetingLink(in: "https://acme.webex.com/meet/x")?.host, "acme.webex.com")
        try expectEqual(StatusRules.meetingLink(in: "https://example.com/a https://meet.google.com/abc-defg-hij")?.host,
                        "meet.google.com", "erster passender Link")
        try expectEqual(StatusRules.meetingLink(in: "https://us02web.zoom.us/j/9")?.host, "us02web.zoom.us")
        try expectEqual(StatusRules.meetingLink(in: "keine Adresse"), nil)
      },
      CheckCase("Beitreten: Termin mit Link läuft jetzt oder beginnt in 10 Min; Laufband und Bedienzeile") {
        let now = LocalTime.parse("2026-10-11T14:52")!
        func state(_ start: String, _ end: String, notes: String = "https://meet.google.com/abc-defg-hij") -> AppState {
          var s = AppState()
          s.overview.eventsToday = [CalendarEvent(id: "m", sourceId: "x", title: "Design-Review", start: start,
                                                  end: end, notes: notes)]
          return s
        }
        let soon = state("2026-10-11T14:57", "2026-10-11T15:30")
        try expectEqual(StatusRules.meetingJoin(state: soon, now: now)?.time, "14:57")
        try expect(StatusRules.meetingJoin(state: state("2026-10-11T14:00", "2026-10-11T15:00"), now: now) != nil,
                   "läuft gerade")
        try expect(StatusRules.meetingJoin(state: state("2026-10-11T15:07", "2026-10-11T15:30"), now: now) == nil,
                   "in 15 Min noch nicht")
        try expect(StatusRules.meetingJoin(state: state("2026-10-11T13:00", "2026-10-11T14:00"), now: now) == nil,
                   "vorbei")
        try expect(StatusRules.meetingJoin(state: state("2026-10-11T14:57", "2026-10-11T15:30", notes: "Agenda"),
                                           now: now) == nil, "ohne Link")
        try expectEqual(tickerTexts(state: soon, today: "2026-10-11", now: now).first,
                        "Design-Review · 14:57")
        try expectEqual(StatusRules.peekActions(state: soon, now: now),
                        PeekActions(media: false, join: URL(string: "https://meet.google.com/abc-defg-hij")))
      },
    ]
  }

  // MARK: - Zustandsautomat

  @MainActor static var machineCases: [CheckCase] {
    [
      CheckCase("Anheften: offen trotz Maus weg und Klick daneben; Lösen schließt wie sonst") {
        var m = IslandStateMachine()
        m.open(tab: nil, now: 0)
        m.setPinned(true, now: 0)
        m.mouseLeft(now: 1)
        m.tick(now: 10)
        try expectEqual(m.mode, .open, "angeheftet bleibt offen")
        m.setPinned(false, now: 11)
        m.mouseLeft(now: 11)
        m.tick(now: 20)
        try expectEqual(m.mode, .closed, "nach Lösen schließt es")
      },
      CheckCase("Laufende Arbeit hält die Insel offen, danach schließt sie") {
        var m = IslandStateMachine()
        m.open(tab: nil, now: 0)
        m.setBusy(true, now: 0)
        m.mouseLeft(now: 1)
        m.tick(now: 30)
        try expectEqual(m.mode, .open, "offen während Scan/Mitschnitt")
        m.setBusy(false, now: 31)
        m.mouseLeft(now: 31)
        m.tick(now: 40)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Esc löst auch die Anheftung") {
        var m = IslandStateMachine()
        m.open(tab: nil, now: 0)
        m.setPinned(true, now: 0)
        m.close()
        try expect(!m.pinned && m.mode == .closed, "Esc/Schließen hebt Pin auf")
      },
      CheckCase("isBusy erkennt Scan und Mitschnitt") {
        try expect(IslandCardRules.isBusy(nil) == false)
        try expect(IslandCardRules.isBusy(AppState(network: NetworkState(scanning: true))))
        try expect(IslandCardRules.isBusy(AppState(network: NetworkState(capturing: true))))
      },
      CheckCase("Begrüßung schließt nach ~2,6 s") {
        var m = IslandStateMachine()
        m.launch(now: 0)
        try expectEqual(m.mode, .greeting)
        m.tick(now: 2.5)
        try expectEqual(m.mode, .greeting)
        m.tick(now: 2.61)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Begrüßung mit Maus darüber endet als Peek") {
        var m = IslandStateMachine()
        m.launch(now: 0)
        m.mouseEntered(now: 1)
        try expectEqual(m.mode, .greeting)
        m.tick(now: 3)
        try expectEqual(m.mode, .peek)
      },
      CheckCase("Peek erst nach 150 ms Verweilen; kurzes Überfahren öffnet nichts") {
        var m = IslandStateMachine()
        m.mouseEntered(now: 0)
        m.tick(now: 0.1)
        try expectEqual(m.mode, .closed, "noch in der Verweilzeit")
        m.mouseLeft(now: 0.12)
        m.tick(now: 0.3)
        try expectEqual(m.mode, .closed, "Maus schon wieder weg")
        m.mouseEntered(now: 1)
        m.tick(now: 1.15)
        try expectEqual(m.mode, .peek, "nach 150 ms Peek")
      },
      CheckCase("Hover: zu → Peek, Verlassen → zu nach Gnadenfrist") {
        var m = IslandStateMachine()
        m.mouseEntered(now: 0)
        m.tick(now: 0.15)
        try expectEqual(m.mode, .peek)
        m.mouseLeft(now: 1)
        m.tick(now: 1.05)
        try expectEqual(m.mode, .peek, "noch in der Gnadenfrist")
        m.tick(now: 1.2)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Peek: kurz raus und wieder rein flackert nicht") {
        var m = IslandStateMachine()
        m.mouseEntered(now: 0)
        m.tick(now: 0.15)
        m.mouseLeft(now: 1)
        m.mouseEntered(now: 1.05)
        m.tick(now: 2)
        try expectEqual(m.mode, .peek)
      },
      CheckCase("Klick öffnet, Verlassen schließt nach 0,7 s") {
        var m = IslandStateMachine()
        m.mouseEntered(now: 0)
        m.click(now: 0.5)
        try expectEqual(m.mode, .open)
        m.mouseLeft(now: 2)
        m.tick(now: 2.69)
        try expectEqual(m.mode, .open)
        m.tick(now: 2.71)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Zurückkehrende Maus bricht das Zuklappen ab") {
        var m = IslandStateMachine()
        m.open(tab: .chat, now: 0)
        m.mouseEntered(now: 0.1)
        m.mouseLeft(now: 1)
        m.mouseEntered(now: 1.5)
        m.tick(now: 5)
        try expectEqual(m.mode, .open)
        try expectEqual(m.tab, .chat)
      },
      CheckCase("Kein Zuklappen, solange getippt wird") {
        var m = IslandStateMachine()
        m.open(tab: .chat, now: 0)
        m.mouseEntered(now: 0.1)
        m.setTyping(true, now: 0.2)
        m.mouseLeft(now: 1)
        m.tick(now: 10)
        try expectEqual(m.mode, .open)
        m.setTyping(false, now: 11)
        m.tick(now: 11.5)
        try expectEqual(m.mode, .open, "Frist läuft erst ab Ende des Tippens")
        m.tick(now: 11.71)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Tippen beginnt während der Frist → bleibt offen") {
        var m = IslandStateMachine()
        m.open(tab: .notes, now: 0)
        m.mouseLeft(now: 1)
        m.setTyping(true, now: 1.3)
        m.tick(now: 3)
        try expectEqual(m.mode, .open)
      },
      CheckCase("Agenten-Anfrage erzwingt Öffnen auf Agenten und hält offen") {
        var m = IslandStateMachine()
        m.selectTab(.notes)
        m.agentRequest(now: 0)
        try expectEqual(m.mode, .open)
        try expectEqual(m.tab, .agents)
        m.mouseLeft(now: 1)
        m.tick(now: 30)
        try expectEqual(m.mode, .open)
        m.agentRequestsCleared(now: 31)
        m.tick(now: 31.71)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Agenten-Anfrage unterbricht Flash und Begrüßung") {
        var m = IslandStateMachine()
        m.launch(now: 0)
        m.agentRequest(now: 0.5)
        try expectEqual(m.mode, .open)
        m.tick(now: 3)
        try expectEqual(m.mode, .open)
        var f = IslandStateMachine()
        f.showFlash(TabyNotification(title: "A", body: "B"), now: 0)
        f.agentRequest(now: 1)
        try expectEqual(f.mode, .open)
        try expect(f.flash == nil)
      },
      CheckCase("Aufgaben-Flash bleibt 15 s, mit Knöpfen; Erledigt/In 10 Min schließt sofort") {
        var m = IslandStateMachine()
        m.showFlash(TabyNotification(title: "Erinnerung", body: "Zahnarzt", taskId: "t1"), now: 0)
        try expectEqual(m.flashDuration, 15)
        m.tick(now: 14.9)
        try expectEqual(m.mode, .flash)
        m.tick(now: 15.01)
        try expectEqual(m.mode, .closed)
        m.showFlash(TabyNotification(title: "Erinnerung", body: "Zahnarzt", taskId: "t1"), now: 20)
        m.dismissFlash()
        try expectEqual(m.mode, .closed)
        try expect(m.flash == nil)
        var p = IslandStateMachine()
        p.showFlash(TabyNotification(title: "T", body: "B"), now: 0)
        try expectEqual(p.flashDuration, 6)
      },
      CheckCase("Aufgaben-Karte: „Ich arbeite daran“ startet den Fokus mit der Aufgabe und schließt die Karte") {
        let (store, fake, id) = try await MainActor.run { () -> (IslandStore, FakeServices, String) in
          let (store, _, fake, _) = makeStore()
          let id = fake.current.tasks.first(where: { !$0.done })!.id
          fake.emit(.flash(TabyNotification(title: "Erinnerung", body: "x", taskId: id)))
          try expectEqual(store.mode, .flash)
          store.workOnFlashTask()
          try expectEqual(store.mode, .closed)
          return (store, fake, id)
        }
        _ = store
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = await MainActor.run { fake.current.focus?.taskId }
        try expectEqual(started, Optional(id))
      },
      CheckCase("Flash poppt auf und verschwindet nach 6 s") {
        var m = IslandStateMachine()
        let n = TabyNotification(title: "Zahnarzt", body: "in 15 Minuten")
        m.showFlash(n, now: 0)
        try expectEqual(m.mode, .flash)
        try expectEqual(m.flash, n)
        m.tick(now: 5.9)
        try expectEqual(m.mode, .flash)
        m.tick(now: 6.01)
        try expectEqual(m.mode, .closed)
        try expect(m.flash == nil)
      },
      CheckCase("Flash bleibt, solange die Maus darauf liegt") {
        var m = IslandStateMachine()
        m.showFlash(TabyNotification(title: "T", body: "B"), now: 0)
        m.mouseEntered(now: 1)
        m.tick(now: 20)
        try expectEqual(m.mode, .flash)
        m.mouseLeft(now: 20)
        m.tick(now: 21.1)
        try expectEqual(m.mode, .flash)
        m.tick(now: 21.3)
        try expectEqual(m.mode, .closed)
      },
      CheckCase("Klick auf Flash öffnet das Board") {
        var m = IslandStateMachine()
        m.showFlash(TabyNotification(title: "T", body: "B"), now: 0)
        m.click(now: 1)
        try expectEqual(m.mode, .open)
        m.tick(now: 10)
        try expectEqual(m.mode, .open, "Flash-Frist darf das Board nicht schließen")
      },
      CheckCase("Flash bei offenem Board ändert den Zustand nicht") {
        var m = IslandStateMachine()
        m.open(tab: .tasks, now: 0)
        m.mouseEntered(now: 0)
        m.showFlash(TabyNotification(title: "T", body: "B"), now: 1)
        try expectEqual(m.mode, .open)
        try expectEqual(m.tab, .tasks)
      },
      CheckCase("Esc/close und toggle") {
        var m = IslandStateMachine()
        m.toggle(now: 0)
        try expectEqual(m.mode, .open)
        m.toggle(now: 1)
        try expectEqual(m.mode, .closed)
        m.agentRequest(now: 2)
        m.close()
        try expectEqual(m.mode, .closed, "Esc schließt auch bei offener Anfrage")
        try expect(m.deadline == nil)
      },
      CheckCase("Schnellerfassung: öffnen, Esc und Fertig schließen") {
        var m = IslandStateMachine()
        m.openCapture(now: 0)
        try expectEqual(m.mode, .capture)
        m.close()
        try expectEqual(m.mode, .closed, "Esc")
        m.openCapture(now: 1)
        m.close()
        try expectEqual(m.mode, .closed, "Fertig (onDone) ruft denselben Weg")
        var c = IslandStateMachine()
        c.openCapture(now: 0)
        c.click(now: 0.5)
        try expectEqual(c.mode, .capture, "Klick wechselt nicht auf das Board")
        c.toggle(now: 1)
        try expectEqual(c.mode, .closed, "Umschalten schließt die Erfassung")
      },
      CheckCase("Schnellerfassung: Mausverlassen schließt nicht, auch ohne Tippen") {
        var m = IslandStateMachine()
        m.openCapture(now: 0)
        m.mouseEntered(now: 0.1)
        m.mouseLeft(now: 1)
        m.tick(now: 60)
        try expectEqual(m.mode, .capture)
        m.setTyping(true, now: 61)
        m.setTyping(false, now: 62)
        m.tick(now: 120)
        try expectEqual(m.mode, .capture, "bleibt bis Fertig/Esc")
      },
      CheckCase("Schnellerfassung: Freigabe-Anfrage hat Vorrang") {
        var m = IslandStateMachine()
        m.openCapture(now: 0)
        m.agentRequest(now: 1)
        try expectEqual(m.mode, .open)
        try expectEqual(m.tab, .agents)
        m.agentRequestsCleared(now: 2)
        m.tick(now: 3)
        try expectEqual(m.mode, .closed, "Board schließt nach Ende der Anfrage")
        var a = IslandStateMachine()
        a.agentRequest(now: 0)
        a.openCapture(now: 1)
        try expectEqual(a.mode, .open, "Erfassung öffnet nicht über wartender Freigabe")
        var f = IslandStateMachine()
        f.showFlash(TabyNotification(title: "T", body: "B"), now: 0)
        f.openCapture(now: 0.5)
        try expectEqual(f.mode, .capture)
        try expect(f.flash == nil)
        f.showFlash(TabyNotification(title: "T", body: "B"), now: 1)
        try expectEqual(f.mode, .capture, "Flash stört die Erfassung nicht")
      },
      CheckCase("Öffnen behält den letzten Reiter") {
        var m = IslandStateMachine()
        m.open(tab: .notes, now: 0)
        m.close()
        m.click(now: 1)
        try expectEqual(m.tab, .notes)
      },
    ]
  }

  // MARK: - Größen

  @MainActor static var sizeCases: [CheckCase] {
    [
      CheckCase("Geschlossen = Notch + Flügel, Höhe = Notch") {
        let g = NotchGeometry(hasNotch: true, notchWidth: 209, notchHeight: 38, screenFrame: .zero)
        let s = IslandMetrics.size(mode: .closed, geometry: g, contentHeight: 0)
        try expectEqual(s, CGSize(width: 209 + 2 * IslandMetrics.closedWing, height: 38))
        let withTicker = IslandMetrics.size(mode: .closed, geometry: g, contentHeight: 0, ticker: true)
        try expectEqual(withTicker, CGSize(width: s.width, height: 38 + IslandMetrics.tickerHeight))
        let peekTicker = IslandMetrics.size(mode: .peek, geometry: g, contentHeight: 0, ticker: true)
        try expectEqual(peekTicker.height, 38 + IslandMetrics.peekExtraHeight + IslandMetrics.tickerHeight)
        let p = IslandMetrics.size(mode: .peek, geometry: g, contentHeight: 0)
        try expect(p.width > s.width && p.height > s.height, "Peek ist größer")
        let b = IslandMetrics.size(mode: .closed, geometry: g, contentHeight: 0, bumped: true)
        try expectEqual(b.width, s.width + IslandMetrics.bumpWidth)
      },
      CheckCase("Offen: Breite 640, Höhe folgt dem Inhalt (begrenzt)") {
        let g = NotchGeometry(hasNotch: true, notchWidth: 209, notchHeight: 38, screenFrame: .zero)
        let fixed = IslandMetrics.bandHeight(g) + IslandMetrics.cardTopGap + 2 * IslandMetrics.cardPadding
          + IslandMetrics.bottomInset
        let mid = IslandMetrics.size(mode: .open, geometry: g, contentHeight: 250)
        try expectEqual(mid, CGSize(width: 640, height: fixed + 250))
        let tiny = IslandMetrics.size(mode: .open, geometry: g, contentHeight: 10)
        try expectEqual(tiny.height, fixed + max(TabLayout.minContentHeight, IslandMetrics.sideColumnHeight),
                        "nie niedriger als Minimum bzw. Seitenspalte")
        let huge = IslandMetrics.size(mode: .open, geometry: g, contentHeight: 2000)
        try expectEqual(huge.height, fixed + TabLayout.maxContentHeight)
        try expect(huge.height + 20 < IslandWindowController.panelSize.height, "größte Insel passt ins Panel")
        try expect(640 + 2 * IslandMetrics.earRadius(.open) < IslandWindowController.panelSize.width)
      },
      CheckCase("Schnellerfassung: 520 breit, Höhe = Reiterleiste + Inhalt (90…420)") {
        let g = NotchGeometry(hasNotch: true, notchWidth: 209, notchHeight: 38, screenFrame: .zero)
        let band = IslandMetrics.bandHeight(g)
        let mid = IslandMetrics.size(mode: .capture, geometry: g, contentHeight: 0, captureHeight: 150)
        try expectEqual(mid, CGSize(width: 520, height: band + 150))
        let low = IslandMetrics.size(mode: .capture, geometry: g, contentHeight: 0, captureHeight: 20)
        try expectEqual(low.height, band + 90, "untere Grenze")
        let high = IslandMetrics.size(mode: .capture, geometry: g, contentHeight: 0, captureHeight: 900)
        try expectEqual(high.height, band + 420, "obere Grenze")
        try expect(high.height + 20 < IslandWindowController.panelSize.height, "passt ins Panel")
        try expect(520 < IslandWindowController.panelSize.width)
        let ng = NotchGeometry.previewNoNotch
        try expectEqual(IslandMetrics.size(mode: .capture, geometry: ng, contentHeight: 0, captureHeight: 90).height,
                        IslandMetrics.bandHeight(ng) + 90)
        try expectEqual(IslandMetrics.earRadius(.capture), 14)
        try expectEqual(IslandMetrics.bottomRadius(.capture), IslandMetrics.bottomRadius(.open))
      },
      CheckCase("Inhaltsspalte + Seitenspalte füllen die Karte") {
        try expect(IslandMetrics.sideColumnWidth >= 100, "Seitenspalte \(IslandMetrics.sideColumnWidth)")
        try expectEqual(IslandMetrics.sideColumnWidth + 14 + TabLayout.contentWidth + 2 * IslandMetrics.cardPadding
                          + 2 * IslandMetrics.cardInset, IslandMetrics.openWidth)
      },
      CheckCase("Flash und Begrüßung: unter der Notch, schmaler als offen") {
        let g = NotchGeometry.preview
        let f = IslandMetrics.size(mode: .flash, geometry: g, contentHeight: 0)
        let gr = IslandMetrics.size(mode: .greeting, geometry: g, contentHeight: 0)
        try expect(f.height > g.notchHeight + 60 && f.width < IslandMetrics.openWidth)
        try expect(gr.height > g.notchHeight + 60 && gr.width < IslandMetrics.openWidth)
      },
      CheckCase("Notch aus Hilfsflächen gemessen") {
        let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 38,
                              auxiliaryLeftWidth: 651.5, auxiliaryRightWidth: 651.5, menuBarHeight: 38)
        try expect(g.hasNotch)
        try expectEqual(g.notchWidth, 209)
        try expectEqual(g.notchHeight, 38)
      },
      CheckCase("Unplausible Hilfsflächen → Ersatzbreite") {
        let g = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 38,
                              auxiliaryLeftWidth: nil, auxiliaryRightWidth: 10, menuBarHeight: 38)
        try expectEqual(g.notchWidth, NotchGeometry.fallbackNotchWidth)
      },
      CheckCase("Ohne Notch: virtuelle Notch 180 × Menüleiste") {
        let g = NotchGeometry(screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                              auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 25)
        try expect(!g.hasNotch)
        try expectEqual(g.notchWidth, 180)
        try expectEqual(g.notchHeight, 25)
        let hidden = NotchGeometry(screenFrame: .zero, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                   menuBarHeight: 0)
        try expectEqual(hidden.notchHeight, NotchGeometry.fallbackHeight, "ausgeblendete Menüleiste")
        try expectEqual(IslandMetrics.hoverInset(mode: .closed, geometry: g), 0, "keine Klicks unter der Menüleiste schlucken")
        try expect(IslandMetrics.hoverInset(mode: .open, geometry: g) > 0)
      },
      CheckCase("Bildschirmwahl: Notch, sonst Hauptbildschirm") {
        try expectEqual(ScreenChooser.index(in: [.init(hasNotch: false, isMain: true), .init(hasNotch: true, isMain: false)]), 1)
        try expectEqual(ScreenChooser.index(in: [.init(hasNotch: false, isMain: false), .init(hasNotch: false, isMain: true)]), 1)
        try expectEqual(ScreenChooser.index(in: [.init(hasNotch: false, isMain: false)]), 0)
        try expect(ScreenChooser.index(in: []) == nil)
      },
      CheckCase("Radien: 14 zu → 24 offen, Ohren überall") {
        try expectEqual(IslandMetrics.bottomRadius(.closed), 14)
        try expectEqual(IslandMetrics.bottomRadius(.open), 24)
        for m in IslandMode.allCases { try expect(IslandMetrics.earRadius(m) > 0) }
      },
      CheckCase("IslandShape: Ohren ragen über den Körper, unten rund") {
        let s = IslandShape(width: 300, height: 40, bottomRadius: 14, ear: 8)
        let p = s.path(in: CGRect(x: 0, y: 0, width: 316, height: 40))
        let b = p.boundingRect
        try expectEqual(b.width, 316)
        try expectEqual(b.height, 40)
        try expect(p.contains(CGPoint(x: 158, y: 20)), "Mitte gefüllt")
        try expect(!p.contains(CGPoint(x: 9, y: 39)), "untere Ecke ausgespart")
        try expect(!p.contains(CGPoint(x: 2, y: 7)), "unter dem Ohr frei")
        try expect(p.contains(CGPoint(x: 6, y: 0.5)), "Ohr an der Kante gefüllt")
      },
    ]
  }

  // MARK: - Stimmung

  @MainActor static var moodCases: [CheckCase] {
    func d(agent: Bool = false, thinking: Bool = false, reaction: UIReaction? = nil, age: Double? = nil,
           flash: Bool = false, idle: Double = 0, open: Bool = false) -> MascotMood {
      MoodRules.derive(agentPending: agent, isThinking: thinking, reaction: reaction, reactionAge: age, flashActive: flash,
                       idleFor: idle, islandOpen: open)
    }
    return [
      CheckCase("Stimmung: Reihenfolge der Ursachen") {
        try expectEqual(d(), .idle)
        try expectEqual(d(agent: true, thinking: true, reaction: .celebrate, age: 0), .alert)
        try expectEqual(d(thinking: true, reaction: .celebrate, age: 0), .thinking)
        try expectEqual(d(reaction: .taskCompleted, age: 1, flash: true), .happy)
        try expectEqual(d(flash: true), .alert)
      },
      CheckCase("Stimmung: Reaktionen und ihr Ablauf") {
        try expectEqual(d(reaction: .celebrate, age: 0.1), .happy)
        try expectEqual(d(reaction: .itemAdded, age: 0.1), .love)
        try expectEqual(d(reaction: .failed("x"), age: 2.5), .error)
        try expectEqual(d(reaction: .failed("x"), age: 2.7), .idle)
        try expectEqual(d(reaction: .itemDeleted, age: 0.1), .idle)
      },
      CheckCase("Stimmung: lange Ruhe macht schläfrig (nur zu)") {
        try expectEqual(d(idle: 301), .sleepy)
        try expectEqual(d(idle: 301, open: true), .idle)
        try expectEqual(d(idle: 100), .idle)
      },
      CheckCase("Reiterleiste: auch mit allen optionalen Reitern passt alles neben die Notch") {
        let n = TabyTab.allCases.count
        for notch in [CGFloat(160), 185, 210] {
          let w = IslandMetrics.tabButtonWidth(count: n, notchWidth: notch)
          let used = 44 + notch + 12 + CGFloat(n) * w + 4 * CGFloat(n - 2)
          try expect(used <= IslandMetrics.openWidth, "Notch \(notch): \(used) > \(IslandMetrics.openWidth)")
          try expect(w >= 24, "Knöpfe noch klickbar: \(w)")
        }
        try expectEqual(IslandMetrics.tabButtonWidth(count: 8, notchWidth: 185), 34)
      },
      CheckCase("Reiterleiste: jeder Reiter hat genau ein Symbol") {
        let shown = OpenBoardTabs.left + OpenBoardTabs.right
        try expectEqual(Set(shown), Set(TabyTab.allCases), "fehlt: \(Set(TabyTab.allCases).subtracting(shown))")
        try expectEqual(shown.count, TabyTab.allCases.count, "doppelt")
      },
      CheckCase("Reiter-Reihenfolge: leer = Standard, Teilwünsche vorne, Rest in Standardreihenfolge") {
        let standard = OpenBoardTabs.left + OpenBoardTabs.right
        try expectEqual(OpenBoardTabs.ordered([]), standard)
        let r = OpenBoardTabs.ordered(["notion", "today"])
        try expectEqual(Array(r.prefix(2)), [.notion, .today])
        try expectEqual(Array(r.dropFirst(2)), standard.filter { $0 != .notion && $0 != .today })
      },
      CheckCase("Reiter-Reihenfolge: Standard nach Gruppen, Einstellungen rechts außen") {
        try expectEqual(OpenBoardTabs.left + OpenBoardTabs.right,
                        [.today, .chat, .tasks, .calendar, .notes, .mail, .messages,
                         .music, .agents, .mods, .notion, .network, .settings])
        try expectEqual(OpenBoardTabs.right.last, .settings)
      },
      CheckCase("Reiterleiste: Name neben dem aktiven Reiter nur, wenn die Breite passt") {
        for notch in [CGFloat(160), 185, 210] {
          // Alle 13 Reiter: kein Platz für einen Namen, Hilfetext wie bisher.
          try expect(!IslandMetrics.activeLabelFits("Einstellungen", count: TabyTab.allCases.count, notchWidth: notch),
                     "13 Reiter, Notch \(notch)")
          // Wenige Reiter (z. B. ausgeblendete): Name passt.
          try expect(IslandMetrics.activeLabelFits("Einstellungen", count: 6, notchWidth: notch), "6 Reiter, Notch \(notch)")
        }
      },
      CheckCase("Reiter-Reihenfolge: unbekannte und doppelte Namen ignoriert, jeder Reiter genau einmal") {
        let r = OpenBoardTabs.ordered(["bogus", "tasks", "tasks", "", "notion"])
        try expectEqual(Array(r.prefix(2)), [.tasks, .notion])
        try expectEqual(r.count, TabyTab.allCases.count, "Anzahl")
        try expectEqual(Set(r), Set(TabyTab.allCases), "Menge")
        let all = OpenBoardTabs.ordered(TabyTab.allCases.reversed().map(\.rawValue))
        try expectEqual(all, Array(TabyTab.allCases.reversed()))
      },
      CheckCase("Reiter-Reihenfolge: Teilung links/rechts, Breite bleibt in der offenen Insel") {
        let all = OpenBoardTabs.ordered(["notion"])
        for notch in [CGFloat(160), 185, 210] {
          for n in 1...all.count {
            let (l, rt) = OpenBoardTabs.split(Array(all.prefix(n)))
            try expectEqual(l.count, (n + 1) / 2, "links bei \(n)")
            try expectEqual(l + rt, Array(all.prefix(n)), "Reihenfolge bei \(n)")
            let w = IslandMetrics.tabButtonWidth(count: n, notchWidth: notch)
            let used = 44 + notch + 12 + CGFloat(n) * w + 4 * CGFloat(max(0, n - 2))
            try expect(used <= IslandMetrics.openWidth, "Notch \(notch), \(n) Reiter: \(used)")
          }
        }
      },
      CheckCase("Maskottchen-Klicks: 1× springen, 2× lachen, 3× Überraschung, Pause setzt zurück") {
        var combo = MascotCombo()
        try expectEqual(combo.tap(at: 0), .jump)
        try expectEqual(combo.tap(at: 0.6), .laugh)
        let third = combo.tap(at: 1.1, random: { _ in 0 })
        try expectEqual(third, MascotAction.surprises[0])
        try expectEqual(combo.tap(at: 1.5), .jump, "nach der Überraschung beginnt die Serie neu")
        try expectEqual(combo.tap(at: 5), .jump, "zu lange Pause")
        for i in 0..<MascotAction.surprises.count {
          var c = MascotCombo()
          _ = c.tap(at: 0); _ = c.tap(at: 1)
          try expectEqual(c.tap(at: 2, random: { _ in i }), MascotAction.surprises[i])
        }
      },
      CheckCase("Maskottchen: Streicheln zeigt Gesicht ohne Herzen, Verliebt-Einlage funkelt") {
        let petting = MascotScene.make(mood: .idle, waving: false, t: 1, now: 1, look: nil, play: nil,
                                       context: MascotContext(hoverStart: 0))
        try expectEqual(petting.face, .petting)
        try expect(petting.sparkle == nil, "Streicheln: kein Funkeln")
        let love = MascotScene.make(mood: .idle, waving: false, t: 1, now: 1, look: nil, play: (.love, 0.5),
                                    context: MascotContext())
        try expectEqual(love.sparkle, 0.5)
        let jump = MascotScene.make(mood: .idle, waving: false, t: 1, now: 1, look: nil, play: (.jump, 0.5),
                                    context: MascotContext())
        try expect(jump.sparkle == nil, "nur Verliebt funkelt")
      },
      CheckCase("Maskottchen-Hover: Start nach 0,3 s, nie dieselbe Reaktion zweimal, höchstens alle 2,5 s") {
        let f = CGRect(x: 100, y: 500, width: 600, height: 400)
        try expect(MascotGaze.look(mouse: CGPoint(x: 150, y: 850), in: f).x < -0.9, "links oben: Blick nach links")
        try expect(MascotGaze.look(mouse: CGPoint(x: 650, y: 550), in: f).x > 0.9, "rechts unten: Blick nach rechts")
        try expect(MascotGaze.look(mouse: CGPoint(x: 400, y: 550), in: f).y > 0.5, "unten: Blick nach unten")
        try expectEqual(MascotHoverPicker.startDelay, 0.3)
        try expectEqual(Set(MascotHoverPicker.pool), Set([.wave, .jump, .laugh, .spin, .peek, .wiggle, .nod]))
        for pick in [{ (_: Int) -> Int in 0 }, { (n: Int) -> Int in n - 1 }, { (n: Int) -> Int in n / 2 }] {
          var p = MascotHoverPicker(random: pick)
          var last: MascotAction?
          var t = MascotHoverPicker.startDelay
          for _ in 0..<60 {
            let a = try expectNotNil(p.pick(at: t), "Reaktion fehlt bei \(t)")
            try expect(a != last, "zweimal hintereinander: \(a)")
            last = a
            t += 2.5
          }
        }
        var q = MascotHoverPicker(random: { $0 - 1 })
        try expect(q.pick(at: 0.3) != nil, "erste Reaktion")
        try expect(q.pick(at: 2.7) == nil, "vor 2,5 s Abstand keine zweite")
        try expect(q.pick(at: 2.8) != nil, "nach 2,5 s wieder")
        // Zufall ist injizierbar: jede Auswahl aus dem Pool ist erreichbar.
        var seen = Set<MascotAction>()
        for i in 0..<MascotHoverPicker.pool.count {
          var r = MascotHoverPicker(random: { _ in i })
          if let a = r.pick(at: 0) { seen.insert(a) }
        }
        try expectEqual(seen.count, MascotHoverPicker.pool.count, "alle Reaktionen erreichbar")
      },
      CheckCase("Maskottchen-Reaktionen: neue Einlagen bewegen Kopf, Blinzeln und Blick") {
        let peek = stride(from: 0.0, to: 1.4, by: 0.01).map { MascotPose.at(10, mood: .idle, waving: false, play: (.peek, $0)) }
        try expect(peek.contains { $0.rotation > 5 }, "Peek lehnt sich zur Maus")
        try expect(peek.contains { $0.blink < 0.3 }, "Peek blinzelt")
        let wiggle = stride(from: 0.0, to: 1.2, by: 0.02).map { MascotPose.at(10, mood: .idle, waving: false, play: (.wiggle, $0)) }
        try expect(wiggle.contains { abs($0.dx) > 2 } && wiggle.contains { $0.sx > 1.02 }, "Wackeln seitlich mit Stauchen")
        let nod = stride(from: 0.0, to: 1.1, by: 0.02).map { MascotPose.at(10, mood: .idle, waving: false, play: (.nod, $0)) }
        try expect(nod.contains { $0.dy > 2 } && nod.contains { $0.lookY > 0.6 }, "Nicken: runter und Blick")
        for a in [MascotAction.peek, .wiggle, .nod] { try expect(a.face(at: 0.5) == nil, "\(a): Gesicht bleibt") }
      },
      CheckCase("Maskottchen-Mikro: Plan alle 4–8 s, Bewegung in dem Fenster, nichts bei zu oder ruhend") {
        for pick in [{ (_: Int) -> Int in 0 }, { (n: Int) -> Int in n - 1 }] {
          var l = MascotLiveliness()
          l.tick(now: 0, active: true, random: pick)
          let due = try expectNotNil(l.nextAt, "geplant")
          try expect(due >= 4 && due <= 8, "Abstand \(due)")
          var first: Double?
          for i in 0...180 {
            let t = Double(i) * 0.05
            l.tick(now: t, active: true, random: pick)
            if first == nil, l.show(at: t) != nil { first = t }
          }
          let at = try expectNotNil(first, "keine Bewegung")
          try expect(at >= 4 && at <= 8, "Bewegung bei \(at)")
        }
        // Zu oder ruhend: nichts geplant, nichts sichtbar, auch nicht nach langer Zeit.
        var idle = MascotLiveliness()
        for t in stride(from: 0.0, through: 20, by: 0.5) {
          idle.tick(now: t, active: false, random: { _ in 0 })
          try expect(idle.show(at: t) == nil && idle.nextAt == nil, "inaktiv bei \(t)")
        }
        try expectEqual(MascotLiveliness.gap({ _ in 4000 }), 8)
        try expectEqual(MascotLiveliness.gap({ _ in 0 }), 4)
        // Lidschlag-Mikro: zweimal blinzeln, Blick geht zur Seite.
        let blink = stride(from: 0.0, to: 1.2, by: 0.01).map {
          MascotPose.at(10, mood: .idle, waving: false, micro: MascotMicroShow(move: .doubleBlink, elapsed: $0)).blink
        }
        try expect(blink.filter { $0 < 0.3 }.count >= 2 * 3, "zweimal blinzelt")
        let glance = MascotPose.at(10, mood: .idle, waving: false, micro: MascotMicroShow(move: .glanceLeft, elapsed: 0.6))
        try expect(glance.lookX < -0.8, "schaut links: \(glance.lookX)")
      },
      CheckCase("Maskottchen-Einlagen: Sprung hebt ab, Umfallen kippt und steht wieder auf, Drehung ganz herum") {
        let base = MascotPose.at(10, mood: .idle, waving: false)
        let jump = MascotPose.at(10, mood: .idle, waving: false, play: (.jump, 0.34))
        try expect(jump.dy < base.dy - 10, "Sprung: \(jump.dy)")
        let lying = MascotPose.at(10, mood: .idle, waving: false, play: (.fall, 1.0))
        try expect(lying.rotation > 80, "liegt: \(lying.rotation)")
        try expectEqual(MascotAction.fall.face(at: 1.0), .error)
        let up = MascotPose.at(10, mood: .idle, waving: false, play: (.fall, MascotAction.fall.duration - 0.01))
        try expect(abs(up.rotation) < 5, "steht wieder: \(up.rotation)")
        let spun = MascotPose.at(10, mood: .idle, waving: false, play: (.spin, 0.79))
        try expect(spun.rotation > 340, "Drehung: \(spun.rotation)")
        let play = MascotPlay(action: .laugh, startedAt: 100)
        try expect(play.elapsed(at: 100.5) == 0.5 && play.elapsed(at: 102) == nil, "Dauer begrenzt")
      },
      CheckCase("Maskottchen-Ärmchen: winkt, jubelt, hängt schlapp") {
        let wave = stride(from: 0.0, to: 2.0, by: 0.05).map { MascotPose.at($0, mood: .idle, waving: true).rightArm }
        try expect(wave.allSatisfy { $0 > 90 }, "Begrüßung: Ärmchen oben")
        try expect((wave.max() ?? 0) - (wave.min() ?? 0) > 20, "Begrüßung: Ärmchen wackelt")
        let happy = MascotPose.at(0.3, mood: .happy, waving: false)
        try expect(happy.leftArm > 90 && happy.rightArm > 90, "Freude: beide Ärmchen hoch")
        let err = MascotPose.at(0.3, mood: .error, waving: false)
        try expect(err.leftArm < 0 && err.rightArm < 0, "Fehler: Ärmchen hängen")
        let idle = stride(from: 0.0, to: 7.0, by: 0.05).map { MascotPose.at($0, mood: .idle, waving: false).rightArm }
        try expect(idle.contains { $0 > 60 } && idle.contains { $0 == 0 }, "Ruhe: gelegentliches Winken, sonst locker")
      },
      CheckCase("Maskottchen-Haltung: blinzelt, hüpft, schaut, folgt der Maus") {
        let blinks = stride(from: 0.0, to: 3.8, by: 0.01).map { MascotPose.at($0, mood: .idle, waving: false).blink }
        try expect(blinks.contains { $0 < 0.3 }, "blinzelt einmal pro Zyklus")
        try expect(blinks.filter { $0 < 1 }.count < 30, "Lidschlag ist kurz")
        let hop = MascotPose.at(0.45 * 0.95, mood: .happy, waving: false)
        try expect(hop.dy < -8, "hüpft hoch (\(hop.dy))")
        let squash = MascotPose.at(0.15 * 0.95, mood: .happy, waving: false)
        try expect(squash.sx > 1 && squash.sy < 1, "staucht beim Absprung")
        let glances = stride(from: 0.0, to: 6.0, by: 0.05).map { MascotPose.at($0, mood: .idle, waving: false).lookX }
        try expect(glances.contains { $0 > 0.5 } && glances.contains { $0 < -0.5 }, "schaut ab und zu zur Seite")
        let greet = stride(from: 0.0, to: 1.6, by: 0.02).map { MascotPose.at($0, mood: .idle, waving: true) }
        try expect(greet.contains { abs($0.rotation) > 6 }, "Begrüßung: wippt")
        try expect(greet.contains { $0.wink > 0.8 }, "Begrüßung: zwinkert")
        let mouse = MascotPose.at(1, mood: .idle, waving: false, look: CGPoint(x: 3, y: -0.4))
        try expectEqual(mouse.lookX, 1, "Blick folgt der Maus (begrenzt)")
        let busy = MascotPose.at(1, mood: .alert, waving: false, look: CGPoint(x: 1, y: 0))
        try expectEqual(busy.lookX, 0, "bei Alarm nicht abgelenkt")
        try expectEqual(MascotPose.at(1.23, mood: .error, waving: false), MascotPose.at(1.23, mood: .error, waving: false))
      },
    ]
  }

  // MARK: - Store mit AppModel/FakeServices

  @MainActor static func makeStore(sample: Bool = true) -> (IslandStore, AppModel, FakeServices, ManualClock) {
    let fake = FakeServices(sample: sample)
    let model = AppModel(services: fake)
    let clock = ManualClock()
    let store = IslandStore(model: model, geometry: .preview, expansion: .memory(), now: { clock.t })
    return (store, model, fake, clock)
  }

  @MainActor static var storeCases: [CheckCase] {
    [
      CheckCase("Store: Mikro-Bewegungen nur offen oder Peek, nie ruhend oder zu") {
        try await MainActor.run {
          let (store, _, _, clock) = makeStore()
          store.mascotRandom = { _ in 0 }
          store.open(tab: nil)
          store.tick()
          clock.advance(4); store.tick()
          try expectEqual(store.mascotContext(at: clock.t).micro?.move, .glanceLeft, "offen: erste Bewegung nach 4 s")
          clock.advance(1.3); store.tick()
          try expect(store.mascotContext(at: clock.t).micro == nil, "Bewegung ist nach 1,2 s vorbei")
          clock.advance(6.5); store.tick()
          try expect(store.mascotStill, "nach langer Ruhe ruht die Figur")
          try expect(store.mascotContext(at: clock.t).micro == nil, "ruhend: keine Bewegung")
          store.close()
          store.tick()
          clock.advance(5); store.tick()
          try expect(store.mascotContext(at: clock.t).micro == nil, "zu: keine Bewegung")
        }
      },
      CheckCase("Store: Agenten-Anfrage öffnet Agenten, Maskottchen alarmiert") {
        try await MainActor.run {
          let (store, model, fake, clock) = makeStore()
          store.mouseLeft()
          fake.emit(.agentRequest(AgentPermissionRequest(id: "r1", toolName: "Bash", toolInput: .string("ls"))))
          try expectEqual(model.agentRequests.count, 1)
          try expectEqual(store.mode, .open)
          try expectEqual(store.tab, .agents)
          try expectEqual(store.mood, .alert)
          clock.advance(5); store.tick()
          try expectEqual(store.mode, .open, "bleibt offen, solange die Anfrage wartet")
          fake.emit(.agentRequestClosed(id: "r1"))
          clock.advance(0.8); store.tick()
          try expectEqual(store.mode, .closed)
          try expectEqual(store.mood, .idle)
        }
      },
      CheckCase("Store: Flash-Ereignis poppt auf und schließt") {
        try await MainActor.run {
          let (store, _, fake, clock) = makeStore()
          fake.emit(.flash(TabyNotification(title: "Erinnerung", body: "Zahnarzt in 15 Minuten")))
          try expectEqual(store.mode, .flash)
          try expectEqual(store.mood, .alert)
          clock.advance(5.9); store.tick()
          try expectEqual(store.mode, .flash, "6 s sichtbar")
          clock.advance(0.2); store.tick()
          try expectEqual(store.mode, .closed)
        }
      },
      CheckCase("Statuszeile Aufgaben zählt wie Heute (überfällig + heute); ⌘1…⌘9 wählen sichtbare Reiter") {
        var st = AppState()
        let a = TabyTask(id: "a", title: "a", createdAt: ""), b = TabyTask(id: "b", title: "b", createdAt: "")
        st.overview.todayTasks = [a]
        st.overview.overdueTasks = [b]
        st.tasks = [a, b, TabyTask(id: "c", title: "c", createdAt: "")]
        try expectEqual(StatusRules.lines(tab: .tasks, state: st, agentRequests: 0, isThinking: false),
                        ["heute 2 · 3 offen", "1 überfällig"])
        try await MainActor.run {
          let (store, _, _, _) = makeStore()
          store.open(tab: .today)
          try expectEqual(store.selectTab(number: 2), true)
          try expectEqual(store.tab, .chat, "zweiter sichtbarer Reiter")
          try expectEqual(store.selectTab(number: 99), false, "außerhalb der Leiste")
          store.close()
          try expectEqual(store.selectTab(number: 1), false, "nur bei offener Insel")
        }
      },
      CheckCase("Store: Reaktion → Stimmung für 2,6 s, Insel stupst an") {
        try await MainActor.run {
          let (store, model, _, clock) = makeStore()
          model.react(.taskCompleted)
          try expectEqual(store.mood, .happy)
          try expect(store.bumped, "geschlossene Insel stupst an")
          let bumpedWidth = store.targetSize.width
          clock.advance(0.5); store.tick()
          try expect(!store.bumped && store.targetSize.width < bumpedWidth)
          clock.advance(2.2); store.tick()
          try expectEqual(store.mood, .idle)
          model.react(.itemAdded)
          try expectEqual(store.mood, .love)
          model.react(.failed("Netz"))
          try expectEqual(store.mood, .error)
        }
      },
      CheckCase("Store: Tippen hält offen, Inhaltshöhe federt mit") {
        try await MainActor.run {
          let (store, _, _, clock) = makeStore()
          store.open(tab: .chat)
          store.setContentHeight(200)
          let h1 = store.targetSize.height
          store.setContentHeight(260)
          try expectEqual(store.targetSize.height, h1 + 60)
          store.setTyping(true)
          store.mouseLeft()
          clock.advance(3); store.tick()
          try expectEqual(store.mode, .open)
          store.setTyping(false)
          clock.advance(0.8); store.tick()
          try expectEqual(store.mode, .closed)
        }
      },
      CheckCase("Store: Schnellerfassung wächst mit gemessener Höhe") {
        try await MainActor.run {
          let (store, _, _, _) = makeStore()
          store.openCapture()
          try expectEqual(store.mode, .capture)
          store.setCaptureHeight(140)
          try expectEqual(store.targetSize.height, IslandMetrics.bandHeight(store.geometry) + 140)
          store.setCaptureHeight(900)
          try expectEqual(store.targetSize.height, IslandMetrics.bandHeight(store.geometry) + 420)
          store.close()
          try expectEqual(store.mode, .closed)
        }
      },
      CheckCase("Store: Moduswechsel meldet sich beim Controller") {
        try await MainActor.run {
          let (store, _, _, _) = makeStore()
          var seen: [IslandMode] = []
          store.onModeChange = { _, new in seen.append(new) }
          store.mouseEntered()
          store.skipPeekDwellForPreview()
          store.click()
          store.close()
          try expectEqual(seen, [.peek, .open, .closed])
        }
      },
    ]
  }

  // MARK: - Reiterleiste mit „Mehr“

  @MainActor static var tabBarCases: [CheckCase] {
    [
      CheckCase("Reiterleiste: alle Reiter sichtbar, ausgeblendete nur unter „Mehr“, Einstellungen immer da") {
        let all = TabyTab.allCases
        let (p0, m0) = OpenBoardTabs.bar(all, hidden: [])
        try expectEqual(p0, all, "ohne Auswahl wie früher: alles in der Leiste")
        try expect(m0.isEmpty, "kein „Mehr“")
        let (p1, m1) = OpenBoardTabs.bar(all, hidden: ["mail", "mods", "settings"])
        try expectEqual(m1, [.mail, .mods])
        try expect(p1.contains(.settings), "Einstellungen lassen sich nicht ausblenden")
        try expectEqual(Set(p1 + m1), Set(all), "jeder Reiter genau einmal")
      },
      CheckCase("Reiterleiste: „Mehr“ hervorgehoben, sobald der gezeigte Reiter ausgeblendet ist") {
        try expect(OpenBoardTabs.moreActive(current: .mail, hidden: ["mail"], dayStartPrompt: false), "Mail hinter Mehr")
        try expect(!OpenBoardTabs.moreActive(current: .mail, hidden: [], dayStartPrompt: false), "Mail in der Leiste")
        try expect(!OpenBoardTabs.moreActive(current: .mail, hidden: ["mail"], dayStartPrompt: true), "Tagesstart hat Vorrang")
      },
      CheckCase("Reiterleiste: alle Symbole einheitlich als Kontur und vorhanden") {
        for t in TabyTab.allCases {
          let name = TabSymbol.name(t)
          try expect(!name.contains(".fill"), "\(t): gefüllt \(name)")
          try expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(t): Symbol fehlt \(name)")
        }
      },
      CheckCase("Statuszeilen: Zahlen kommen aus denselben Feldern wie der Reiter") {
        try await MainActor.run {
          let s = FakeServices(sample: true).current
          let notes = s.notes.count
          try expectEqual(StatusRules.lines(tab: .notes, state: s, agentRequests: 0, isThinking: false),
                          ["\(notes) \(notes == 1 ? "Notiz" : "Notizen")"])
          let open = s.tasks.filter { !$0.done }.count
          try expectEqual(StatusRules.lines(tab: .tasks, state: s, agentRequests: 0, isThinking: false).first,
                          "heute \(s.overview.todayTasks.count + s.overview.overdueTasks.count) · \(open) offen")
          let unread = s.messengerConversations.reduce(0) { $0 + $1.unread }
          try expectEqual(StatusRules.lines(tab: .messages, state: s, agentRequests: 0, isThinking: false),
                          [unread > 0 ? "\(unread) ungelesen" : "Nachrichten"])
        }
      },
    ]
  }

  // MARK: - Sonstiges

  @MainActor static var miscCases: [CheckCase] {
    [
      CheckCase("Begrüßung nach Tageszeit") {
        try expectEqual(StatusRules.greeting(hour: 7), "Guten Morgen!")
        try expectEqual(StatusRules.greeting(hour: 13), "Hallo!")
        try expectEqual(StatusRules.greeting(hour: 19), "Guten Abend!")
        try expectEqual(StatusRules.greeting(hour: 2), "Noch wach?")
      },
      CheckCase("Statusanzeige rechts und Statuszeilen") {
        try await MainActor.run {
          let fake = FakeServices(sample: true)
          let s = fake.current
          try expectEqual(StatusRules.indicator(state: s, agentPending: true, isThinking: true, now: fixedNow), .attention)
          try expectEqual(StatusRules.indicator(state: s, agentPending: false, isThinking: true, now: fixedNow), .thinking)
          guard case .count(3, overdue: true) = StatusRules.indicator(state: s, agentPending: false, isThinking: false, now: fixedNow) else {
            throw fail("erwartet .count(3, überfällig)")
          }
          try expectEqual(StatusRules.indicator(state: AppState(), agentPending: false, isThinking: false, now: fixedNow), .calm)
          // Mod-Texte gehören zum Laufband, nicht zum rechten Flügel.
          let withMsg = AppState(islandMessage: IslandMessage(text: "Noch 3 Tage", until: "2026-10-12T23:59", modId: "c"))
          try expectEqual(StatusRules.indicator(state: withMsg, agentPending: false, isThinking: false, now: fixedNow), .calm)
          try expectEqual(StatusRules.indicator(state: withMsg, agentPending: true, isThinking: false, now: fixedNow), .attention)
          var busy = withMsg; busy.overview = Overview(overdueTasks: [TabyTask(id: "t", title: "x", createdAt: "2026-10-10")])
          try expectEqual(StatusRules.indicator(state: busy, agentPending: false, isThinking: false, now: fixedNow),
                          .count(1, overdue: true))
          try expectEqual(StatusRules.lines(tab: .today, state: s, agentRequests: 0, isThinking: false),
                          ["3 Termine · 2 Aufgaben", "1 überfällig"])
          try expectEqual(StatusRules.lines(tab: .notion, state: s, agentRequests: 0, isThinking: false), ["Notion"])
          try expectEqual(StatusRules.lines(tab: .agents, state: s, agentRequests: 1, isThinking: false), ["Freigabe nötig"])
          try expectEqual(StatusRules.lines(tab: .chat, state: s, agentRequests: 0, isThinking: true), ["Denkt nach …"])
          try expectEqual(StatusRules.lines(tab: .notes, state: nil, agentRequests: 0, isThinking: false), ["Lädt …"])
        }
      },
      CheckCase("Ansicht rendert ohne Fenster in jedem Zustand") {
        try await MainActor.run {
          for spec in ShellSnapshots.all {
            let r = ImageRenderer(content: spec.make().frame(width: spec.size.width, height: spec.size.height))
            try expect(r.cgImage != nil, "\(spec.name) rendert")
          }
        }
      },
    ]
  }
}

// MARK: - Snapshots

enum ShellSnapshots {
  static let panel = CGSize(width: 760, height: 470)

  /// Store in einem bestimmten Zustand, mit geladenem Beispielzustand.
  @MainActor static func store(geometry: NotchGeometry = .preview, _ setup: (IslandStore, FakeServices) -> Void)
    -> IslandStore {
    let fake = FakeServices(sample: true)
    let model = AppModel(services: fake)
    let clock = ManualClock()
    let s = IslandStore(model: model, geometry: geometry, expansion: .memory(), now: { clock.t })
    // AppModel lädt den Zustand nur asynchron; Snapshots rendern synchron.
    s.previewState = fake.current
    setup(s, fake)
    return s
  }

  @MainActor static func island(_ name: String, height: CGFloat = 470, geometry: NotchGeometry = .preview,
                                _ setup: @escaping (IslandStore, FakeServices) -> Void) -> SnapshotSpec {
    SnapshotSpec("shell-island-\(name)", size: CGSize(width: panel.width, height: height)) {
      let s = store(geometry: geometry, setup)
      return AnyView(
        ZStack(alignment: .top) {
          SnapshotDesktop(menuBarHeight: geometry.notchHeight)
          IslandRootView(store: s, animateEntrance: false)
        }
        .environment(\.tabySnapshot, true)
      )
    }
  }

  /// Wie `island`, aber mit festem Zeitpunkt (für Countdown-Texte der Meeting-Karte).
  @MainActor static func islandAt(_ name: String, now: String, height: CGFloat = 470,
                                  _ setup: @escaping (IslandStore, FakeServices) -> Void) -> SnapshotSpec {
    SnapshotSpec("shell-island-\(name)", size: CGSize(width: panel.width, height: height)) {
      let s = store(geometry: .preview, setup)
      return AnyView(
        ZStack(alignment: .top) {
          SnapshotDesktop(menuBarHeight: NotchGeometry.preview.notchHeight)
          IslandRootView(store: s, animateEntrance: false)
        }
        .environment(\.tabyNow, now)
        .environment(\.tabySnapshot, true)
      )
    }
  }

  /// App-Symbol (für scripts/make-icon.sh; Snapshots rendern mit Faktor 2 → 1024 px).
  @MainActor static var appIcon: SnapshotSpec {
    SnapshotSpec("app-icon-1024", size: CGSize(width: 512, height: 512)) { AnyView(AppIconArt()) }
  }

  @MainActor static var all: [SnapshotSpec] {
    [appIcon, SnapshotSpec("mascot-actions", size: CGSize(width: 1000, height: 150)) {
      AnyView(HStack(spacing: 22) {
        ForEach(Array([(MascotAction.jump, 0.34), (.laugh, 0.4), (.fall, 1.0), (.spin, 0.5), (.sneeze, 0.78),
                       (.love, 0.5), (.wave, 0.6), (.peek, 0.5), (.wiggle, 0.5), (.nod, 0.5)].enumerated()),
                id: \.offset) { _, item in
          VStack(spacing: 6) {
            TabyMascot(mood: .idle, size: 70, time: 50 + item.1, followsMouse: false,
                       play: MascotPlay(action: item.0, startedAt: 50))
            Text(item.0.rawValue).font(.caption).foregroundStyle(.white.opacity(0.7))
          }
        }
      }.padding(20))
    }] + [
      island("closed", height: 120) { _, _ in },
      island("closed-attention", height: 120) { s, fake in
        fake.emit(.agentRequest(AgentPermissionRequest(id: "r", toolName: "Bash", toolInput: .string("ls"))))
        s.close()
      },
      island("closed-ticker", height: 120) { s, _ in
        s.previewState?.islandMessages = [IslandMessage(text: "⛅️ Köln 14 °C", until: "2026-10-14T23:59", modId: "w")]
      },
      island("closed-no-notch", height: 120, geometry: .previewNoNotch) { _, _ in },
      island("peek", height: 120) { s, _ in s.mouseEntered(); s.skipPeekDwellForPreview() },
      island("greeting", height: 180) { s, _ in s.greetingText = "Guten Morgen!"; s.launch() },
      island("flash-task", height: 200) { _, fake in
        fake.emit(.flash(TabyNotification(title: "Zahnarzt anrufen", body: "Fällig um 11:00 – jetzt erledigen?", taskId: "t1")))
      },
      island("flash", height: 200) { _, fake in
        fake.emit(.flash(TabyNotification(title: "Zahnarzt anrufen", body: "Fällig um 11:00 – jetzt erledigen?")))
      },
      island("open-today") { s, _ in s.open(tab: .today) },
      island("open-chat") { s, _ in s.open(tab: .chat); s.model.isThinking = true },
      island("open-agents-request") { _, fake in
        fake.emit(.agentRequest(AgentPermissionRequest(id: "r", toolName: "Bash", toolInput: .string("npm test"))))
      },
      island("open-happy-max") { s, _ in
        s.previewContent = AnyView(SnapshotList())
        s.open(tab: .tasks)
        s.setContentHeight(2000)
        s.model.react(.celebrate)
      },
      island("open-no-notch", geometry: .previewNoNotch) { s, _ in s.open(tab: .notes) },
      island("capture", height: 200) { s, _ in s.openCapture() },
      islandAt("meeting-upcoming", now: "2026-10-11T14:52") { s, fake in
        s.previewMeeting(fake.sampleMeeting(.upcoming))
      },
      island("peek-music", height: 150) { s, _ in liveSample(s, timer: false, music: true, meeting: false); s.mouseEntered(); s.skipPeekDwellForPreview() },
      island("closed-timer", height: 120) { s, _ in liveSample(s, timer: true, music: false, meeting: false) },
      island("closed-live", height: 120) { s, _ in liveSample(s, timer: true, music: true, meeting: true) },
      island("peek-live", height: 150) { s, _ in liveSample(s, timer: true, music: true, meeting: true); s.mouseEntered(); s.skipPeekDwellForPreview() },
      island("peek-meeting", height: 150) { s, _ in liveSample(s, timer: false, music: false, meeting: true); s.mouseEntered(); s.skipPeekDwellForPreview() },
      islandAt("meeting-ended", now: "2026-10-11T16:05") { s, fake in
        s.previewMeeting(fake.sampleMeeting(.ended))
      },
      islandAt("meeting-saved", now: "2026-10-11T16:05") { s, fake in
        s.previewMeeting(fake.sampleMeeting(.ended), saved: "Notiz + 2 Aufgaben gespeichert")
      },
      island("weekly-review") { s, fake in
        fake.current.weeklyReview = fake.sampleWeeklyReview()
        fake.current.weeklyReviewPrompt = true
        s.previewState = fake.current
        s.open(tab: .today)
      },
      island("drop-target") { s, _ in s.setDropTargeted(true) },
      island("expanded-mail", height: 760) { s, fake in
        // Viele wichtige, ungelesene Mails: die Liste (Filter „Wichtig“) braucht mehr Höhe.
        var mail = fake.sampleMail()
        mail.messages += (0..<12).map { i in
          MailMessage(id: "x\(i)", senderName: "Kollegin \(i + 1)", senderAddress: "k\(i)@example.com",
                      subject: "Bitte kurz prüfen, Punkt \(i + 1)", date: "2026-10-10T1\(i % 10):00",
                      category: .important)
        }
        fake.current.mail = mail
        s.previewState = fake.current
        s.previewContent = AnyView(TabContentView(tab: .mail, preview: fake.current))
        s.open(tab: .mail)
        s.toggleExpanded()
      },
      SnapshotSpec("view-network-off-hidden", size: panel) {
        // Netzwerk aus: der Reiter fehlt in der Reiterleiste.
        let s = store { s, _ in s.open(tab: .today) }
        return AnyView(
          ZStack(alignment: .top) {
            SnapshotDesktop(menuBarHeight: NotchGeometry.preview.notchHeight)
            IslandRootView(store: s, animateEntrance: false)
          }
          .environment(\.tabySnapshot, true)
        )
      },
      SnapshotSpec("shell-mascot-moods", size: CGSize(width: 760, height: 330)) {
        AnyView(MascotSheet())
      },
    ] + MascotChecks.snapshots
  }
}

/// Zeitabhängige Beispiele: fester Zeitpunkt 14:52, Timer bis 14:55, Musik, Termin 14:57 mit Link.
@MainActor private func liveSample(_ s: IslandStore, timer: Bool, music: Bool, meeting: Bool) {
  s.wallClock = { LocalTime.parse("2026-10-11T14:52")! }
  if timer { s.previewState?.timers = [TabyTimer(id: "p", label: "Pause", endsAt: "2026-10-11T14:55")] }
  if music {
    s.previewState?.nowPlaying = NowPlaying(title: "Ruhige Musik", artist: "Beispielband", app: "Musik", playing: true)
  }
  if meeting {
    s.previewState?.overview.eventsToday.append(CalendarEvent(
      id: "m", sourceId: "snap", title: "Design-Review", start: "2026-10-11T14:57", end: "2026-10-11T15:30",
      notes: "Einwahl: https://teams.microsoft.com/l/meetup-join/demo"))
  }
}

/// Lange Beispielliste (zeigt die Höhenbegrenzung; echte Inhalte liefert Views/).
private struct SnapshotList: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(0..<14, id: \.self) { i in
        HStack(spacing: 10) {
          Image(systemName: i < 3 ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(i < 3 ? MascotMood.happy.color : .white.opacity(0.4))
          Text("Beispielaufgabe \(i + 1)").foregroundStyle(.white.opacity(0.85))
          Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
      }
    }
  }
}

/// Angedeuteter Schreibtisch mit Menüleiste, damit die Verschmelzung sichtbar ist.
private struct SnapshotDesktop: View {
  let menuBarHeight: CGFloat
  var body: some View {
    ZStack(alignment: .top) {
      LinearGradient(colors: [Color(shellHex: 0x2B3350), Color(shellHex: 0x6B4E7A)], startPoint: .topLeading,
                     endPoint: .bottomTrailing)
      Rectangle().fill(Color.white.opacity(0.12)).frame(height: menuBarHeight)
      HStack {
        Text("Finder   Ablage   Bearbeiten").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        Spacer()
        Text("Mo 9:41").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
      }
      .padding(.horizontal, 12)
      .frame(height: menuBarHeight)
    }
  }
}

private struct MascotSheet: View {
  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 14) {
        ForEach(MascotMood.allCases, id: \.self) { m in
          VStack(spacing: 10) {
            TabyMascot(mood: m, size: 84, glow: true, time: sampleTime(m))
              .frame(width: 92, height: 100)
            Text(m.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
          }
        }
      }
      HStack(spacing: 30) {
        ForEach(MascotMood.allCases, id: \.self) { m in
          TabyMascot(mood: m, size: 30, time: sampleTime(m))
        }
        TabyMascot(mood: .happy, size: 30, waving: true, time: 0.3)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 20)
      .background(Capsule().fill(Color.black))
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(shellHex: 0x0E0E10))
  }

  /// Zeitpunkte, an denen die Bewegung gut sichtbar ist.
  private func sampleTime(_ m: MascotMood) -> Double {
    switch m {
    case .idle: 0.9
    case .happy: 0.43
    case .love: 0.5
    case .thinking: 0.2
    case .alert: 0.1
    case .error: 0.3
    case .sleepy: 0.8
    }
  }
}


// MARK: - Paket 2: Tagesabschluss offen halten, Fokus-Countdown

extension ShellChecks {
  // MARK: - Ausklappen, Reitersichtbarkeit (Netzwerk)

  @MainActor static var expansionCases: [CheckCase] {
    [
      CheckCase("Ausgeklappt: Höhe je Bildschirm (900 px → 560, 1440 px → 820, nie unter 380)") {
        try expectEqual(IslandMetrics.maxContent(screenHeight: 900), 560)
        try expectEqual(IslandMetrics.maxContent(screenHeight: 1440), 820)
        try expectEqual(IslandMetrics.maxContent(screenHeight: 1000), 630)
        try expectEqual(IslandMetrics.maxContent(screenHeight: 300), 380)
        try expectEqual(IslandMetrics.contentCap(expanded: false, screenHeight: 1440), 380)
        try expectEqual(IslandMetrics.contentCap(expanded: true, screenHeight: 900), 560)
      },
      CheckCase("Ausgeklappt: Insel wächst, eingeklappt bleibt bei 380") {
        let g = NotchGeometry.preview
        let big = IslandMetrics.size(mode: .open, geometry: g, contentHeight: 2000,
                                     contentCap: IslandMetrics.maxContent(screenHeight: 1440))
        try expectEqual(big.height, 34 + 4 + 820 + 24 + 10)
        try expectEqual(big.height, IslandMetrics.maxOpenHeight(screenHeight: 1440, geometry: g))
        let small = IslandMetrics.size(mode: .open, geometry: g, contentHeight: 2000)
        try expectEqual(small.height, 34 + 4 + 380 + 24 + 10)
        try expect(big.height + 20 < 1440, "Panel-Höhe bleibt unter der Bildschirmhöhe")
      },
      CheckCase("Ausgeklappt merken: je Reiter getrennt (islandExpanded.<reiter>)") {
        let mem = IslandExpansionStore.memory()
        try expectEqual(mem.isExpanded(.mail), false)
        mem.setExpanded(.mail, true)
        try expectEqual(mem.isExpanded(.mail), true)
        try expectEqual(mem.isExpanded(.tasks), false, "Aufgaben bleiben eingeklappt")
        try expectEqual(IslandExpansionRules.key(.mail), "islandExpanded.mail")
      },
      CheckCase("Reitersichtbarkeit: Netzwerk, Notion und Mail nur, wenn eingeschaltet, sonst Heute") {
        let all = OpenBoardTabs.left + OpenBoardTabs.right
        var on = TabySettings.defaults
        on.networkToolsEnabled = true
        on.notionTasksEnabled = true
        on.mailEnabled = true
        try expectEqual(IslandExpansionRules.visible(all, settings: nil).contains(.network), false)
        try expectEqual(TabyTab.mail.isVisible(.defaults), TabySettings.defaults.mailEnabled, "Mail-Reiter folgt dem Schalter")
        try expectEqual(TabyTab.notion.isVisible(nil), false)
        try expectEqual(TabyTab.notion.isVisible(on), true)
        try expectEqual(IslandExpansionRules.visible(all, settings: .defaults).count,
                        all.count - (TabySettings.defaults.mailEnabled ? 3 : 4))
        try expectEqual(Set(IslandExpansionRules.visible(all, settings: on)), Set(TabyTab.allCases).subtracting([.messages]))
        try expectEqual(IslandExpansionRules.fallbackTab(.network, settings: .defaults), .today)
        try expectEqual(IslandExpansionRules.fallbackTab(.network, settings: on), .network)
        try expectEqual(IslandExpansionRules.fallbackTab(.mail, settings: on), .mail)
      },
      CheckCase("Store: Ausklappen wirkt auf die Höhe, Reiterwechsel merkt je Reiter") {
        try await MainActor.run {
          let (store, _, _, _) = makeStore()
          store.open(tab: .mail)
          try expectEqual(store.contentCap, 380)
          store.toggleExpanded()
          try expect(store.expanded, "ausgeklappt")
          try expectEqual(store.contentCap, IslandMetrics.maxContent(screenHeight: NotchGeometry.preview.screenFrame.height))
          store.selectTab(.tasks)
          try expect(!store.expanded, "Aufgaben sind eingeklappt")
          store.selectTab(.mail)
          try expect(store.expanded, "Mail merkt sich ausgeklappt")
        }
      },
      CheckCase("Store: ausgeblendeter Netzwerk-Reiter springt auf Heute") {
        let (store, model, fake, _) = await MainActor.run { makeStore() }
        await MainActor.run { fake.current.settings.networkToolsEnabled = true }
        await model.refresh()
        try await MainActor.run { store.selectTab(.network); try expectEqual(store.tab, .network) }
        await MainActor.run { fake.current.settings.networkToolsEnabled = false }
        await model.refresh()
        try await MainActor.run { try expectEqual(store.tab, .today, "fällt auf Heute zurück") }
      },
    ]
  }

  @MainActor static var packageTwoCases: [CheckCase] {
    [
      CheckCase("Tagesabschluss öffnet und hält offen, bis beantwortet") {
        var m = IslandStateMachine()
        m.setPromptPending(true, now: 0)
        try expectEqual(m.mode, .open)
        m.mouseLeft(now: 1)
        m.tick(now: 10)
        try expectEqual(m.mode, .open, "darf beim Verlassen nicht schließen")
        m.setPromptPending(false, now: 11)
        m.tick(now: 20)
        try expectEqual(m.mode, .closed, "nach der Antwort schließt sie wieder")
      },
      CheckCase("Fokus-Uhr: angehalten bleibt die Restzeit stehen, auch wenn die Uhr weiterläuft") {
        let f = FocusSession(id: "f", title: "Bericht", startedAt: "2026-10-12T09:00:00", endsAt: "2026-10-12T09:25:00",
                             minutes: 25, pausedAt: "2026-10-12T09:10:00")
        let later = try expectNotNil(LocalTime.parse("2026-10-12T09:20:00"))
        try expectEqual(FocusClock.remaining(f, now: later), 15 * 60)
      },
      CheckCase("Fokus-Uhr: Restzeit, Format, Fortschritt") {
        let f = FocusSession(id: "f", title: "Bericht", startedAt: "2026-10-12T09:00:00", endsAt: "2026-10-12T09:25:00",
                             minutes: 25)
        let now = try expectNotNil(LocalTime.parse("2026-10-12T09:10:00"))
        try expectEqual(FocusClock.remaining(f, now: now), 15 * 60)
        try expectEqual(FocusClock.format(15 * 60), "15:00")
        try expectEqual(FocusClock.format(59), "00:59")
        try expectEqual(FocusClock.format(3_725), "1:02:05")
        let after = try expectNotNil(LocalTime.parse("2026-10-12T09:30:00"))
        try expectEqual(FocusClock.remaining(f, now: after), 0)
        try expect(abs(FocusClock.progress(f, now: now) - 0.4) < 0.001)
        try expect(FocusClock.statusLine(f, now: now).hasPrefix("Fokus · 15:00"))
      },
      CheckCase("Eigener Notch-Text und Countdown") {
        let today = "2026-10-14"
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "", today: today), "Urlaub")
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "2026-10-19", today: today), "Urlaub · noch 5 Tage")
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "2026-10-15", today: today), "Urlaub · morgen")
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "2026-10-14", today: today), "Urlaub · heute")
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "2026-10-01", today: today), "Urlaub")
        try expectEqual(StatusRules.ownNotchText(text: "", countdown: "2026-10-19", today: today), "noch 5 Tage")
        try expectEqual(StatusRules.ownNotchText(text: "", countdown: "", today: today), nil)
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "2026-02-31", today: today), "Urlaub")
        try expectEqual(StatusRules.ownNotchText(text: "Urlaub", countdown: "nope", today: today), "Urlaub")
        let long = String(repeating: "x", count: 60)
        let clamped = try expectNotNil(StatusRules.ownNotchText(text: long, countdown: "", today: today))
        try expectEqual(clamped.count, 40)
        let withCount = try expectNotNil(StatusRules.ownNotchText(text: long, countdown: "2026-10-19", today: today))
        try expectEqual(withCount.count <= 40, true)
        try expect(withCount.hasSuffix(" · noch 5 Tage"), "Countdown bleibt sichtbar")
        // Eigener Notch-Text steht am Ende des Laufbands, nicht im rechten Flügel.
        var st = AppState()
        st.settings.notchText = "Urlaub"
        st.settings.notchCountdown = "2026-10-19"
        try expectEqual(StatusRules.indicator(state: st, agentPending: false, isThinking: false, now: fixedNow), .calm)
        try expectEqual(tickerTexts(state: st, today: today, now: fixedNow), ["Urlaub · noch 5 Tage"])
        st.islandMessage = IslandMessage(text: "Mod", until: "2026-10-20T23:59", modId: "m")
        try expectEqual(tickerTexts(state: st, today: today, now: fixedNow), ["Mod", "Urlaub · noch 5 Tage"])
        st.islandMessage = nil
        try expectEqual(StatusRules.indicator(state: st, agentPending: true, isThinking: false, now: fixedNow), .attention)
      },
      CheckCase("Geschlossene Insel zeigt Fokus vor Aufgaben-Zähler") {
        var st = AppState()
        st.overview.todayTasks = [TabyTask(id: "t", title: "x", createdAt: "")]
        st.focus = FocusSession(id: "f", title: "x", startedAt: "", endsAt: "2026-10-12T09:25:00", minutes: 25)
        guard case .focus = StatusRules.indicator(state: st, agentPending: false, isThinking: false, now: fixedNow) else {
          throw fail("erwartet .focus")
        }
        guard case .attention = StatusRules.indicator(state: st, agentPending: true, isThinking: false, now: fixedNow) else {
          throw fail("Freigabe hat Vorrang")
        }
      },
      CheckCase("Laufband: Mod-Texte, ungelesene Chats, eigener Text") {
        var st = AppState()
        st.overview.todayTasks = [TabyTask(id: "t", title: "x", createdAt: "")]
        st.islandMessages = [IslandMessage(text: "⛅️ Köln 14 °C", until: "2026-10-14T23:59", modId: "w"),
                             IslandMessage(text: "Deadline", until: "2026-10-14T23:59", modId: "c")]
        st.messengerConversations = [
          MessengerConversation(id: "a|1", accountId: "a", title: "Team", unread: 2, lastText: "Hallo", lastAt: "2026-10-14T09:00"),
          MessengerConversation(id: "a|2", accountId: "a", title: "Ruhig", unread: 0, lastText: "x", lastAt: "2026-10-14T10:00"),
          MessengerConversation(id: "a|3", accountId: "a", title: "Mama", unread: 1, lastText: nil, lastAt: "2026-10-14T11:00"),
        ]
        // Reihenfolge: Mod-Texte, ungelesene Chats (neueste zuerst), eigener Text. Aufgaben bleiben draußen.
        try expectEqual(tickerTexts(state: st, today: "2026-10-14", now: fixedNow),
                        ["⛅️ Köln 14 °C", "Deadline", "Mama: neue Nachricht", "Team: Hallo"])
        try expectEqual(StatusRules.indicator(state: st, agentPending: false, isThinking: false, now: fixedNow),
                        .count(1, overdue: false))
        try expectEqual(StatusRules.indicator(state: st, agentPending: true, isThinking: false, now: fixedNow), .attention)
        try expectEqual(StatusRules.indicator(state: st, agentPending: false, isThinking: true, now: fixedNow), .thinking)
        // Höchstens drei Chats; jede Zeile höchstens 48 Zeichen, der Rest wird mit "…" gekürzt.
        var chats = AppState()
        chats.messengerConversations = (1...4).map {
          MessengerConversation(id: "a|\($0)", accountId: "a", title: String(repeating: "x", count: 50) + "\($0)",
                                unread: 1, lastText: nil, lastAt: "2026-10-14T0\($0):00")
        }
        let lines = tickerTexts(state: chats, today: "2026-10-14", now: fixedNow)
        try expectEqual(lines.count, 3)
        for l in lines { try expect(l.count == 48 && l.hasSuffix("…"), "Zeile auf 48 Zeichen gekürzt") }
        try expectEqual(StatusRules.cutTickerLine("kurz"), "kurz")
        // Leer: keine Zeilen, also kein Laufband.
        try expectEqual(tickerTexts(state: AppState(), today: "2026-10-14", now: fixedNow), [])
        try expectEqual(tickerTexts(state: nil, today: "2026-10-14", now: fixedNow), [])
      },
    ]
  }
}
