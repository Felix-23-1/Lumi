# 0005: Agenten-Reiter — Claude-Code-Freigabe über lokalen Hook-Server

**Entscheidung:** Der bisherige Platzhalter-Reiter "Agenten" (ADR 0004) wird
durch eine echte Anbindung an Claude Codes `PermissionRequest`-Hook ersetzt:
Taby kann sich auf Klick in `~/.claude/settings.json` eintragen und zeigt
dann Freigabe-Anfragen aller laufenden Claude-Code-Sitzungen als Allow/Deny-
Karten im Reiter.

**Warum:** Direkte Fortsetzung des vom Nutzer gewünschten "Agenten"-Features
(ADR 0004), recherchiert anhand der MIT-lizenzierten Referenz-App "Coucou"
(deren Hook-Protokoll real gegen Claude Code läuft) und verifiziert gegen die
aktuelle offizielle Hooks-Referenz (docs.claude.com/en/docs/claude-code/hooks,
abgerufen 2026-10-11). Das tatsächliche Antwortschema unterscheidet sich von
Coucous vereinfachter Doku (siehe unten) — hier zählt die offizielle Referenz.

**Technische Umsetzung:**
- `src/main/agents/hookServer.ts`: Unix-Domain-Socket-Server (`node:net`),
  läuft immer, solange Taby läuft (unabhängig vom Eintrag in settings.json —
  ohne Eintrag verbindet sich niemand). Pro Anfrage wird eine Promise-artige
  Wartestelle offengehalten (Timeout 110s, knapp unter dem registrierten
  Hook-Timeout von 120s), bis `resolveAgentRequest(id, decision)` aufgerufen
  wird oder der Timeout greift (dann: Verbindung ohne Antwort schließen →
  Claude Code fällt auf den normalen Terminal-Dialog zurück).
- `resources/taby-hook-relay.cjs`: abhängigkeitsfreies, eigenständiges
  CommonJS-Skript (läuft via `node`, außerhalb von Electron). Liest das
  Event-JSON von stdin (von Claude Code geliefert), verbindet sich mit dem
  Taby-Socket, leitet es weiter, gibt die Antwortzeile unverändert auf
  stdout aus. Ist der Socket nicht erreichbar (Taby zu), schlägt `connect`
  sofort fehl (kein manueller Timeout nötig) → leerer Exit 0 → normaler
  Freigabe-Dialog im Terminal. End-to-End gegen einen echten Unix-Socket
  getestet (siehe Sitzungsverlauf), inkl. Fail-Fast-Fall.
- **Echtes Antwortschema** (laut aktueller Hooks-Referenz, nicht Coucous
  vereinfachter Doku):
  ```json
  {
    "hookSpecificOutput": {
      "hookEventName": "PermissionRequest",
      "decision": { "behavior": "allow" | "deny", "message"?: "..." }
    }
  }
  ```
  `updatedInput`/`updatedPermissions` (Input-Patch, Regel-Updates) werden
  bewusst nicht unterstützt — YAGNI, Taby erlaubt/verweigert nur.
- `src/main/agents/installHooks.ts`: liest/schreibt `~/.claude/settings.json`
  idempotent (nur `fs`/`os`/`path`, keine Abhängigkeit). Erkennt eigene
  Einträge am Relay-Skript-Pfad im `args`-Feld, entfernt nur diese vor dem
  Neuanlegen — fremde Hook-Gruppen (eigene Skripte des Nutzers, andere
  Tools) bleiben unberührt. Getestet gegen ein Fake-`$HOME` inkl.
  Zweifach-Install (keine Duplikate) und Uninstall (fremder Eintrag bleibt).
  **Nur auf expliziten Klick im Reiter** — nie automatisch beim App-Start,
  da es eine globale, für alle Projekte geltende Datei des Nutzers ändert.
- Nur **ein** Hook-Event registriert: `PermissionRequest`, Matcher `*`
  (alle Werkzeuge). Die Hooks-Referenz listet weit mehr Events (SessionStart,
  PreToolUse, Notification, …) als Coucous Pill-Lebenszyklus nutzt — für
  Tabys MVP reicht die Freigabe-Karte, der kosmetische Status-Ticker
  (idle/thinking/working) ist bewusst nicht gebaut (YAGNI, kann später
  ergänzt werden).
- `resources/**/*` wird jetzt mit ins `files`-Glob von
  `electron-builder.yml` aufgenommen (zusammen mit dem schon vorhandenen,
  bis dahin ungenutzten `asarUnpack: resources/**`), damit das Relay-Skript
  im gepackten `.app` als echte Datei existiert und von `node` gestartet
  werden kann. `relayScriptPath()` in `appContext.ts` unterscheidet
  Entwicklung (`app.getAppPath()/resources/...`) und gepackte App
  (`process.resourcesPath/app.asar.unpacked/resources/...`).
- Neue IPC-Kanäle `agents:status`, `agents:install`, `agents:uninstall`,
  `agents:resolve` plus Ereignisse `agent:request`/`agent:requestClosed`
  (Main → Renderer) in `src/shared/ipc.ts`. `AgentsTab.tsx` zeigt
  Installieren/Deinstallieren-Knopf und die offenen Anfragen als Karten.

