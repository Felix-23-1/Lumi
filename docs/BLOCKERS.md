# Blocker

Alles, was ein Subagent nicht lösen oder automatisiert prüfen konnte. Jeder
Eintrag: was blockiert, warum, welcher Mock/Rückfall stattdessen verwendet
wird, und was der Nutzer am echten Mac noch bestätigen muss (siehe auch
`docs/HANDTEST.md`).

## Native App (2026-10-11)
- Kein Xcode installiert → XCTest/swift-testing fehlen; Prüfungen laufen über
  `swift run TabyChecks` (eigenes Gerüst). Mit Xcode auf swift-testing umziehen.
- Keine Freigabe für Bildschirmaufnahme → Aussehen am echten Bildschirm nur über
  SwiftUI-Snapshots (`TabyChecks --snapshots`) und Fensterliste (Position/Ebene) geprüft.
- Notion-Token (Kalenderquelle) lag in der Quellen-Konfiguration in SQLite. Erledigt: Altbestand wird beim
  Start in den Schlüsselbund verschoben und aus SQLite entfernt (`CoreServices.moveTokensToKeychain`, Prüfung
  mit Speicher-Schlüsselbund). Neue Tokens gehen gleich in den Schlüsselbund.
- Integrations-Prüfungen der Szenarien A–E gegen `CoreServices` fehlen noch.
- Wieder geöffnete Aufgabe mit unveränderter Fälligkeit erinnert nicht erneut
  (zurückgezogene Erinnerung bleibt bestätigt; Unterscheidung zu vom Nutzer
  bestätigtem "Verpasst" fehlt). Bekannt, bewusst offen.
- Skript-Mods: eine synchrone Endlosschleife (`while(true){}`) lässt sich mit
  öffentlicher JavaScriptCore-API nicht abbrechen. Taby wartet nach dem Zeitlimit
  nicht weiter, der Hintergrund-Thread bleibt aber belegt. Mods laufen nur nach
  Freigabe durch den Nutzer (Code ist vorher sichtbar).
- Kurzbefehl-Mods nur mit Attrappe geprüft; echter Aufruf von /usr/bin/shortcuts
  steht im Handtest.

## Paket 4 – Oberfläche (nur Ansichten, Kern fehlt noch)
- Dateien auf die Insel ziehen: Overlay und Annahme nur als Snapshot geprüft; ob das
  Fenster Drag-and-Drop überhaupt durchlässt (Fenster ignoriert Mausereignisse außerhalb der
  Insel), ist am echten Mac nicht geprüft.
- Markierten Text übernehmen und Sprechen (gedrückt halten): Einstellungen und Bedienungshilfen-
  Freigabe sind da, die globalen Kurzbefehle selbst sind in der Hülle noch nicht verdrahtet.
- Diktat in der Schnellerfassung: nur mit FakeServices geprüft; echte Spracherkennung und
  Mikrofon-/Spracherkennungs-Freigabe nicht ausprobiert.
- Meeting-Begleiter: Karte erscheint nur in der Insel (nicht im Heute-Reiter); Konflikt mit
  Terminen und echte Kalender-Links nicht geprüft.
- Schlüsselbund-Abfragen nach Updates der Freunde-DMG: ad-hoc-Signatur ändert bei jedem Build die
  Code-Identität, macOS fragt daher je Schlüsselbund-Eintrag neu. Taby liest jedes Geheimnis jetzt nur
  noch einmal je Lauf; ganz weg gehen die Abfragen nur mit einer stabilen Signatur (Entscheidung offen).

## Paket 12 – Nachrichten (iMessage)
- Nur gegen eine nachgebaute `chat.db` (Schema-Ausschnitt, auch im WAL-Modus) geprüft. Echte
  Datenbank, Festplattenvollzugriff (TCC), Automation-Abfrage für Messages und echtes Senden sind
  nur am echten Mac prüfbar (siehe Handtest Paket 12).
- `attributedBody` wird ohne NSUnarchiver gelesen (eigener typedstream-Ausschnitt); exotische
  Nachrichtenformate könnten „(Anhang)“ statt Text zeigen.
- Kalender-Löschen/-Verschieben aus dem Chat: Bestätigung ist gegen Fake-Modell und lokalen Kalender
  geprüft; mit Apple Kalender/Notion nur im Handtest. (Aufträge laufen im Lesemodus, der MCP-Zugang
  bietet delete_event/move_event nicht an – beide können also nur über den Chat mit Bestätigung laufen.)

