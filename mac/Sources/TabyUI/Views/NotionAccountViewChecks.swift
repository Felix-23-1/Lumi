// Prüfungen und Snapshots für die Notion-Zugänge in den Einstellungen: Regeln der Karte,
// Vorschau-Dienst (anlegen, Kategorie, entfernen) und der Zugangscode, der nirgends landet.
import Foundation
import SwiftUI
import TabyCore

enum NotionAccountViewChecks {
  static let legacy = NotionAccount.legacy
  static let privat = NotionAccount(id: "notion-privat", name: "Privat", categoryId: "privat")

  @MainActor static var cases: [CheckCase] {
    [
      CheckCase("Notion-Zugänge: leerer, doppelter (ohne Groß/Klein) und zu langer Name werden abgelehnt") {
        try expectEqual(NotionAccountLogic.nameProblem("  ", others: []), "Gib dem Notion-Zugang einen Namen.")
        try expect(NotionAccountLogic.nameProblem("privat", others: ["Privat"]) != nil, "doppelt ohne Groß/Klein")
        try expect(NotionAccountLogic.nameProblem(String(repeating: "x", count: 25), others: []) != nil, "25 Zeichen zu lang")
        try expectEqual(NotionAccountLogic.nameProblem(" Privat ", others: ["Geschäftlich"]), nil, "gültig, getrimmt")
        try expectEqual(NotionAccountLogic.renameProblem("Geschäftlich", account: legacy, accounts: [legacy, privat]), nil,
                        "eigener Name ist kein Duplikat")
      },
      CheckCase("Notion-Zugänge: höchstens 8, Standard-Zugang nie entfernbar, Kategorie muss in den Einstellungen stehen") {
        try expect(NotionAccountLogic.canAdd(count: 7), "7 Zugänge: noch einer")
        try expect(!NotionAccountLogic.canAdd(count: 8), "8 Zugänge: kein weiterer")
        try expect(!NotionAccountLogic.canRemove(legacy), "Standard-Zugang bleibt")
        try expect(NotionAccountLogic.canRemove(privat), "anderer Zugang entfernbar")
        let defs = TaskCategoryChecks.defs
        let accounts = [legacy]
        try expectEqual(NotionAccountLogic.addProblem(name: "Sport", categoryId: "", token: "t", accounts: accounts, defs: defs),
                        "Wähle eine Kategorie, zu der der Zugang gehören soll.")
        try expect(NotionAccountLogic.addProblem(name: "Sport", categoryId: "gibt-es-nicht", token: "t",
                                                 accounts: accounts, defs: defs) != nil, "unbekannte Kategorie")
        try expectEqual(NotionAccountLogic.addProblem(name: "Sport", categoryId: "sport", token: " ",
                                                      accounts: accounts, defs: defs), "Der Zugangscode fehlt.")
        try expectEqual(NotionAccountLogic.addProblem(name: "Sport", categoryId: "sport", token: "t",
                                                      accounts: accounts, defs: defs), nil, "alles gültig")
        let full = (1...8).map { NotionAccount(id: "a\($0)", name: "Zugang \($0)", categoryId: "arbeit") }
        try expect(NotionAccountLogic.addProblem(name: "Neu", categoryId: "arbeit", token: "t", accounts: full, defs: defs) != nil,
                   "9. Zugang wird abgelehnt")
        try expectEqual(NotionAccountRules.maxCount, 8)
      },
      CheckCase("Notion-Zugänge Vorschau: Beispiel mit Geschäftlich (Arbeit) und Privat (Privat), je eine Quelle") {
        let fake = FakeServices()
        try expectEqual(fake.current.settings.notionAccounts.map(\.categoryId), ["arbeit", "privat"])
        try expectEqual(fake.current.settings.notionAccounts.map(\.name), ["Geschäftlich", "Privat"])
        try expectEqual(fake.current.notionSources.map(\.accountId), [NotionAccount.legacyId, "notion-privat"])
        try expectEqual(fake.current.notionTaskCategories, ["nt-work": "arbeit", "nt-privat": "privat"])
      },
      CheckCase("Notion-Zugänge Vorschau: anlegen, Kategorie ändern verschiebt Aufgaben, entfernen mit und ohne Aufgaben") {
        let fake = FakeServices(sample: false)
        let added = await fake.addNotionAccount(name: "Privat", categoryId: "privat", token: "TESTCODE-1")
        guard case .ok(let account) = added else { try expect(false, "Anlegen fehlgeschlagen"); return }
        try expect(fake.current.notionConnectedAccounts.contains(account.id), "Code gilt als hinterlegt")
        let src = await fake.addNotionSource(name: "Privat", category: .todos, link: "x", accountId: account.id)
        guard case .ok(let source) = src else { try expect(false, "Quelle fehlgeschlagen"); return }
        try expectEqual(source.accountId, account.id, "Quelle gehört zum Zugang")
        fake.current.notionSourceLinks = ["t-priv": source.id]
        fake.current.notionLinkedTasks = [TabyTask(id: "t-priv", title: "Einkauf", createdAt: "")]
        _ = await fake.updateNotionAccount(account.id, name: nil, categoryId: "privat")
        try expectEqual(fake.current.notionTaskCategories, ["t-priv": "privat"], "Aufgabe bei Privat")
        _ = await fake.updateNotionAccount(account.id, name: nil, categoryId: "arbeit")
        try expectEqual(fake.current.notionTaskCategories, ["t-priv": "arbeit"], "Aufgabe wandert mit der Kategorie")
        let kept = await fake.removeNotionAccount(account.id, deleteTasks: false)
        try expect(kept.isOk, "Zugang entfernt, Aufgaben behalten")
        try expectEqual(fake.current.notionTaskCategories, [:], "keine Notion-Aufgabe mehr")
        try expect(fake.current.notionSources.isEmpty, "Quelle mit dem Zugang weg")
        try expectEqual(fake.current.settings.notionAccounts.map(\.id), [NotionAccount.legacyId], "nur der Standard-Zugang bleibt")

        let again = await fake.addNotionAccount(name: "Privat", categoryId: "privat", token: "TESTCODE-2")
        guard case .ok(let second) = again else { try expect(false, "zweites Anlegen fehlgeschlagen"); return }
        fake.current.tasks = [TabyTask(id: "t-del", title: "Wird gelöscht", createdAt: "")]
        let srcAgain = await fake.addNotionSource(name: "Privat", category: .todos, link: "y", accountId: second.id)
        guard case .ok(let sourceAgain) = srcAgain else { try expect(false, "Quelle fehlgeschlagen"); return }
        fake.current.notionSourceLinks = ["t-del": sourceAgain.id]
        fake.current.notionLinkedTasks = [TabyTask(id: "t-del", title: "Wird gelöscht", createdAt: "")]
        _ = await fake.updateNotionAccount(second.id, name: nil, categoryId: "privat")
        let gone = await fake.removeNotionAccount(second.id, deleteTasks: true)
        try expect(gone.isOk, "Zugang mit Aufgaben entfernt")
        try expect(!fake.current.tasks.contains { $0.id == "t-del" }, "Aufgabe gelöscht")
        try expect(fake.current.notionTaskCategories.isEmpty, "keine Zuordnung mehr")

        let legacyRemove = await fake.removeNotionAccount(NotionAccount.legacyId, deleteTasks: true)
        try expect(!legacyRemove.isOk, "Standard-Zugang bleibt, auch mit Aufgaben löschen")
      },
      CheckCase("Notion-Zugänge Vorschau: Validierung wie im Kern (Name, Kategorie, Code, Höchstzahl)") {
        let fake = FakeServices()
        let duplicate = await fake.addNotionAccount(name: "privat", categoryId: "arbeit", token: "t")
        try expect(!duplicate.isOk, "doppelter Name")
        let noCategory = await fake.addNotionAccount(name: "Sport", categoryId: "gibt-es-nicht", token: "t")
        try expect(!noCategory.isOk, "unbekannte Kategorie")
        let noCode = await fake.addNotionAccount(name: "Sport", categoryId: "arbeit", token: "  ")
        try expect(!noCode.isOk, "leerer Code")
        let unknownSource = await fake.addNotionSource(name: "X", category: .tickets, link: "z", accountId: "gibt-es-nicht")
        try expect(!unknownSource.isOk, "Quelle in unbekanntem Zugang")
        _ = await fake.addNotionAccount(name: "Zwei", categoryId: "arbeit", token: "t")
        _ = await fake.addNotionAccount(name: "Drei", categoryId: "arbeit", token: "t")
        _ = await fake.addNotionAccount(name: "Vier", categoryId: "arbeit", token: "t")
        _ = await fake.addNotionAccount(name: "Fünf", categoryId: "arbeit", token: "t")
        _ = await fake.addNotionAccount(name: "Sechs", categoryId: "arbeit", token: "t")
        _ = await fake.addNotionAccount(name: "Sieben", categoryId: "arbeit", token: "t")
        try expectEqual(fake.current.settings.notionAccounts.count, NotionAccountRules.maxCount, "genau 8 Zugänge")
        let tooMany = await fake.addNotionAccount(name: "Acht", categoryId: "arbeit", token: "t")
        try expect(!tooMany.isOk, "9. Zugang abgelehnt")
      },
      CheckCase("Notion-Zugänge Vorschau: der Zugangscode steht weder im Zustand noch in den Einstellungen") {
        let fake = FakeServices()
        let secret = "GEHEIM-TESTCODE-4242"
        let set = await fake.setNotionAccountToken("notion-privat", token: secret)
        let added = await fake.addNotionAccount(name: "Neu", categoryId: "arbeit", token: secret + "-2")
        try expect(set.isOk && added.isOk, "beide Aufrufe gelingen")
        let dump = String(describing: fake.current) + String(describing: fake.current.settings)
        try expect(!dump.contains("GEHEIM"), "kein Zugangscode im Zustand")
        try expect(!dump.contains("TESTCODE"), "kein Zugangscode in den Einstellungen")
      },
    ]
  }

