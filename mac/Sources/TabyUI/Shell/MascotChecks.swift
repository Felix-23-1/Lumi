// Prüfungen und Snapshots für die Zusatzszenen des Maskottchens (Requisiten,
// Tageszeit, Feiertage, Streicheln, Schütteln, Ziehen, Glühbirne, Jubel).
import AppKit
import Foundation
import SwiftUI
import TabyCore

enum MascotChecks {
  static var cases: [CheckCase] {
    [
      CheckCase("Maskottchen ruht geschlossen: kein Takt, außer während einer Reaktion") {
        let jump = MascotPlay(action: .jump, startedAt: 100)
        try expect(!MascotPace.animates(still: true, play: nil, now: 100, reduceMotion: false), "ruhend ohne Reaktion")
        try expect(MascotPace.animates(still: true, play: jump, now: 100.2, reduceMotion: false), "Sprung läuft")
        try expect(!MascotPace.animates(still: true, play: jump, now: 105, reduceMotion: false), "Sprung vorbei: wieder ruhend")
        try expect(MascotPace.animates(still: false, play: nil, now: 100, reduceMotion: false), "offen/Peek animiert")
        try expect(!MascotPace.animates(still: false, play: jump, now: 100.2, reduceMotion: true), "Reduce Motion nie")
      },
      CheckCase("Maskottchen: Feiertagsmützen mit Grenzdaten") {
        try expectEqual(MascotDecor.for(date: "2026-12-01T09:00", birthday: "", enabled: true), .santa)
        try expectEqual(MascotDecor.for(date: "2026-12-26", birthday: "", enabled: true), .santa)
        try expectEqual(MascotDecor.for(date: "2026-12-27", birthday: "", enabled: true), nil, "ab dem 27. keine Mütze")
        try expectEqual(MascotDecor.for(date: "2026-11-30", birthday: "", enabled: true), nil)
        try expectEqual(MascotDecor.for(date: "2026-10-31", birthday: "", enabled: true), .pumpkin)
        try expectEqual(MascotDecor.for(date: "2026-10-12", birthday: "10-12", enabled: true), .party)
        try expectEqual(MascotDecor.for(date: "2026-10-12", birthday: "10-13", enabled: true), nil)
        try expectEqual(MascotDecor.for(date: "2026-12-05", birthday: "", enabled: false), nil, "ohne Schalter keine Deko")
      },
      CheckCase("Maskottchen: Tageszeit-Phasen nach Stunde") {
        let table: [(Int, MascotDaypart)] = [(0, .night), (5, .night), (6, .morning), (8, .morning), (9, .day),
                                             (20, .day), (21, .evening), (23, .evening)]
        for (h, d) in table { try expectEqual(MascotDaypart.at(hour: h), d, "Stunde \(h)") }
      },
      CheckCase("Maskottchen: Gähnen nur morgens, alle 25 s") {
        try expect(MascotYawn.amount(at: 1.2, daypart: .morning) > 0.5, "mitten im Gähnen")
        try expectEqual(MascotYawn.amount(at: 1.2, daypart: .day), 0)
        try expectEqual(MascotYawn.amount(at: 5.0, daypart: .morning), 0)
        try expect(MascotYawn.amount(at: 26.2, daypart: .morning) > 0.5, "nach 25 s wieder")
      },
      CheckCase("Maskottchen: Schütteln erkannt (≥ 4 Wechsel in 1 s)") {
        let zig = (0..<8).map { MascotPointerSample(t: Double($0) * 0.1, x: $0 % 2 == 0 ? 100 : 110) }
        try expect(MascotShake.isDizzy(zig, now: 0.7), "schnelles Hin und Her")
        let line = (0..<8).map { MascotPointerSample(t: Double($0) * 0.1, x: CGFloat($0) * 5) }
        try expect(!MascotShake.isDizzy(line, now: 0.7), "gleichmäßige Bewegung ist kein Schütteln")
        let slow = (0..<4).map { MascotPointerSample(t: Double($0) * 0.5, x: $0 % 2 == 0 ? 100 : 110) }
        try expect(!MascotShake.isDizzy(slow, now: 1.5), "langsames Hin und Her zählt nicht")
        try expect(MascotShake.dizzyActive(since: 10, now: 11.5), "2 s schwindelig")
        try expect(!MascotShake.dizzyActive(since: 10, now: 12.1), "danach vorbei")
      },
      CheckCase("Maskottchen: Streicheln nach 0,8 s, Rangfolge der Gesichter") {
        var c = MascotContext()
        c.hoverStart = 0
        try expectEqual(MascotPriority.face(c, now: 0.5, playing: false), .normal)
        try expectEqual(MascotPriority.face(c, now: 0.9, playing: false), .petting)
        c.dizzyStart = 0.9
        try expectEqual(MascotPriority.face(c, now: 1.0, playing: false), .petting, "Streicheln geht vor Schwindel")
        c.hoverStart = nil
        try expectEqual(MascotPriority.face(c, now: 1.0, playing: false), .dizzy)
        try expectEqual(MascotPriority.face(c, now: 1.0, playing: true), .dizzy, "Schwindel geht vor Klick-Einlage")
        c.dizzyStart = nil
        c.hoverStart = 0
        c.drag = CGSize(width: 40, height: 0)
        try expectEqual(MascotPriority.face(c, now: 2, playing: false), .normal, "Ziehen geht vor allem")
      },
      CheckCase("Maskottchen: Schlaf nur nachts, Insel zu, ohne Fokus") {
        var c = MascotContext()
        c.daypart = .night
        try expectEqual(MascotPriority.face(c, now: 0, playing: false), .asleep)
        try expectEqual(MascotPriority.face(c, now: 0, playing: true), .normal, "Klick-Einlage geht vor")
        c.islandOpen = true
        try expectEqual(MascotPriority.face(c, now: 0, playing: false), .normal, "offene Insel: wach")
        c.islandOpen = false
        c.focus = .work
        try expectEqual(MascotPriority.face(c, now: 0, playing: false), .normal, "Fokus läuft: wach")
      },
      CheckCase("Maskottchen: Zubehör – Kopfhörer ersetzen Schlafmütze, Tageszeit vor Feiertag") {
        var c = MascotContext()
        c.daypart = .evening
        c.decor = .santa
        let a = MascotPriority.accessories(c)
        try expect(a.nightcap && a.hat == nil, "Schlafmütze vor Weihnachtsmütze")
        c.focus = .work
        let b = MascotPriority.accessories(c)
        try expect(b.headphones && !b.nightcap, "Kopfhörer ersetzen die Schlafmütze")
        try expectEqual(b.hat, .santa)
        c.focus = .rest
        try expect(MascotPriority.accessories(c).coffee, "Pause: Kaffeetasse")
      },
      CheckCase("Maskottchen: Requisit hält 3 s, nie während einer Klick-Einlage") {
        let p = MascotPropEvent(prop: .envelope, startedAt: 10)
        try expect(p.elapsed(at: 12.9) != nil, "noch sichtbar")
        try expect(p.elapsed(at: 13.0) == nil, "nach 3 s weg")
        try expect(p.elapsed(at: 9.9) == nil, "vor dem Start nicht")
        var c = MascotContext()
        c.prop = p
        try expect(MascotPriority.prop(c, now: 11, playing: true) == nil, "Klick-Einlage geht vor")
        try expectEqual(MascotPriority.prop(c, now: 11, playing: false)?.prop, .envelope)
      },
      CheckCase("Maskottchen: Glühbirne taucht auf und verschwindet") {
        try expect(MascotBulb.visibility(startedAt: nil, now: 1) == nil)
        try expect(MascotBulb.visibility(startedAt: 0, now: -0.1) == nil)
        try expect((MascotBulb.visibility(startedAt: 0, now: 0.05) ?? 0) < 0.7, "beim Auftauchen noch klein")
        try expect((MascotBulb.visibility(startedAt: 0, now: 0.6) ?? 0) > 0.95, "dann voll")
        try expect(MascotBulb.visibility(startedAt: 0, now: 1.5) == nil, "nach 1,5 s weg")
      },
      CheckCase("Maskottchen: Streckung begrenzt, Feder federt auf 1,0 zurück") {
        try expect(MascotStretch.shape(for: CGSize(width: 1000, height: 0)).scale == 1.35, "höchstens 1,35×")
        try expectEqual(MascotStretch.shape(for: .zero).scale, 1)
        let v = CGSize(width: 80, height: 0)
        try expectEqual(MascotStretch.released(v, sinceRelease: 0), v, "beim Loslassen volle Auslenkung")
        try expect(MascotStretch.released(v, sinceRelease: 0.25).width < 0, "überschwingt in die Gegenrichtung")
        try expectEqual(MascotStretch.released(v, sinceRelease: MascotStretch.settleTime), .zero)
        try expectEqual(MascotStretch.shape(for: MascotStretch.released(v, sinceRelease: 1.7)).scale, 1)
      },
      CheckCase("Maskottchen: Konfetti ist für eine Saat deterministisch") {
        let a = MascotConfetti.pieces(seed: 7, count: 20, elapsed: 0.5, duration: 1.2)
        try expect(a == MascotConfetti.pieces(seed: 7, count: 20, elapsed: 0.5, duration: 1.2), "gleiche Saat")
        try expect(a != MascotConfetti.pieces(seed: 8, count: 20, elapsed: 0.5, duration: 1.2), "andere Saat")
        let start = MascotConfetti.pieces(seed: 7, count: 5, elapsed: 0, duration: 1.2)
        try expect(start.allSatisfy { $0.x == 0 && $0.y == 0 }, "alles startet am Ursprung")
        try expect(MascotConfetti.pieces(seed: 7, count: 5, elapsed: 1.3, duration: 1.2).allSatisfy { $0.alpha == 0 },
                   "nach Ablauf unsichtbar")
        let f = MascotConfetti.fireworks(seed: 3, elapsed: 0.5)
        try expect(f == MascotConfetti.fireworks(seed: 3, elapsed: 0.5), "Feuerwerk deterministisch")
        try expect(!f.isEmpty, "Funken fliegen")
      },
      CheckCase("Maskottchen: Store – Konfetti bei Aufgabe, Feuerwerk bei der letzten für heute") {
        try await MainActor.run {
          let (store, model, fake, clock) = ShellChecks.makeStore()
          model.react(.taskCompleted)
          try expectEqual(store.celebration?.kind, .confetti)
          var before = fake.current
          before.overview = Overview(todayTasks: [TabyTask(id: "t1", title: "Steuer", createdAt: "2026-10-12T08:00")])
          store.observeMascotEvents(before)
          var after = before
          after.overview = Overview()
          clock.advance(1)
          store.observeMascotEvents(after)
          try expectEqual(store.celebration?.kind, .fireworks, "letzte Aufgabe für heute")
        }
      },
      CheckCase("Maskottchen: Store – neue wichtige Mail hält einen Briefumschlag hoch") {
        try await MainActor.run {
          let (store, _, fake, _) = ShellChecks.makeStore()
          var s1 = fake.current
          s1.mail = MailOverview(messages: [], unread: 0)
          store.observeMascotEvents(s1)
          try expect(store.mascotProp == nil, "beim ersten Stand nichts")
          var s2 = s1
          let mail = MailMessage(id: "m1", senderName: "Anna", senderAddress: "anna@example.de", subject: "Angebot",
                                 date: "2026-10-12T09:00", category: .important)
          s2.mail = MailOverview(messages: [mail], unread: 1)
          store.observeMascotEvents(s2)
          try expectEqual(store.mascotProp?.prop, .envelope)
        }
      },
      CheckCase("Maskottchen: Store – Tageszeit und Feiertag kommen aus der Uhr") {
        try await MainActor.run {
          let (store, _, fake, _) = ShellChecks.makeStore()
          var s = fake.current
          s.settings.seasonalDecor = true
          store.previewState = s
          store.localClock = { ("2026-12-05", 2) }
          let c = store.mascotContext(at: 1000)
          try expectEqual(c.daypart, .night)
          try expectEqual(c.decor, .santa)
        }
      },
    ]
  }