## Sicherheits-Fixes (Team-Prüfung, SECURITY.md Punkte 6, 9, 10)
- **Notion-OAuth-Rückruf `https://notion-callback` ist kein erreichbarer Host** (SECURITY N1). Der Browser zeigt
  nach der Freigabe „Seite nicht erreichbar“, der Code wird per Einfügen übernommen. Es gibt keine offensichtlich
  richtige Alternative: `http://127.0.0.1:<port>` braucht einen lokalen Listener und eine geänderte Registrierung
  der Notion-Integration; eigene Domain braucht eine Website. Offen, bis eine der beiden Wege gewählt ist.
  Der `state` (Zufallswert je Anmeldung, nur im Speicher) wird jetzt geprüft; PKCE fehlt noch.
- **Notion-OAuth-`state` nur im Speicher**: Wird Taby zwischen „Mit Notion anmelden“ und dem Einfügen beendet,
  muss der Ablauf neu gestartet werden (bewusst, kein Speichern des Werts auf Platte).
- **Paket-Mitschnitt (SECURITY M3)**: Der Arbeitsordner wird jetzt von der root-Shell per `mktemp` unter
  `/private/var/tmp` angelegt (Modus 0711, root-eigen). Der Nutzer kann dort nichts anlegen oder verlinken.
  Nur `out.txt`, `err.txt` und die .pcap werden ihm nach dem Anlegen übergeben, die Ordner-Übergabe am Ende
  geschieht über `chown -R`. Der Steuerordner mit der `stop`-Datei gehört dem Nutzer, root liest sie nur.
  Ungeprüft am echten Mac: der Administrator-Dialog und der Ablauf mit echtem tcpdump (siehe HANDTEST).
- **`-T /usr/bin/codesign` in `friend-setup.command` und `setup-signing.sh` (SECURITY H3, bewusst akzeptiert)**:
  Das selbstsignierte Zertifikat „Taby Local Signing“ erlaubt `codesign` ohne Abfrage. Damit kann jeder Prozess
  desselben Nutzers als Taby signieren und Schlüsselbund- und Datenschutzfreigaben (TCC) mitnutzen. Das Risiko
  bleibt, bis eine Apple-Developer-ID mit Hardened Runtime genutzt wird. Die Signierung selbst wurde nicht geändert.
- **Lokale Sockets (SECURITY N3)**: Die Socket-Datei entsteht jetzt mit `umask(0o077)` beim `bind`, es gibt kein
  Fenster mit 0644. Die MCP-Brücke nimmt höchstens 8 gleichzeitige Verbindungen an, weitere werden sofort
  geschlossen. Offen: Peer-Prüfung (`getpeereid`, Code-Signatur des Aufrufers) und die Verdrängung offener
  Freigaben am Agenten-Hook (`AgentHookServer.swift`, Meldungen fälschen) sind nicht umgesetzt.
- **Modell-Schlüssel (SECURITY N2)**: Der Authorization-Header geht nur über https oder an localhost,
  127.0.0.1 und ::1. Sonst bricht die Anfrage vorher ab mit „Der Schlüssel wird nur über https gesendet.“
  Offen: Bindung des Schlüssels an den Host beim Wechsel der Basis-URL (SECURITY N2 „neu fragen“).
- **Musik-Steuerung (Runde 3)**: Die AppleScript-Abfrage und -Steuerung von Music/Spotify ist nur gegen eine Attrappe geprüft. Ungeprüft am echten Mac: Automation-Freigabe, Verhalten bei laufender App und die Spotify-Feldnamen. Siehe HANDTEST.
- **Sicherung wiederherstellen (Runde 3)**: Plan schreiben, Ersetzen beim Öffnen und Zurückrollen sind mit echten SQLite-Dateien geprüft. Ungeprüft: der Neustart der App nach dem Plan im echten Appstart.
- **Status automatisch**: Slack-Status (Im Fokus / Im Termin) ist nur gegen das gestubbte HTTP und eine Uhr geprüft. Ungeprüft: users.profile:read/write in der echten Slack-App des Nutzers (Scope-Hinweis), Ablauf im Slack-Profil. Element/Matrix: keine Präsenz-API im Matrix-SDK-Connector, nicht umgesetzt.
- **Datenschutz (A3)**: Schranke (Nur lokal, Einwilligung, Mod-Internet) ist mit Stub-HTTP und Snapshots geprüft. Ungeprüft in der laufenden App: der Ablauf der Einwilligungskarte im echten Chat und die Diktat-Angabe (Apple-Spracherkennung schickt Audio ggf. an Apple, nicht am Gerät ausgewertet).