  /// Ein Modell mit geladenem Zustand (Snapshots sind synchron; das Laden läuft auf der Hauptschleife).
  @MainActor static func loaded(_ fake: FakeServices) -> AppModel {
    AppModel(services: fake, preloaded: fake.current)
  }

  @MainActor static func wrap<V: View>(_ v: V, _ model: AppModel) -> AnyView {
    AnyView(v.environmentObject(model).tabyNow(ViewChecks.now).environment(\.tabySnapshot, true))
  }

  @MainActor static var snapshots: [SnapshotSpec] {
    [
      // Zwei Zugänge, je eine Quelle; Privat ohne Zugangscode („Zugangscode fehlt“).
      SnapshotSpec("view-notion-accounts-card", size: CGSize(width: TabLayout.contentWidth, height: 2600)) {
        let fake = FakeServices()
        fake.current.settings.notionTasksEnabled = true
        fake.current.settings.notionAccounts = [
          NotionAccount(id: NotionAccount.legacyId, name: "Geschäftlich", categoryId: "arbeit"),
          NotionAccount(id: "privat", name: "Privat", categoryId: "privat"),
        ]
        fake.current.notionSources = [
          NotionSource(id: "s1", name: "Tickets", category: .tickets, link: "abc", accountId: NotionAccount.legacyId),
          NotionSource(id: "s2", name: "Einkauf", category: .todos, link: "def", accountId: "privat"),
        ]
        fake.current.notionConnectedAccounts = [NotionAccount.legacyId]  // Privat: „Zugangscode fehlt“
        fake.current.notionTasksConnected = true
        let model = loaded(fake)
        let s = fake.current
        var view = SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .accounts)
        view.pageHeight = 2600  // Seite ungekürzt, damit die Notion-Karte im Bild ist
        return wrap(view.tabyPage(), model)
      },
      SnapshotSpec("view-notion-accounts-add", size: CGSize(width: TabLayout.contentWidth, height: 760)) {
        let fake = FakeServices()
        let model = loaded(fake)
        let s = fake.current
        return wrap(NotionAccountAdder(accounts: s.settings.notionAccounts, categories: s.settings.taskCategories,
                                       startOpen: true).tabyPage(), model)
      },
      SnapshotSpec("view-notion-tasks-lines", size: CGSize(width: TabLayout.contentWidth, height: 900)) {
        let fake = FakeServices()
        let model = loaded(fake)
        let s = fake.current
        return wrap(SettingsView(settings: s.settings, sources: s.calendarSources, jobs: s.jobs, page: .tasks).tabyPage(), model)
      },
    ]
  }
}
