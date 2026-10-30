// VERTRAG (nur Orchestrator ändert). Port von src/shared/overview.ts,
// src/shared/settings.ts und src/shared/tool-result.ts.
import Foundation

/// Erinnerung mit aufgelöstem Titel der Aufgabe/des Termins (für Briefing/UI).
public struct ReminderWithTitle: Codable, Equatable, Identifiable, Sendable {
  public var reminder: Reminder
  public var title: String
  public var id: String { reminder.id }

  public init(reminder: Reminder, title: String) {
    self.reminder = reminder; self.title = title
  }
}

/// Deterministisch im Code zusammengestellter Stand (get_overview, Briefing).
/// Wird auch in jeden Systemprompt eingebettet.
public struct Overview: Codable, Equatable, Sendable {
  public var overdueTasks: [TabyTask]
  public var todayTasks: [TabyTask]
  public var upcomingTasks: [TabyTask]
  public var habitsToday: [Habit]
  public var eventsToday: [CalendarEvent]
  public var eventsUpcoming: [CalendarEvent]
  public var conflicts: [Conflict]
  public var remindersToday: [ReminderWithTitle]
  public var missed: [ReminderWithTitle]
  public var unreachableCalendarSources: [SourceProblem]

  public init(overdueTasks: [TabyTask] = [], todayTasks: [TabyTask] = [], upcomingTasks: [TabyTask] = [],
              habitsToday: [Habit] = [], eventsToday: [CalendarEvent] = [], eventsUpcoming: [CalendarEvent] = [],
              conflicts: [Conflict] = [], remindersToday: [ReminderWithTitle] = [], missed: [ReminderWithTitle] = [],
              unreachableCalendarSources: [SourceProblem] = []) {
    self.overdueTasks = overdueTasks; self.todayTasks = todayTasks; self.upcomingTasks = upcomingTasks
    self.habitsToday = habitsToday; self.eventsToday = eventsToday; self.eventsUpcoming = eventsUpcoming
    self.conflicts = conflicts; self.remindersToday = remindersToday; self.missed = missed
    self.unreachableCalendarSources = unreachableCalendarSources
  }

  public static let empty = Overview()
}

public struct Briefing: Codable, Equatable, Sendable {
  public var overview: Overview
  /// Vom Modell formuliert, oder regelbasierter Fallback.
  public var text: String
  public var generatedByModel: Bool

  public init(overview: Overview, text: String, generatedByModel: Bool) {
    self.overview = overview; self.text = text; self.generatedByModel = generatedByModel
  }
}

public enum Personality: String, Codable, Sendable, CaseIterable {
  case direkt, ruhig, coach, locker
}

