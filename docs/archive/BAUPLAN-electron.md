# Bauplan: Desktop-Assistent (Arbeitstitel „Assistent“)

Dieses Dokument ist die Bauanleitung für Claude Code. Es ist so geschrieben, dass ein Orchestrator mit mehreren Subagenten daraus eine **lauffähige macOS-App** baut, die alles Beschriebene wirklich kann und deren Funktionen **automatisiert getestet** sind. Abschnitt 13 beschreibt die Aufteilung auf Subagenten, Abschnitt 14 die Fertig-Kriterien.

Sprache der App und der Texte für den Nutzer: **Deutsch**. Code, Bezeichner und Commit-Nachrichten: Englisch.

---

## 0. Kurzfassung in zehn Sätzen

1. Eine Electron-App für macOS mit Tray-Symbol, kleinem Fenster, Kurzbefehl und Start bei Anmeldung.
2. Sie verwaltet Aufgaben, Notizen, Habits und Termine lokal in SQLite.
3. Ein Chat-Assistent bedient diese Daten über **Werkzeuge** (Function Calling).
4. Das Modell ist frei wählbar: eigener OpenRouter-Key, Modellname in den Einstellungen, jeder OpenAI-kompatible Endpunkt geht.
5. Kalender sind **Module** (Lokal, Apple Kalender, Notion-Datenbank, ICS-Link) mit gemeinsamer Schnittstelle.
6. Beim Eintragen eines Termins prüft **Code** (nicht das Modell) auf Überschneidungen und warnt konkret.
7. Nach der Anmeldung am Mac fragt der Assistent einmal pro Tag: „Bist du bereit für heute?“. Erst nach „Ja“ wird das Modell aufgerufen und liefert das Briefing.
8. Erinnerungen zur Uhrzeit löst der Code aus, ohne Modell. Was verpasst wurde (Mac aus/Ruhezustand), wird nachgeholt und aufgelistet.
9. Der Assistent kann per Chat wiederkehrende Aufgaben einrichten („jeden Montag um 8 …“) und führt sie später selbst aus, mit klaren Grenzen.
10. Am Ende liegt eine installierbare `.app` (bzw. `.dmg`) vor, und `npm run verify` ist grün.

---

## 1. Ziel und Erfolgsmaßstab

Der Nutzer will einen **echten Assistenten**, kein Chatfenster. Er soll ihn an Termine erinnern, Konflikte beim Eintragen nennen, morgens den Tag zusammenfassen und von sich aus (innerhalb klarer Grenzen) handeln, wenn man es ihm eingerichtet hat. Das Ganze ohne Bezahlstufe, mit einem Modell nach Wahl.

**Maßstab „fertig“:** Die fünf Szenarien in Abschnitt 2 laufen Ende-zu-Ende, automatisiert getestet und (wo nur ein Mensch am Mac es prüfen kann) in der Handtest-Liste in Abschnitt 15 belegt. „Fertig“ heißt nicht „Code geschrieben“.

---

## 2. Szenarien und Abnahmekriterien

| # | Szenario | Abnahme (muss automatisiert testbar sein, sofern nicht „Hand“ vermerkt) |
|---|---|---|
| A | Der Nutzer trägt einen Termin ein, der sich mit einem bestehenden überschneidet (egal in welchem aktiven Kalendermodul) | Der Termin wird **nicht** gespeichert. Antwort nennt Titel und Zeit des Konflikttermins. Erst auf ausdrückliche Bestätigung („trotzdem eintragen“) wird gespeichert. Die Prüfung ist reiner Code. |
| B | Tagesstart | Beim ersten Start des Tages nach Anmeldung erscheint das Fenster „Bist du bereit für heute?“ mit **Ja / Später (30 Min) / Heute nicht**. Bei Ja: Briefing mit Terminen, Erinnerungen, offenen/überfälligen Aufgaben, Konflikten, „Verpasst“. Pro Tag höchstens einmal gefragt (außer „Später“). |
| C | Aufgabe oder Erinnerung mit Uhrzeit | Zur Uhrzeit wird eine macOS-Benachrichtigung ausgelöst, ohne Modellaufruf und ohne Netz. Auslösen ist idempotent (nie doppelt). Hand: Benachrichtigung sichtbar. |
| D | Wiederkehrende Aufgabe per Chat („erinnere mich jeden Montag um 8 an …“) | Assistent legt über Werkzeug einen geplanten Auftrag an; der Planer führt ihn zur Zeit aus; Ergebnis erscheint als Benachrichtigung und im Chatverlauf. |
| E | Mac war aus oder im Ruhezustand | Beim nächsten Start werden verpasste Erinnerungen und Aufträge nachgeholt: Erinnerungen erscheinen unter „Verpasst“, fällige geplante Aufträge laufen einmal nach. |

---

## 3. Festlegungen (nicht neu diskutieren)

