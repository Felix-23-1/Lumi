# 0002: Zugriffsweg Apple Kalender

**Status:** unverifiziert — diese Sitzung läuft unter Linux, kein echter Mac
verfügbar (siehe `docs/BLOCKERS.md`). Diese Entscheidung ist eine begründete
Empfehlung, kein Messergebnis. Der Nutzer führt `scripts/spike-apple-calendar.sh`
am echten Mac aus (Anleitung in `docs/HANDTEST.md`) und bestätigt oder
korrigiert sie.

## Verglichene Wege (BAUPLAN.md Abschnitt 10)

(a) kleines Swift-Hilfsprogramm mit EventKit, in `resources/` mitgeliefert
(b) `osascript` (JXA/AppleScript)
(c) vorhandenes Kommandozeilenwerkzeug (z. B. `icalBuddy`)

## Empfehlung: (a) Swift/EventKit-Hilfsprogramm

**Begründung (ohne Messung, aus bekanntem Verhalten von macOS/EventKit):**

- **Freigabe-Dialog-Zuordnung ist das entscheidende Kriterium.** Der
  TCC-Dialog für Kalenderzugriff wird dem *aufrufenden* Prozess zugeordnet.
  Bei `osascript` ist das `osascript`/Terminal bzw. — wichtiger — bei einem
  per `NSTask`/`child_process.spawn` aus Electron gestarteten `osascript`
  kann die Zuordnung uneinheitlich sein (teils dem Elternprozess, teils dem
  Helper zugeschrieben, abhängig von macOS-Version und Code-Signing). Ein
  **in die App eingebettetes** EventKit-Hilfsprogramm, das als Teil des
  signierten `.app`-Bundles läuft (nicht als separat signierter externer
  Prozess), bekommt den Dialog zuverlässig der App selbst zugeordnet — genau
  das will BAUPLAN.md Abschnitt 10 ("Freigabe-Dialog wird dem aufrufenden
  Programm zugeordnet, bei Electron also der App").
- **Typsicherheit und Fehlerbehandlung:** EventKit liefert strukturierte
  Objekte (`EKEvent`, Fehlercodes), `osascript`/JXA liefert Text/JSON über
  stdout, das geparst und bei jeder macOS-Version neu verifiziert werden
  muss (AppleScript-Dictionaries ändern sich leise zwischen macOS-Versionen).
- **(c) entfällt für Schreiben:** `icalBuddy` (gängigstes CLI für
  Kalenderzugriff) ist nur lesend. Es gibt kein etabliertes, verlässlich
  gepflegtes Schreib-CLI für Calendar.app. Für `add_event` scheidet (c) damit
  aus; es bliebe höchstens als zusätzlicher Lese-Rückfall, was aber bereits
  der ICS-Link abdeckt (Pflicht-Rückfall laut Abschnitt 10).
- **Geschwindigkeit:** Ein kompiliertes, einmal gestartetes Hilfsprogramm
  (oder dauerhaft laufender Helper-Prozess mit stdin/stdout-Protokoll) vermeidet
  den Prozessstart-Overhead, den jeder einzelne `osascript`-Aufruf hat.

**Bekanntes Risiko, im Spike zu prüfen:** Ob ein *separat signiertes*
Hilfsprogramm in `resources/` (eigenständige Binärdatei, von der App per
`spawn` aufgerufen) den Freigabe-Dialog trotzdem der Haupt-App zuordnet, oder
ob dafür echtes Einbetten (z. B. als eingebettetes Helper-Tool mit
`NSExtension`/gleichem Code-Signing-Team, oder Aufruf über eine In-Process-
Bridge statt separatem Prozess) nötig ist. Das lässt sich nur am echten,
**gebauten und signierten** `.app`-Bundle beobachten, nicht am rohen
Swift-Skript aus dem Spike — deshalb prüft `scripts/spike-apple-calendar.sh`
nur die grundsätzliche Machbarkeit (Lesen/Schreiben über EventKit
funktioniert überhaupt), die Freigabe-Zuordnung in der gebauten App ist ein
separater Punkt in `docs/HANDTEST.md`.

## Rückfall

Unverändert gemäß Abschnitt 10: ICS-Link ist Pflicht-Rückfall, falls der
Apple-Zugriff (aus welchem Grund auch immer, z. B. verweigerte Freigabe)
scheitert. Bis zum Mac-Spike entwickelt der Rest der App gegen den
Mock-Provider `createAppleMockProvider` (`src/main/calendar/apple.ts`).