/// Einstellungen ohne Geheimnisse. Der API-Key liegt separat im Schlüsselbund;
/// `hasApiKey` verrät nur, ob einer gesetzt ist, nie den Wert.
public struct TabySettings: Codable, Equatable, Sendable {
  public var llmBaseUrl: String
  public var llmModel: String
  public var hasApiKey: Bool
  public var personality: Personality
  public var customInstructions: String
  /// Standard 10, 0 = aus.
  public var reminderLeadMinutes: Int
  public var startOnLogin: Bool
  /// Standard "Control+Option+Space".
  public var globalShortcut: String
  public var askAfterUnlock: Bool
  // Paket 1 (docs/ROADMAP.md):
  /// Günstiges Modell für Briefing und geplante Aufträge; leer = `llmModel`.
  public var briefingModel: String
  /// Mindestabstand zwischen Terminen in Minuten (0 = aus); zu knapp → Warnung wie Konflikt.
  public var bufferMinutes: Int
  /// Kostenlimits in US-Dollar (0 = kein Limit). Über dem Limit antwortet das Modell nicht mehr.
  public var dailyCostLimitUsd: Double
  public var monthlyCostLimitUsd: Double
  /// Kurzbefehl für die Schnellerfassung (Standard "Control+Option+N").
  public var quickCaptureShortcut: String
  /// Zwei-Wege-Abgleich mit Apple Erinnerungen.
  public var appleRemindersSync: Bool
  /// Liste in Apple Erinnerungen für neue Lumi-Aufgaben; leer = Standardliste.
  public var appleRemindersListId: String
  // Paket 2 (docs/ROADMAP.md):
  /// Tagesabschluss am Abend ("Das ist offen – auf morgen schieben?").
  public var dayEndEnabled: Bool
  /// Uhrzeit des Tagesabschlusses, "HH:mm" (Standard "20:00").
  public var dayEndTime: String
  /// Fokus-Timer: Arbeits- und Pausenlänge in Minuten (Standard 25/5).
  public var focusMinutes: Int
  public var breakMinutes: Int
  /// Zielordner für den Markdown-Export (leer = noch nicht gewählt).
  public var exportFolder: String
  /// MCP-Schnittstelle für Hermes/Claude (lokal, nur dieser Mac).
  public var mcpEnabled: Bool
  // Sprache (Vorlesen mit Apple-Stimmen):
  /// Hauptschalter für alle Ansagen.
  public var voiceEnabled: Bool
  /// Briefing morgens und Tagesabschluss abends vorlesen.
  public var voiceBriefings: Bool
  /// Erinnerungen, anstehende Termine und Terminkonflikte ansagen.
  public var voiceAlerts: Bool
  /// Kennung der Stimme (AVSpeechSynthesisVoice.identifier); leer = deutsche Standardstimme.
  public var voiceName: String
  /// Einrichtungs-Assistent abgeschlossen (oder übersprungen).
  public var onboardingDone: Bool
  /// Paket 4: Standardlänge eines Aufgaben-Blocks beim automatischen Einplanen (5–240).
  public var planBlockMinutes: Int
  /// Meeting-Begleiter: Vorbereitung vor und Stichpunkte nach Terminen.
  public var meetingCompanion: Bool
  /// Minuten vor dem Termin, in denen die Vorbereitung erscheint (1–60).
  public var meetingLeadMinutes: Int
  /// Vorlesen-Knopf: Termine der nächsten so vielen Minuten (5–1440).
  public var readAloudMinutes: Int
  /// Eigene Vorgabe fürs Tagesbriefing (Stil + Muster); leer = eingebaute Vorgabe.
  public var briefingPrompt: String
  /// Kurzbefehl: markierten Text in die Schnellerfassung übernehmen.
  public var captureSelectionShortcut: String
  /// Kurzbefehl zum Sprechen (gedrückt halten).
  public var voiceInputShortcut: String
  /// Wochenplanung (Rückblick + 3 Ziele).
  public var weeklyReviewEnabled: Bool
  /// ISO-Wochentag der Wochenplanung (1 = Montag … 7 = Sonntag).
  public var weeklyReviewDay: Int
  /// Uhrzeit der Wochenplanung, "HH:mm".
  public var weeklyReviewTime: String
  /// Kurzbefehl (App „Kurzbefehle“), der beim Fokus-Start läuft, z. B. „Nicht stören“ an; leer = keiner.
  public var focusShortcutOn: String
  /// Kurzbefehl beim Fokus-Ende; leer = keiner.
  public var focusShortcutOff: String
  /// Bundle-IDs von Apps, die während einer Fokus-Arbeitsphase ausgeblendet werden.
  public var focusHideApps: [String]
  /// Reihenfolge der Reiter in der oberen Leiste (TabyTab.rawValue); leer = Standard.
  public var tabOrder: [String]
  /// Ausgeblendete Reiter (TabyTab.rawValue): stehen nicht in der Leiste, nur unter „Mehr“. Leer = alle sichtbar.
  public var hiddenTabs: [String]
  /// Arbeitszeiten je Wochentag, Index 0 = Montag … 6 = Sonntag: "HH:mm-HH:mm" oder "" (frei).
  /// Standard Mo–Fr 08:00-17:00. Auswertung in `WorkWeek`.
  public var workHours: [String]
  /// Kategorien für Aufgaben und Ordner (Reihenfolge = Anzeige); eingebaut Arbeit und Privat, dazu eigene.
  public var taskCategories: [TaskCategoryDef]
  /// Was in der Mitte der geschlossenen Notch durchrollt; ausgeschaltete Arten (`TickerKind.rawValue`) fehlen. Leer = alles an.
  public var hiddenTickerKinds: [String]
  /// Paket 12: mindestens ein Chat-Dienst verbunden (blendet den Reiter „Nachrichten“ ein).
  public var messengerEnabled: Bool
  /// Eigener Kurztext für die geschlossene Notch (leer = aus), höchstens 40 Zeichen.
  public var notchText: String
  /// Paket „Merk dir das“: holt den Kontext der vordersten App (Safari-Seite, Mail, Finder, markierter Text).
  public var captureContextShortcut: String
  /// „Mit Lumi erklären“ (markierten Text erklären).
  public var explainShortcut: String
  /// Bereich einkreisen und per Sprache fragen.
  public var circleShortcut: String
  /// Notion-Stand (kleingeschrieben) → `TaskStatus.rawValue`; leer = Vorschläge aus `NotionStatusRules`.
  public var notionStatusMap: [String: String]
  /// Paket „Status automatisch“: bei Fokus/Meeting/Feierabend Slack-Status und Element-Präsenz setzen.
  public var autoStatus: Bool
  /// Paket „Privat nebenbei“: Apple-Erinnerungen-Liste für Einkauf/Privates (leer = keine gewählt).
  public var privateListId: String
  /// „Nur lokal“: kein Cloud-Modell, kein Mod-Internet; nur Apple Intelligence bzw. ohne Modell.
  public var localOnly: Bool
  /// Zeitpunkt der Einwilligung in Cloud-Modelle (leer = noch nicht gefragt/abgelehnt).
  public var cloudConsentAt: String
  /// Chatverlauf wird nach so vielen Tagen gelöscht (0 = nie).
  public var chatHistoryDays: Int
  /// Sicherungen und Protokoll (Datenschutz → Protokoll) älter als so viele Tage werden gelöscht (1–365, Standard 7).
  public var backupRetentionDays: Int
  public var auditRetentionDays: Int
  /// Fremde MCP-Server, deren Werkzeuge der Chat nutzen darf (Welle D).
  public var mcpServers: [MCPServerConfig]
  /// Obsidian-/Markdown-Ordner als lokale Wissensquelle (leer = aus).
  public var markdownVaultPath: String
  /// Unterordner im Obsidian-Vault, in den Lumi schreibt (nie außerhalb; Standard "Lumi").
  public var vaultWriteFolder: String
  /// Netzlaufwerke (SMB), siehe `NetworkShare`.
  public var networkShares: [NetworkShare]
  /// Notion-Zugänge (Arbeitsbereiche), siehe `NotionAccount`; immer mindestens der Standard-Zugang.
  public var notionAccounts: [NotionAccount]
  /// Client-ID der Microsoft-App-Registrierung (öffentlicher Client, kein Geheimnis). Leer = Microsoft aus.
  public var microsoftClientId: String
  /// Angemeldetes Microsoft-Konto (Mail-Adresse); leer = nicht verbunden.
  public var microsoftAccount: String
  /// Mail-Zugang: "apple" (Apple Mail per AppleScript) oder "imap" (direkt).
  public var mailBackend: String
  public var imapHost: String
  public var imapUser: String
  /// Wohnort (Ortsname, z. B. „Köln“) für Mods wie das Wetter; leer = keiner.
  public var homeCity: String
  /// Woher Updates kommen: GitHub-Adresse des Repos (z. B. https://github.com/Felix-23-1/Lumi) oder ein
  /// Ordner-Link, unter dem `version.json` und `Taby.dmg` liegen. Leer = `AppUpdate.defaultSource`.
  public var updateSource: String
  /// Optionales Zieldatum "YYYY-MM-DD" für einen Countdown zum Notch-Text (leer = keiner).
  public var notchCountdown: String
  /// Paket 9: Notion-Aufgaben importieren (read-only, kein Schreibzugriff auf Notion).
  public var notionTasksEnabled: Bool
  /// Notion-Datenbank-ID für den Aufgaben-Import (Zeilen = Aufgaben); leer = Seiten-Modus.
  public var notionTasksDatabaseId: String
  /// Notion-Seiten-ID für den Aufgaben-Import (To-do-Blöcke, z. B. eine 1:1-Seite); nur wenn notionTasksDatabaseId leer ist.
  public var notionTasksPageId: String
  /// Paket 5: Mail über Apple Mail (aus, bis der Nutzer es einschaltet).
  public var mailEnabled: Bool
  /// Mail-Inhalte nur auf dem Mac verarbeiten (Apple Intelligence), nie an ein Cloud-Modell.
  public var mailLocalOnly: Bool
  /// Ungelesene/wichtige Mails im Morgen-Briefing nennen (nur Anzahl und Absender).
  public var mailBriefing: Bool
  /// Meldungen aus Claude Code (wartet auf Eingabe / fertig) in der Insel zeigen.
  public var claudeNotify: Bool
  /// Paket 6: Netzwerk-Werkzeuge (Reiter erscheint erst, wenn an).
  public var networkToolsEnabled: Bool
  /// Wächter: meldet unbekannte Geräte im WLAN und wenn das Internet wegfällt.
  public var networkWatch: Bool
  /// Feiertags-Deko am Maskottchen (Weihnachtsmütze, Kürbis, Geburtstagshut).
  public var seasonalDecor: Bool
  /// Geburtstag "MM-DD" für den Partyhut; leer = keiner.
  public var birthday: String

