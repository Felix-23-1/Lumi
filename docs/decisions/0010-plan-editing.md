# 0010 – Tagesplan bearbeiten + Prioritätsliste

Stand: 2026-10-13 · Status: angenommen

## Kontext
Der automatische Tagesplan (Paket 4) war bisher nur Vorschlag-oder-nichts:
„Neu planen“ ersetzt alles, „Plan löschen“ wirft alles weg. Der Nutzer will
den Vorschlag **anpassen** können (Reihenfolge ändern, eine Aufgabe für heute
herausnehmen) und zusätzlich eine **Prioritätsliste**, die beeinflusst, was
der Planer zuerst vorschlägt.

## Entscheidung
- **`AutoPlanner.reorder(order:tasks:events:now:...)`** packt den Tag in genau
  der vom Nutzer gegebenen Aufgaben-Reihenfolge neu (reiner Code, nutzt
  denselben Lücken-Packer wie `plan()`). Lässt der Nutzer eine Aufgabe weg,
  wird sie nicht eingeplant (bleibt eine normale offene Aufgabe, kein Löschen).
- **Stabil über die Zeit:** `AutoPlanner.replan()` (der 30-Sekunden-Takt) nimmt
  die Reihenfolge der *bestehenden* Blöcke als Kandidaten-Reihenfolge, nicht
  die Heuristik neu – eine Hand-Sortierung bleibt also über Tickwechsel hinweg
  erhalten, bis der Nutzer „Neu planen“ drückt oder selbst wieder umsortiert.
- **Prioritätsliste** (`task_priority`-Tabelle, Repository `TaskPriorityRepository`):
  eine vom Nutzer gepflegte, geordnete Liste von Aufgaben-IDs. `AutoPlanner.ordered()`
  stellt priorisierte Aufgaben an den Anfang (in der gemerkten Reihenfolge),
  der Rest folgt wie bisher (überfällig → heute → ohne Frist → bald fällig).
  Wirkt nur auf den **nächsten** „Neu planen“-Vorschlag, nicht rückwirkend auf
  einen schon bestehenden Plan.
- **Kein Verlauf/Undo**: der Nutzer sortiert erneut oder plant neu.
