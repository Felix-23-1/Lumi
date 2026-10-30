// Prüfungen der Microsoft-Karte und der Teams-Karte (reine Regeln, ohne Ansicht).
import Foundation
import TabyCore

enum MicrosoftCardChecks {
  static var cases: [CheckCase] {
    [
      CheckCase("Microsoft-Karte: Client-ID-Form, Anleitung mit fünf Schritten, nur https zum Öffnen") {
        try expect(MicrosoftCardLogic.clientIdProblem("") == nil, "leer ist noch kein Fehler")
        try expect(MicrosoftCardLogic.clientIdProblem("11111111-2222-3333-4444-555555555555") == nil)
        try expectEqual(MicrosoftCardLogic.clientIdProblem("abc"), MicrosoftCardLogic.clientIdFormat)
        try expectEqual(MicrosoftCardLogic.steps.count, 5)
        try expect(MicrosoftCardLogic.openURL("https://microsoft.com/devicelogin") != nil)
        try expect(MicrosoftCardLogic.openURL("http://microsoft.com/devicelogin") == nil, "kein http")
        try expect(MicrosoftCardLogic.openURL("file:///etc/hosts") == nil)
      },

      CheckCase("Microsoft-Karte: Öffnen nur auf Microsoft-Domains, der Host steht als Text dabei") {
        try expect(MicrosoftCardLogic.openURL("https://login.microsoftonline.com/common/oauth2/deviceauth") != nil)
        try expect(MicrosoftCardLogic.openURL("https://www.microsoft.de/devicelogin") != nil)
        try expect(MicrosoftCardLogic.openURL("https://evil-microsoft.com/devicelogin") == nil, "Domain endet nur ähnlich")
        try expect(MicrosoftCardLogic.openURL("https://microsoft.com.evil.example/devicelogin") == nil, "Domain-Trick")
        try expect(MicrosoftCardLogic.openURL("https://evil.example/microsoft.com") == nil, "Name nur im Pfad")
        try expectEqual(MicrosoftCardLogic.host("https://microsoft.com/devicelogin"), "microsoft.com")
        try expectEqual(MicrosoftCardLogic.host("kaputt"), "unbekannt")
        try expect(MicrosoftCardLogic.codeWarning.contains("„Anmelden“"), "Warnung vor fremden Codes")
      },

      CheckCase("Teams-Karte: ohne Microsoft-Anmeldung verweist sie auf die Anleitung, mit Anmeldung verbindet sie") {
        let off = ConnectionLogic.teamsCard(nil, microsoftSignedIn: false)
        try expectEqual(off.detail, "Erst bei Microsoft anmelden: Verbindungen → Microsoft")
        try expectEqual(off.status, .off)
        try expectEqual(off.action, .connectMessenger(.teams))
        let on = ConnectionLogic.teamsCard(nil, microsoftSignedIn: true)
        try expectEqual(on.detail, "Chats über dein Microsoft-Konto")
        try expectEqual(on.action, .connectMessenger(.teams))
      },

      CheckCase("Teams-Karte: verbunden zeigt das Konto und trennt; ein Fehler bleibt sichtbar") {
        let account = MessengerAccount(id: "acc-teams", service: .teams, user: "felix@beispiel.de")
        let connected = ConnectionLogic.teamsCard(account, microsoftSignedIn: true)
        try expectEqual(connected.status, .connected)
        try expectEqual(connected.detail, "felix@beispiel.de")
        try expectEqual(connected.action, .disconnectMessenger("acc-teams"))
        var broken = account
        broken.status = .error("Microsoft bremst gerade. Bitte gleich erneut versuchen.")
        let problem = ConnectionLogic.teamsCard(broken, microsoftSignedIn: true)
        try expectEqual(problem.status, .problem)
        try expectEqual(problem.detail, "Microsoft bremst gerade. Bitte gleich erneut versuchen.")
      },

      CheckCase("Teams-Karte steht in der Liste der Chat-Dienste an dritter Stelle") {
        let cards = ConnectionLogic.messengerCards([], microsoftSignedIn: false)
        try expectEqual(cards.map(\.id), ["imessage", "slack", "teams", "matrix"])
      },
    ]
  }
}