## Performance-Runde: nicht umgesetzt
- `state()` baut AppState nur auf dem Hauptthread; die Speicher-Lesezugriffe laufen im Hintergrund (`StateStoreValues`). Mods, Planer-Zustand, Mail-, Messenger- und Netzwerk-Werte bleiben auf dem Hauptthread, weil sie Laufzeit-Zustand der Schicht sind (nicht im Speicher).
- Tick-Settings: `settings` wird je Takt einmal gelesen und an die Teilfunktionen gereicht; die Auto-Status-, Erinnerungs- und Notion-Pfade lesen weiterhin selbst (dort nicht geändert, siehe Dateien außerhalb des Auftrags).
- Apple-Mail-JXA: Kontonamen je Mailbox statt je Nachricht nicht umgesetzt, weil ohne echtes Mail-Konto nicht prüfbar und eine Fehlzuordnung (gleicher Ordnername in zwei Konten) möglich wäre.

## Runde 5 (Review-Befunde)
- **JavaScriptCore-Watchdog (Skript-Mods, Punkt 12)**: Die harte Zeitgrenze per privatem Symbol (`JSContextGroupSetExecutionTimeLimit`) und die Erkennung der Meldung „JavaScript execution terminated“ sind nur indirekt geprüft. Ungeprüft am echten Mac: ein `while(true){}`-Mod wird nach der Frist beendet und der Platz im Lauf-Limit wird danach frei. Ohne das Symbol bleibt der Mod bis zum Neustart gesperrt.
- **Update-Austausch auf einer echten Installation (Punkt 5)**: Prüfsumme, schreibgeschützter Mount, `codesign --verify --deep -R='identifier "de.felix.taby"'` und der Tausch der App laufen nur als Textprüfung des Skripts. Ungeprüft: der Ablauf mit einer signierten DMG auf einem installierten Lumi, die Einrichtung mit dem Zertifikat dieses Macs und der Neustart. Die Identifier-Anforderung muss mit der echten Signatur der Release-DMG übereinstimmen.
- **Löschen in Apple Erinnerungen (Punkt 9)**: Wird eine Erinnerung in Apple gelöscht, bleibt die Verknüpfung zur offenen Aufgabe bestehen (sonst würde der nächste Lauf sie neu anlegen). Ungeprüft am echten Mac: Verhalten von EventKit beim Löschen, bei Listenwechseln und bei nicht freigegebenen Listen.
- **Bestätigung nach Umbau der MCP-Routen (Punkt 2)**: Der Pin (Server und Werkzeug) wird über die Routentabelle geprüft; das ist mit einem Stub-Server geprüft, nicht mit einem echten MCP-Server.

## Selbst-Signatur (Welle G, Punkt 1)
- **Was sie schützt**: Mit dem eigenen Zertifikat „Taby Local Signing“ behält macOS die Freigaben (Kalender, Erinnerungen, Mitteilungen, Bedienungshilfen) über Updates, weil die Code-Identität gleich bleibt.
- **Was sie nicht schützt**: Ein Programm, das als derselbe Benutzer läuft, kann die App oder den Schlüsselbund-Eintrag ändern oder neu signieren. Der Schlüssel ist nicht exportierbar (`-x`) und hat keine Vorfreigabe für `codesign`; damit fragt der Schlüsselbund bei jeder Signatur. Das ist kein Schutz gegen Manipulation durch dasselbe Benutzerkonto.
- **Ungeprüft am echten Mac**: Der Schlüsselbund-Dialog bei Einrichtung und Update („Erlauben“, nicht „Immer erlauben“), die Zeitüberschreitung von 120 s und das Überleben der Freigaben über ein Update. Siehe `docs/HANDTEST.md`, Runde 5 – Welle G.
- **Zertifikat-Suche**: `security find-identity -p codesigning` ohne `-v`, weil `-v` nicht vertraute selbstsignierte Zertifikate ausblendet.

