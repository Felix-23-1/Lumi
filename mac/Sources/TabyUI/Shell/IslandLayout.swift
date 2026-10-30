// Reine Rechnungen der Hülle: Inselgröße je Zustand, Stimmung des
// Maskottchens, Statuszeilen, Begrüßung. Alles ohne Fenster prüfbar.
import Foundation
import SwiftUI
import TabyCore

enum IslandMetrics {
  static let openWidth: CGFloat = 640

  /// Breite eines Reiter-Knopfs: 34 pt, bei vielen Reitern schmaler (mind. 24), damit links und
  /// rechts der Notch alles in die offene Insel passt.
  static func tabButtonWidth(count: Int, notchWidth: CGFloat) -> CGFloat {
    guard count > 0 else { return 34 }
    let available = openWidth - 44 - (notchWidth + 12) - 4 * CGFloat(max(0, count - 2))
    return min(34, max(24, (available / CGFloat(count)).rounded(.down)))
  }
  /// Name neben dem aktiven Reiter (geschätzt, 11 pt semibold): nur wenn die Leiste dafür Platz hat,
  /// sonst bleibt es beim Symbol mit Hilfetext. `count` = Reiter in der Leiste (inkl. „Mehr“).
  static func activeLabelWidth(_ title: String) -> CGFloat { CGFloat(title.count) * 6.5 + 10 }
  static func activeLabelFits(_ title: String, count: Int, notchWidth: CGFloat) -> Bool {
    let w = tabButtonWidth(count: count, notchWidth: notchWidth)
    let used = 44 + notchWidth + 12 + CGFloat(count) * w + 4 * CGFloat(max(0, count - 2))
    return used + activeLabelWidth(title) <= openWidth
  }
  /// Breite je Flügel neben der Notch (geschlossen / Peek).
  static let closedWing: CGFloat = 74
  static let peekWing: CGFloat = 90
  static let peekExtraHeight: CGFloat = 8
  /// Laufband unter der Notch (Mittelstreifen), nur wenn Zeilen anstehen.
  static let tickerHeight: CGFloat = 22
  static let flashWidth: CGFloat = 470
  static let flashBodyHeight: CGFloat = 96
  static let greetingWidth: CGFloat = 420
  static let greetingBodyHeight: CGFloat = 82
  /// Inhaltskarte im offenen Zustand.
  static let cardInset: CGFloat = 10
  static let cardTopGap: CGFloat = 4
  static let cardPadding: CGFloat = 12
  static let bottomInset: CGFloat = 10
  /// Zusätzliche Breite beim kurzen "Anstupsen" (Reaktion bei geschlossener Insel).
  static let bumpWidth: CGFloat = 18
  /// Schnellerfassung: feste Breite und Grenzen der gemessenen Inhaltshöhe.
  static let captureWidth: CGFloat = 520
  static let captureMinHeight: CGFloat = 90
  static let captureMaxHeight: CGFloat = 420

  /// Untere Eckenradien: 14 geschlossen → 24 offen (Coucou: 14/22).
  static func bottomRadius(_ mode: IslandMode) -> CGFloat {
    switch mode {
    case .closed: 14
    case .peek: 16
    case .greeting, .flash: 22
    case .capture, .open: 24
    }
  }

  /// Konkave "Ohren" oben links/rechts, mit denen die Insel in die Bildschirmkante übergeht.
  static func earRadius(_ mode: IslandMode) -> CGFloat {
    switch mode {
    case .closed: 8
    case .peek: 10
    case .greeting, .flash, .capture, .open: 14
    }
  }

  /// Höhe der Reiterleiste (Notch-Zeile).
  static func bandHeight(_ g: NotchGeometry) -> CGFloat { max(g.notchHeight, 32) }

  static func clampContent(_ h: CGFloat, cap: CGFloat = TabLayout.maxContentHeight) -> CGFloat {
    min(max(h, TabLayout.minContentHeight), cap)
  }