  /// Wert für `briefingModel`: Apples Sprachmodell auf dem Mac (Apple Intelligence).
  public static let appleIntelligenceModel = "apple-intelligence"

  public init(llmBaseUrl: String = "https://openrouter.ai/api/v1", llmModel: String = "", hasApiKey: Bool = false,
              personality: Personality = .direkt, customInstructions: String = "", reminderLeadMinutes: Int = 10,
              startOnLogin: Bool = false, globalShortcut: String = "Control+Option+Space",
              askAfterUnlock: Bool = false, briefingModel: String = "", bufferMinutes: Int = 0,
              dailyCostLimitUsd: Double = 0, monthlyCostLimitUsd: Double = 0,
              quickCaptureShortcut: String = "Control+Option+N", appleRemindersSync: Bool = false,
              appleRemindersListId: String = "", dayEndEnabled: Bool = true, dayEndTime: String = "20:00",
              focusMinutes: Int = 25, breakMinutes: Int = 5, exportFolder: String = "", mcpEnabled: Bool = false,
              voiceEnabled: Bool = false, voiceBriefings: Bool = true, voiceAlerts: Bool = true, voiceName: String = "",
              onboardingDone: Bool = false,
              planBlockMinutes: Int = 30,
              meetingCompanion: Bool = true,
              meetingLeadMinutes: Int = 10,
              readAloudMinutes: Int = 60,
              briefingPrompt: String = "",
              captureSelectionShortcut: String = "Control+Option+C",
              voiceInputShortcut: String = "Control+Option+S",
              weeklyReviewEnabled: Bool = true,
              weeklyReviewDay: Int = 7,
              weeklyReviewTime: String = "18:00",
              focusShortcutOn: String = "",
              focusShortcutOff: String = "",
              focusHideApps: [String] = [],
              tabOrder: [String] = [],
              hiddenTabs: [String] = ["mods", "agents"],
              workHours: [String] = TabySettings.defaultWorkHours,
              taskCategories: [TaskCategoryDef] = TaskCategoryDef.builtIn,
              hiddenTickerKinds: [String] = [],
              messengerEnabled: Bool = false,
              notchText: String = "",
              captureContextShortcut: String = "Control+Option+M",
              explainShortcut: String = "Control+Option+E",
              circleShortcut: String = "Control+Option+K",
              notionStatusMap: [String: String] = [:],
              autoStatus: Bool = false,
              privateListId: String = "",
              localOnly: Bool = false,
              cloudConsentAt: String = "",
              chatHistoryDays: Int = 30,
              backupRetentionDays: Int = 7,
              auditRetentionDays: Int = 7,
              mcpServers: [MCPServerConfig] = [],
              markdownVaultPath: String = "",
              vaultWriteFolder: String = "Lumi",
              networkShares: [NetworkShare] = [],
              notionAccounts: [NotionAccount] = [NotionAccount.legacy],
              microsoftClientId: String = "",
              microsoftAccount: String = "",
              mailBackend: String = "apple",
              imapHost: String = "",
              imapUser: String = "",
              homeCity: String = "",
              updateSource: String = "",
              notchCountdown: String = "",
              notionTasksEnabled: Bool = false,
              notionTasksDatabaseId: String = "",
              notionTasksPageId: String = "",
              mailEnabled: Bool = false,
              mailLocalOnly: Bool = true,
              mailBriefing: Bool = true,
              claudeNotify: Bool = true,
              networkToolsEnabled: Bool = false,
              networkWatch: Bool = false,
              seasonalDecor: Bool = true,
              birthday: String = "") {
    self.llmBaseUrl = llmBaseUrl; self.llmModel = llmModel; self.hasApiKey = hasApiKey
    self.personality = personality; self.customInstructions = customInstructions
    self.reminderLeadMinutes = reminderLeadMinutes; self.startOnLogin = startOnLogin
    self.globalShortcut = globalShortcut; self.askAfterUnlock = askAfterUnlock
    self.briefingModel = briefingModel; self.bufferMinutes = bufferMinutes
    self.dailyCostLimitUsd = dailyCostLimitUsd; self.monthlyCostLimitUsd = monthlyCostLimitUsd
    self.quickCaptureShortcut = quickCaptureShortcut; self.appleRemindersSync = appleRemindersSync
    self.appleRemindersListId = appleRemindersListId
    self.dayEndEnabled = dayEndEnabled; self.dayEndTime = dayEndTime
    self.focusMinutes = focusMinutes; self.breakMinutes = breakMinutes
    self.exportFolder = exportFolder; self.mcpEnabled = mcpEnabled
    self.voiceEnabled = voiceEnabled; self.voiceBriefings = voiceBriefings
    self.voiceAlerts = voiceAlerts; self.voiceName = voiceName
    self.onboardingDone = onboardingDone
    self.planBlockMinutes = planBlockMinutes
    self.meetingCompanion = meetingCompanion
    self.meetingLeadMinutes = meetingLeadMinutes
    self.readAloudMinutes = readAloudMinutes
    self.briefingPrompt = briefingPrompt
    self.captureSelectionShortcut = captureSelectionShortcut
    self.voiceInputShortcut = voiceInputShortcut
    self.weeklyReviewEnabled = weeklyReviewEnabled
    self.weeklyReviewDay = weeklyReviewDay
    self.weeklyReviewTime = weeklyReviewTime
    self.focusShortcutOn = focusShortcutOn
    self.focusShortcutOff = focusShortcutOff
    self.focusHideApps = focusHideApps
    self.tabOrder = tabOrder
    self.hiddenTabs = hiddenTabs
    self.workHours = workHours
    self.taskCategories = taskCategories
    self.hiddenTickerKinds = hiddenTickerKinds
    self.messengerEnabled = messengerEnabled
    self.notchText = notchText
    self.captureContextShortcut = captureContextShortcut
    self.explainShortcut = explainShortcut
    self.circleShortcut = circleShortcut
    self.notionStatusMap = notionStatusMap
    self.autoStatus = autoStatus
    self.privateListId = privateListId
    self.localOnly = localOnly
    self.cloudConsentAt = cloudConsentAt
    self.chatHistoryDays = chatHistoryDays
    self.backupRetentionDays = backupRetentionDays
    self.auditRetentionDays = auditRetentionDays
    self.mcpServers = mcpServers
    self.markdownVaultPath = markdownVaultPath
    self.vaultWriteFolder = vaultWriteFolder
    self.networkShares = networkShares
    self.notionAccounts = notionAccounts
    self.microsoftClientId = microsoftClientId
    self.microsoftAccount = microsoftAccount
    self.mailBackend = mailBackend
    self.imapHost = imapHost
    self.imapUser = imapUser
    self.homeCity = homeCity
    self.updateSource = updateSource
    self.notchCountdown = notchCountdown
    self.notionTasksEnabled = notionTasksEnabled
    self.notionTasksDatabaseId = notionTasksDatabaseId
    self.notionTasksPageId = notionTasksPageId
    self.mailEnabled = mailEnabled
    self.mailLocalOnly = mailLocalOnly
    self.mailBriefing = mailBriefing
    self.claudeNotify = claudeNotify
    self.networkToolsEnabled = networkToolsEnabled
    self.networkWatch = networkWatch
    self.seasonalDecor = seasonalDecor
    self.birthday = birthday
  }

