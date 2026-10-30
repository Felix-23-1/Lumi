# 0006: Native Swift-App statt Electron

**Entscheidung (Nutzerwunsch, 2026-10-11):** Taby wird komplett nativ in
Swift/SwiftUI neu gebaut (`mac/`, Swift-Paket). Begründung des Nutzers: es
sollen laufend weitere Funktionen dazukommen, und je später der Umbau, desto
teurer. Vorbild für Notch-Verhalten und Animationen ist Coucou
(https://github.com/Louis-CFM/coucou, Code MIT): Zustände hidden/compact/
expanded, `.spring(response: 0.5, dampingFraction: 0.72)` zum Öffnen,
`.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)` zum Schließen, eigene Höhe
je Ansicht, breite flache Insel (640 pt). **Nicht übernommen** (laut
`LICENSE-ASSETS.md` geschützt): Name, Maskottchen Mochi und dessen
Animationen als Figur, Icons, Sounds. Taby behält sein eigenes Maskottchen.

**Übergang:** Die Electron-App (`src/`) bleibt bis zur Funktionsgleichheit
lauffähig und wird erst danach entfernt. Letzter Electron-Stand: c50bf28.

**Aufbau (`mac/Package.swift`):**
- `TabyCore` – Verträge (`Contracts/`, nur Orchestrator) und Kern:
  `Store/` + `Tools/` (A), `LLM/` + `Agent/` (B), `Planner/` (C),
  `Calendar/` + `Agents/` (D). Port der TS-Module 1:1 inkl. Tests.
- `TabyUI` – `Contracts/` (AppModel, FakeServices, Snapshots; Orchestrator),
  `Shell/` (Insel-Fenster, Animationen, Maskottchen; E1), `Views/` (alle
  Ansichten neu gestaltet; E2).
- `TabyApp` – Start + Verdrahtung (Integrator), `TabyHookRelay` (D).
- `TabyChecks` – Prüfprogramm.

**Werkzeuge ohne Xcode:** Auf dem Mac sind nur die Command Line Tools
installiert. `swift build` reicht für SwiftUI, AppKit, EventKit, SQLite3 und
UserNotifications. XCTest und swift-testing fehlen ohne Xcode → eigenes
Prüf-Gerüst (`Contracts/Checks.swift`), Ausführung `swift run TabyChecks`.
UI-Prüfung ohne Bildschirmaufnahme: `swift run TabyChecks --snapshots DIR`
rendert Ansichten per `ImageRenderer` als PNG. Wird Xcode später
installiert, können die Suiten auf swift-testing umziehen.

**Ersetzungen gegenüber Electron:** `safeStorage` → Schlüsselbund
(Keychain); IPC/Preload → Protokoll `TabyServices`; `better-sqlite3` →
SQLite3-C-API; Node-Relay-Skript → `taby-hook-relay` (Swift); Electron
`Notification` → UserNotifications; Apple-Kalender-Spike → EventKit direkt.

**Gate:** `mac/scripts/verify.sh` (= `swift build` + `swift run TabyChecks`).