  /// Ausgeklappt: Anteil der Bildschirmhöhe, der dem Inhalt höchstens bleibt.
  static let expandedFraction: CGFloat = 0.7
  /// Obergrenze der ausgeklappten Inhaltshöhe (auch auf sehr hohen Bildschirmen).
  static let expandedMaxContent: CGFloat = 820
  /// Platz, der außerhalb des Inhalts gebraucht wird: Reiterleiste (~32) + Kartenrand (~38).
  static let expandedChrome: CGFloat = 70

  /// Höchstens sichtbare Inhaltshöhe im ausgeklappten Zustand:
  /// min(70 % der Bildschirmhöhe − Reiterleiste/Rand, 820), nie unter 380.
  static func maxContent(screenHeight: CGFloat) -> CGFloat {
    let fitted = min(expandedFraction * screenHeight - expandedChrome, expandedMaxContent)
    return max(TabLayout.maxContentHeight, fitted)
  }

  /// Obergrenze der Inhaltshöhe je Zustand (eingeklappt = bisherige 380).
  static func contentCap(expanded: Bool, screenHeight: CGFloat) -> CGFloat {
    expanded ? maxContent(screenHeight: screenHeight) : TabLayout.maxContentHeight
  }

  /// Höhe der offenen Insel bei der größten zulässigen Inhaltshöhe (Panel muss sie fassen).
  static func maxOpenHeight(screenHeight: CGFloat, geometry g: NotchGeometry) -> CGFloat {
    bandHeight(g) + cardTopGap + maxContent(screenHeight: screenHeight) + 2 * cardPadding + bottomInset
  }

  /// Höhe des Inhaltsbereichs der Schnellerfassung (ohne Reiterleiste).
  static func captureContentHeight(_ measured: CGFloat) -> CGFloat {
    min(max(measured, captureMinHeight), captureMaxHeight)
  }

  /// Natürliche Höhe der Seitenspalte (Maskottchen 80 + Titel + 2 Statuszeilen).
  /// Die Karte wird nie niedriger, sonst würde die Spalte abgeschnitten.
  static let sideColumnHeight: CGFloat = 140

  /// Höhe des Inhaltsbereichs der Karte.
  static func cardContentHeight(_ measured: CGFloat, cap: CGFloat = TabLayout.maxContentHeight) -> CGFloat {
    max(clampContent(measured, cap: cap), sideColumnHeight)
  }

  /// Linke Spalte der offenen Karte (Maskottchen + Titel + Status).
  static var sideColumnWidth: CGFloat {
    openWidth - 2 * cardInset - 2 * cardPadding - 14 - TabLayout.contentWidth
  }

  /// Sichtbare Inselgröße ohne Ohren.
  static func size(mode: IslandMode, geometry g: NotchGeometry, contentHeight: CGFloat,
                   bumped: Bool = false, captureHeight: CGFloat = 120,
                   contentCap: CGFloat = TabLayout.maxContentHeight, ticker: Bool = false,
                   peekControls: Bool = false) -> CGSize {
    let nh = g.notchHeight
    let tickerExtra = ticker ? tickerHeight : 0
    switch mode {
    case .closed:
      return CGSize(width: g.notchWidth + 2 * closedWing + (bumped ? bumpWidth : 0), height: nh + tickerExtra)
    case .peek:
      // Bedienzeile (Musik, Beitreten) liegt unter dem Laufband.
      let controlsExtra = peekControls ? tickerHeight : 0
      return CGSize(width: g.notchWidth + 2 * peekWing + (bumped ? bumpWidth : 0),
                    height: nh + peekExtraHeight + tickerExtra + controlsExtra)
    case .greeting:
      return CGSize(width: max(greetingWidth, g.notchWidth + 2 * peekWing), height: nh + greetingBodyHeight)
    case .flash:
      return CGSize(width: max(flashWidth, g.notchWidth + 2 * peekWing), height: nh + flashBodyHeight)
    case .capture:
      return CGSize(width: captureWidth, height: bandHeight(g) + captureContentHeight(captureHeight))
    case .open:
      let card = cardContentHeight(contentHeight, cap: contentCap) + 2 * cardPadding
      return CGSize(width: openWidth, height: bandHeight(g) + cardTopGap + card + bottomInset)
    }
  }