  public static let defaults = TabySettings()
}

/// Teil-Aktualisierung der Einstellungen (nil = unverändert).
public struct SettingsPatch: Equatable, Sendable {
  public var llmBaseUrl: String?
  public var llmModel: String?
  public var personality: Personality?
  public var customInstructions: String?
  public var reminderLeadMinutes: Int?
  public var startOnLogin: Bool?
  public var globalShortcut: String?
  public var askAfterUnlock: Bool?
  public var briefingModel: String?
  public var bufferMinutes: Int?
  public var dailyCostLimitUsd: Double?
  public var monthlyCostLimitUsd: Double?
  public var quickCaptureShortcut: String?
  public var appleRemindersSync: Bool?
  public var appleRemindersListId: String?
  public var dayEndEnabled: Bool?
  public var dayEndTime: String?
  public var focusMinutes: Int?
  public var breakMinutes: Int?
  public var exportFolder: String?
  public var mcpEnabled: Bool?
  public var voiceEnabled: Bool?
  public var voiceBriefings: Bool?
  public var voiceAlerts: Bool?
  public var voiceName: String?
  public var onboardingDone: Bool?
  public var planBlockMinutes: Int?
  public var meetingCompanion: Bool?
  public var meetingLeadMinutes: Int?
  public var readAloudMinutes: Int?
  public var briefingPrompt: String?
  public var captureSelectionShortcut: String?
  public var voiceInputShortcut: String?
  public var weeklyReviewEnabled: Bool?
  public var weeklyReviewDay: Int?
  public var weeklyReviewTime: String?
  public var focusShortcutOn: String?
  public var focusShortcutOff: String?
  public var focusHideApps: [String]?
  public var tabOrder: [String]?
  public var hiddenTabs: [String]?
  public var workHours: [String]?
  public var taskCategories: [TaskCategoryDef]?
  public var hiddenTickerKinds: [String]?
  public var messengerEnabled: Bool?
  public var notchText: String?
  public var captureContextShortcut: String?
  public var explainShortcut: String?
  public var circleShortcut: String?
  public var notionStatusMap: [String: String]?
  public var autoStatus: Bool?
  public var privateListId: String?
  public var localOnly: Bool?
  public var cloudConsentAt: String?
  public var chatHistoryDays: Int?
  public var backupRetentionDays: Int?
  public var auditRetentionDays: Int?
  public var mcpServers: [MCPServerConfig]?
  public var markdownVaultPath: String?
  public var vaultWriteFolder: String?
  public var networkShares: [NetworkShare]?
  public var notionAccounts: [NotionAccount]?
  public var microsoftClientId: String?
  public var microsoftAccount: String?
  public var mailBackend: String?
  public var imapHost: String?
  public var imapUser: String?
  public var homeCity: String?
  public var updateSource: String?
  public var notchCountdown: String?
  public var notionTasksEnabled: Bool?
  public var notionTasksDatabaseId: String?
  public var notionTasksPageId: String?
  public var mailEnabled: Bool?
  public var mailLocalOnly: Bool?
  public var mailBriefing: Bool?
  public var claudeNotify: Bool?
  public var networkToolsEnabled: Bool?
  public var networkWatch: Bool?
  public var seasonalDecor: Bool?
  public var birthday: String?

