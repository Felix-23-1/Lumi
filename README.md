# Lumi

Dein Assistent in der MacBook-Notch: Aufgaben, Notizen, Habits und Termine,
Tagesplan, Tagesstart und Feierabend, Fokus-Timer, Nachrichten und Mods –
bedient über einen Chat mit frei wählbarem Modell (OpenRouter) oder
Apple Intelligence. Native macOS-App in Swift/SwiftUI.

## Was Lumi kann

- **Notch:** geschlossen links Lumi, in der Mitte rollen Wetter, Mod-Texte und
  ungelesene Nachrichten durch, rechts die Zahl offener Aufgaben. Ein Klick
  öffnet die Insel mit allen Reitern.
- **Aufgaben und Fokus:** Dauer, „Jetzt beginnen“ mit automatischem Nachrücken der
  übrigen Aufgaben, Pause, Stand (Offen / In Bearbeitung / Info fehlt), Kennzeichen,
  Ansicht-Menü zum Gruppieren und Filtern.
- **Notizen:** kleiner Markdown-Editor, Notizen an Aufgaben und Terminen.
- **Meetings:** Agenda vorab, lokales Mitschreiben (nur Text, mit Zustimmung aller),
  Aufgaben-Vorschläge mit Zitat, Zusammenfassung danach.
- **Erklären:** Text markieren, Ctrl+Option+E, Lumi erklärt und liest vor – oder schreibt per „Antwort entwerfen“ einen Antwortentwurf.
- **Einkreisen und fragen:** Ctrl+Option+K, Bereich einkreisen, per Sprache fragen („Was ist das?“); Texterkennung nur auf dem Mac (braucht Bildschirmaufnahme-Freigabe).
- **Umzug:** Einstellungen → Sicherungen → „Alles exportieren“ / „Aus Datei importieren“ bringt Notizen, Aufgaben und Termine auf einen anderen Mac.
- **Tagesplan, Habits:** Aufgaben mit fester Uhrzeit oder automatisch einplanen.
- **Kalender und Erinnerungen:** Apple Kalender/Erinnerungen, ICS- und
  Notion-Kalender; Konflikte prüft Lumi selbst, nicht das Modell.
- **Notion:** mehrere Quellen (Tickets, To-dos, Weekly) mit Abhaken zurück nach Notion.
- **Verbindungen:** iMessage, Slack (eigene Slack-App), Element/Matrix
  (verschlüsselt, Bestätigung per Emoji-Vergleich) und Apple Mail.
- **Mods:** eigene Skripte und Kurzbefehle sowie eine Bibliothek mit fertigen Mods,
  z. B. „Wetter in der Notch“ für deinen Wohnort (Einstellungen → Notch → Wohnort).
- **Updates:** Einstellungen → Updates → „Jetzt aktualisieren“ (siehe unten).
- Das Briefing funktioniert auch ohne Modell und ohne Netz.

Eine Tour mit Bildern: **[docs/ANLEITUNG.md](docs/ANLEITUNG.md)**

## Herunterladen

**[⬇ Lumi.dmg (aktuelle Version)](https://github.com/Felix-23-1/Lumi/raw/main/download/Taby.dmg)**

Dazu: [Lumi einrichten.command](https://github.com/Felix-23-1/Lumi/raw/main/download/Lumi%20einrichten.command)
(steckt auch in der DMG) und die [Anleitung](download/Anleitung.txt).

Kurz:
1. DMG öffnen, Lumi.app auf „Programme“ ziehen.
2. Terminal öffnen, `sh ` tippen, „Lumi einrichten.command“ hineinziehen, Enter.
   Das legt ein eigenes Zertifikat auf deinem Mac an und signiert Lumi damit
   (kein Apple-Konto, kein Xcode nötig). In der DMG steckt keine fremde Signatur.
3. Der Einrichtungs-Assistent führt durch Modell, Kalender, Erinnerungen,
   Sprache und Kurzbefehle.
4. Spätere Versionen kommen über den Update-Knopf in den Einstellungen.

Voraussetzung: macOS 14 (Sonoma) oder neuer, Apple Silicon oder Intel.

## Download/Update

Updates kommen automatisch von GitHub; in Lumi unter Einstellungen → Updates.

Für den Eigentümer: vor dem Veröffentlichen die Neuerungen in `mac/RELEASE-NOTES.txt`
eintragen (höchstens 600 Zeichen, leer = ohne Notizen) und committen. Dann
`mac/scripts/publish-dmg.sh` ausführen und `download/` mitcommitten. Die Notizen
erscheinen im Update-Hinweis; die Signatur deckt sie nicht ab.

Element ist in der Download-DMG nicht enthalten (die Matrix-Bibliothek macht
die App rund 100 MB größer). Wer Element braucht, baut Lumi selbst (siehe unten).

## Selbst bauen

Nur die Command Line Tools sind nötig (`xcode-select --install`).

```bash
cd mac
./scripts/verify.sh        # bauen + alle Prüfungen
./scripts/bundle.sh        # build/Lumi.app
./scripts/personal-dmg.sh  # eigene DMG, mit lokalem Zertifikat signiert
./scripts/publish-dmg.sh   # Freunde-DMG + version.json nach download/ (dann committen)
```

Mit Element: einmal `./scripts/build-matrix-sdk.sh` (braucht Rust), danach baut
`bundle.sh` Element automatisch mit ein.

## Aufbau

- `mac/Sources/TabyCore` – Kern ohne Oberfläche: Speicher (SQLite), Werkzeuge,
  Modell-Anbindung, Planer, Kalender, Erinnerungen, Notion, Nachrichten, MCP,
  Mods, Updates.
- `mac/Sources/TabyUI` – SwiftUI: Notch-Insel, Maskottchen, Ansichten.
- `mac/Sources/TabyApp` – Start und Verdrahtung.
- `mac/Sources/TabyChecks` – Prüfprogramm (`swift run TabyChecks`).
- `docs/` – Entscheidungen, Roadmap, Handtest, Blocker.

Daten bleiben auf dem Mac (`~/Library/Application Support/de.felix.taby`),
Schlüssel und Tokens im macOS-Schlüsselbund.