- **Plattform:** macOS auf Apple Silicon. Windows/Linux sind kein Ziel.
- **Stack:** Electron (aktuelle stabile Version), TypeScript (strict), React, Vite. Paketverwaltung: npm.
- **Tests:** Vitest (Unit/Integration), Playwright mit `_electron` (E2E), ESLint + `tsc --noEmit`.
- **Verpacken:** electron-builder (`dir` und `dmg`, arm64).
- **Daten:** lokal in SQLite im `userData`-Ordner. Kein Cloud-Konto.
- **Modell:** OpenAI-kompatibles `/chat/completions` mit `tools`. Standard-Endpunkt `https://openrouter.ai/api/v1`. Modellname Freitext + Auswahlliste aus `GET {baseUrl}/models`.
- **Schlüssel:** Electron `safeStorage` (Keychain-gestützt). Nie im Klartext in Dateien, Logs oder Fehlermeldungen.
- **Entfällt:** Handy-App, Cloud-Sync, Windows/Linux, Sprachsteuerung, Browser-Steuerung, Bildgenerierung.

**SQLite-Treiber, Entscheidungsregel:** Prüfe in Meilenstein 1 zuerst, ob `node:sqlite` im Electron-Main-Prozess der gewählten Electron-Version läuft. Wenn ja, nimm es (keine nativen Module). Wenn nein, nimm `better-sqlite3` mit `@electron/rebuild`. Dokumentiere die Entscheidung in `docs/decisions/0001-sqlite.md`.

---

## 4. Architektur und Verzeichnisse

```
assistent/
  CLAUDE.md                 Arbeitsregeln (kurz)
  BAUPLAN.md                dieses Dokument
  docs/decisions/           kurze Entscheidungsnotizen (ADR)
  docs/BLOCKERS.md          alles, was nicht gelöst werden konnte
  docs/HANDTEST.md          Checkliste für den Nutzer am echten Mac
  scripts/                  Hilfsskripte (eval, spike, verify)
  src/
    shared/                 Verträge: Typen, Schnittstellen, IPC-Kanäle  (nur Orchestrator ändert)
    main/
      index.ts              App-Start, Tray, Fenster, Single-Instance (Integrator)
      ipc/                  IPC-Handler (Integrator)
      store/                SQLite, Migrationen, Repositories          (Agent A)
      tools/                Werkzeuge + Konfliktprüfung                 (Agent A)
      llm/                  Modell-Client, Fehlerabbildung, safeStorage (Agent B)
      agent/                Agenten-Schleife, Systemprompt              (Agent B)
      planner/              Uhr, Erinnerungen, Tagesstart, Aufträge     (Agent C)
      calendar/             Provider + Registry                         (Agent D)
      notify/               Benachrichtigungen (Wrapper, austauschbar)  (Agent C)
    preload/                contextBridge-API                           (Integrator)
    renderer/               React-Oberfläche                            (Agent E)
  test/
    e2e/                    Playwright-Abnahmetests A–E                 (Agent T)
    fixtures/               Mock-LLM-Server, Mock-Notion-Server, Mock-Kalender
  resources/                Icons, ggf. Swift-Hilfsprogramm für Apple Kalender
```

**Prozessmodell:** Der gesamte Kern (Daten, Werkzeuge, Planer, Modell, Kalender) läuft im **Main-Prozess**. Der Renderer hat keinen Node-Zugriff und spricht nur über die Preload-API.

**Sicherheit Electron:** `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true` wo möglich, keine Remote-Inhalte, restriktive CSP, `will-navigate` und `setWindowOpenHandler` sperren, Single-Instance-Lock.

**App-Verhalten:** Läuft im Hintergrund weiter, wenn das Fenster geschlossen wird (Tray). Start bei Anmeldung per `app.setLoginItemSettings` (in den Einstellungen abschaltbar). Globaler Kurzbefehl (Standard `Control+Option+Space`, änderbar) zeigt/versteckt das Fenster.

---

## 5. Verträge (`src/shared`, vom Orchestrator in Welle 0 festgeschrieben)

Diese Schnittstellen werden vor der Parallelarbeit eingefroren. Änderungen laufen nur über den Orchestrator.

```ts
// Zeit: lokale, zonenlose ISO-Strings. "YYYY-MM-DDTHH:mm" oder "YYYY-MM-DD" (ganztägig).
export interface Clock { now(): Date }                // im Test ersetzbar, überall injizieren

export interface CalendarEvent {
  id: string; sourceId: string; title: string;
  start: string; end?: string; allDay: boolean;
  notes?: string; readOnly: boolean;
}
export interface NewEvent { title: string; start: string; end?: string; notes?: string }

export interface CalendarProvider {
  readonly id: string;                                 // stabil, z. B. "apple", "notion:abc", "local"
  readonly kind: 'local' | 'apple' | 'notion' | 'ics';
  readonly capabilities: { write: boolean };
  listEvents(range: { from: string; to: string }): Promise<CalendarEvent[]>; // from inklusiv, to exklusiv (Datum)
  createEvent?(e: NewEvent): Promise<CalendarEvent>;
  healthCheck(): Promise<{ ok: boolean; message?: string }>;
}

export interface Conflict { with: CalendarEvent; kind: 'overlap' | 'same-start' }

export interface LlmClient {
  chat(req: { messages: ChatMessage[]; tools?: ToolDef[]; signal?: AbortSignal }):
    Promise<{ message: ChatMessage }>;                 // wirft LlmError mit code
}
export type LlmErrorCode = 'auth' | 'quota' | 'no-tools' | 'rate-limit' | 'network' | 'bad-response' | 'unknown';
```