## Welle H – Netzlaufwerke und Geheimnis-Suche
- **Echte Einhängung nicht geprüft**: NetFS (`NetFSMountURLSync`) und die Fehlercodes sind nur gegen die Header geprüft, nicht gegen einen echten SMB-Server. Die Zuordnung der Fehlercodes zu Meldungen (EAUTH, ENOENT, EHOSTUNREACH) muss am Mac mit echtem NAS bestätigt werden (`docs/HANDTEST.md`, Welle H).
- **Blockierter NetFS-Aufruf läuft weiter**: Nach 30 s meldet Lumi „Server nicht erreichbar“ und verwirft das spätere Ergebnis. Der Aufruf selbst läuft im Hintergrund weiter, bis das System ihn beendet; ein Einhängen, das doch gelingt, bleibt bestehen (Zustand kommt aus der Mount-Tabelle). Am echten Server prüfen.
- **Apple Intelligence und Zwischenablage nur am echten Gerät prüfbar**: Die Geheimnis-Suche mit dem Sprachmodell und das Leeren der Zwischenablage nach 60 s laufen in den Prüfungen nur mit Attrappen.
- **Dateisuche nicht erweitert**: `find_files` durchsucht weiterhin nur den Benutzerordner; Netzlaufwerke werden dort nicht einbezogen (Punkt 4 übersprungen, siehe Bericht).

## Notion-Zugänge (Arbeitsbereiche)

- Notion-Kalenderquellen (`NotionCalendarProvider`) nutzen weiter den Zugangscode des Kalenders je Quelle, nicht die Notion-Zugänge für Aufgaben. Eine Kalenderquelle je Arbeitsbereich wäre der nächste Schritt.
- Der OAuth-Gastfluss (`completeNotionOAuth`) gilt nur für den Standard-Zugang "notion".
- Ungeprüft am echten Notion: zwei echte Arbeitsbereiche mit eigenen Codes (Checks nutzen nur das gestubbte HTTP).
- **Rückgängig für Massenlöschung nicht gruppiert**: Wer eine Notion-Quelle oder einen Zugang mit Aufgaben entfernt, legt je Aufgabe einen eigenen Rückgängig-Eintrag an. Der Stapel kennt keine Gruppe (`UndoSnapshot` hat keinen Fall dafür), also macht ein Schritt nur eine Aufgabe rückgängig; bei mehr als zehn Aufgaben fallen ältere Einträge (auch der Zugang selbst) vom Stapel.
- **Kategorien zweimal berechnet**: `state()` rechnet `NotionTaskOwnership.categories` einmal, `buildOverview` (`Tools/ToolOverview.swift`, nicht im Besitz dieses Auftrags) rechnet sie noch einmal. Ein Parameter dafür braucht eine Änderung in `ToolOverview.swift`.
- **Zugangsanzeige nutzt noch den Gesamtstand**: `SettingsAccountsPage.swift` (Zeilen 284 und 291) prüft für den Standard-Zugang `notionTasksConnected`, das jetzt „irgendein Zugang hat einen Code“ heißt. Richtig ist `notionConnectedAccounts.contains(NotionAccount.legacyId)`; die Datei gehört nicht zu diesem Auftrag.
- **Verbundene Zugänge nur im Speicher**: Die Menge der Zugänge mit Code wird beim ersten Bedarf einmal gelesen (nicht beim Start), danach aktualisiert jeder Schreibzugriff seinen Zugang. Ein Eingriff von außen am Schlüsselbund wird erst nach einem Neustart gesehen.
- **Alle-Ansicht zu hoch in der Vorschau**: Mit der Übersicht nach Kategorie (Auftrag 6) ist `view-tasks-done-due` (`ViewChecks.swift`, nicht im Besitz dieses Auftrags) 392 px hoch, die Grenze ist 380 px. Entweder die Grenze für die Vorschau anheben oder die Fixture dort verkleinern.
- **Menüleiste nicht geprüft**: `menuWillOpen` liest jetzt den Stand des Modells statt `state()`; die Prüfungen decken die AppKit-Menüleiste nicht ab. Am Mac prüfen: Punkt „Update verfügbar“ erscheint nach einer Prüfung.
- **„Lumi ist aktuell.“ nach Prüfung**: Die Anzeige wechselt, wenn die Prüfung ohne Fehler endet (Zustand in der Seite, `onChange`). Die Prüfungen decken nur den Anfangszustand („Noch nicht geprüft.“) ab; das Umschalten nach einem echten Lauf ist am Mac zu prüfen.

