# Handtest-Checkliste (nur am echten Mac prüfbar)

Was die automatischen Prüfungen (`mac/scripts/verify.sh`) nicht abdecken:
Systemdialoge, echte Freigaben, Aussehen an der Notch.

## Native App (Swift, `mac/`) – ab 2026-10-11
Bauen und starten: `mac/scripts/bundle.sh && open mac/build/Taby.app`
(Daten: `~/Library/Application Support/de.felix.taby/`).
1. Start: Insel begrüßt ("Guten Abend!" o. ä.) und klappt nach ~2,6 s zur Notch.
2. MacBook offen: schwarze Form verschmilzt mit der Kamera-Notch. Zugeklappt:
   Ersatz-Pille oben mittig auf dem externen Monitor.
3. Klick auf die Insel → federt auf; Maus weg → schließt nach ~0,7 s;
   nicht während man tippt. Esc schließt.
4. Klicks neben der Insel (Menüleiste, Fenster darunter) funktionieren.
5. Menüleisten-Symbol (Taby-Gesicht): "Taby öffnen", "Einstellungen…", "Beenden".
6. Einstellungen → API-Schlüssel setzen → App beenden/neu starten → "gesetzt"
   bleibt, "Verbindung testen" ok (Schlüsselbund; evtl. Zugriffsdialog).
7. Kalender → Apple-Quelle hinzufügen → Freigabe-Dialog erscheint, Termine
   sichtbar; Termin mit Überschneidung → Warnung, erst "Trotzdem speichern" speichert.
8. Aufgabe mit Uhrzeit in 12 min → Benachrichtigung (Freigabe-Dialog beim
   ersten Mal) + Insel poppt auf; genau einmal.
9. Agenten → Hook installieren → in Claude Code eine Bash-Aktion auslösen →
   Insel springt auf mit Erlauben/Ablehnen (Y/N).
10. Einstellungen → "Start bei Anmeldung" an → abmelden/anmelden → Taby startet.

## Kernfunktionen

- [ ] Ohne Modell-Key: Aufgabe/Notiz/Termin direkt in den Reitern
      anlegen funktioniert; der Reiter „Heute" zeigt ein regelbasiertes
      Briefing ohne Fehlermeldung.
- [ ] Einstellungen: OpenRouter-Key eintragen, Modell wählen, „Verbindung
      testen" ist grün.