`ChatMessage`, `ToolDef` (OpenAI-Format), IPC-Kanalnamen und -Payloads, `Settings`-Typ und `ToolResult = { ok: true, ... } | { ok: false, code: string, error: string }` gehören ebenfalls nach `src/shared`.

**UI-Testkennungen:** `src/shared/testids.ts` legt die `data-testid`-Namen fest (z. B. `chat-input`, `chat-send`, `chat-message`, `daystart-yes`, `daystart-later`, `daystart-skip`, `briefing`, `missed-list`, `task-add`, `event-add`, `settings-save`). Agent E implementiert sie, Agent T nutzt sie, ohne `src/renderer` zu lesen.

**IPC-Kanäle (Mindestumfang):** `state:get`, `chat:send`, `chat:clear`, `settings:get`, `settings:set`, `models:list`, `llm:test`, `dayStart:answer` (`yes|later|skip`), `missed:acknowledge`, `entity:*` (direkte CRUD-Aktionen der Oberfläche ohne Modell), `calendar:sources`, `calendar:healthCheck`. Ereignisse Main → Renderer: `state:changed`, `dayStart:prompt`, `briefing:ready`.

---

## 6. Datenmodell (SQLite, Migrationen versioniert)

| Tabelle | Wichtige Spalten |
|---|---|
| `tasks` | id, title, notes, `due` (Datum oder lokale Zeit, optional), done, done_at, created_at |
| `notes` | id, title, content, created_at, updated_at |
| `habits` | id, name, description, archived, created_at |
| `habit_checks` | habit_id, date (PK zusammen) |
| `local_events` | id, title, start, end, all_day, notes |
| `reminders` | id, source (`task`/`event`/`job`), source_ref, due_at, fired_at (NULL = offen), acknowledged_at |
| `jobs` | id, name, prompt, rule (JSON), mode (`read-only`/`standard`), enabled, last_run_at, created_at |
| `job_runs` | id, job_id, scheduled_for, started_at, status, output |
| `daily_state` | date (PK), state (`none`/`asked`/`snoozed`/`done`/`skipped`), snooze_until |
| `messages` | id, json, created_at (vollständige Chat-Nachrichten inkl. Tool-Calls) |
| `action_log` | id, at, actor (`user`/`assistant`/`job`), tool, args_json, ok, error |
| `calendar_sources` | id, kind, config_json, enabled, is_default_write |

Geheimnisse (OpenRouter-Key, Notion-Token) liegen **nicht** hier, sondern über `safeStorage` verschlüsselt in einer eigenen Datei.

---

## 7. Werkzeuge für das Modell

Alle Werkzeuge liegen in `src/main/tools`, haben JSON-Schema, validieren Argumente streng und liefern `ToolResult`. Jede ausgeführte Änderung wird in `action_log` protokolliert.

| Werkzeug | Zweck | Besonderheit |
|---|---|---|
| `get_overview` | Stand: überfällig, heute, kommend, Habits, Termine (alle Module), Verpasstes | wird auch in jeden Systemprompt eingebettet |
| `add_task`, `list_tasks`, `update_task`, `complete_task`, `reopen_task`, `delete_task` | Aufgaben | `due` validieren |
| `add_note`, `list_notes`, `search_notes`, `update_note`, `delete_note` | Notizen | |
| `add_habit`, `list_habits`, `check_habit`, `delete_habit` | Habits mit Serie | Streak-Berechnung im Code |
| `add_event` | Termin anlegen | **Konflikt-Wächter, siehe unten** |
| `list_events` | Termine eines Zeitraums über **alle** aktiven Module | |
| `schedule_job`, `list_jobs`, `cancel_job` | wiederkehrende Aufträge | Regeln: `daily`, `weekly`, `once` |

**Konflikt-Wächter (Szenario A), verbindlich:**
- `findConflicts(newEvent, existing)` ist eine **reine Funktion** mit eigenen Unit-Tests.
- Zwei Termine mit Uhrzeit überschneiden sich, wenn `startA < endB && startB < endA`. Fehlt `end`, gilt `start + 60 Minuten`.
- Ganztägige Termine sind **kein** Konflikt, werden aber als Hinweis (`info`) mitgeliefert.
- `add_event` ruft zuerst `findConflicts` über **alle** aktiven Module auf. Bei Konflikt: `{ ok:false, code:'CONFLICT', conflicts:[…] }`, **nichts wird gespeichert**. Erst ein erneuter Aufruf mit `allow_conflict: true` speichert. Der Systemprompt verlangt, dass das Modell den Konflikt dem Nutzer nennt und nachfragt.
- Dieselbe Funktion nutzt die Oberfläche beim manuellen Eintragen.
- Geschrieben wird in das als „Standard zum Schreiben“ gewählte Modul; ist keines beschreibbar, in `local`.