  public init(llmBaseUrl: String? = nil, llmModel: String? = nil, personality: Personality? = nil,
              customInstructions: String? = nil, reminderLeadMinutes: Int? = nil, startOnLogin: Bool? = nil,
              globalShortcut: String? = nil, askAfterUnlock: Bool? = nil, briefingModel: String? = nil,
              bufferMinutes: Int? = nil, dailyCostLimitUsd: Double? = nil, monthlyCostLimitUsd: Double? = nil,
              quickCaptureShortcut: String? = nil, appleRemindersSync: Bool? = nil,
              appleRemindersListId: String? = nil, dayEndEnabled: Bool? = nil, dayEndTime: String? = nil,
              focusMinutes: Int? = nil, breakMinutes: Int? = nil, exportFolder: String? = nil,
              mcpEnabled: Bool? = nil, voiceEnabled: Bool? = nil, voiceBriefings: Bool? = nil,
              voiceAlerts: Bool? = nil, voiceName: String? = nil, onboardingDone: Bool? = nil,
              planBlockMinutes: Int? = nil,
              meetingCompanion: Bool? = nil,
              meetingLeadMinutes: Int? = nil,
              readAloudMinutes: Int? = nil,
              briefingPrompt: String? = nil,
              captureSelectionShortcut: String? = nil,
              voiceInputShortcut: String? = nil,
              weeklyReviewEnabled: Bool? = nil,
              weeklyReviewDay: Int? = nil,
              weeklyReviewTime: String? = nil,
              focusShortcutOn: String? = nil,
              focusShortcutOff: String? = nil,
              focusHideApps: [String]? = nil,
              tabOrder: [String]? = nil,
              hiddenTabs: [String]? = nil,
              workHours: [String]? = nil,
              taskCategories: [TaskCategoryDef]? = nil,
              hiddenTickerKinds: [String]? = nil,
              messengerEnabled: Bool? = nil,
              notchText: String? = nil,
              captureContextShortcut: String? = nil,
              explainShortcut: String? = nil,
              circleShortcut: String? = nil,
              notionStatusMap: [String: String]? = nil,
              autoStatus: Bool? = nil,
              privateListId: String? = nil,
              localOnly: Bool? = nil,
              cloudConsentAt: String? = nil,
              chatHistoryDays: Int? = nil,
              backupRetentionDays: Int? = nil,
              auditRetentionDays: Int? = nil,
              mcpServers: [MCPServerConfig]? = nil,
              markdownVaultPath: String? = nil,
              vaultWriteFolder: String? = nil,
              networkShares: [NetworkShare]? = nil,
              notionAccounts: [NotionAccount]? = nil,
              microsoftClientId: String? = nil,
              microsoftAccount: String? = nil,
              mailBackend: String? = nil,
              imapHost: String? = nil,
              imapUser: String? = nil,
              homeCity: String? = nil,
              updateSource: String? = nil,
              notchCountdown: String? = nil,
              notionTasksEnabled: Bool? = nil,
              notionTasksDatabaseId: String? = nil,
              notionTasksPageId: String? = nil,
              mailEnabled: Bool? = nil,
              mailLocalOnly: Bool? = nil,
              mailBriefing: Bool? = nil,
              claudeNotify: Bool? = nil,
              networkToolsEnabled: Bool? = nil,
              networkWatch: Bool? = nil,
              seasonalDecor: Bool? = nil,
              birthday: String? = nil) {
    self.llmBaseUrl = llmBaseUrl; self.llmModel = llmModel; self.personality = personality
    self.customInstructions = customInstructions; self.reminderLeadMinutes = reminderLeadMinutes
    self.startOnLogin = startOnLogin; self.globalShortcut = globalShortcut; self.askAfterUnlock = askAfterUnlock
    self.briefingModel = briefingModel; self.bufferMinutes = bufferMinutes
    self.dailyCostLimitUsd = dailyCostLimitUsd; self.monthlyCostLimitUsd = monthlyCostLimitUsd
    self.quickCaptureShortcut = quickCaptureShortcut; self.appleRemindersSync = appleRemindersSync
    self.appleRemindersListId = appleRemindersListId
    self.dayEndEnabled = dayEndEnabled; self.dayEndTime = dayEndTime
    self.focusMinutes = focusMinutes; self.breakMinutes = breakMinutes
    self.exportFolder = exportFolder; self.mcpEnabled = mcpEnabled
    self.voiceEnabled = voiceEnabled; self.voiceBriefings = voiceBriefings
    self.voiceAlerts = voiceAlerts; self.voiceName = voiceName
    self.onboardingDone = onboardingDone
    self.planBlockMinutes = planBlockMinutes
    self.meetingCompanion = meetingCompanion
    self.meetingLeadMinutes = meetingLeadMinutes
    self.readAloudMinutes = readAloudMinutes
    self.briefingPrompt = briefingPrompt
    self.captureSelectionShortcut = captureSelectionShortcut
    self.voiceInputShortcut = voiceInputShortcut
    self.weeklyReviewEnabled = weeklyReviewEnabled
    self.weeklyReviewDay = weeklyReviewDay
    self.weeklyReviewTime = weeklyReviewTime
    self.focusShortcutOn = focusShortcutOn
    self.focusShortcutOff = focusShortcutOff
    self.focusHideApps = focusHideApps
    self.tabOrder = tabOrder
    self.hiddenTabs = hiddenTabs
    self.workHours = workHours
    self.taskCategories = taskCategories
    self.hiddenTickerKinds = hiddenTickerKinds
    self.messengerEnabled = messengerEnabled
    self.notchText = notchText
    self.captureContextShortcut = captureContextShortcut
    self.explainShortcut = explainShortcut
    self.circleShortcut = circleShortcut
    self.notionStatusMap = notionStatusMap
    self.autoStatus = autoStatus
    self.privateListId = privateListId
    self.localOnly = localOnly
    self.cloudConsentAt = cloudConsentAt
    self.chatHistoryDays = chatHistoryDays
    self.backupRetentionDays = backupRetentionDays
    self.auditRetentionDays = auditRetentionDays
    self.mcpServers = mcpServers
    self.markdownVaultPath = markdownVaultPath
    self.vaultWriteFolder = vaultWriteFolder
    self.networkShares = networkShares
    self.notionAccounts = notionAccounts
    self.microsoftClientId = microsoftClientId
    self.microsoftAccount = microsoftAccount
    self.mailBackend = mailBackend
    self.imapHost = imapHost
    self.imapUser = imapUser
    self.homeCity = homeCity
    self.updateSource = updateSource
    self.notchCountdown = notchCountdown
    self.notionTasksEnabled = notionTasksEnabled
    self.notionTasksDatabaseId = notionTasksDatabaseId
    self.notionTasksPageId = notionTasksPageId
    self.mailEnabled = mailEnabled
    self.mailLocalOnly = mailLocalOnly
    self.mailBriefing = mailBriefing
    self.claudeNotify = claudeNotify
    self.networkToolsEnabled = networkToolsEnabled
    self.networkWatch = networkWatch
    self.seasonalDecor = seasonalDecor
    self.birthday = birthday
  }
}