  /// Fläche, auf der die Insel Mausereignisse annimmt (relativ zur Insel-Mitte oben).
  /// Mit Notch etwas großzügiger; ohne Notch im Ruhezustand exakt, damit die
  /// Insel keine Klicks in Fenster direkt unter der Menüleiste schluckt.
  static func hoverInset(mode: IslandMode, geometry g: NotchGeometry) -> CGFloat {
    if !g.hasNotch && (mode == .closed || mode == .peek) { return 0 }
    return 6
  }
}

// MARK: - Stimmung

public enum MascotMood: String, CaseIterable, Sendable {
  case idle, thinking, alert, happy, love, error, sleepy

  /// Akzentfarbe (Glow, Abzeichen) – wie moods.ts der Electron-Version.
  public var color: Color {
    switch self {
    case .idle, .thinking: Color(shellHex: 0x7AA7FF)
    case .alert: Color(shellHex: 0xF5A524)
    case .happy: Color(shellHex: 0x4ADE80)
    case .love: Color(shellHex: 0x2DD4BF)
    case .error: Color(shellHex: 0xF87171)
    case .sleepy: Color(shellHex: 0xA78BFA)
    }
  }
}

enum MoodRules {
  /// So lange hält eine Reaktion (z. B. "Aufgabe erledigt") die Stimmung.
  static let reactionDuration: Double = 2.6
  /// Ab so viel Ruhe (ohne Interaktion/Ereignis, Insel zu) wird Lumi schläfrig.
  static let sleepyAfter: Double = 300

  static func mood(for reaction: UIReaction) -> MascotMood? {
    switch reaction {
    case .taskCompleted, .celebrate: .happy
    case .itemAdded: .love
    case .failed: .error
    case .itemDeleted: nil
    }
  }

  /// Reihenfolge: Freigabe → Nachdenken → frische Reaktion → Flash → Ruhe/Schlaf.
  static func derive(agentPending: Bool, isThinking: Bool, reaction: UIReaction?, reactionAge: Double?,
                     flashActive: Bool, idleFor: Double, islandOpen: Bool) -> MascotMood {
    if agentPending { return .alert }
    if isThinking { return .thinking }
    if let reaction, let age = reactionAge, age >= 0, age < reactionDuration, let m = mood(for: reaction) {
      return m
    }
    if flashActive { return .alert }
    if !islandOpen && idleFor >= sleepyAfter { return .sleepy }
    return .idle
  }
}

// MARK: - Anzeige rechts in der geschlossenen Insel

enum ClosedIndicator: Equatable {
  case attention
  case thinking
  /// Offene Aufgaben: Zähler und Titel der nächsten (überfällig zuerst, sonst heute).
  case count(Int, overdue: Bool)
  case calm
  /// Laufender Fokus-Timer: Countdown neben der Notch.
  case focus(FocusSession)
  /// Laufender Timer: Restzeit in Sekunden (der nächste Timer).
  case timer(remaining: Int)
}

/// Was in der Peek-Ansicht unter der Notch an Bedienknöpfen gebraucht wird.
struct PeekActions: Equatable {
  /// Musik läuft: Zurück / Abspielen-Pause / Weiter.
  var media: Bool
  /// Konferenzlink des nächsten Termins ("Beitreten").
  var join: URL?
}

/// Eine Laufband-Zeile: Art (für die Ausblend-Einstellung), optionales SF-Symbol und Text.
/// Modtexte behalten ihren eigenen Inhalt und bekommen kein Symbol.
struct TickerLine: Equatable {
  var kind: TickerKind
  var symbol: String?
  var text: String
}

/// Anstehender oder laufender Termin mit Konferenzlink (für Laufband und Beitreten-Knopf).
struct MeetingJoin: Equatable {
  var title: String
  /// "HH:mm" des Termins.
  var time: String
  var url: URL
}

enum StatusRules {
  /// Rechter Flügel: nur symbolhafte Anzeigen
  /// (Priorität Freigabe > Denken > Fokus > Timer > Aufgaben > ruhig).
  static func indicator(state: AppState?, agentPending: Bool, isThinking: Bool, now: Date) -> ClosedIndicator {
    if agentPending { return .attention }
    if isThinking { return .thinking }
    if let f = state?.focus { return .focus(f) }
    if let t = nearestTimer(state?.timers ?? [], now: now) { return .timer(remaining: t) }
    if let o = state?.overview {
      let n = o.overdueTasks.count + o.todayTasks.count
      if n > 0 {
        return .count(n, overdue: !o.overdueTasks.isEmpty)
      }
    }
    return .calm
  }