**Schutz bei selbstständigen Läufen:** Im Modus `read-only` (Standard für geplante Aufträge) sind nur Lesewerkzeuge, `add_task`, `add_note` und „Benachrichtigung senden“ erlaubt. `update_*`, `delete_*` und `add_event` sind gesperrt. Das ist im Code erzwungen, nicht nur im Prompt.

---

## 8. Modellschicht und Agent

- **Client** (`src/main/llm`): `fetch` auf `{baseUrl}/chat/completions` mit `Authorization: Bearer`, Zusatz-Header `HTTP-Referer` und `X-Title` für OpenRouter. Kein Key nötig, wenn `baseUrl` auf `127.0.0.1`/`localhost` zeigt (z. B. Ollama).
- **Fehlerabbildung** auf `LlmErrorCode` mit verständlichen deutschen Meldungen: 401/403 → `auth`, 402 → `quota`, 404 mit „tool“ im Text → `no-tools` („Dieses Modell unterstützt keine Werkzeuge, bitte anderes wählen“), 429 → `rate-limit`, Netzfehler → `network`.
- **Agent-Schleife** (`src/main/agent`): bis zu 8 Schritte; Systemprompt wird **pro Anfrage neu** gebaut (Datum, Uhrzeit, Persönlichkeit, eigene Anweisungen, `get_overview` als JSON). Verlauf: letzte 40 Nachrichten, beginnt nie mit einer verwaisten Tool-Antwort. Abbruch über `AbortSignal`.
- **Regeln im Systemprompt:** Aktionen sofort mit Werkzeugen ausführen, nur bei fehlenden Pflichtangaben nachfragen; nie IDs erfinden; relative Zeitangaben anhand des Datums in ISO umrechnen; nach Aktionen knapp bestätigen und nie Erfolg behaupten, wenn kein Werkzeug erfolgreich war; Konflikte immer nennen; Deutsch, kurz.
- **Persönlichkeiten:** wenige Presets (z. B. direkt, ruhig, Coach, locker) als reine Prompt-Texte, dazu freies Feld „Eigene Anweisungen“.
- **Einstellungen-Test:** Knopf „Verbindung testen“ (`llm:test`) schickt eine minimale Anfrage und zeigt Erfolg oder die abgebildete Fehlermeldung.

---

## 9. Planer, Erinnerungen, Tagesstart

Der Planer ist ein Dienst im Main-Prozess mit **injizierbarer Uhr** (`Clock`). Er tickt alle 30 Sekunden und beim Aufwachen aus dem Ruhezustand (`powerMonitor.on('resume')`).

**Erinnerungen (Szenario C):**
- Aufgaben mit Uhrzeit in `due` erzeugen einen `reminders`-Eintrag. Optional: Termine erzeugen eine Erinnerung N Minuten vor Beginn (Standard 10, abschaltbar). Der Planer holt Termine der nächsten 48 Stunden aus den Modulen und gleicht sie alle 5 Minuten ab.
- Fällig und `fired_at IS NULL` → Benachrichtigung auslösen und `fired_at` setzen. **Idempotent:** nie doppelt.
- Datumsangaben ohne Uhrzeit lösen keine Benachrichtigung aus, sie erscheinen im Briefing.

**Verpasstes (Szenario E):** Alles mit `due_at < now`, `fired_at IS NULL` (also nie ausgelöst, weil Mac aus/Ruhezustand) gilt als **verpasst**. Es wird beim Start/Aufwachen **nicht** einzeln mit Benachrichtigungen überflutet, sondern in einer Liste „Verpasst“ gesammelt und im Briefing und in der Oberfläche angezeigt, bis der Nutzer sie bestätigt (`missed:acknowledge`).

**Tagesstart (Szenario B), Zustandsautomat über `daily_state`:**

```
Auslöser: App-Start (auch per Anmeldung), Tick, optional Entsperren/Aufwachen (Einstellung, Standard AUS)
Wenn heute state = none                      → zeige Frage-Fenster, state = asked
Wenn state = snoozed und now >= snooze_until → zeige Frage-Fenster erneut
Wenn state in (done, skipped)                → nichts

Antwort Ja         → state = done; Briefing erzeugen (siehe unten)
Antwort Später     → state = snoozed, snooze_until = now + 30 min
Antwort Heute nicht→ state = skipped
Frage-Fenster geschlossen ohne Antwort → bleibt asked, wird beim nächsten App-Start des Tages erneut gezeigt
```