/// Ergebnis einer Aktion: Erfolg mit Wert, oder Fehlercode + deutsche Meldung.
public enum ToolResult<Value> {
  case ok(Value)
  case failure(code: String, error: String)

  public var value: Value? { if case .ok(let v) = self { return v }; return nil }
  public var isOk: Bool { if case .ok = self { return true }; return false }
  public var errorMessage: String? { if case .failure(_, let e) = self { return e }; return nil }
}

extension ToolResult: Equatable where Value: Equatable {}
extension ToolResult: Sendable where Value: Sendable {}

/// Platzhalter für Ergebnisse ohne Nutzlast (`ToolResult<Empty>`).
public struct Empty: Equatable, Sendable {
  public init() {}
}

/// Arten der Zeilen, die in der geschlossenen Notch durchrollen (Einstellung `hiddenTickerKinds`).
public enum TickerKind: String, CaseIterable, Sendable {
  case mods, messages, music, timer, meeting, ownText

  public var title: String {
    switch self {
    case .mods: "Wetter & Mods"
    case .messages: "Nachrichten"
    case .music: "Musik"
    case .timer: "Timer"
    case .meeting: "Meetings"
    case .ownText: "Eigener Text"
    }
  }
}

/// Fremder MCP-Server (stdio-Befehl). Seine Werkzeuge erscheinen im Chat als "mcp_<id>_<name>".
public struct MCPServerConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  /// Ausführbare Datei (absoluter Pfad), z. B. /opt/homebrew/bin/npx.
  public var command: String
  public var args: [String]
  public var enabled: Bool
  /// Schreibende Werkzeuge erlaubt (immer mit Bestätigung); aus = nur lesende.
  public var allowWrite: Bool
  public init(id: String, name: String, command: String, args: [String] = [], enabled: Bool = true,
              allowWrite: Bool = false) {
    self.id = id; self.name = name; self.command = command; self.args = args; self.enabled = enabled
    self.allowWrite = allowWrite
  }
}