- [ ] Chat: „Trag morgen um 14 Uhr Zahnarzt ein" → Termin erscheint. Danach
      „Trag morgen um 14:30 Uhr Meeting ein" → Assistent nennt den Konflikt
      (Titel „Zahnarzt", Zeit 14:00) und fragt nach; erst nach Bestätigung
      wird das Meeting gespeichert.
- [ ] Apple Kalender: Freigabe-Dialog erscheint und wird bestätigt (siehe
      Abschnitt unten); heutige Termine werden angezeigt; ein neuer Termin
      erscheint in der Kalender-App.
- [ ] Notion: Token und Datenbank eintragen (Abschnitt unten), Feldzuordnung
      setzen; Termine erscheinen im Briefing; ein per Chat angelegter Termin
      erscheint als neue Seite in der Notion-Datenbank.
- [ ] Benachrichtigung: Aufgabe mit Uhrzeit in zwei Minuten anlegen →
      macOS-Benachrichtigung erscheint (ggf. in den Systemeinstellungen
      erlauben), genau einmal.
- [ ] Start bei Anmeldung: Abmelden und wieder anmelden → Frage „Bist du
      bereit für heute?" erscheint einmal. „Später" fragt nach 30 Minuten
      erneut.
- [ ] Ruhezustand: Erinnerung in 2 Minuten anlegen, Mac in den Ruhezustand,
      nach 5 Minuten aufwecken → Erinnerung steht unter „Verpasst", nicht
      doppelt; „Gesehen" entfernt sie dauerhaft.
- [ ] Wiederkehrender Auftrag per Chat anlegen ("Erinnere mich jeden Montag
      um 8 an …") und zur Zeit prüfen: Benachrichtigung erscheint, Ergebnis
      steht im Chatverlauf.


## Notion-Feldzuordnung (Agent D, BAUPLAN.md Abschnitt 10)

Beim Einrichten einer Notion-Kalenderquelle in den Einstellungen:

1. In Notion eine interne Integration anlegen, Token kopieren, die Ziel-
   Datenbank **mit der Integration teilen** (sonst `restricted_resource`).
2. Database-ID aus der Notion-URL entnehmen (der UUID-Teil nach dem
   Workspace-Namen, vor `?v=`).
3. In den Taby-Einstellungen: Token, Database-ID sowie die Feldnamen für
   Titel (`titleField`, Spaltentyp „Title") und Start-Datum (`startField`,
   Spaltentyp „Date") exakt wie in Notion benannt eintragen. Optional
   `endField`, falls Start und Ende in getrennten Spalten stehen statt im
   Datums-Bereich derselben Spalte.
4. „Verbindung testen" prüfen — bei falschem Token/ID meldet Taby den
   Notion-Fehlercode (`unauthorized`/`object_not_found`/...) aus der
   Kurzreferenz in `docs/decisions/0003-notion-api-version.md`.

## Paket 3 – Mods
1. Reiter „Mods“ → „+ Kurzbefehl“ → einen Kurzbefehl wählen (Liste muss deine Kurzbefehle zeigen), „Bei Fokus-Start“, hinzufügen.
2. Schalter → Freigabe-Karte nennt den Kurzbefehl → „Freigeben & einschalten“ → „Testen“ führt ihn aus.
3. Fokus starten → Kurzbefehl läuft automatisch.
4. Chat: „Bau mir einen Mod, der …“ → Insel meldet „Neuer Mod“, im Reiter ausgeschaltet; Code + Rechte sichtbar; erst nach Freigabe nutzbar.
5. „Teilen“ → .tabymod im Finder; auf anderem Mac „Importieren“ → kommt ausgeschaltet an.

## Paket 4 – Tagesplan, Meeting, Dateien, Diktat, Wochenplanung, Fokus
1. Heute → „Aufgaben einplanen“ → Plan erscheint mit Zeiten; laufender Block hervorgehoben; „Neu planen“ und „Plan löschen“.
2. Wochenziele: Häkchen setzen; „Wochenplanung“ öffnet die Insel mit Rückblick; drei Ziele speichern.
3. Termin mit Link in 10 min (Einstellung Vorlauf) → Insel zeigt „Gleich: …“ mit Countdown; „Beitreten“ öffnet den Link; „Schließen“ schließt.
4. Nach dem Termin → Stichpunkte mit „-“ eintragen → „Speichern“ → Rückmeldung und Aufgaben im Heute-Reiter.
5. Datei (PDF, Text) aus dem Finder auf die Insel ziehen → Overlay „Datei loslassen“ → Chat zeigt Antwort; mehr als drei Dateien → nur die ersten drei.
6. Schnellerfassung → Mikrofon-Knopf → sprechen → Text erscheint im Feld, Knopf erneut → Text bleibt zum Senden.
7. Einstellungen → Planung: Block-Länge, Meeting-Vorlauf, Wochentag/Uhrzeit der Wochenplanung.
8. Einstellungen → Tag & Fokus → macOS-Fokus: Kurzbefehle aus der Liste wählen; Apps zum Ausblenden anhaken; Fokus starten und prüfen, dass die Apps verschwinden.
9. Einstellungen → Allgemein → „Bedienungshilfen erlauben“ → Systemdialog; danach markierten Text übernehmen (wenn der Kurzbefehl verdrahtet ist).
10. Einrichtung → Mitteilungen → „Mikrofon & Spracherkennung“ und Bedienungshilfen → Freigaben erscheinen.

## Paket 5 – Mail & Claude-Meldungen
1. Reiter Mail → „Mail einschalten“ → macOS fragt „Taby möchte Mail steuern“ → Erlauben → Posteingang erscheint.
2. Mail aufklappen → Text sichtbar, wird als gelesen markiert; „Aufgabe“ legt „Antworten: …“ an.
3. An einer unwichtigen Mail: Archivieren und Papierkorb (landet im Papierkorb, nicht endgültig gelöscht).
4. Antworten → Entwurf (mit „Nur lokal“: nur mit Apple Intelligence) → Senden kommt beim Empfänger an.
5. Agenten → Hook installieren → in Claude Code eine Aufgabe beenden lassen → Insel „Claude ist fertig“.

## Paket 6 – Netzwerk, große Insel, Animationen
1. Einstellungen → Netzwerk → einschalten → Reiter erscheint; WLAN-Name (evtl. nur mit Ortungsdiensten), IP, Router.
2. „Scannen“ findet Router, diesen Mac, Handy; Gerät umbenennen und als bekannt markieren.
3. Ping auf den Router, Ports auf den Router (offen: 53/80/443), Port-Check auf 8.8.8.8 wird verweigert.
4. Speedtest (~20 s) liefert Mbit/s; öffentliche IP nur nach Klick.
5. Vergrößern-Knopf unter dem Reitertitel: Insel wächst, bleibt pro Reiter gemerkt.
6. Animationen: Aufgabe abhaken → Konfetti; letzte heutige Aufgabe → Feuerwerk; Maus auf Taby ruhen lassen → Herzchen;
   Maus wild hin und her → Schwindel; Taby in der offenen Insel ziehen → dehnt sich und schnappt zurück; Fokus → Kopfhörer.
7. Sprache → Stimme „Systemstimme (z. B. Siri)“ + in den Bedienungshilfen Siri-Stimme als Systemstimme → „Probe hören“.

## Paket 7 – Profi-Netzwerk, Anheften, eigenes Fenster
1. Insel offen → unter dem Reitertitel drei Knöpfe: Anheften (Pin), eigenes Fenster, Vergrößern.
2. Anheften → Insel bleibt offen, auch beim Klick nach außen; Pin erneut klicken oder Esc löst es.
3. Fenster-Knopf → der Reiter öffnet sich in einem eigenen, frei vergrößerbaren Fenster; Größe bleibt beim nächsten Mal erhalten.
4. Netzwerk → Profi → Scan: Router-IP, „Dienste“ → offene Ports mit Diensten; Ziel 8.8.8.8 → „nur im eigenen Netz“ abgelehnt.
5. Verbindungen → Aktualisieren → zeigt laufende Verbindungen des Macs (extern zuerst).
6. Meine Server → Server hinzufügen nur mit Bestätigungsschalter; danach ist ein Scan dieses Servers erlaubt.
7. Mitschnitt → Schnittstelle + Filter (z. B. „port 443“) → Start fragt nach dem Admin-Passwort; Pakete laufen live ein; „Speichern“ legt eine Textzusammenfassung ab. Während des Mitschnitts bleibt die Insel offen.
   Bekannt: echter .pcap-Export für Wireshark fehlt noch (ADR 0008).

## Paket 8 – Mods mit Zeit, Notch-Text, Termin-Ansage, .pcap
1. Termin mit Uhrzeit in wenigen Minuten anlegen (Sprache an, „Ansagen“ an) → Taby sagt „Termin bald: … um HH:mm – in X Minuten“.
2. Mod „Aufgaben-Friedhof“ (docs/examples/aufgaben-friedhof.js) als Skript-Mod anlegen, Rechte tasks.read + notify, Trigger „Tagesstart“ → meldet montags alte offene Aufgaben (bis zu 3 mit Namen), löscht nichts.
3. Ein Skript-Mod mit Recht „island.text“ und `taby.island.set("Deadline: noch 3 Tage", 3600)` → der Text steht an der Notch, solange nichts Wichtigeres ansteht; nach Ablauf verschwindet er.
4. Mitschnitt → „Als .pcap für Wireshark speichern“ → die Datei öffnet sich in Wireshark mit allen Paketen.
5. Mods → Bibliothek → „Hinzufügen“ bei „Wetter in der Notch“ → „Freigeben & einschalten“ → „Testen“ (Notch zeigt „Köln … °C“; Internet nur an open-meteo.com).

## Cloud-Sitzung 2026-10-13 – Vorlesen-Knopf, Diktat-Meldungen (ungebaut!)
In der Cloud gibt es kein Swift/macOS: diese Änderungen sind **nicht kompiliert und nicht geprüft**.
Zuerst `cd mac && swift run TabyChecks` (Exit 0) und Snapshots von „Heute“ und Einstellungen → Sprache ansehen.
1. Heute → Lautsprecher-Knopf oben rechts → Taby liest Termine der nächsten 60 Minuten und offene/überfällige Aufgaben vor,
   auch wenn „Taby spricht“ aus ist.
2. Einstellungen → Sprache → „Vorlesen-Knopf“: 15/30/60/120 oder frei (5–1440 Min) → Knopf liest nur diesen Zeitraum.
3. Diktat: Control+Option+S halten. Erstes Mal → Freigabedialoge für Spracherkennung und Mikrofon.
   Sprechen → Teiltext im Schnellerfassungsfeld; loslassen → Aufgabe/Notiz entsteht.
4. Diktat-Fehler sind jetzt sichtbar statt still: Mikrofon-Freigabe aus → „Nichts verstanden: Das Mikrofon liefert nur Stille …“;
   Diktat in Systemeinstellungen → Tastatur aus → „Die Spracherkennung hat abgebrochen (<Fehlercode>) …“.
   Den Fehlercode bitte notieren, falls Diktat weiter nicht geht (steht auch in der Konsole unter „Diktat:“).
   Ungeklärt: ob die erzwungene Erkennung auf dem Gerät (`requiresOnDeviceRecognition`) ohne geladenes Diktat-Sprachpaket scheitert.

## Paket 9 – Notion-Aufgaben (read-only)
1. Einstellungen → Erinnerungen → Notion-Aufgaben → Integrationstoken einfügen → Verbinden.
2. Datenbank-ID ODER Seiten-ID eintragen, Einschalten, Speichern, „Jetzt abgleichen“.
3. Zeilen/To-dos erscheinen als Aufgaben in Taby; in Notion wurde nichts verändert (nur lesende Aufrufe).
4. Nochmal abgleichen → keine Dubletten, geänderte Titel/Status werden übernommen.
5. „Trennen“ → Token weg, Import aus; bereits importierte Aufgaben bleiben lokal erhalten.

## Paket 10 – Tagesplan bearbeiten, Prioritätsliste
1. Heute-Tab → Plan: Pfeile ↑/↓ verschieben Blöcke, ✕ nimmt einen Block aus dem Plan; der oberste ↑ und unterste ↓ sind ausgegraut.
2. Aufgaben-Tab: Stern an einer Zeile setzen → erscheint in der Karte „Priorität“ oben; Reihenfolge dort mit ↑/↓ ändern, danach „Neu planen“ → Plan folgt der Priorität.
3. Stern erneut antippen (oder ✕ in der Prioritätskarte) → Aufgabe fällt aus der Prioritätsliste, bleibt aber als Aufgabe erhalten.

- [ ] Aufgaben: Kategorie-Symbol (Tag/Koffer/Haus) beim Überfahren einer Zeile prüfen, Klick-Zyklus nil → Arbeit → Privat → nil, Filter "Alle/Arbeit/Privat" und Notch-Zahl "N offen" bleibt gesamt. Hover-Zustand ist im Snapshot nicht sichtbar.

## Paket 11 – Mehrere Notion-Quellen, Unterreiter
1. Einstellungen → Erinnerungen → Notion-Aufgaben: „+ Quelle hinzufügen“ → Name, Kategorie (Tickets/To-dos/Weekly) und Link eintragen; Änderungen wirken sofort (ohne Speichern).
2. „Jetzt abgleichen“ holt alle Quellen; Tickets (Datenbank) und To-dos/Weekly (Seite) erscheinen als Aufgaben. Nur mit einem echten Notion-Workspace prüfbar (in Taby nur mit Fakes getestet).
3. Notion-Reiter: je Quelle ein Unterreiter mit dem Quellnamen; Umschalten zeigt nur die Aufgaben dieser Quelle.
4. ✕ an einer Quelle entfernt sie aus der Liste; Taby schreibt nie in Notion.
5. Der Name einer Quelle wird automatisch vom Notion-Seiten-/Datenbanktitel übernommen, solange noch kein eigener Name vergeben wurde (Link einfügen oder nächster Abgleich holt ihn nach) – nur mit echtem Notion-Workspace prüfbar.
6. "Mit Notion anmelden" (OAuth, für Gäste ohne Admin-Zugang): öffnet den Browser zur Notion-Anmeldung; die Verbindung ist mit `https://notion-callback` registriert. Nach der Zustimmung zeigt der Browser „Seite nicht erreichbar“ – die Adresse aus der Browserzeile (`https://notion-callback?code=…`) kopieren, im Feld unter „Mit Notion anmelden“ einfügen und „Übernehmen“ drücken. Nicht vollständig durchgespielt – der echte Notion-Login/Seiten-Auswahl-Dialog wurde nicht mit einem echten Workspace getestet. Braucht: eine echte Öffentliche Verbindung bei Notion (Client ID `3f8d872b-594c-81d4-9459-003791f2ff80`) und das Client-Secret im Schlüsselbund (`security add-generic-password -a "Taby" -s "notion-oauth-client-secret" -w`).
7. Weekly-Quelle: Eine Seite mit einem Weekly je Woche (Unterseiten oder Zeilen einer eingebetteten Tabelle). Nach „Jetzt abgleichen“ stehen im Notion-Reiter die Aufgaben aus den Weeklies, gruppiert nach Woche, die neueste aufgeklappt. Wird eine Aufgabe in Notion in eine andere Woche verschoben, bleibt die alte Gruppe stehen, bis sie sich sonst ändert. Nur mit echtem Workspace prüfbar.
8. Tickets-Quelle auf einer verknüpften Ansicht: Taby meldet „verknüpfte Ansicht – Originaldatenbank freigeben“. Nach Freigabe der Originaldatenbank für die Verbindung klappt der Abgleich.
9. Tickets mit Seiteninhalt: Offene Tickets lassen sich im Notion-Reiter per Pfeil aufklappen und zeigen den Seiteninhalt sowie „In Notion öffnen“. Notizen eines Tickets kommen aus Notion und werden beim Abgleich überschrieben.
10. Weekly als Datenbank (eine Zeile je Termin, gleicher Titel, Datumsspalte): Die Gruppen heißen „TT.MM.JJJJ · Titel“, die neueste ist aufgeklappt. Jede Woche enthält das Weekly selbst (aufklappbar mit der ganzen Seite) und ihre Häkchen-Aufgaben. Nur mit echtem Workspace prüfbar.
11. Notion-Reiter Stufe 1: Reiter „Tickets / Weekly / To-dos“ mit Zähler; Quellenauswahl nur bei mehreren Quellen je Bereich. Tickets zeigen „Ersteller · Datum · Status“ (Datum orange ab 14 Tagen). Der Ersteller-Name erscheint nur, wenn die Notion-Verbindung „Benutzerinformationen lesen (ohne E-Mail)“ hat. Weekly: Checkboxen im Inhalt sind anklickbar und haken in Notion ab; nicht zuordenbare sind ausgegraut („Nur in Notion abhakbar“). Gleichnamige To-dos in unterschiedlicher Tiefe einer Seite können vertauscht zugeordnet werden. Nur mit echtem Workspace prüfbar.

## Hänger / Schlüsselbund (Freunde-DMG, ad-hoc signiert)
1. Taby aus der DMG über eine ältere Version installieren (mit API-Schlüssel und Notion-Kalender- oder Notion-Aufgaben-Token). Erwartung: je Geheimnis höchstens EINE Schlüsselbund-Abfrage pro Programmlauf (vorher bei jedem Neuladen und alle 30 s für das Notion-Kalender-Token). Während einer offenen Abfrage kann Taby kurz stehen – nach „Immer erlauben“ läuft es flüssig weiter.
2. Nach „Ablehnen“ fragt Taby in diesem Lauf nicht erneut; neues Eintragen des Schlüssels in den Einstellungen wirkt sofort.
3. Mehrere schnelle Klicks (Aufgaben abhaken, Notion abgleichen) dürfen keinen Beachball erzeugen. Nur am echten Mac prüfbar.

## Absturz EventKit / Systemlast
1. Apple Kalender und Apple Erinnerungen (Abgleich an) aktiv, Insel öffnen/schließen, Kalender-Reiter wechseln, Aufgaben abhaken, mehrere Stunden laufen lassen. Erwartung: kein Absturz mehr (vorher `EXC_BAD_ACCESS` in `EKPredicateSearch` bzw. `doesNotRecognizeSelector`, siehe `~/Library/Logs/DiagnosticReports/Taby-*.ips`). Termin anlegen/löschen und Erinnerungen anlegen müssen weiter gehen.
2. Aktivitätsanzeige: CPU von Taby und WindowServer bei geschlossener Insel (Maus weit weg) und bei offener Insel notieren. Erwartung geschlossen: Taby im niedrigen einstelligen Prozentbereich, WindowServer ohne Taby nicht merklich anders. Das Maskottchen zeichnet geschlossen weiter mit 15 Bildern/s, offen mit 60 – falls das spürbar ist, melden.
3. Netzwerk-Wächter an, Gerätescan läuft (alle 10 min): Taby darf währenddessen nicht hängen (Chat, Reiterwechsel, Abhaken). Vorher blockierten Namensauflösungen alle Hintergrund-Threads.
12. Reiter verschieben: In der geöffneten Notch ein Reiter-Symbol auf ein anderes ziehen; es landet an dessen Stelle (auch über die Notch hinweg). Ein Klick wählt weiter den Reiter. Die Reihenfolge bleibt nach Neustart erhalten; Einstellungen → Allgemein → „Reiter-Reihenfolge zurücksetzen“ stellt den Standard her.

## Paket 12 – Nachrichten (iMessage) und Kalender aus dem Chat
1. Einstellungen → Verbindungen → iMessage verbinden **ohne** Festplattenvollzugriff: Fehler „Taby braucht den Festplattenvollzugriff …“. Freigabe erteilen (Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff), Taby neu starten → Verbindung klappt, Reiter „Nachrichten“ erscheint.
2. Echte `~/Library/Messages/chat.db` (läuft im WAL-Modus, Messages geöffnet): Liste zeigt die neuesten Unterhaltungen mit Titel (Gruppenname bzw. Nummer/E-Mail, keine Kontaktnamen), letzter Text, Zeit, Ungelesen-Zahl. Neue Nachricht vom Handy schicken → erscheint binnen eines Takts in Taby (beweist: WAL wird mitgelesen), Insel zeigt genau EINEN Hinweis je Nachricht, eigene Nachrichten keinen.
3. Nachrichten mit Formatierung/Emoji/Links (nur `attributedBody`, `text` leer): Text erscheint korrekt, nie Absturz; reine Anhänge zeigen „(Anhang)“.
4. Unterhaltung öffnen → Ungelesen-Zahl geht auf 0 (Taby-Lesestand; Messages selbst bleibt ungelesen).
5. Senden: erste Nachricht löst die Automation-Abfrage („Taby möchte Messages steuern“) aus. Ablehnen → Hinweis „… Automation“; erlauben → Nachricht kommt an. Text mit `"`, `\`, Zeilenumbruch und `& do shell script` wird wörtlich gesendet.
6. Trennen → Reiter „Nachrichten“ verschwindet, nach Neustart bleibt das Konto (bzw. bleibt getrennt).
7. Chat: „Lösch den Termin X“ → Insel fragt „Termin „X“ löschen“; erst Bestätigen löscht (in Apple Kalender prüfen). „Verschieb X auf morgen 15 Uhr“ → „Termin „X“ verschieben auf … 15:00“; nach Bestätigen liegt der Termin dort mit gleicher Dauer, das Original ist weg. Ablehnen lässt alles unverändert.
8. Apple Kalender verbunden, keine Quelle ausdrücklich „Hier eintragen“: neue Termine aus dem Chat landen im Apple Kalender, Einstellungen zeigt dort den Chip „Standard“.

## Paket 13 – Aufgaben für heute selbst einplanen
- [ ] Aufgaben → „Heute planen“ (oder Heute → „Aufgaben wählen“): Aufgaben abhaken → „Weiter“ → je Aufgabe „Automatisch“ oder „Uhrzeit“ + Dauer → „Einplanen“: Plan zeigt feste Zeiten mit Stecknadel, der Rest liegt in freien Lücken.
- [ ] Feste Uhrzeit über einem Termin: gelbe Warnung „überschneidet …“; ganztägige Termine warnen nicht; 23:30 + 60 Min warnt „endet nach Mitternacht“ und der Block endet um 23:59.
- [ ] Im Plan einen Block anklicken: Uhrzeiten-Schritt öffnet mit ALLEN Plan-Aufgaben; Zeit ändern → „Einplanen“: geänderte Aufgabe steht neu, die anderen bleiben im Plan.
- [ ] Angeheftete Zeit bleibt: „Neu planen“, neuer Termin dazwischen und Pfeile ↑/↓ verschieben nur automatische Blöcke; ✕ nimmt auch einen angehefteten Block heraus.
- [ ] Angeheftete Aufgabe abhaken oder löschen: Block verschwindet aus dem Plan (wie automatische).

## Notizen: Checkboxen und Groß öffnen
- [ ] Notiz aufklappen, "Groß öffnen" (Pfeil-Symbol): eigenes Fenster füllt Breite und Höhe, Liste scrollt darin.
- [ ] "Bearbeiten", Knopf "Checkbox" und ⌘⇧C hängen `- [ ] ` an; "Sichern" speichert.
- [ ] In der Lese-Ansicht eine Checkbox anklicken: sofort abgehakt, nach Neustart noch so; zweimal schnell klicken verliert nichts.

## Notion Weekly: Datums-Chips
- [ ] Weekly zeigt eine Chip-Reihe mit Datum (z. B. 13.10.) und Zahl offener To-dos; viele Wochen scrollen seitlich.
- [ ] To-do in der gewählten Woche abhaken: erscheint auch in Notion als erledigt.
- [ ] Besprechung steht als leichte Kopfzeile (Kalender-Symbol) oben, "Ganze Seite" klappt den Inhalt auf.

## Element / Matrix (nur mit eingebauter Matrix-SDK)
- [ ] Verbindungen → Element → „Verbinden“: Server (z. B. matrix.org), Benutzer, Passwort → Karte zeigt die Kennung bzw. „Gesperrt – Sicherheitsschlüssel fehlt“. Falsches Passwort → „Anmeldung fehlgeschlagen …“, kein Ordner unter `~/Library/Application Support/de.felix.taby/Matrix/` bleibt zurück.
- [ ] In Element (anderes Gerät) → Einstellungen → Sitzungen: neues Gerät „Taby (Mac)“ erscheint.
- [ ] Gesperrt: Sicherheitsschlüssel eingeben → Karte springt ohne Neustart auf „verbunden“. Falscher Schlüssel → „Sicherheitsschlüssel passt nicht.“; ohne Netz → „Entsperren fehlgeschlagen …“.
- [ ] Nachrichten: Räume mit Titel, Ungelesen-Zahl und letzter Nachricht; nicht entschlüsselbare zeigen „(verschlüsselt)“. Neue Nachricht von außen → Insel-Hinweis nach ≤ 20 s.
- [ ] Senden aus Taby → kommt in Element an (auch im verschlüsselten Raum). Öffnen setzt die Ungelesen-Zahl auf 0 (auch in Element).
- [ ] Neustart von Taby: Konto kommt ohne erneute Anmeldung zurück; Karte zeigt nach kurzer Zeit „verbunden“ (kein kurzes falsches „Gesperrt“).
- [ ] Trennen: „Taby (Mac)“ verschwindet aus Elements Sitzungsliste, der Kontoordner unter `…/de.felix.taby/Matrix/` ist weg, Schlüsselbund-Eintrag „messenger-…“ gelöscht.
- [ ] Mit anderem Gerät bestätigen: in Element (Handy/Web) Anfrage annehmen → gleiche Emojis in Taby und Element; „Stimmen überein“ → Karte „verbunden“, verschlüsselte Nachrichten lesbar. „Stimmen nicht“ / Abbrechen → kein Hängenbleiben, erneut versuchbar.

## Slack (eigene App, Nutzer-Token)
- [ ] Anleitung in der Slack-Karte durchgehen (App anlegen, Scopes, installieren, `xoxp-…` einfügen) → Karte „verbunden“, Kanäle und Direktnachrichten erscheinen mit Namen.
- [ ] Neue Nachricht von außen → Insel-Hinweis nach ≤ 20 s; Öffnen setzt die Zahl auf 0 und sie kommt nicht zurück.
- [ ] Senden aus Taby → kommt in Slack an. Falscher Token → deutsche Fehlermeldung, kein Token im Text.

## Notch und Updates
- [ ] Geschlossene Notch: links Taby, Mitte rollt (Wetter, Mod-Texte, ungelesene Chats, eigener Text) alle 3,5 s ruhig von oben nach unten, rechts Aufgaben-Zahl + nächste Aufgabe. Mit Reduce Motion nur Überblenden.
- [ ] Einstellungen → Wohnort eintragen, Mod „Wetter in der Notch“ einschalten → Wetter erscheint sofort (nicht erst zur vollen Stunde).
- [ ] Update: alte Version installiert, neuere auf GitHub → Mitteilung „Taby-Update verfügbar“ (einmal je Version). Einstellungen → „Jetzt aktualisieren“ → Taby beendet sich, startet neu als neue Version; Freigaben (Schlüsselbund, Kalender) bleiben; alte App im Papierkorb; Log unter ~/Library/Logs/Taby-Update.log.
- [ ] Update-Adresse auf eigene GitHub-Adresse/Ordner ändern → Suche nutzt diese Adresse; falsche Adresse → deutsche Fehlermeldung.

## Sicherheits-Fixes (Team-Prüfung)
- [ ] Notion-Anmeldung: „Mit Notion anmelden“ → Browser → Adresse einfügen → „Verbunden.“. Eine fremde oder
  alte Adresse (zweiter Klick, anderer Lauf) → Meldung „gehört nicht zu dieser Anmeldung“.
- [ ] Notion-Token: Altbestand aus einer früheren Version (Token in der Kalenderquelle) verschwindet nach dem
  Start aus der Datenbank; Notion-Kalender weiter lesbar; Schlüsselbund-Eintrag „calendar-token-…“ vorhanden.
- [ ] Paket-Mitschnitt: Administrator-Dialog erscheint, Pakete laufen ein, Stopp funktioniert, .pcap lässt sich
  speichern. Der Ordner `/private/var/tmp/taby-capture.*` gehört nach dem Stopp dem Nutzer (`ls -ld`), so
  dass er sich löschen lässt.
- [ ] Lokales Modell (http://localhost) mit Schlüssel funktioniert; Remote-Adresse mit http:// zeigt
  „Der Schlüssel wird nur über https gesendet.“
- [ ] Ein eigenes Modell mit `curl` bei mehr als 8 parallelen Verbindungen zur MCP-Brücke: die 9. wird
  geschlossen, die anderen antworten.


## Runde 1 (2026-10-15)
- [ ] Aufgaben: im Filter „Arbeit“ anlegen → Aufgabe hat Arbeit, steht auch unter „Alle“. Stift → Datum/Uhrzeit setzen, ändern, entfernen (Enter speichert, Esc bricht ab).
- [ ] Heute → Plan: Zeile mit der Maus ziehen (auch am Titel greifen) → Reihenfolge ändert sich; Esc/außerhalb loslassen → nichts bleibt blass hängen.
- [ ] Gedächtnis „Mittagspause von 12 bis 13 Uhr“ → Plan erstellen lässt 12–13 frei; „keine Mittagspause mehr“ → wieder frei planbar.
- [ ] Schnellerfassung ohne Netz → Gedanke landet als Aufgabe.
- [ ] Notion: Titel/Fälligkeit einer Notion-Aufgabe in Taby ändern → nach ≤ 15 min in Notion; Taby neu starten vor dem Abgleich → Änderung bleibt; Datenbank mit „Erledigt am“ + „Fällig“ → nur „Fällig“ wird geschrieben; Zeitraum mit Ende bleibt erhalten.

## Runde 2 (2026-10-15)
- [ ] Reiterleiste: nur Haupt-Reiter, Rest unter „Mehr“; „Einstellungen“ öffnet ein eigenes Fenster.
- [ ] Einstellungen: Feld ändern → nach kurzer Pause „Gespeichert“. Endpunkt-URL halb tippen und warten → wird NICHT gespeichert; Enter mit ungültiger URL → rote Meldung. Schlüssel einfügen und Fenster sofort schließen → Schlüssel ist gespeichert.
- [ ] Belegtes Tastenkürzel (z. B. eines von Spotlight) → roter Hinweis.
- [ ] Leerer Chat: Beispiel antippen → steht im Feld, wird nicht abgeschickt.
- [ ] Im Fokus: „Vorlesen“ → Hinweis „Im Fokus oder Termin bleibt Taby still.“
- [ ] Planen → Aufgaben wählen: Gruppen Notion-Tickets / Notion-Quellen / Arbeit / Privat / Ohne Kategorie.
- [ ] Aufgaben: Ordner anlegen, Aufgabe hineinlegen (Ordner-Symbol), umbenennen und löschen (Rechtsklick) → Aufgaben bleiben erhalten; mit gewähltem Ordner neue Aufgabe anlegen → landet im Ordner.
- [ ] Kalender: „Kalender neu laden“ lädt sofort.
- [ ] Musik: Apple Music oder Spotify spielt → Notch zeigt Titel und Interpret nach höchstens 10 s; Play/Pause, Weiter und Zurück steuern die gezeigte App. Automation-Freigabe erteilen, wenn macOS fragt.
- [ ] Musik-Freigabe verweigert → Hinweis „Taby darf Musik/Spotify nicht steuern – Systemeinstellungen → Datenschutz → Automation.“
- [ ] Sicherung wiederherstellen → Taby startet neu, enthält den Stand der Sicherung, `restore-plan.json` ist danach weg.

## Kontakte (2026-10-15)
- [ ] Erste Nutzung im Chat („Wer ist Anna?“ → find_contact) zeigt den Systemdialog „Kontakte“; Freigabe → Treffer mit Name, Firma, E-Mail, Telefon.
- [ ] Freigabe verweigert → Antwort enthält „Kein Zugriff auf Kontakte – Systemeinstellungen → Datenschutz → Kontakte.“ und keine Treffer.
- [ ] „Schreib Anna eine Mail …“ → Bestätigungskarte nennt die echte Adresse; bei zwei Annas fragt Taby nach, sendet nichts.
- [ ] Geburtstag heute in den Kontakten (nach Freigabe) → Heute-Tab zeigt „🎂 Heute: Name“ mit Anrufen, FaceTime (nur mit Telefonnummer) und Nachricht; Anrufen/FaceTime öffnen die App, Nachricht legt den Namen in die Zwischenablage.
- [ ] Geburtstage erscheinen erst, wenn die Freigabe erteilt ist; der Dialog kommt nur bei ausdrücklicher Kontakte-Nutzung (Suche, Senden).
- [ ] Tagesstart mit Geburtstag → Briefing nennt „Geburtstag“ (Namen gehen dabei an das Modell in der Cloud, sofern kein Apple Intelligence).

- [ ] Status automatisch an: Fokus starten → Slack zeigt „Im Fokus“ mit Kopfhörer bis Fokus-Ende; Fokus beenden → Status weg. Termin jetzt → „Im Termin“. Eigenen Status vorher setzen → Taby überschreibt ihn nicht. Slack-App ohne users.profile:write → Verbindungskarte zeigt „Slack-App braucht das Recht users.profile:write“.

## Alltags-Pakete (2026-10-16)
- [ ] Kontakte: Chat „Schreib Anna …“ → Freigabe-Dialog Kontakte, Karte zeigt die richtige Adresse; zwei Annas → Rückfrage. Geburtstag heute → Zeile in Heute mit Anrufen/FaceTime.
- [ ] Dateien: Heute → Suche „Angebot“ → Gruppe Dateien, Öffnen / Im Finder zeigen. Mit OpenRouter kein „Zusammenfassen“; mit Apple Intelligence Zusammenfassung lokal.
- [ ] Merk dir das: ⌃⌥M in Safari / Mail / Finder → Karte mit Titel/Link; Notiz, Aufgabe, Später lesen. Automation-Freigabe erscheint je App einmal.
- [ ] Eingang: Nachrichten → Eingang zeigt „Antwort nötig“ / „Wartet“; Antworten öffnet Mail-Entwurf (sendet nicht); Erledigt bleibt nach Neustart weg.
- [ ] Daraus wird was: Mail mit „Freitag 10:30“ → „Termin erkannt“ → Karte, Anlegen prüft Konflikte; „Daraus Aufgabe“ mit Link zurück zur Mail.
- [ ] Status automatisch (Slack, Recht users.profile:write): Fokus starten → Slack „Im Fokus“, Ende → weg; eigener Status bleibt unangetastet.
- [ ] Privat: Einstellungen → Erinnerungen → Liste wählen; Chat „Milch und Brot auf die Liste“ → in Apple Erinnerungen. Nach Termin „Nachbereitung als Mail-Entwurf“ → Entwurf an Teilnehmer.
- [ ] Notch-Freigaben: Tippen in anderen Apps löst nichts aus; ⌘⏎ erlaubt, ⌘. lehnt ab (auch prüfen: kein Konflikt mit dem Chatfeld).

## Lokale Modelle, Suche, Chatverlauf (2026-10-16)
- [ ] Lokal: Einstellungen → Modell → „Lokal (Ollama / LM Studio)“ mit laufendem Ollama (Port 11434) → Hinweis „nichts verlässt den Rechner“, kein Schlüsselfeld. „Modelle laden“ listet die Ollama-Modelle; Wahl über das Menü, „Verbindung testen“ grün. Nicht geprüft: echter Ollama- und LM-Studio-Lauf (in der Entwicklung nicht installiert).
- [ ] LM Studio: Schalter „LM Studio statt Ollama“ setzt Port 1234; Modelle laden zeigt LM-Studio-Modelle. Ohne laufenden Server: verständliche Fehlermeldung, kein Absturz.
- [ ] Picker-Menü (Chat- und Briefing-Modell) lädt die Liste erst beim Öffnen; SwiftUI-Menü auf dem Mac muss das Öffnen wirklich melden (sonst bleibt „Keine Vorschläge“, „Modelle laden“ hilft trotzdem).
- [ ] Heute → Suche „Angebot“ → Treffer antippen: Aufgabe öffnet Aufgaben, Notiz Notizen, Termin Kalender; Suche schließt sich.
- [ ] Nachrichten-Reiter ausgeblendet (Einstellungen → Reiter): Heute zeigt „Eingang“ mit Chat-Nachrichten, keine Mail-Einträge.
- [ ] Allgemein → Chatverlauf behalten 7 Tage: nach Neustart am nächsten Tag sind ältere Nachrichten weg; „immer“ löscht nichts.
- [ ] Datenschutz (A3): Einstellungen → Datenschutz zeigt die Tabelle mit echten Diensten; Chat mit Cloud-Modell ohne Einwilligung fragt vor dem Senden („Einverstanden“ / „Nur lokal nutzen“), danach geht die Nachricht ab. „Einwilligung zurückziehen“ fragt wieder. Nur lokal ohne Apple Intelligence zeigt den Hinweis im Chat. Mit Apple Intelligence am echten Mac prüfen.
- [ ] Umbenennung Taby → Lumi am echten Mac: Lumi.app startet mit Menüleisten-Titel „Lumi“, Dienst „Mit Lumi erfassen“ funktioniert (Dienste-Eintrag nach Neuanmeldung), Freigaben (Kalender, Erinnerungen, Mikrofon) bleiben erhalten.
- [ ] Update von einer alten Taby.app auf eine Lumi-DMG am echten Mac: Taby.dmg aus download/ wird geladen, App wird an ihrem bisherigen Pfad ersetzt, Log in ~/Library/Logs/Taby-Update.log zeigt „Einrichtung ok“.
- [ ] Was jetzt? (B3) am echten Mac: Knopf „Was jetzt?“ neben „Fokus starten“ wählt eine Aufgabe, zeigt „Jetzt: …“ und startet den Fokus; bei laufendem Fokus erscheint „Fokus läuft schon.“. Tagesplan: Info-Knopf am Block zeigt den Grund. Die Snapshots prüfen nur das Aussehen, nicht die Klicks.

## Leerlauf-Last (Lumi, geschlossene Insel)
- [ ] Activity Monitor / Instruments: Lumi mit geschlossener Insel ruhig laufen lassen; CPU und Aufwachvorgänge (Idle Wake Ups) notieren. Erwartung: Figur steht still.
- [ ] Musik in Music oder Spotify starten: Laufband zeigt die Musik-Zeile, Abfrage alle 10 s. Ohne sichtbare Musik-Zeile nur alle 60 s.
- [ ] Figur antippen: Reaktion läuft kurz, danach wieder ruhend.
- [ ] Systemeinstellung „Bewegung reduzieren“ an: Figur bleibt stehen, auch beim Öffnen.

## Mail per IMAP direkt (Paket D3)
- [ ] Einstellungen → Mail → „IMAP direkt“ mit echtem Server (z. B. imap.gmx.net, imap.web.de, Dovecot), Benutzer und Passwort: „Verbindung testen“ meldet „Verbindung hergestellt. Im Posteingang liegen N Mails.“
- [ ] Falsches Passwort: Meldung „Anmeldung am Mailserver fehlgeschlagen …“, kein Passwort im Log (~/Library/Logs) und in keiner Meldung.
- [ ] Passwort liegt im Schlüsselbund unter „mail-imap-password“ (Schlüsselbundverwaltung), nicht in der Einstellungsdatei.
- [ ] Posteingang-Überblick zeigt Mails der letzten 7 Tage mit Absender und Betreff (inkl. Umlauten und =?UTF-8?…?= im Betreff); Körper erst beim Öffnen.
- [ ] Archivieren und Papierkorb verschieben: Mail erscheint im Server-Archiv bzw. Papierkorb; Server ohne MOVE-Fähigkeit meldet das.
- [ ] Gesendet wird nichts per SMTP; „Senden“ öffnet einen Entwurf in Apple Mail (dort ist ein Konto nötig).
- [ ] Ungeprüft im Code: Mail-Ordner mit nicht-ASCII-Namen (modifiziertes UTF-7), Passwörter mit Nicht-ASCII-Zeichen (LOGIN mit quoted string), Anhänge und mehrteilige Mails mit verschachtelten Teilen.
## Anbieter-Voreinstellungen (Modell)
- [ ] Echter Schlüssel je Anbieter (OpenAI, Anthropic, Gemini, Mistral, Groq, DeepSeek): Verbindung testen, Modelle laden, Chat-Antwort prüfen.
- [ ] Anthropic über den OpenAI-kompatiblen Endpunkt mit Bearer-Schlüssel: prüfen, ob /models und /chat/completions antworten (nicht gegen echtes Netz geprüft).
- [ ] Anbieterwechsel: Schlüssel bleibt beim alten Host, neuer Host zeigt „gesetzt“ nur mit eigenem Schlüssel; Einwilligung wird für den neuen Host erneut gefragt.
- [ ] Verbrauch bei Nicht-OpenRouter: nur Tokens, keine Beträge.

## Performance-Runde (Hintergrund-Lasten)
- [ ] Apple Mail: Abruf alle 15 Minuten; die JXA-Abfrage liest das Konto je Nachricht weiter (Mailbox-Aufruf einmal je Nachricht). Mit echtem Mail-Konto prüfen, ob Konto und Ordner je Nachricht stimmen.
- [ ] iMessage: eine offene, schreibgeschützte Verbindung zu chat.db über mehrere Takte; neue Nachricht erscheint im nächsten Takt. Nach Festplattenvollzugriff-Entzug/-Erteilung prüfen, dass die Verbindung neu öffnet.
- [ ] Insel zu, keine neuen Nachrichten: Messenger-Takt wird 300 s, bei Nutzung wieder 60 s.
- [ ] Termine von heute: nach Erstellen oder Löschen eines Termins in Lumi sofort im Plan; nach Änderung im Kalender-Programm innerhalb weniger Sekunden (EKEventStoreChanged).
- [ ] Datei fragen (askAboutFile) mit großem PDF/Scan: Notch bleibt während der Texterkennung bedienbar.
- [ ] Start: tägliche Sicherung erscheint im Backups-Ordner etwa 30 s nach dem Start.

## Runde 5 – Welle F
- [ ] Echte Maus in der Notch: Hover öffnet die Vorschau (Peek), Klick öffnet, Anheften bleibt offen, Verlassen schließt wieder. Nach dem Umbau auf die ereignisgesteuerte Shell prüfen, ob keine Zustände hängen bleiben.
- [ ] Apple Kalender: Termin an Ort und Stelle verschieben; Teilnehmer bleiben erhalten (keine Neuanlage mit leerer Teilnehmerliste).
- [ ] Sicherung zurückspielen: Lumi startet neu, Daten und Einstellungen stehen wie in der Sicherung; die vorherige Stand-Sicherung liegt im Backups-Ordner.
- [ ] Aufbewahrung ändern: „Automatisch löschen nach“ (Sicherungen) auf 1 Tag stellen, Lumi neu starten bzw. eine Stunde warten; ältere Sicherungen verschwinden, die neueste bleibt. Protokoll-Aufbewahrung ebenso prüfen.
- [ ] Datenschutz → Protokoll: eingeklappt beim Öffnen; aufklappen zeigt Einträge; „Jetzt löschen“ fragt nach, danach ist die Liste leer.
- [ ] Ungeprüft im Code: Bestätigungskarte für eine MCP-Anfrage mit sehr langen Argumenten („Alles anzeigen“ scrollt, Text bleibt im Karte-Rahmen).
- [ ] Ungeprüft im Code: Einstellungen speichern mit Schlüsselbund gesperrt zeigt die Fehlermeldung statt „Gespeichert“, der Schlüssel bleibt im Feld.
- [ ] Ungeprüft im Code: Update-Download zeigt den Fortschrittsbalken in den Einstellungen → Updates bis zum Neustart.
- [ ] Ungeprüft im Code: Kalenderquelle nicht erreichbar (z. B. Netz aus): Erinnerungen für Termine bleiben offen, bis die Quelle wieder antwortet.
- [ ] Ungeprüft im Code: Aufgabe wieder öffnen, deren Erinnerung noch in der Zukunft liegt: die Erinnerung feuert zur neuen Zeit.
- [ ] Ungeprüft im Code: Apple Erinnerungen entfernt eine Aufgabe → Rückgängig-Leiste zeigt „Aus Erinnerungen entfernt – rückgängig?“; Rückgängig legt die Erinnerung beim nächsten Abgleich neu an.
- [ ] Ungeprüft im Code: Notion-Quelle entfernen mit „Aufgaben löschen“ → Aufgaben weg; Rückgängig holt Quelle und Aufgaben zurück.
- [ ] Ungeprüft im Code: Mod, der eine Aufgabe erledigt, schreibt den Haken nach Notion zurück und legt einen Rückgängig-Eintrag an.
- [ ] Export nach Markdown zweimal hintereinander: Ergebnis nennt den Ordner „.vorher“ mit den vorherigen Notiz-Dateien.

## Runde 5 – Welle G

Nur ein echter Mac kann diese Punkte prüfen (Signatur, Neustart, Freigabe-Dialoge).

- [ ] Frische Installation (Lumi aus der DMG nach Programme, Rechtsklick → Öffnen): Einrichtungs-Assistent erscheint, Schritt 1 „Einrichtung abschließen“.
- [ ] „Einrichtung abschließen“ legt das Zertifikat „Taby Local Signing“ an; macOS fragt nach dem Schlüsselbund-Passwort, „Immer erlauben“ wählen. Danach `codesign -dv /Applications/Lumi.app` zeigt `Authority=Taby Local Signing`.
- [ ] Nach dem Signieren startet Lumi von selbst neu und der Assistent steht auf Schritt 2 („Wie soll Lumi denken?“).
- [ ] Zweiter Durchlauf (schon signiert): „Einrichtung abschließen“ geht sofort weiter, ohne Neustart.
- [ ] Lumi außerhalb von Programme (z. B. Schreibtisch): Schritt 1 zeigt den Grund „liegt nicht im Ordner Programme“ und „Anleitung öffnen“; „Überspringen“ funktioniert.
- [ ] Update: neue Lumi.app über die alte ziehen, Kalender- und Erinnerungs-Freigaben bleiben erhalten (keine erneute Abfrage).
- [ ] Schlüsselbund gesperrt oder Passwort abgebrochen: die Fehlermeldung nennt den Schritt, Lumi startet nicht neu.
- [ ] Mitteilungen: Beim Start fragt macOS nicht nach Mitteilungen; erst im Schritt „Mitteilungen“ oder beim ersten Erinnern.
- [ ] Freigabe-Zeilen: Bei „Nicht erlaubt“ erscheinen „Erneut versuchen“ und „Systemeinstellungen öffnen“; der Link öffnet die richtige Seite (Kalender, Erinnerungen, Mikrofon, Spracherkennung, Bedienungshilfen).
- [ ] Bedienungshilfen: Beim Klick auf „Erlauben“ steht „Wird gefragt…“ (nicht rot), bis macOS antwortet; nach Rückkehr in Lumi wird der Stand geprüft.
- [ ] Apple Mail: Mailzugriff wird nur eingeschaltet, wenn die Automation-Freigabe erteilt wurde.
- [ ] Anmeldestart-Schalter zeigt den echten Stand der Anmeldeobjekte in den Systemeinstellungen.
- [ ] Modell „Apple Intelligence“ (auf einem Mac mit Apple Intelligence): Auswahl setzt Chat und Briefing auf das Apple-Modell; ohne verfügbare Apple Intelligence fehlt die Karte.
- [ ] Cloud-Anbieter: Schlüssel speichern mit leerem Modell übernimmt den Vorschlag des Anbieters; beim ersten Chat fragt Lumi einmal um Erlaubnis.
- [ ] „Später“ auf der Modell-Seite schließt den Assistenten; beim nächsten Start erscheint er nicht mehr.
- [ ] Beispiel-Tag: Schalter legt drei Aufgaben, eine Notiz und den Termin 14:00–14:30 heute an; Menü „Beispiel-Tag entfernen“ erscheint nur, solange Beispiele da sind, und entfernt genau diese.
- [ ] „So geht’s…“ im Menü öffnet die Kacheln in eigenem Fenster; das „?“ im letzten Schritt zeigt dieselben Kacheln.
- [ ] Zwischen Schritten schließen und Lumi neu starten: Der Assistent setzt beim gemerkten Schritt fort.
- [ ] Ungeprüft im Code: Drag & Drop einer Datei auf die Notch öffnet den Chat (Kachel „Datei ablegen“ stimmt).
- [ ] Ungeprüft im Code: Der Termin „Beispiel: Kurze Abstimmung“ landet im Kalender, den Lumi als Standard nutzt (lokale Quelle, falls vorhanden).
- [ ] Schlüsselbund bei der Signatur (Einrichtung): macOS fragt pro Signatur; „Erlauben“ wählen (nicht „Immer erlauben“). Der Hinweis steht auf Schritt 1 und in der Meldung „Update wird eingespielt“.
- [ ] Bei einem Update fragt der Schlüsselbund einmal (Hinweis in der Meldung „Update wird eingespielt“); danach läuft die neue App signiert (`codesign -dv /Applications/Lumi.app` zeigt „Authority=Taby Local Signing“).
- [ ] Die laufende App nach dem Signieren: Lumi startet neu, der Assistent steht auf den Freigaben, wenn er aus der Menüleiste kam.
- [ ] Freigaben überleben das Update (TCC): Kalender und Erinnerungen fragen nach dem Austausch nicht erneut.
- [ ] Schlüsselbund-Dialog nicht bestätigen: nach 120 s meldet Lumi „Signieren nicht abgeschlossen“ mit dem Hinweis auf den Dialog.
- [ ] Anmeldestart: Schalter in Einrichtung und Einstellungen zeigt den echten Stand (Systemeinstellungen → Anmeldeobjekte), nie vorab an.
- [ ] Menüleiste „Nach Updates suchen…“ öffnet Einstellungen auf „Updates“, auch wenn das Fenster schon offen ist; die Seite steht in der Grundgruppe.
- [ ] Menüleiste „Einrichtung…“ nach erledigter Einrichtung: Signieren führt nach dem Neustart zu den Freigaben mit dem Hinweis „Nach dem Signieren fragt macOS die Freigaben noch einmal.“
- [ ] Tastenkürzel-Aufnahme: Taste drücken nimmt die Position (QWERTZ-Z), unbekannte Taste zeigt „Taste nicht unterstützt“, Esc bricht ab, nur eine Aufnahme gleichzeitig.
- [ ] Obsidian: Bestätigungskarte nennt „Notiz „<Name>.md“ in Obsidian unter Lumi“ (mit „(anhängen)“ bei Anhängen); Laufwerk getrennt: „Obsidian-Ordner nicht gefunden“ statt neuer Ordner.
- [ ] Beispiel-Tag: eigene Aufgabe mit „[Beispiel]“ bleibt beim Entfernen erhalten.

## Einstellungen neu gegliedert (ungeprüft am echten Mac)
- [ ] Tastenkürzel-Recorder: Klick auf eine Kombination, echte Tasten drücken (z. B. Control+Option+K) → Kürzel übernommen und wirksam; Esc bricht ab; „Zurücksetzen“ stellt die Vorgabe wieder her.
- [ ] Seitenleiste „Erweitert anzeigen“ an/aus: Verbindungen, Netzwerk, Export & Schnittstellen, Aufträge, Tastenkürzel, Updates erscheinen und verschwinden; Auswahl bleibt nach Neustart.
- [ ] Verbindungen → Obsidian-Karte: „Ordner wählen…“ öffnet den Dialog und zeigt den Pfad; „Entfernen“ leert ihn.
- [ ] Notion trennen und MCP-Server entfernen fragen vorher nach; Aufträge stoppen/entfernen fragt vorher nach.
- [ ] Heute: „Tagesplan“ und „Heute“ wechseln die Ansicht; im leeren Zustand öffnet „Aufgabe anlegen“ den Reiter Aufgaben mit Cursor im Eingabefeld; „Lumi fragen“ öffnet den Chat.
## Aufgaben-Kategorien (ungeprüft am echten Mac)
- [ ] Reiter Aufgaben: „+“ öffnet „Neue Kategorie“, Symbol wählen, Enter legt an und wählt sie; Dublette und 13. Kategorie zeigen die Meldung.
- [ ] Ordner-Kontextmenü „Kategorie ändern…“ verschiebt den Ordner in eine andere Kategorie; er erscheint nur dort.
- [ ] Klick auf das Kategorie-Symbol einer Aufgabe wechselt durch die Einstellungen-Kategorien und endet bei keiner.
- [ ] Einstellungen → Aufgaben: Hoch/Runter, Umbenennen und Löschen eigener Kategorien speichern automatisch; Arbeit und Privat lassen sich nicht löschen.

## Runde 5 – Welle H (Netzlaufwerke, Geheimnis-Suche; ungeprüft am echten Mac)
- [ ] Einstellungen → Verbindungen → Netzlaufwerke → „+ Netzlaufwerk“ mit `smb://<echter NAS>/<Freigabe>`, ohne Passwort: „Verbinden“ hängt die Freigabe unter /Volumes ein, Status „verbunden“, im Finder sichtbar.
- [ ] Dasselbe mit Passwort (Schlüsselbund-Eintrag `share-<id>` wird angelegt, das Passwort steht nicht in der Einstellungsdatei).
- [ ] Falsches Passwort: Meldung „Anmeldung abgelehnt – Benutzer oder Passwort prüfen.“ Den Fehlercode-Mapping gegen echte NetFS-Rückgaben prüfen (EAUTH/ENOENT/EHOSTUNREACH).
- [ ] Nicht erreichbarer Server: „Server nicht erreichbar“ nach höchstens 30 s, Oberfläche bleibt bedienbar.
- [ ] „Trennen“ hängt aus; bei geöffneter Datei erscheint der Trennen-Hinweis.
- [ ] „Beim Start verbinden“: nach dem Anmelden erscheint das Laufwerk ca. 10 s später, ohne Eingriff.
- [ ] Netzwerk-Reiter: Gerät mit offenem Port 445 zeigt „Als Netzlaufwerk verbinden“; danach steht smb://<ip>/ im Formular.
- [ ] Löschen fragt nach, entfernt Eintrag und Passwort (Schlüsselbund prüfen).
- [ ] Geheimnis-Suche: „Such mir das Passwort von <Dienst>“ mit Apple Intelligence an: Bestätigung in der Notch, dann Fundstelle im Gespräch, Wert ist in der Zwischenablage (Passwort-Manager-Feld, ConcealedType, TransientType). Auf anderen Geräten mit gleicher Apple-ID erscheint er nicht (Handoff ist aus); ein Zwischenablage-Verlauf (z. B. Paste, Maccy) kann ihn dagegen speichern – dort prüfen, ob er ausgeblendet wird.
- [ ] Zwischenablage ist nach 60 s leer, wenn inzwischen nichts anderes kopiert wurde; wurde etwas anderes kopiert, bleibt es unangetastet.
- [ ] Mit ausgeschalteter Apple Intelligence: Meldung „Das mache ich nur lokal …“, kein Netzverkehr (Netzwerk-Monitor prüfen).
- [ ] Protokoll (Einstellungen → Protokoll): Einträge „Netzlaufwerk … verbunden“ und „lookup_secret“ zeigen weder Passwort, Wert noch URL.

## Runde 5 – Welle H (Microsoft: Outlook und Teams; braucht ein Microsoft-Konto)
- [ ] Einstellungen → Verbindungen → Microsoft: Ohne Client-ID ist „Anmelden“ ausgegraut; eine falsche Form (z. B. „abc“) zeigt den Hinweis „Die Client-ID hat 36 Zeichen …“.
- [ ] „Wie bekomme ich eine Client-ID?“ öffnen: die fünf Schritte sind vollständig. Im Portal die App „Lumi“ anlegen (öffentlicher Client, `http://localhost`, „Öffentliche Clientflows zulassen“ = Ja) und die Anwendungs-ID eintragen. „Speichern“ wird erst aktiv, wenn die Form stimmt.
- [ ] „Anmelden“: Der Code erscheint groß. „Öffnen“ öffnet die Microsoft-Seite, „Code kopieren“ legt den Code in die Zwischenablage. Code dort eingeben, Lumi zeigt danach „Angemeldet als <Mail>“ (ca. 5–15 s nach der Bestätigung).
- [ ] „Abbrechen“ während des Wartens: die Karte kehrt zurück; nach dem Ablauf des Codes erscheint nichts mehr.
- [ ] Firmenkonto ohne Freigabe: Meldung „Deine IT muss Lumi einmal freigeben: Kalender, Chats und Status.“ (Anmeldung oder Abruf).
- [ ] Verweigern im Browser: „Die Anmeldung wurde abgebrochen.“
- [ ] Nach der Anmeldung erscheint die Quelle „Outlook“ unter Einstellungen → Kalender (aktiv, nicht Standard zum Schreiben); Termine der nächsten Tage stehen im Kalender mit Teams-Link in den Notizen.
- [ ] Termin in Lumi anlegen: erscheint in Outlook (Zeit stimmt, auch bei Sommerzeit). Termin in Lumi löschen: verschwindet in Outlook.
- [ ] Ganztägiger Termin in Outlook erscheint als ganztägig, nicht als 00:00-Termin.
- [ ] Abgesagter Termin in Outlook fehlt in Lumi.
- [ ] Nachrichten → Verbindungen: Teams-Karte zeigt „Erst bei Microsoft anmelden“ ohne Anmeldung, nach der Anmeldung „Verbinden“; danach Konto mit Mail-Adresse.
- [ ] Teams-Chats erscheinen mit Titel (Gruppenthema oder Name des Gegenübers), letzte Nachricht ohne HTML-Reste, Systemmeldungen nicht als Vorschau.
- [ ] Neue Nachricht in Teams: Hinweis in der Notch, danach ungelesen 1; Öffnen des Chats setzt den Zähler zurück.
- [ ] Senden aus Lumi: Nachricht erscheint in Teams als Text, nicht als HTML.
- [ ] Status automatisch (Einstellungen → Verbindungen/Allgemein, eingeschaltet): Während eines Fokus steht in Teams „Nicht stören“; nach Fokus-Ende ist es wieder frei. Ein eigener Teams-Status wird nicht überschrieben.
- [ ] Status automatisch ausgeschaltet: Teams bleibt unverändert (Netzwerk-Monitor: keine Aufrufe an graph.microsoft.com/…/presence).
- [ ] Trennen (Karte Microsoft): Bestätigung fragt nach; danach ist die Outlook-Quelle weg, Teams abgemeldet, und im Schlüsselbund fehlt „microsoft-refresh“.
- [ ] Nach einem Neustart von Lumi bleibt die Anmeldung erhalten (ohne erneuten Code), Outlook und Teams laden wieder.
- [ ] Protokoll und Diagnose: Weder Client-ID, Code, Token noch Nachrichtentext erscheinen dort.

## Runde 5 – Welle H (Musik ereignisgesteuert; ungeprüft am echten Mac)

Ersetzt die Abfrage alle 10 s / 60 s (Zeilen „Leerlauf-Last“ und „Musik: Apple Music oder Spotify spielt“ oben gelten so nicht mehr). Lumi fragt Musik und Spotify nicht mehr ab, sondern hört auf deren Benachrichtigungen.

- [ ] Musik spielt, Activity Monitor: Lumi bleibt nahe 0 % CPU (mit geschlossener und offener Insel).
- [ ] Titelwechsel in Music oder Spotify erscheint in der Notch innerhalb einer Sekunde.
- [ ] Pause und Weiter aktualisieren die Musik-Zeile.
- [ ] Music beenden: die Musik-Zeile verschwindet.
- [ ] Lumi bei laufender Musik starten: das gerade Lied erscheint (eine einzige Abfrage beim Start).
- [ ] Grenze: Spotify nur über die Desktop-App; Spotify im Browser wird nicht gesehen.

## Element: Antworten im Thread
- In einer Element-Unterhaltung eine eingegangene Nachricht antippen (am besten eine, die in einem Thread steht, erkennbar an „Thread · “ vor der Uhrzeit), antworten und in Element prüfen: Die Antwort steht im selben Thread, nicht als neue Raum-Nachricht.
- Eine Nachricht außerhalb eines Threads antippen und antworten: sie erscheint als normale Antwort.

## Aufgaben-Stand, Dauer, Pause, Kennzeichen, Notiz-Editor, Termin-Notiz (2026-10-27)
- [ ] Aufgabe mit Dauer anlegen (Sanduhr), auf „Heute“ antippen → „Jetzt beginnen“: spätere Aufgaben mit Uhrzeit rücken nach, Fälligkeit ändert sich.
- [ ] Fokus mit Aufgabe laufen lassen bis Ende: Karte „Zeit um“ mit Fertig / Noch 15 / Noch 30; auch als System-Mitteilung mit denselben Aktionen.
- [ ] Pause-Tasse (Heute) und Fokus anhalten/weiter: Countdown steht, Ende rückt um die Pause.
- [ ] Stand setzen (Offen / In Bearbeitung / Info fehlt), Gruppieren nach Stand und nach Kennzeichen, Filter nach Kennzeichen.
- [ ] Notiz-Editor: H1/H2, fett (⌘B), kursiv (⌘I), Listen mit Return fortsetzen, Checkbox, Zitat; langer Text springt nicht ans Ende.
- [ ] Termin in <15 Min: Karte → „Notizen mitnehmen“ → Agenda erstellen → „Termin-Notiz öffnen“ öffnet das Notizen-Fenster mit der Notiz.
- [ ] Nach dem Termin: „Zusammenfassung erstellen“ hängt die Zusammenfassung an und legt Aufgaben an.
- [ ] Insel angepinnt: Klick in ein anderes Fenster legt sie dahinter, Klick auf Lumi holt sie nach vorn.

## Meeting-Mitschrift lokal (2026-10-28)
- [ ] Mitschrift „nur ich“ starten: Mikrofon- und Spracherkennungs-Freigabe erscheinen, Sprechen erzeugt in der Termin-Notiz `- [mm:ss] Ich: …` (gebündelt, nicht pro Wort).
- [ ] Ohne deutsches Diktat-Paket: Start bricht mit deutscher Meldung ab, es wird nichts über die Cloud erkannt.
- [ ] „Alle“ erst nach Bestätigung möglich; Freigabe „Bildschirm- & Systemaudioaufnahme“ erteilen, Lumi neu öffnen; Ton aus Zoom/Teams/Meet (Kopfhörer) erscheint als `- [mm:ss] Andere: …`, Zeile `- Einwilligung aller Teilnehmer bestätigt um HH:mm` steht davor.
- [ ] Länger als 2 Minuten sprechen: Text reißt nach dem Neustart der Erkennung nicht ab und wird nicht doppelt geschrieben.
- [ ] Merker setzt `- [mm:ss] ★ Merker`; Stopp schreibt `- Mitschrift beendet um HH:mm`; Lumi spricht währenddessen nicht.
- [ ] Mitschrift endet 15 Minuten nach Terminende und beim Beenden von Lumi.
## „Lumi, erklär mir das“ (Ctrl+Opt+E, ungeprüft am echten Mac)
- [ ] In Safari einen Absatz markieren, Ctrl+Opt+E: Insel zeigt Ladezustand, dann die Erklärung (max. 6 Sätze) und liest sie vor.
- [ ] Gleiches in einem PDF (Vorschau) und in Mail: markierter Text kommt vollständig an, Zwischenablage danach unverändert.
- [ ] Ohne markierten Text: Hinweis „Markiere zuerst einen Text“. Ohne Bedienungshilfen-Freigabe: Freigabe-Hinweis.
- [ ] Einstellungen → Sprache & Vorlesen → „Erklärungen vorlesen“ aus: keine Stimme, Erklärung steht trotzdem in der Karte.
- [ ] Während einer laufenden Mitschrift: keine Stimme, Hinweis „Während der Mitschrift wird nicht vorgelesen“.
- [ ] „Im Chat weiterfragen“ öffnet den Chat mit dem Text im Eingabefeld; „Stopp“ bricht das Vorlesen ab.
- [ ] Ctrl+Opt+E ist nicht von einer anderen App belegt (sonst rot in den Kurzbefehl-Einstellungen).

## Meeting-Einstieg auf Heute
- [ ] Heute öffnen: Abschnitt „Meeting“ zeigt den nächsten Termin und „Spontan mitschreiben“.
- [ ] „Spontan mitschreiben“ → Modus wählen → Start; Termin-Notiz „Gespräch HH:mm – Agenda“ erscheint in Notizen.
- [ ] Termin antippen → „Notizen mitnehmen“ und „Mitschreiben“ funktionieren wie auf der automatischen Karte.

## Musik-Reiter
- [ ] Reiter „Musik“ erscheint in der Leiste (ggf. unter „Mehr“) und lässt sich ein-/ausblenden und verschieben.
- [ ] Spotify: in developer.spotify.com/dashboard App anlegen, Redirect-URI `http://127.0.0.1:8898/callback` eintragen, Client-ID in Lumi speichern, „Verbinden“ → Browser → zurück zu Lumi. Danach Suche, Playlist, „Abspielen“ (Premium nötig, Spotify-App muss auf dem Mac offen sein).
- [ ] Apple Musik: Musik-App öffnen, in Lumi Playlists sehen und abspielen; Suche in der Bibliothek. Die AppleScript-Befehle sind nicht gegen die echte App geprüft; Automation-Freigabe erscheint beim ersten Mal.
- [ ] YouTube Music / Amazon Music: „Auf … suchen“ öffnet die Suche im Browser (keine Steuerung).
- [ ] „Trennen“ bei Spotify löscht die Anmeldung (Schlüsselbund-Eintrag `spotify-refresh`).
- [ ] Player oben im Musik-Reiter: bei Spotify/Apple Musik Titel + Pause/Weiter. YouTube im Browser starten → Pause/Weiter-Knöpfe in Lumi steuern es (Bedienungshilfen-Freigabe nötig).
- [ ] Heute: Zurück/Pause/Weiter rechts neben „Heute / Tagesplan" steuern Spotify, Apple Musik bzw. YouTube im Browser.
- [ ] Schalter „YouTube im Browser anzeigen": YouTube im Browser starten, Schalter an, Automation-Freigabe erlauben → Titel erscheint im Player; aus → Titel verschwindet.
- [ ] Heute: Lautsprecher drücken → Lumi liest vor, Symbol wird zum Stopp; Tipp beendet die Ansage sofort und das Symbol springt zurück.
- [ ] YouTube im Browser: Pause in Lumi wechselt das Symbol auf Play und zurück.
- [ ] Heute: Abschnitte Aufgaben/Termine per Pfeil einklappen (bleibt nach Neustart); Aufgabe antippen → Stand, Dauer, Neu planen; Neu planen ändert die Fälligkeit; ▶ startet Fokus und die übrigen Aufgaben rücken nach.

## UX-Runde (Reiter, Einstellungen, Onboarding)
- [ ] Reiterleiste: neue Gruppenreihenfolge, Name am aktiven Reiter nur wenn Platz, Tooltips der anderen; „Mehr“ → „Reiter anordnen …“ öffnet Einstellungen → Notch.
- [ ] Einstellungen → Notch: Karte „Reiter in der Notch“ mit Ein/Aus und „zurücksetzen“; Verbindungen auch ohne „Erweitert“; Datenschutz zeigt oben, wohin Anfragen gehen; KI-Modell: „Kosten & Limits“ eingeklappt.
- [ ] Einrichtungs-Assistent: „Später“ oben rechts schließt, der Assistent kommt beim nächsten Start wieder, bis er fertig ist.
- [ ] Bestätigungskarten: Titel/Knopf passen zur Aktion (anlegen/löschen/senden), nie „Löschen“ bei Anlegen.
- [ ] Notizen/Kalender: Papierkorb immer sichtbar; Aufgaben-Gruppen offen; Mods: Erklärzeile, „Hinzugefügt – zum Benutzen einschalten“.

## Einrichtung und Erklären
- [ ] Assistent: „Später“ schließt, kommt beim nächsten Start wieder; „Nicht mehr anzeigen“ fragt nach und kommt dann nicht mehr; Einstellungen → Allgemein → „Einrichtung öffnen“ öffnet ihn wieder.
- [ ] Erklären per Rechtsklick: Text markieren → Rechtsklick → Dienste → „Mit Lumi erklären“ (erscheint nach Neustart/Neuanmeldung; sonst Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Dienste → Text).
- [ ] Erklären per Ctrl+Option+E: ohne Bedienungshilfen-Freigabe erscheint der Hinweis; mit Freigabe erscheint die Karte.
- [ ] Erklär-Karte: lange Erklärung wird nicht abgeschnitten (Insel wächst bis ca. 420 pt, Text scrollt), Knöpfe und „Nachfragen …“-Zeile sichtbar; Return in der Zeile öffnet den Chat und sendet.

## Antwort entwerfen und Einkreisen (Handtest)
- [ ] Text markieren → Rechtsklick → Dienste → „Mit Lumi erklären“ → „Antwort entwerfen“: Entwurf erscheint, Platzhalter in [ ], Grußformel aus den Einstellungen.
- [ ] „Kopieren“ legt den Entwurf in die Zwischenablage; „Als Mail-Entwurf“ öffnet ein neues Mail-Fenster, nichts wird gesendet.
- [ ] Ctrl+Option+K: Bildschirm dunkel, Einkreisen mit Maus/Trackpad, Esc bricht ab, Overlay verschwindet immer (auch bei Fehler).
- [ ] Freigabe „Bildschirmaufnahme“ fehlt: Hinweis „Freigabe nötig“ statt Absturz.
- [ ] Ausschnitt erscheint NICHT mit abgedunkeltem Overlay im erkannten Text (Wartezeit 150 ms reicht?). Mehrere Bildschirme / Retina-Koordinaten prüfen.
- [ ] Frage per Sprache („Was ist das?“): Lumi hört zu, endet nach Pause, Antwort in der Karte; ohne Sprache nach ~8 s Erklärung.
- [ ] Zweiter Druck auf Ctrl+Option+K bricht das Zuhören ab.

## Notion-Stände, Filter, Tastenkürzel (Handtest)
- [ ] Notion-Aufgabe mit Stand „In progress“ erscheint in Lumi als „In Bearbeitung“; Stand in Notion ändern → nach dem Abgleich ändert sich der Lumi-Stand.
- [ ] Einstellungen → Konten → „Notion-Stände zuordnen“: eigene Zuordnung (z. B. „Waiting for client“ → Info fehlt) wirkt beim nächsten Abgleich.
- [ ] Lumi-Stand lokal ändern, Notion-Stand bleibt gleich: Lumi-Stand bleibt.
- [ ] Aufgaben → Ansicht: Quelle „Aus Notion“ + Stand + Fällig „Morgen“ kombinieren; Auswahl bleibt nach Neustart.
- [ ] Einstellungen → Tastenkürzel: Erklären und Einkreisen ändern und zurücksetzen; belegte Kombination wird rot.

## Umzug Export/Import (Handtest)
- [ ] Einstellungen → Allgemein → Sicherungen → „Alles exportieren …“ legt `taby-….sqlite` im gewählten Ordner ab; Banner nennt den Dateinamen.
- [ ] Auf einem zweiten Mac (oder frischem Benutzer) „Aus Datei importieren …“: Notizen/Aufgaben erscheinen nach dem Neustart; Schlüssel fehlen (erwartet).
- [ ] Beliebige Nicht-Lumi-Datei wählen: Fehlermeldung, nichts wird ersetzt.
- [ ] Datei aus neuerer Lumi-Version: Hinweis „neuere Lumi-Version“.