  /// Laufband unter der Notch, in dieser Reihenfolge: Termin mit Beitreten-Link, laufende Musik,
  /// laufender Timer, Mod-Texte, bis zu drei ungelesene Chats (neueste zuerst), eigener Notch-Text.
  /// Arten aus `settings.hiddenTickerKinds` fallen weg. `today` ("YYYY-MM-DD") und `now` kommen aus der Uhr.
  static func tickerLines(state: AppState?, today: String, now: Date) -> [TickerLine] {
    tickerLines(state: state, today: today, now: now, join: meetingJoin(state: state, now: now))
  }

  /// Wie `tickerLines(state:today:now:)`, mit bereits berechnetem Beitreten-Termin (einmal je Takt).
  static func tickerLines(state: AppState?, today: String, now: Date, join: MeetingJoin?) -> [TickerLine] {
    var lines: [TickerLine] = []
    if let join {
      lines.append(TickerLine(kind: .meeting, symbol: "video.fill", text: "\(join.title) · \(join.time)"))
    }
    if let np = state?.nowPlaying { lines.append(nowPlayingLine(np)) }
    if let hit = nearestTimerEntry(state?.timers ?? [], now: now) {
      let label = hit.timer.label.trimmingCharacters(in: .whitespaces)
      lines.append(TickerLine(kind: .timer, symbol: "timer",
                              text: (label.isEmpty ? "Timer" : label) + " · " + FocusClock.format(hit.left)))
    }
    var texts = (state?.islandMessages ?? []).map(\.text)
    if texts.isEmpty, let m = state?.islandMessage { texts = [m.text] }
    lines += texts.filter { !$0.isEmpty }.map { TickerLine(kind: .mods, symbol: nil, text: $0) }
    let needReply = (state?.inbox ?? []).filter { $0.kind == .needsReply }.count
    if needReply > 0 {
      lines.append(TickerLine(kind: .messages, symbol: "arrowshape.turn.up.left.fill", text: "Antwort nötig: \(needReply)"))
    }
    let chats = (state?.messengerConversations ?? [])
      .filter { $0.unread > 0 }
      .sorted { ($0.lastAt ?? "") > ($1.lastAt ?? "") }
      .prefix(3)
      .map { TickerLine(kind: .messages, symbol: "bubble.left.fill",
                        text: "\($0.title): \($0.lastText ?? "neue Nachricht")") }
    lines += chats
    if let s = state?.settings,
       let text = ownNotchText(text: s.notchText, countdown: s.notchCountdown, today: today) {
      lines.append(TickerLine(kind: .ownText, symbol: nil, text: text))
    }
    let hidden = Set(state?.settings.hiddenTickerKinds ?? [])
    return lines.filter { !hidden.contains($0.kind.rawValue) }
      .map { TickerLine(kind: $0.kind, symbol: $0.symbol, text: cutTickerLine($0.text)) }
  }

  /// Musik: Note bei Wiedergabe, Pause-Symbol bei pausierter Musik; ohne Interpret nur der Titel.
  static func nowPlayingLine(_ np: NowPlaying) -> TickerLine {
    let artist = np.artist.trimmingCharacters(in: .whitespaces)
    return TickerLine(kind: .music, symbol: np.playing ? "music.note" : "pause.fill",
                      text: np.title + (artist.isEmpty ? "" : " – " + artist))
  }

