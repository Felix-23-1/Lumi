// Prüfungen für Skills: Werkzeug-Einschränkung, lesend als Standard, Freigabe,
// Befehl-Routing im Chat und Prüfung der Eingabe. Der Modell-Aufruf selbst läuft nicht
// (keine Netz- oder Modellgrenze in den Prüfungen); geprüft wird, was dem Modell angeboten wird.
import Foundation

@MainActor
enum SkillChecks {
  static let cases: [CheckCase] = [
    CheckCase("Skill: nur die eigene Werkzeugliste wird angeboten") {
      let m = ModManifest(id: "skill-test-a", name: "Test", description: "d", kind: .skill,
                          prompt: "p", tools: ["list_tasks"], command: "testa")
      let allowed = CoreServices.skillToolFilter(m)
      try expect(allowed("list_tasks"), "erlaubtes Werkzeug fehlt")
      try expect(!allowed("add_task"), "fremdes Werkzeug wird angeboten")
      try expect(!allowed("send_mail"), "Mail-Versand wird angeboten")
    },
    CheckCase("Skill: ohne Liste nur lesende Werkzeuge") {
      let m = ModManifest(id: "skill-test-b", name: "Test", description: "d", kind: .skill,
                          prompt: "p", tools: nil, command: "testb")
      let allowed = CoreServices.skillToolFilter(m)
      for name in ["list_mails", "get_overview", "show_plan", "search_notes"] {
        try expect(allowed(name), "\(name) sollte lesend erlaubt sein")
      }
      for name in ["add_task", "send_mail", "draft_mail", "delete_task"] {
        try expect(!allowed(name), "\(name) darf ohne Liste nicht angeboten werden")
      }
    },
    CheckCase("Skill: Bibliotheks-Skills nennen nur bekannte Werkzeuge und keine Änderung ohne Bestätigung") {
      let known = Set((ToolRegistry.definitions + MailTools.definitions + ContactTools.defs).map(\.name))
      for entry in ModCatalog.skills {
        try expectEqual(entry.manifest.kind, .skill, "Art von „\(entry.id)“")
        try expectEqual(ModValidation.validate(entry.manifest), [], "Manifest „\(entry.id)“")
        for t in entry.manifest.tools ?? [] {
          try expect(known.contains(t), "„\(entry.id)“ nennt unbekanntes Werkzeug „\(t)“")
        }
      }
      let week = ModCatalog.skills.first { $0.id == "wochenplanung" }?.manifest
      try expect(!((week?.tools ?? []).contains { $0.hasPrefix("add_") || $0.hasPrefix("delete_") }),
                 "Wochenplanung legt nichts direkt an")
      let abschluss = ModCatalog.skills.first { $0.id == "tagesabschluss-mail" }?.manifest
      try expect((abschluss?.tools ?? []).contains("draft_mail"), "Tagesabschluss braucht den Entwurf")
    },
    CheckCase("Skill: Entwurf-Werkzeug öffnet nur, sendet nicht") {
      try expect(!MailTools.confirmationRequired.contains("draft_mail"), "Entwurf braucht keine Bestätigung")
      try expect(!MailTools.confirmationRequired.isEmpty && MailTools.confirmationRequired.contains("send_mail"),
                 "Senden bleibt bestätigungspflichtig")
    },
    CheckCase("Skill: Eingabe und Anleitung im Verlauf und Systemprompt") {
      let m = ModManifest(id: "skill-test-c", name: "Wochenplanung", description: "d", kind: .skill,
                          prompt: " Plane gut. ", tools: nil, command: "wochenplan")
      try expectEqual(CoreServices.skillUserText(m, input: "  Montag  "), "/wochenplan Montag")
      try expectEqual(CoreServices.skillUserText(m, input: ""), "/wochenplan")
      try expectEqual(CoreServices.skillNote(m), "Skill „Wochenplanung“: Plane gut.")
    },
    CheckCase("Skill: Eingabe wird geprüft (Anleitung, Befehl, Dubletten)") {
      let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("taby-skillcheck-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: base) }
      var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-16T08:00"),
                                      keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
      opts.modsRoot = base.appendingPathComponent("Mods", isDirectory: true)
      let svc = try CoreServices(options: opts)
      let empty = svc.addSkillMod(name: "Leer", command: "leer", prompt: "  ", tools: [])
      try expect(!empty.isOk, "ohne Anleitung wird nichts angelegt")
      let badCommand = svc.addSkillMod(name: "Befehl", command: "Wo chen", prompt: "x", tools: [])
      try expect(!badCommand.isOk, "Befehl mit Leerzeichen wird abgelehnt")
      let first = svc.addSkillMod(name: "Eins", command: "eins", prompt: "Mach eins.", tools: ["list_tasks"])
      try expect(first.isOk, "gültiger Skill wird angelegt")
      let info = try expectNotNil(first.value, "Skill liefert Eintrag")
      try expect(!info.enabled && !info.approved, "neuer Skill ist aus und ungeprüft")
      try expect(info.code == nil && info.manifest.kind == .skill, "Skill hat keinen Code")
      let dup = svc.addSkillMod(name: "Eins 2", command: "eins", prompt: "Anders.", tools: [])
      try expect(!dup.isOk, "doppelter Befehl wird abgelehnt")
    },
    CheckCase("Skill: ungeprüfter Skill läuft nicht und wird im Chat nicht geroutet") {
      let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("taby-skillrefuse-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: base) }
      var opts = CoreServices.Options(databasePath: nil, socketPath: nil, clock: ControllableClock("2026-10-16T08:00"),
                                      keyStore: InMemoryApiKeyStore(), systemNotifier: SinkNotifier(), plannerInterval: nil)
      opts.modsRoot = base.appendingPathComponent("Mods", isDirectory: true)
      let svc = try CoreServices(options: opts)
      let added = svc.addSkillMod(name: "Probe", command: "probe", prompt: "Tu nichts.", tools: [])
      let id = try expectNotNil(added.value?.id, "Skill-ID")
      try await expectThrows("ausgeschalteter Skill darf nicht laufen") {
        _ = try await svc.runSkill(id, input: "x")
      }
      try expect(svc.skillCall("/probe hallo") == nil, "ausgeschalteter Skill wird nicht geroutet")
      _ = await svc.setModEnabled(id, true)
      let routed = try expectNotNil(svc.skillCall("/probe hallo"), "eingeschalteter, freigegebener Skill wird geroutet")
      try expectEqual(routed.id, id)
      try expectEqual(routed.input, "hallo")
      try expect(svc.skillCall("/unbekannt hallo") == nil, "unbekannter Befehl bleibt normaler Chat")
      try expect(svc.skillCall("probe hallo") == nil, "ohne Schrägstrich kein Skill")
      try expect(svc.skillCall("/") == nil, "nur Schrägstrich kein Skill")
    },
  ]
}
