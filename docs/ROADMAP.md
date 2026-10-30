# Roadmap (native App, Stand 2026-10-11)

Entschieden mit dem Nutzer. Grundsatz bleibt: Logik/Berechnung im Code, das
Modell formuliert und bedient Werkzeuge.

## 0. Grundlagen (zuerst)
- Abnahme-Prüfungen der Szenarien A–E gegen `CoreServices` (TabyChecks "Integration").
- Sonnet-Review des Integrations-Codes (`TabyCore/Integration`, `TabyApp`).

## Paket 1
1. Schnellerfassung – globaler Kurzbefehl öffnet Eingabe, Modell sortiert in Aufgabe/Notiz/Termin.
2. Freie Zeit finden – Werkzeug `find_free_time`, Berechnung im Code über alle Kalender.
3. Puffer zwischen Terminen – Einstellung Mindestabstand, Warnung wie Konflikt.
4. Zwei Modelle – günstiges für Briefing/Aufträge, starkes für Chat.
5. Kostenanzeige und Limit – Verbrauch je Tag/Monat aus der Modell-Antwort, Warnung/Stopp.
6. Apple Erinnerungen – Zwei-Wege-Abgleich mit Taby-Aufgaben (EventKit), Nutzerwunsch.

## Paket 2
7. Tagesabschluss am Abend ("offen – auf morgen schieben?").
8. Fokus-Timer (Pomodoro mit Aufgabenbezug, Countdown in der eingeklappten Insel).
9. Gedächtnis (Fakten-Tabelle + Werkzeug, im Systemprompt).
10. Export nach Markdown (Obsidian).
11. Eigene MCP-Schnittstelle (Hermes/Claude lesen den Tag, legen Aufgaben an).

## Paket 3 – Mods (entschieden 2026-10-11)
- Mod-Bibliothek in den Einstellungen: ein-/ausschalten, Rechte ansehen, teilen als `.tabymod`-Datei.
- Kurzbefehl-Mods: Kurzbefehle aus der Apple-App „Kurzbefehle“, die Taby aufrufen darf (Erlaubnis pro Mod).
- Skript-Mods: JavaScript (JavaScriptCore) eingesperrt mit Rechte-Liste (z. B. Aufgaben lesen, bestimmte Domains abrufen),
  kein Datei-/Terminal-Zugriff. Taby kann Mods im Chat selbst schreiben; Nutzer prüft Rechte und gibt frei.
- Nicht: Swift-Plugins; MCP-Server als Mods vorerst nicht.

## Später / bewusst nicht
- Wochenrückblick, Web-Suche (OpenRouter `:online`) – später.
- Bildschirm-/Zwischenablage-Kontext – nicht (Datenschutz, Bildschirmaufnahme-Freigabe).

## Online-Meetings mitschreiben (Entwurf 2026-10-27, noch nicht gebaut)
Ziel: Lumi schreibt in Online-Terminen mit und legt Aufgaben selbst an. Baut auf der Termin-Notiz auf
(`Note.meetingKey`, Abschnitte „Agenda / Mitschrift / Zusammenfassung“, `summarizeMeeting`).
- **Ton:** Mikrofon über `AVAudioEngine` (eigene Stimme, vorhanden für Diktat) plus Systemton der anderen
  Teilnehmer über ScreenCaptureKit (`SCStream`, nur Audio). Beides braucht Systemfreigaben (Mikrofon, Bildschirmaufnahme).
- **Text:** Apple-Spracherkennung auf dem Gerät (`SFSpeechRecognizer`, de-DE, `requiresOnDeviceRecognition`),
  später ggf. `SpeechAnalyzer`. Es wird nur Text gespeichert, nie Audio. Sprecher nur nach Quelle: „Ich“ / „Andere“.
- **Ablauf:** Termin mit Beitritts-Link beginnt → Karte „Mitschreiben?“ → bei Ja läuft die Erkennung, der Text
  landet fortlaufend unter „Mitschrift“ der Termin-Notiz (sichtbarer Aufnahme-Hinweis in der Notch, jederzeit Stopp).
  Nach dem Termin: `summarizeMeeting` (Zusammenfassung + Aufgaben aus der Mitschrift, mit Bestätigung vor dem Anlegen).
- **Recht:** Vor dem Start der Hinweis, dass alle Teilnehmer informiert sein müssen (Einwilligung); nie heimlich.
- **Offen:** Systemton-Freigabe und Erkennungsqualität sind nur am echten Mac prüfbar → `docs/HANDTEST.md`/`docs/BLOCKERS.md`.

## Arbeitsweise
Subagenten bauen mit Haiku, Opus/Sonnet prüfen (Build, Prüfungen, Diff-Review).
