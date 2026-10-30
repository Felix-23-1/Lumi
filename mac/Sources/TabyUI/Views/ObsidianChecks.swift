// Prüfungen und Snapshots für Obsidian: Status, Ordnerprüfung, Titel, Ablegen (gegen FakeServices).
import Foundation
import SwiftUI
import TabyCore

enum ObsidianChecks {
  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Obsidian: Status-Text und Notizanzahl (1 Notiz / N Notizen)") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        try expect(!ObsidianLogic.isConnected(s))
        try expectEqual(ObsidianLogic.statusText(s), "nicht verbunden")
        try expectEqual(ConnectionLogic.obsidianCard(s).status, .off)
        s.settings.markdownVaultPath = "/Users/x/Vault"
        s.vaultNoteCount = 12
        try expectEqual(ObsidianLogic.statusText(s), "verbunden · 12 Notizen")
        s.vaultNoteCount = 1
        try expectEqual(ObsidianLogic.statusText(s), "verbunden · 1 Notiz")
        let card = ConnectionLogic.cards(s).last
        try expectEqual(card?.id, "obsidian")
        try expectEqual(card?.status, .connected)
        try expectEqual(card?.action, .obsidian)
      },
      CheckCase("Obsidian: Actions sind ohne Vault aus (kein Pfad oder nur Leerzeichen)") {
        var s = FakeServices(sample: false).current
        s.settings = TabySettings.defaults
        try expect(!ObsidianLogic.isConnected(nil))
        try expect(!ObsidianLogic.isConnected(s))
        s.settings.markdownVaultPath = "   "
        try expect(!ObsidianLogic.isConnected(s))
        try expect(!ObsidianLogic.isConnected(path: ""))
        s.settings.markdownVaultPath = "/Users/x/Vault"
        try expect(ObsidianLogic.isConnected(s))
      },
      CheckCase("Obsidian: Schreibordner nur relativ ohne „..“") {
        try expect(ObsidianLogic.writeFolderError("Lumi") == nil)
        try expect(ObsidianLogic.writeFolderError("Inbox/Lumi") == nil)
        try expect(ObsidianLogic.writeFolderError("") != nil)
        try expect(ObsidianLogic.writeFolderError("   ") != nil)
        try expect(ObsidianLogic.writeFolderError("/etc") != nil)
        try expect(ObsidianLogic.writeFolderError("~/Notizen") != nil)
        try expect(ObsidianLogic.writeFolderError("../Privat") != nil)
        try expect(ObsidianLogic.writeFolderError("Lumi/../../Privat") != nil)
      },
      CheckCase("Obsidian: Besprechungsnotiz heißt „<Termin> – <Datum>“") {
        try expectEqual(ObsidianLogic.meetingNoteTitle(title: "Kunde X", start: "2026-10-11T09:00"),
                        "Kunde X – 11.10.2026")
      },
      CheckCase("Obsidian: Ablegen schreibt in den Vault, zählt die Notiz und meldet den Dateinamen") {
        let fake = FakeServices(sample: false)
        fake.current.settings.markdownVaultPath = "/Users/x/Vault"
        let model = AppModel(services: fake)
        let before = fake.current.vaultNoteCount
        let error = await ObsidianActions.saveNote(model, title: "Ideen", content: "Text")
        try expect(error == nil)
        try expectEqual(fake.current.vaultNoteCount, before + 1)
        try expectEqual(model.flash?.title, "In Obsidian abgelegt: Ideen.md")
      },
      CheckCase("Obsidian: abgelegte Datei wird als Notiz ohne Endung gespeichert und die Ablage geleert") {
        let fake = FakeServices(sample: false)
        fake.current.settings.markdownVaultPath = "/Users/x/Vault"
        let model = AppModel(services: fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Angebot-Pruefung.txt")
        try "Hallo Welt".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        model.droppedFiles = [url.path]
        await ObsidianActions.saveDroppedFiles(model)
        try expect(model.droppedFiles.isEmpty)
        try expectEqual(model.flash?.title, "In Obsidian abgelegt: Angebot-Pruefung.md")
      },
    ]
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      // Verbindungen mit verbundenem Vault: Karte mit Ordnername, Notizanzahl und Unterordner-Feld.
      SnapshotSpec("view-settings-page-connect-obsidian", size: CGSize(width: TabLayout.contentWidth, height: 1150)) {
        let fake = FakeServices()
        fake.current.settings.markdownVaultPath = "/Users/felix/Documents/Obsidian/Wissen"
        let model = AppModel(services: fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs,
                                page: .connections, privacyState: s)
        view.pageHeight = 1130
        return ViewSnapshots.wrapPicker(view.tabyPage().frame(maxHeight: .infinity, alignment: .top), model)
      },
      // Chat mit abgelegter Datei: Karte mit „In Obsidian“ (Notch-Breite).
      SnapshotSpec("view-chat-file-obsidian", size: ViewSnapshots.size) {
        let fake = FakeServices()
        fake.current.settings.markdownVaultPath = "/Users/felix/Documents/Obsidian/Wissen"
        let model = AppModel(services: fake)
        model.droppedFiles = ["/Users/felix/Desktop/Angebot-Kunde-X.pdf"]
        let page = ChatView(state: fake.current).tabyPage()
        return ViewSnapshots.wrapPicker(page, model)
      },
    ]
  }
}