**Nachtrag — Verhalten aus dem echten Coucou-Code übernommen (nicht nur aus
der Demo-GIF abgeleitet):** Auf Nutzerwunsch wurde `IslandWindowController.swift`
und der `HookServer.swift`-Ausschnitt rund um `pendingApproval` gezielt
gelesen (Code, keine Assets/Mascot-Zeichnung — siehe Lizenz oben). Übernommen,
weil es reines Verhalten ist, kein geschütztes Design:
- **"Approval always forces the island open"** (wörtlicher Kommentar im
  Original): eine neue Freigabe-Anfrage klappt die Kapsel automatisch auf
  und springt direkt zum Agenten-Reiter (`App.tsx`: `onAgentRequest` setzt
  `setExpanded(true)` + `setTab('agents')`), statt dass man selbst hinklicken
  muss.
- **Immer nur eine Anfrage gleichzeitig, keine Warteschlange:** trifft eine
  neue Anfrage ein, während eine andere noch offen ist, verdrängt die neue
  die alte — die alte bekommt keine Antwort und fällt im Terminal der
  jeweiligen Claude-Code-Sitzung auf den normalen Dialog zurück (Original:
  schreibt `"ask"`, Taby: schließt die Verbindung ohne Daten, gleiche
  Wirkung). Umgesetzt in `hookServer.ts` (`dismiss(id)`) und als Policy in
  `appContext.ts` (`currentRequestId`). End-to-End mit zwei echten
  Relay-Prozessen gegen einen echten Socket getestet (siehe
  Sitzungsverlauf): verdrängte Anfrage → leerer Output; aktuelle Anfrage →
  echte Entscheidung.
- **Asymmetrische Auf-/Zuklapp-Animation:** Original nutzt beim Zuklappen
  `timingCurve(.45,0,.2,1)` über 0.34s (reines Abbremsen), beim Aufklappen
  `spring(response:0.5, dampingFraction:0.72)` (leichtes Überschwingen).
  In `styles.css` als zwei `.fade`-Transition-Varianten nachgebaut
  (`.fade` = zu, `.fade:not(.is-hidden)` = auf) — CSS übernimmt dafür
  automatisch die Transition des jeweiligen Zielzustands.
- **"Always"-Freigabe-Option bewusst nicht übernommen** (Original bietet sie
  für Agenten, die `updatedPermissions` unterstützen): hätte bedeutet, dass
  Taby selbst Freigabe-Regeln in Claude Codes Einstellungen zurückschreibt —
  YAGNI für den aktuellen Bedarf (Allow/Deny reicht), kann bei Bedarf
  ergänzt werden.
- Maskottchen/Farben/Name bleiben Tabys eigene (`TabyFace.tsx`, bestehende
  CSS-Variablen) — nur das Verhalten (Timing, Fokus-Erzwingung,
  Verdrängungslogik) kommt aus dem Original.

**Nicht verifiziert (nur aus dieser Linux-Sitzung geprüft, siehe
docs/BLOCKERS.md):**
- Realer Claude-Code-Lauf gegen einen tatsächlich installierten Hook-Eintrag
  (nur der Socket-Server + das Relay-Skript wurden end-to-end getestet, mit
  einem von Hand nachgebauten Beispiel-Payload — nicht mit einer echten
  Claude-Code-`PermissionRequest` aus einer laufenden Sitzung).
- Ob `node` auf dem PATH der Umgebung liegt, in der Claude Code den Hook
  ausführt (auf jedem System mit installiertem Claude Code sollte Node
  vorhanden sein, aber nicht am echten Mac geprüft).
- Verhalten bei mehreren parallelen Claude-Code-Sitzungen (mehrere offene
  Anfragen gleichzeitig) — die UI zeigt mehrere Karten, aber nicht mit
  mehreren echten Sitzungen getestet.

## Paket 5: Meldungen aus Claude Code (Hooks `Notification` und `Stop`)

- `ClaudeHookInstaller.install` trägt das Relay zusätzlich für `Notification`
  und `Stop` ein (ohne Matcher, gleiche Handler-Form, Timeout 120 s). Idempotent,
  fremde Einträge bleiben. `uninstall` entfernt eigene Einträge aus allen drei
  Ereignissen. `noticesInstalled` prüft beide Meldungs-Ereignisse; `isInstalled`
  bleibt unverändert auf `PermissionRequest` bezogen.
- `AgentHookServer` bekommt `onNotice` (optional). Meldungen werden nie
  beantwortet: die Verbindung schließt sofort, das Relay endet still mit Exit 0.
  Meldungen verdrängen keine offene Freigabe-Anfrage.
  `Notification` → `needsInput` (Text aus `message`), `Stop` mit
  `stop_hook_active != true` → `finished`. Unbekannte Ereignisse werden verworfen.
- Dublette: Eine `Notification` mit „permission“ im Text wird verworfen, solange
  eine Freigabe-Anfrage offen ist (die Karte zeigt die Anfrage bereits).
- Relay: Bei Ereignissen außer `PermissionRequest` gilt eine Empfangsfrist von
  3 s statt 118 s. Ohne `hook_event_name` gilt die Freigabe-Frist.
- Nicht getestet: echter Lauf aus Claude Code (Hook-Auslösung, tatsächlicher
  Wortlaut von `message` in der jeweiligen Claude-Code-Version).
