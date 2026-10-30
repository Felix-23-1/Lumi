# 0003: Notion-API-Version

**Entscheidung:** `Notion-Version: 2025-09-03` auf jedem Request, mit dem
zweistufigen Data-Sources-Workflow (nicht die ältere, mittlerweile
deprecated "Query a database"-API).

**Herkunft dieser Entscheidung:** Der Orchestrator hat die Notion-API-Doku
für diese Aufgabe bereits recherchiert (Kurzreferenz im Auftrag an Agent D)
und genau diese Version samt Endpunkten vorgegeben. Diese Sitzung hat dazu
**keinen eigenen** Netzwerk-/WebFetch-Zugriff auf `developers.notion.com`
durchgeführt (das war ausdrücklich untersagt, um Race-Bedingungen mit
anderen gleichzeitig arbeitenden Agenten zu vermeiden). Diese Datei
dokumentiert die Begründung aus der vorgegebenen Kurzreferenz; **wer als
Erstes echte Notion-Zugangsdaten verdrahtet, sollte die Doku noch einmal
live gegen `developers.notion.com` prüfen**, falls sich die API seitdem
geändert hat.

**Begründung:**

- Seit Version `2025-09-03` hängen Seiten (Zeilen) einer Notion-Database an
  einer oder mehreren **Data Sources**, nicht mehr direkt an der Database.
  Die alte Abfrage `POST /v1/databases/{database_id}/query` ist für diese
  Version nicht mehr der richtige Weg — die konfigurierte `database_id`
  liefert stattdessen über `GET /v1/databases/{database_id}` die zugehörige(n)
  `data_source_id`(s), gegen die anschließend abgefragt wird.
- Damit bleibt die **Konfiguration pro Kalenderquelle** (BAUPLAN.md
  Abschnitt 10: Datenbank-ID und Feldzuordnung sind konfigurierbar, weil die
  konkrete Datenbank noch nicht bekannt ist) stabil: Der Nutzer trägt weiter
  nur die `database_id` ein, die Data-Source-Auflösung passiert intern bei
  jedem Request (kein zusätzliches Konfigurationsfeld nötig, da bei genau
  einer Data Source pro Database die erste genommen wird — der Normalfall).

**Verwendete Endpunkte (siehe `src/main/calendar/notion.ts`):**

1. `GET https://api.notion.com/v1/databases/{database_id}`
   Header: `Authorization: Bearer <token>`, `Notion-Version: 2025-09-03`.
   Antwort: `{ "object": "database", "data_sources": [{ "id": "...", "name": "..." }] }`.
2. `POST https://api.notion.com/v1/data_sources/{data_source_id}/query`
   Zusätzlich `Content-Type: application/json`, Body `{ "start_cursor"?, "page_size"? }`.
   Antwort: `{ "object": "list", "results": [...], "has_more": bool, "next_cursor": string|null }`.

**Fehlerform (beide Endpunkte):**
`{ "object": "error", "message": "...", "code": "unauthorized"|"object_not_found"|"rate_limited"|"restricted_resource"|..., "status": 401|404|429|403|... }`.
Der Provider prüft `res.ok === false || body.object === 'error'` und wirft
mit `body.message`.

**Nicht implementiert (bewusst, siehe Bericht "Offene Fragen"):** Die
Kurzreferenz deckt nur Discovery (`GET /v1/databases/...`) und Abfrage
(`POST /v1/data_sources/.../query`) ab, kein Seiten-Anlegen
(`POST /v1/pages`). `createNotionProvider` setzt deshalb
`capabilities.write: false`, obwohl die Tabelle in BAUPLAN.md Abschnitt 10
Notion als beschreibbar führt. Eine Schreibfunktion braucht eine eigene,
gegen die aktuelle `/v1/pages`-Doku geprüfte Umsetzung.

**Getestet nur gegen:** `test/fixtures/mock-notion/server.ts` (liefert genau
diese Antwortformen). Kein Zugriff auf echtes Notion in dieser Sitzung.
