# CLAUDE.md – Taby

## Projekt in einem Satz
Native macOS-App (Swift/SwiftUI, Swift-Paket in `mac/`) – Assistent in der Notch mit Chat, Aufgaben/Notizen/Habits/Terminen, modularen Kalendern, Konflikt-Prüfung im Code, Tagesstart/Feierabend, Fokus, Mods und frei wählbarem Modell über OpenRouter oder Apple Intelligence.

Hintergrund: `docs/decisions/` (v. a. 0006-native-swift.md), `docs/ROADMAP.md`. Der alte Electron-Bauplan liegt nur noch als Archiv in `docs/archive/`.

## Arbeitsweise
- Du bist der **Orchestrator**. Größere Arbeit in Teile zerlegen und Subagenten parallel starten (bauen mit Haiku, prüfen mit Opus/Sonnet); jeder besitzt nur seine Dateien.
- **Verträge zuerst:** `mac/Sources/TabyCore/Contracts` und `mac/Sources/TabyUI/Contracts` ändert nur der Orchestrator.
- **Nichts gilt als fertig ohne Nachweis.** `mac/scripts/verify.sh` (bzw. `swift run TabyChecks`) selbst ausführen, Exit-Code prüfen, keinem Subagenten-Bericht ohne Ausgabe glauben.
- Oberfläche über Snapshots prüfen: `swift run TabyChecks --snapshots <ordner> <filter>` und die PNGs ansehen.
- Teste an den **Grenzen** (Modell-HTTP, Notion-HTTP, EventKit, Benachrichtigung, Uhr), nie die eigene Logik weg.
- Konflikt-Prüfung, Erinnerungen, Tagesstart und Planung sind **Code**, nicht Modell. Das Modell formuliert und bedient Werkzeuge.
- Das Fallback-Briefing muss ohne Modell und ohne Netz funktionieren.

## Befehle (in `mac/`)
`./scripts/verify.sh` · `swift run TabyChecks` · `./scripts/bundle.sh` · `./scripts/personal-dmg.sh` · `./scripts/release.sh` · `./scripts/publish-dmg.sh`

## Download im Repository
Nach jeder veröffentlichten Änderung `mac/scripts/publish-dmg.sh` ausführen und `download/` mitcommitten – auf GitHub liegt dann immer die aktuelle `download/Taby.dmg`.
Vorher `mac/RELEASE-NOTES.txt` mit den Neuerungen füllen und committen (wird als „Was ist neu“ in `version.json` übernommen, max. 600 Zeichen; leer = keine Notizen).

## Regeln
- UI-Texte Deutsch; Code, Bezeichner, Commits Englisch.
- Zeit als lokale zonenlose ISO-Strings; überall `Clock` injizieren, nie `Date()` direkt in Logik.
- Keine Geheimnisse in Code, Tests, Logs, Berichten. Schlüssel nur im Schlüsselbund.
- Was du nicht lösen oder prüfen kannst (z. B. Systemfreigabe am echten Mac): in `docs/BLOCKERS.md` und `docs/HANDTEST.md` eintragen und im Bericht ehrlich sagen.
- Vor einer Notion-Implementierung die aktuelle Notion-API-Doku lesen.
- Kleine, nachvollziehbare Commits pro Aufgabe.