**Briefing:**
1. Deterministisch zusammenstellen (Code): Termine heute und die nächsten Tage aus **allen** Modulen, Konflikte unter diesen Terminen, Erinnerungen heute, überfällige und heutige Aufgaben, Habits ohne Haken heute, Verpasstes.
2. **Ein** Modellaufruf formuliert daraus das Briefing und schlägt eine Reihenfolge vor.
3. **Fallback ohne Modell:** Schlägt der Aufruf fehl (kein Key, offline, Fehler), zeigt die App ein vollständiges **regelbasiertes Textbriefing** aus denselben Daten. Das Briefing darf nie an der Modellverbindung scheitern.

**Geplante Aufträge (Szenario D):** `rule` ist `{type:'daily', time:'HH:mm'}`, `{type:'weekly', days:[1..7], time:'HH:mm'}` oder `{type:'once', at:'…'}`. Zur Zeit führt der Planer den Prompt im Modus `read-only` über die Agent-Schleife aus, speichert die Ausgabe in `job_runs` und im Chat und sendet eine Benachrichtigung. War die App zur Zeit nicht aktiv: beim nächsten Start **einmal** nachholen, wenn die Fälligkeit weniger als 24 Stunden zurückliegt, sonst überspringen und in `job_runs` als `skipped-stale` vermerken.

**Zeit:** Zeitzone der Systemuhr. Sommer-/Winterzeit-Wechsel und Mitternachtsübergang gehören in die Unit-Tests des Planers.

---

## 10. Kalendermodule

Registry in `src/main/calendar`: lädt aktive Quellen aus `calendar_sources`, hält pro Quelle einen Provider, aggregiert `listEvents` über alle, fängt Fehler pro Quelle ab (eine ausgefallene Quelle darf Briefing und Konfliktprüfung nicht kippen, sie wird im Ergebnis als „nicht erreichbar“ ausgewiesen).

| Modul | Lesen | Schreiben | Hinweise |
|---|---|---|---|
| **Lokal** | ja | ja | SQLite `local_events`. Immer vorhanden, Rückfall für Schreiben. |
| **Apple Kalender** | ja | ja | Siehe Spike unten. Enthält auch in macOS eingetragene Google-/iCloud-Konten. |
| **Notion-Datenbank** | ja | ja | Interne Integration mit Token. Datenbank-ID und **Feldzuordnung konfigurierbar** (Titel, Datum inkl. Ende, optional Status), weil die konkrete Datenbank noch nicht bekannt ist. |
| **ICS-Link** | ja | nein | Abo-Adresse, einfacher Rückfall, falls der Apple-Zugriff scheitert. |

**Spike Apple Kalender (Meilenstein 0, zuerst):** Ziel ist der Nachweis, dass die App die heutigen Termine aus Apple Kalender lesen und einen Termin anlegen kann. Verglichen werden mögliche Wege:
- (a) kleines Swift-Hilfsprogramm mit EventKit, in `resources/` mitgeliefert und von der App aufgerufen,
- (b) `osascript` (JXA/AppleScript),
- (c) vorhandenes Kommandozeilenwerkzeug.

Kriterien: Zuverlässigkeit, Geschwindigkeit, Freigabe-Dialog (Kalenderzugriff wird dem aufrufenden Programm zugeordnet, bei Electron also der App), Verhalten in der gebauten `.app`. Ergebnis in `docs/decisions/0002-apple-calendar.md`. **Wichtig:** Der Freigabe-Dialog erfordert einen Klick des Nutzers am echten Mac. Der Agent schreibt dafür `scripts/spike-apple-calendar.sh` plus eine Anleitung in `docs/HANDTEST.md`, der Nutzer führt es aus und meldet das Ergebnis. Bis dahin entwickelt der Rest gegen einen Mock-Provider, und **ICS-Link wird als Rückfall zwingend mitgebaut**.

**Notion-Hinweis:** Nach bisherigem Kenntnisstand hat Notion die Datenbank-Abfrage mit neueren API-Versionen auf „Data Sources“ umgestellt. **Vor der Implementierung die aktuelle Notion-API-Dokumentation lesen** (WebFetch), die `Notion-Version` festschreiben und die Abfrage danach ausrichten. Tests laufen gegen einen Mock-Server, der dieselben Antwortformen liefert.

---

## 11. Oberfläche (React, Deutsch, folgt dem System-Hell/Dunkel)

