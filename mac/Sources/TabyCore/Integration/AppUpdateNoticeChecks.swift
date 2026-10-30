// Prüfungen für den Update-Hinweis: Versionsname, Notizen aus version.json, Signatur mit und ohne
// Notizen und der Benachrichtigungstext. Die Antworten kommen aus AppUpdateRig (IntegrationChecks.swift).
import CryptoKit
import Foundation

enum AppUpdateNoticeChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Versionsname: Build 0 ist 2.0, Build 527 ist 2.527") {
        try expectEqual(AppUpdate.versionName(build: 0), "2.0")
        try expectEqual(AppUpdate.versionName(build: 527), "2.527")
        let u = AppUpdate(commit: "def5678", date: "2026-10-18T10:42", currentCommit: "abc1234", build: 531, currentBuild: 0)
        try expectEqual(u.versionName, "2.531")
        try expectEqual(u.currentVersionName, "2.0")
      },
      CheckCase("Update-Notizen: Steuerzeichen raus, Zeilenumbruch bleibt, höchstens 600 Zeichen, leer ist nil") {
        try expectEqual(CoreServices.cleanNotes(nil), nil)
        try expectEqual(CoreServices.cleanNotes(" \n "), nil)
        try expectEqual(CoreServices.cleanNotes("a\u{7}b\u{0}c\r\nd"), "abc\r\nd")
        try expectEqual(CoreServices.cleanNotes(String(repeating: "x", count: 700))?.count, 600)
      },
      CheckCase("Update-Prüfung: Notizen kommen mit, fehlen sie, bleibt es nil") {
        let withNotes = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00","notes":"Neu: Obsidian\u0007\n<b>Test</b>"}"#)])
        guard case .ok(let found?) = await withNotes.svc.checkForUpdate() else {
          try expect(false, "Update erwartet")
          return
        }
        try expectEqual(found.notes, "Neu: Obsidian\n<b>Test</b>")
        let plain = try await AppUpdateRig.make(replies: [.json(status: 200, body: #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00"}"#)])
        guard case .ok(let bare?) = await plain.svc.checkForUpdate() else {
          try expect(false, "Update erwartet")
          return
        }
        try expectEqual(bare.notes, nil)
      },
      CheckCase("Update-Signatur: mit und ohne Notizen gleich gültig, Notizen gehören nicht zur Signatur") {
        let owner = Curve25519.Signing.PrivateKey()
        let pub = owner.publicKey.rawRepresentation.base64EncodedString()
        let dmg = Data("fake dmg".utf8)
        let sha = UpdateSignature.sha256Hex(dmg)
        let sig = try owner.signature(for: UpdateSignature.message(build: 6, commit: "def5678", sha256: sha)).base64EncodedString()
        let plain = #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00","sha256":"\#(sha)","signature":"\#(sig)"}"#
        let noted = #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00","sha256":"\#(sha)","signature":"\#(sig)","notes":"Neu: Etwas\n"}"#
        for json in [plain, noted] {
          let info = try JSONDecoder().decode(UpdateVersion.self, from: Data(json.utf8))
          try UpdateSignature.check(info, dmg: dmg, currentBuild: 5, publicKey: pub)
        }
      },
      CheckCase("Update-Hinweis: Text nennt die Version und den Weg in die Einstellungen") {
        let defaults = UserDefaults(suiteName: "taby-update-notice-\(UUID().uuidString)")!
        let reply = StubReply.json(status: 200, body: #"{"commit":"def5678","build":6,"date":"2026-10-14T10:00"}"#)
        let rig = try await AppUpdateRig.make(replies: [reply], defaults: defaults)
        await rig.svc.quietUpdateCheck()
        try expectEqual(rig.sink.sent.map(\.body), ["Lumi 2.6 ist da – Einstellungen → Updates."])
      },
    ]
  }
}