extension TabySettings {
  /// Mo–Fr 08:00–17:00, Wochenende frei.
  public static let defaultWorkHours = Array(repeating: "08:00-17:00", count: 5) + ["", ""]
}

/// Arbeitszeiten auswerten (`TabySettings.workHours`).
public enum WorkWeek {
  /// Montag = 0 … Sonntag = 6 für ein Datum "yyyy-MM-dd".
  public static func weekdayIndex(_ date: String) -> Int? {
    guard let d = LocalTime.parse(LocalTime.datePart(date)) else { return nil }
    let w = Calendar(identifier: .gregorian).component(.weekday, from: d)  // So = 1
    return (w + 5) % 7
  }

  /// Arbeitszeit an diesem Tag ("HH:mm", "HH:mm") oder nil (frei oder ungültig).
  public static func hours(_ settings: TabySettings, date: String) -> (start: String, end: String)? {
    guard let i = weekdayIndex(date), settings.workHours.indices.contains(i) else { return nil }
    return parse(settings.workHours[i])
  }

  public static func isWorkday(_ settings: TabySettings, date: String) -> Bool { hours(settings, date: date) != nil }

  /// "08:00-17:00" → ("08:00", "17:00"); Ende muss nach Beginn liegen.
  public static func parse(_ text: String) -> (start: String, end: String)? {
    let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, valid(parts[0]), valid(parts[1]), parts[0] < parts[1] else { return nil }
    return (parts[0], parts[1])
  }

  static func valid(_ t: String) -> Bool {
    let p = t.split(separator: ":")
    guard t.count == 5, p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
    return (0...23).contains(h) && (0...59).contains(m)
  }

  /// Ein Satz für den Systemtext, z. B. "Mo–Do 08:00–17:00, Fr 08:00–13:00; Sa, So frei".
  public static func summary(_ settings: TabySettings) -> String {
    let names = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    var groups: [(days: [String], hours: String)] = []
    for (i, h) in settings.workHours.prefix(7).enumerated() {
      let label = parse(h).map { "\($0.start)–\($0.end)" } ?? "frei"
      if let last = groups.last, last.hours == label { groups[groups.count - 1].days.append(names[i]) }
      else { groups.append(([names[i]], label)) }
    }
    return groups.map { g in
      let days = g.days.count > 2 ? "\(g.days.first!)–\(g.days.last!)" : g.days.joined(separator: ", ")
      return "\(days) \(g.hours)"
    }.joined(separator: ", ")
  }
}