- **Hauptfenster:** links Chat, rechts Reiter **Heute · Aufgaben · Notizen · Habits · Kalender · Einstellungen**. Direkte Bearbeitung ohne Modell muss überall gehen (anlegen, abhaken, löschen), auch mit leerem API-Key.
- **Chat:** Eingabe, „denkt …“-Zustand, abbrechen, Verlauf leeren; ausgeführte Aktionen als kleine Zeilen unter der Antwort („Aufgabe angelegt: …“); Fehlermeldungen verständlich auf Deutsch mit nächstem Schritt.
- **Tagesstart-Fenster:** klein, rahmenlos, oben mittig, immer im Vordergrund, drei Knöpfe (Ja / Später / Heute nicht). Danach zeigt das Hauptfenster das Briefing.
- **Verpasst:** sichtbarer Block im Reiter „Heute“ mit Knopf „Gesehen“.
- **Einstellungen:** Endpunkt-URL, Key (Eingabe maskiert, nie zurückgelesen), Modellfeld mit Vorschlagsliste, Verbindung testen, Persönlichkeit, eigene Anweisungen, Kalenderquellen (an/aus, Standard zum Schreiben, Notion-Zugangsdaten und Feldzuordnung, ICS-URL), Erinnerungsvorlauf, Start bei Anmeldung, Kurzbefehl, „Auch nach Entsperren fragen“.
- **Qualität:** Tastaturbedienung, sichtbarer Fokus, ausreichender Kontrast, keine Layoutsprünge beim Laden.

---

## 12. Teststrategie

**Grundsatz:** Nur an den **Grenzen** wird gemockt (HTTP zum Modell, HTTP zu Notion, Apple-Hilfsprogramm, Systembenachrichtigung, Uhr). Eigene Logik wird nie weggemockt, damit ein grüner Test etwas bedeutet.

1. **Unit** (Vitest): `findConflicts` (Grenzfälle: Berührung ohne Überschneidung, fehlendes Ende, ganztägig, Mitternacht, gleicher Start), Streak, Regel-Berechnung der Aufträge (`daily/weekly/once`, Sommerzeit), Fehlerabbildung, Argumentvalidierung jedes Werkzeugs, Zustandsautomat Tagesstart.
2. **Integration** (Vitest, echte SQLite in temporärem Ordner): Agent-Schleife gegen den **Mock-LLM-Server** (`test/fixtures`), der geskriptete Werkzeugaufrufe liefert, inklusive fehlerhafter Argumente, unbekannter Werkzeuge, Endlosschleife (Abbruch nach 8 Schritten), Fehlerantworten 401/402/404/429.
3. **Planer-Zeitreisen:** Mit künstlicher Uhr acht Stunden „schlafen“ und prüfen: Verpasstes erscheint genau einmal, Aufträge laufen einmal nach, nichts feuert doppelt.
4. **Provider-Verträge:** Dieselbe Testsuite läuft gegen jedes Modul (Lokal, Notion-Mock, ICS-Fixture, Apple-Mock).
5. **E2E** (Playwright `_electron`, Agent T): Szenarien A bis E gegen die **gebaute Electron-App** mit Mock-LLM und Mock-Kalender, über echte UI-Bedienung. Eigener `userData`-Ordner pro Lauf. Dafür gibt es **Test-Haken**, die nur bei `ASSISTENT_TEST=1` wirken (Prüfer R kontrolliert, dass ohne diese Variable nichts davon greift): `ASSISTENT_USER_DATA` (eigener Datenordner), `ASSISTENT_FAKE_NOW` (feste Startzeit, per Test-IPC `test:advance-clock` vorstellbar), `ASSISTENT_NOTIFY_SINK` (Benachrichtigungen als JSON-Zeilen in eine Datei statt ans System), `ASSISTENT_LLM_BASE_URL` und `ASSISTENT_CALENDAR_MOCK` (Pfad zu einer Fixture-Datei).
6. **Modellqualität (`npm run eval`, optional, braucht echten Key):** 12 deutsche Beispielanfragen („Trag morgen 14 Uhr Zahnarzt ein“, „Hab ich Freitag Zeit?“, „Hak Lesen ab“ …). Prüft, ob das richtige Werkzeug mit gültigen Argumenten gewählt wird, und gibt eine Tabelle mit Trefferquote aus. Nicht Teil von `verify`, läuft nur auf Wunsch.
7. **Nicht automatisierbar:** Siehe Abschnitt 15 (Handtest).

**Verbot:** Kein Test darf nur prüfen, dass „etwas aufgerufen wurde“. Jeder Test prüft das beobachtbare Ergebnis (Datenbankinhalt, UI-Text, ausgelöste Benachrichtigung).

---

## 13. Teamplan: Orchestrator und Subagenten

**Vorgehen:** Der Orchestrator (Haupt-Claude-Code-Sitzung) baut nichts allein, sondern zerlegt, setzt Verträge fest, startet Subagenten parallel, **prüft jedes Ergebnis selbst** und integriert. Wenn verfügbar, bekommt jeder parallel arbeitende Subagent einen eigenen Git-Worktree (`isolation: worktree`) und der Orchestrator führt die Zweige zusammen.

### Rollen und Eigentum

