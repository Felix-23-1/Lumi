# 0009 – Notion-Aufgaben-Import, read-only

Stand: 2026-10-13 · Status: angenommen

## Kontext
Der Nutzer will Tickets/To-dos aus Notion (eine Datenbank oder eine Seite,
z. B. 1:1-Notizen) als Taby-Aufgaben sehen und planen können, ausdrücklich
**ohne Schreibrechte** für Taby in Notion.

## Entscheidung
- **Nur lesende Aufrufe:** `NotionTaskSource` ruft ausschließlich `GET` und
  Notions Abfrage-`POST`-Endpunkte auf (`/data_sources/{id}/query`,
  `/blocks/{id}/children`), beides liest. Kein `PATCH`/`POST`, das etwas in
  Notion ändert, löscht oder anlegt – anders als `NotionCalendarProvider`
  (Paket 1), der für den Kalender bewusst schreibt.
- **Import statt Spiegel:** Jeder gefundene Eintrag wird als eigene
  Taby-Aufgabe angelegt (`Store.notionTaskLinks` merkt sich Notion-ID →
  Aufgaben-ID). Planung (Paket 4) und Löschen funktionieren wie bei jeder
  anderen Aufgabe, ohne je nach Notion zurückzuschreiben. Ein erneuter
  Abgleich aktualisiert Titel/Status der verknüpften Aufgabe, legt aber keine
  Dublette an; wurde die Aufgabe lokal gelöscht, kommt sie beim nächsten
  Abgleich als neue Aufgabe zurück (keine Lösch-Erkennung, um nicht fälschlich
  Lokales zu entfernen).
- **Zwei Quellen, automatisch erkannt:** Datenbank-ID (jede Zeile eine
  Aufgabe) oder Seiten-ID (To-do-Blöcke, rekursiv – passt für eine 1:1-Seite).
  Eigenschaften werden per **Notion-Typ** erkannt (erste `title`, erste
  `checkbox`, erstes `date`), nicht per Feldname – keine Konfiguration nötig,
  funktioniert mit jeder Datenbank.
- **Eigenes Token, eigener Schlüsselbund-Eintrag** (`calendar-token-notion-tasks`,
  getrennt vom Notion-Kalender-Token), damit ein Widerruf das eine nicht ans
  andere koppelt.
- **Automatischer Abgleich alle 15 Minuten**, wenn eingeschaltet, zusätzlich
  zum manuellen „Jetzt abgleichen“.

## Nachtrag 2026-10-13: Abhaken synchron (ein einziger, eng begrenzter Schreibzugriff)
Der Nutzer wollte ausdrücklich nicht doppelt pflegen: Hakt er eine aus Notion
importierte Aufgabe in Taby ab (oder öffnet sie wieder), setzt Taby **nur
diese eine Checkbox** in Notion – nichts sonst.
- `NotionTaskSource.setPageChecked`/`setBlockChecked` sind die einzigen
  schreibenden Aufrufe des Moduls. `setPageChecked` liest zuerst die Seite, um
  den Namen der Checkbox-Eigenschaft zu finden (Taby merkt sich nur die
  Notion-ID, nicht den Feldnamen), und PATCHt danach **nur** dieses eine Feld.
  Gibt es keine Checkbox-Eigenschaft, passiert nichts.
- Ausgelöst einzig durch `CoreServices.completeTask`/`reopenTask` – also nur,
  wenn der Nutzer selbst (oder über den Chat, mit vorheriger Bestätigung wie
  jedes `delete_*`) in Taby abhakt. Nie durch den Hintergrund-Abgleich.
- Bestes Bemühen: schlägt der Notion-Aufruf fehl, bleibt die Aufgabe in Taby
  trotzdem erledigt/offen; Taby meldet es nur kurz. Der nächste Abgleich
  gleicht wieder ab.
- Reiner Lese-Zweig (`fetchDatabase`/`fetchPageTodos`) bleibt unverändert rein lesend.

## Nachtrag 2026-10-13: OAuth-Anmeldung als Alternative zum manuellen Token (Paket 11)
Ein Internal-Integration-Token muss von einem Workspace-Owner angelegt werden;
Personal Access Tokens kann Notion zufolge ausdrücklich kein Gast anlegen.
Für Nutzer, die nur als Gast in einem fremden Workspace sitzen, bleibt ohne
OAuth keine Selbstbedienung übrig.

- `NotionOAuthConfig` (öffentliche Notion-Verbindung) baut die Anmelde-URL
  (`https://api.notion.com/v1/oauth/authorize?...&owner=user`) und tauscht den
  Rückruf-Code gegen ein Zugriffs-Token (`POST /v1/oauth/token`, Basic-Auth aus
  Client-ID und -Secret).
- **Client-ID ist nicht geheim** (steht offen in der Anmelde-URL) und steht im
  Code. Das **Client-Secret liegt ausschließlich im Schlüsselbund**
  (`security add-generic-password -a "Taby" -s "notion-oauth-client-secret" -w`,
  vom Nutzer selbst eingetragen – läuft nie durch Taby-Code, Logs oder Chat).
- Rückruf per Copy-Paste: Die öffentliche Verbindung ist bei Notion mit
  `https://notion-callback` registriert (nicht änderbar). Diese Seite gibt es
  nicht – nach der Freigabe zeigt der Browser „Seite nicht erreichbar“, die
  Adresse enthält aber `?code=…`. Die Person kopiert die Adresse und fügt sie
  in Taby ein; `NotionOAuthConfig.code(fromPasted:)` zieht den Code heraus.
  Kein URL-Schema, kein lokaler Server nötig.
- `CoreServices.completeNotionOAuth(code:)` tauscht den Code gegen ein Token
  und speichert es wie jedes andere Notion-Token im selben Schlüsselbund-Eintrag
  (`notion-tasks`) speichert – die restliche Sync-/Abhaken-Logik unterscheidet
  nicht, woher das Token kam.
- Die Seiten-Auswahl (welche Notion-Seiten/-Datenbanken freigegeben werden)
  entscheidet Notion selbst während der Anmeldung im Browser, basierend auf
  den eigenen Zugriffsrechten der Person – auch als Gast, ohne dass ein
  Workspace-Admin etwas freigeben muss.

## Nachtrag „Status-Eigenschaft“

Tickets-Datenbanken haben oft eine Status-Eigenschaft (Gruppen „To-do“ / „In progress“ /
„Complete“) statt einer Checkbox. Erledigt ist dann die Option der Gruppe „Complete“
(ohne lesbares Schema: der Optionsname, z. B. „Erledigt“ oder „Done“). Beim Abhaken
setzt Taby ohne Checkbox NUR die Status-Eigenschaft der Zeile auf die Option der Gruppe
„Complete“ bzw. „To-do“ – weiterhin nur der Erledigt-Zustand, nichts sonst. Hat die Zeile
eine Checkbox, bleibt es bei der Checkbox.