## Microsoft ungetestet (kein Konto)
Der Owner hat kein Microsoft-Konto zum Testen. Anmeldung, Outlook-Kalender und Teams sind nur gegen gestubbtes HTTP geprüft (`MicrosoftChecks`, `MicrosoftCalendarChecks`, `MicrosoftTeamsChecks`). Ein echter Mandant muss bestätigen:
- **Gerätecode-Anmeldung**: Die Anfrage an `login.microsoftonline.com/common` mit der eingetragenen Client-ID wird angenommen, der Code wird angezeigt und die Bestätigung im Browser führt zu einem Token (Abstand der Abfragen, `slow_down`, Ablauf).
- **Client-ID-Anleitung**: Die fünf Schritte im Portal stimmen mit der aktuellen Oberfläche von Entra/Azure überein; „Öffentliche Clientflows zulassen“ ist nötig, sonst scheitert das Gerätecode-Verfahren.
- **Freigabe durch die IT**: Im Firmenkonto erscheint AADSTS65001 bzw. 403 genau dann, wenn die Freigabe fehlt; der Hinweistext passt zur echten Meldung.
- **Erneuerung**: Das Erneuerungs-Token wird nach ca. einer Stunde mit dem Zugriffs-Token getauscht und dabei gedreht; die Abmeldung nach Ablauf eines Erneuerungs-Tokens (`invalid_grant`) ist unerprobt.
- **Outlook-Kalender**: `calendarView` mit `Prefer: outlook.timezone` liefert Zeiten in der Systemzone (IANA-Name wie `Europe/Berlin` wird als Zone akzeptiert?), wiederkehrende Termine kommen expandiert, `@odata.nextLink` wird gefolgt. Anlegen, Löschen und Verschieben laufen gegen echte Termine.
- **Teams-Chats**: `GET /me/chats?$expand=lastMessagePreview,members` liefert Titel und Vorschau; Systemmeldungen fallen weg; HTML wird entfernt. Ob Chat-Lesen für private Konten überhaupt erlaubt ist, ist nur mit einem Firmenkonto zu prüfen (private Konten: kein Teams, siehe Karte).
- **Teams-Status**: `POST /me/presence/setUserPreferredPresence` mit `DoNotDisturb` und `PT1H` wird im Teams-Status sichtbar; nach einem Neustart von Lumi kennt der Connector den eigenen Status nicht mehr und lässt ihn nach höchstens einer Stunde von selbst ablaufen (Ablauf in Graph, kein Löschen).
- **Lesestand Teams**: Ungelesen ist nur grob (eine neuere Nachricht eines anderen = 1); Graph liefert keinen Zähler. Der Lesestand liegt nur im Speicher.
- **Zeitzone**: Lumi schickt die IANA-Kennung der Systemzone; ob Graph sie in allen Konten akzeptiert, ist nicht geprüft.
- **Abbrechen der Anmeldung in der Oberfläche**: Der Knopf „Abbrechen“ beendet nur die Anzeige; die Anmeldung auf Microsoft-Seite läuft bis zum Ablauf des Codes weiter. Ein Abbruch am Server gibt es nicht.
- **Netzfehler und Zeitüberschreitung** sind nur im Code geprüft, nicht mit einem echten Netz.

## Meeting-Mitschrift (listen-core, 2026-10-28)
- `LiveMeetingListener` (Mikrofon + ScreenCaptureKit-Systemton + SFSpeechRecognizer on-device) ist ohne echte Freigaben nicht prüfbar; Prüfungen laufen nur gegen `FakeAudioTextSource`. Kompiliert, nie gegen echten Ton gelaufen.
- Offen am echten Mac: Freigaben Mikrofon, Spracherkennung, „Bildschirm- & Systemaudioaufnahme“ (nach Erteilung ist ein Neustart von Lumi nötig); Erkennungsqualität; Verhalten bei fehlendem deutschem Diktat-Paket (Start bricht mit Meldung ab, keine Cloud-Rückfall); Neustart der Erkennung nach ~1 Minute; Lumis eigene Stimme ist per `excludesCurrentProcessAudio` ausgeschlossen.
- Bekannt: Aus Lautsprechern kann das Mikrofon die Anderen mithören („Ich“ doppelt zu „Andere“); mit Kopfhörern vermeiden. Zeitmarken beginnen bei jedem Start wieder bei 00:00.