| Rolle | Eigentum (nur hier schreiben) | Aufgabe |
|---|---|---|
| **O** Orchestrator | `src/shared`, `docs/`, Konfiguration | Verträge, Skripte, Integration, Endkontrolle |
| **A** Datenkern | `src/main/store`, `src/main/tools` | SQLite, Migrationen, Repositories, Werkzeuge, `findConflicts`, Aktionsprotokoll |
| **B** Modell & Agent | `src/main/llm`, `src/main/agent`, `test/fixtures/mock-llm` | Client, Fehlerabbildung, `safeStorage`, Agent-Schleife, Systemprompt, Mock-LLM, Eval-Skript |
| **C** Planer | `src/main/planner`, `src/main/notify` | Uhr, Erinnerungen, Verpasstes, Tagesstart-Automat, Aufträge, Briefing-Zusammenstellung und Fallback |
| **D** Kalender | `src/main/calendar`, `resources/`, `scripts/spike-*` | Provider-Schnittstelle, Registry, Lokal, ICS, Notion (mit Mock), Apple (Spike + Provider) |
| **E** Oberfläche | `src/renderer` | React-UI gegen eine **Fake-Preload-API**, Komponententests |
| **T** Tester (blind) | `test/e2e` | Schreibt die E2E-Abnahmetests **allein aus Abschnitt 2 und 5**, ohne `src/main` zu lesen |
| **I** Integrator | `src/main/index.ts`, `src/main/ipc`, `src/preload` | Verdrahtung in Welle 2 |
| **P** Verpacker | `electron-builder.yml`, Build-Skripte | `.app`/`.dmg`, Signatur-Prüfung, Startnachweis |
| **R** Prüfer (gegnerisch) | nur `docs/REVIEW.md` | Sucht Fehler, Lücken, geschönte Tests |

### Wellen

**Welle 0 (Orchestrator allein):** Repo anlegen, Tooling (`npm run typecheck|lint|test|test:e2e|build|dist:mac|verify|eval`), `src/shared` mit allen Verträgen aus Abschnitt 5, leere Verzeichnisse, `CLAUDE.md`, CI-Skript. Gate: `npm run verify` läuft (noch leer) grün durch.

**Welle 1 (parallel, jeder in eigenem Verzeichnis):** A, B, C, D, E und T starten gleichzeitig, jeder gegen die eingefrorenen Verträge. D beginnt mit dem Apple-Spike-Skript. Gate je Agent: eigene Tests grün, `typecheck` und `lint` sauber, Bericht mit **ausgeführten Befehlen und Ausgabe**.

**Welle 2 (Integration):** I verdrahtet Main, IPC und Preload; E ersetzt die Fake-API durch die echte. O führt zusammen und fährt `npm run verify`. T lässt die E2E-Tests gegen die echte App laufen. Fehlschläge gehen als konkrete Aufträge an den zuständigen Agenten zurück.

**Welle 3 (Absicherung):** R prüft gegnerisch (siehe unten), die gemeldeten Funde werden behoben. P baut `.app`/`.dmg` und weist nach, dass sie **startet**.

**Welle 4 (Übergabe):** O erzeugt `docs/HANDTEST.md` final, `README.md` (Installation, Einrichtung des Keys, Kalender, bekannte Grenzen), führt die Endkontrolle aus Abschnitt 14 aus.

### Pflichtregeln für jeden Subagenten

1. Nur im **eigenen** Verzeichnis ändern. Brauchst du eine Vertragsänderung, melde sie dem Orchestrator, ändere nicht selbst `src/shared`.
2. **Test zuerst** für Logik mit Verhalten (Konflikte, Zeit, Zustandsautomat).
3. **Nichts als fertig melden ohne Nachweis:** exakt die ausgeführten Befehle und deren Ergebnis im Bericht. „Sollte funktionieren“ zählt nicht.
4. Blockiert etwas, das du nicht lösen kannst (z. B. Systemfreigabe am echten Mac): in `docs/BLOCKERS.md` eintragen, mit Mock/Rückfall weiterarbeiten, im Bericht deutlich sagen, was **nicht** verifiziert ist.
5. Keine Geheimnisse im Code, in Tests, Logs oder Berichten.
6. Berichtsformat: **Ergebnis** (ein Absatz) · **Befehle und Ausgabe** · **Nicht verifiziert** · **Offene Fragen an den Orchestrator**.

### Briefing-Vorlage für jeden Subagenten (vom Orchestrator auszufüllen)

```
Rolle: <A|B|C|D|E|T|I|P|R>
Lies: BAUPLAN.md Abschnitte <…>, src/shared/*
Du besitzt: <Verzeichnisse>. Ändere sonst nichts.
Liefere: <konkrete Dateien/Funktionen>
Fertig, wenn: <Befehle, die grün sein müssen>
Nicht tun: Verträge ändern, fremde Verzeichnisse anfassen, eigene Logik wegmocken.
Berichte im Format: Ergebnis / Befehle+Ausgabe / Nicht verifiziert / Fragen.
```

### Der Prüfer R (gegnerisch)