  /// Erster https-Link auf einem Konferenz-Host (teams.microsoft.com, zoom.us, meet.google.com,
  /// webex.com, auch deren Subdomains). Andere Schemata und Hosts werden übersprungen.
  static func meetingLink(in text: String) -> URL? {
    let hosts = ["teams.microsoft.com", "zoom.us", "meet.google.com", "webex.com"]
    guard let re = linkExpression else { return nil }
    let ns = text as NSString
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      var raw = ns.substring(with: m.range)
      while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
      guard let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased() else { continue }
      if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
    }
    return nil
  }

  /// Muster einmal übersetzt (vorher bei jedem Aufruf neu kompiliert). Fehlt nur, wenn das Muster ungültig ist.
  private static let linkExpression = try? NSRegularExpression(pattern: #"https://[^\s<>"'\]\)]+"#)

  /// Termin mit Konferenzlink, der jetzt läuft oder höchstens 10 Minuten später beginnt (frühester zuerst).
  /// Ohne Endzeit gilt eine Stunde ab Beginn. Ganztägige Termine zählen nicht.
  static func meetingJoin(state: AppState?, now: Date) -> MeetingJoin? {
    let hits: [(event: CalendarEvent, url: URL, start: Date, end: Date)] = (state?.overview.eventsToday ?? [])
      .filter { !$0.allDay }
      .compactMap { e in
        guard let url = meetingLink(in: [e.title, e.notes ?? ""].joined(separator: " ")),
              let start = LocalTime.parse(e.start) else { return nil }
        let end = e.end.flatMap(LocalTime.parse) ?? start.addingTimeInterval(3600)
        return (e, url, start, end)
      }
    guard let hit = hits
      .filter({ now >= $0.start.addingTimeInterval(-600) && now < $0.end })
      .min(by: { $0.start < $1.start }) else { return nil }
    return MeetingJoin(title: hit.event.title, time: String(hit.event.start.dropFirst(11).prefix(5)), url: hit.url)
  }

  /// Bedienknöpfe der Peek-Ansicht; auch bei pausierter Musik, damit man sie wieder starten kann.
  static func peekActions(state: AppState?, now: Date) -> PeekActions? {
    peekActions(state: state, join: meetingJoin(state: state, now: now))
  }

  /// Wie `peekActions(state:now:)`, mit bereits berechnetem Beitreten-Termin.
  static func peekActions(state: AppState?, join: MeetingJoin?) -> PeekActions? {
    let media = state?.nowPlaying != nil
    let url = join?.url
    return media || url != nil ? PeekActions(media: media, join: url) : nil
  }

  /// Restzeit in Sekunden des Timers, der als Nächstes abläuft; abgelaufene fallen heraus.
  static func nearestTimer(_ timers: [TabyTimer], now: Date) -> Int? {
    nearestTimerEntry(timers, now: now)?.left
  }

  /// Wie `nearestTimer`, aber mit dem Timer selbst (für die Laufbandzeile mit Namen).
  static func nearestTimerEntry(_ timers: [TabyTimer], now: Date) -> (timer: TabyTimer, left: Int)? {
    timers.compactMap { t -> (timer: TabyTimer, left: Int)? in
      guard let end = LocalTime.parse(t.endsAt) else { return nil }
      let left = Int(end.timeIntervalSince(now).rounded(.down))
      return left > 0 ? (t, left) : nil
    }.min { $0.left < $1.left }
  }

  /// Höchstens 48 Zeichen pro Laufband-Zeile (ohne Symbol); der Rest wird mit "…" abgeschnitten.
  static func cutTickerLine(_ line: String) -> String {
    let maxLen = 48
    return line.count > maxLen ? String(line.prefix(maxLen - 1)) + "…" : line
  }

  /// Eigener Notch-Text mit optionalem Countdown, höchstens 40 Zeichen.
  /// Ohne gültiges Zieldatum (leer, falsch oder vergangen) nur der Text; ohne Text nichts.
  static func ownNotchText(text: String, countdown: String, today: String) -> String? {
    let maxLen = 40
    let base = text.trimmingCharacters(in: .whitespaces)
    let part = countdownPart(countdown, today: today)
    guard let part else {
      return base.isEmpty ? nil : String(base.prefix(maxLen))
    }
    if base.isEmpty { return String(part.prefix(maxLen)) }
    // Der Text wird gekürzt, damit der Countdown sichtbar bleibt.
    let room = maxLen - (part.count + 3)  // " · "
    if room < 1 { return String(part.prefix(maxLen)) }
    return String(base.prefix(room)) + " · " + part
  }

  /// "noch N Tage" / "morgen" / "heute"; nil bei leerem, falschem oder vergangenem Datum.
  static func countdownPart(_ countdown: String, today: String) -> String? {
    guard let days = daysUntil(countdown, from: today), days >= 0 else { return nil }
    switch days {
    case 0: return "heute"
    case 1: return "morgen"
    default: return "noch \(days) Tage"
    }
  }

  /// Ganze Tage von `from` bis `target` (beide "YYYY-MM-DD"), nil bei ungültigem Datum.
  static func daysUntil(_ target: String, from today: String) -> Int? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    func date(_ s: String) -> Date? {
      let parts = s.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
      guard s.count == 10, parts.count == 3 else { return nil }
      let (y, m, d) = (parts[0], parts[1], parts[2])
      guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
      let c = cal.dateComponents([.year, .month, .day], from: date)
      // Kalender rollt z. B. 2026-02-31 still weiter; so werden solche Eingaben verworfen.
      return c.year == y && c.month == m && c.day == d ? date : nil
    }
    guard let t = date(target), let n = date(today) else { return nil }
    return cal.dateComponents([.day], from: n, to: t).day
  }

  /// 1–2 kurze Statuszeilen unter dem Reitertitel.
  static func lines(tab: TabyTab, state: AppState?, agentRequests: Int, isThinking: Bool) -> [String] {
    if tab == .agents { return agentRequests > 0 ? ["Freigabe nötig"] : ["Keine offenen Anfragen"] }
    guard let s = state else { return ["Lädt …"] }
    let o = s.overview
    func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    switch tab {
    case .today:
      var l = [plural(o.eventsToday.count, "Termin", "Termine") + " · " + plural(o.todayTasks.count, "Aufgabe", "Aufgaben")]
      if !o.overdueTasks.isEmpty { l.append("\(o.overdueTasks.count) überfällig") }
      return l
    case .chat:
      if isThinking { return ["Denkt nach …"] }
      let model = s.settings.llmModel.split(separator: "/").last.map(String.init) ?? s.settings.llmModel
      return [plural(s.messages.count, "Nachricht", "Nachrichten"), model].filter { !$0.isEmpty }
    case .agents:
      return []
    case .network:
      return [s.network?.info?.ssid ?? "Netzwerk"]
    case .messages:
      let unread = s.messengerConversations.reduce(0) { $0 + $1.unread }
      return [unread > 0 ? "\(unread) ungelesen" : "Nachrichten"]
    case .mail:
      return MailLogic.islandLines(s.mail)
    case .tasks:
      // Heute wie im Heute-Board (überfällig plus heute fällig), dazu alle offenen Aufgaben.
      let todayOpen = o.overdueTasks.count + o.todayTasks.count
      let allOpen = s.tasks.filter { !$0.done }.count
      var l = [TaskLogic.sidebarCount(todayOpen: todayOpen, allOpen: allOpen)]
      if !o.overdueTasks.isEmpty { l.append("\(o.overdueTasks.count) überfällig") }
      return l
    case .notes:
      return [plural(s.notes.count, "Notiz", "Notizen")]
    case .notion:
      let n = s.notionLinkedTasks.filter { !$0.done }.count
      return [n > 0 ? "\(n) offen" : "Notion"]
    case .calendar:
      return [plural(o.eventsToday.count, "Termin", "Termine") + " heute",
              plural(s.calendarSources.filter(\.enabled).count, "Kalender", "Kalender")]
    case .music:
      return [s.nowPlaying.map { $0.artist.isEmpty ? $0.title : "\($0.title) – \($0.artist)" } ?? "Spotify, Apple Musik …"]
    case .mods:
      let on = s.mods.filter { $0.enabled && $0.approved }.count
      return ["\(on) von \(s.mods.count) aktiv"]
    case .settings:
      return [s.settings.hasApiKey ? "Schlüssel gespeichert" : "Kein API-Schlüssel"]
    }
  }

  /// Begrüßung nach Tageszeit.
  static func greeting(hour: Int) -> String {
    switch hour {
    case 5..<11: "Guten Morgen!"
    case 11..<17: "Hallo!"
    case 17..<22: "Guten Abend!"
    default: "Noch wach?"
    }
  }
}

extension Color {
  init(shellHex hex: UInt32, opacity: Double = 1) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}