  // MARK: - Snapshots

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      SnapshotSpec("mascot-accessories", size: CGSize(width: 960, height: 150)) {
        AnyView(HStack(spacing: 4) {
          cell("Kopfhörer", ctx: MascotContext(focus: .work))
          cell("Kaffee", ctx: MascotContext(focus: .rest))
          cell("Schlafmütze", ctx: MascotContext(daypart: .evening))
          cell("Nikolaus", ctx: MascotContext(decor: .santa))
          cell("Kürbis", ctx: MascotContext(decor: .pumpkin))
          cell("Partyhut", ctx: MascotContext(decor: .party))
          cell("Brief", ctx: MascotContext(prop: MascotPropEvent(prop: .envelope, startedAt: 99.5)))
          cell("Laptop", ctx: MascotContext(prop: MascotPropEvent(prop: .laptop, startedAt: 99.5)))
          cell("Idee", ctx: MascotContext(bulbStart: 99.6))
          cell("Regen", mood: .error, ctx: MascotContext())
          cell("Streicheln", ctx: MascotContext(hoverStart: 98))
          cell("Schwindel", ctx: MascotContext(dizzyStart: 99.5))
          cell("Ziehen", ctx: MascotContext(drag: CGSize(width: 60, height: -20)))
        }
        .padding(14)
        .background(Color(shellHex: 0x0E0E10)))
      },
      SnapshotSpec("mascot-confetti", size: CGSize(width: 760, height: 470)) {
        celebrationIsland(.confetti, advance: 0.45)
      },
      SnapshotSpec("mascot-fireworks", size: CGSize(width: 760, height: 470)) {
        celebrationIsland(.fireworks, advance: 0.55)
      },
    ]
  }

  /// Eine Zelle der Zubehör-Reihe: Maskottchen mit festen Zusatzszenen und Beschriftung.
  @MainActor private static func cell(_ label: String, mood: MascotMood = .idle, ctx: MascotContext) -> some View {
    VStack(spacing: 4) {
      TabyMascot(mood: mood, size: 62, glow: true, time: 100, followsMouse: false)
        .withContext(ctx)
      Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
    }
    .frame(width: 66)
  }

  /// Insel mit einem laufenden Jubel (fester Zeitpunkt über die Prüf-Uhr).
  @MainActor private static func celebrationIsland(_ kind: CelebrationBurst.Kind, advance: Double) -> AnyView {
    let (s, _, fake, clock) = ShellChecks.makeStore()
    s.previewState = fake.current
    s.open(tab: .today)
    s.celebrate(kind)
    clock.advance(advance)
    return AnyView(
      ZStack(alignment: .top) {
        LinearGradient(colors: [Color(shellHex: 0x2B3350), Color(shellHex: 0x6B4E7A)], startPoint: .topLeading,
                       endPoint: .bottomTrailing)
        IslandRootView(store: s, animateEntrance: false)
      }
      .environment(\.tabySnapshot, true)
    )
  }
}