R bekommt den Auftrag, die Arbeit **zu widerlegen**: Gibt es Tests, die immer grün sind? Wird irgendwo Erfolg behauptet, ohne dass ein Werkzeug lief? Kann `add_event` am Konflikt-Wächter vorbei speichern (UI-Pfad, Werkzeug-Pfad, geplanter Lauf)? Feuert eine Erinnerung doppelt oder nie? Läuft das Briefing ohne Modell? Kippt ein ausgefallener Kalender das Ganze? Landet der Key irgendwo im Klartext (Dateien, Logs, Fehlertext)? Funde mit Reproduktionsschritt in `docs/REVIEW.md`, jeder Fund wird behoben oder begründet abgelehnt.

---

## 14. Definition of Done und Endkontrolle

Der Orchestrator führt dies **selbst** aus und berichtet die echten Ausgaben:

1. `npm run verify` ist grün. Es führt aus: `typecheck`, `lint`, Unit und Integration, Provider-Verträge, `build`, E2E gegen die gebaute App.
2. Die E2E-Tests der Szenarien **A, B, C, D, E** sind einzeln aufgeführt und bestanden.
3. `npm run dist:mac` erzeugt eine `.app` (und `.dmg`) für arm64. Die `.app` wurde **tatsächlich gestartet** (nicht nur gebaut), und das Fenster erschien. Die Signatur ist geprüft (`codesign -dv`); auf Apple Silicon braucht die App mindestens eine ad-hoc-Signatur, um zu starten, und der `Info.plist`-Eintrag für Kalenderzugriff (`NSCalendarsFullAccessUsageDescription`) ist enthalten. Hinweis im README: nicht notarisiert, beim ersten Öffnen Rechtsklick → Öffnen.
4. Die App funktioniert **ohne Modell-Key** für alles, was kein Modell braucht (Direktbearbeitung, Erinnerungen, Fallback-Briefing) und zeigt bei fehlendem Key eine klare Meldung.
5. Kein Klartext-Key in Dateien/Logs (Suche belegt es).
6. `docs/BLOCKERS.md` ist ehrlich: alles, was nicht verifiziert werden konnte, steht drin.
7. `docs/HANDTEST.md` ist vollständig und so geschrieben, dass der Nutzer es in 15 Minuten abarbeiten kann.

---

## 15. Handtest-Checkliste für den Nutzer (nur am echten Mac prüfbar)

Der Agent schreibt diese Liste als `docs/HANDTEST.md` mit konkreten Schritten und erwarteten Ergebnissen:

- [ ] `.app` starten (Rechtsklick → Öffnen). Tray-Symbol erscheint, Kurzbefehl öffnet das Fenster.
- [ ] Einstellungen: OpenRouter-Key eintragen, Modell wählen, „Verbindung testen“ ist grün.
- [ ] Chat: „Trag morgen um 14 Uhr Zahnarzt ein“ → Termin erscheint. Danach „Trag morgen um 14:30 Uhr Meeting ein“ → Assistent nennt den Konflikt.
- [ ] Apple Kalender: Freigabe-Dialog erscheint und wird bestätigt; heutige Termine werden angezeigt; ein neuer Termin erscheint in der Kalender-App.
- [ ] Notion: Token und Datenbank eintragen, Feldzuordnung setzen; Termine erscheinen im Briefing.
- [ ] Benachrichtigung: Aufgabe mit Uhrzeit in zwei Minuten anlegen → macOS-Benachrichtigung erscheint (ggf. in den Systemeinstellungen erlauben).
- [ ] Start bei Anmeldung: Abmelden und wieder anmelden → Frage „Bist du bereit für heute?“ erscheint einmal. „Später“ fragt nach 30 Minuten erneut.
- [ ] Ruhezustand: Erinnerung in 2 Minuten anlegen, Mac in den Ruhezustand, nach 5 Minuten aufwecken → Erinnerung steht unter „Verpasst“, nicht doppelt.
- [ ] Wiederkehrender Auftrag per Chat anlegen und zur Zeit prüfen.

---

## 16. Nicht im Umfang

Handy-App, Cloud-Sync, Windows/Linux, Sprachsteuerung, Browser-Steuerung, Bildgenerierung, Notarisierung/App-Store, Mehrbenutzer, Streaming-Antworten (optional später), Plugin-System.

---

## 17. Bekannte Unsicherheiten (bewusst offen)

- **Apple-Kalender-Zugriff aus Electron:** der größte technische Unsicherheitsfaktor, deshalb Spike zuerst und ICS als Pflicht-Rückfall.
- **Notion-Struktur:** Datenbank und Felder sind nicht bekannt, deshalb konfigurierbar. Die Notion-API-Form (Datenbank vs. Data Source) ist vor dem Bauen in der aktuellen Doku zu prüfen.
- **Modellqualität:** Manche Modelle beherrschen Werkzeugaufrufe schlecht. Das fängt weder Code noch Test vollständig ab; dafür gibt es `npm run eval` und die Meldung „Modell unterstützt keine Werkzeuge“.
- **Benachrichtigungen im Entwicklungsmodus:** werden unter macOS dem Electron-Programm statt der App zugeordnet; die echte Prüfung geschieht an der gebauten `.app`.
- **SQLite-Treiber:** Entscheidung per Regel in Abschnitt 3.
